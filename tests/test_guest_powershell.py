#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "assets/install-powershell.sh"
MAKEFILE = ROOT / "assets/Makefile"


class PowerShellBootstrapTests(unittest.TestCase):
    def make_fixture(self, directory: Path, *, digest: str | None = "valid") -> tuple[dict[str, str], Path, Path]:
        fake_bin = directory / "bin"
        fake_bin.mkdir()
        cache = directory / "cache"
        cache.mkdir()
        rpm_content = b"official PowerShell RPM fixture\n"
        rpm_source = directory / "source.rpm"
        rpm_source.write_bytes(rpm_content)
        rpm_digest = hashlib.sha256(rpm_content).hexdigest()
        api_digest = f"sha256:{rpm_digest}" if digest == "valid" else (digest or "")
        api = {
            "tag_name": "v7.6.6",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": "powershell-7.6.6-1.cm.x86_64.rpm",
                    "browser_download_url": "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-1.cm.x86_64.rpm",
                },
                {
                    "name": "powershell-7.6.6-1.rh.x86_64.rpm",
                    "browser_download_url": "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-1.rh.x86_64.rpm",
                    "digest": api_digest,
                },
                {
                    "name": "hashes.sha256",
                    "browser_download_url": "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/hashes.sha256",
                },
            ],
        }
        api_file = directory / "api.json"
        api_file.write_text(json.dumps(api))
        log = directory / "commands.log"
        installed = directory / "installed"
        curl = fake_bin / "curl"
        curl.write_text(
            "#!/usr/bin/bash\n"
            "url=; output=\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  case $1 in\n"
            "    -o) shift; output=$1 ;;\n"
            "    https://api.github.com/*) url=$1 ;;\n"
            "    https://github.com/*) url=$1 ;;\n"
            "  esac\n"
            "  shift\n"
            "done\n"
            "printf 'curl %s\\n' \"$url\" >> \"$POWERSHELL_TEST_LOG\"\n"
            "case $url in\n"
            "  https://api.github.com/*) cp \"$POWERSHELL_TEST_API\" \"$output\" ;;\n"
            "  *powershell-7.6.6-1.rh.x86_64.rpm) cp \"$POWERSHELL_TEST_RPM\" \"$output\" ;;\n"
            "  *hashes.sha256) printf '%s  *powershell-7.6.6-1.rh.x86_64.rpm\\n' \"$POWERSHELL_TEST_DIGEST\" > \"$output\" ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n"
        )
        curl.chmod(0o755)
        rpm = fake_bin / "rpm"
        rpm.write_text(
            "#!/usr/bin/bash\n"
            "printf 'rpm %s\\n' \"$*\" >> \"$POWERSHELL_TEST_LOG\"\n"
            "if [[ $1 == -q ]]; then\n"
            "  [[ -e \"$POWERSHELL_TEST_INSTALLED\" ]] || exit 1\n"
            "  printf '7.6.6-1.rh.x86_64\\n'\n"
            "elif [[ $1 == -qp ]]; then\n"
            "  printf 'powershell 7.6.6 1.rh x86_64\\n'\n"
            "fi\n"
        )
        rpm.chmod(0o755)
        dnf = fake_bin / "dnf"
        dnf.write_text(
            "#!/usr/bin/bash\n"
            "printf 'dnf %s\\n' \"$*\" >> \"$POWERSHELL_TEST_LOG\"\n"
            "> \"$POWERSHELL_TEST_INSTALLED\"\n"
        )
        dnf.chmod(0o755)
        (fake_bin / "pwsh").write_text("#!/usr/bin/bash\nexit 0\n")
        (fake_bin / "pwsh").chmod(0o755)
        environment = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "CACHE": str(cache),
            "POWERSHELL_TEST_API": str(api_file),
            "POWERSHELL_TEST_RPM": str(rpm_source),
            "POWERSHELL_TEST_DIGEST": rpm_digest,
            "POWERSHELL_TEST_INSTALLED": str(installed),
            "POWERSHELL_TEST_LOG": str(log),
        }
        return environment, cache, log

    def run_script(self, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(SCRIPT)], env=environment, text=True, capture_output=True)

    def test_selects_rh_rpm_verifies_and_skips_exact_installed_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment, cache, log = self.make_fixture(Path(temporary))

            first = self.run_script(environment)
            self.assertEqual(first.returncode, 0, first.stderr)
            rpm = cache / "powershell-7.6.6-1.rh.x86_64.rpm"
            self.assertEqual(rpm.read_bytes(), b"official PowerShell RPM fixture\n")
            entries = log.read_text().splitlines()
            self.assertTrue(any(line.startswith(
                "dnf -y --setopt=localpkg_gpgcheck=0 --setopt=gpgcheck=1 install "
            ) for line in entries))
            self.assertNotIn("-1.cm.x86_64.rpm", "\n".join(entries))

            second = self.run_script(environment)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(sum(line.startswith("dnf ") for line in log.read_text().splitlines()), 1)
            self.assertIn("already installed", second.stdout)

    def test_checksum_failure_propagates_without_dnf_or_cached_rpm(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment, cache, log = self.make_fixture(Path(temporary), digest="sha256:" + "0" * 64)

            result = self.run_script(environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 verification failed", result.stderr)
            self.assertFalse(any(line.startswith("dnf ") for line in log.read_text().splitlines()))
            self.assertFalse((cache / "powershell-7.6.6-1.rh.x86_64.rpm").exists())

    def test_hashes_asset_fallback_maps_the_exact_rpm_basename(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment, cache, log = self.make_fixture(Path(temporary), digest=None)

            result = self.run_script(environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((cache / "powershell-7.6.6-1.rh.x86_64.rpm").is_file())
            self.assertTrue(any(line.endswith("/hashes.sha256") for line in log.read_text().splitlines()))

    def test_ambiguous_rpm_assets_fail_before_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment, cache, log = self.make_fixture(Path(temporary))
            api_file = Path(environment["POWERSHELL_TEST_API"])
            api = json.loads(api_file.read_text())
            api["assets"].append({
                "name": "powershell-7.6.6-1.rh.x86_64.rpm",
                "browser_download_url": "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/duplicate.rpm",
                "digest": "sha256:" + "0" * 64,
            })
            api_file.write_text(json.dumps(api))

            result = self.run_script(environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one official x86_64 RPM", result.stderr)
            self.assertFalse(any(".rpm" in line for line in log.read_text().splitlines()))
            self.assertFalse(any(cache.iterdir()))

    def test_make_graph_places_powershell_after_base_packages_and_before_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "stage"
            shutil.copytree(ROOT / "assets", stage)

            output = subprocess.run(
                ["make", "-n", "--no-print-directory", "-f", str(stage / "Makefile"), "bootstrap"],
                env={
                    **os.environ,
                    "STAGE": str(stage),
                    "CACHE": str(root / "cache"),
                    "VM_HOSTNAME": "offline-test",
                    "SSH_CONFIG": str(root / "etc" / "ssh"),
                    "SAMBA_CONFIG": str(root / "etc" / "samba" / "smb.conf"),
                    "AVAHI_SERVICES": str(root / "etc" / "avahi"),
                    "BOOTSTRAP_BIN": str(root / "usr" / "local" / "sbin" / "pi-vm-bootstrap"),
                },
                text=True,
                capture_output=True,
                check=True,
            ).stdout.splitlines()
            positions = {
                marker: next(i for i, line in enumerate(output) if marker in line)
                for marker in ("dnf -y install", "install-powershell.sh", "systemctl enable --now sshd")
            }
            self.assertLess(positions["dnf -y install"], positions["install-powershell.sh"])
            self.assertLess(positions["install-powershell.sh"], positions["systemctl enable --now sshd"])


if __name__ == "__main__":
    unittest.main()
