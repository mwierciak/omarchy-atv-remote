import io
import json
from pathlib import Path
import subprocess
import sys
import unittest

BIN = Path(__file__).resolve().parents[1] / 'bin'
sys.path.insert(0, str(BIN))
from command_input import read_command


class CommandInputTests(unittest.TestCase):
    def test_reads_json_command_frame(self):
        self.assertEqual(read_command(io.BytesIO(b'{"command":"text_append:s"}\n')),
                         'text_append:s')

    def test_accepts_escaped_text_without_line_confusion(self):
        frame = (json.dumps({'command': 'text_append:\\n'}) + '\n').encode()
        self.assertEqual(read_command(io.BytesIO(frame)), 'text_append:\\n')

    def test_rejects_missing_oversized_and_non_string_commands(self):
        bad_frames = (b'', b'{}\n', b'{"command":3}\n',
                      b'{"command":"x"}', b'x' * 1025 + b'\n')
        for frame in bad_frames:
            with self.subTest(frame=frame[:20]), self.assertRaises(ValueError):
                read_command(io.BytesIO(frame))

    def test_panel_sends_commands_over_stdin(self):
        panel = (BIN.parent / 'Panel.qml').read_text()
        self.assertIn('action.command = [backend, activeAddress, "--stdin"]', panel)
        self.assertIn('stdinEnabled: true', panel)
        self.assertNotIn('action.command = [backend, activeAddress, runningCommand]', panel)

    def test_sensitive_defaults_are_secure(self):
        manifest = json.loads((BIN.parent / 'manifest.json').read_text())
        defaults = manifest['barWidget']['defaults']
        self.assertTrue(defaults['maskTextPreview'])
        self.assertFalse(defaults['networkScan'])

    def test_shell_entrypoint_rejects_text_in_argv(self):
        result = subprocess.run([str(BIN / 'apple-tv'), '127.0.0.1',
                                 'text_append:not-a-real-secret'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('must be supplied with --stdin', result.stderr)
        self.assertNotIn('not-a-real-secret', result.stderr)


if __name__ == '__main__':
    unittest.main()
