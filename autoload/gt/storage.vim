let s:base_dir = ''

function! s:GetBaseDir() abort
  if s:base_dir ==# ''
    let l:override = get(g:, 'gt_data_dir', '')
    let s:base_dir = type(l:override) == v:t_string && l:override !=# ''
          \ ? expand(l:override) : expand('~/.vim/gutenberg-typist')
  endif
  return s:base_dir
endfunction

" Machine identity for per-machine stat records. g:gt_machine_id also serves
" as a pseudonym for users who share export bundles publicly.
function! gt#storage#MachineId() abort
  let l:id = get(g:, 'gt_machine_id', '')
  if type(l:id) == v:t_string && l:id !=# ''
    return l:id
  endif
  let l:host = hostname()
  return l:host !=# '' ? l:host : 'unknown'
endfunction

function! s:IsNum(v) abort
  return type(a:v) == v:t_number || type(a:v) == v:t_float
endfunction

" Tolerant read of a counter that may have been poisoned by a hand-edited
" file or a pre-sanitization import: anything non-numeric counts as 0.
function! s:NumOr0(v) abort
  return s:IsNum(a:v) ? a:v : 0
endfunction

" json_encode writes Floats at ~6 significant digits, so large accumulated
" values can shrink on round-trip, breaking the only-grows guarantee the
" import merge relies on. Keep accumulated seconds integral.
function! s:NormalizeSeconds(v) abort
  return type(a:v) == v:t_float ? float2nr(round(a:v)) : a:v
endfunction

function! s:EnsureDir(path) abort
  if !isdirectory(a:path)
    call mkdir(a:path, 'p')
  endif
endfunction

function! s:ReadJson(path) abort
  if !filereadable(a:path)
    return v:null
  endif
  try
    let l:content = join(readfile(a:path), "\n")
    if l:content ==# ''
      return v:null
    endif
    return json_decode(l:content)
  catch
    return v:null
  endtry
endfunction

let s:temp_counter = 0
function! s:AtomicWrite(path, lines, flags) abort
  let s:temp_counter += 1
  let l:tmp = a:path . '.tmp.' . getpid() . '.' . s:temp_counter
  try
    " EnsureDir inside the try: mkdir throws E739 when a path component
    " is an existing file or the parent is unwritable.
    call s:EnsureDir(fnamemodify(a:path, ':h'))
    if writefile(a:lines, l:tmp, a:flags) != 0
      throw 'temporary write failed'
    endif
    if rename(l:tmp, a:path) != 0
      throw 'atomic rename failed'
    endif
    return v:true
  catch
    call delete(l:tmp)
    echomsg 'GT: Failed to save ' . a:path . ': ' . v:exception
    return v:false
  endtry
endfunction

function! s:WriteJson(path, data) abort
  try
    return s:AtomicWrite(a:path, [json_encode(a:data)], '')
  catch
    echomsg 'GT: Failed to save ' . a:path . ': ' . v:exception
    return v:false
  endtry
endfunction

function! s:ReadFile(path) abort
  if !filereadable(a:path)
    return v:null
  endif
  return join(readfile(a:path, 'b'), "\n")
endfunction

function! s:WriteFile(path, content) abort
  return s:AtomicWrite(a:path, split(a:content, "\n", 1), 'b')
endfunction

" Book text

function! s:BookDir(book_id) abort
  return s:GetBaseDir() . '/books/' . a:book_id
endfunction

function! gt#storage#SaveBookText(book_id, text) abort
  return s:WriteFile(s:BookDir(a:book_id) . '/text.txt', a:text)
endfunction

function! gt#storage#LoadBookText(book_id) abort
  return s:ReadFile(s:BookDir(a:book_id) . '/text.txt')
endfunction

function! gt#storage#SaveBookMetadata(book_id, metadata) abort
  return s:WriteJson(s:BookDir(a:book_id) . '/metadata.json', a:metadata)
