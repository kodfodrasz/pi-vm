#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for f in "$root"/scripts/*.sh; do bash -n "$f"; done
python3 -m py_compile "$root/scripts/render-seed.py"
export TMPDIR=${TMPDIR:-$root/build/test-tmp}
mkdir -p "$TMPDIR"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 "$root/tests/render.py"
python3 -m json.tool "$root/assets/pi/settings.json" >/dev/null
if command -v fish >/dev/null; then fish -n "$root/assets/config/config.fish" "$root/assets/config/pi.fish"; fi
if command -v testparm >/dev/null; then testparm -s "$root/assets/config/smb.conf" >/dev/null; fi
python3 "$root/scripts/render-seed.py" --instance-id host-test-unique --output-dir "$tmp/seed"
grep -q 'host-test-unique' "$tmp/seed/meta-data"
grep -q '__WRITE_FILES__' "$tmp/seed/user-data" && exit 1 || true
if command -v shellcheck >/dev/null; then shellcheck -x -S warning -e SC1091,SC2015 "$root"/scripts/*.sh; fi
if command -v pwsh >/dev/null; then pwsh -NoProfile -File "$root/tests/powershell.ps1"; pwsh -NoProfile -File "$root/tests/hyperv.ps1"; fi
echo 'host checks passed'
