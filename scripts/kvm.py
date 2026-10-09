#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Fedora KVM lifecycle, image verification, and exact-process safety."""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("PI_VM_CACHE", Path.home() / ".cache/pi-vm/images"))
BUILD = Path(os.environ.get("PI_VM_BUILD", ROOT / "build"))
IMAGE_NAME = "Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
IMAGE_URL = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/" + IMAGE_NAME
IMAGE_SHA256 = "28680fe5b371a5a82ebf43a31926e086a168e59949d03969c5093e7071f90b7f"
IMAGE_SIZE = 583729152
QEMU = "qemu-system-x86_64"


def valid_resources(memory: str, cpus: str, disk: str, port: str) -> tuple[int, int, str, int]:
    if any(len(value) > 20 for value in (memory, cpus, disk, port)):
        raise ValueError("resource value is too long")
    if not re.fullmatch(r"[0-9]+", memory) or not re.fullmatch(r"[0-9]+", cpus):
        raise ValueError("memory and CPUs must be integers")
    if not re.fullmatch(r"[0-9]+[GM]", disk) or not re.fullmatch(r"[0-9]+", port):
        raise ValueError("disk must use G or M and port must be an integer")
    mem, cpu, number, port_number = int(memory), int(cpus), int(disk[:-1]), int(port)
    disk_bytes = number * (1024 ** (3 if disk[-1] == "G" else 2))
    if not (512 <= mem <= 1024 * 1024 and 1 <= cpu <= 1024 and
            5 * 1024**3 <= disk_bytes <= 64 * 1024**4 and 1024 <= port_number <= 65535):
        raise ValueError("resources outside supported limits")
    return mem, cpu, f"{number}{disk[-1]}", port_number


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(argv: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=True, **kwargs)


