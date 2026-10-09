#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"
usage(){ echo 'Usage: kvm.sh {start|stop|status} INSTANCE-ID [--force] [--memory MB] [--cpus N] [--disk SIZE] [--ssh-port PORT]'; }
[[ $# -ge 2 ]] || { usage >&2; exit 2; }
action=$1; id=$2; shift 2
[[ $action == start || $action == stop || $action == status ]] || { usage >&2; exit 2; }
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$ ]] || { echo 'Invalid instance id' >&2; exit 2; }
mem=2048; cpus=2; disk=16G; force=0; port=2222
while (($#)); do
 case $1 in
  --force) force=1; shift;;
  --memory|--cpus|--disk|--ssh-port)
   option=$1; (($# >= 2)) || { echo "Missing value for $option" >&2; exit 2; }
   case $option in --memory) mem=$2;; --cpus) cpus=$2;; --disk) disk=$2;; --ssh-port) port=$2;; esac
   shift 2;;
  *) usage >&2; exit 2;;
 esac
done
need python3
resources=$(python3 "$PI_VM_ROOT/scripts/kvm-process.py" validate "$mem" "$cpus" "$disk" "$port") || exit $?
read -r mem cpus disk port <<< "$resources"
# All paths passed to QEMU must be absolute; commas delimit QEMU drive options.
BUILD_DIR=$(realpath -m -- "$BUILD_DIR")
[[ $BUILD_DIR != *,* && $BUILD_DIR != *$'\n'* && $BUILD_DIR != *$'\r'* ]] || { echo 'Build path must not contain commas or newlines' >&2; exit 2; }
need python3; need flock
mkdir -p "$BUILD_DIR"
exec 8>"$BUILD_DIR/.kvm.lock"
flock -n 8 || { echo 'Another KVM operation is in progress' >&2; exit 1; }
inst=$BUILD_DIR/$id; pid=$inst/qemu.pid; qmp=$inst/qmp.sock
[[ ! -L $inst ]] || { echo 'Refuse symlink instance directory' >&2; exit 1; }
running() { python3 "$PI_VM_ROOT/scripts/kvm-process.py" status "$pid" "$inst/disk.qcow2"; }
case $action in
start)
 if running; then echo "Instance already active: $id" >&2; exit 1; fi
 need qemu-img; need qemu-system-x86_64; need python3; need xorriso
 [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || { echo '/dev/kvm unavailable; check BIOS virtualization, host KVM and permissions' >&2; exit 1; }
 grep -Eq '(vmx|svm)' /proc/cpuinfo || { echo 'CPU virtualization extensions not exposed' >&2; exit 1; }
 "$PI_VM_ROOT/scripts/download.sh"
 mkdir -p "$BUILD_DIR"
 if [[ -e $inst ]] && ((force)); then rm -rf -- "$inst"; fi
 [[ ! -L $inst ]] || { echo 'Refuse symlink instance directory' >&2; exit 1; }
 mkdir -p "$inst"
 base=$BUILD_DIR/fedora44-base.qcow2
 if [[ ! -e $base ]]; then qemu-img convert -p -f raw -O qcow2 -o compat=1.1 "$RAW" "$base.tmp"; qemu-img check "$base.tmp"; mv "$base.tmp" "$base"; fi
 if [[ ! -f $inst/disk.qcow2 ]]; then
   space_check "$BUILD_DIR" 2000000000
   if [[ ! -f $inst/seed.iso ]]; then "$PI_VM_ROOT/scripts/seed.sh" "$id" pipette "$inst/seed.iso" >/dev/null; fi
   qemu-img create -f qcow2 -F qcow2 -b "$base" "$inst/disk.qcow2.part" "$disk"
   mv -- "$inst/disk.qcow2.part" "$inst/disk.qcow2"
 fi
 [[ -f $inst/seed.iso ]] || { echo 'Instance seed is missing; refuse to start' >&2; exit 1; }
 rm -f -- "$qmp" "$pid"
 (cd "$inst"; nohup qemu-system-x86_64 -name "$id" -machine q35,accel=kvm -cpu host -smp "$cpus" -m "$mem" -display none -serial "file:$inst/serial.log" -daemonize -pidfile "$pid" -qmp "unix:$qmp,server=on,wait=off" -drive "file=$inst/disk.qcow2,if=virtio,format=qcow2" -drive "file=$inst/seed.iso,media=cdrom,readonly=on" -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$port-:22 -device virtio-net-pci,netdev=net0 -device virtio-balloon-pci 8>&- >"$inst/qemu.log" 2>&1) || { echo "QEMU failed: see $inst/qemu.log" >&2; exit 1; }
 echo "Started $id. SSH: ssh -p $port pi@127.0.0.1; serial: $inst/serial.log";;
status) running && echo "$id running (pid $(<"$pid"))" || { echo "$id stopped"; exit 1; };;
stop)
 running || { echo "$id is not running"; exit 1; }
 if ((force)); then
  python3 "$PI_VM_ROOT/scripts/kvm-process.py" terminate "$pid" "$inst/disk.qcow2" || { echo 'Could not safely terminate QEMU; disk preserved' >&2; exit 1; }
 else python3 - "$qmp" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
f=s.makefile('rb')
json.loads(f.readline())
for command in ['qmp_capabilities', 'system_powerdown']:
    s.sendall((json.dumps({'execute':command})+'\r\n').encode())
    while True:
        reply=json.loads(f.readline())
        if 'error' in reply: raise RuntimeError(reply['error'])
        if 'return' in reply: break
s.close()
PY
 fi
 echo "Powerdown requested (force=$force); check status before removing files";;
*) usage >&2; exit 2;; esac
