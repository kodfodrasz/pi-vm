#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Offline checks for the Python-only prototype."""
from __future__ import annotations

import base64
import importlib.util
import hashlib
import json
import os
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
bootstrap = load("bootstrap", ROOT / "assets/bootstrap.py")


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

    def test_authorized_key_inventory_matches_key_blobs(self):
        keys = [line for line in (ROOT / "assets/authorized_keys").read_text().splitlines() if line and not line.startswith("#")]
        fingerprints = []
        for key in keys:
            fields = key.split()
            self.assertGreaterEqual(len(fields), 2)
            digest = base64.b64encode(hashlib.sha256(base64.b64decode(fields[1], validate=True)).digest()).decode().rstrip("=")
            fingerprints.append("SHA256:" + digest)
        inventory = [line for line in (ROOT / "assets/public-key-identities.txt").read_text().splitlines() if line.startswith("SHA256:")]
        self.assertEqual(fingerprints, inventory)

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

    def test_windows_normalized_renderer_matches_linux(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            import shutil
            shutil.copytree(ROOT / "assets", root / "assets", ignore=shutil.ignore_patterns("__pycache__"))
            renderer = root / "scripts"
            renderer.mkdir()
            shutil.copyfile(ROOT / "scripts/seed.py", renderer / "seed.py")
            text_files = [path for path in (root / "assets").rglob("*")
                          if path.is_file() and path.name != "authorized_keys"]
            for path in text_files:
                text = path.read_text(encoding="utf-8-sig").replace("\n", "\r\n")
                path.write_bytes(b"\xef\xbb\xbf" + text.encode())
            expected = root / "expected"
            seed.render_seed("windows-test", "pipette", expected)
            actual = root / "actual"
            subprocess.run([sys.executable, str(renderer / "seed.py"), "windows-test",
                            "--hostname", "pipette", "--render-only", str(actual)], check=True)
            self.assertEqual((actual / "user-data").read_bytes(), (expected / "user-data").read_bytes())
            self.assertEqual((actual / "meta-data").read_bytes(), (expected / "meta-data").read_bytes())


class BootstrapTests(unittest.TestCase):
    def test_retry_entrypoint_uses_system_python(self):
        content = b"#!/usr/bin/env -S uv run --script\n# /// script\n"
        self.assertEqual(bootstrap.retry_script_bytes(content), b"#!/usr/bin/python3\n# /// script\n")

    def test_directory_tree_owner_is_applied_with_explicit_fake(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "nested").mkdir()
            (root / "nested/file").write_bytes(b"x")
            calls = []
            bootstrap.set_tree_owner(root, "pi", "pi", owner=lambda path, **kwargs: calls.append((path, kwargs)))
            self.assertEqual({path for path, _ in calls}, {root, root / "nested", root / "nested/file"})
            self.assertTrue(all(kwargs == {"user": "pi", "group": "pi"} for _, kwargs in calls))


class SeedPublicationTests(unittest.TestCase):
    def test_istream_query_and_readback_use_native_interface(self):
        class Stream:
            def __init__(self):
                self.calls = 0
                self.iid = None
            def QueryInterface(self, iid):
                self.iid = iid
                return self
            def Read(self, size):
                self.calls += 1
                return b"iso" if self.calls == 1 else b""
        stream = Stream()
        self.assertIs(seed.query_istream(stream, "IStream"), stream)
        self.assertEqual(stream.iid, "IStream")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "iso"
            seed.write_istream(stream, output)
            self.assertEqual(output.read_bytes(), b"iso")

    def test_local_binary_payload_is_byte_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            local = Path(directory) / "local"
            local.mkdir()
            binary = local / "opaque.bin"
            original = b"\xff\x00\r\n\xc9"
            binary.write_bytes(original)
            local_bootstrap = local / "bootstrap.py"
            local_bootstrap.write_bytes(b"\xef\xbb\xbf#!/usr/bin/python3\r\nprint('ok')\r\n")
            old_local = seed.LOCAL
            try:
                seed.LOCAL = local
                payloads = {name: content for name, _, _, content in seed.collect_assets()}
            finally:
                seed.LOCAL = old_local
            self.assertEqual(payloads["local/opaque.bin"], original)
            self.assertEqual(payloads["local/bootstrap.py"], b"#!/usr/bin/python3\nprint('ok')\n")

    def test_publication_is_private_and_race_refuses_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "seed.iso"
            old_builder = seed.build_iso
            try:
                seed.build_iso = lambda files, partial: partial.write_bytes(b"iso")
                old_umask = os.umask(0o022)
                try:
                    seed.publish_iso("private", "pipette", output)
                finally:
                    os.umask(old_umask)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                output.unlink()
                def racing_builder(files, partial):
                    partial.write_bytes(b"new")
                    output.write_bytes(b"old")
                seed.build_iso = racing_builder
                with self.assertRaises(FileExistsError):
                    seed.publish_iso("race", "pipette", output)
                self.assertEqual(output.read_bytes(), b"old")
            finally:
                seed.build_iso = old_builder


class SafetyTests(unittest.TestCase):
    def test_restrictive_umask_protects_new_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact"
            old_umask = os.umask(0o022)
            try:
                with kvm.restrictive_umask():
                    path.write_bytes(b"private")
            finally:
                os.umask(old_umask)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_download_action_has_no_instance_argument(self):
        with tempfile.TemporaryDirectory() as directory:
            old_download = kvm.download_image
            try:
                kvm.download_image = lambda cache: cache / "image"
                self.assertEqual(kvm.main(["download", "--cache", directory]), 0)
            finally:
                kvm.download_image = old_download

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

    def test_pid_file_and_exact_drive_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pid = root / "qemu.pid"
            pid.write_text("123\n")
            self.assertEqual(kvm.read_pid(pid), 123)
            pid.write_text("123\nextra")
            self.assertIsNone(kvm.read_pid(pid))
            process = root / "proc" / "123"
            process.mkdir(parents=True)
            disk = root / "disk.qcow2"
            (process / "exe").symlink_to("/usr/bin/qemu-system-x86_64")
            (process / "cmdline").write_bytes(b"qemu-system-x86_64\0-drive\0file=" + str(disk).encode() + b",if=virtio\0")
            self.assertTrue(kvm.qemu_matches(123, disk, root / "proc"))
            (process / "cmdline").write_bytes(b"qemu-system-x86_64\0-drive\0file=" + str(disk).encode() + b",file=/other\0")
            self.assertFalse(kvm.qemu_matches(123, disk, root / "proc"))

    def test_invalid_image_never_passes_without_pinned_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.qcow2"
            path.write_bytes(b"not an image")
            self.assertFalse(hyperv.verified_fixed_vhd(path))


class HyperVSafetyTests(unittest.TestCase):
    def test_cache_lock_refuses_concurrent_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / ".download.lock"
            with hyperv.exclusive_cache_lock(lock):
                with self.assertRaises(RuntimeError):
                    with hyperv.exclusive_cache_lock(lock):
                        pass

    def test_cache_space_is_checked_before_download(self):
        with tempfile.TemporaryDirectory() as directory:
            old_usage = hyperv.shutil.disk_usage
            try:
                hyperv.shutil.disk_usage = lambda path: type("Usage", (), {"free": 1})()
                with self.assertRaisesRegex(RuntimeError, "12 GiB"):
                    hyperv.download_and_extract(Path(directory))
            finally:
                hyperv.shutil.disk_usage = old_usage


class EntrypointTests(unittest.TestCase):
    def test_python_entrypoints_parse(self):
        for path in (ROOT / "scripts/seed.py", ROOT / "scripts/kvm.py", ROOT / "scripts/hyperv.py", ROOT / "scripts/validate.py", ROOT / "assets/bootstrap.py"):
            result = subprocess.run([sys.executable, str(path), "--help"], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, (path, result.stderr))

    def test_hyperv_mutation_is_explicitly_disabled(self):
        settings = type("Settings", (), {"action": "stop"})()
        with self.assertRaises(NotImplementedError):
            hyperv.start_stop_status(settings)

    def test_no_shell_or_powershell_tooling_remains(self):
        forbidden = list((ROOT / "scripts").glob("*.sh")) + list((ROOT / "scripts").glob("*.ps1"))
        forbidden += list((ROOT / "tests").glob("*.sh")) + list((ROOT / "tests").glob("*.ps1"))
        self.assertEqual(forbidden, [])


if __name__ == "__main__":
    unittest.main()
