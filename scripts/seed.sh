#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

require_command python3
require_command xorriso

instance_id=${1:?usage: seed.sh INSTANCE-ID [HOSTNAME] [OUTPUT.iso]}
hostname=${2:-pipette}
output_iso=${3:-$BUILD_DIR/$instance_id-seed.iso}

if [[ ! $instance_id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$ ]]; then
    echo 'Invalid instance id' >&2
    exit 2
fi
if [[ -e $output_iso ]]; then
    echo 'Seed ISO exists; remove it explicitly to recreate' >&2
    exit 1
fi

output_directory=$(dirname -- "$output_iso")
mkdir -p "$output_directory"
scratch=$(mktemp -d "$output_directory/.seed-$instance_id.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

python3 "$PI_VM_ROOT/scripts/render-seed.py" \
    --instance-id "$instance_id" \
    --hostname "$hostname" \
    --output-dir "$scratch/files"

partial_iso=$scratch/image.iso
xorriso -as mkisofs -volid CIDATA -joliet -rock \
    -o "$partial_iso" "$scratch/files"

# A hard link publishes atomically and refuses to replace another caller's ISO.
ln -- "$partial_iso" "$output_iso"
echo "$output_iso"
