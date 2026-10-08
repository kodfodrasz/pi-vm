#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
need curl; need xz; need sha256sum; need flock
mkdir -p "$CACHE_DIR"
exec 9>"$CACHE_DIR/.download.lock"
flock 9
archive=${CACHE_DIR}/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz
if check_raw; then echo "Validated image cache: $RAW"; exit 0; fi
rm -f "$RAW" "$RAW.part"
if [[ ! -f $archive ]] || [[ $(sha256sum "$archive" | awk '{print $1}') != "$IMAGE_SHA256" ]]; then
  rm -f "$archive.part"
  space_check "$CACHE_DIR" 1200000000
  curl --fail --location --retry 3 "$IMAGE_URL" -o "$archive.part"
  [[ $(sha256sum "$archive.part" | awk '{print $1}') == "$IMAGE_SHA256" ]] || { rm -f "$archive.part"; echo 'Image SHA-256 mismatch' >&2; exit 1; }
  mv -f "$archive.part" "$archive"
fi
# Decompression can expand to 5 GiB. Budget conservatively for a dense filesystem.
space_check "$CACHE_DIR" 6500000000
xz --decompress --keep --stdout "$archive" > "$RAW.part"
[[ $(stat -c %s "$RAW.part") == "$RAW_SIZE" ]] && [[ $(sha256sum "$RAW.part" | awk '{print $1}') == "$RAW_SHA256" ]] || { rm -f "$RAW.part"; echo 'Raw image size/SHA-256 mismatch' >&2; exit 1; }
mv -f "$RAW.part" "$RAW"
echo "Downloaded and validated: $RAW"
