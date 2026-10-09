#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "assets/bootstrap.sh"
MAKEFILE = ROOT / "assets/Makefile"


class GuestMakeTests(unittest.TestCase):
    def test_make_graph_orders_real_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            shutil.copytree(ROOT / "assets", stage)
            config = root / "etc" / "pi-vm"
            output = subprocess.run(
                ["make", "-n", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                env={
                    **os.environ,
                    "STAGE": str(stage),
                    "CONFIG": str(config),
                    "CACHE": str(root / "cache"),
                    "VM_HOSTNAME": "offline-test",
                },
                text=True,
                capture_output=True,
                check=True,
            ).stdout
            operations = [line for line in output.splitlines() if line.strip()]
            positions = {
                marker: next(i for i, line in enumerate(operations) if marker in line)
                for marker in ("hostnamectl set-hostname", "dnf -y install", "rpm -q", "systemctl enable --now sshd")
            }
            self.assertLess(positions["hostnamectl set-hostname"], positions["dnf -y install"])
            self.assertLess(positions["dnf -y install"], positions["rpm -q"])
            self.assertLess(positions["rpm -q"], positions["systemctl enable --now sshd"])

    def test_make_reconciles_with_fakes_and_is_safe_under_j(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            shutil.copytree(ROOT / "assets", stage)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_log = root / "commands"
            fake = fake_bin / "fake-command"
            fake.write_text(
                "#!/usr/bin/bash\n"
                "name=${0##*/}\n"
                "printf '%s\\n' \"$name\" >> \"$PI_FAKE_LOG\"\n"
                "case $name in\n"
                "  rpm|pdbedit|id) exit 1 ;;\n"
                "  curl) while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { shift; printf archive > \"$1\"; }; shift; done ;;\n"
                "  tar) printf starship ;;\n"
                "  sha256sum) ;;\n"
                "  openssl) printf 0123456789abcdef\\n ;;\n"
                "  runuser) if [[ $* == *ssh-keygen* ]]; then\n"
                "    while [[ $# -gt 0 ]]; do if [[ $1 == -f ]]; then shift; printf key > \"$1\"; printf pub > \"$1.pub\"; fi; shift; done; fi ;;\n"
                "esac\n"
            )
            fake.chmod(0o755)
            for command in ("rpm", "pdbedit", "id", "curl", "tar", "sha256sum", "openssl",
                            "runuser", "install", "chown", "hostnamectl", "dnf", "systemctl",
                            "useradd", "usermod", "visudo", "loginctl", "chsh", "testparm",
                            "setsebool", "firewall-cmd", "smbpasswd"):
                (fake_bin / command).symlink_to(fake)
            # The fake shell's install/chown do not apply user names, but all
            # writes remain below this temporary tree.
            real_install = fake_bin / "real-install"
            real_install.symlink_to("/usr/bin/install")
            fake_install = fake_bin / "install"
            fake_install.unlink()
            fake_install.write_text(
                "#!/usr/bin/bash\nargs=()\nwhile [[ $# -gt 0 ]]; do\n"
                "  if [[ $1 == -o || $1 == -g ]]; then shift 2; else args+=(\"$1\"); shift; fi\n"
                "done\nexec /usr/bin/install \"${args[@]}\"\n"
            )
            fake_install.chmod(0o755)
            shell_file = root / "etc" / "shells"
            shell_file.parent.mkdir(parents=True)
            shell_file.write_text("/usr/bin/fish\n")
            variables = {
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "PI_FAKE_LOG": str(fake_log),
                "STAGE": str(stage),
                "CONFIG": str(root / "etc" / "pi-vm"),
                "STATE": str(root / "state"),
                "CACHE": str(root / "cache"),
                "PI_HOME": str(root / "home" / "pi"),
                "SKEL": str(root / "etc" / "skel"),
                "SSH_CONFIG": str(root / "etc" / "ssh"),
                "SUDOERS": str(root / "etc" / "sudoers"),
                "SAMBA_CONFIG": str(root / "etc" / "samba" / "smb.conf"),
                "AVAHI_SERVICES": str(root / "etc" / "avahi"),
                "SHELLS_FILE": str(shell_file),
                "SUBUID_FILE": str(root / "etc" / "subuid"),
                "SUBGID_FILE": str(root / "etc" / "subgid"),
                "AZURE_CONFIG": str(root / "etc" / "waagent.conf"),
                "AZURE_STATE": str(root / "var" / "lib" / "waagent"),
                "AZURE_LOG": str(root / "var" / "log" / "waagent.log"),
                "STARSHIP_BIN": str(root / "usr" / "local" / "bin" / "starship"),
                "BOOTSTRAP_BIN": str(root / "usr" / "local" / "sbin" / "pi-vm-bootstrap"),
                "VM_HOSTNAME": "offline-test",
            }
            environment = {**os.environ, **variables}
            for _ in range(2):
                result = subprocess.run(["make", "-j4", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                        env=environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout + fake_log.read_text())
            commands = fake_log.read_text().splitlines()
            self.assertLess(commands.index("hostnamectl"), commands.index("dnf"))
            self.assertLess(commands.index("dnf"), commands.index("rpm"))
            self.assertGreaterEqual(commands.count("dnf"), 2)
            self.assertGreaterEqual(commands.count("systemctl"), 2)
            self.assertTrue((root / "state" / "samba-initial-password").stat().st_mode & 0o077 == 0)

    def test_wrapper_retries_failed_make_without_touching_host_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir()
            (stage / "Makefile").write_text("# fake graph\n")
            state = root / "state"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            calls = root / "calls"
            fake_make = fake_bin / "make"
            fake_make.write_text(
                "#!/usr/bin/bash\n"
                "printf '%s\\n' \"$VM_HOSTNAME\" >> \"$PI_TEST_CALLS\"\n"
                "[[ ! -e \"$PI_TEST_FAIL\" ]]\n"
            )
            fake_make.chmod(0o755)
            environment = {
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "PI_VM_STAGE": str(stage),
                "PI_VM_STATE": str(state),
                "VM_HOSTNAME": "offline-test",
                "PI_TEST_CALLS": str(calls),
                "PI_TEST_FAIL": str(root / "fail"),
            }
            (root / "fail").touch()
            if os.geteuid() != 0:
                rejected = subprocess.run([str(WRAPPER)], env=environment, text=True, capture_output=True)
                self.assertEqual(rejected.returncode, 1)
                self.assertIn("status=1", (state / "bootstrap-failed").read_text())
                return
            failed = subprocess.run([str(WRAPPER)], env=environment, text=True, capture_output=True)
            self.assertEqual(failed.returncode, 1)
            self.assertIn("status=1", (state / "bootstrap-failed").read_text())
            (root / "fail").unlink()
            succeeded = subprocess.run([str(WRAPPER)], env=environment, text=True, capture_output=True)
            self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
            self.assertEqual((state / "bootstrap-complete").read_text().splitlines()[-1],
                             "recovered_from_failure=true")
            succeeded_again = subprocess.run([str(WRAPPER)], env=environment, text=True, capture_output=True)
            self.assertEqual(succeeded_again.returncode, 0, succeeded_again.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["offline-test"] * 3)


if __name__ == "__main__":
    unittest.main()
