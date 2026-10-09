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
            local_source = stage / "local" / "nested"
            local_source.mkdir(parents=True)
            local_source.chmod(0o755)
            (local_source / "payload.bin").write_bytes(b"payload")
            (local_source / "payload.bin").chmod(0o644)
            (stage / "local" / "bootstrap.sh").write_text("#!/usr/bin/bash\n")
            (stage / "local" / "bootstrap.sh").chmod(0o700)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_log = root / "commands"
            fake = fake_bin / "fake-command"
            fake.write_text(
                "#!/usr/bin/bash\n"
                "name=${0##*/}\n"
                "printf 'start:%s:%s:%s\\n' \"$PI_FAKE_PASS\" \"$name\" \"$*\" >> \"$PI_FAKE_LOG\"\n"
                "case $name in\n"
                "  rpm|pdbedit|id) exit 1 ;;\n"
                "  dnf) [[ -z ${PI_FAKE_DELAY_DNF:-} ]] || sleep 0.05; if [[ -n ${PI_FAKE_FAIL_DNF:-} && -e $PI_FAKE_FAIL_DNF ]]; then rm -f -- $PI_FAKE_FAIL_DNF; exit 1; fi; printf 'done:%s:dnf:%s\\n' \"$PI_FAKE_PASS\" \"$*\" >> \"$PI_FAKE_LOG\" ;;\n"
                "  curl) while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { shift; printf archive > \"$1\"; }; shift; done; printf 'done:%s:curl:%s\\n' \"$PI_FAKE_PASS\" \"$*\" >> \"$PI_FAKE_LOG\" ;;\n"
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
                "done\nprintf 'start:%s:install:%s\\n' \"$PI_FAKE_PASS\" \"${args[*]}\" >> \"$PI_FAKE_LOG\"\nprintf 'done:%s:install:%s\\n' \"$PI_FAKE_PASS\" \"${args[*]}\" >> \"$PI_FAKE_LOG\"\nexec /usr/bin/install \"${args[@]}\"\n"
            )
            fake_install.chmod(0o755)
            shell_file = root / "etc" / "shells"
            shell_file.parent.mkdir(parents=True)
            shell_file.write_text("/usr/bin/fish\n")
            variables = {
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "PI_FAKE_LOG": str(fake_log),
                "PI_FAKE_PASS": "failed",
                "PI_FAKE_DELAY_DNF": "1",
                "PI_FAKE_FAIL_DNF": str(root / "fail-dnf"),
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
            (root / "fail-dnf").touch()
            failed = subprocess.run(["make", "-j4", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                    env=environment, text=True, capture_output=True)
            self.assertNotEqual(failed.returncode, 0)
            retry = root / "usr" / "local" / "sbin" / "pi-vm-bootstrap"
            self.assertTrue(retry.is_file(), "retry wrapper must precede package failure")
            failed_entries = fake_log.read_text().splitlines()
            self.assertFalse(any(":curl:" in line or "authorized_keys" in line for line in failed_entries))
            for pass_name in ("retry-1", "retry-2"):
                environment["PI_FAKE_PASS"] = pass_name
                result = subprocess.run(["make", "-j4", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                        env=environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout + fake_log.read_text())
                entries = [line for line in fake_log.read_text().splitlines() if f":{pass_name}:" in line]
                dnf_done = next(i for i, line in enumerate(entries) if line.startswith(f"done:{pass_name}:dnf:"))
                curl_starts = [i for i, line in enumerate(entries) if line.startswith(f"start:{pass_name}:curl:")]
                config_installs = [i for i, line in enumerate(entries) if "authorized_keys" in line]
                self.assertTrue(all(dnf_done < i for i in curl_starts))
                self.assertTrue(all(dnf_done < i for i in config_installs))
                pi_chown = [i for i, line in enumerate(entries)
                             if line.startswith(f"start:{pass_name}:chown:") and "pi:pi" in line]
                pi_runuser = [i for i, line in enumerate(entries)
                               if line.startswith(f"start:{pass_name}:runuser:") and "npm" in line]
                self.assertTrue(pi_chown)
                self.assertTrue(pi_runuser)
                self.assertLess(min(pi_chown), min(pi_runuser))
            commands = fake_log.read_text().splitlines()
            self.assertGreaterEqual(sum(line.startswith("done:") and ":dnf:" in line for line in commands), 2)
            self.assertGreaterEqual(sum(line.startswith("start:") and ":systemctl:" in line for line in commands), 2)
            local = root / "etc" / "pi-vm" / "local"
            self.assertEqual(local.stat().st_mode & 0o777, 0o700)
            self.assertEqual((local / "nested").stat().st_mode & 0o777, 0o700)
            self.assertEqual((local / "nested" / "payload.bin").stat().st_mode & 0o777, 0o600)
            self.assertEqual((local / "bootstrap.sh").stat().st_mode & 0o777, 0o700)
            self.assertTrue((root / "state" / "samba-initial-password").stat().st_mode & 0o077 == 0)

    @unittest.skipUnless(os.geteuid() == 0, "wrapper recovery test requires root")
    def test_make_install_failure_persists_hostname_for_environment_free_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir()
            shutil.copyfile(WRAPPER, stage / "bootstrap.sh")
            (stage / "Makefile").write_text("bootstrap:\n\ttrue\n")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            calls = root / "calls"
            attempt = root / "dnf-attempt"
            fake = fake_bin / "fake-command"
            fake.write_text(
                "#!/usr/bin/bash\n"
                "name=${0##*/}\n"
                "case $name in\n"
                "  hostnamectl) exit 1 ;;\n"
                "  hostname) printf system-old\\n ;;\n"
                "  id) exit 0 ;;\n"
                "  dnf) if [[ ! -e $PI_DNF_ATTEMPT ]]; then : > $PI_DNF_ATTEMPT; exit 1; fi\n"
                "    printf '#!/usr/bin/bash\\nprintf \\\'%s\\\\n\\\' \\\"$VM_HOSTNAME\\\" >> \\\"$PI_CALLS\\\"\\n' > $PI_FAKE_BIN/make\n"
                "    chmod 0755 $PI_FAKE_BIN/make ;;\n"
                "esac\n"
            )
            fake.chmod(0o755)
            for command in ("hostnamectl", "hostname", "id", "dnf", "install", "chmod", "mktemp", "tee", "mv", "rm"):
                (fake_bin / command).symlink_to(fake if command not in ("install", "chmod", "mktemp", "tee", "mv", "rm") else f"/usr/bin/{command}")
            environment = {
                **os.environ,
                "PATH": str(fake_bin),
                "PI_VM_STAGE": str(stage),
                "PI_VM_STATE": str(root / "state"),
                "PI_VM_RETRY_WRAPPER": str(root / "retry-wrapper"),
                "VM_HOSTNAME": "seeded-name",
                "PI_DNF_ATTEMPT": str(attempt),
                "PI_CALLS": str(calls),
                "PI_FAKE_BIN": str(fake_bin),
            }
            first = subprocess.run([str(WRAPPER)], env=environment, text=True, capture_output=True)
            self.assertNotEqual(first.returncode, 0)
            self.assertEqual((root / "state" / "hostname").read_text(), "seeded-name\\n")
            self.assertTrue((root / "retry-wrapper").is_file())
            environment.pop("VM_HOSTNAME")
            second = subprocess.run([str(root / "retry-wrapper")], env=environment, text=True, capture_output=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["seeded-name"])
            self.assertIn("hostname=seeded-name", (root / "state" / "bootstrap-complete").read_text())

    def test_wrapper_retries_failed_make_without_touching_host_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir()
            shutil.copyfile(WRAPPER, stage / "bootstrap.sh")
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
                "PI_VM_RETRY_WRAPPER": str(state / "retry-wrapper"),
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
