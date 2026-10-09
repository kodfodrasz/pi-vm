#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

require_command curl
require_command flock
require_command sha256sum
require_command xz

mkdir -p "$CACHE_DIR"
exec 9>"$CACHE_DIR/.download.lock"
flock 9

archive=$CACHE_DIR/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz

if raw_image_is_valid; then
    echo "Validated image cache: $RAW"
    exit 0
fi

rm -f -- "$RAW" "$RAW.part"
archive_hash=$(sha256sum "$archive" 2>/dev/null | awk '{print $1}' || true)
if [[ $archive_hash != "$IMAGE_SHA256" ]]; then
    rm -f -- "$archive.part"
    require_free_space "$CACHE_DIR" 1200000000
    curl --fail --location --retry 3 "$IMAGE_URL" -o "$archive.part"

    downloaded_hash=$(sha256sum "$archive.part" | awk '{print $1}')
    if [[ $downloaded_hash != "$IMAGE_SHA256" ]]; then
        rm -f -- "$archive.part"
        echo 'Image SHA-256 mismatch' >&2
        exit 1
    fi
    mv -f -- "$archive.part" "$archive"
fi

# The raw image expands to 5 GiB. Leave room for both files during publication.
require_free_space "$CACHE_DIR" 6500000000
xz --decompress --keep --stdout "$archive" > "$RAW.part"

raw_size=$(stat -c %s "$RAW.part")
raw_hash=$(sha256sum "$RAW.part" | awk '{print $1}')
if [[ $raw_size != "$RAW_SIZE" || $raw_hash != "$RAW_SHA256" ]]; then
    rm -f -- "$RAW.part"
    echo 'Raw image size/SHA-256 mismatch' >&2
    exit 1
fi

mv -f -- "$RAW.part" "$RAW"
echo "Downloaded and validated: $RAW"
