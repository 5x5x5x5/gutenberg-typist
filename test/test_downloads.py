#!/usr/bin/env python3
"""Offline downloader checks using a fake curl executable."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VIM = shutil.which("vim")

FAKE_CURL = r'''#!/usr/bin/python3
import json, os, sys
if "--fail" not in sys.argv:
    sys.exit(91)
url = sys.argv[-1]
with open(os.environ["CURL_LOG"], "a", encoding="utf-8") as f:
    f.write(url + "\n")
mode = os.environ["CURL_MODE"]
if url.startswith("https://search.invalid/books?"):
    print(json.dumps({"results": [{"id": 41, "formats": {
        "text/plain; charset=utf-8": "https://files.invalid/book.txt",
        "text/plain; charset=us-ascii": "https://files.invalid/book.zip",
        "application/epub+zip": "https://files.invalid/book.epub"}}]}))
    sys.exit(0)
if mode == "http":
    sys.stdout.write("partial error body")
    sys.exit(22)
if mode == "partial":
    sys.stdout.write("truncated transfer")
    sys.exit(18)
if mode == "large":
    sys.stdout.write("x" * 300000)
    sys.exit(0)
sys.stdout.write("*** START OF THE PROJECT GUTENBERG EBOOK ***\nhello book\n*** END OF THE PROJECT GUTENBERG EBOOK ***\n")
'''


def run(mode, vim_body, with_curl=True):
    with tempfile.TemporaryDirectory(prefix="gt-download-test-") as td:
        tmp = Path(td)
        if with_curl:
            curl = tmp / "curl"
            curl.write_text(FAKE_CURL, encoding="utf-8")
            curl.chmod(0o755)
        script = tmp / "test.vim"
        result = tmp / "result.json"
        script.write_text(
            "set rtp^=" + str(ROOT) + "\n"
            + "let g:gt_data_dir = " + json.dumps(str(tmp / "data")) + "\n"
            + "call gt#config#Apply({'gutenberg': {'search_url': 'https://search.invalid/books', 'book_url': 'https://fallback.invalid/%d/%d'}})\n"
            + vim_body.replace("RESULT_PATH", json.dumps(str(result)))
            + "\nqa!\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        path = str(tmp) if with_curl else ""
        if with_curl:
            path += os.pathsep + env.get("PATH", "")
        env.update(PATH=path, CURL_MODE=mode, CURL_LOG=str(tmp / "curl.log"))
        proc = subprocess.run(
            [VIM, "-Nu", "NONE", "-i", "NONE", "-n", "-es", "-S", str(script)],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode:
            raise AssertionError(f"Vim failed: {proc.stderr}\n{proc.stdout}")
        urls = (tmp / "curl.log").read_text(encoding="utf-8").splitlines() if (tmp / "curl.log").exists() else []
        return json.loads(result.read_text(encoding="utf-8")), urls


class DownloadTests(unittest.TestCase):
    def test_cached_metadata_url_and_success(self):
        results, urls = run(
            "success",
            r'''
let g:done = 0
let g:answer = {}
call gt#storage#SaveBookMetadata(41, {'formats': {'text/plain; charset=utf-8': 'https://files.invalid/book.txt'}})
call gt#gutenberg#DownloadWithMetadata(41, v:null, {value, err -> execute("let g:answer.text = value | let g:answer.err = err | let g:done += 1")})
while g:done < 1 | sleep 10m | endwhile
sleep 50m
let g:answer.callback_count = g:done
call writefile([json_encode(g:answer)], RESULT_PATH)
''',
        )
        self.assertEqual(results["text"].strip(), "hello book")
        self.assertIsNone(results["err"])
        self.assertEqual(results["callback_count"], 1)
        self.assertEqual(urls, ["https://files.invalid/book.txt"])

    def test_search_result_selected_url_is_used(self):
        results, urls = run(
            "success",
            r'''
let g:done = 0
let g:answer = {}
call gt#gutenberg#Search('x', {value, err -> execute("let g:answer.search = value | let g:answer.search_err = err | let g:done += 1")})
while g:done < 1 | sleep 10m | endwhile
call gt#gutenberg#DownloadWithMetadata(41, {'download_url': g:answer.search[0].download_url}, {value, err -> execute("let g:answer.text = value | let g:answer.err = err | let g:done += 1")})
while g:done < 2 | sleep 10m | endwhile
call writefile([json_encode(g:answer)], RESULT_PATH)
''',
        )
        self.assertEqual(results["search"][0]["download_url"], "https://files.invalid/book.txt")
        self.assertIsNone(results["search_err"])
        self.assertEqual(results["text"].strip(), "hello book")
        self.assertIsNone(results["err"])
        self.assertEqual(urls[-1], "https://files.invalid/book.txt")

    def test_successfully_drains_large_output(self):
        results, urls = run(
            "large",
            r'''
let g:done = 0
let g:answer = {}
call gt#gutenberg#Download(60, {value, err -> execute("let g:answer.text_length = strlen(value) | let g:answer.err = err | let g:done += 1")})
while g:done < 1 | sleep 10m | endwhile
call writefile([json_encode(g:answer)], RESULT_PATH)
''',
        )
        self.assertEqual(results["text_length"], 300000)
        self.assertIsNone(results["err"])
        self.assertEqual(urls, ["https://fallback.invalid/60/60"])

    def test_unsuccessful_transfers_are_not_cached(self):
        for mode in ("http", "partial"):
            with self.subTest(mode=mode):
                results, urls = run(
                    mode,
                    r'''
let g:done = 0
let g:answer = {}
call gt#gutenberg#Download(51, {value, err -> execute("let g:answer.text = value | let g:answer.err = err | let g:done += 1")})
while g:done < 1 | sleep 10m | endwhile
sleep 50m
let g:answer.callback_count = g:done
let g:answer.cached = gt#storage#LoadBookText(51)
call writefile([json_encode(g:answer)], RESULT_PATH)
''',
                )
                self.assertIsNone(results["text"])
                self.assertTrue(results["err"])
                self.assertEqual(results["callback_count"], 1)
                self.assertIsNone(results["cached"])
                self.assertEqual(urls, ["https://fallback.invalid/51/51"])

    def test_cache_write_failure_is_reported(self):
        results, _urls = run(
            "success",
            r'''
let g:done = 0
let g:answer = {}
call mkdir(g:gt_data_dir, 'p')
call delete(g:gt_data_dir, 'd')
call writefile(['file blocks directory creation'], g:gt_data_dir)
call gt#gutenberg#Download(52, {value, err -> execute("let g:answer.text = value | let g:answer.err = err | let g:done += 1")})
while g:done < 1 | sleep 10m | endwhile
call writefile([json_encode(g:answer)], RESULT_PATH)
''',
        )
        self.assertIsNone(results["text"])
        self.assertIn("cache downloaded book", results["err"])

    def test_curl_start_failure_calls_back(self):
        results, urls = run(
            "unused",
            r'''
let g:done = 0
let g:answer = {}
call gt#gutenberg#Download(53, {value, err -> execute("let g:answer.text = value | let g:answer.err = err | let g:done += 1")})
while g:done < 1 | sleep 10m | endwhile
sleep 50m
let g:answer.callback_count = g:done
call writefile([json_encode(g:answer)], RESULT_PATH)
''',
            with_curl=False,
        )
        self.assertIsNone(results["text"])
        self.assertTrue(results["err"])
        self.assertEqual(results["callback_count"], 1)
        self.assertEqual(urls, [])


if __name__ == "__main__":
    unittest.main()
