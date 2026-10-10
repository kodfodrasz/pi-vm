#!/usr/bin/bash
set -Eeuo pipefail

# This entrypoint is intentionally small: it validates the boot contract,
# records recovery state, and leaves ordering and reconciliation to make.
STAGE=${PI_VM_STAGE:-/opt/pi-vm}
STATE=${PI_VM_STATE:-/var/lib/pi-vm}
export STAGE STATE
LOG_FILE=$STATE/bootstrap.log
FAILURE_MARKER=$STATE/bootstrap-failed
SUCCESS_MARKER=$STATE/bootstrap-complete
HOSTNAME_FILE=$STATE/hostname
USER_FILE=$STATE/username
BOOT_ID_FILE=${PI_VM_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
MAKEFILE=${PI_VM_MAKEFILE:-$STAGE/Makefile}
RETRY_WRAPPER=${PI_VM_RETRY_WRAPPER:-/usr/local/sbin/pi-vm-bootstrap}
recovered_from_failure=false

fail_bootstrap() {
    local line=$1
    local status=$2
    trap - ERR
    install -d -m 0755 "$STATE"
    local temporary
    temporary=$(mktemp "$STATE/.bootstrap-failed.XXXXXX")
    chmod 0644 "$temporary"
    {
        printf 'line=%s\n' "$line"
        printf 'status=%s\n' "$status"
    } > "$temporary"
    mv -f -- "$temporary" "$FAILURE_MARKER"
    printf 'pi-vm bootstrap failed at line %s (status %s)\n' "$line" "$status" >&2
    exit "$status"
}

validate_hostname() {
    local hostname=$1
    if [[ -z $hostname ]]; then
        echo 'invalid VM_HOSTNAME: must be 1-64 ASCII characters' >&2
        return 1
    fi
    if (( ${#hostname} > 64 )); then
        echo 'invalid VM_HOSTNAME: Linux static hostnames are limited to 64 characters' >&2
        return 1
    fi
    if [[ $hostname == .* || $hostname == *. || $hostname == *..* ]]; then
        echo 'invalid VM_HOSTNAME: labels must not be empty (no leading, trailing, or repeated dots)' >&2
        return 1
    fi
    if [[ $hostname == *[^A-Za-z0-9.-]* ]]; then
        echo 'invalid VM_HOSTNAME: labels may contain only ASCII letters, digits, dots, and interior hyphens' >&2
        return 1
    fi
    local label
    local -a labels
    IFS=. read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        if (( ${#label} > 63 )); then
            echo 'invalid VM_HOSTNAME: each DNS label must be at most 63 characters' >&2
            return 1
        fi
        if [[ ! $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
            echo 'invalid VM_HOSTNAME: each DNS label must be 1-63 ASCII letters or digits, with hyphens only between them' >&2
            return 1
        fi
    done
}

validate_inputs() {
    if (( EUID != 0 )); then
        echo 'pi-vm bootstrap must run as root' >&2
        return 1
    fi
    local candidate
    if [[ ${VM_HOSTNAME+x} == x ]]; then
        candidate=$VM_HOSTNAME
    elif [[ -f $HOSTNAME_FILE ]]; then
        candidate=$(<"$HOSTNAME_FILE")
    else
        candidate=$(hostnamectl --static 2>/dev/null || hostname)
    fi
    validate_hostname "$candidate"
    VM_HOSTNAME=$candidate
    export VM_HOSTNAME
    if [[ ${PI_USER+x} != x ]]; then
        if [[ -f $USER_FILE ]]; then PI_USER=$(<"$USER_FILE"); else PI_USER=pi; fi
    fi
    if [[ ! $PI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ || $PI_USER == root ]]; then
        echo 'invalid PI_USER (expected a non-root Linux username)' >&2
        return 1
    fi
    export PI_USER
    [[ -f $MAKEFILE ]] || { echo "missing Makefile: $MAKEFILE" >&2; return 1; }
    [[ -r $MAKEFILE ]] || return 1
    [[ -r $STAGE/bootstrap.sh ]] || { echo "missing bootstrap wrapper: $STAGE/bootstrap.sh" >&2; return 1; }
}

persist_hostname() {
    local temporary
    temporary=$(mktemp "$HOSTNAME_FILE.XXXXXX")
    chmod 0644 "$temporary"
    printf '%s\n' "$VM_HOSTNAME" > "$temporary"
    mv -f -- "$temporary" "$HOSTNAME_FILE"
    temporary=$(mktemp "$USER_FILE.XXXXXX")
    chmod 0644 "$temporary"
    printf '%s\n' "$PI_USER" > "$temporary"
    mv -f -- "$temporary" "$USER_FILE"
}

install_retry_wrapper() {
    install -D -m 0755 -o root -g root "$STAGE/bootstrap.sh" "$RETRY_WRAPPER"
}

ensure_make() {
    if ! command -v make >/dev/null 2>&1; then
        echo 'make is missing; installing it before reading the guest graph'
        dnf -y install make
    fi
}

run_make() {
    ensure_make
    # The Makefile is silent so credentials passed to commands cannot be
    # disclosed by make's command echoing. Its recipes still report durable
    # progress and failures through this log.
    make --no-print-directory -f "$MAKEFILE" bootstrap
}

trap 'fail_bootstrap "$LINENO" "$?"' ERR
install -d -m 0755 "$STATE"
if [[ -L $LOG_FILE ]]; then
    echo "refusing symlink log path: $LOG_FILE" >&2
    exit 1
elif [[ -e $LOG_FILE ]]; then
    chmod 0600 "$LOG_FILE"
else
    install -m 0600 /dev/null "$LOG_FILE"
fi
exec > >(tee -a "$LOG_FILE") 2>&1

validate_inputs
persist_hostname
install_retry_wrapper
if [[ -f $FAILURE_MARKER ]] \
        || { [[ -f $SUCCESS_MARKER ]] \
            && grep -qx 'recovered_from_failure=true' "$SUCCESS_MARKER"; }; then
    recovered_from_failure=true
fi
rm -f -- "$FAILURE_MARKER" "$FAILURE_MARKER.tmp" "$SUCCESS_MARKER"
export recovered_from_failure
run_make
reboot_required=false
selinux_mode=$(getenforce)
if [[ $selinux_mode != Disabled ]]; then reboot_required=true; fi
temporary=$(mktemp "$STATE/.bootstrap-complete.XXXXXX")
chmod 0644 "$temporary"
{
    printf 'hostname=%s\n' "$VM_HOSTNAME"
    printf 'boot_id=%s\n' "$(<"$BOOT_ID_FILE")"
    printf 'reboot_required=%s\n' "$reboot_required"
    printf 'recovered_from_failure=%s\n' "$recovered_from_failure"
} > "$temporary"
mv -f -- "$temporary" "$SUCCESS_MARKER"
rm -f -- "$FAILURE_MARKER"
printf 'pi-vm bootstrap complete for %s\n' "$VM_HOSTNAME"
# Cloud-init's final power_state module waits for cloud-final. Manual retries
# request the same reboot only after the entire graph has succeeded.
if [[ $reboot_required == true && ${PI_VM_CLOUD_INIT:-0} != 1 ]]; then
    shutdown -r +1 'pi-vm: reboot to fully disable SELinux'
fi
