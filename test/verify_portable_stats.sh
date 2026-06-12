#!/usr/bin/env bash
# Headless verification of :GT export/import (portable stats).
# Simulates two machines with sandboxed $HOMEs on one host, using
# g:gt_machine_id to give each a distinct identity.
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

# ── 1. Seed machine A with LEGACY flat-format stats + one session ──────────
mkdir -p "$T/homeA/.vim/gutenberg-typist/sessions"
echo '{"total_chars":1000,"correct_chars":900,"total_time_seconds":120.5,"sessions_count":3}' \
  > "$T/homeA/.vim/gutenberg-typist/lifetime_stats.json"
echo '{"book_id":4300,"offset":1847,"total_chars_typed":1847,"correct_chars":1742,"last_active":1718199000}' \
  > "$T/homeA/.vim/gutenberg-typist/sessions/4300.json"

run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ExportBundle('$T/bundle-a.json'))], '$T/c1')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c2')"
check "export succeeds from legacy data"        "$T/c1" '"ok":true'
check "export migrates legacy record to machA"  "$T/bundle-a.json" '"machA"'
check "bundle carries the session"              "$T/bundle-a.json" '"offset":1847'
check "aggregate sums migrated chars"           "$T/c2" '"total_chars":1000'
check "legacy float seconds rounded to int"     "$T/c2" '"total_time_seconds":121'

# ── 2. Import on B twice: idempotence ───────────────────────────────────────
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-a.json')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c3')"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-a.json')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c4')"
check "import lands machA stats on B"           "$T/c3" '"total_chars":1000'
if diff -q "$T/c3" "$T/c4" >/dev/null 2>&1; then
  echo "PASS: double import is idempotent"; PASS=$((PASS+1))
else
  echo "FAIL: double import changed aggregates"; diff "$T/c3" "$T/c4"; FAIL=$((FAIL+1))
fi

# Session arrives with original last_active (import must not re-stamp it)
check "session imported on B"                   "$T/homeB/.vim/gutenberg-typist/sessions/4300.json" '"offset":1847'
check "imported last_active preserved"          "$T/homeB/.vim/gutenberg-typist/sessions/4300.json" '"last_active":1718199000'

# ── 3. Type on B, cross-sync, re-import stale bundle: max-not-sum ──────────
run_vim "$T/homeB" machB \
  "call gt#storage#AddLifetimeDeltas({'total_chars':500,'correct_chars':450,'total_time_seconds':60,'sessions_count':1,'best_wpm':62})" \
  "call gt#storage#ExportBundle('$T/bundle-b.json')"
run_vim "$T/homeA" machA \
  "call gt#storage#ImportBundle('$T/bundle-b.json')" \
  "call gt#storage#ImportBundle('$T/bundle-a.json')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c5')"
check "A sees both machines' chars (1000+500)"  "$T/c5" '"total_chars":1500'
check "stale own-snapshot re-import is a no-op" "$T/c5" '"sessions_count":4'
check "best_wpm max-merges across machines"     "$T/c5" '"best_wpm":62'
check "machines_count reflects both"            "$T/c5" '"machines_count":2'

