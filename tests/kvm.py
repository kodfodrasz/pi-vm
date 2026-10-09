"""Offline KVM lifecycle checks; never start or stop a real VM."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('kvm_process', ROOT/'scripts/kvm-process.py')
k = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT/'build/test-tmp'
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pidfile = self.root/'qemu.pid'
        self.pidfile.write_text('123\n')
        self.disk = self.root/'disk with spaces.qcow2'
        self.proc = self.root/'proc'
        self.process = self.proc/'123'
        self.process.mkdir(parents=True)
        (self.process/'exe').symlink_to('/usr/bin/qemu-system-x86_64')
        self.argv(b'qemu-system-x86_64', b'-drive', os.fsencode('file='+str(self.disk)+',if=virtio'))
        context = patch.object(k, 'PROC_ROOT', self.proc)
        context.start()
        self.addCleanup(context.stop)

    def argv(self, *args):
        (self.process/'cmdline').write_bytes(b'\0'.join(args)+b'\0')

    def test_exact_process_and_disk_match(self):
        self.assertTrue(k.status(self.pidfile, self.disk))

    def test_upgraded_deleted_executable_still_matches(self):
        (self.process/'exe').unlink()
        (self.process/'exe').symlink_to('/usr/bin/qemu-system-x86_64 (deleted)')
        self.assertTrue(k.status(self.pidfile, self.disk))

    def test_argument_impostor_is_not_qemu(self):
        (self.process/'exe').unlink()
        (self.process/'exe').symlink_to('/usr/bin/python3')
        self.assertFalse(k.status(self.pidfile, self.disk))

    def test_wrong_or_ambiguous_disk_does_not_match(self):
        for option in ['file='+str(self.disk)+'.backup',
                       'note=file='+str(self.disk),
                       'file='+str(self.disk)+',file=/other.qcow2']:
            self.argv(b'qemu-system-x86_64', b'-drive', os.fsencode(option))
            with self.subTest(option=option):
                self.assertFalse(k.status(self.pidfile, self.disk))

    def test_disk_string_outside_drive_option_does_not_match(self):
        self.argv(b'qemu-system-x86_64', os.fsencode('file='+str(self.disk)))
        self.assertFalse(k.status(self.pidfile, self.disk))

    def test_missing_process_or_cmdline_is_stopped(self):
        (self.process/'cmdline').unlink()
        self.assertFalse(k.status(self.pidfile, self.disk))
        self.pidfile.write_text('124')
        self.assertFalse(k.status(self.pidfile, self.disk))

    def test_invalid_pid_records_are_rejected(self):
        for text in ['', '0', '-1', '1.5', 'abc', '2147483648', '9'*5000, '123'+' '*100+'x']:
            self.pidfile.write_text(text)
            with self.subTest(text=text[:20]):
                self.assertIsNone(k.read_pid(self.pidfile))

    def test_symlink_and_nonregular_pid_records_are_rejected(self):
        link = self.root/'link.pid'
        link.symlink_to(self.pidfile)
        self.assertIsNone(k.read_pid(link))
        self.assertIsNone(k.read_pid(self.root))
        fifo = self.root/'fifo.pid'
        os.mkfifo(fifo)
        self.assertIsNone(k.read_pid(fifo))

    def test_pidfd_is_pinned_before_identity_check_and_closed(self):
        events = []
        with patch.object(k, 'read_pid', return_value=123), \
             patch.object(k.os, 'pidfd_open', side_effect=lambda pid: events.append('pin') or 42), \
             patch.object(k, 'matches', side_effect=lambda *args: events.append('verify') or True), \
             patch.object(k.signal, 'pidfd_send_signal', side_effect=lambda *args: events.append('signal')), \
             patch.object(k.os, 'close', side_effect=lambda fd: events.append('close')), \
             patch.object(k.os, 'kill') as unsafe:
            self.assertTrue(k.terminate(self.pidfile, self.disk))
            unsafe.assert_not_called()
        self.assertEqual(events, ['pin', 'verify', 'signal', 'close'])

    def test_mismatch_after_pin_never_signals(self):
        with patch.object(k, 'read_pid', return_value=123), \
             patch.object(k.os, 'pidfd_open', return_value=42), \
             patch.object(k, 'matches', return_value=False), \
             patch.object(k.signal, 'pidfd_send_signal') as send, patch.object(k.os, 'close') as close:
            self.assertFalse(k.terminate(self.pidfile, self.disk))
            send.assert_not_called()
            close.assert_called_once_with(42)

    def test_missing_pidfd_support_has_no_unsafe_fallback(self):
        with patch.object(k, 'read_pid', return_value=123), \
             patch.object(k.os, 'pidfd_open', side_effect=AttributeError('unsupported')), \
             patch.object(k.os, 'kill') as unsafe:
            self.assertFalse(k.terminate(self.pidfile, self.disk))
            unsafe.assert_not_called()

    def test_exited_process_signal_failure_closes_handle(self):
        with patch.object(k, 'read_pid', return_value=123), \
             patch.object(k.os, 'pidfd_open', return_value=42), patch.object(k, 'matches', return_value=True), \
             patch.object(k.signal, 'pidfd_send_signal', side_effect=ProcessLookupError()), \
             patch.object(k.os, 'close') as close:
            self.assertFalse(k.terminate(self.pidfile, self.disk))
            close.assert_called_once_with(42)

    @unittest.skipUnless(hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'),
                         'Python pidfd API unavailable')
    def test_native_pidfd_terminates_only_owned_sentinel(self):
        sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        try:
            self.pidfile.write_text(str(sentinel.pid))
            with patch.object(k, 'matches', return_value=True):
                self.assertTrue(k.terminate(self.pidfile, self.disk))
            self.assertEqual(sentinel.wait(timeout=5), -signal.SIGTERM)
        finally:
            if sentinel.poll() is None:
                sentinel.terminate()
                sentinel.wait(timeout=5)

    def shell(self, *args, build=None):
        env = dict(os.environ, PI_VM_BUILD=str(build or self.root/'build'),
                   PI_VM_CACHE=str(self.root/'cache'))
        return subprocess.run([str(ROOT/'scripts/kvm.sh'), *args], env=env,
                              text=True, capture_output=True, timeout=10)

    def test_invalid_cli_input_creates_no_storage(self):
        cases = [('bogus', 'test'), ('status', '../test'), ('start', 'test', '--memory'),
                 ('start', 'test', '--memory', '511'), ('start', 'test', '--cpus', '0'),
                 ('start', 'test', '--disk', '4G'), ('start', 'test', '--ssh-port', '65536'),
                 ('start', 'test', '--disk', '9'*5000+'G'),
                 ('start', 'test', '--memory', '1048577'), ('start', 'test', '--disk', '65537G')]
        for args in cases:
            with self.subTest(args=str(args)[:80]):
                result = self.shell(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse((self.root/'build').exists())
                self.assertFalse((self.root/'cache').exists())

    def test_comma_build_path_rejected_before_writes(self):
        build = self.root/'comma,build'
        self.assertEqual(self.shell('status', 'test', build=build).returncode, 2)
        self.assertFalse(build.exists())

    def test_decimal_resource_normalization_and_limits(self):
        self.assertTrue(k.valid_resources('0000512', '0001', '0005120M', '02222'))
        result = subprocess.run([sys.executable, str(ROOT/'scripts/kvm-process.py'),
                                 'validate', '0000512', '0001', '0005120M', '02222'],
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.stdout.strip(), '512 1 5120M 2222')
        self.assertTrue(k.valid_resources('1048576', '1024', '65536G', '65535'))

    def test_real_unrelated_process_survives_status_and_force_stop(self):
        instance = self.root/'build/test'
        instance.mkdir(parents=True)
        disk = instance/'disk.qcow2'
        disk.write_bytes(b'owned test disk')
        sentinel = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)',
                                     'qemu-system-x86_64', 'file='+str(disk)])
        try:
            (instance/'qemu.pid').write_text(str(sentinel.pid))
            self.assertEqual(self.shell('status', 'test').returncode, 1)
            self.assertEqual(self.shell('stop', 'test', '--force').returncode, 1)
            self.assertIsNone(sentinel.poll())
            self.assertEqual(disk.read_bytes(), b'owned test disk')
        finally:
            sentinel.terminate()
            sentinel.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
