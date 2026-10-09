#!/usr/bin/env python3
"""Safely identify and signal this instance's QEMU process."""
import os
from pathlib import Path
import re
import signal
import stat
import sys

QEMU = "qemu-system-x86_64"
PROC_ROOT = Path("/proc")


def read_pid(pid_file):
    try:
        fd = os.open(pid_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return None
            data = os.read(fd, 65)
            if len(data) > 64:
                return None
            text = data.decode("ascii").strip()
        finally:
            os.close(fd)
    except (OSError, UnicodeError):
        return None
    if not re.fullmatch(r"[1-9][0-9]{0,9}", text):
        return None
    pid = int(text)
    return pid if pid <= 2147483647 else None


def matches(pid, disk):
    try:
        executable = os.readlink(PROC_ROOT / str(pid) / "exe")
        basename = os.path.basename(executable)
        if basename.endswith(" (deleted)"):
            basename = basename[:-10]
        if basename != QEMU:
            return False
        argv = (PROC_ROOT / str(pid) / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
        target = os.fsencode(os.fspath(disk))
        for index, arg in enumerate(argv[:-1]):
            if arg != b"-drive":
                continue
            files = [field[5:] for field in argv[index + 1].split(b",")
                     if field.startswith(b"file=")]
            if files == [target]:
                return True
        return False
    except (OSError, ValueError):
        return False


def status(pid_file, disk):
    pid = read_pid(pid_file)
    return pid is not None and matches(pid, disk)


def terminate(pid_file, disk):
    pid = read_pid(pid_file)
    if pid is None:
        return False
    try:
        # Pin first: never signal a PID after it may have been reused.
        handle = os.pidfd_open(pid)
    except (OSError, AttributeError):
        return False
    try:
        if not matches(pid, disk):
            return False
        try:
            signal.pidfd_send_signal(handle, signal.SIGTERM)
        except (OSError, AttributeError):
            return False
        return True
    finally:
        os.close(handle)


def valid_resources(memory, cpus, disk, port):
    if any(len(value) > 20 for value in (memory, cpus, disk, port)):
        return False
    if not re.fullmatch(r"[0-9]+", memory) or not re.fullmatch(r"[0-9]+", cpus):
        return False
    if not re.fullmatch(r"[0-9]+[GM]", disk) or not re.fullmatch(r"[0-9]+", port):
        return False
    mem, cpu, number, port_num = int(memory), int(cpus), int(disk[:-1]), int(port)
    disk_bytes = number * (1024 ** (3 if disk[-1] == "G" else 2))
    return (512 <= mem <= 1024 * 1024 and 1 <= cpu <= 1024
            and 5 * 1024 ** 3 <= disk_bytes <= 64 * 1024 ** 4
            and 1024 <= port_num <= 65535)


def main(argv):
    if len(argv) == 6 and argv[1] == "validate":
        if valid_resources(*argv[2:]):
            memory, cpus, disk, port = argv[2:]
            print(int(memory), int(cpus), str(int(disk[:-1])) + disk[-1], int(port))
            return 0
        print("Invalid resources (memory 512..1048576 MB, CPUs 1..1024, disk 5G..64T in G/M, port 1024..65535)", file=sys.stderr)
        return 2
    if len(argv) == 4 and argv[1] in ("status", "terminate"):
        ok = status(argv[2], argv[3]) if argv[1] == "status" else terminate(argv[2], argv[3])
        return 0 if ok else 1
    print("Usage: kvm-process.py {status|terminate} PID-FILE DISK | validate MEMORY CPUS DISK PORT", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
