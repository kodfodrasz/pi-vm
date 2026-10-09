#!/usr/bin/env python3
"""Offline checks for the Python-only prototype."""
from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


seed = load("seed", ROOT / "scripts/seed.py")
kvm = load("kvm", ROOT / "scripts/kvm.py")
hyperv = load("hyperv", ROOT / "scripts/hyperv.py")


class SeedTests(unittest.TestCase):
    def test_render_stages_everything_under_opt_pi_vm(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            seed.render_seed("offline-test", "pipette", output)
            user_data = (output / "user-data").read_text()
            for placeholder in ("__HOSTNAME_YAML__", "__HOSTNAME_SHELL__", "__WRITE_FILES__", "__AUTHORIZED_KEYS__"):
                self.assertNotIn(placeholder, user_data)
            self.assertIn("/opt/pi-vm/bootstrap.py", user_data)
            self.assertIn("/opt/pi-vm/config/smb.conf", user_data)
            payloads = [base64.b64decode(line.split(": ", 1)[1])
                        for line in user_data.splitlines() if line.strip().startswith("content: ")]
            self.assertIn((ROOT / "assets/bootstrap.py").read_bytes(), payloads)
            self.assertNotIn("/etc/pi-vm/", user_data)

    def test_render_rejects_bad_identifiers_and_symlink_local_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                seed.render_seed("../escape", "pipette", Path(directory))
            local = ROOT / "local"
            local.mkdir(exist_ok=True)
            link = local / ".offline-test-link"
            try:
                link.symlink_to(ROOT / "assets/bootstrap.py")
                with self.assertRaises(ValueError):
                    seed.render_seed("offline-test", "pipette", Path(directory))
            finally:
                link.unlink(missing_ok=True)

    def test_windows_normalized_assets_are_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "assets"
            import shutil
            shutil.copytree(ROOT / "assets", source)
            renderer = root / "scripts"
            renderer.mkdir()
            shutil.copyfile(ROOT / "scripts/seed.py", renderer / "seed.py")
            text_asset = source / "cloud-init/user-data.in"
            text_asset.write_bytes(b"\xef\xbb\xbf" + text_asset.read_text(encoding="utf-8-sig").replace("\n", "\r\n").encode())
            normalized = text_asset.read_text(encoding="utf-8-sig").replace("\r\n", "\n").encode()
            self.assertEqual(normalized, (ROOT / "assets/cloud-init/user-data.in").read_bytes())


class SafetyTests(unittest.TestCase):
    def test_resource_contract(self):
        self.assertEqual(kvm.valid_resources("0000512", "0001", "0005120M", "02222"),
                         (512, 1, "5120M", 2222))
        with self.assertRaises(ValueError):
            kvm.valid_resources("511", "1", "5G", "2222")
        with self.assertRaises(ValueError):
            kvm.valid_resources("2048", "1", "4G", "2222")

    def test_exact_process_match_never_accepts_python_impostor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = root / "proc" / "123"
            process.mkdir(parents=True)
            disk = root / "disk.qcow2"
            (process / "exe").symlink_to("/usr/bin/python3")
            (process / "cmdline").write_bytes(b"python\0-drive\0file=" + str(disk).encode() + b"\0")
            self.assertFalse(kvm.qemu_matches(123, disk, root / "proc"))

    def test_invalid_image_never_passes_without_pinned_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.qcow2"
            path.write_bytes(b"not an image")
            self.assertFalse(hyperv.verified_fixed_vhd(path))


class EntrypointTests(unittest.TestCase):
    def test_python_entrypoints_parse(self):
        for path in (ROOT / "scripts/seed.py", ROOT / "scripts/kvm.py", ROOT / "scripts/hyperv.py", ROOT / "scripts/validate.py", ROOT / "assets/bootstrap.py"):
            result = subprocess.run([sys.executable, str(path), "--help"], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, (path, result.stderr))

    def test_no_shell_or_powershell_tooling_remains(self):
        forbidden = list((ROOT / "scripts").glob("*.sh")) + list((ROOT / "scripts").glob("*.ps1"))
        forbidden += list((ROOT / "tests").glob("*.sh")) + list((ROOT / "tests").glob("*.ps1"))
        self.assertEqual(forbidden, [])


if __name__ == "__main__":
    unittest.main()
