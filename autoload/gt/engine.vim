let s:state = {
      \ 'active': v:false,
      \ 'book_id': v:null,
      \ 'source_text': '',
      \ 'source_lines': [],
      \ 'stats': {},
      \ 'prev_typed_len': 0,
      \ 'resume_offset': 0,
      \ 'checkpoint_timer': v:null,
      \ 'typed_chars': [],
      \ 'typed_text': '',
      \ 'correct_by_pos': [],
      \ 'finalizing': v:false,
      \ 'snapshot_offset': 0,
      \ 'dirty': v:false,
      \ 'last_changedtick': -1,
      \}

function! gt#engine#IsActive() abort
  return s:state.active
endfunction

function! s:CommonPrefix(old, new, old_len, new_len) abort
  if strpart(a:new, 0, strlen(a:old)) ==# a:old
    return a:old_len
  elseif strpart(a:old, 0, strlen(a:new)) ==# a:new
    return a:new_len
  endif
  let l:lo = 0
  let l:hi = min([a:old_len, a:new_len])
  while l:lo < l:hi
    let l:mid = float2nr(ceil((l:lo + l:hi) / 2.0))
    if strcharpart(a:old, 0, l:mid) ==# strcharpart(a:new, 0, l:mid)
      let l:lo = l:mid
    else
      let l:hi = l:mid - 1
    endif
  endwhile
  return l:lo
endfunction

function! gt#engine#GetState() abort
  return s:state
endfunction