endfunction

function! gt#storage#LoadBookMetadata(book_id) abort
  return s:ReadJson(s:BookDir(a:book_id) . '/metadata.json')
endfunction

" Byte size of the cached text, -1 if not cached. Cheap progress-% proxy:
" session offsets are byte offsets into this same file.
function! gt#storage#BookTextSize(book_id) abort
  return getfsize(s:BookDir(a:book_id) . '/text.txt')
endfunction

" Sessions

function! s:SessionPath(book_id) abort
  return s:GetBaseDir() . '/sessions/' . a:book_id . '.json'
endfunction

function! gt#storage#SaveSession(book_id, session) abort
  let a:session.last_active = localtime()
  return s:WriteJson(s:SessionPath(a:book_id), a:session)
endfunction

function! gt#storage#LoadSession(book_id) abort
  return s:ReadJson(s:SessionPath(a:book_id))
endfunction


" Lifetime stats
"
" On-disk format v2 keeps one record per machine:
"   {'format_version': 2, 'machines': {'<machine-id>': {counters...}}}
" Records are maps of numeric counters that only ever grow on their own
" machine, so merging two snapshots of the same machine is field-wise max.

function! s:StatsPath() abort
  return s:GetBaseDir() . '/lifetime_stats.json'
endfunction

function! s:EmptyCounters() abort
  return {
        \ 'total_chars': 0,
        \ 'correct_chars': 0,
        \ 'corrections': 0,
        \ 'total_time_seconds': 0,
        \ 'sessions_count': 0,
        \}
endfunction

