#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
need python3; need xorriso
id=${1:?usage: seed.sh INSTANCE-ID [HOSTNAME] [OUTPUT.iso]}
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$ ]] || { echo 'Invalid instance id' >&2; exit 2; }
host=${2:-pipette}; iso=${3:-$BUILD_DIR/$id-seed.iso}
[[ ! -e $iso ]] || { echo 'Seed ISO exists; remove it explicitly to recreate' >&2; exit 1; }
mkdir -p "$(dirname -- "$iso")"
dir=$(mktemp -d "$(dirname -- "$iso")/.seed-$id.XXXXXX")
part=$dir/image.iso
trap 'rm -rf -- "$dir"' EXIT
python3 "$PI_VM_ROOT/scripts/render-seed.py" --instance-id "$id" --hostname "$host" --output-dir "$dir/files"
xorriso -as mkisofs -volid CIDATA -joliet -rock -o "$part" "$dir/files"
# Hard-link publication refuses to replace an ISO created by another caller.
ln -- "$part" "$iso"
echo "$iso"