function! gt#engine#Start(book_id, source_text, resume_offset) abort
  if s:state.active
    call gt#engine#Stop()
  endif

  let l:source_lines = gt#util#SplitLines(a:source_text)
  let l:flat_source = gt#util#FlattenLines(l:source_lines)
  let l:line_offsets = [0]
  for l:line in l:source_lines
    call add(l:line_offsets, l:line_offsets[-1] + strchars(l:line) + 1)
  endfor

  let s:state = {
        \ 'active': v:true,
        \ 'book_id': a:book_id,
        \ 'source_text': l:flat_source,
        \ 'source_chars': split(l:flat_source, '\zs'),
        \ 'line_offsets': l:line_offsets,
        \ 'source_lines': l:source_lines,
        \ 'stats': gt#stats#New(),
        \ 'prev_typed_len': 0,
        \ 'resume_offset': a:resume_offset,
          \ 'checkpoint_timer': v:null,
        \ 'typed_chars': [],
        \ 'typed_text': '',
        \ 'correct_by_pos': [],
          \ 'finalizing': v:false,
        \ 'snapshot_offset': strlen(strpart(l:flat_source, 0, min([a:resume_offset, strlen(l:flat_source)]))),
        \ 'dirty': v:false,
        \ 'last_changedtick': -1,
        \ 'session_uuid': gt#util#Uuid4(),
        \ 'session_date': strftime('%Y-%m-%d'),
        \}
  let s:state.stats.resume_base = strchars(strpart(l:flat_source, 0, a:resume_offset))

  " Open UI
  call gt#ui#Open(l:source_lines)

  let l:ui = gt#ui#GetState()

  " Apply initial untyped highlights
  let [l:top, l:bot] = gt#ui#GetVisibleRange()
  call gt#highlight#Apply(l:ui.source_buf, l:source_lines, 0, {}, l:top, l:bot)

  " If resuming, pre-fill typed text
  if a:resume_offset > 0
    let l:resume_text = strpart(l:flat_source, 0, a:resume_offset)
    let l:resume_lines = gt#util#SplitLines(l:resume_text)
    call setbufvar(l:ui.typing_buf, '&modifiable', 1)
    call setbufline(l:ui.typing_buf, 1, l:resume_lines)
    " Move cursor to end
    let l:last_line = len(l:resume_lines)
    if l:last_line > 0
      let l:last_col = strlen(l:resume_lines[l:last_line - 1]) + 1
      call win_execute(l:ui.typing_win, 'call cursor(' . l:last_line . ', ' . l:last_col . ')')
    endif
  endif

  " Register autocmds
  augroup GTEngine
    autocmd!
  augroup END
  execute 'autocmd GTEngine TextChangedI,TextChanged <buffer=' . l:ui.typing_buf . '> call gt#engine#OnTextChanged()'
  execute 'autocmd GTEngine BufWinLeave <buffer=' . l:ui.typing_buf . '> call s:OnBufLeave()'
  execute 'autocmd GTEngine BufWinLeave <buffer=' . l:ui.source_buf . '> call s:OnBufLeave()'
  autocmd GTEngine TabLeave * call gt#engine#Stop()
  autocmd GTEngine VimLeavePre * call gt#engine#Stop()

  " Periodic checkpoint avoids one timer reset per keystroke.
  let l:cfg = gt#config#Get()
  let s:state.checkpoint_timer = timer_start(max([l:cfg.save_interval_ms, 1]),
        \ function('s:Checkpoint'), {'repeat': -1})

  " Trigger initial display for resume
  if a:resume_offset > 0
    call timer_start(0, {-> gt#engine#OnTextChanged()})
  endif
endfunction

function! s:OnBufLeave() abort
  if s:state.active
    " Snapshot is maintained by TextChanged; defer window cleanup until Vim
    " has completed the close that triggered BufWinLeave.
    call gt#engine#OnTextChanged()
    let l:id = s:state.session_uuid
    call timer_start(0, {-> s:StopIfCurrent(l:id)})
  endif
endfunction

function! s:StopIfCurrent(id) abort
  if s:state.active && s:state.session_uuid ==# a:id
    call gt#engine#Stop()
  endif
endfunction

function! gt#engine#OnTextChanged() abort
  if !s:state.active || !bufexists(gt#ui#GetState().typing_buf)
    return
  endif

  let l:ui = gt#ui#GetState()
  let l:changedtick = getbufvar(l:ui.typing_buf, 'changedtick')
  if l:changedtick == s:state.last_changedtick
    return
  endif
  let s:state.last_changedtick = l:changedtick

  " Read all typed text and flatten
  let l:typed_lines = getbufline(l:ui.typing_buf, 1, '$')
  let l:typed_text = gt#util#FlattenLines(l:typed_lines)
  let l:typed_chars = split(l:typed_text, '\zs')
  let l:typed_len = len(l:typed_chars)
  let s:state.snapshot_offset = strlen(l:typed_text)
  let s:state.dirty = v:true

  let l:source = s:state.source_text
  let l:source_chars = s:state.source_chars
  let l:source_len = len(l:source_chars)

  " Character-by-character comparison
  " Compare only the changed suffix. Arbitrary edits are handled by finding
  " the longest unchanged prefix against the previous transcript.
  let l:old_len = len(s:state.typed_chars)
  let l:common = s:CommonPrefix(s:state.typed_text, l:typed_text, l:old_len, l:typed_len)
  let l:correct_by_pos = l:common > 0 ? s:state.correct_by_pos[: l:common - 1] : []
  let l:matches = {}
  let l:i = l:common
  while l:i < l:typed_len
    let l:ok = l:i < l:source_len && l:typed_chars[l:i] ==# l:source_chars[l:i]
    call add(l:correct_by_pos, l:ok)
    if !l:ok
      let s:state.stats.ever_wrong[l:i + 1] = 1
    endif
    let l:i += 1
  endwhile
  let s:state.typed_chars = l:typed_chars
  let s:state.typed_text = l:typed_text
  let s:state.correct_by_pos = l:correct_by_pos

  " Update stats with session-relative counts: the resumed prefix is
  " reconstructed from the source (so it always fully matches) and must not
  " count as typed or correct — it would inflate lifetime chars and produce
  " fluke best_wpm values that max-merge never forgets.
  let l:base = s:state.stats.resume_base
  let l:rel_typed = max([l:typed_len - l:base, 0])
  let l:rel_correct = count(l:correct_by_pos[l:base :], 1)
  let s:state.stats.corrections = 0
  for l:pos in keys(s:state.stats.ever_wrong)
    let l:index = str2nr(l:pos) - 1
    if l:index >= l:base && l:index < l:typed_len && l:correct_by_pos[l:index]
      let s:state.stats.corrections += 1
    endif
  endfor
  call gt#stats#UpdateFromComparison(s:state.stats, l:rel_typed, l:rel_correct,
        \ s:state.prev_typed_len, reltimefloat(reltime()))
  let s:state.prev_typed_len = l:rel_typed

  " Sync source scroll first so highlights apply to the post-scroll
  " visible range (avoids a one-frame unhighlighted blip on scroll).
  let l:byte_offset = strlen(strcharpart(l:source, 0, min([l:typed_len, l:source_len])))
  let l:pos = gt#util#OffsetToPos(s:state.source_lines, l:byte_offset)
  call gt#ui#SyncSourceScroll(l:pos[0])

  " Apply highlights on visible range of source buffer
  let [l:top, l:bot] = gt#ui#GetVisibleRange()
  let l:line_base = s:state.line_offsets[min([l:top, len(s:state.source_lines)])]
  for l:line_no in range(l:top, l:bot)
    if l:line_no >= len(s:state.source_lines)
      break
    endif
    let l:line_chars = split(s:state.source_lines[l:line_no], '\zs')
    let l:ci = 0
    while l:ci < len(l:line_chars)
      let l:pos = l:line_base + l:ci + 1
      if l:pos <= min([l:typed_len, l:source_len])
        let l:matches[l:pos] = l:typed_chars[l:pos - 1] ==# l:source_chars[l:pos - 1]
      endif
      let l:ci += 1
    endwhile
    let l:line_base += len(l:line_chars) + 1
  endfor
  call gt#highlight#Apply(l:ui.source_buf, s:state.source_lines, l:typed_len, l:matches, l:top, l:bot)

  " Calculate and display stats
  let l:wpm = gt#stats#Wpm(s:state.stats)
  let l:accuracy = gt#stats#Accuracy(s:state.stats)
  let l:progress = 0.0
  if l:source_len > 0
    let l:progress = (l:typed_len * 100.0) / l:source_len
  endif
  call gt#ui#UpdateStatsDisplay(l:wpm, l:accuracy, l:progress)

endfunction

function! s:Checkpoint(_timer) abort
  if s:state.active && s:state.dirty
    if s:SaveSession()
      let s:state.dirty = v:false
    else
      echomsg 'GT: Could not save progress checkpoint'
    endif
  endif
endfunction

function! s:SaveSession() abort
  if s:state.book_id is v:null
    return
  endif
  return gt#storage#SaveSession(s:state.book_id, {
        \ 'book_id': s:state.book_id,
        \ 'offset': s:state.snapshot_offset,
        \ 'total_chars_typed': s:state.stats.total_chars_typed,
        \ 'correct_chars': s:state.stats.correct_chars,
        \})