# ── 4. Malformed input never corrupts local data ────────────────────────────
echo 'not json' > "$T/bad.json"
echo '{"format_version":99,"machines":{},"sessions":{}}' > "$T/future.json"
cp "$T/homeA/.vim/gutenberg-typist/lifetime_stats.json" "$T/stats-before"
run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ImportBundle('$T/bad.json')), json_encode(gt#storage#ImportBundle('$T/future.json'))], '$T/c6')"
check "malformed file rejected"                 "$T/c6" 'Cannot read or parse'
check "future format_version rejected"          "$T/c6" 'not supported'
if cmp -s "$T/stats-before" "$T/homeA/.vim/gutenberg-typist/lifetime_stats.json"; then
  echo "PASS: rejected imports leave stats untouched"; PASS=$((PASS+1))
else
  echo "FAIL: rejected import modified lifetime_stats.json"; FAIL=$((FAIL+1))
fi

# ── 5. Export with no data refuses to write ─────────────────────────────────
run_vim "$T/homeC" machC \
  "call writefile([json_encode(gt#storage#ExportBundle('$T/bundle-c.json'))], '$T/c7')"
check "empty export refused"                    "$T/c7" 'No stats to export yet'
if [ ! -e "$T/bundle-c.json" ]; then
  echo "PASS: no bundle file written for empty export"; PASS=$((PASS+1))
else
  echo "FAIL: empty export wrote a file"; FAIL=$((FAIL+1))
fi

# ── 6. Session merge policy: newer last_active wins ─────────────────────────
# B's 4300 session came from bundle-a (last_active 1718199000). An incoming
# record with NEWER last_active must replace it, even at a lower offset
# (e.g. the book was reset and restarted on the other machine).
echo '{"format_version":1,"exported_from":"machA","exported_at":1718300000,"machines":{},"sessions":{"4300":{"book_id":4300,"offset":120,"total_chars_typed":2500,"correct_chars":2400,"last_active":1718299000}}}' \
  > "$T/bundle-newer.json"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-newer.json')" \
  "call writefile(readfile('$T/homeB/.vim/gutenberg-typist/sessions/4300.json'), '$T/c8')"
check "newer incoming session wins"             "$T/c8" '"offset":120'
check "winner keeps its own last_active"        "$T/c8" '"last_active":1718299000'

# An incoming record with OLDER last_active must be ignored.
echo '{"format_version":1,"exported_from":"machA","exported_at":1718300001,"machines":{},"sessions":{"4300":{"book_id":4300,"offset":9999,"total_chars_typed":9999,"correct_chars":9999,"last_active":1718100000}}}' \
  > "$T/bundle-stale.json"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-stale.json')" \
  "call writefile(readfile('$T/homeB/.vim/gutenberg-typist/sessions/4300.json'), '$T/c8b')"
check "older incoming session ignored"          "$T/c8b" '"offset":120'

# ── 6b. Malicious session keys must not escape the sessions dir ────────────
echo '{"format_version":1,"machines":{},"sessions":{"../../evil":{"book_id":1,"offset":5,"last_active":1}}}' \
  > "$T/bundle-evil.json"
run_vim "$T/homeB" machB \
  "call gt#storage#ImportBundle('$T/bundle-evil.json')"
if [ ! -e "$T/homeB/.vim/evil.json" ] && [ ! -e "$T/homeB/.vim/gutenberg-typist/evil.json" ]; then
  echo "PASS: path-traversal session key ignored"; PASS=$((PASS+1))
else
  echo "FAIL: malicious session key escaped sessions dir"; FAIL=$((FAIL+1))
fi

# ── 7. Completion + plugin load smoke tests ─────────────────────────────────
run_vim "$T/homeA" machA \
  "runtime plugin/gt.vim" \
  "call writefile([exists(':GT') == 2 ? 'cmd-ok' : 'cmd-missing', string(gt#Complete('ex', 'GT ex', 5)), len(gt#Complete('', 'GT export ', 10)) > 0 ? 'file-completion-ok' : 'file-completion-empty', string(gt#Complete('', 'GT start ', 9))], '$T/c9')"
check "plugin loads, :GT defined"               "$T/c9" 'cmd-ok'
check "subcommand completion includes export"   "$T/c9" "'export'"
check "file completion for export arg"          "$T/c9" 'file-completion-ok'
grep -q "'search'" <(sed -n '4p' "$T/c9") && { echo "FAIL: ':GT start ' re-offers subcommands"; FAIL=$((FAIL+1)); } \
  || { echo "PASS: ':GT start ' offers no subcommands"; PASS=$((PASS+1)); }

# ── 8. Float counters in a bundle are rounded, never persisted as floats ───
mkdir -p "$T/homeF"
echo '{"format_version":1,"machines":{"other":{"total_chars":1500.0,"correct_chars":1400.0,"total_time_seconds":120.5,"sessions_count":2.0,"best_wpm":55.5}},"sessions":{}}' \
  > "$T/bundle-float.json"
run_vim "$T/homeF" machF \
  "call gt#storage#ImportBundle('$T/bundle-float.json')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c11')" \
  "try | call gt#Command('stats') | call writefile(['stats-ok'], '$T/c12') | catch | call writefile(['stats-threw: ' . v:exception], '$T/c12') | endtry"
check "float counters rounded to integers"      "$T/c11" '"total_chars":1500[,}]'
check "no floats persisted on disk"             "$T/homeF/.vim/gutenberg-typist/lifetime_stats.json" '"total_chars":1500[,}]'
check ":GT stats survives imported floats"      "$T/c12" 'stats-ok'

# ── 9. Non-numeric counter values are dropped; session-end still saves ─────
mkdir -p "$T/homeG"
echo '{"format_version":1,"machines":{"machG":{"best_wpm":{"x":1},"total_chars":50}},"sessions":{}}' \
  > "$T/bundle-poison.json"
run_vim "$T/homeG" machG \
  "call gt#storage#ImportBundle('$T/bundle-poison.json')" \
  "call gt#storage#AddLifetimeDeltas({'total_chars':500,'correct_chars':450,'total_time_seconds':60,'sessions_count':1,'best_wpm':42})" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c13')"
check "dict counter dropped, numeric kept"      "$T/c13" '"total_chars":550[,}]'
check "session-end save survives poisoned file" "$T/c13" '"best_wpm":42[,}]'

# ── 10. Imported session values are sanitized ──────────────────────────────
echo '{"format_version":1,"machines":{},"sessions":{"111":{"book_id":111,"offset":"99"},"222":{"book_id":222,"offset":{"x":1}},"333":{"book_id":999,"offset":10,"last_active":"abc","total_chars_typed":5}}}' \
  > "$T/bundle-badsess.json"
run_vim "$T/homeG" machG \
  "call gt#storage#ImportBundle('$T/bundle-badsess.json')"
SESS="$T/homeG/.vim/gutenberg-typist/sessions"
if [ ! -e "$SESS/111.json" ] && [ ! -e "$SESS/222.json" ]; then
  echo "PASS: non-numeric offsets rejected"; PASS=$((PASS+1))
else
  echo "FAIL: session with junk offset was written"; FAIL=$((FAIL+1))
fi
check "book_id forced to match dict key"        "$SESS/333.json" '"book_id":333[,}]'
if grep -q 'last_active' "$SESS/333.json" 2>/dev/null; then
  echo "FAIL: non-numeric last_active kept"; FAIL=$((FAIL+1))
else
  echo "PASS: non-numeric last_active dropped"; PASS=$((PASS+1))
fi

# ── 11. Legacy fold is persisted once; id change cannot double-count ───────
mkdir -p "$T/homeE/.vim/gutenberg-typist"
echo '{"total_chars":1000,"correct_chars":900,"total_time_seconds":120,"sessions_count":3}' \
  > "$T/homeE/.vim/gutenberg-typist/lifetime_stats.json"
run_vim "$T/homeE" machE1 \
  "call gt#storage#ExportBundle('$T/bundle-e.json')"
check "legacy fold persisted by read-only op"   "$T/homeE/.vim/gutenberg-typist/lifetime_stats.json" '"machE1"'
run_vim "$T/homeE" machE2 \
  "call gt#storage#ImportBundle('$T/bundle-e.json')" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c14')"
check "id change + self-import: no double count" "$T/c14" '"total_chars":1000[,}]'
check "id change keeps a single machine record"  "$T/c14" '"machines_count":1[,}]'

# ── 12. Export to an impossible path fails gracefully (no E739) ────────────
run_vim "$T/homeA" machA \
  "call writefile([json_encode(gt#storage#ExportBundle('$T/c1/sub/bundle.json'))], '$T/c15')"
check "unwritable export path reports failure"  "$T/c15" 'Failed to write'

# ── 13. Resume must not credit the pre-typed prefix ────────────────────────
mkdir -p "$T/homeD"
run_vim "$T/homeD" machD \
  "runtime plugin/gt.vim" \
  "call gt#engine#Start(7, repeat('abcdef ', 200), 350)" \
  "call gt#engine#OnTextChanged()" \
  "call gt#engine#Stop()" \
  "call writefile([json_encode(gt#storage#LoadLifetimeStats())], '$T/c16')"
check "resume prefix not counted as typed"      "$T/c16" '"total_chars":0[,}]'
check "resume produces no fluke best_wpm"       "$T/c16" '"best_wpm":0[,}]'
check "resumed session still counted"           "$T/c16" '"sessions_count":1[,}]'

echo
echo "=== $PASS passed, $FAIL failed (work dir: $T) ==="
[ "$FAIL" -eq 0 ]
