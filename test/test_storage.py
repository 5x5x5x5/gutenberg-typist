"""Offline reliability checks for the Vim storage layer."""
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class StorageReliability(unittest.TestCase):
    def run_vim(self, data_dir: Path, commands: list[str]) -> None:
        script = data_dir.parent / "check.vim"
        lines = [
            "set nocompatible",
            f"execute 'set runtimepath^=' . fnameescape({json.dumps(str(ROOT))})",
            f"let g:gt_data_dir = {json.dumps(str(data_dir))}",
            *commands,
            "qa!",
        ]
        script.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result = subprocess.run(
            ["vim", "-Nu", "NONE", "-i", "NONE", "-n", "-es", "-S", str(script)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_atomic_json_preserves_previous_file_and_data_dir_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            data_dir = Path(temp) / "private-data"
            self.run_vim(data_dir, [
                "call assert_true(gt#storage#SaveBookMetadata(12, {'title': 'kept'}))",
                # json_encode cannot encode a Funcref; failed serialization must
                # not truncate the previously valid metadata file.
                "call assert_false(gt#storage#SaveBookMetadata(12, {'bad': function('tr')}))",
                "call assert_equal('kept', gt#storage#LoadBookMetadata(12).title)",
                "if len(v:errors) | cquit | endif",
            ])
            self.assertTrue((data_dir / "books/12/metadata.json").is_file())
            self.assertEqual(list(data_dir.rglob("*.tmp.*")), [])

    def test_legacy_migration_retries_after_retirement_failure_without_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            data_dir = Path(temp) / "state"
            data_dir.mkdir()
            (data_dir / "lifetime_stats.json").write_text(json.dumps({
                "format_version": 1,
                "total_chars": 120,
                "correct_chars": 115,
                "total_time_seconds": 30,
                "sessions_count": 1,
            }), encoding="utf-8")
            # Force only the retirement rename to fail after the log is safely
            # written. The second attempt must detect the deterministic ID.
            (data_dir / "lifetime_stats.json.v0").mkdir()
            self.run_vim(data_dir, [
                "let l1 = gt#storage#LoadSessionLog()",
                "call assert_equal(1, len(l1))",
                "call assert_true(filereadable(g:gt_data_dir . '/lifetime_stats.json'))",
                "call delete(g:gt_data_dir . '/lifetime_stats.json.v0', 'd')",
                "let l2 = gt#storage#LoadSessionLog()",
                "call assert_equal(1, len(l2))",
                "call assert_false(filereadable(g:gt_data_dir . '/lifetime_stats.json'))",
                "call assert_true(filereadable(g:gt_data_dir . '/lifetime_stats.json.v0'))",
                "if len(v:errors) | cquit | endif",
            ])

    def test_import_rejects_malformed_records_and_progress_container(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            data_dir = Path(temp) / "state"
            data_dir.mkdir()
            good = {
                "id": "f3d2c8a1-7b4e-4c9a-9e21-0a8f6d5b3c17",
                "machine": "host",
                "date": "2026-07-19",
                "book": {"gutenberg_id": 1342},
                "active_ms": 10,
                "wall_ms": 10,
                "chars_typed": 3,
                "errors_uncorrected": 1,
                "corrections": 1,
            }
            bad_record = dict(good, errors_uncorrected=4)
            bundles = [
                {"schema": 1, "sessions": [bad_record]},
                {"schema": 1, "sessions": [good], "gt_progress": []},
            ]
            for i, bundle in enumerate(bundles):
                (data_dir.parent / f"bad-{i}.json").write_text(json.dumps(bundle), encoding="utf-8")
            self.run_vim(data_dir, [
                f"let r1 = gt#storage#ImportBundle({json.dumps(str(data_dir.parent / 'bad-0.json'))})",
                f"let r2 = gt#storage#ImportBundle({json.dumps(str(data_dir.parent / 'bad-1.json'))})",
                "call assert_false(r1.ok)",
                "call assert_false(r2.ok)",
                "call assert_false(filereadable(g:gt_data_dir . '/session_log.json'))",
                "if len(v:errors) | cquit | endif",
            ])


if __name__ == "__main__":
    unittest.main()
