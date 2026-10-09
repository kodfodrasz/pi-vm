#!/usr/bin/env python3
"""Render cloud-init NoCloud seed files with embedded guest assets."""
import argparse
import base64
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
EMBED = {
    "/etc/pi-vm/authorized_keys": (ASSETS / "authorized_keys", "0600", "root:root"),
    "/etc/pi-vm/public-key-identities.txt": (ASSETS / "public-key-identities.txt", "0644", "root:root"),
    "/etc/pi-vm/vimrc": (ASSETS / "config/vimrc", "0644", "root:root"),
    "/etc/pi-vm/tmux.conf": (ASSETS / "config/tmux.conf", "0644", "root:root"),
    "/etc/pi-vm/starship.toml": (ASSETS / "config/starship.toml", "0644", "root:root"),
    "/etc/pi-vm/config.fish": (ASSETS / "config/config.fish", "0644", "root:root"),
    "/etc/pi-vm/pi.fish": (ASSETS / "config/pi.fish", "0644", "root:root"),
    "/usr/local/sbin/pi-vm-bootstrap": (ASSETS / "bootstrap.sh", "0755", "root:root"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", default="pipette")
    parser.add_argument("--instance-id", required=True, help="unique NoCloud instance id")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,62}", args.hostname):
        parser.error("hostname must be 1-63 DNS-label characters")
    instance_id = args.instance_id
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", instance_id):
        parser.error("instance-id must contain 1-128 safe ASCII characters")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_files = []
    for dest, (source, permissions, owner) in EMBED.items():
        if not source.is_file():
            parser.error(f"missing asset: {source}")
        # All embedded assets are UTF-8 text. Normalize Windows CRLF and BOMs
        # before encoding: Linux shebangs must not end with a carriage return.
        content = source.read_text(encoding="utf-8-sig").encode("utf-8")
        payload = base64.b64encode(content).decode("ascii")
        write_files.extend([
            f"  - path: {json.dumps(dest)}",
            f"    owner: {owner}",
            f"    permissions: '{permissions}'",
            "    encoding: b64",
            f"    content: {payload}",
        ])
    user_data = (ASSETS / "cloud-init/user-data.in").read_text(encoding="utf-8-sig")
    user_data = user_data.replace("__HOSTNAME_YAML__", json.dumps(args.hostname))
    user_data = user_data.replace("__HOSTNAME_SHELL__", args.hostname)
    user_data = user_data.replace("__WRITE_FILES__", "\n".join(write_files))
    keys = [line for line in (ASSETS / "authorized_keys").read_text(encoding="utf-8-sig").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]
    if not keys:
        parser.error("authorized_keys must contain at least one public key")
    user_data = user_data.replace("__AUTHORIZED_KEYS__", "\n".join(
        "      - " + json.dumps(key) for key in keys))
    meta_data = (ASSETS / "cloud-init/meta-data.in").read_text(encoding="utf-8-sig")
    meta_data = meta_data.replace("__INSTANCE_ID_YAML__", json.dumps(instance_id))
    meta_data = meta_data.replace("__HOSTNAME_YAML__", json.dumps(args.hostname))
    (args.output_dir / "user-data").write_bytes(user_data.encode("utf-8"))
    (args.output_dir / "meta-data").write_bytes(meta_data.encode("utf-8"))


if __name__ == "__main__":
    main()
