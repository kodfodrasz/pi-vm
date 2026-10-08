#!/usr/bin/env python3
"""Check the seed renderer without downloading an image."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(['python3', str(root/'scripts/render-seed.py'), '--instance-id',
                    'render-test', '--output-dir', tmp], check=True)
    user = (Path(tmp)/'user-data').read_text()
    meta = (Path(tmp)/'meta-data').read_text()
    assert '__' not in user and '__' not in meta, 'Unexpanded template placeholder'
    expected = [k for k in (root/'assets/authorized_keys').read_text().splitlines()
                if k.strip() and not k.startswith('#')]
    assert expected
    for key in expected:
        assert '      - '+json.dumps(key) in user, 'Missing initial SSH key'
    assert 'preserve_hostname: true' in user
    assert 'resize_rootfs: true' in user
    payloads = [base64.b64decode(line.strip().split(': ', 1)[1])
                for line in user.splitlines() if line.strip().startswith('content: ')]
    assert (root/'assets/bootstrap.sh').read_bytes() in payloads
    subprocess.run(['bash', '-n', str(root/'assets/bootstrap.sh')], check=True)
    for bad in ['../escape', 'bad\nname', 'x/y']:
        result = subprocess.run(['python3', str(root/'scripts/render-seed.py'),
                                 '--instance-id', bad, '--output-dir', tmp],
                                capture_output=True)
        assert result.returncode != 0
print('Seed keys, embedded bootstrap, root growth and input checks passed')