def valid_image(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    if path.stat().st_size != IMAGE_SIZE or sha256(path) != IMAGE_SHA256:
        return False
    try:
        run(["qemu-img", "check", "-f", "qcow2", "--", str(path)], stdout=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return False
    return True


def download_image(cache: Path = CACHE) -> Path:
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(cache, 0o700)
    image = cache / IMAGE_NAME
    lock_path = cache / ".download.lock"
    with lock_path.open("a+") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if valid_image(image):
            return image
        if image.exists() or image.is_symlink():
            raise RuntimeError(f"invalid cached image will not be replaced: {image}")
        if shutil.disk_usage(cache).free < 1_500_000_000:
            raise RuntimeError(f"insufficient free space at {cache}")
        fd, name = tempfile.mkstemp(prefix=".download-", dir=cache)
        stage = Path(name)
        os.close(fd)
        try:
            with urllib.request.urlopen(IMAGE_URL, timeout=60) as source, stage.open("wb") as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
            if not valid_image(stage):
                raise RuntimeError("downloaded Fedora image failed size, hash, or qcow2 checks")
            os.link(stage, image)
            os.chmod(image, 0o600)
        finally:
            stage.unlink(missing_ok=True)
    return image


def read_pid(path: Path) -> int | None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat_is_regular(fd):
                return None
            text = os.read(fd, 65).decode("ascii").strip()
        finally:
            os.close(fd)
    except (OSError, UnicodeError):
        return None
    if not re.fullmatch(r"[1-9][0-9]{0,9}", text):
        return None
    pid = int(text)
    return pid if pid <= 2_147_483_647 else None


def stat_is_regular(fd: int) -> bool:
    return __import__("stat").S_ISREG(os.fstat(fd).st_mode)


def qemu_matches(pid: int, disk: Path, proc_root: Path = Path("/proc")) -> bool:
    try:
        executable = os.readlink(proc_root / str(pid) / "exe")
        if os.path.basename(executable.removesuffix(" (deleted)")) != QEMU:
            return False
        argv = (proc_root / str(pid) / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
        target = os.fsencode(str(disk))
        return any(
            arg == b"-drive" and [field[5:] for field in argv[index + 1].split(b",") if field.startswith(b"file=")] == [target]
            for index, arg in enumerate(argv[:-1])
        )
    except (OSError, ValueError):
        return False


def process_status(pid_file: Path, disk: Path) -> bool:
    pid = read_pid(pid_file)
    return pid is not None and qemu_matches(pid, disk)


def terminate_process(pid_file: Path, disk: Path) -> bool:
    pid = read_pid(pid_file)
    if pid is None or not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        return False
    try:
        handle = os.pidfd_open(pid)
    except OSError:
        return False
    try:
        if not qemu_matches(pid, disk):
            return False
        try:
            signal.pidfd_send_signal(handle, signal.SIGTERM)
        except OSError:
            return False
        return True
    finally:
        os.close(handle)


def qmp_powerdown(socket_path: Path) -> None:
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(socket_path)
        stream = connection.makefile("rb")
        json.loads(stream.readline())
        for command in ("qmp_capabilities", "system_powerdown"):
            connection.sendall((json.dumps({"execute": command}) + "\r\n").encode())
            while True:
                reply = json.loads(stream.readline())
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                if "return" in reply:
                    break


@contextlib.contextmanager
def restrictive_umask():
    old = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(old)


@contextlib.contextmanager
def operation_lock(build: Path):
    build.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (build / ".kvm.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("another KVM operation is in progress") from exc
        yield


def build_instance(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,100}", args.instance):
        raise ValueError("invalid instance id")
    memory, cpus, disk, port = valid_resources(str(args.memory), str(args.cpus), args.disk, str(args.ssh_port))
    build = Path(args.build).resolve()
    return build / args.instance, build / args.instance / "qemu.pid", build / args.instance / "disk.qcow2"


def start(args: argparse.Namespace) -> None:
    instance, pid_file, disk = build_instance(args)
    with restrictive_umask(), operation_lock(Path(args.build).resolve()):
        if process_status(pid_file, disk):
            raise RuntimeError(f"instance already active: {args.instance}")
        for command in ("qemu-img", QEMU, "xorriso"):
            if shutil.which(command) is None:
                raise RuntimeError(f"required command not found: {command}")
        kvm = Path("/dev/kvm")
        if os.name != "nt" and not (kvm.is_char_device() and os.access(kvm, os.R_OK | os.W_OK)):
            raise RuntimeError("/dev/kvm unavailable; check host KVM and permissions")
        if os.name != "nt" and not any(flag in Path("/proc/cpuinfo").read_text(errors="ignore") for flag in ("vmx", "svm")):
            raise RuntimeError("CPU virtualization extensions are not exposed")
        base = download_image(Path(args.cache))
        if args.force and instance.exists():
            if instance.is_symlink():
                raise RuntimeError("refusing symlink instance directory")
            shutil.rmtree(instance)
        if instance.is_symlink():
            raise RuntimeError("refusing symlink instance directory")
        instance.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(instance, 0o700)
        seed = instance / "seed.iso"
        if not disk.exists():
            if shutil.disk_usage(Path(args.build)).free < 2_000_000_000:
                raise RuntimeError("insufficient free space for VM storage")
            if not seed.exists():
                run([sys.executable, str(ROOT / "scripts/seed.py"), args.instance, "--output", str(seed)])
            partial = instance / "disk.qcow2.part"
            partial.unlink(missing_ok=True)
            run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(base), str(partial), args.disk])
            os.link(partial, disk)
            partial.unlink()
            os.chmod(disk, 0o600)
        if not seed.is_file():
            raise RuntimeError("instance seed is missing")
        qmp = instance / "qmp.sock"
        qmp.unlink(missing_ok=True)
        pid_file.unlink(missing_ok=True)
        options = [QEMU, "-name", args.instance, "-machine", "q35,accel=kvm", "-cpu", "host",
                   "-smp", str(cpus), "-m", str(memory), "-display", "none",
                   "-serial", f"file:{instance / 'serial.log'}", "-daemonize", "-pidfile", str(pid_file),
                   "-qmp", f"unix:{qmp},server=on,wait=off", "-drive", f"file={disk},if=virtio,format=qcow2",
                   "-drive", f"file={seed},media=cdrom,readonly=on", "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22",
                   "-device", "virtio-net-pci,netdev=net0", "-device", "virtio-balloon-pci"]
        with (instance / "qemu.log").open("ab") as log:
            subprocess.run(options, cwd=instance, stdout=log, stderr=log, check=True, close_fds=True)
        for artifact in (instance / "qemu.log", instance / "serial.log", pid_file):
            if artifact.exists():
                os.chmod(artifact, 0o600)
    print(f"Started {args.instance}. SSH: ssh -p {port} pi@127.0.0.1")


def stop_or_status(args: argparse.Namespace) -> int:
    instance, pid_file, disk = build_instance(args)
    if not process_status(pid_file, disk):
        if args.action == "status":
            print(f"{args.instance} stopped")
        else:
            print(f"{args.instance} is not running")
        return 1
    if args.action == "status":
        print(f"{args.instance} running (pid {read_pid(pid_file)})")
    elif args.force:
        if not terminate_process(pid_file, disk):
            raise RuntimeError("could not safely terminate QEMU; disk preserved")
        print("Forced stop requested; check status before removing files")
    else:
        qmp_powerdown(instance / "qmp.sock")
        print("Powerdown requested; check status before restarting")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("download", "start", "stop", "status"))
    parser.add_argument("instance", nargs="?")
    parser.add_argument("--memory", type=int, default=2048)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--disk", default="16G")
    parser.add_argument("--ssh-port", type=int, default=2222)
    parser.add_argument("--cache", default=str(CACHE))
    parser.add_argument("--build", default=str(BUILD))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.action == "download":
            print(download_image(Path(args.cache)))
            return 0
        if not args.instance:
            parser.error("instance is required for start, stop, and status")
        return start(args) if args.action == "start" else stop_or_status(args)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
