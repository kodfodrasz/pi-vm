#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Offline checks for the Python-only prototype."""
from __future__ import annotations

import argparse
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
class SeedTests(unittest.TestCase):
    def test_render_stages_everything_under_opt_pi_vm(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            seed.render_seed("offline-test", "pipette", output)
            user_data = (output / "user-data").read_text()
            for placeholder in ("__HOSTNAME_YAML__", "__HOSTNAME_SHELL__", "__WRITE_FILES__", "__AUTHORIZED_KEYS__"):
                self.assertNotIn(placeholder, user_data)
            self.assertIn("/opt/pi-vm/bootstrap.sh", user_data)
            self.assertIn("/opt/pi-vm/Makefile", user_data)
            self.assertIn("/opt/pi-vm/config/smb.conf", user_data)
            payloads = [base64.b64decode(line.split(": ", 1)[1])
                        for line in user_data.splitlines() if line.strip().startswith("content: ")]
            self.assertIn((ROOT / "assets/bootstrap.sh").read_bytes(), payloads)
            self.assertIn((ROOT / "assets/Makefile").read_bytes(), payloads)
            self.assertNotIn("/etc/pi-vm/", user_data)

    def test_configurable_cloud_account_upgrade_and_success_only_reboot(self):
        with tempfile.TemporaryDirectory() as directory:
            seed.render_seed("personal", "workbox", Path(directory), "developer")
            user_data = (Path(directory) / "user-data").read_text()
            self.assertIn('name: "developer"', user_data)
            self.assertIn('homedir: "/home/developer"', user_data)
            self.assertNotIn('primary_group:', user_data)
            self.assertIn('"PI_USER=developer"', user_data)
            self.assertIn('"PI_VM_CLOUD_INIT=1"', user_data)
            self.assertIn('package_update: true\npackage_upgrade: true', user_data)
            self.assertIn('condition: [/opt/pi-vm/reboot-needed.sh]', user_data)
            self.assertIn('mode: reboot', user_data)
            self.assertNotIn('__USERNAME_', user_data)
            for username in ("root", "bad;name", "../user", ""):
                with self.subTest(username=username), self.assertRaises(ValueError):
                    seed.render_seed("personal", "workbox", Path(directory), username)

    def test_exact_subagents_configuration(self):
        settings = json.loads((ROOT / "assets/pi/settings.json").read_text())
        self.assertEqual(settings["subagents"], {
            "defaultThinking": "medium",
            "agentOverrides": {
                "scout": {"model": "openai-codex/gpt-6-luna", "thinking": "low"},
                "researcher": {"model": "openai-codex/gpt-6-luna", "thinking": "medium"},
                "evidence-auditor": {"model": "openai-codex/gpt-6-luna", "thinking": "medium"},
                "worker": {"model": "openai-codex/gpt-6.1-sol", "thinking": "medium"},
                "reviewer": {"model": "openai-codex/gpt-6.1-sol", "thinking": "medium"},
                "oracle": {"model": "openai-codex/gpt-6-astra", "thinking": "high"},
            },
        })

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
                link.symlink_to(ROOT / "assets/bootstrap.sh")
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
            fixture_local = root / "local"
            fixture_local.mkdir()
            (fixture_local / "opaque.bin").write_bytes(b"\xfffixture\r\nbytes")
            expected = root / "expected"
            old_local = seed.LOCAL
            try:
                seed.LOCAL = fixture_local
                seed.render_seed("windows-test", "pipette", expected)
            finally:
                seed.LOCAL = old_local
            actual = root / "actual"
            subprocess.run([sys.executable, str(renderer / "seed.py"), "windows-test",
                            "--hostname", "pipette", "--render-only", str(actual)], check=True)
            self.assertEqual((actual / "user-data").read_bytes(), (expected / "user-data").read_bytes())
            self.assertEqual((actual / "meta-data").read_bytes(), (expected / "meta-data").read_bytes())


class BootstrapTests(unittest.TestCase):
    def test_guest_scripts_parse_and_wrapper_uses_make(self):
        result = subprocess.run(["bash", "-n", str(ROOT / "assets/bootstrap.sh")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["make", "-n", "-f", str(ROOT / "assets/Makefile"), "bootstrap"],
                env={**os.environ, "STAGE": str(ROOT / "assets"),
                     "CONFIG": str(Path(directory) / "etc" / "pi-vm"),
                     "CACHE": str(Path(directory) / "cache"),
                     "VM_HOSTNAME": "offline-test"},
                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        wrapper = (ROOT / "assets/bootstrap.sh").read_text()
        self.assertIn("make --no-print-directory", wrapper)
        self.assertIn("VM_HOSTNAME", wrapper)
        self.assertNotIn("bootstrap.py", wrapper)


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
            local_bootstrap = local / "bootstrap.sh"
            local_bootstrap.write_bytes(b"\xef\xbb\xbf#!/usr/bin/bash\r\nprintf 'ok\\n'\r\n")
            legacy_bootstrap = local / "bootstrap.py"
            legacy_bootstrap.write_bytes(b"\xfflegacy\r\n")
            old_local = seed.LOCAL
            try:
                seed.LOCAL = local
                payloads = {name: content for name, _, _, content in seed.collect_assets()}
            finally:
                seed.LOCAL = old_local
            self.assertEqual(payloads["local/opaque.bin"], original)
            self.assertEqual(payloads["local/bootstrap.sh"], b"#!/usr/bin/bash\nprintf 'ok\\n'\n")
            self.assertEqual(payloads["local/bootstrap.py"], b"\xfflegacy\r\n")

    def test_publication_is_private_and_race_refuses_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "seed.iso"
            old_builder = seed.build_iso
            old_link = seed.os.link
            observed_modes = []
            try:
                seed.build_iso = lambda files, partial: partial.write_bytes(b"iso")
                def checking_link(source, destination):
                    observed_modes.append(Path(source).stat().st_mode & 0o777)
                    return old_link(source, destination)
                seed.os.link = checking_link
                old_umask = os.umask(0o022)
                try:
                    seed.publish_iso("private", "pipette", output)
                finally:
                    os.umask(old_umask)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                self.assertEqual(observed_modes, [0o600])
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
                seed.os.link = old_link


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

    def test_start_constructs_normalized_launch_argv_without_real_qemu(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build"
            instance = build / "launch-test"
            instance.mkdir(parents=True)
            (instance / "disk.qcow2").write_bytes(b"disk")
            (instance / "seed.iso").write_bytes(b"seed")
            args = argparse.Namespace(action="start", instance="launch-test", memory=2048,
                                      cpus=2, disk="16G", ssh_port=2222,
                                      cache=str(root / "cache"), build=str(build), force=False)
            calls = []
            old_prerequisites = kvm.require_host_prerequisites
            old_download = kvm.download_image
            old_status = kvm.process_status
            old_run = kvm.subprocess.run
            try:
                kvm.require_host_prerequisites = lambda: None
                kvm.download_image = lambda cache: root / "base.qcow2"
                kvm.process_status = lambda pid, disk: False
                def fake_run(argv, **kwargs):
                    calls.append((argv, kwargs))
                    pid_index = argv.index("-pidfile") + 1
                    Path(argv[pid_index]).write_text("1234\\n")
                    return subprocess.CompletedProcess(argv, 0)
                kvm.subprocess.run = fake_run
                kvm.start(args)
            finally:
                kvm.require_host_prerequisites = old_prerequisites
                kvm.download_image = old_download
                kvm.process_status = old_status
                kvm.subprocess.run = old_run
            self.assertEqual(len(calls), 1)
            argv = calls[0][0]
            self.assertEqual(argv[argv.index("-smp") + 1], "2")
            self.assertEqual(argv[argv.index("-m") + 1], "2048")
            self.assertTrue(any("hostfwd=tcp:127.0.0.1:2222-:22" in value for value in argv))
            self.assertNotEqual(argv[0], sys.executable)

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
        for path in (ROOT / "scripts/seed.py", ROOT / "scripts/kvm.py", ROOT / "scripts/hyperv.py", ROOT / "scripts/validate.py"):
            result = subprocess.run([sys.executable, str(path), "--help"], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, (path, result.stderr))

    def test_hyperv_cli_help_describes_read_only_scope(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/hyperv.py"), "--help"],
                                text=True, capture_output=True, check=True)
        self.assertIn("read-only status", result.stdout)
        self.assertNotIn("inspect or control", result.stdout)

    def test_hyperv_mutation_is_explicitly_disabled(self):
        settings = type("Settings", (), {"action": "stop"})()
        with self.assertRaises(NotImplementedError):
            hyperv.start_stop_status(settings)

    def test_no_shell_or_powershell_tooling_remains(self):
        forbidden = list((ROOT / "scripts").glob("*.sh")) + list((ROOT / "scripts").glob("*.ps1"))
        forbidden += list((ROOT / "tests").glob("*.sh")) + list((ROOT / "tests").glob("*.ps1"))
        self.assertEqual(forbidden, [])
        self.assertFalse((ROOT / "assets/bootstrap.py").exists())


if __name__ == "__main__":
    unittest.main()
