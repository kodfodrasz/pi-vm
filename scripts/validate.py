#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Check an existing KVM guest. Nested and balloon tests are explicit opt-ins."""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent

REMOTE = r'''
import json, os, pathlib, pwd, subprocess, time, uuid
success_marker = pathlib.Path('/var/lib/pi-vm/bootstrap-complete')
failure_marker = pathlib.Path('/var/lib/pi-vm/bootstrap-failed')
if failure_marker.exists():
    print(json.dumps({
        'ready': False,
        'bootstrap_failure': failure_marker.read_text().strip()
    }))
    raise SystemExit(0)
if not success_marker.is_file():
    print(json.dumps({'ready': False}))
    raise SystemExit(0)
bootstrap_recovered = 'recovered_from_failure=true' in success_marker.read_text()
def run(argv):
    p = subprocess.run(argv, text=True, capture_output=True, timeout=15,
                       env=dict(os.environ, PI_OFFLINE='1'))
    if p.returncode:
        raise RuntimeError('command failed: ' + argv[0] + ': ' + p.stderr.strip())
    return p.stdout.strip()
instance_id = run(['sudo', '-n', 'cat', '/var/lib/cloud/data/instance-id'])
if globals().get('EXPECTED_INSTANCE') is not None and instance_id != EXPECTED_INSTANCE:
    print(json.dumps({'ready': True, 'instance_id': instance_id}))
    raise SystemExit(0)
cloud = subprocess.run(['sudo', '-n', 'cloud-init', 'status', '--format', 'json'],
                       text=True, capture_output=True, timeout=15)
allowed_cloud_statuses = (0, 1, 2) if bootstrap_recovered else (0, 2)
if cloud.returncode not in allowed_cloud_statuses:
    raise RuntimeError('cloud-init status command failed')
status = json.loads(cloud.stdout)
# The bootstrap marker can precede cloud-final finishing by a short interval.
if status.get('status') == 'running' and status.get('errors') == []:
    print(json.dumps({'ready': False}))
    raise SystemExit(0)
completion = dict(line.split('=', 1) for line in success_marker.read_text().splitlines())
reboot_required = completion.get('reboot_required')
bootstrap_boot_id = completion.get('boot_id')
boot_id = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
if reboot_required not in ('true', 'false') or not bootstrap_boot_id or not boot_id:
    raise RuntimeError('bootstrap reboot metadata missing')
if reboot_required == 'true' and bootstrap_boot_id == boot_id:
    print(json.dumps({'ready': False}))
    raise SystemExit(0)
home = pathlib.Path.home()
run(['fish', '-n', str(home/'.config/fish/config.fish'),
     str(home/'.config/fish/completions/pi.fish')])
run(['vim', '-Nu', str(home/'.vimrc'), '-i', 'NONE', '-n', '-es', '+q'])
server = 'pi-vm-check-' + uuid.uuid4().hex[:12]
try:
    # tmux can exit successfully when startup config has errors. source-file
    # returns a failing exit code, so check the config explicitly.
    run(['tmux', '-L', server, '-f', '/dev/null', 'new-session', '-d', 'sleep 5'])
    run(['tmux', '-L', server, 'source-file', str(home/'.config/tmux/tmux.conf')])
finally:
    subprocess.run(['tmux', '-L', server, 'kill-server'], capture_output=True, timeout=10)
    deadline = time.monotonic() + 2
    while True:
        probe = subprocess.run(['tmux', '-L', server, 'show-options', '-s'],
                               text=True, capture_output=True, timeout=5)
        if probe.returncode == 1 and any(text in probe.stderr.lower()
                                        for text in ('no server running', 'no such file or directory')):
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('cannot confirm temporary tmux server cleanup: ' + probe.stderr.strip())
        time.sleep(.1)
fs = os.statvfs('/')
base_auth = dict(line.split(None, 1) for line in run(['sudo', '-n', 'sshd', '-T']).splitlines())
if base_auth.get('usedns') != 'no':
    raise RuntimeError('UseDNS is enabled; Match Host policy needs manual verification')
connection = os.environ.get('SSH_CONNECTION', '').split()
if len(connection) != 4:
    raise RuntimeError('SSH connection metadata missing')
peer, _, local, port = connection
criteria = f'user={pwd.getpwuid(os.getuid()).pw_name},addr={peer},host={peer},laddr={local},lport={port}'
sshd = dict(line.split(None, 1) for line in run(['sudo', '-n', 'sshd', '-T', '-C', criteria]).splitlines())
print(json.dumps({
    'ready': True, 'user': pwd.getpwuid(os.getuid()).pw_name,
    'shell': pwd.getpwuid(os.getuid()).pw_shell,
    'hostname': run(['hostname']), 'cloud': status,
    'instance_id': instance_id,
    'bootstrap_recovered': bootstrap_recovered,
    'reboot_required': reboot_required == 'true',
    'bootstrap_boot_id': bootstrap_boot_id, 'boot_id': boot_id,
    'root_bytes': fs.f_blocks * fs.f_frsize,
    'pi': run([str(home/'.local/bin/pi'), '--version']),
    'starship': run(['starship', '--version']).splitlines()[0],
    'rootless': run(['podman', 'info', '--format', '{{.Host.Security.Rootless}}']) == 'true',
    'selinux': run(['getenforce']), 'sshd': sshd,
    'balloon_driver': pathlib.Path('/sys/bus/virtio/drivers/virtio_balloon').is_dir(),
    'configs': True
}))
'''


