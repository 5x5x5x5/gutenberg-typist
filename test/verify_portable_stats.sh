#!/usr/bin/env bash
# Headless verification of the schema-1 stats pipeline (SPEC.md in the
# typist-guild repo): session log, legacy migration, export/import by set
# union, and :GT publish. Simulates machines with sandboxed $HOMEs.
set -u
cd "$(dirname "$0")/.."
PLUGIN_DIR=$PWD
T=$(mktemp -d /tmp/gt-verify.XXXXXX)
mkdir -p "$T/homeA" "$T/homeB" "$T/homeC"
PASS=0; FAIL=0

run_vim() {  # run_vim <home> <machine-id> <ex-command>...
  local home=$1 mid=$2; shift 2
  local args=()
  for c in "$@"; do args+=(-c "$c"); done
  HOME="$home" vim -es -N -u NONE \
    --cmd "set rtp+=$PLUGIN_DIR" \
    --cmd "let g:gt_machine_id='$mid'" \
    "${args[@]}" -c 'qa!'
}

check() {  # check <desc> <file> <grep-pattern (ERE)>
  if grep -qE "$3" "$2" 2>/dev/null; then
    echo "PASS: $1"; PASS=$((PASS+1))
  else
    echo "FAIL: $1  (pattern: $3)"
    echo "  got: $(cat "$2" 2>/dev/null || echo '<missing>')"
    FAIL=$((FAIL+1))
  fi
}

check_not() {  # check_not <desc> <file> <grep-pattern (ERE)> — pattern must NOT match
  if grep -qE "$3" "$2" 2>/dev/null; then
    echo "FAIL: $1  (unexpected pattern: $3)"; FAIL=$((FAIL+1))
  else
    echo "PASS: $1"; PASS=$((PASS+1))
  fi
}

LOG_A="$T/homeA/.vim/gutenberg-typist/session_log.json"
LOG_B="$T/homeB/.vim/gutenberg-typist/session_log.json"

# ── 1. UUID helpers ─────────────────────────────────────────────────────────
run_vim "$T/homeA" machA \
  "call writefile([gt#util#Uuid4(), gt#util#Uuid4(), gt#util#LegacyUuid('sable'), gt#util#LegacyUuid('sable'), gt#util#LegacyUuid('other')], '$T/c1')"
check "Uuid4 is uuid-shaped" "$T/c1" '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
if [ "$(sed -n 1p "$T/c1")" != "$(sed -n 2p "$T/c1")" ]; then
  echo "PASS: two Uuid4 calls differ"; PASS=$((PASS+1))
else
  echo "FAIL: Uuid4 repeated itself"; FAIL=$((FAIL+1))
fi
if [ "$(sed -n 3p "$T/c1")" = "$(sed -n 4p "$T/c1")" ]; then
  echo "PASS: LegacyUuid is deterministic"; PASS=$((PASS+1))
else
  echo "FAIL: LegacyUuid not deterministic"; FAIL=$((FAIL+1))
fi
if [ "$(sed -n 3p "$T/c1")" != "$(sed -n 5p "$T/c1")" ]; then
  echo "PASS: LegacyUuid differs per machine"; PASS=$((PASS+1))
else
  echo "FAIL: LegacyUuid collides across machines"; FAIL=$((FAIL+1))
fi
sed -n 3p "$T/c1" > "$T/c1b"
check "LegacyUuid is uuid-shaped" "$T/c1b" '^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# ── 2. Active time (§5.1): gaps > 5 s excluded in full ─────────────────────
run_vim "$T/homeA" machA \
  "let s = gt#stats#New()" \
  "call gt#stats#UpdateFromComparison(s, 5, 5, 0, 0.0)" \
  "call gt#stats#UpdateFromComparison(s, 10, 10, 5, 2.0)" \
  "call gt#stats#UpdateFromComparison(s, 15, 15, 10, 4.0)" \
  "call gt#stats#UpdateFromComparison(s, 20, 20, 15, 20.0)" \
  "call writefile(['active_ms=' . s.active_ms], '$T/c2')"
check "2s+2s counted, 16s gap excluded" "$T/c2" '^active_ms=4000$'

