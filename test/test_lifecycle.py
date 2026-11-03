"""Regressions for closing Vim, checkpoints, and ordinary Vim editing."""
import json
from pathlib import Path
import tempfile
import unittest
import test_commands as support


class LifecycleTests(unittest.TestCase):
    run_vim = support.CommandTests.run_vim

    def test_close_and_exit_capture_pending_changes_once(self):
        for ending in [[], ['close!', 'sleep 20m'],
                       ["call win_execute(gt#ui#GetState().source_win, 'quit!')", 'sleep 20m'],
                       ['tabprevious', 'call gt#engine#Stop()']]:
            with self.subTest(ending=ending), tempfile.TemporaryDirectory() as name:
                directory = Path(name)
                self.run_vim(directory, [
                    "call gt#engine#Start(1, 'é—abc', 0)",
                    "call setbufline(gt#ui#GetState().typing_buf, 1, 'é—ab')",
                    # Deliberately no TextChanged call before closing.
                    *ending,
                ])
                data = directory / 'data'
                record, = json.loads((data / 'session_log.json').read_text())
                self.assertEqual(record['chars_typed'], 4)
                self.assertEqual(record['errors_uncorrected'], 0)
                self.assertEqual(json.loads((data / 'sessions/1.json').read_text())['offset'], 7)

    def test_checkpoints_happen_during_continuous_changes(self):
        with tempfile.TemporaryDirectory() as name:
            self.run_vim(Path(name), [
                "call gt#Setup({'save_interval_ms': 20})",
                "call gt#engine#Start(1, 'abcdefghij', 0)",
                'for i in range(1, 8)',
                "call setbufline(gt#ui#GetState().typing_buf, 1, strpart('abcdefghij', 0, i))",
                'call gt#engine#OnTextChanged()', 'sleep 15m', 'endfor',
                'call assert_true(gt#engine#IsActive())',
                'call assert_true(gt#storage#LoadSession(1).offset >= 6)',
                'call assert_equal([], gt#storage#LoadSessionLog())',
            ])

    def test_middle_edits_deletion_and_multibyte_mismatches(self):
        source = 'é—abc\nxyz'
        edits = ['é', 'ê', 'é—abX', 'é—abc', 'é—abc\nxy', 'éXabc\nxyz', '',
                 'é—abc\nxyzTAIL', 'é—abc\nxyzTA', 'é—abc\nxyz']
        commands = [f'call gt#engine#Start(1, {json.dumps(source, ensure_ascii=False)}, 0)',
                    'let ui = gt#ui#GetState()']
        for typed in edits:
            commands += [f'call setbufline(ui.typing_buf, 1, {json.dumps(typed.split(chr(10)), ensure_ascii=False)})',
                         f"call deletebufline(ui.typing_buf, {len(typed.split(chr(10))) + 1}, '$')",
                         'call gt#engine#OnTextChanged()',
                         f'call assert_equal({len(typed)}, gt#engine#GetState().stats.rel_typed)',
                         f'call assert_equal({sum(a == b for a, b in zip(typed, source))}, gt#engine#GetState().stats.rel_correct)',
                         "call assert_equal(5, len(prop_list(1, {'bufnr': ui.source_buf})))"]
        with tempfile.TemporaryDirectory() as name:
            self.run_vim(Path(name), commands)

    def test_resume_prefix_and_abandoned_errors_do_not_change_accuracy(self):
        with tempfile.TemporaryDirectory() as name:
            self.run_vim(Path(name), [
                "call gt#engine#Start(1, 'éabc', 2)",
                "call setbufline(gt#ui#GetState().typing_buf, 1, 'XabZ')",
                'call gt#engine#OnTextChanged()',
                "call setbufline(gt#ui#GetState().typing_buf, 1, 'Xab')",
                'call gt#engine#OnTextChanged()',
                'call assert_equal(2, gt#engine#GetState().stats.rel_correct)',
                'call assert_equal(100.0, gt#stats#Accuracy(gt#engine#GetState().stats))',
                'call gt#engine#Stop()',
                'call assert_equal(0, gt#storage#LoadSessionLog()[0].corrections)',
            ])


if __name__ == '__main__':
    unittest.main()
