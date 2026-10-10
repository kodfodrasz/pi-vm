#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pywin32>=306; sys_platform == 'win32'",
# ]
# ///
"""Render and publish a Fedora NoCloud seed ISO without a shell wrapper."""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
LOCAL = ROOT / "local"

# The ISO is a staging transport. The Bash bootstrap copies the files that it
# needs to their real /etc locations after cloud-init has mounted the seed.
EMBED = {
    "authorized_keys": (ASSETS / "authorized_keys", "0600", "root:root"),
    "public-key-identities.txt": (ASSETS / "public-key-identities.txt", "0644", "root:root"),
    "config/vimrc": (ASSETS / "config/vimrc", "0644", "root:root"),
    "config/tmux.conf": (ASSETS / "config/tmux.conf", "0644", "root:root"),
    "config/starship.toml": (ASSETS / "config/starship.toml", "0644", "root:root"),
    "config/config.fish": (ASSETS / "config/config.fish", "0644", "root:root"),
    "config/pi.fish": (ASSETS / "config/pi.fish", "0644", "root:root"),
    "config/smb.conf": (ASSETS / "config/smb.conf", "0644", "root:root"),
    "config/firewall-sources.conf": (ASSETS / "config/firewall-sources.conf", "0644", "root:root"),
    "config/avahi-samba.service": (ASSETS / "config/avahi-samba.service", "0644", "root:root"),
    "pi/settings.json": (ASSETS / "pi/settings.json", "0600", "root:root"),
    "pi/AGENTS.md": (ASSETS / "pi/AGENTS.md", "0644", "root:root"),
    "skills/kodfodrasz/SKILL.md": (ASSETS / "skills/kodfodrasz/SKILL.md", "0644", "root:root"),
    "config/sshd.conf": (ASSETS / "config/sshd.conf", "0644", "root:root"),
    "config/sudoers": (ASSETS / "config/sudoers", "0440", "root:root"),
    "Makefile": (ASSETS / "Makefile", "0644", "root:root"),
    "user-context.sh": (ASSETS / "user-context.sh", "0644", "root:root"),
    "install-user.sh": (ASSETS / "install-user.sh", "0644", "root:root"),
    "write-user-readme.sh": (ASSETS / "write-user-readme.sh", "0644", "root:root"),
    "reboot-needed.sh": (ASSETS / "reboot-needed.sh", "0700", "root:root"),
    "config/readme-wall.sh": (ASSETS / "config/readme-wall.sh", "0644", "root:root"),
    "config/login.bash": (ASSETS / "config/login.bash", "0644", "root:root"),
    "config/login.fish": (ASSETS / "config/login.fish", "0644", "root:root"),
    "bootstrap.sh": (ASSETS / "bootstrap.sh", "0700", "root:root"),
}


def valid_name(value: str, pattern: str, label: str) -> str:
    if not re.fullmatch(pattern, value):
        raise ValueError(f"invalid {label}")
    return value


def normalized_asset(path: Path, binary: bool) -> bytes:
    if binary:
        return path.read_bytes()
    return path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")


def collect_assets() -> list[tuple[str, Path, str, bytes]]:
    assets = [(name, path, mode, normalized_asset(path, False)) for name, (path, mode, _) in EMBED.items()]
    if LOCAL.is_dir():
        for source in sorted(LOCAL.rglob("*")):
            if source.is_symlink():
                raise ValueError(f"local payload must not contain symlinks: {source}")
            if not source.is_file():
                continue
            relative = source.relative_to(LOCAL).as_posix()
            mode = "0700" if relative == "bootstrap.sh" else "0600"
            # Only the executable Bash payload is normalized. Other local
            # payloads, including a legacy bootstrap.py, remain byte-for-byte stable.
            assets.append((f"local/{relative}", source, mode,
                           normalized_asset(source, False) if relative == "bootstrap.sh" else source.read_bytes()))
    return assets