function! s:LoadLifetimeV2() abort
  let l:data = s:ReadJson(s:StatsPath())
  if type(l:data) != v:t_dict
    return {'format_version': 2, 'machines': {}}
  endif
  let l:legacy = !has_key(l:data, 'machines') && has_key(l:data, 'total_chars')
  if has_key(l:data, 'machines') && type(l:data.machines) == v:t_dict
    let l:data.format_version = 2
  elseif l:legacy
    " Pre-v2 flat record: fold into this machine's entry
    let l:data = {'format_version': 2, 'machines': {gt#storage#MachineId(): l:data}}
  else
    return {'format_version': 2, 'machines': {}}
  endif
  for l:rec in values(l:data.machines)
    if type(l:rec) == v:t_dict && has_key(l:rec, 'total_time_seconds')
      let l:rec.total_time_seconds = s:NormalizeSeconds(l:rec.total_time_seconds)
    endif
  endfor
  if l:legacy
    " Persist immediately so the fold happens exactly once; deferring it
    " would re-attribute the same history if the machine id later changes
    " (g:gt_machine_id set, hostname changed), double-counting on import.
    call s:SaveLifetimeV2(l:data)
  endif
  return l:data
endfunction

function! s:SaveLifetimeV2(data) abort
  return s:WriteJson(s:StatsPath(), a:data)
endfunction

" Session log (SPEC.md schema 1)
"
" The local source of truth is an append-only array of immutable session
" records at session_log.json. Everything else — :GT stats, export,
" publish — derives from it. The legacy counter file is migrated into
" the log exactly once (§9) and then renamed out of the way.

let s:GENERATOR = 'gutenberg-typist/0.5.0'

function! s:LogPath() abort
  return s:GetBaseDir() . '/session_log.json'
endfunction

function! s:RawLog() abort
  let l:data = s:ReadJson(s:LogPath())
  return type(l:data) == v:t_list ? l:data : []
endfunction

" One-time v0 counter migration (SPEC §9): one legacy record per machine,
" carrying the original counters verbatim; then the counter file is renamed
" so migration can never run twice. Runs only on the machine that owns the
" counters — v0 *bundles* are refused by ImportBundle for the same reason.
let s:migrated = 0
function! s:EnsureMigrated() abort
  if s:migrated
    return
  endif
  let l:stats_path = s:StatsPath()
  if !filereadable(l:stats_path)
    let s:migrated = 1
    return
  endif
  let l:log = s:RawLog()
  let l:existing = {}
  for l:record in l:log
    if type(l:record) == v:t_dict && type(get(l:record, 'id', 0)) == v:t_string
      let l:existing[l:record.id] = 1
    endif
  endfor
  let l:today = strftime('%Y-%m-%d')
  let l:changed = 0
  for [l:id, l:rec] in items(s:LoadLifetimeV2().machines)
    if type(l:rec) != v:t_dict
      continue
    endif
    let l:chars = s:NumOr0(get(l:rec, 'total_chars', 0))
    let l:correct = s:NumOr0(get(l:rec, 'correct_chars', 0))
    let l:secs = s:NormalizeSeconds(s:NumOr0(get(l:rec, 'total_time_seconds', 0)))
    let l:id_uuid = gt#util#LegacyUuid(l:id)
    if has_key(l:existing, l:id_uuid)
      continue
    endif
    call add(l:log, {
          \ 'id': l:id_uuid,
          \ 'machine': l:id,
          \ 'date': l:today,
          \ 'legacy': v:true,
          \ 'legacy_counters': l:rec,
          \ 'active_ms': l:secs * 1000,
          \ 'wall_ms': l:secs * 1000,
          \ 'chars_typed': l:chars,
          \ 'errors_uncorrected': l:chars > l:correct ? l:chars - l:correct : 0,
          \})
    let l:existing[l:id_uuid] = 1
    let l:changed = 1
  endfor
  if l:changed && !s:WriteJson(s:LogPath(), l:log)
    return
  endif
  if rename(l:stats_path, l:stats_path . '.v0') != 0
    echomsg 'GT: Legacy counters were imported but could not be retired; migration will retry.'
    return
  endif
  let s:migrated = 1
endfunction

function! gt#storage#LoadSessionLog() abort
  call s:EnsureMigrated()
  return s:RawLog()
endfunction

function! gt#storage#AppendSessionRecord(record) abort
  call s:EnsureMigrated()
  let l:log = s:RawLog()
  call add(l:log, a:record)
  " ponytail: whole-file rewrite per session; years of use is a few
  " thousand ~200-byte records, revisit if it ever hurts.
  return s:WriteJson(s:LogPath(), l:log)
endfunction

" Sorted-keys, no-whitespace JSON — record identity for the §4 immutability
" check. Mirrors canonicalJson in typist-guild's src/bundle.ts.
function! s:CanonicalJson(val) abort
  let l:t = type(a:val)
  if l:t == v:t_dict
    let l:parts = []
    for l:key in sort(copy(keys(a:val)))
      call add(l:parts, json_encode(l:key) . ':' . s:CanonicalJson(a:val[l:key]))
    endfor
    return '{' . join(l:parts, ',') . '}'
  elseif l:t == v:t_list
    return '[' . join(map(copy(a:val), 's:CanonicalJson(v:val)'), ',') . ']'
  endif
  return json_encode(a:val)
endfunction

" Aggregate lifetime view for :GT stats, derived from the session log.
" Flat counter shape kept so the stats popup needs no changes. Legacy
" records contribute their preserved v0 counters where they can.
function! gt#storage#LoadLifetimeStats() abort
  let l:agg = s:EmptyCounters()
  let l:agg.best_wpm = 0
  let l:machines = {}
  let l:best = 0.0
  for l:rec in gt#storage#LoadSessionLog()
    if type(l:rec) != v:t_dict
      continue
    endif
    let l:chars = s:NumOr0(get(l:rec, 'chars_typed', 0))
    let l:errors = s:NumOr0(get(l:rec, 'errors_uncorrected', 0))
    let l:corrections = s:NumOr0(get(l:rec, 'corrections', 0))
    let l:active = s:NumOr0(get(l:rec, 'active_ms', 0))
    let l:agg.total_chars += l:chars
    let l:agg.correct_chars += l:chars > l:errors ? l:chars - l:errors : 0
    let l:agg.corrections += l:corrections
    let l:agg.total_time_seconds += l:active / 1000.0
    let l:machines[get(l:rec, 'machine', '?')] = 1
    if get(l:rec, 'legacy', v:false)
      let l:lc = get(l:rec, 'legacy_counters', {})
      let l:n = type(l:lc) == v:t_dict ? s:NumOr0(get(l:lc, 'sessions_count', 1)) : 1
      let l:agg.sessions_count += l:n > 0 ? l:n : 1
      let l:lb = type(l:lc) == v:t_dict ? s:NumOr0(get(l:lc, 'best_wpm', 0)) : 0
      if l:lb * 1.0 > l:best
        let l:best = l:lb * 1.0
      endif
    else
      let l:agg.sessions_count += 1
      " Same consumer rule as the guild: sub-10s flukes never set bests.
      if l:active >= 10000 && l:chars > 0
        let l:wpm = (l:chars / 5.0) / (l:active / 60000.0)
        if l:wpm > l:best
          let l:best = l:wpm
        endif
      endif
    endif
  endfor
  let l:agg.best_wpm = float2nr(round(l:best))
  let l:agg.machines_count = len(l:machines)
  return l:agg
endfunction

" Portable export/import (SPEC.md schema 1)
"
" A bundle is {'schema': 1, 'generator': ..., 'sessions': [records...]}
" plus 'gt_progress', a plugin-private extension carrying per-book resume
" offsets (unknown top-level fields are legal per SPEC §2 — the guild
" ignores it, other plugin instances use it for cross-machine resume).
" Import is set union by record id: idempotent by construction, and a
" record that changed content under the same id aborts the whole import.

function! gt#storage#ListSessions() abort
  let l:sessions_dir = s:GetBaseDir() . '/sessions'
  if !isdirectory(l:sessions_dir)
    return {}
  endif
  let l:result = {}
  for l:file in glob(l:sessions_dir . '/*.json', 0, 1)
    let l:data = s:ReadJson(l:file)
    if l:data isnot v:null
      let l:result[fnamemodify(l:file, ':t:r')] = l:data
    endif
  endfor
  return l:result
endfunction

function! gt#storage#ExportBundle(path) abort
  let l:log = gt#storage#LoadSessionLog()
  let l:progress = gt#storage#ListSessions()
  if empty(l:log) && empty(l:progress)
    return {'ok': v:false, 'msg': 'No stats to export yet'}
  endif
  " Only closed sessions are in the log, so the SPEC §3 closed-sessions
  " rule holds by construction. No 'user' field: the upload token carries
  " identity (§2).
  let l:bundle = {
        \ 'schema': 1,
        \ 'generator': s:GENERATOR,
        \ 'sessions': l:log,
        \ 'gt_progress': l:progress,
        \}
  if !s:WriteJson(a:path, l:bundle)
    return {'ok': v:false, 'msg': 'Failed to write ' . a:path}
  endif
  return {'ok': v:true, 'msg': printf('Exported %d session record(s), %d book(s) in progress to %s',
        \ len(l:log), len(l:progress), a:path)}
endfunction

" Sessions in a bundle are untrusted: keep only the known numeric fields,
" force book_id to agree with the dict key (the key decides the filename),
" and reject records without a sane offset.
function! s:SanitizeSession(book_id, incoming) abort
  if type(get(a:incoming, 'offset', '')) != v:t_number || a:incoming.offset < 0
    return v:null
  endif
  let l:clean = {'book_id': str2nr(a:book_id), 'offset': a:incoming.offset}
  for l:key in ['total_chars_typed', 'correct_chars', 'last_active']
    if type(get(a:incoming, l:key, '')) == v:t_number
      let l:clean[l:key] = a:incoming[l:key]
    endif
  endfor
  return l:clean
endfunction

function! s:IsSchema1Record(rec) abort
  if type(a:rec) != v:t_dict || type(get(a:rec, 'id', 0)) != v:t_string
        \ || a:rec.id !~# '^\x\{8}-\x\{4}-\x\{4}-\x\{4}-\x\{12}$'
        \ || type(get(a:rec, 'machine', 0)) != v:t_string || a:rec.machine ==# ''
        \ || type(get(a:rec, 'date', 0)) != v:t_string
        \ || a:rec.date !~# '^\d\{4}-\d\{2}-\d\{2}$'
    return 0
  endif
  for l:key in ['active_ms', 'wall_ms', 'chars_typed', 'errors_uncorrected']
    if type(get(a:rec, l:key, v:null)) != v:t_number || a:rec[l:key] < 0
      return 0
    endif
  endfor
  if a:rec.active_ms > a:rec.wall_ms || a:rec.errors_uncorrected > a:rec.chars_typed
    return 0
  endif
  if has_key(a:rec, 'corrections') && (type(a:rec.corrections) != v:t_number || a:rec.corrections < 0)
    return 0
  endif
  if has_key(a:rec, 'legacy') && type(a:rec.legacy) != v:t_bool
    return 0
  endif
  if has_key(a:rec, 'range')
    let l:range = a:rec.range
    if type(l:range) != v:t_dict || type(get(l:range, 'start', v:null)) != v:t_number
          \ || type(get(l:range, 'end', v:null)) != v:t_number
          \ || l:range.start < 0 || l:range.end < l:range.start
      return 0
    endif
  endif
  if get(a:rec, 'legacy', v:false)
    return type(get(a:rec, 'legacy_counters', v:null)) == v:t_dict
  endif
  let l:book = get(a:rec, 'book', v:null)
  return type(l:book) == v:t_dict && type(get(l:book, 'gutenberg_id', v:null)) == v:t_number
        \ && l:book.gutenberg_id > 0
endfunction

function! gt#storage#ImportBundle(path) abort
  let l:bundle = s:ReadJson(a:path)
  if l:bundle is v:null
    return {'ok': v:false, 'msg': 'Cannot read or parse ' . a:path}
  endif
  if type(l:bundle) != v:t_dict
    return {'ok': v:false, 'msg': 'Not a gutenberg-typist export bundle: ' . a:path}
  endif
  if has_key(l:bundle, 'format_version')
    " SPEC §9: v0 counter bundles migrate only on their owning machine —
    " migrating a stale copy here would mint the same deterministic id
    " with different totals, the one conflict §4 forbids.
    return {'ok': v:false, 'msg':
          \ 'v0 counter bundle — update gutenberg-typist on the exporting machine and re-export'}
  endif
  let l:schema = get(l:bundle, 'schema', v:null)
  if type(l:schema) != v:t_number || l:schema != 1
        \ || type(get(l:bundle, 'sessions', 0)) != v:t_list
    if type(l:schema) == v:t_number && l:schema > 1
      return {'ok': v:false, 'msg': printf(
            \ 'Bundle schema %d not supported — update gutenberg-typist', l:schema)}
    endif
    return {'ok': v:false, 'msg': 'Not a schema-1 bundle: ' . a:path}
  endif
  if has_key(l:bundle, 'gt_progress') && type(l:bundle.gt_progress) != v:t_dict
    return {'ok': v:false, 'msg': 'Invalid gt_progress object in bundle'}
  endif
  for l:record in l:bundle.sessions
    if !s:IsSchema1Record(l:record)
      return {'ok': v:false, 'msg': 'Invalid schema-1 session record in bundle'}
    endif
  endfor

  call s:EnsureMigrated()
  let l:log = s:RawLog()
  let l:by_id = {}
  for l:rec in l:log
    if type(l:rec) == v:t_dict && type(get(l:rec, 'id', 0)) == v:t_string
      let l:by_id[l:rec.id] = s:CanonicalJson(l:rec)
    endif
  endfor
  let l:added = 0
  let l:conflicts = []
  for l:rec in l:bundle.sessions
    if type(l:rec) != v:t_dict || type(get(l:rec, 'id', 0)) != v:t_string
          \ || get(l:rec, 'id', '') ==# ''
      continue
    endif
    if has_key(l:by_id, l:rec.id)
      if l:by_id[l:rec.id] !=# s:CanonicalJson(l:rec)
        call add(l:conflicts, l:rec.id)
      endif
      continue
    endif
    call add(l:log, l:rec)
    let l:by_id[l:rec.id] = s:CanonicalJson(l:rec)
    let l:added += 1
  endfor
  if !empty(l:conflicts)
    " Abort before writing anything: records are immutable (§4).
    return {'ok': v:false, 'msg': 'Import aborted — record content changed for id(s) '
          \ . join(l:conflicts, ', ') . ' (session records are immutable; nothing was imported)'}
  endif
  if l:added > 0 && !s:WriteJson(s:LogPath(), l:log)
    return {'ok': v:false, 'msg': 'Failed to save merged session log'}
  endif

  let l:imported_books = 0
  for [l:book_id, l:incoming] in items(get(l:bundle, 'gt_progress', {}))
    " Numeric keys only: the id becomes a filename, so anything else
    " (e.g. '../x') could escape the sessions directory.
    if l:book_id !~# '^\d\+$' || type(l:incoming) != v:t_dict
      continue
    endif
    let l:clean = s:SanitizeSession(l:book_id, l:incoming)
    if l:clean is v:null
      continue
    endif
    let l:merged = gt#storage#MergeSession(gt#storage#LoadSession(l:book_id), l:clean)
    if l:merged isnot v:null
      " Write directly rather than via SaveSession, which would re-stamp
      " last_active and make every imported record look brand-new.
      if !s:WriteJson(s:SessionPath(l:book_id), l:merged)
        return {'ok': v:false, 'msg': 'Failed to save progress for book ' . l:book_id}
      endif
      let l:imported_books += 1
    endif
  endfor

  return {'ok': v:true, 'msg': printf('Merged %d new session record(s), %d book progress update(s) from %s',
        \ l:added, l:imported_books, a:path)}
endfunction

" Decides what happens when an imported bundle contains progress for a book
" that also has local progress. Called once per book in the bundle.
"
"   a:local     existing local session dict, or v:null when the book has no
"               local progress yet
"   a:incoming  session dict from the bundle: {book_id, offset,
"               total_chars_typed, correct_chars, last_active}
"
" Returns the dict to persist, or v:null to keep the local record untouched.
"
" Policy: newer last_active wins. The most recent action on any machine is
" what the user meant — including a deliberate Reset that wiped progress.
" The cost is trusting machine clocks to be roughly in sync; an alternative
" (higher offset wins) would survive clock skew but resurrect reset books.
" Ties keep the local record, which makes re-importing a bundle a no-op.
function! gt#storage#MergeSession(local, incoming) abort
  if a:local is v:null
    return a:incoming
  endif
  if get(a:incoming, 'last_active', 0) > get(a:local, 'last_active', 0)
    return a:incoming
  endif
  return v:null
endfunction

" List cached books

function! gt#storage#ListCachedBooks() abort
  let l:books_dir = s:GetBaseDir() . '/books'
  if !isdirectory(l:books_dir)
    return []
  endif
  let l:dirs = glob(l:books_dir . '/*', 0, 1)
  let l:books = []
  for l:dir in l:dirs
    let l:id = fnamemodify(l:dir, ':t')
    let l:meta = gt#storage#LoadBookMetadata(l:id)
    if l:meta isnot v:null
      let l:meta.id = l:id
      call add(l:books, l:meta)
    endif
  endfor
  return l:books
endfunction