# ── 3. Legacy counter migration on first export (§9) ────────────────────────
mkdir -p "$T/homeA/.vim/gutenberg-typist/sessions"
echo '{"total_chars":1000,"correct_chars":900,"total_time_seconds":120.5,"sessions_count":3}' \
  > "$T/homeA/.vim/gutenberg-typist/lifetime_stats.json"
echo '{"book_id":4300,"offset":1847,"total_chars_typed":1847,"correct_chars":1742,"last_active":1718199000}' \
  > "$T/homeA/.vim/gutenberg-typist/sessions/4300.json"

run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ExportBundle('$T/bundle-a.json'))], '$T/c3')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c4')"
check "export succeeds from legacy data"      "$T/c3" '"ok":true'
check "bundle is schema 1"                    "$T/bundle-a.json" '"schema":1'
check "legacy record minted for machA"        "$T/bundle-a.json" '"legacy":true'
check "original counters preserved verbatim"  "$T/bundle-a.json" '"legacy_counters":\{[^}]*"total_chars":1000'
check "gt_progress carries book progress"     "$T/bundle-a.json" '"offset":1847'
check_not "no user field in the bundle"       "$T/bundle-a.json" '"user"'
check "aggregate sums migrated chars"         "$T/c4" '"total_chars":1000'
check "float legacy seconds rounded (121s)"   "$T/c4" '"total_time_seconds":121'
if [ -e "$T/homeA/.vim/gutenberg-typist/lifetime_stats.json.v0" ] \
   && [ ! -e "$T/homeA/.vim/gutenberg-typist/lifetime_stats.json" ]; then
  echo "PASS: counter file retired to .v0"; PASS=$((PASS+1))
else
  echo "FAIL: counter file not renamed after migration"; FAIL=$((FAIL+1))
fi
RECORDS_BEFORE=$(grep -o '"id"' "$LOG_A" | wc -l)
run_vim "$T/homeA" machA "call gt#storage#ExportBundle('$T/bundle-a2.json')"
RECORDS_AFTER=$(grep -o '"id"' "$LOG_A" | wc -l)
if [ "$RECORDS_BEFORE" = "$RECORDS_AFTER" ]; then
  echo "PASS: migration cannot run twice"; PASS=$((PASS+1))
else
  echo "FAIL: second run minted more legacy records"; FAIL=$((FAIL+1))
fi

# ── 4. Import on B twice: set union is idempotent ──────────────────────────
run_vim "$T/homeB" machB \
  "call writefile([json_encode(gt#storage#ImportBundle('$T/bundle-a.json'))], '$T/c5')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c6')"
run_vim "$T/homeB" machB \
  "call writefile([json_encode(gt#storage#ImportBundle('$T/bundle-a.json'))], '$T/c7')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c8')"
check "first import adds the record"          "$T/c5" 'Merged 1 new session record'
check "import lands machA stats on B"         "$T/c6" '"total_chars":1000'
check "re-import adds nothing"                "$T/c7" 'Merged 0 new session record'
if diff -q "$T/c6" "$T/c8" >/dev/null 2>&1; then
  echo "PASS: double import is idempotent"; PASS=$((PASS+1))
else
  echo "FAIL: double import changed aggregates"; diff "$T/c6" "$T/c8"; FAIL=$((FAIL+1))
fi
check "book progress imported on B"           "$T/homeB/.vim/gutenberg-typist/sessions/4300.json" '"offset":1847'
check "imported last_active preserved"        "$T/homeB/.vim/gutenberg-typist/sessions/4300.json" '"last_active":1718199000'

# ── 5. Cross-machine union + own-bundle replay ─────────────────────────────
run_vim "$T/homeB" machB \
  "call gt#storage#AppendSessionRecord({'id': gt#util#Uuid4(), 'machine': 'machB', 'date': '2026-07-18', 'book': {'gutenberg_id': 4300, 'title': 'Ulysses'}, 'range': {'start': 0, 'end': 310}, 'active_ms': 60000, 'wall_ms': 70000, 'chars_typed': 310, 'errors_uncorrected': 0, 'corrections': 2})" \
  "call gt#storage#ExportBundle('$T/bundle-b.json')"
