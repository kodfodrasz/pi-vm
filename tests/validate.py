#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import os
import pwd
import subprocess
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('validator', Path(__file__).parents[1]/'scripts/build/validate.py')
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def good():
    return {'ready': True, 'user': 'pi', 'shell': '/bin/fish', 'hostname': 'pipette',
            'instance_id': 'pipette', 'bootstrap_recovered': False,
            'cloud': {'status': 'done', 'errors': [], 'recoverable_errors': {}},
            'pi': '1.1.0', 'starship': 'starship 1.26.0', 'rootless': True,
            'reboot_required': True, 'boot_id': 'new-boot', 'bootstrap_boot_id': 'old-boot',
            'selinux': 'Disabled', 'balloon_driver': True, 'configs': True,
            'sshd': {'passwordauthentication': 'no', 'kbdinteractiveauthentication': 'no'},
            'root_bytes': 8*1024**3}


class ValidatorTests(unittest.TestCase):
    def test_good_metadata(self):
        self.assertEqual(v.check_metadata(good(), 'pipette', 8*1024**3), {})

    def test_latest_semver_core_and_configured_user(self):
        for version in ("1.1.0", "11.2.3", "2.0.0-rc.1", "2.3.4+build.5"):
            data = good()
            data.update(pi=version, user="developer")
            with self.subTest(version=version):
                self.assertEqual(v.check_metadata(data, 'pipette', 8*1024**3,
                                                  username="developer"), {})
        for version in ("", "latest", "1.2", "v1.2.3", "1.2.3\nnoise", "01.2.3"):
            data = good()
            data['pi'] = version
            with self.subTest(version=version), self.assertRaises(v.Failure):
                v.check_metadata(data, 'pipette', 8*1024**3)

    def test_required_reboot_cannot_false_pass_on_initial_boot(self):
        data = good()
        data['boot_id'] = data['bootstrap_boot_id']
        with self.assertRaisesRegex(v.Failure, 'reboot has not completed'):
            v.check_metadata(data, 'pipette', 8*1024**3)
        data['reboot_required'] = False
        self.assertEqual(v.check_metadata(data, 'pipette', 8*1024**3), {})
        data['selinux'] = 'Enforcing'
        with self.assertRaisesRegex(v.Failure, 'SELinux is not disabled'):
            v.check_metadata(data, 'pipette', 8*1024**3)

    def test_remote_waits_for_required_reboot_before_config_probes(self):
        marker = 'recovered_from_failure=false\nreboot_required=true\nboot_id=boot-one'
        def read_text(path, *args, **kwargs):
            return 'boot-one' if str(path) == '/proc/sys/kernel/random/boot_id' else marker
        replies = [subprocess.CompletedProcess([], 0, 'pipette', ''),
                   subprocess.CompletedProcess([], 0, json.dumps(good()['cloud']), '')]
        output = io.StringIO()
        with patch.object(v.subprocess, 'run', side_effect=replies) as run, \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'read_text', read_text), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit):
                exec(v.REMOTE, {'EXPECTED_INSTANCE': 'pipette'})
        self.assertEqual(json.loads(output.getvalue()), {'ready': False})
        self.assertEqual(run.call_count, 2)

    def test_missing_fields_fail_closed(self):
        for key in good():
            data = good()
            del data[key]
            with self.subTest(key=key), self.assertRaises(v.Failure):
                v.check_metadata(data, 'pipette', 8*1024**3)

    def test_bad_metadata(self):
        for key, value in [('ready', False), ('user', 'root'), ('shell', None),
                           ('hostname', 'other'), ('instance_id', 'other'), ('pi', ''),
                           ('starship', 'starship 1.26.01'), ('rootless', False),
                           ('rootless', 'true'), ('configs', False),
                           ('selinux', 'Permissive'), ('balloon_driver', False),
                           ('root_bytes', 1), ('root_bytes', '99999999999')]:
            data = good()
            data[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(v.Failure):
                v.check_metadata(data, 'pipette', 8*1024**3)

    def test_cloud_errors_and_unknown_warnings_rejected(self):
        clouds = [{'status': 'running', 'errors': [], 'recoverable_errors': {}},
                  {'status': 'done', 'errors': ['failure'], 'recoverable_errors': {}},
                  {'status': 'done', 'errors': [], 'recoverable_errors': {'WARNING': ['network failed']}},
                  {'status': 'done', 'errors': [], 'recoverable_errors': None},
                  {'status': 'done', 'errors': [], 'recoverable_errors': {
                      'WARNING': [
                          'Failed to set the hostname to pipette (pipette); package setup failed'
                      ]
                  }}]
        for cloud in clouds:
            data = good()
            data['cloud'] = cloud
            with self.subTest(cloud=cloud), self.assertRaises(v.Failure):
                v.check_metadata(data, 'pipette', 8*1024**3)

    def test_known_initial_hostname_warning_is_reported(self):
        data = good()
        warnings = {'WARNING': ['Failed to set the hostname to pipette (pipette)']}
        data['cloud']['recoverable_errors'] = warnings
        self.assertEqual(v.check_metadata(data, 'pipette', 8*1024**3), warnings)

    def test_recovered_bootstrap_history_is_reported(self):
        data = good()
        data['bootstrap_recovered'] = True
        data['cloud'] = {
            'status': 'error',
            'errors': [
                "('scripts_user', RuntimeError('Runparts: 1 failures (runcmd)'))"
            ],
            'recoverable_errors': {
                'WARNING': [
                    'Failed to run module scripts_user '
                    '(scripts in /var/lib/cloud/instance/scripts)',
                    "Running module scripts_user (<module 'cloudinit.config.cc_scripts_user'>) failed",
                ]
            },
        }
        self.assertEqual(
            v.check_metadata(data, 'pipette', 8*1024**3),
            data['cloud']['recoverable_errors'],
        )

    def test_recovery_rejects_unrelated_cloud_history(self):
        bad_clouds = [
            {'status': 'error', 'errors': ['network failed'], 'recoverable_errors': {}},
            {'status': 'error', 'errors': [],
             'recoverable_errors': {'WARNING': ['network failed']}},
        ]
        for cloud in bad_clouds:
            data = good()
            data['bootstrap_recovered'] = True
            data['cloud'] = cloud
            with self.subTest(cloud=cloud), self.assertRaises(v.Failure):
                v.check_metadata(data, 'pipette', 8*1024**3)

    def test_password_or_missing_auth_rejected(self):
        for key in good()['sshd']:
            for value in ['yes', None]:
                data = good()
                data['sshd'][key] = value
                with self.subTest(key=key, value=value), self.assertRaises(v.Failure):
                    v.check_metadata(data, 'pipette', 8*1024**3)

    def test_ssh_timeout_and_hostkey_error(self):
        with patch.object(v.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ssh', 1)):
            with self.assertRaisesRegex(v.Failure, 'timed out'):
                v.ssh(2222, Path('known'), 'code', timeout=1)
        for error in ['Host key verification failed', 'Permission denied (publickey)']:
            with patch.object(v.subprocess, 'run', return_value=subprocess.CompletedProcess([], 255, '', error)):
                with self.assertRaisesRegex(v.Failure, 'host-key or authentication'):
                    v.ssh(2222, Path('known'), 'code')

        # A guest file permission error is not an SSH authentication error.
        denied = subprocess.CompletedProcess([], 1, '', 'Permission denied reading config')
        with patch.object(v.subprocess, 'run', return_value=denied):
            self.assertIs(v.ssh(2222, Path('known'), 'code'), denied)

    def test_wrong_or_malformed_guest_json(self):
        for output in ['not-json', '[]', '{}', '{"ready":"true"}']:
            with patch.object(v, 'ssh', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.subTest(output=output), self.assertRaises(v.Failure):
                    v.collect(2222, Path('known'), 1)

    def test_bootstrap_failure_is_reported_immediately(self):
        reply = subprocess.CompletedProcess(
            [], 0, '{"ready":false,"bootstrap_failure":"line=42\\nstatus=1"}', '')
        with patch.object(v, 'ssh', return_value=reply), patch.object(v.time, 'sleep') as sleep:
            with self.assertRaisesRegex(v.Failure, 'guest bootstrap failed.*line=42'):
                v.collect(2222, Path('known'), 10)
        sleep.assert_not_called()

    def test_marker_wait_then_success(self):
        replies = [subprocess.CompletedProcess([], 0, '{"ready":false}', ''),
                   subprocess.CompletedProcess([], 0, json.dumps(good()), '')]
        with patch.object(v, 'ssh', side_effect=replies), patch.object(v.time, 'sleep'):
            self.assertEqual(v.collect(2222, Path('known'), 2)['hostname'], 'pipette')

    def test_marker_wait_is_bounded(self):
        with patch.object(v, 'ssh', return_value=subprocess.CompletedProcess([], 0, '{"ready":false}', '')), \
             patch.object(v.time, 'monotonic', side_effect=[0, 0, 0, .5, 2]), patch.object(v.time, 'sleep'):
            with self.assertRaisesRegex(v.Failure, 'not ready before timeout'):
                v.collect(2222, Path('known'), 1)

    def test_guest_check_error_does_not_wait(self):
        with patch.object(v, 'ssh', return_value=subprocess.CompletedProcess([], 1, '', 'config failed')):
            with self.assertRaisesRegex(v.Failure, 'guest check failed'):
                v.collect(2222, Path('known'), 1)

    def test_wrong_instance_stops_before_config_probes(self):
        output = io.StringIO()
        with patch.object(v.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'other-vm', '')) as run, \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'read_text', return_value='recovered_from_failure=false\nreboot_required=false\nboot_id=old-boot'), \
             contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit):
                exec(v.REMOTE, {'EXPECTED_INSTANCE': 'pipette'})
        self.assertEqual(json.loads(output.getvalue()), {'ready': True, 'instance_id': 'other-vm'})
        self.assertEqual(run.call_count, 1)
        self.assertIn('/var/lib/cloud/data/instance-id', run.call_args.args[0])

    def test_marker_before_cloud_final_done_keeps_waiting(self):
        status = {'status': 'running', 'errors': [], 'recoverable_errors': {}}
        output = io.StringIO()
        with patch.object(v.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(status), '')), \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'read_text', return_value='recovered_from_failure=false\nreboot_required=false\nboot_id=old-boot'), \
             contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as result:
                exec(v.REMOTE, {})
        self.assertEqual(result.exception.code, 0)
        self.assertEqual(json.loads(output.getvalue()), {'ready': False})

    def test_recovered_cloud_status_exit_one_is_collected(self):
        status = {'status': 'running', 'errors': [], 'recoverable_errors': {}}
        replies = [
            subprocess.CompletedProcess([], 0, 'pipette', ''),
            subprocess.CompletedProcess([], 1, json.dumps(status), ''),
        ]
        output = io.StringIO()
        with patch.object(v.subprocess, 'run', side_effect=replies), \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'read_text', return_value='recovered_from_failure=true\nreboot_required=false\nboot_id=old-boot'), \
             contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as result:
                exec(v.REMOTE, {})
        self.assertEqual(result.exception.code, 0)
        self.assertEqual(json.loads(output.getvalue()), {'ready': False})

    def test_bad_tmux_config_fails_and_server_is_cleaned_up(self):
        def remote_command(argv, **kwargs):
            if 'source-file' in argv:
                return subprocess.CompletedProcess(argv, 1, '', 'unknown command')
            if 'show-options' in argv:
                return subprocess.CompletedProcess(argv, 1, '', 'no server running')
            output = json.dumps(good()['cloud']) if 'cloud-init' in argv else ''
            return subprocess.CompletedProcess(argv, 0, output, '')
        with patch.object(v.subprocess, 'run', side_effect=remote_command) as run, \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'read_text', return_value='recovered_from_failure=false\nreboot_required=false\nboot_id=old-boot'):
            with self.assertRaisesRegex(RuntimeError, 'unknown command'):
                exec(v.REMOTE, {})
        self.assertTrue(any('kill-server' in call.args[0] for call in run.call_args_list))

    def test_tmux_cleanup_must_be_confirmed(self):
        for code, error in [(0, ''), (1, 'permission denied')]:
            def remote_command(argv, **kwargs):
                if 'show-options' in argv:
                    return subprocess.CompletedProcess(argv, code, '', error)
                output = json.dumps(good()['cloud']) if 'cloud-init' in argv else ''
                return subprocess.CompletedProcess(argv, 0, output, '')
            with patch.object(v.subprocess, 'run', side_effect=remote_command), \
                 patch.object(Path, 'is_file', return_value=True), \
                 patch.object(Path, 'read_text', return_value='recovered_from_failure=false\nreboot_required=false\nboot_id=old-boot'):
                with self.subTest(code=code), self.assertRaisesRegex(RuntimeError, 'temporary tmux'):
                    exec(v.REMOTE, {})

    def test_ssh_match_policy_is_evaluated_for_real_connection(self):
        def remote_command(argv, **kwargs):
            output = ''
            if 'show-options' in argv:
                return subprocess.CompletedProcess(argv, 1, '', 'no server running')
            if 'cloud-init' in argv:
                output = json.dumps(good()['cloud'])
            elif 'sshd' in argv:
                enabled = 'yes' if '-C' in argv else 'no'
                output = f'usedns no\npasswordauthentication {enabled}\nkbdinteractiveauthentication no'
            elif 'cat' in argv or argv[0] == 'hostname':
                output = 'pipette'
            elif str(argv[0]).endswith('/pi'):
                output = '1.1.0'
            elif argv[0] == 'starship':
                output = 'starship 1.26.0'
            elif argv[0] == 'podman':
                output = 'true'
            elif argv[0] == 'getenforce':
                output = 'Disabled'
            return subprocess.CompletedProcess(argv, 0, output, '')
        output = io.StringIO()
        with patch.object(v.subprocess, 'run', side_effect=remote_command) as run, \
             patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'is_dir', return_value=True), \
             patch.object(Path, 'read_text', return_value='recovered_from_failure=false\nreboot_required=false\nboot_id=old-boot'), \
             patch.dict(os.environ, {'SSH_CONNECTION': '10.0.2.2 49152 10.0.2.15 22'}), \
             contextlib.redirect_stdout(output):
            exec(v.REMOTE, {})
        data = json.loads(output.getvalue())
        data.update(user='pi', shell='/bin/fish')
        self.assertTrue(any('-C' in call.args[0] and f'user={pwd.getpwuid(os.getuid()).pw_name},addr=10.0.2.2,host=10.0.2.2,laddr=10.0.2.15,lport=22' in call.args[0]
                            for call in run.call_args_list))
        with self.assertRaisesRegex(v.Failure, 'password authentication'):
            v.check_metadata(data, 'pipette', 8*1024**3)

    def test_root_growth_threshold_is_exact(self):
        data = good()
        data['root_bytes'] = 85
        v.check_metadata(data, 'pipette', 100)
        data['root_bytes'] = 84
        with self.assertRaises(v.Failure):
            v.check_metadata(data, 'pipette', 100)

    def test_balloon_success_restores_memory(self):
        qmp = Mock()
        qmp.command.return_value = {'actual': 1024**3}
        with patch.object(v, 'wait_balloon') as wait:
            report = v.balloon_test(qmp)
        self.assertTrue(report['restored'])
        self.assertEqual(qmp.command.call_args.args, ('balloon', {'value': 1024**3}))
        self.assertEqual(wait.call_count, 2)

    def test_balloon_failure_still_restores_memory(self):
        qmp = Mock()
        qmp.command.return_value = {'actual': 1024**3}
        with patch.object(v, 'wait_balloon', side_effect=[v.Failure('target failed'), None]):
            with self.assertRaisesRegex(v.Failure, 'target failed'):
                v.balloon_test(qmp)
        self.assertEqual(qmp.command.call_args.args, ('balloon', {'value': 1024**3}))

    def test_balloon_restore_failure_is_explicit(self):
        qmp = Mock()
        qmp.command.return_value = {'actual': 1024**3}
        with patch.object(v, 'wait_balloon', side_effect=[None, v.Failure('restore failed')]):
            with self.assertRaisesRegex(v.Failure, 'restoration FAILED'):
                v.balloon_test(qmp)


if __name__ == '__main__':
    unittest.main()
