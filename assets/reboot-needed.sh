#!/usr/bin/bash
set -Eeuo pipefail
STATE=${PI_VM_STATE:-/var/lib/pi-vm}
BOOT_ID_FILE=${PI_VM_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
[[ ! -e $STATE/bootstrap-failed && -f $STATE/bootstrap-complete ]] || exit 1
grep -qx 'reboot_required=true' "$STATE/bootstrap-complete" || exit 1
grep -Fxq "boot_id=$(<"$BOOT_ID_FILE")" "$STATE/bootstrap-complete"
