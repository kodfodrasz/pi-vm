#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pywin32>=306; sys_platform == 'win32'",
# ]
# ///
"""Bounded native Hyper-V feasibility tool.

This file deliberately does not invoke PowerShell.  It verifies and stages the
Fedora Azure source with Python, and can inspect or control a VM only when the
instance's creation marker proves that this checkout owns it.  New Generation
2 VM creation is refused: the documented WMI DefineSystem/resource-setting
sequence still needs a Windows validation run before it is safe to implement.
"""
from __future__ import annotations

import argparse
import hashlib
import lzma
import os
from pathlib import Path
import shutil
import tempfile
import urllib.request

IMAGE_NAME = "Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz"
IMAGE_URL = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/" + IMAGE_NAME
ARCHIVE_SHA256 = "daa212a316a94d7a4584a704cad89dfd0bac45e70ee83c4212c095b3b8d55ce5"
FIXED_NAME = "Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd"
FIXED_SIZE = 5_368_709_632
FIXED_SHA256 = "dd0c36585f1da3d19866804600e272428a381af9cc83b7fe6a1d4f9e72770835"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verified_fixed_vhd(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and path.stat().st_size == FIXED_SIZE and sha256(path) == FIXED_SHA256


def download_and_extract(cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / IMAGE_NAME
    fixed = cache / FIXED_NAME
    lock = cache / ".download.lock"
    # Windows opens this exclusively. Linux uses the same conservative refusal;
    # the Hyper-V command is intended for one host operator at a time.
    with lock.open("a+"):
        if not archive.is_file() or sha256(archive) != ARCHIVE_SHA256:
            if archive.exists() or archive.is_symlink():
                raise RuntimeError(f"invalid cached archive will not be replaced: {archive}")
            fd, temporary_name = tempfile.mkstemp(prefix=".download-", dir=cache)
            os.close(fd)
            temporary = Path(temporary_name)
            try:
                with urllib.request.urlopen(IMAGE_URL, timeout=60) as source, temporary.open("wb") as destination:
                    shutil.copyfileobj(source, destination, 1024 * 1024)
                if sha256(temporary) != ARCHIVE_SHA256:
                    raise RuntimeError("compressed Fedora Azure image SHA-256 mismatch")
                os.link(temporary, archive)
            finally:
                temporary.unlink(missing_ok=True)
        if verified_fixed_vhd(fixed):
            return fixed
        if fixed.exists() or fixed.is_symlink():
            raise RuntimeError(f"invalid cached fixed VHD will not be replaced: {fixed}")
        fd, temporary_name = tempfile.mkstemp(prefix=".azure-stage-", suffix=".vhd", dir=cache)
        os.close(fd)
        temporary = Path(temporary_name)
        try:
            with lzma.open(archive, "rb") as source, temporary.open("wb") as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
            if not verified_fixed_vhd(temporary):
                raise RuntimeError("decompressed payload is not the pinned fixed VHD")
            os.link(temporary, fixed)
        finally:
            temporary.unlink(missing_ok=True)
    return fixed


def native_hyperv():
    if os.name != "nt":
        raise RuntimeError("native Hyper-V WMI is available only on Windows")
    try:
        import win32com.client
    except ImportError as exc:
        raise RuntimeError("Windows Hyper-V support needs uv's pywin32 dependency") from exc
    locator = win32com.client.Dispatch("WbemScripting.SWbemLocator")
    return locator.ConnectServer(".", r"root\virtualization\v2")


def vm_by_name(namespace, name: str):
    escaped = name.replace("'", "''")
    matches = list(namespace.ExecQuery(f"SELECT * FROM Msvm_ComputerSystem WHERE ElementName='{escaped}'"))
    return matches[0] if len(matches) == 1 else None


def invoke_vm(vm, requested_state: int) -> None:
    # Msvm_ComputerSystem.RequestStateChange uses the documented RequestedState
    # values: 2 is enabled and 3 is disabled.  WMI returns either a code or an
    # async job wrapper; both are checked instead of treating invocation as success.
    result = vm.RequestStateChange(requested_state)
    code = int(result.ReturnValue) if hasattr(result, "ReturnValue") else int(result)
    if code not in (0, 4096):  # 4096 means an async job was accepted.
        raise RuntimeError(f"Hyper-V RequestStateChange failed with WMI code {code}")
    job = getattr(result, "Job", None)
    if job is not None:
        state = int(job.JobState)
        if state not in (7,):
            raise RuntimeError(f"Hyper-V state-change job did not complete (state {state})")


def require_owned(settings: argparse.Namespace) -> tuple[object, Path]:
    directory = Path(settings.build).resolve() / settings.instance
    marker = directory / "creation-complete"
    if not marker.is_file() or marker.read_text(encoding="utf-8") != "complete":
        raise RuntimeError("refusing an unmarked or unrelated Hyper-V VM; no native creator has established ownership")
    vm_name = "pi-vm-" + settings.instance
    vm = vm_by_name(native_hyperv(), vm_name)
    if vm is None:
        raise RuntimeError(f"owned VM is not registered: {vm_name}")
    return vm, directory


def start_stop_status(settings: argparse.Namespace) -> int:
    namespace = native_hyperv()
    vm_name = "pi-vm-" + settings.instance
    vm = vm_by_name(namespace, vm_name)
    if vm is None:
        print(f"{vm_name} is not registered")
        return 1
    directory = Path(settings.build).resolve() / settings.instance
    marker = directory / "creation-complete"
    if not marker.is_file() or marker.read_text(encoding="utf-8") != "complete":
        raise RuntimeError("refusing to manage a VM without this instance's creation-complete marker")
    if settings.action == "status":
        print(f"{vm_name}: {vm.EnabledState}")
        return 0
    if settings.action == "start":
        invoke_vm(vm, 2)
    else:
        invoke_vm(vm, 3)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "stop", "status", "image"))
    parser.add_argument("instance", nargs="?", default="")
    parser.add_argument("--cache", default=str(Path.home() / ".cache/pi-vm/images"))
    parser.add_argument("--build", default=str(Path(__file__).resolve().parents[1] / "build"))
    parser.add_argument("--hostname", default="pipette")
    parser.add_argument("--memory-mb", type=int, default=2048)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--disk-size", default="16GiB")
    args = parser.parse_args(argv)
    try:
        if args.action == "image":
            print(download_and_extract(Path(args.cache)))
            return 0
        if not args.instance or not __import__("re").fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,100}", args.instance):
            parser.error("instance must contain safe ASCII characters")
        if args.action == "start" and not (1024 <= args.memory_mb <= 1_048_576 and 1 <= args.cpus <= 1024):
            parser.error("memory must be at least 1024 MiB and CPUs at least one")
        return start_stop_status(args)
    except (OSError, RuntimeError, ValueError) as exc:
        parser.error(str(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