class Failure(Exception):
    pass


def ssh(port, hosts, code, command='python3 -', timeout=45, username='pi'):
    argv = ['ssh', '-p', str(port), '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=5',
            '-o', 'UserKnownHostsFile=' + str(hosts), username + '@127.0.0.1', command]
    try:
        result = subprocess.run(argv, input=code, text=True, capture_output=True,
                                timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise Failure('SSH timed out') from exc
    error = result.stderr.lower()
    if result.returncode == 255 and any(text in error for text in ('host key verification failed',
                                      'remote host identification has changed',
                                      'permission denied', 'authentication failed')):
        raise Failure('SSH host-key or authentication failure; do not disable key checks')
    return result


def collect(port, hosts, wait_seconds, instance_id=None, username='pi'):
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        remaining = max(.1, deadline - time.monotonic())
        try:
            code = 'EXPECTED_INSTANCE = ' + json.dumps(instance_id) + '\n' + REMOTE
            result = ssh(port, hosts, code, timeout=min(45, remaining), username=username)
        except Failure as exc:
            if str(exc) != 'SSH timed out':
                raise
        else:
            if result.returncode == 0:
                try:
                    data = json.loads(result.stdout)
                except ValueError as exc:
                    raise Failure('guest returned malformed JSON') from exc
                if not isinstance(data, dict) or type(data.get('ready')) is not bool:
                    raise Failure('guest readiness metadata is missing or malformed')
                if data.get('bootstrap_failure'):
                    raise Failure('guest bootstrap failed: ' + str(data['bootstrap_failure']))
                if data['ready']:
                    return data
            elif result.returncode != 255:
                raise Failure('guest check failed: ' + result.stderr.strip())
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    raise Failure('bootstrap marker not ready before timeout')


def check_metadata(data, hostname, disk_bytes, instance_id='pipette', username='pi'):
    def require(condition, message):
        if not condition:
            raise Failure(message)

    require(data.get('ready') is True, 'bootstrap marker missing')
    require(data.get('user') == username, 'unexpected guest user')
    require(
        isinstance(data.get('shell'), str) and Path(data['shell']).name == 'fish',
        'pi login shell is not fish'
    )
    require(data.get('hostname') == hostname, 'guest hostname mismatch')
    require(
        data.get('instance_id') == instance_id,
        'guest instance ID mismatch (check SSH port)'
    )

    recovered = data.get('bootstrap_recovered')
    require(type(recovered) is bool, 'bootstrap recovery metadata missing')
    cloud = data.get('cloud')
    require(isinstance(cloud, dict), 'cloud-init status metadata missing')
    errors = cloud.get('errors')
    if recovered:
        require(cloud.get('status') in ('done', 'error'), 'cloud-init not finished')
        require(isinstance(errors, list), 'cloud-init errors metadata missing')
        for error in errors:
            require(
                isinstance(error, str)
                and 'scripts_user' in error
                and 'Runparts: 1 failures (runcmd)' in error,
                'unexpected recovered cloud-init error'
            )
    else:
        require(cloud.get('status') == 'done', 'cloud-init not done')
        require(errors == [], 'cloud-init errors are present or missing')

    warnings = cloud.get('recoverable_errors')
    require(isinstance(warnings, dict), 'cloud-init warning metadata missing')
    known_hostname_warning = f'Failed to set the hostname to {hostname} ({hostname})'
    for category, messages in warnings.items():
        require(
            category == 'WARNING' and isinstance(messages, list),
            'unexpected cloud-init warning category'
        )
        for message in messages:
            known_recovery_warning = (
                recovered
                and isinstance(message, str)
                and (
                    message == 'Failed to run module scripts_user '
                               '(scripts in /var/lib/cloud/instance/scripts)'
                    or (message.startswith('Running module scripts_user (')
                        and message.endswith(') failed'))
                )
            )
            require(
                message == known_hostname_warning or known_recovery_warning,
                'unexpected cloud-init warning'
            )

    require(isinstance(data.get('pi'), str) and re.fullmatch(
        r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?',
        data['pi']) is not None, 'Pi version is not a nonempty semantic version')
    require(type(data.get('reboot_required')) is bool, 'bootstrap reboot metadata missing')
    require(all(isinstance(data.get(key), str) and data[key]
                for key in ('boot_id', 'bootstrap_boot_id')), 'bootstrap boot IDs missing')
    require(not data['reboot_required'] or data['boot_id'] != data['bootstrap_boot_id'],
            'SELinux reboot has not completed')
    require(data.get('starship') == 'starship 1.26.0', 'Starship version is not 1.26.0')
    require(data.get('rootless') is True, 'Podman is not rootless')
    require(data.get('selinux') == 'Disabled', 'SELinux is not disabled')
    require(data.get('balloon_driver') is True, 'virtio balloon driver missing')
    require(data.get('configs') is True, 'editor or shell config check missing')

    sshd = data.get('sshd')
    require(
        isinstance(sshd, dict)
        and sshd.get('passwordauthentication') == 'no'
        and sshd.get('kbdinteractiveauthentication') == 'no',
        'SSH password authentication enabled or missing'
    )
    root_bytes = data.get('root_bytes')
    require(
        type(root_bytes) is int and type(disk_bytes) is int and disk_bytes > 0,
        'disk/root size metadata malformed'
    )
    require(
        root_bytes * 100 >= disk_bytes * 85,
        'root filesystem is under 85% of virtual disk size'
    )
    return warnings


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.stream = None
        try:
            self.sock.settimeout(10)
            self.sock.connect(str(path))
            self.stream = self.sock.makefile('rb')
            self.receive()
            self.command('qmp_capabilities')
        except Exception:
            if self.stream is not None:
                self.stream.close()
            self.sock.close()
            raise

    def receive(self):
        line = self.stream.readline()
        if not line:
            raise Failure('QMP connection closed')
        return json.loads(line)

    def command(self, name, arguments=None):
        request = {'execute': name}
        if arguments is not None:
            request['arguments'] = arguments
        deadline = time.monotonic() + 10
        self.sock.sendall((json.dumps(request) + '\n').encode())
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Failure('QMP command timed out')
            self.sock.settimeout(remaining)
            reply = self.receive()
            if 'error' in reply:
                raise Failure('QMP error: ' + str(reply['error']))
            if 'return' in reply:
                return reply['return']

    def close(self):
        try:
            self.stream.close()
        finally:
            self.sock.close()


def wait_balloon(qmp, expected, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if qmp.command('query-balloon')['actual'] == expected:
            return
        time.sleep(.5)
    raise Failure('balloon did not reach requested memory target')


def balloon_test(qmp):
    original = qmp.command('query-balloon')['actual']
    target = original - 256 * 1024 * 1024
    if target < 512 * 1024 * 1024:
        raise Failure('VM is too small for the balloon test')
    try:
        qmp.command('balloon', {'value': target})
        wait_balloon(qmp, target)
    finally:
        try:
            qmp.command('balloon', {'value': original})
            wait_balloon(qmp, original)
        except Exception as exc:
            raise Failure(f'Balloon restoration FAILED; restore {original} bytes manually') from exc
    return {'original_bytes': original, 'test_bytes': target, 'restored': True}


def validate(args):
    instance = args.build / args.instance
    env = dict(os.environ, PI_VM_BUILD=str(args.build))
    state = subprocess.run([sys.executable, str(ROOT/'scripts/kvm.py'), 'status', args.instance],
                           env=env, text=True, capture_output=True, timeout=10)
    if state.returncode:
        raise Failure('instance is not running: ' + state.stdout.strip())
    hosts = args.known_hosts or instance / 'known_hosts'
    hosts.parent.mkdir(parents=True, exist_ok=True)
    data = collect(args.ssh_port, hosts, args.wait_seconds, args.instance, args.username)
    if data.get('instance_id') != args.instance:
        raise Failure('guest instance ID mismatch (check SSH port)')
    image = subprocess.run(['qemu-img', 'info', '-U', '--output=json', str(instance/'disk.qcow2')],
                           text=True, capture_output=True, timeout=15)
    try:
        if image.returncode:
            raise ValueError(image.stderr)
        disk = json.loads(image.stdout)['virtual-size']
    except (ValueError, KeyError) as exc:
        raise Failure('cannot read virtual disk size') from exc
    warnings = check_metadata(data, args.hostname, disk, args.instance, args.username)
    report = {
        'instance': args.instance,
        'status': 'PASS',
        'disk_bytes': disk,
        'root_bytes': data['root_bytes'],
        'hostname': data['hostname'],
        'bootstrap_recovered': data['bootstrap_recovered'],
        'cloud_init_errors': data['cloud']['errors'],
        'cloud_init_warnings': warnings,
        'configs': True,
        'rootless': True,
    }
    if args.nested:
        code = """import pathlib
import subprocess
cpu_info = pathlib.Path('/proc/cpuinfo').read_text()
module = 'kvm_amd' if 'svm' in cpu_info else 'kvm_intel'
subprocess.run(['modprobe', module], check=True)
"""
        code += (ROOT/'tests/nested-kvm.py').read_text()
        result = ssh(args.ssh_port, hosts, code, command='sudo -n python3 -', timeout=30, username=args.username)
        if result.returncode or 'PASS: nested KVM executed an L2 halt instruction' not in result.stdout:
            raise Failure('nested KVM execution failed: ' + result.stderr.strip())
        report['nested_kvm'] = True
    if args.balloon:
        qmp = QMP(instance/'qmp.sock')
        try:
            report['balloon'] = balloon_test(qmp)
        finally:
            qmp.close()
    return report


def save_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        json.dump(report, output, indent=2)
        output.write('\n')
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance', required=True)
    parser.add_argument('--ssh-port', type=int, default=2222)
    parser.add_argument('--username', default=os.environ.get('PI_USER', 'pi'))
    parser.add_argument('--hostname', default='pipette')
    parser.add_argument('--known-hosts', type=Path)
    parser.add_argument('--wait-seconds', type=int, default=300)
    parser.add_argument('--build', type=Path, default=Path(os.environ.get('PI_VM_BUILD', ROOT/'build')))
    parser.add_argument('--report', type=Path)
    parser.add_argument('--nested', action='store_true')
    parser.add_argument('--balloon', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', args.username) or args.username == 'root':
        parser.error('invalid username')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}', args.instance):
        parser.error('invalid instance ID')
    if not 1024 <= args.ssh_port <= 65535 or not 1 <= args.wait_seconds <= 3600:
        parser.error('invalid SSH port or wait time')
    args.build = args.build.resolve()
    if args.report:
        args.report = args.report.resolve()
        if not args.report.is_relative_to((args.build/args.instance).resolve()) or args.report.suffix != '.json':
            parser.error('--report must be a .json file within this instance directory')
    try:
        report = validate(args)
    except (Failure, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
        report = {'instance': args.instance, 'status': 'FAIL', 'error': str(exc)}
    if args.report:
        save_report(args.report, report)
    print(json.dumps(report, indent=2))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
