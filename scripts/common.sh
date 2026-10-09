#!/usr/bin/env bash
set -Eeuo pipefail

PI_VM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CACHE_DIR=${PI_VM_CACHE:-${HOME}/.cache/pi-vm/images}
BUILD_DIR=${PI_VM_BUILD:-${PI_VM_ROOT}/build}
RAW=${CACHE_DIR}/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw

export PI_VM_ROOT CACHE_DIR BUILD_DIR RAW
export IMAGE_URL=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz
export IMAGE_SHA256=7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953
export RAW_SHA256=ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce
export RAW_SIZE=5368709120

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

raw_image_is_valid() {
    [[ -f $RAW ]] || return 1
    [[ $(stat -c %s "$RAW") == "$RAW_SIZE" ]] || return 1
    [[ $(sha256sum "$RAW" | awk '{print $1}') == "$RAW_SHA256" ]]
}
