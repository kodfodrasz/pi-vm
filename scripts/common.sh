#!/usr/bin/env bash
set -Eeuo pipefail

PI_VM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CACHE_DIR=${PI_VM_CACHE:-${HOME}/.cache/pi-vm/images}
BUILD_DIR=${PI_VM_BUILD:-${PI_VM_ROOT}/build}
KVM_IMAGE=${CACHE_DIR}/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2

export PI_VM_ROOT CACHE_DIR BUILD_DIR KVM_IMAGE
export KVM_IMAGE_URL=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
# Fedora-Cloud-44-1.7-x86_64-CHECKSUM, retrieved from Fedora's release mirror.
export KVM_IMAGE_SHA256=28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f
export KVM_IMAGE_SIZE=583729152

# VM images may contain credentials added after installation.
umask 077

require_command() {
    if ! command -v "$1" >/dev/null; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

require_free_space() {
    local path=$1
    local required_bytes=$2
    local available_bytes

    mkdir -p "$path"
    available_bytes=$(df -Pk "$path" | awk 'NR == 2 {printf "%.0f", $4 * 1024}')
    if (( available_bytes < required_bytes )); then
        echo "Insufficient disk space at $path" >&2
        exit 1
    fi
}