def render_seed(instance_id: str, hostname: str, output_dir: Path, username: str = "pi") -> None:
    valid_name(instance_id, r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", "instance id")
    valid_name(hostname, r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", "hostname")
    valid_name(username, r"[a-z_][a-z0-9_-]{0,31}", "username")
    if username == "root":
        raise ValueError("username must not be root")
    keys = [line for line in (ASSETS / "authorized_keys").read_text(encoding="utf-8-sig").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]
    if not keys:
        raise ValueError("authorized_keys must contain at least one public key")
    write_files: list[str] = []
    for name, source, mode, content in collect_assets():
        payload = base64.b64encode(content).decode("ascii")
        write_files.extend([
            f"  - path: {json.dumps('/opt/pi-vm/' + name)}",
            "    owner: root:root",
            f"    permissions: '{mode}'",
            "    encoding: b64",
            f"    content: {payload}",
        ])
    user_data = (ASSETS / "cloud-init/user-data.in").read_text(encoding="utf-8-sig")
    user_data = user_data.replace("__HOSTNAME_YAML__", json.dumps(hostname))
    user_data = user_data.replace("__HOSTNAME_SHELL__", hostname)
    user_data = user_data.replace("__USERNAME_YAML__", json.dumps(username))
    user_data = user_data.replace("__HOME_YAML__", json.dumps("/home/" + username))
    user_data = user_data.replace("__USERNAME_SHELL__", username)
    user_data = user_data.replace("__WRITE_FILES__", "\n".join(write_files))
    user_data = user_data.replace("__AUTHORIZED_KEYS__", "\n".join("      - " + json.dumps(key) for key in keys))
    meta_data = (ASSETS / "cloud-init/meta-data.in").read_text(encoding="utf-8-sig")
    meta_data = meta_data.replace("__INSTANCE_ID_YAML__", json.dumps(instance_id))
    meta_data = meta_data.replace("__HOSTNAME_YAML__", json.dumps(hostname))
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output_dir, 0o700)
    for name, content in (("user-data", user_data), ("meta-data", meta_data)):
        target = output_dir / name
        target.write_text(content, encoding="utf-8", newline="\n")
        os.chmod(target, 0o600)


def build_iso(files: Path, output: Path) -> None:
    if os.name == "nt":
        try:
            import pythoncom
            import win32com.client
        except ImportError as exc:
            raise RuntimeError("Windows seed creation needs uv's pywin32 dependency") from exc
        pythoncom.CoInitialize()
        try:
            image = win32com.client.Dispatch("IMAPI2FS.MsftFileSystemImage")
            image.ChooseImageDefaultsForMediaType(12)  # IMAPI_MEDIA_TYPE_DISK
            image.FileSystemsToCreate = 3  # ISO9660 | Joliet | UDF
            image.VolumeName = "cidata"
            image.Root.AddTree(str(files), False)
            stream = image.CreateResultImage().ImageStream
            stream = query_istream(stream, pythoncom.IID_IStream)
            write_istream(stream, output)
        finally:
            pythoncom.CoUninitialize()
        return
    subprocess.run(["xorriso", "-as", "mkisofs", "-volid", "CIDATA", "-joliet", "-rock",
                    "-o", str(output), str(files)], check=True)


def query_istream(stream, iid):
    return stream.QueryInterface(iid)


def write_istream(stream, output: Path) -> None:
    with output.open("xb") as destination:
        while True:
            chunk = stream.Read(1024 * 1024)
            if isinstance(chunk, tuple):
                chunk = chunk[0]
            if not chunk:
                break
            destination.write(bytes(chunk))
    if output.stat().st_size == 0:
        raise RuntimeError("IMAPI2FS produced an empty ISO")


def publish_iso(instance_id: str, hostname: str, output: Path, username: str = "pi") -> Path:
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"seed ISO exists; remove it explicitly: {output}")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=f".seed-{instance_id}.", dir=output.parent) as temporary:
        files = Path(temporary) / "files"
        render_seed(instance_id, hostname, files, username)
        partial = Path(temporary) / "seed.iso"
        build_iso(files, partial)
        if not partial.is_file() or partial.stat().st_size == 0:
            raise RuntimeError("ISO builder produced no image")
        # Restrict the staged inode before it becomes visible at its final
        # name. Hard-link publication is atomic and refuses a race-created
        # destination on NTFS and POSIX filesystems.
        os.chmod(partial, 0o600)
        os.link(partial, output)
        os.chmod(output, 0o600)
    return output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("instance_id")
    parser.add_argument("--username", default=os.environ.get("PI_USER", "pi"))
    parser.add_argument("--hostname", default="pipette")
    parser.add_argument("--output", type=Path, help="ISO destination")
    parser.add_argument("--render-only", type=Path, help="write NoCloud files instead of an ISO")
    args = parser.parse_args(argv)
    if not args.render_only and args.output is None:
        parser.error("--output is required unless --render-only is used")
    if args.render_only and args.output is not None:
        parser.error("--output and --render-only cannot be combined")
    try:
        if args.render_only:
            render_seed(args.instance_id, args.hostname, args.render_only, args.username)
            print(args.render_only)
        else:
            print(publish_iso(args.instance_id, args.hostname, args.output, args.username))
    except (OSError, ValueError, RuntimeError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
