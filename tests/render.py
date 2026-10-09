#!/usr/bin/env python3
"""Check seed rendering without downloading an image."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RENDERER = ROOT / 'scripts/render-seed.py'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def authorized_keys():
    return [
        line for line in (ROOT / 'assets/authorized_keys').read_text().splitlines()
        if line.strip() and not line.lstrip().startswith('#')
    ]


def check_public_key_inventory(keys):
    fingerprints = []
    for key in keys:
        fields = key.split()
        require(len(fields) >= 2, 'Malformed authorized key')
        key_blob = base64.b64decode(fields[1], validate=True)
        digest = base64.b64encode(hashlib.sha256(key_blob).digest()).decode().rstrip('=')
        fingerprints.append('SHA256:' + digest)

    inventory = [
        line for line in (ROOT / 'assets/public-key-identities.txt').read_text().splitlines()
        if line.startswith('SHA256:')
    ]
    require(fingerprints == inventory, 'Public-key fingerprint inventory is stale')


def check_rendered_seed(directory):
    subprocess.run([
        'python3', str(RENDERER), '--instance-id', 'render-test',
        '--output-dir', str(directory)
    ], check=True)

    user_data = (directory / 'user-data').read_text()
    meta_data = (directory / 'meta-data').read_text()
    require('__' not in user_data and '__' not in meta_data,
            'Unexpanded template placeholder')

    keys = authorized_keys()
    require(keys, 'No authorized public keys')
    for key in keys:
        require('      - ' + json.dumps(key) in user_data,
                'Missing initial SSH key')
    check_public_key_inventory(keys)

    require('preserve_hostname: true' in user_data, 'Hostname policy missing')
    require('resize_rootfs: true' in user_data, 'Root resize policy missing')
    payloads = [
        base64.b64decode(line.strip().split(': ', 1)[1])
        for line in user_data.splitlines()
        if line.strip().startswith('content: ')
    ]
    required_assets = [
        ROOT / 'assets/bootstrap.sh',
        ROOT / 'assets/config/smb.conf',
        ROOT / 'assets/config/firewall-sources.conf',
        ROOT / 'assets/config/avahi-samba.service',
        ROOT / 'assets/pi/settings.json',
        ROOT / 'assets/pi/AGENTS.md',
        ROOT / 'assets/skills/kodfodrasz/SKILL.md',
    ]
    for asset in required_assets:
        require(asset.read_bytes() in payloads, f'{asset.name} was not embedded')
    subprocess.run(['bash', '-n', str(ROOT / 'assets/bootstrap.sh')], check=True)


def check_invalid_instance_ids(directory):
    for value in ['../escape', 'bad\nname', 'x/y']:
        result = subprocess.run([
            'python3', str(RENDERER), '--instance-id', value,
            '--output-dir', str(directory)
        ], capture_output=True)
        require(result.returncode != 0, f'Accepted invalid instance ID: {value!r}')


def check_windows_line_endings(directory):
    windows_root = directory / 'windows'
    (windows_root / 'scripts').mkdir(parents=True)
    shutil.copyfile(RENDERER, windows_root / 'scripts/render-seed.py')

    for asset in (ROOT / 'assets').rglob('*'):
        if not asset.is_file():
            continue
        target = windows_root / asset.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        text = asset.read_text(encoding='utf-8-sig').replace('\n', '\r\n')
        target.write_bytes(b'\xef\xbb\xbf' + text.encode())

    subprocess.run([
        'python3', str(windows_root / 'scripts/render-seed.py'),
        '--instance-id', 'render-test',
        '--output-dir', str(windows_root / 'seed')
    ], check=True)

    for name in ['user-data', 'meta-data']:
        actual = (windows_root / 'seed' / name).read_bytes()
        expected = (directory / name).read_bytes()
        require(actual == expected, 'Windows source normalization differs')
        require(b'\r' not in actual, 'Rendered seed contains carriage returns')
        require(not actual.startswith(b'\xef\xbb\xbf'), 'Rendered seed contains a BOM')


def check_local_payload(directory):
    local_root = directory / 'local-root'
    shutil.copytree(ROOT / 'assets', local_root / 'assets')
    (local_root / 'scripts').mkdir()
    shutil.copyfile(RENDERER, local_root / 'scripts/render-seed.py')
    (local_root / 'local').mkdir()
    bootstrap = b'#!/usr/bin/bash\necho local setup\n'
    windows_bootstrap = b'\xef\xbb\xbf#!/usr/bin/bash\r\necho local setup\r\n'
    private_data = b'private-config\x00binary\r\n'
    (local_root / 'local/bootstrap.sh').write_bytes(windows_bootstrap)
    (local_root / 'local/config.bin').write_bytes(private_data)

    output = local_root / 'seed'
    subprocess.run([
        'python3', str(local_root / 'scripts/render-seed.py'),
        '--instance-id', 'local-test', '--output-dir', str(output)
    ], check=True)
    user_data = (output / 'user-data').read_text()
    payloads = [
        base64.b64decode(line.strip().split(': ', 1)[1])
        for line in user_data.splitlines()
        if line.strip().startswith('content: ')
    ]
    require(bootstrap in payloads, 'Local bootstrap was not embedded')
    require(private_data in payloads, 'Binary local payload was not embedded')


def main():
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        check_rendered_seed(directory)
        check_invalid_instance_ids(directory)
        check_windows_line_endings(directory)
        check_local_payload(directory)
    print('Seed rendering checks passed')


if __name__ == '__main__':
    main()
