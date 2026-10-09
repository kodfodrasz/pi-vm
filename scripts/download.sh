#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

require_command curl
require_command flock
require_command qemu-img
require_command sha256sum

mkdir -p "$CACHE_DIR"
exec 9>"$CACHE_DIR/.download.lock"
flock 9

if [[ -L $KVM_IMAGE ]]; then
    echo "Refusing symlink image cache: $KVM_IMAGE" >&2
    exit 1
fi

image_is_valid() {
    [[ -f $KVM_IMAGE ]] || return 1
    [[ $(stat -c %s "$KVM_IMAGE") == "$KVM_IMAGE_SIZE" ]] || return 1
    [[ $(sha256sum "$KVM_IMAGE" | awk '{print $1}') == "$KVM_IMAGE_SHA256" ]] || return 1
    qemu-img check -f qcow2 -- "$KVM_IMAGE" >/dev/null
}

if image_is_valid; then
    echo "Validated image cache: $KVM_IMAGE"
    exit 0
fi

# Never replace an image that may already be a backing file for an instance.
if [[ -e $KVM_IMAGE ]]; then
    echo "Invalid cached image; refusing to replace possible backing parent: $KVM_IMAGE" >&2
    exit 1
fi

require_free_space "$CACHE_DIR" 1500000000
stage=$(mktemp "$CACHE_DIR/.download-XXXXXX")
cleanup() { rm -f -- "$stage"; }
trap cleanup EXIT
curl --fail --location --retry 3 "$KVM_IMAGE_URL" -o "$stage"

if [[ $(stat -c %s "$stage") != "$KVM_IMAGE_SIZE" ]] ||
   [[ $(sha256sum "$stage" | awk '{print $1}') != "$KVM_IMAGE_SHA256" ]]; then
    echo 'Image size/SHA-256 mismatch' >&2
    exit 1
fi
qemu-img check -f qcow2 -- "$stage" >/dev/null
mv -- "$stage" "$KVM_IMAGE"
trap - EXIT
echo "Downloaded and validated: $KVM_IMAGE"
