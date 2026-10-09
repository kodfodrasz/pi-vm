#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

usage() {
    echo 'Usage: kvm.sh {start|stop|status} INSTANCE-ID [--force] [--memory MB] [--cpus N] [--disk SIZE] [--ssh-port PORT]'
}

parse_arguments() {
    if (( $# < 2 )); then
        usage >&2
        exit 2
    fi

    action=$1
    instance_id=$2
    shift 2
    memory_mb=2048
    cpu_count=2
    disk_size=16G
    ssh_port=2222
    force=0

    while (( $# )); do
        case $1 in
            --force)
                force=1
                shift
                ;;
            --memory|--cpus|--disk|--ssh-port)
                local option=$1
                if (( $# < 2 )); then
                    echo "Missing value for $option" >&2
                    exit 2
                fi
                case $option in
                    --memory) memory_mb=$2 ;;
                    --cpus) cpu_count=$2 ;;
                    --disk) disk_size=$2 ;;
                    --ssh-port) ssh_port=$2 ;;
                esac
                shift 2
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
    done
}

validate_arguments() {
    case $action in
        start|stop|status) ;;
        *) usage >&2; exit 2 ;;
    esac
    if [[ ! $instance_id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$ ]]; then
        echo 'Invalid instance id' >&2
        exit 2
    fi

    require_command python3
    local normalized
    normalized=$(python3 "$PI_VM_ROOT/scripts/kvm-process.py" validate \
        "$memory_mb" "$cpu_count" "$disk_size" "$ssh_port") || exit $?
    read -r memory_mb cpu_count disk_size ssh_port <<< "$normalized"

    BUILD_DIR=$(realpath -m -- "$BUILD_DIR")
    if [[ $BUILD_DIR == *,* || $BUILD_DIR == *$'\n'* || $BUILD_DIR == *$'\r'* ]]; then
        echo 'Build path must not contain commas or newlines' >&2
        exit 2
    fi
}

initialize_instance() {
    require_command flock
    mkdir -p "$BUILD_DIR"
    exec 8>"$BUILD_DIR/.kvm.lock"
    if ! flock -n 8; then
        echo 'Another KVM operation is in progress' >&2
        exit 1
    fi

    instance_dir=$BUILD_DIR/$instance_id
    pid_file=$instance_dir/qemu.pid
    qmp_socket=$instance_dir/qmp.sock
    base_image=$KVM_IMAGE
    if [[ -L $instance_dir ]]; then
        echo 'Refuse symlink instance directory' >&2
        exit 1
    fi
}

instance_is_running() {
    python3 "$PI_VM_ROOT/scripts/kvm-process.py" status \
        "$pid_file" "$instance_dir/disk.qcow2"
}

prepare_instance_storage() {
    if [[ -e $instance_dir ]] && (( force )); then
        rm -rf -- "$instance_dir"
    fi
    if [[ -L $instance_dir ]]; then
        echo 'Refuse symlink instance directory' >&2
        exit 1
    fi
    mkdir -p "$instance_dir"

    if [[ ! -f $base_image ]]; then
        echo "Validated KVM parent is missing: $base_image" >&2
        exit 1
    fi

    if [[ ! -f $instance_dir/disk.qcow2 ]]; then
        rm -f -- "$instance_dir/disk.qcow2.part"
        require_free_space "$BUILD_DIR" 2000000000
        if [[ ! -f $instance_dir/seed.iso ]]; then
            "$PI_VM_ROOT/scripts/seed.sh" "$instance_id" pipette \
                "$instance_dir/seed.iso" >/dev/null
        fi
        qemu-img create -f qcow2 -F qcow2 -b "$base_image" \
            "$instance_dir/disk.qcow2.part" "$disk_size"
        mv -- "$instance_dir/disk.qcow2.part" "$instance_dir/disk.qcow2"
    fi
    if [[ ! -f $instance_dir/seed.iso ]]; then
        echo 'Instance seed is missing; refuse to start' >&2
        exit 1
    fi
}

launch_qemu() {
    local -a options=(
        -name "$instance_id"
        -machine "q35,accel=kvm"
        -cpu host
        -smp "$cpu_count"
        -m "$memory_mb"
        -display none
        -serial "file:$instance_dir/serial.log"
        -daemonize
        -pidfile "$pid_file"
        -qmp "unix:$qmp_socket,server=on,wait=off"
        -drive "file=$instance_dir/disk.qcow2,if=virtio,format=qcow2"
        -drive "file=$instance_dir/seed.iso,media=cdrom,readonly=on"
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
        -device "virtio-net-pci,netdev=net0"
        -device virtio-balloon-pci
    )

    rm -f -- "$qmp_socket" "$pid_file"
    # QEMU must not inherit the build lock after it becomes a daemon.
    (
        cd "$instance_dir"
        nohup qemu-system-x86_64 "${options[@]}" \
            8>&- >"$instance_dir/qemu.log" 2>&1
    ) || {
        echo "QEMU failed: see $instance_dir/qemu.log" >&2
        exit 1
    }
    echo "Started $instance_id. SSH: ssh -p $ssh_port pi@127.0.0.1; serial: $instance_dir/serial.log"
}

start_instance() {
    if instance_is_running; then
        echo "Instance already active: $instance_id" >&2
        exit 1
    fi

    require_command qemu-img
    require_command qemu-system-x86_64
    require_command xorriso
    if [[ ! -c /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        echo '/dev/kvm unavailable; check BIOS virtualization, host KVM and permissions' >&2
        exit 1
    fi
    if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        echo 'CPU virtualization extensions not exposed' >&2
        exit 1
    fi

    "$PI_VM_ROOT/scripts/download.sh"
    prepare_instance_storage
    launch_qemu
}

show_instance_status() {
    if instance_is_running; then
        echo "$instance_id running (pid $(<"$pid_file"))"
    else
        echo "$instance_id stopped"
        exit 1
    fi
}

request_guest_shutdown() {
    python3 - "$qmp_socket" <<'PY'
import json
import socket
import sys

with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(10)
    connection.connect(sys.argv[1])
    with connection.makefile('rb') as stream:
        json.loads(stream.readline())
        for command in ['qmp_capabilities', 'system_powerdown']:
            connection.sendall((json.dumps({'execute': command}) + '\r\n').encode())
            while True:
                reply = json.loads(stream.readline())
                if 'error' in reply:
                    raise RuntimeError(reply['error'])
                if 'return' in reply:
                    break
PY
}

stop_instance() {
    if ! instance_is_running; then
        echo "$instance_id is not running"
        exit 1
    fi

    if (( force )); then
        if ! python3 "$PI_VM_ROOT/scripts/kvm-process.py" terminate \
            "$pid_file" "$instance_dir/disk.qcow2"; then
            echo 'Could not safely terminate QEMU; disk preserved' >&2
            exit 1
        fi
    else
        request_guest_shutdown
    fi
    echo "Powerdown requested (force=$force); check status before removing files"
}

parse_arguments "$@"
validate_arguments
initialize_instance

case $action in
    start) start_instance ;;
    stop) stop_instance ;;
    status) show_instance_status ;;
esac
