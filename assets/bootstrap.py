#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Install and configure the Pi guest from the files staged on its NoCloud ISO."""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

STAGE = Path("/opt/pi-vm")
CONFIG = Path("/etc/pi-vm")
STATE = Path("/var/lib/pi-vm")
STARSHIP_URL = "https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz"
STARSHIP_SHA256 = "b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3"


def run(argv: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=True, **kwargs)


def retry_script_bytes(content: bytes) -> bytes:
    return content.replace(b"#!/usr/bin/env -S uv run --script\n", b"#!/usr/bin/python3\n", 1)


def set_tree_owner(root: Path, user: str, group: str, owner=shutil.chown) -> None:
    if not root.exists() and not root.is_symlink():
        return
    if root.is_symlink():
        raise RuntimeError(f"refusing symlink ownership root: {root}")
    pending = [root]
    while pending:
        path = pending.pop()
        owner(path, user=user, group=group)
        if not path.is_dir():
            continue
        with os.scandir(path) as entries:
            for entry in entries:
                child = Path(entry.path)
                if entry.is_symlink():
                    # npm and the Pi launcher create executable links; never own their targets.
                    continue
                if entry.is_dir(follow_symlinks=False):
                    pending.append(child)
                else:
                    owner(child, user=user, group=group)


def atomic_bytes(path: Path, content: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as temporary:
        temporary.write(content)
        name = Path(temporary.name)
    os.chmod(name, mode)
    os.replace(name, path)


def copy_staged_assets() -> None:
    CONFIG.mkdir(parents=True, exist_ok=True)
    for source, destination, mode in (
        ("authorized_keys", "authorized_keys", 0o600),
        ("public-key-identities.txt", "public-key-identities.txt", 0o644),
        ("config/vimrc", "vimrc", 0o644),
        ("config/tmux.conf", "tmux.conf", 0o644),
        ("config/starship.toml", "starship.toml", 0o644),
        ("config/config.fish", "config.fish", 0o644),
        ("config/pi.fish", "pi.fish", 0o644),
        ("config/smb.conf", "smb.conf", 0o644),
        ("config/firewall-sources.conf", "firewall-sources.conf", 0o644),
        ("config/avahi-samba.service", "avahi-samba.service", 0o644),
        ("pi/settings.json", "pi-settings.json", 0o600),
        ("pi/AGENTS.md", "AGENTS.md", 0o644),
        ("skills/kodfodrasz/SKILL.md", "kodfodrasz/SKILL.md", 0o644),
    ):
        source_path = STAGE / source
        if not source_path.is_file():
            raise RuntimeError(f"staged asset is missing: {source_path}")
        content = source_path.read_bytes()
        destination_path = CONFIG / destination
        atomic_bytes(destination_path, content, mode)
        os.chown(destination_path, 0, 0)
    installed_bootstrap = Path("/usr/local/sbin/pi-vm-bootstrap")
    retry_script = retry_script_bytes((STAGE / "bootstrap.py").read_bytes())
    atomic_bytes(installed_bootstrap, retry_script, 0o755)
    os.chown(installed_bootstrap, 0, 0)
    local = STAGE / "local"
    if local.is_dir():
        target = CONFIG / "local"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(local, target, symlinks=False)
        for path in target.rglob("*"):
            if path.is_file():
                os.chmod(path, 0o700 if path.relative_to(target).as_posix() == "bootstrap.py" else 0o600)
                os.chown(path, 0, 0)


def install_guest_packages() -> None:
    run(["dnf", "-y", "install", "avahi", "cloud-utils-growpart", "curl", "fastfetch", "fd-find",
         "firewalld", "fish", "gcc", "gcc-c++", "git", "hyperv-daemons", "jq", "make", "micro",
         "nodejs", "npm", "podman", "python3", "ripgrep", "rsync", "samba", "samba-client",
         "tmux", "unzip", "vim-enhanced", "wsdd"])


def remove_azure_guest_tools() -> None:
    installed = [package for package in ("azure-vm-utils", "WALinuxAgent", "WALinuxAgent-udev")
                 if subprocess.run(["rpm", "-q", package], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0]
    if installed:
        subprocess.run(["systemctl", "disable", "--now", "waagent.service"], check=False)
        run(["dnf", "-y", "remove", *installed])
    for path in ("/etc/waagent.conf", "/var/lib/waagent", "/var/log/waagent.log"):
        candidate = Path(path)
        if candidate.is_dir() and not candidate.is_symlink():
            shutil.rmtree(candidate)
        else:
            candidate.unlink(missing_ok=True)


def install_starship() -> None:
    cache = Path("/var/cache/pi-vm")
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "starship.tar.gz"
    with urllib.request.urlopen(STARSHIP_URL, timeout=60) as source, archive.open("wb") as destination:
        shutil.copyfileobj(source, destination, 1024 * 1024)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != STARSHIP_SHA256:
        archive.unlink(missing_ok=True)
        raise RuntimeError("Starship SHA-256 mismatch")
    with tarfile.open(archive, "r:gz") as bundle:
        member = bundle.getmember("starship")
        if not member.isfile():
            raise RuntimeError("Starship archive has no regular starship file")
        extracted = bundle.extractfile(member)
        assert extracted is not None
        atomic_bytes(Path("/usr/local/bin/starship"), extracted.read(), 0o755)


def configure_ssh() -> None:
    target = Path("/etc/ssh/sshd_config.d/10-pi-vm.conf")
    atomic_bytes(target, b"PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n")
    run(["systemctl", "enable", "--now", "sshd"])


def configure_pi_user(hostname: str) -> None:
    if subprocess.run(["id", "pi"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        run(["useradd", "--create-home", "--shell", "/bin/bash", "--groups", "wheel", "pi"])
    run(["usermod", "--lock", "pi"])
    ssh = Path("/home/pi/.ssh")
    ssh.mkdir(parents=True, exist_ok=True)
    os.chmod(ssh, 0o700)
    shutil.copyfile(CONFIG / "authorized_keys", ssh / "authorized_keys")
    os.chmod(ssh / "authorized_keys", 0o600)
    for path in (ssh, ssh / "authorized_keys"):
        shutil.chown(path, "pi", "pi")
    deploy_key = ssh / "pi-vm-deploy"
    if not deploy_key.exists():
        run(["runuser", "-u", "pi", "--", "ssh-keygen", "-q", "-t", "ed25519", "-N", "",
             "-C", f"pi-vm-deploy@{hostname}", "-f", str(deploy_key)])
    atomic_bytes(Path("/etc/sudoers.d/90-pi-vm"), b"pi ALL=(ALL) NOPASSWD: ALL\n", 0o440)
    run(["visudo", "-cf", "/etc/sudoers.d/90-pi-vm"])
    configs = (("vimrc", "/home/pi/.vimrc"), ("tmux.conf", "/home/pi/.config/tmux/tmux.conf"),
               ("starship.toml", "/home/pi/.config/starship.toml"), ("config.fish", "/home/pi/.config/fish/config.fish"),
               ("pi.fish", "/home/pi/.config/fish/completions/pi.fish"))
    for source, destination in configs:
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CONFIG / source, target)
        shutil.chown(target, user="pi", group="pi")
    for source, destination, mode in (("pi-settings.json", "/home/pi/.pi/agent/settings.json", 0o600),
                                      ("AGENTS.md", "/home/pi/.pi/agent/AGENTS.md", 0o644),
                                      ("kodfodrasz/SKILL.md", "/home/pi/.pi/agent/skills/kodfodrasz/SKILL.md", 0o644)):
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CONFIG / source, target)
        os.chmod(target, mode)
        shutil.chown(target, user="pi", group="pi")
    for directory in (Path("/home/pi/.config"), Path("/home/pi/.pi"), Path("/home/pi/.local")):
        set_tree_owner(directory, "pi", "pi")
    pi_local = Path("/home/pi/.local")
    pi_local.mkdir(parents=True, exist_ok=True)
    set_tree_owner(pi_local, "pi", "pi")
    run(["runuser", "-u", "pi", "--", "env", "HOME=/home/pi", "npm", "install", "--global", "--prefix", "/home/pi/.local/share/pi-npm", "@earendil-works/pi-coding-agent@1.1.0"])
    set_tree_owner(Path("/home/pi/.local"), "pi", "pi")
    local_bin = Path("/home/pi/.local/bin")
    local_bin.mkdir(parents=True, exist_ok=True)
    shutil.chown(local_bin, user="pi", group="pi")
    link = local_bin / "pi"
    link.unlink(missing_ok=True)
    link.symlink_to("/home/pi/.local/share/pi-npm/bin/pi")
    for package in ("pi-web-access@0.37.0", "pi-subagents@0.76.1", "pi-reset-usage-limit@0.1.1", "@wayner6/pi-usage@0.3.0", "pi-keep-going@1.1.0"):
        run(["runuser", "-u", "pi", "--", "/home/pi/.local/bin/pi", "install", "npm:" + package])
    if not any(line.startswith("pi:") for line in Path("/etc/subuid").read_text().splitlines()):
        run(["usermod", "--add-subuids", "100000-165535", "pi"])
    if not any(line.startswith("pi:") for line in Path("/etc/subgid").read_text().splitlines()):
        run(["usermod", "--add-subgids", "100000-165535", "pi"])
    run(["loginctl", "enable-linger", "pi"])
    fish = next((line.strip() for line in Path("/etc/shells").read_text().splitlines() if line.strip().endswith("/fish")), None)
    if not fish:
        raise RuntimeError("fish is not registered in /etc/shells")
    run(["chsh", "-s", fish, "pi"])


def install_default_configs() -> None:
    for source, destination in (("vimrc", "/etc/skel/.vimrc"), ("tmux.conf", "/etc/skel/.config/tmux/tmux.conf"),
                                ("starship.toml", "/etc/skel/.config/starship.toml"), ("config.fish", "/etc/skel/.config/fish/config.fish"),
                                ("pi.fish", "/etc/skel/.config/fish/completions/pi.fish")):
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CONFIG / source, target)


def firewall_sources() -> tuple[str, str]:
    values = {}
    for line in (CONFIG / "firewall-sources.conf").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values["HOME_LAN_CIDR"], values["VPN_CIDR"]


def configure_file_sharing() -> None:
    shutil.copyfile(CONFIG / "smb.conf", "/etc/samba/smb.conf")
    shutil.copyfile(CONFIG / "avahi-samba.service", "/etc/avahi/services/samba.service")
    run(["testparm", "-s"], stdout=subprocess.DEVNULL)
    run(["setsebool", "-P", "samba_enable_home_dirs", "on"])
    lan, vpn = firewall_sources()
    run(["systemctl", "enable", "--now", "firewalld"])
    run(["firewall-cmd", "--set-default-zone=public"])
    for service in ("ssh", "mdns", "wsdd", "wsdd-http"):
        run(["firewall-cmd", "--permanent", "--zone=public", "--add-service=" + service])
    for source in (lan, vpn):
        run(["firewall-cmd", "--permanent", "--zone=trusted", "--add-source=" + source])
    run(["firewall-cmd", "--reload"])
    password_file = STATE / "samba-initial-password"
    if subprocess.run(["pdbedit", "-L", "-u", "pi"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        password_file.parent.mkdir(parents=True, exist_ok=True)
        if not password_file.exists() or not password_file.read_text().strip():
            atomic_bytes(password_file, (secrets.token_urlsafe(18) + "\n").encode(), 0o600)
        password = password_file.read_text().strip()
        run(["smbpasswd", "-a", "-s", "pi"], input=(password + "\n" + password + "\n").encode())
    run(["systemctl", "enable", "--now", "smb", "nmb", "wsdd", "avahi-daemon"])
    if password_file.exists():
        print("Samba initial login: user pi; change it with sudo smbpasswd pi and remove /var/lib/pi-vm/samba-initial-password")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", default=os.environ.get("VM_HOSTNAME", "pipette"))
    args = parser.parse_args(argv)
    hostname = args.hostname
    failure = STATE / "bootstrap-failed"
    success = STATE / "bootstrap-complete"
    recovered = failure.exists() or (success.exists() and "recovered_from_failure=true" in success.read_text())
    STATE.mkdir(parents=True, exist_ok=True)
    failure.unlink(missing_ok=True)
    success.unlink(missing_ok=True)
    try:
        run(["hostnamectl", "set-hostname", hostname])
        copy_staged_assets()
        install_guest_packages()
        remove_azure_guest_tools()
        install_starship()
        configure_ssh()
        install_default_configs()
        configure_pi_user(hostname)
        configure_file_sharing()
        print("Private-repository deploy public key:")
        print(Path("/home/pi/.ssh/pi-vm-deploy.pub").read_text(), end="")
        local = CONFIG / "local" / "bootstrap.py"
        if local.is_file():
            run(["runuser", "-u", "root", "--", "python3", str(local)], env={**os.environ, "PI_VM_LOCAL_DIR": str(CONFIG / "local")})
        atomic_bytes(success, f"hostname={hostname}\nrecovered_from_failure={str(bool(recovered)).lower()}\n".encode())
    except Exception as exc:
        atomic_bytes(failure, f"status=1\nerror={exc}\n".encode())
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
