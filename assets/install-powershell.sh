#!/usr/bin/bash
set -Eeuo pipefail

# PowerShell publishes Fedora RPMs only in its GitHub release assets. Resolve
# the latest stable release before checking the installed version so an older
# local package is reconciled on a retry.
RELEASE_API=https://api.github.com/repos/PowerShell/PowerShell/releases/latest
CACHE=${CACHE:-/var/cache/pi-vm}

fail() {
    printf 'PowerShell install: %s\n' "$*" >&2
    exit 1
}

fetch() {
    local url=$1
    local destination=$2
    curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 120 \
        --retry 3 --retry-delay 2 --retry-max-time 90 --retry-connrefused \
        "$url" -o "$destination"
}

verify_sha256() {
    local expected=$1
    local file=$2
    local actual
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    actual=$(sha256sum "$file")
    actual=${actual%% *}
    [[ ${actual,,} == ${expected,,} ]]
}

extract_hash_from_asset() {
    local hashes_file=$1
    local asset_name=$2
    python3 - "$hashes_file" "$asset_name" <<'PY'
import re
import sys
from pathlib import Path

path, wanted = sys.argv[1:]
data = Path(path).read_bytes()
for encoding in ("utf-8-sig", "utf-16", "utf-16-le", "utf-16-be"):
    try:
        text = data.decode(encoding)
    except UnicodeError:
        continue
    if "\x00" in text and encoding == "utf-8-sig":
        continue
    matches = []
    for line in text.splitlines():
        fields = line.strip().split()
        if len(fields) != 2:
            continue
        digest, name = fields
        if name.startswith("*"):
            name = name[1:]
        if name == wanted and re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            matches.append(digest)
    if len(matches) == 1:
        print(matches[0].lower())
        raise SystemExit(0)
    if matches:
        raise SystemExit("hashes.sha256 contains ambiguous entries for " + wanted)
raise SystemExit("hashes.sha256 has no exact entry for " + wanted)
PY
}

[[ -n $CACHE && $CACHE != / ]] || fail 'refusing an empty or root cache path'
install -d -m 0755 "$CACHE"
release_file=$(mktemp "$CACHE/.powershell-release.XXXXXX")
rpm_temp=$(mktemp "$CACHE/.powershell-rpm.XXXXXX")
hash_temp=$(mktemp "$CACHE/.powershell-hashes.XXXXXX")
cleanup() {
    rm -f -- "$release_file" "$rpm_temp" "$hash_temp"
}
trap cleanup EXIT

fetch "$RELEASE_API" "$release_file"
stable=$(jq -er '(.draft == false and .prerelease == false)' "$release_file") \
    || fail 'latest release metadata is malformed'
[[ $stable == true ]] || fail 'latest release is not a stable, non-draft release'
tag=$(jq -er '.tag_name | strings | select(test("^v[0-9]+(\\.[0-9]+)+$"))' "$release_file") \
    || fail 'latest release tag is not a stable semantic version'
tag_version=${tag#v}

rpm_pattern='^powershell-[0-9]+(\.[0-9]+)+-1\.rh\.x86_64\.rpm$'
rpm_count=$(jq -er --arg pattern "$rpm_pattern" '[.assets[]? | select(.name | test($pattern))] | length' "$release_file") \
    || fail 'latest release assets are malformed'
if (( rpm_count != 1 )); then
    fail "expected exactly one official x86_64 RPM, found $rpm_count"
fi
rpm_name=$(jq -er --arg pattern "$rpm_pattern" '[.assets[] | select(.name | test($pattern))][0].name' "$release_file")
rpm_url=$(jq -er --arg name "$rpm_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_file")
rpm_version=${rpm_name#powershell-}
rpm_version=${rpm_version%-1.rh.x86_64.rpm}
[[ $rpm_version == "$tag_version" ]] || fail "RPM version $rpm_version does not match release $tag_version"
release_base="https://github.com/PowerShell/PowerShell/releases/download/$tag"
[[ $rpm_url == "$release_base/$rpm_name" ]] || fail 'RPM download URL is not the official release asset URL'

api_digest=$(jq -r --arg name "$rpm_name" '.assets[] | select(.name == $name) | .digest // empty' "$release_file")
expected_digest=''
if [[ $api_digest =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
    expected_digest=${BASH_REMATCH[1],,}
else
    hash_count=$(jq -er '[.assets[]? | select(.name == "hashes.sha256")] | length' "$release_file") \
        || fail 'latest release assets are malformed'
    if (( hash_count != 1 )); then
        fail "expected exactly one official hashes.sha256 asset, found $hash_count"
    fi
    hash_url=$(jq -er '.assets[] | select(.name == "hashes.sha256") | .browser_download_url' "$release_file")
    [[ $hash_url == "$release_base/hashes.sha256" ]] || fail 'hash URL is not the official release asset URL'
    fetch "$hash_url" "$hash_temp" || fail 'could not download the official release hashes'
    expected_digest=$(extract_hash_from_asset "$hash_temp" "$rpm_name") \
        || fail 'official release hashes do not identify the selected RPM exactly'
fi

installed_version=''
if installed_version=$(rpm -q powershell --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null); then
    if [[ $installed_version == "$rpm_version-1.rh.x86_64" ]]; then
        command -v pwsh >/dev/null 2>&1 || fail 'installed PowerShell package did not provide pwsh'
        printf 'PowerShell %s is already installed\n' "$installed_version"
        exit 0
    fi
fi

rpm_path=$CACHE/$rpm_name
if [[ -L $rpm_path || (-e $rpm_path && ! -f $rpm_path) ]]; then
    fail "refusing non-regular cached RPM: $rpm_path"
fi
if [[ -f $rpm_path ]] && ! verify_sha256 "$expected_digest" "$rpm_path"; then
    rm -f -- "$rpm_path"
fi
if [[ ! -f $rpm_path ]]; then
    rm -f -- "$rpm_temp"
    rpm_temp=$(mktemp "$CACHE/.powershell-rpm.XXXXXX")
    fetch "$rpm_url" "$rpm_temp" || fail 'could not download the official PowerShell RPM'
    verify_sha256 "$expected_digest" "$rpm_temp" || fail 'PowerShell RPM SHA-256 verification failed'
    chmod 0644 "$rpm_temp"
    mv -f -- "$rpm_temp" "$rpm_path"
fi
verify_sha256 "$expected_digest" "$rpm_path" || fail 'cached PowerShell RPM SHA-256 verification failed'

metadata=$(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' "$rpm_path") \
    || fail 'cached file is not a readable RPM'
[[ $metadata == "powershell $rpm_version 1.rh x86_64" ]] \
    || fail "cached RPM metadata does not match $rpm_name"

# The local RPM is SHA-256 verified above. Keep repository signature checks on;
# localpkg_gpgcheck=0 only avoids requiring a local RPM signing key.
dnf -y --setopt=localpkg_gpgcheck=0 --setopt=gpgcheck=1 install "$rpm_path"
installed_version=$(rpm -q powershell --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n')
[[ $installed_version == "$rpm_version-1.rh.x86_64" ]] \
    || fail "installed PowerShell version is $installed_version, expected $rpm_version-1.rh.x86_64"
command -v pwsh >/dev/null 2>&1 || fail 'PowerShell package did not provide pwsh'
printf 'Installed PowerShell %s\n' "$installed_version"