run_vim "$T/homeA" machA \
  "call gt#storage#ImportBundle('$T/bundle-b.json')" \
  "call gt#storage#ImportBundle('$T/bundle-a.json')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c9')"
check "A unions both machines' chars"         "$T/c9" '"total_chars":1310'
check "legacy sessions_count + real session"  "$T/c9" '"sessions_count":4'
check "best_wpm from the real record (62)"    "$T/c9" '"best_wpm":62'
check "machines_count reflects both"          "$T/c9" '"machines_count":2'

# ── 6. Same id, changed content: loud abort, nothing written (§4) ──────────
sed 's/"chars_typed":310/"chars_typed":9999/' "$T/bundle-b.json" > "$T/bundle-mutated.json"
run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ImportBundle('$T/bundle-mutated.json'))], '$T/c10')"
check "mutated record aborts the import"      "$T/c10" 'Import aborted'
check "abort message names the id"            "$T/c10" '[0-9a-f]{8}-[0-9a-f]{4}'
check_not "nothing from the mutant persisted" "$LOG_A" '"chars_typed":9999'

# ── 7. v0 bundles and future schemas are refused ───────────────────────────
echo 'not json' > "$T/bad.json"
echo '{"format_version":1,"machines":{"m":{"total_chars":5}},"sessions":{}}' > "$T/v0.json"
echo '{"schema":9,"sessions":[]}' > "$T/future.json"
cp "$LOG_A" "$T/log-before"
run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ImportBundle('$T/bad.json')), json_encode(gt#storage#ImportBundle('$T/v0.json')), json_encode(gt#storage#ImportBundle('$T/future.json'))], '$T/c11')"
check "malformed file rejected"               "$T/c11" 'Cannot read or parse'
check "v0 bundle refused with re-export tip"  "$T/c11" 'v0 counter bundle.*re-export'
check "future schema refused"                 "$T/c11" 'schema 9 not supported'
if cmp -s "$T/log-before" "$LOG_A"; then
  echo "PASS: rejected imports leave the log untouched"; PASS=$((PASS+1))
else
  echo "FAIL: rejected import modified session_log.json"; FAIL=$((FAIL+1))
fi

# ── 8. Export with no data refuses to write ────────────────────────────────
run_vim "$T/homeC" machC \
  "call writefile([json_encode(gt#storage#ExportBundle('$T/bundle-c.json'))], '$T/c12')"
check "empty export refused"                  "$T/c12" 'No stats to export yet'
if [ ! -e "$T/bundle-c.json" ]; then
  echo "PASS: no bundle file written for empty export"; PASS=$((PASS+1))
else
  echo "FAIL: empty export wrote a file"; FAIL=$((FAIL+1))
fi

# ── 9. gt_progress merge policy: newer last_active wins ────────────────────
echo '{"schema":1,"sessions":[],"gt_progress":{"4300":{"book_id":4300,"offset":120,"total_chars_typed":2500,"correct_chars":2400,"last_active":1718299000}}}' \
  > "$T/bundle-newer.json"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-newer.json')" \
  "call writefile(readfile('$T/homeB/.vim/gutenberg-typist/sessions/4300.json'), '$T/c13')"
check "newer incoming progress wins"          "$T/c13" '"offset":120'
check "winner keeps its own last_active"      "$T/c13" '"last_active":1718299000'
echo '{"schema":1,"sessions":[],"gt_progress":{"4300":{"book_id":4300,"offset":9999,"total_chars_typed":9999,"correct_chars":9999,"last_active":1718100000}}}' \
  > "$T/bundle-stale.json"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-stale.json')" \
  "call writefile(readfile('$T/homeB/.vim/gutenberg-typist/sessions/4300.json'), '$T/c14')"
check "older incoming progress ignored"       "$T/c14" '"offset":120'

# ── 9b. Malicious progress keys must not escape the sessions dir ───────────
echo '{"schema":1,"sessions":[],"gt_progress":{"../../evil":{"book_id":1,"offset":5,"last_active":1},"111":{"book_id":111,"offset":"99"},"333":{"book_id":999,"offset":10,"last_active":"abc","total_chars_typed":5}}}' \
  > "$T/bundle-evil.json"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-evil.json')"
SESS="$T/homeB/.vim/gutenberg-typist/sessions"
if [ ! -e "$T/homeB/.vim/evil.json" ] && [ ! -e "$T/homeB/.vim/gutenberg-typist/evil.json" ]; then
  echo "PASS: path-traversal progress key ignored"; PASS=$((PASS+1))
else
  echo "FAIL: malicious progress key escaped sessions dir"; FAIL=$((FAIL+1))
fi
if [ ! -e "$SESS/111.json" ]; then
  echo "PASS: non-numeric offsets rejected"; PASS=$((PASS+1))
else
  echo "FAIL: progress with junk offset was written"; FAIL=$((FAIL+1))
fi
check "book_id forced to match dict key"      "$SESS/333.json" '"book_id":333[,}]'
check_not "non-numeric last_active dropped"   "$SESS/333.json" 'last_active'

# ── 10. Completion + plugin load smoke tests ───────────────────────────────
run_vim "$T/homeA" machA \
  "runtime plugin/gt.vim" \
  "call writefile([exists(':GT') == 2 ? 'cmd-ok' : 'cmd-missing', string(gt#Complete('ex', 'GT ex', 5)), len(gt#Complete('', 'GT export ', 10)) > 0 ? 'file-completion-ok' : 'file-completion-empty', string(gt#Complete('', 'GT start ', 9))], '$T/c15')"
check "plugin loads, :GT defined"             "$T/c15" 'cmd-ok'
check "subcommand completion includes export" "$T/c15" "'export'"
check "file completion for export arg"        "$T/c15" 'file-completion-ok'
grep -q "'search'" <(sed -n '4p' "$T/c15") && { echo "FAIL: ':GT start ' re-offers subcommands"; FAIL=$((FAIL+1)); } \
  || { echo "PASS: ':GT start ' offers no subcommands"; PASS=$((PASS+1)); }

# ── 11. Engine records: errors, corrections, uuid, range ───────────────────
mkdir -p "$T/homeD"
run_vim "$T/homeD" machD \
  "runtime plugin/gt.vim" \
  "call gt#engine#Start(9, 'abcdef', 0) | call setbufline(gt#ui#GetState().typing_buf, 1, 'abcdeX') | call gt#engine#OnTextChanged() | sleep 150m | call setbufline(gt#ui#GetState().typing_buf, 1, 'abcdef') | call gt#engine#OnTextChanged() | call gt#engine#Stop()" \
  "call gt#engine#Start(10, 'zzzzzz', 0) | call setbufline(gt#ui#GetState().typing_buf, 1, 'zzzzzY') | call gt#engine#OnTextChanged() | sleep 150m | call gt#engine#OnTextChanged() | call gt#engine#Stop()"
LOG_D="$T/homeD/.vim/gutenberg-typist/session_log.json"
check "fixed mismatch counts as correction"   "$LOG_D" '"corrections":1'
check "clean final transcript: zero errors"   "$LOG_D" '"errors_uncorrected":0'
check "unfixed mismatch counts as error"      "$LOG_D" '"errors_uncorrected":1'
check "chars_typed is final length"           "$LOG_D" '"chars_typed":6'
check "record ids are uuids"                  "$LOG_D" '"id":"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"'
check "range covers the transcript"           "$LOG_D" '"range":\{"end":6,"start":0\}|"range":\{"start":0,"end":6\}'
check "record carries the date"               "$LOG_D" '"date":"[0-9]{4}-[0-9]{2}-[0-9]{2}"'

# ── 12. Resume must not credit the pre-typed prefix ────────────────────────
mkdir -p "$T/homeR"
run_vim "$T/homeR" machR \
  "runtime plugin/gt.vim" \
  "call gt#engine#Start(7, repeat('abcdef ', 200), 350)" \
  "call gt#engine#OnTextChanged()" \
  "call gt#engine#Stop()" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c16')"
check "resume prefix not counted as typed"    "$T/c16" '"total_chars":0[,}]'
check "resume produces no fluke best_wpm"     "$T/c16" '"best_wpm":0[,}]'
check "empty session logs no record (§3)"     "$T/c16" '"sessions_count":0[,}]'

# ── 13. Export to an impossible path fails gracefully (no E739) ────────────
run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ExportBundle('$T/c3/sub/bundle.json'))], '$T/c17')"
check "unwritable export path reports failure" "$T/c17" 'Failed to write'

