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
MAKEFILE=${PI_VM_MAKEFILE:-$STAGE/Makefile}
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
    if [[ ! $hostname =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
        printf 'invalid VM_HOSTNAME: %s\n' "$hostname" >&2
        return 1
    fi
}

validate_inputs() {
    if (( EUID != 0 )); then
        echo 'pi-vm bootstrap must run as root' >&2
        return 1
    fi
    if [[ -z ${VM_HOSTNAME:-} ]]; then
        VM_HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
    fi
    validate_hostname "$VM_HOSTNAME"
    export VM_HOSTNAME
    [[ -f $MAKEFILE ]] || { echo "missing Makefile: $MAKEFILE" >&2; return 1; }
    [[ -r $MAKEFILE ]] || return 1
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
if [[ -f $FAILURE_MARKER ]] \
        || { [[ -f $SUCCESS_MARKER ]] \
            && grep -qx 'recovered_from_failure=true' "$SUCCESS_MARKER"; }; then
    recovered_from_failure=true
fi
rm -f -- "$FAILURE_MARKER" "$FAILURE_MARKER.tmp" "$SUCCESS_MARKER"
export recovered_from_failure
run_make
temporary=$(mktemp "$STATE/.bootstrap-complete.XXXXXX")
chmod 0644 "$temporary"
{
    printf 'hostname=%s\n' "$VM_HOSTNAME"
    printf 'recovered_from_failure=%s\n' "$recovered_from_failure"
} > "$temporary"
mv -f -- "$temporary" "$SUCCESS_MARKER"
rm -f -- "$FAILURE_MARKER"
printf 'pi-vm bootstrap complete for %s\n' "$VM_HOSTNAME"
