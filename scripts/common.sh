#!/usr/bin/env bash
set -Eeuo pipefail
PI_VM_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export IMAGE_URL=https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz
export IMAGE_SHA256=7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953
export RAW_SHA256=ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce
export RAW_SIZE=5368709120
CACHE_DIR=${PI_VM_CACHE:-${HOME}/.cache/pi-vm/images}
export BUILD_DIR=${PI_VM_BUILD:-${PI_VM_ROOT}/build}
RAW=${CACHE_DIR}/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw
need() { command -v "$1" >/dev/null || { echo "Required command not found: $1" >&2; exit 1; }; }
space_check() { local path=$1 bytes=$2 available; mkdir -p "$path"; available=$(df -Pk "$path" | awk 'NR==2 {printf "%.0f", $4*1024}'); (( available >= bytes )) || { echo "Insufficient disk space at $path" >&2; exit 1; }; }
check_raw() { [[ -f $RAW && $(stat -c %s "$RAW") == "$RAW_SIZE" ]] && [[ $(sha256sum "$RAW" | awk '{print $1}') == "$RAW_SHA256" ]]; }
