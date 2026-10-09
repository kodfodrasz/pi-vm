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

# The ISO is a staging transport. Bootstrap copies the files that it needs to
# their real /etc locations after cloud-init has mounted the seed.
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
    "bootstrap.py": (ASSETS / "bootstrap.py", "0700", "root:root"),
}


def valid_name(value: str, pattern: str, label: str) -> str:
    if not re.fullmatch(pattern, value):
        raise ValueError(f"invalid {label}")
    return value


def normalized_asset(path: Path, binary: bool) -> bytes:
    if binary:
        return path.read_bytes()
    return path.read_text(encoding="utf-8-sig").encode("utf-8")


def collect_assets() -> list[tuple[str, Path, str, bytes]]:
    assets = [(name, path, mode, normalized_asset(path, False)) for name, (path, mode, _) in EMBED.items()]
    if LOCAL.is_dir():
        for source in sorted(LOCAL.rglob("*")):
            if source.is_symlink():
                raise ValueError(f"local payload must not contain symlinks: {source}")
            if not source.is_file():
                continue
            relative = source.relative_to(LOCAL).as_posix()
            mode = "0700" if relative == "bootstrap.py" else "0600"
            assets.append((f"local/{relative}", source, mode, normalized_asset(source, relative == "bootstrap.sh")))
    return assets


def render_seed(instance_id: str, hostname: str, output_dir: Path) -> None:
    valid_name(instance_id, r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", "instance id")
    valid_name(hostname, r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", "hostname")
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
    user_data = user_data.replace("__WRITE_FILES__", "\n".join(write_files))
    user_data = user_data.replace("__AUTHORIZED_KEYS__", "\n".join("      - " + json.dumps(key) for key in keys))
    meta_data = (ASSETS / "cloud-init/meta-data.in").read_text(encoding="utf-8-sig")
    meta_data = meta_data.replace("__INSTANCE_ID_YAML__", json.dumps(instance_id))
    meta_data = meta_data.replace("__HOSTNAME_YAML__", json.dumps(hostname))
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "user-data").write_text(user_data, encoding="utf-8", newline="\n")
    (output_dir / "meta-data").write_text(meta_data, encoding="utf-8", newline="\n")


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
            with output.open("xb") as destination:
                while True:
                    chunk = stream.Read(1024 * 1024)
                    if isinstance(chunk, tuple):
                        chunk = chunk[0]
                    if not chunk:
                        break
                    destination.write(bytes(chunk))
        finally:
            pythoncom.CoUninitialize()
        return
    subprocess.run(["xorriso", "-as", "mkisofs", "-volid", "CIDATA", "-joliet", "-rock",
                    "-o", str(output), str(files)], check=True)


def publish_iso(instance_id: str, hostname: str, output: Path) -> Path:
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"seed ISO exists; remove it explicitly: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".seed-{instance_id}.", dir=output.parent) as temporary:
        files = Path(temporary) / "files"
        render_seed(instance_id, hostname, files)
        partial = Path(temporary) / "seed.iso"
        build_iso(files, partial)
        if not partial.is_file() or partial.stat().st_size == 0:
            raise RuntimeError("ISO builder produced no image")
        # Link publication refuses replacement and is atomic on filesystems that
        # support hard links; Windows uses an atomic move with the same refusal.
        if os.name == "nt":
            if output.exists():
                raise FileExistsError(output)
            os.replace(partial, output)
        else:
            os.link(partial, output)
    return output


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("instance_id")
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
            render_seed(args.instance_id, args.hostname, args.render_only)
            print(args.render_only)
        else:
            print(publish_iso(args.instance_id, args.hostname, args.output))
    except (OSError, ValueError, RuntimeError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
