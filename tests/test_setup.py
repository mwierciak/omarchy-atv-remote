import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))
import runtime


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.data = Path(self.temporary.name) / 'data'
        self.venv = self.data / 'venv'
        for key, value in [('DATA', self.data), ('VENV', self.venv)]:
            item = patch.object(runtime, key, value)
            item.start()
            self.addCleanup(item.stop)

    def test_install_uses_system_python_and_complete_hash_lock(self):
        with patch.object(runtime.subprocess, 'run') as run:
            runtime.install()
        calls = [call.args[0] for call in run.call_args_list]
        self.assertEqual(calls[0][0], '/usr/bin/python')
        self.assertIn('--copies', calls[0])
        self.assertIn('--require-hashes', calls[1])
        self.assertIn('--only-binary=:all:', calls[1])
        self.assertIn('--isolated', calls[1])
        self.assertIn(str(runtime.LOCK), calls[1])
        self.assertTrue(all(call.kwargs['timeout'] <= 240 for call in run.call_args_list))
        self.assertTrue(runtime.installed())

    def test_completed_install_is_reused(self):
        with patch.object(runtime.subprocess, 'run') as run:
            runtime.install()
            run.reset_mock()
            runtime.install()
            run.assert_not_called()

    def test_failed_install_never_marks_runtime_complete(self):
        with patch.object(runtime.subprocess, 'run', side_effect=RuntimeError('failed')):
            with self.assertRaises(RuntimeError):
                runtime.install()
        self.assertFalse(runtime.installed())

    def test_symlinked_install_directory_is_rejected(self):
        self.data.mkdir()
        destination = Path(self.temporary.name) / 'victim'
        destination.mkdir()
        self.venv.symlink_to(destination, target_is_directory=True)
        with self.assertRaises(OSError), patch.object(runtime.subprocess, 'run') as run:
            runtime.install()
        run.assert_not_called()
        self.assertEqual(list(destination.iterdir()), [])

    def test_stdin_remote_mode_omits_command_from_exec_arguments(self):
        with patch.object(runtime, 'installed', return_value=True), \
             patch.object(runtime.os, 'execv') as execv, \
             patch.object(sys, 'argv', ['runtime.py', 'remote-stdin', '10.0.0.5', '/plugin/remote_daemon.py']):
            runtime.main()
        arguments = execv.call_args.args[1]
        self.assertEqual(arguments[-2:], ['10.0.0.5', '/plugin/remote_daemon.py'])
        self.assertNotIn('text_append:', ' '.join(arguments))
