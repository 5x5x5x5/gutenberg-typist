let s:base_dir = ''

function! s:GetBaseDir() abort
  if s:base_dir ==# ''
    let s:base_dir = expand('~/.vim/gutenberg-typist')
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

" Vim's max() rejects Floats (E892); '>' compares Number/Float mixes fine.
function! s:NumMax(a, b) abort
  return a:a > a:b ? a:a : a:b
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

function! s:WriteJson(path, data) abort
  try
    " EnsureDir inside the try: mkdir throws E739 when a path component
    " is an existing file or the parent is unwritable.
    call s:EnsureDir(fnamemodify(a:path, ':h'))
    let l:encoded = json_encode(a:data)
    call writefile([l:encoded], a:path)
    return v:true
  catch
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
  call s:EnsureDir(fnamemodify(a:path, ':h'))
  call writefile(split(a:content, "\n", 1), a:path, 'b')
  return v:true
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

function! gt#storage#LastSession() abort
  let l:sessions_dir = s:GetBaseDir() . '/sessions'
  if !isdirectory(l:sessions_dir)
    return v:null
  endif
  let l:files = glob(l:sessions_dir . '/*.json', 0, 1)
  if empty(l:files)
    return v:null
  endif
  let l:latest = v:null
  let l:latest_time = 0
  for l:file in l:files
    let l:data = s:ReadJson(l:file)
    if l:data isnot v:null && has_key(l:data, 'last_active') && l:data.last_active > l:latest_time
      let l:latest = l:data
      let l:latest_time = l:data.last_active
    endif
  endfor
  return l:latest
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

" Aggregate view across machines, in the pre-v2 flat shape callers expect.
function! gt#storage#LoadLifetimeStats() abort
  let l:agg = s:EmptyCounters()
  let l:agg.best_wpm = 0
  let l:machines = s:LoadLifetimeV2().machines
  for l:rec in values(l:machines)
    if type(l:rec) != v:t_dict
      continue
    endif
    let l:agg.total_chars += s:NumOr0(get(l:rec, 'total_chars', 0))
    let l:agg.correct_chars += s:NumOr0(get(l:rec, 'correct_chars', 0))
    let l:agg.total_time_seconds += s:NormalizeSeconds(s:NumOr0(get(l:rec, 'total_time_seconds', 0)))
    let l:agg.sessions_count += s:NumOr0(get(l:rec, 'sessions_count', 0))
    let l:agg.best_wpm = s:NumMax(l:agg.best_wpm, s:NumOr0(get(l:rec, 'best_wpm', 0)))
  endfor
  if type(l:agg.best_wpm) == v:t_float
    let l:agg.best_wpm = float2nr(round(l:agg.best_wpm))
  endif
  let l:agg.machines_count = len(l:machines)
  return l:agg
endfunction

" Accumulate a finished session into this machine's record. Counter fields
" are summed; best_wpm is max-merged (it is a high-water mark, not a sum).
function! gt#storage#AddLifetimeDeltas(deltas) abort
  let l:v2 = s:LoadLifetimeV2()
  let l:id = gt#storage#MachineId()
  if !has_key(l:v2.machines, l:id)
    let l:v2.machines[l:id] = s:EmptyCounters()
  endif
  let l:rec = l:v2.machines[l:id]
  for l:key in ['total_chars', 'correct_chars', 'sessions_count']
    if has_key(a:deltas, l:key)
      let l:rec[l:key] = s:NumOr0(get(l:rec, l:key, 0)) + a:deltas[l:key]
    endif
  endfor
  if has_key(a:deltas, 'total_time_seconds')
    let l:rec.total_time_seconds = s:NumOr0(get(l:rec, 'total_time_seconds', 0))
          \ + s:NormalizeSeconds(a:deltas.total_time_seconds)
  endif
  if has_key(a:deltas, 'best_wpm')
    let l:rec.best_wpm = s:NumMax(s:NumOr0(get(l:rec, 'best_wpm', 0)), a:deltas.best_wpm)
  endif
  return s:SaveLifetimeV2(l:v2)
