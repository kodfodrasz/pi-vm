#!/usr/bin/env python3
"""Exercise fixed-VHD footer encoding, including UInt64 size fields."""
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PWSH, QEMU = shutil.which("pwsh"), shutil.which("qemu-img")
if not PWSH or not QEMU:
    raise SystemExit("footer tests require pwsh and qemu-img")

with tempfile.TemporaryDirectory() as td:
    td = pathlib.Path(td)
    cases = [("small", 512)]
    # Conversion emits a dense fixed VHD; avoid failing on quota-limited CI.
    if shutil.disk_usage(td).free >= 11 * 1024**3:
        cases.append(("5g", 5 * 1024**3))
    else:
        print("Skipping 5 GiB integration case: requires at least 11 GiB free space")
    for label, size in cases:
        raw, vhd = td / f"{label}.raw", td / f"{label}.vhd"
        with raw.open("wb") as f:
            f.truncate(size)
            f.seek(size - 1)
            f.write(b"\x5a")
        subprocess.run([PWSH, "-NoProfile", "-File", str(ROOT / "scripts/raw-to-vhd.ps1"), "-RawPath", str(raw), "-VhdPath", str(vhd)], check=True)
        subprocess.run([QEMU, "info", "-f", "vpc", str(vhd)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([QEMU, "compare", "-f", "raw", "-F", "vpc", str(raw), str(vhd)], check=True)
        with vhd.open("rb") as f:
            f.seek(-512, os.SEEK_END)
            footer = f.read(512)
        assert footer[:8] == b"conectix"
        assert struct.unpack_from(">I", footer, 12)[0] == 0x10000
        assert struct.unpack_from(">Q", footer, 16)[0] == 0xFFFFFFFFFFFFFFFF
        assert footer[28:32] == b"PIVM" and footer[36:40] == b"Wi2k"
        assert struct.unpack_from(">Q", footer, 40)[0] == size
        assert struct.unpack_from(">Q", footer, 48)[0] == size
        assert (sum(footer[:64]) + sum(footer[68:]) + struct.unpack_from(">I", footer, 64)[0]) & 0xFFFFFFFF == 0xFFFFFFFF
print("VHD footer tests passed")
