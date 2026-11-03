"""Core command and optional companion integration, without network access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CommandTests(unittest.TestCase):
    def run_vim(self, directory, commands, env=None):
        script = directory / 'commands.vim'
        result_file = directory / 'errors.json'
        script.write_text('\n'.join([
            'set nocompatible encoding=utf-8',
            f'let &runtimepath = {json.dumps(str(ROOT))} . "," . &runtimepath',
            f'let g:gt_data_dir = {json.dumps(str(directory / "data"))}',
            'runtime plugin/gt.vim', *commands,
            f'call writefile([json_encode(v:errors)], {json.dumps(str(result_file))})',
            'if !empty(v:errors) | cquit | endif', 'qa!',
        ]))
        result = subprocess.run(['vim', '-Nu', 'NONE', '-i', 'NONE', '-n', '-es', '-S', str(script)],
                                capture_output=True, text=True, env=env, timeout=15)
        self.assertEqual(result.returncode, 0,
                         (result_file.read_text() if result_file.exists() else '') + result.stderr)

    def test_unicode_queries_and_optional_command_boundary(self):
        with tempfile.TemporaryDirectory() as name:
            self.run_vim(Path(name), [
                "call assert_equal('caf%C3%A9%20%E2%80%94', gt#util#UriEncode('café —'))",
                "call assert_equal('', gt#util#UriEncode(''))",
                "call assert_equal(0, exists(':GTGuildPublish'))",
                "call assert_equal(-1, index(gt#Complete('', 'GT ', 3), 'publish'))",
                'runtime extras/guild/plugin/gt_guild.vim',
                "call assert_equal(2, exists(':GTGuildPublish'))",
            ])

    def test_companion_reports_failed_transport_and_malformed_response(self):
        for status, body, expected in [
            (22, '{"rank":1,"total_users":1,"best_wpm":1}', 'curl exited with status 22'),
            (0, '{"unexpected":true}', 'invalid guild response'),
        ]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as name:
                directory = Path(name)
                executable = directory / 'curl'
                executable.write_text('#!/usr/bin/env python3\nimport sys\n'
                                      f'print({body!r})\nsys.exit({status})\n')
                executable.chmod(0o755)
                env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'])
                self.run_vim(directory, [
                    'runtime extras/guild/plugin/gt_guild.vim',
                    "let g:gt_hub_url = 'https://guild.invalid'",
                    "let g:gt_hub_token = 'fake-test-token'",
                    "call gt#storage#SaveSession(1, {'offset': 1})",
                    'GTGuildPublish', 'sleep 500m',
                    f"call assert_match('{expected}', execute('messages'))",
                    "call assert_notmatch('GT: Published', execute('messages'))",
                ], env)


if __name__ == '__main__':
    unittest.main()