endfunction

function! gt#engine#Stop() abort
  if !s:state.active || s:state.finalizing
    return
  endif
  call gt#engine#OnTextChanged()
  let s:state.finalizing = v:true
  let s:state.active = v:false

  " Save session before cleanup
  let l:progress_saved = s:SaveSession()

  " Build a SPEC.md schema-1 session record from the final transcript.
  let l:elapsed = 0.0
  if s:state.stats.start_time isnot v:null
    let l:elapsed = reltimefloat(reltime()) - s:state.stats.start_time
  endif
  let l:chars = s:state.stats.rel_typed
  let l:errors = s:state.stats.rel_typed - s:state.stats.rel_correct
  if l:errors < 0
    let l:errors = 0
  endif
  let l:base = s:state.stats.resume_base
  let l:corrections = get(s:state.stats, 'corrections', 0)
  let l:wall_ms = float2nr(round(l:elapsed * 1000))
  " Per-event rounding can nudge active a few ms past wall; never let a
  " legitimate session trip the active<=wall plausibility flag.
  let l:active_ms = min([s:state.stats.active_ms, l:wall_ms])

  let l:prev_best = get(gt#storage#LoadLifetimeStats(), 'best_wpm', 0)
  let l:msg = 'GT: Session saved'
  if l:chars > 0
    let l:book = {'gutenberg_id': str2nr(s:state.book_id)}
    let l:meta = gt#storage#LoadBookMetadata(s:state.book_id)
    if l:meta isnot v:null && get(l:meta, 'title', '') !=# ''
      let l:book.title = l:meta.title
    endif
    let l:record_saved = gt#storage#AppendSessionRecord({
          \ 'id': s:state.session_uuid,
          \ 'machine': gt#storage#MachineId(),
          \ 'date': s:state.session_date,
          \ 'book': l:book,
          \ 'range': {'start': l:base, 'end': l:base + l:chars},
          \ 'active_ms': l:active_ms,
          \ 'wall_ms': l:wall_ms,
          \ 'chars_typed': l:chars,
          \ 'errors_uncorrected': l:errors,
          \ 'corrections': l:corrections,
          \})

    if !l:record_saved
      let l:msg = 'GT: Could not save session record'
    endif
    " One-line recap on SPEC §5.3 numbers: gross WPM over active time,
    " accuracy = (chars - errors) / (chars + corrections).
    if l:record_saved && l:active_ms > 0
      let l:wpm = (l:chars / 5.0) / (l:active_ms / 60000.0)
      let l:msg = printf('GT: Session saved — %.0f wpm · %.1f%% accuracy · %d chars · %s',
            \ l:wpm,
            \ ((l:chars - l:errors) * 100.0) / (l:chars + l:corrections),
            \ l:chars,
            \ l:elapsed >= 60.0
            \   ? float2nr(round(l:elapsed / 60.0)) . ' min'
            \   : float2nr(round(l:elapsed)) . ' sec')
      if l:active_ms >= 10000 && float2nr(round(l:wpm)) > l:prev_best
        let l:msg .= ' · new best WPM!'
      endif
    endif
  endif
  if !l:progress_saved
    let l:msg = 'GT: Could not save progress checkpoint'
  endif

  " Clear autocmds
  augroup GTEngine
    autocmd!
  augroup END

  " Stop periodic checkpoints
  if s:state.checkpoint_timer isnot v:null
    call timer_stop(s:state.checkpoint_timer)
  endif

  " Clear highlights
  let l:ui = gt#ui#GetState()
  if l:ui.source_buf != -1 && bufexists(l:ui.source_buf)
    call gt#highlight#Clear(l:ui.source_buf)
  endif

  " Close UI
  call gt#ui#Close()

  let s:state = {
        \ 'active': v:false,
        \ 'book_id': v:null,
        \ 'source_text': '',
        \ 'source_lines': [],
        \ 'stats': {},
        \ 'prev_typed_len': 0,
        \ 'resume_offset': 0,
          \ 'checkpoint_timer': v:null,
        \ 'typed_text': '',
        \ 'typed_chars': [],
        \ 'finalizing': v:false,
        \ 'snapshot_offset': 0,
        \ 'dirty': v:false,
        \ 'last_changedtick': -1,
        \}

  echomsg l:msg
endfunction
