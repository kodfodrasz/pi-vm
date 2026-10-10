#!/usr/bin/env python3
from __future__ import annotations

import os
import pty
import select
import time
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
                "  rpm) exit 1 ;;\n"
                "  id) [[ $1 != -gn ]] || printf 'staff\\n'; [[ -z ${PI_FAKE_MISSING_USER:-} ]] ;;\n"
                "  getent) printf 'dev:x:1000:1000::%s:/bin/bash\\n' \"$PI_FAKE_HOME\" ;;\n"
                "  pdbedit) [[ -e $PI_FAKE_ACCOUNT ]] ;;\n"
                "  smbpasswd) cat > \"$PI_FAKE_ACCOUNT\" ;;\n"
                "  firewall-cmd) case $* in\n"
                "    *--get-ipsets*) cat \"$PI_FAKE_SETS\" 2>/dev/null || true ;;\n"
                "    *--new-ipset=*) for arg in \"$@\"; do [[ $arg != --new-ipset=* ]] || printf '%s ' \"${arg#--new-ipset=}\" >> \"$PI_FAKE_SETS\"; done ;;\n"
                "    *--query-entry=*|*--query-source=*) grep -Fxq \"$*\" \"$PI_FAKE_RULES\" 2>/dev/null ;;\n"
                "    *--add-entry=*|*--add-source=*) printf '%s\\n' \"${*//--add-/--query-}\" >> \"$PI_FAKE_RULES\" ;;\n"
                "  esac ;;\n"
                "  dnf) [[ -z ${PI_FAKE_DELAY_DNF:-} ]] || sleep 0.05; if [[ -n ${PI_FAKE_FAIL_DNF:-} && -e $PI_FAKE_FAIL_DNF ]]; then rm -f -- $PI_FAKE_FAIL_DNF; exit 1; fi; printf 'done:%s:dnf:%s\\n' \"$PI_FAKE_PASS\" \"$*\" >> \"$PI_FAKE_LOG\" ;;\n"
                "  curl) while [[ $# -gt 0 ]]; do [[ $1 == -o ]] && { shift; printf archive > \"$1\"; }; shift; done; printf 'done:%s:curl:%s\\n' \"$PI_FAKE_PASS\" \"$*\" >> \"$PI_FAKE_LOG\" ;;\n"
                "  tar) printf starship ;;\n"
                "  sha256sum) ;;\n"
                "  openssl) printf '0123456789abcdef\\n' ;;\n"
                "  su) shift; shift; shift; shift; script=$1; shift; exec /bin/sh -c \"$script\" \"$@\" ;;\n"
                "  ssh-keygen) while [[ $# -gt 0 ]]; do if [[ $1 == -f ]]; then shift; printf key > \"$1\"; printf pub > \"$1.pub\"; fi; shift; done ;;\n"
                "  setsid) [[ $* == '--fork --wait sh '* ]] ;;\n"
                "  pi) ;;\n"
                "  systemctl) [[ $* != 'enable --now smb nmb wsdd avahi-daemon' ]] || echo SAMBA_SERVICE_START ;;\n"
                "esac\n"
            )
            fake.chmod(0o755)
            for command in ("rpm", "pdbedit", "id", "curl", "tar", "sha256sum", "openssl",
                            "su", "getent", "ssh-keygen", "setsid", "pi", "grubby", "install", "chown", "hostnamectl", "dnf", "systemctl",
                            "usermod", "visudo", "loginctl", "chsh", "testparm",
                            "firewall-cmd", "smbpasswd"):
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
            home = root / "home" / "dev"
            home.mkdir(parents=True)
            selinux = root / "etc" / "selinux-config"
            selinux.write_text("SELINUX=enforcing\n")
            variables = {
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "PI_FAKE_LOG": str(fake_log),
                "PI_USER": "dev",
                "PI_FAKE_HOME": str(home),
                "PI_FAKE_ACCOUNT": str(root / "samba-account"),
                "PI_FAKE_SETS": str(root / "ipsets"),
                "PI_FAKE_RULES": str(root / "rules"),
                "SELINUX_CONFIG": str(selinux),
                "PI_FAKE_PASS": "failed",
                "PI_FAKE_DELAY_DNF": "1",
                "PI_FAKE_FAIL_DNF": str(root / "fail-dnf"),
                "STAGE": str(stage),
                "CONFIG": str(root / "etc" / "pi-vm"),
                "STATE": str(root / "state"),
                "CACHE": str(root / "cache"),

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
            (home / ".bash_profile").write_text("# keep my profile\n")
            custom_fish = home / ".config/fish/config.fish"
            custom_fish.parent.mkdir(parents=True)
            custom_fish.write_text("# keep my fish config\n")
            # Recover an interrupted account creation using the saved password.
            saved_password = home / "samba-initial-password"
            saved_password.write_text("interrupted-password\n")
            saved_password.chmod(0o600)
            (root / "ipsets").write_text("manual_set ")
            (root / "rules").write_text("manual-rule\n")
            for pass_name in ("retry-1", "retry-2"):
                environment["PI_FAKE_PASS"] = pass_name
                result = subprocess.run(["make", "-j4", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                        env=environment, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout + fake_log.read_text())
                self.assertEqual("password: interrupted-password" in result.stdout, pass_name == "retry-1")
                if pass_name == "retry-1":
                    self.assertLess(result.stdout.index("password: interrupted-password"),
                                    result.stdout.index("SAMBA_SERVICE_START"))
                    readme = (home / "README.md").read_text()
                    self.assertIn("# Welcome to offline-test", readme)
                    self.assertIn("sudo smbpasswd dev", readme)
                    self.assertNotIn("interrupted-password", readme)
                    (home / "README.md").write_text("# My unrelated README\n")
                entries = [line for line in fake_log.read_text().splitlines() if f":{pass_name}:" in line]
                dnf_done = next(i for i, line in enumerate(entries) if line.startswith(f"done:{pass_name}:dnf:"))
                curl_starts = [i for i, line in enumerate(entries) if line.startswith(f"start:{pass_name}:curl:")]
                config_installs = [i for i, line in enumerate(entries) if "authorized_keys" in line]
                self.assertTrue(all(dnf_done < i for i in curl_starts))
                self.assertTrue(all(dnf_done < i for i in config_installs))
                pi_chown = [i for i, line in enumerate(entries)
                             if line.startswith(f"start:{pass_name}:chown:") and "dev:staff" in line]
                pi_su = [i for i, line in enumerate(entries)
                               if line.startswith(f"start:{pass_name}:su:") and "install-user.sh" in line]
                self.assertTrue(pi_chown)
                self.assertTrue(pi_su)
                self.assertLess(min(pi_chown), min(pi_su))
            commands = fake_log.read_text().splitlines()
            self.assertGreaterEqual(sum(line.startswith("done:") and ":dnf:" in line for line in commands), 2)
            self.assertGreaterEqual(sum(line.startswith("start:") and ":systemctl:" in line for line in commands), 2)
            local = stage / "local"
            self.assertEqual(local.stat().st_mode & 0o777, 0o700)
            self.assertEqual((local / "nested").stat().st_mode & 0o777, 0o700)
            self.assertEqual((local / "nested" / "payload.bin").stat().st_mode & 0o777, 0o600)
            self.assertEqual((local / "bootstrap.sh").stat().st_mode & 0o777, 0o700)
            self.assertTrue((home / "samba-initial-password").stat().st_mode & 0o077 == 0)
            self.assertEqual(saved_password.read_text(), "interrupted-password\n")
            self.assertEqual((root / "samba-account").read_text(), "interrupted-password\n" * 2)
            self.assertEqual((home / "README.md").read_text(), "# My unrelated README\n")
            self.assertEqual(custom_fish.read_text(), "# keep my fish config\n")
            self.assertEqual((home / ".bash_profile").read_text().count('if [ -n "${BASH_VERSION:-}" ]; then . "$HOME/.config/pi-vm/login.bash"; fi'), 1)
            self.assertIn("# keep my profile", (home / ".bash_profile").read_text())
            self.assertEqual(selinux.read_text(), "SELINUX=disabled\n")
            self.assertEqual((root / "ipsets").read_text(), "manual_set home_lan vpn ")
            self.assertIn("manual-rule", (root / "rules").read_text())
            self.assertEqual(sum(":smbpasswd:" in line for line in commands), 1)
            self.assertEqual(sum("--new-ipset=" in line for line in commands), 2)
            self.assertFalse(any("npm install" in line or ":useradd:" in line or ":runuser:" in line for line in commands))
            self.assertTrue(any(":su:-s /bin/sh dev -c" in line for line in commands))
            self.assertTrue(any("--args=selinux=0" in line for line in commands))
            self.assertFalse((root / "etc" / "pi-vm").exists())
            # A genuinely new account saves one private value atomically.
            (root / "samba-account").unlink()
            saved_password.unlink()
            environment["PI_FAKE_PASS"] = "new-account"
            generated = subprocess.run(["make", "-j4", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                       env=environment, text=True, capture_output=True)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            self.assertEqual(saved_password.read_text(), "0123456789abcdef\n")
            self.assertEqual(saved_password.stat().st_mode & 0o777, 0o600)
            self.assertEqual(sum(":openssl:" in line for line in fake_log.read_text().splitlines()), 1)
            self.assertTrue(any(":chown:dev:staff " in line and ".samba-password." in line
                                for line in fake_log.read_text().splitlines()))
            self.assertIn(f"saved in: {saved_password}", generated.stdout)

            environment["PI_FAKE_MISSING_USER"] = "1"
            missing = subprocess.run(["make", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                     env=environment, text=True, capture_output=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("Cloud-init must create account dev", missing.stderr)
            environment.pop("PI_FAKE_MISSING_USER")
            environment["PI_USER"] = "dev;touch /tmp/not-allowed"
            invalid = subprocess.run(["make", "--no-print-directory", "-f", str(MAKEFILE), "bootstrap"],
                                     env=environment, text=True, capture_output=True)
            self.assertNotEqual(invalid.returncode, 0)


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
            fake_make_source = root / "fake-make"
            fake_make_source.write_text(
                "#!/usr/bin/bash\n"
                "printf '%s:%s\\n' \"$VM_HOSTNAME\" \"$PI_USER\" >> \"$PI_CALLS\"\n"
            )
            fake = fake_bin / "fake-command"
            fake.write_text(
                "#!/usr/bin/bash\n"
                "name=${0##*/}\n"
                "case $name in\n"
                "  hostnamectl) exit 1 ;;\n"
                "  hostname) printf system-old\\n ;;\n"
                "  id) exit 0 ;;\n"
                "  getenforce) printf 'Disabled\\n' ;;\n"
                "  dnf) if [[ ! -e $PI_DNF_ATTEMPT ]]; then : > $PI_DNF_ATTEMPT; exit 1; fi\n"
                "    cp -- \"$PI_FAKE_MAKE_SOURCE\" \"$PI_FAKE_BIN/make\"\n"
                "    chmod 0755 $PI_FAKE_BIN/make ;;\n"
                "esac\n"
            )
            fake.chmod(0o755)
            for command in ("hostnamectl", "hostname", "id", "getenforce", "dnf", "install", "chmod", "mktemp", "tee", "mv", "rm", "cp"):
                (fake_bin / command).symlink_to(fake if command not in ("install", "chmod", "mktemp", "tee", "mv", "rm", "cp") else f"/usr/bin/{command}")
            environment = {
                **os.environ,
                "PATH": str(fake_bin),
                "PI_VM_STAGE": str(stage),
                "PI_VM_STATE": str(root / "state"),
                "PI_VM_RETRY_WRAPPER": str(root / "retry-wrapper"),
                "VM_HOSTNAME": "seeded-name",
                "PI_USER": "developer",
                "PI_DNF_ATTEMPT": str(attempt),
                "PI_CALLS": str(calls),
                "PI_FAKE_BIN": str(fake_bin),
                "PI_FAKE_MAKE_SOURCE": str(fake_make_source),
            }
            first = subprocess.run([str(WRAPPER)], env=environment, text=True, capture_output=True)
            self.assertNotEqual(first.returncode, 0)
            self.assertEqual((root / "state" / "hostname").read_text(), "seeded-name\n")
            self.assertTrue((root / "retry-wrapper").is_file())
            self.assertEqual((root / "state" / "username").read_text(), "developer\n")
            environment.pop("VM_HOSTNAME")
            environment.pop("PI_USER")
            second = subprocess.run([str(root / "retry-wrapper")], env=environment, text=True, capture_output=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["seeded-name:developer"])
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
            getenforce = fake_bin / "getenforce"
            getenforce.write_text("#!/bin/sh\nprintf 'Disabled\\n'\n")
            getenforce.chmod(0o755)
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


def terminal_run(argv, environment):
    """Run an offline command with a real controlling terminal and timeout."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, environment)
    output = bytearray()
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], .1)[0]:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
        else:
            os.kill(pid, 9)
            raise AssertionError("offline terminal command timed out")
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode()
    finally:
        os.close(fd)


class PersonalBootstrapTests(unittest.TestCase):
    def test_installer_workflow_detaches_terminal_and_keeps_user_context(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / ".ssh").mkdir()
            (home / ".ssh/pi-vm-deploy").touch()
            (home / ".pi/agent").mkdir(parents=True)
            binaries = home / ".local/bin"
            binaries.mkdir(parents=True)
            log = home / "calls"
            # curl writes an inert placeholder. The fake sh probes the detached
            # session; it never executes an installer (saved or downloaded).
            (binaries / "curl").write_text(
                "#!/bin/sh\nprintf 'curl:%s\\n' \"$*\" >> \"$TEST_LOG\"\n"
                "while [ $# -gt 0 ]; do if [ \"$1\" = -o ]; then shift; printf inert > \"$1\"; fi; shift; done\n")
            (binaries / "sh").write_text(
                "#!/usr/bin/python3\nimport os\n"
                "try:\n    os.open('/dev/tty', os.O_RDWR)\n"
                "except OSError:\n    pass\n"
                "else:\n    raise SystemExit('controlling terminal leaked')\n"
                "assert os.getcwd() == os.environ['HOME']\n"
                "assert os.environ['PATH'].split(':')[0] == os.environ['HOME'] + '/.local/bin'\n"
                "assert os.environ['PI_CODING_AGENT_DIR'] == os.environ['HOME'] + '/.pi/agent'\n"
                "assert os.read(0, 1) == b''\n"
                "with open(os.environ['TEST_LOG'], 'a') as f: f.write('detached\\n')\n")
            (binaries / "pi").write_text("#!/bin/sh\nprintf 'pi:%s\\n' \"$*\" >> \"$TEST_LOG\"\n")
            for binary in binaries.iterdir():
                binary.chmod(0o755)
            environment = {**os.environ, "HOME": str(home), "TEST_LOG": str(log),
                           "PATH": f"{binaries}:/usr/bin:/bin"}
            argv = ["/bin/sh", str(ROOT / "assets/install-user.sh")]
            first = subprocess.run(argv, cwd=home, env=environment, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            code, output = terminal_run(["/bin/sh", "-c", 'cd "$HOME"; exec /bin/sh "$1"', "sh", argv[1]], environment)
            self.assertEqual(code, 0, output)
            calls = log.read_text().splitlines()
            self.assertEqual(calls.count("detached"), 2)
            self.assertEqual(calls.count("pi:install npm:pi-subagents@0.76.1"), 2)
            self.assertEqual(len([line for line in calls if line.startswith("pi:install npm:")]), 10)
            self.assertTrue(all("https://pi.dev/install.sh" in line for line in calls if line.startswith("curl:")))
            self.assertEqual(list((home / ".pi/agent").iterdir()), [])

    def test_readme_wall_uses_literal_boundary_and_dismiss_file(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            environment = {**os.environ, "HOME": str(home)}
            script = ROOT / "assets/config/readme-wall.sh"
            (home / "README.md").write_text("# Welcome\nintro\n## Still welcome\ntext\n<!-- END_OF_WALL_MESSAGE -->\n## Private detail\nnever shown\n")
            result = subprocess.check_output(["sh", str(script)], env=environment, text=True)
            self.assertEqual(result, "# Welcome\nintro\n## Still welcome\ntext\n")
            (home / ".readme-dismissed").touch()
            self.assertEqual(subprocess.check_output(["sh", str(script)], env=environment), b"")
            (home / ".readme-dismissed").unlink()
            (home / "README.md").write_text("# Unrelated README without sentinel\n")
            self.assertEqual(subprocess.check_output(["sh", str(script)], env=environment), b"")

    def test_bash_and_fish_only_greet_interactive_logins(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binaries = home / ".local/bin"
            binaries.mkdir(parents=True)
            shutil.copyfile(ROOT / "assets/config/readme-wall.sh", binaries / "pi-vm-readme")
            (binaries / "pi-vm-readme").chmod(0o755)
            (home / "README.md").write_text("# GREETING\n<!-- END_OF_WALL_MESSAGE -->\nsecret-detail\n")
            environment = {**os.environ, "HOME": str(home)}
            for shell, hook, options in (
                ("bash", "login.bash", ["--noprofile", "--norc"]),
                ("fish", "login.fish", ["--no-config"]),
            ):
                command = f'source "{ROOT / "assets/config" / hook}"'
                with self.subTest(shell=shell):
                    code, output = terminal_run([shell, *options, "-ilc", command], environment)
                    self.assertEqual(code, 0, output)
                    self.assertIn("GREETING", output)
                    self.assertNotIn("secret-detail", output)
                    for flags in ("-lc", "-ic"):
                        code, output = terminal_run([shell, *options, flags, command], environment)
                        self.assertEqual(code, 0, output)
                        self.assertNotIn("GREETING", output)
                    non_tty = subprocess.run([shell, *options, "-ilc", command], env=environment, capture_output=True, text=True)
                    self.assertNotIn("GREETING", non_tty.stdout)
                    code, output = terminal_run([shell, *options, "-ilc", command], {**environment, "SSH_ORIGINAL_COMMAND": "echo remote"})
                    self.assertEqual(code, 0, output)
                    self.assertNotIn("GREETING", output)
                    (home / ".readme-dismissed").touch()
                    code, output = terminal_run([shell, *options, "-ilc", command], environment)
                    self.assertEqual(code, 0, output)
                    self.assertNotIn("GREETING", output)
                    (home / ".readme-dismissed").unlink()

    def test_reboot_condition_requires_success_on_current_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            boot_id = root / "boot-id"
            boot_id.write_text("boot-one\n")
            environment = {**os.environ, "PI_VM_STATE": str(root), "PI_VM_BOOT_ID_FILE": str(boot_id)}
            condition = ["bash", str(ROOT / "assets/reboot-needed.sh")]
            self.assertNotEqual(subprocess.run(condition, env=environment).returncode, 0)
            (root / "bootstrap-complete").write_text("reboot_required=true\nboot_id=boot-one\n")
            self.assertEqual(subprocess.run(condition, env=environment).returncode, 0)
            (root / "bootstrap-failed").touch()
            self.assertNotEqual(subprocess.run(condition, env=environment).returncode, 0)
            (root / "bootstrap-failed").unlink()
            boot_id.write_text("boot-two\n")
            self.assertNotEqual(subprocess.run(condition, env=environment).returncode, 0)
            (root / "bootstrap-complete").write_text("reboot_required=false\nboot_id=boot-two\n")
            self.assertNotEqual(subprocess.run(condition, env=environment).returncode, 0)


if __name__ == "__main__":
    unittest.main()
