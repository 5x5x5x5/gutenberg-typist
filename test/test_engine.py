"""Focused Vim integration checks for Unicode offsets and finalization."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_unicode_comparison_and_finalization_use_character_ranges():
    vim = shutil.which("vim")
    if vim is None:
        raise RuntimeError("Vim is required for engine integration checks")
    with tempfile.TemporaryDirectory(prefix="gt-engine-") as temp:
        data = Path(temp) / "data"
        script = Path(temp) / "engine.vim"
        script.write_text(
            "\n".join(
                [
                    f"set runtimepath^={ROOT}",
                    "set viminfofile=NONE",
                    "highlight GTCorrect ctermfg=Green guifg=Green",
                    "highlight GTWrong ctermfg=Red guifg=Red",
                    "highlight GTUntyped ctermfg=White guifg=White",
                    "highlight GTCursor ctermfg=Yellow guifg=Yellow",
                    f"let g:gt_data_dir = '{data}'",
                    "let g:gt_machine_id = 'engine-test'",
                    "call gt#engine#Start(987654, 'éabc', strlen('é'))",
                    "let s:ui = gt#ui#GetState()",
                    "call setbufline(s:ui.typing_buf, 1, ['éX'])",
                    "call gt#engine#OnTextChanged()",
                    "tabnew",
                    "qa!",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [vim, "-Nu", "NONE", "-n", "-es", "-S", str(script)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr
        log = json.loads((data / "session_log.json").read_text())
        assert len(log) == 1
        record = log[0]
        assert record["chars_typed"] == 1
        assert record["errors_uncorrected"] == 1
        assert record["range"] == {"start": 1, "end": 2}
        progress = json.loads((data / "sessions" / "987654.json").read_text())
        assert progress["offset"] == len("éX".encode("utf-8"))


def test_stats_accuracy_includes_corrections_and_sample_history_is_bounded():
    vim = shutil.which("vim")
    if vim is None:
        raise RuntimeError("Vim is required for engine stats checks")
    with tempfile.TemporaryDirectory(prefix="gt-stats-") as temp:
        result_file = Path(temp) / "result"
        script = Path(temp) / "stats.vim"
        script.write_text(
            "\n".join(
                [
                    f"set runtimepath^={ROOT}",
                    "set viminfofile=NONE",
                    "let s:s = gt#stats#New()",
                    "let s:s.ever_wrong = {'1': 1}",
                    "call gt#stats#UpdateFromComparison(s:s, 2, 2, 0, 0.0)",
                    "for s:i in range(1, 5000)",
                    "  call gt#stats#UpdateFromComparison(s:s, 2, 2, 2, s:i * 0.01)",
                    "endfor",
                    f"call writefile([string(gt#stats#Accuracy(s:s)), string(len(s:s.samples))], '{result_file}')",
                    "qa!",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        subprocess.run(
            [vim, "-Nu", "NONE", "-n", "-es", "-S", str(script)],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        accuracy, sample_count = result_file.read_text().splitlines()
        assert abs(float(accuracy) - (2 / 3 * 100)) < 0.01
        assert int(sample_count) < 1500


class EngineIntegrationTests(unittest.TestCase):
    def test_unicode_offsets_and_tab_finalization(self):
        test_unicode_comparison_and_finalization_use_character_ranges()

    def test_accuracy_and_bounded_sample_history(self):
        test_stats_accuracy_includes_corrections_and_sample_history_is_bounded()


if __name__ == "__main__":
    unittest.main()
