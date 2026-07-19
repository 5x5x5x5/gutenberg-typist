let s:state = {
      \ 'active': v:false,
      \ 'book_id': v:null,
      \ 'source_text': '',
      \ 'source_lines': [],
      \ 'stats': {},
      \ 'prev_typed_len': 0,
      \ 'resume_offset': 0,
      \ 'save_timer': v:null,
      \}

function! gt#engine#IsActive() abort
  return s:state.active
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

  let s:state = {
        \ 'active': v:true,
        \ 'book_id': a:book_id,
        \ 'source_text': l:flat_source,
        \ 'source_lines': l:source_lines,
        \ 'stats': gt#stats#New(),
        \ 'prev_typed_len': 0,
        \ 'resume_offset': a:resume_offset,
        \ 'save_timer': v:null,
        \ 'session_uuid': gt#util#Uuid4(),
        \ 'session_date': strftime('%Y-%m-%d'),
        \}

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

  " Debounced session save
  let l:cfg = gt#config#Get()
  let s:state.save_timer = gt#util#Debounce(function('s:SaveSession'), l:cfg.save_interval_ms)

  " Trigger initial display for resume
  if a:resume_offset > 0
    call timer_start(0, {-> gt#engine#OnTextChanged()})
  endif
endfunction

function! s:OnBufLeave() abort
  if s:state.active
    call timer_start(0, {-> gt#engine#Stop()})
  endif
endfunction

function! gt#engine#OnTextChanged() abort
  if !s:state.active || !gt#ui#IsOpen()
    return
  endif

  let l:ui = gt#ui#GetState()

  " Read all typed text and flatten
  let l:typed_lines = getbufline(l:ui.typing_buf, 1, '$')
  let l:typed_text = gt#util#FlattenLines(l:typed_lines)
  let l:typed_len = strlen(l:typed_text)

  let l:source = s:state.source_text
  let l:source_len = strlen(l:source)

  " Character-by-character comparison
  let l:matches = {}
  let l:correct_count = 0
  let l:compare_len = min([l:typed_len, l:source_len])
  let l:i = 1
  while l:i <= l:compare_len
    if l:typed_text[l:i - 1] ==# l:source[l:i - 1]
      let l:matches[l:i] = v:true
      let l:correct_count += 1
    else
      let l:matches[l:i] = v:false
      " Ever-mismatched positions feed the SPEC §5.2 corrections count at
      " session end (ever wrong minus still wrong = fixed).
      let s:state.stats.ever_wrong[l:i] = 1
    endif
    let l:i += 1
  endwhile

  " Update stats with session-relative counts: the resumed prefix is
  " reconstructed from the source (so it always fully matches) and must not
  " count as typed or correct — it would inflate lifetime chars and produce
  " fluke best_wpm values that max-merge never forgets.
  let l:base = min([s:state.resume_offset, l:source_len])
  let l:rel_typed = max([l:typed_len - l:base, 0])
  let l:rel_correct = max([l:correct_count - l:base, 0])
  call gt#stats#UpdateFromComparison(s:state.stats, l:rel_typed, l:rel_correct,
        \ s:state.prev_typed_len, reltimefloat(reltime()))
  let s:state.prev_typed_len = l:rel_typed

  " Sync source scroll first so highlights apply to the post-scroll
  " visible range (avoids a one-frame unhighlighted blip on scroll).
  let l:pos = gt#util#OffsetToPos(s:state.source_lines, min([l:typed_len, l:source_len - 1]))
  call gt#ui#SyncSourceScroll(l:pos[0])

  " Apply highlights on visible range of source buffer
  let [l:top, l:bot] = gt#ui#GetVisibleRange()
  call gt#highlight#Apply(l:ui.source_buf, s:state.source_lines, l:typed_len, l:matches, l:top, l:bot)

  " Calculate and display stats
  let l:wpm = gt#stats#Wpm(s:state.stats)
  let l:accuracy = gt#stats#Accuracy(s:state.stats)
  let l:progress = 0.0
  if l:source_len > 0
    let l:progress = (l:typed_len * 100.0) / l:source_len
  endif
  call gt#ui#UpdateStatsDisplay(l:wpm, l:accuracy, l:progress)

  " Trigger debounced save
  if s:state.save_timer isnot v:null
    call s:state.save_timer.call()
  endif
endfunction

function! s:SaveSession() abort
  if s:state.book_id is v:null
    return
  endif
  let l:ui = gt#ui#GetState()
  let l:typed_lines = []
  if gt#ui#IsOpen()
    let l:typed_lines = getbufline(l:ui.typing_buf, 1, '$')
  endif
  let l:typed_text = gt#util#FlattenLines(l:typed_lines)

  call gt#storage#SaveSession(s:state.book_id, {
        \ 'book_id': s:state.book_id,
        \ 'offset': strlen(l:typed_text),
        \ 'total_chars_typed': s:state.stats.total_chars_typed,
        \ 'correct_chars': s:state.stats.correct_chars,
        \})
endfunction

function! gt#engine#Stop() abort
  if !s:state.active
    return
  endif

  " Save session before cleanup
  call s:SaveSession()

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
  " Corrections (§5.2): ever-mismatched positions that are not mismatched
  " now, restricted to the final transcript — abandoned tails don't count.
  let l:base = s:state.resume_offset
  let l:ever = 0
  for l:pos in keys(s:state.stats.ever_wrong)
    if str2nr(l:pos) <= l:base + l:chars
      let l:ever += 1
    endif
  endfor
  let l:corrections = l:ever - l:errors > 0 ? l:ever - l:errors : 0
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
    call gt#storage#AppendSessionRecord({
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

    " One-line recap on SPEC §5.3 numbers: gross WPM over active time,
    " accuracy = (chars - errors) / (chars + corrections).
    if l:active_ms > 0
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

  " Clear autocmds
  augroup GTEngine
    autocmd!
  augroup END

  " Clean up debounce timer
  if s:state.save_timer isnot v:null
    call s:state.save_timer.close()
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
        \ 'save_timer': v:null,
        \}

  echomsg l:msg
endfunction