# ── 14. Resume picker + session recap ──────────────────────────────────────
mkdir -p "$T/homeP/.vim/gutenberg-typist/sessions" \
         "$T/homeP/.vim/gutenberg-typist/books/11" "$T/homeP/.vim/gutenberg-typist/books/22"
echo '{"id":11,"title":"Alice in Wonderland","author":"Carroll"}' \
  > "$T/homeP/.vim/gutenberg-typist/books/11/metadata.json"
echo '{"id":22,"title":"Moby Dick","author":"Melville"}' \
  > "$T/homeP/.vim/gutenberg-typist/books/22/metadata.json"
printf 'a%.0s' $(seq 100) > "$T/homeP/.vim/gutenberg-typist/books/11/text.txt"
printf 'b%.0s' $(seq 200) > "$T/homeP/.vim/gutenberg-typist/books/22/text.txt"
echo '{"book_id":11,"offset":25,"last_active":1718199000}' \
  > "$T/homeP/.vim/gutenberg-typist/sessions/11.json"
echo '{"book_id":22,"offset":100,"last_active":1718299000}' \
  > "$T/homeP/.vim/gutenberg-typist/sessions/22.json"

run_vim "$T/homeP" machP \
  "runtime plugin/gt.vim" \
  "GT resume" \
  "call writefile(getbufline(winbufnr(popup_list()[0]), 1, '\$'), '$T/c18')"