endfunction

" Portable export/import
"
" Bundle format v1:
"   {'format_version': 1, 'exported_from': '<machine-id>', 'exported_at': N,
"    'machines': {'<machine-id>': {counters...}}, 'sessions': {'<book_id>': {...}}}
" Machine records merge by field-wise max over the union of numeric keys, so
" newer plugin versions (or external tools, e.g. a leaderboard ingester) can
" add counters without breaking older importers. Counter values must be
" integers that only ever grow on their owning machine; on import, floats
" are rounded and non-numeric values are dropped.

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
  let l:machines = s:LoadLifetimeV2().machines
  let l:sessions = gt#storage#ListSessions()
  if empty(l:machines) && empty(l:sessions)
    return {'ok': v:false, 'msg': 'No stats to export yet'}
  endif
  let l:bundle = {
        \ 'format_version': 1,
        \ 'exported_from': gt#storage#MachineId(),
        \ 'exported_at': localtime(),
        \ 'machines': l:machines,
        \ 'sessions': l:sessions,
        \}
  if !s:WriteJson(a:path, l:bundle)
    return {'ok': v:false, 'msg': 'Failed to write ' . a:path}
  endif
  return {'ok': v:true, 'msg': printf('Exported %d machine record(s), %d session(s) to %s',
        \ len(l:machines), len(l:sessions), a:path)}
endfunction

" Records are maps of integer counters by contract. Floats are rounded and
" anything non-numeric is dropped rather than persisted: a malformed bundle
" must never poison values that printf('%d')/arithmetic consumers rely on
" (E805/E735), and re-exports must never propagate the poison downstream.
function! s:MergeMachineRecord(local, incoming) abort
  let l:merged = {}
  for l:key in uniq(sort(keys(a:local) + keys(a:incoming)))
    let l:lv = get(a:local, l:key, 0)
    let l:iv = get(a:incoming, l:key, 0)
    if !s:IsNum(l:lv) || !s:IsNum(l:iv)
      continue
    endif
    let l:val = s:NumMax(l:lv, l:iv)
    let l:merged[l:key] = type(l:val) == v:t_float ? float2nr(round(l:val)) : l:val
  endfor
  return l:merged
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

function! gt#storage#ImportBundle(path) abort
  let l:bundle = s:ReadJson(a:path)
  if l:bundle is v:null
    return {'ok': v:false, 'msg': 'Cannot read or parse ' . a:path}
  endif
  if type(l:bundle) != v:t_dict
        \ || type(get(l:bundle, 'machines', 0)) != v:t_dict
        \ || type(get(l:bundle, 'sessions', 0)) != v:t_dict
    return {'ok': v:false, 'msg': 'Not a gutenberg-typist export bundle: ' . a:path}
  endif
  if get(l:bundle, 'format_version', 0) != 1
    return {'ok': v:false, 'msg': printf(
          \ 'Bundle format_version %s not supported (expected 1) — update gutenberg-typist',
          \ string(get(l:bundle, 'format_version', '?')))}
  endif

  let l:v2 = s:LoadLifetimeV2()
  for [l:id, l:incoming] in items(l:bundle.machines)
    if type(l:incoming) != v:t_dict
      continue
    endif
    let l:v2.machines[l:id] = s:MergeMachineRecord(get(l:v2.machines, l:id, {}), l:incoming)
  endfor
  if !s:SaveLifetimeV2(l:v2)
    return {'ok': v:false, 'msg': 'Failed to save merged stats'}
  endif

  let l:imported_sessions = 0
  for [l:book_id, l:incoming] in items(l:bundle.sessions)
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
      call s:WriteJson(s:SessionPath(l:book_id), l:merged)
      let l:imported_sessions += 1
    endif
  endfor

  return {'ok': v:true, 'msg': printf('Merged %d machine record(s), %d session(s) from %s',
        \ len(l:bundle.machines), l:imported_sessions, a:path)}
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