check "resume picker lists cached titles"     "$T/c18" 'Alice in Wonderland — Carroll \(25%'
check "picker shows progress from text size"  "$T/c18" 'Moby Dick — Melville \(50%'
head -1 "$T/c18" > "$T/c19" 2>/dev/null
check "picker sorts most-recent first"        "$T/c19" 'Moby Dick'

run_vim "$T/homeP" machP \
  "runtime plugin/gt.vim" \
  "redir! > $T/c20" \
  "call gt#engine#Start(7, repeat('abcdef ', 200), 0) | call setbufline(gt#ui#GetState().typing_buf, 1, 'abcdef') | call gt#engine#OnTextChanged() | sleep 150m | call setbufline(gt#ui#GetState().typing_buf, 1, 'abcdef abcdef') | call gt#engine#OnTextChanged() | call gt#engine#Stop()" \
  "redir END"
check "stop recap reports wpm/accuracy/chars" "$T/c20" 'Session saved — [0-9]+ wpm · 100.0% accuracy · 13 chars · [0-9]+ sec'

# ── 15. :GT publish posts the bundle to the guild ──────────────────────────
STUB_PORT=$((20000 + RANDOM % 20000))
python3 test/hub_stub.py "$STUB_PORT" "$T/hub-capture" &
STUB_PID=$!
sleep 0.3
run_vim "$T/homeA" machA \
  "runtime plugin/gt.vim" \
  "let g:gt_hub_url='http://127.0.0.1:$STUB_PORT'" \
  "let g:gt_hub_token='gt_testtoken'" \
  "redir! > $T/c21" \
  "GT publish" \
  "let i=0 | while i < 50 && !exists('g:gt_hub_last') | sleep 100m | let i+=1 | endwhile" \
  "redir END"
kill "$STUB_PID" 2>/dev/null
check "publish sends the bearer token"        "$T/hub-capture" '^AUTH:Bearer gt_testtoken$'
check "publish posts a schema-1 bundle"       "$T/hub-capture" '"schema":1'
check "publish body carries session records"  "$T/hub-capture" '"machA"'
check "publish echoes rank + new sessions"    "$T/c21" 'Published 3 new session\(s\) — #1 of 3 \(best 72 wpm\)'
run_vim "$T/homeA" machA \
  "runtime plugin/gt.vim" \
  "redir! > $T/c22" \
  "GT publish" \
  "redir END"
check "publish without token points at account" "$T/c22" 'Set g:gt_hub_token first'

echo
echo "=== $PASS passed, $FAIL failed (work dir: $T) ==="
[ "$FAIL" -eq 0 ]
