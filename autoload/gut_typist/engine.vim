let s:state = {
      \ 'active': v:false,
      \ 'book_id': v:null,
      \ 'source_text': '',
      \ 'source_lines': [],
      \ 'stats': {},
      \ 'prev_typed_len': 0,
      \ 'save_timer': v:null,
      \}

function! gut_typist#engine#IsActive() abort
  return s:state.active
endfunction

function! gut_typist#engine#GetState() abort
  return s:state
endfunction

function! gut_typist#engine#Start(book_id, source_text, resume_offset) abort
  if s:state.active
    call gut_typist#engine#Stop()
  endif

  let l:source_lines = gut_typist#util#SplitLines(a:source_text)
  let l:flat_source = gut_typist#util#FlattenLines(l:source_lines)

  let s:state = {
        \ 'active': v:true,
        \ 'book_id': a:book_id,
        \ 'source_text': l:flat_source,
        \ 'source_lines': l:source_lines,
        \ 'stats': gut_typist#stats#New(),
        \ 'prev_typed_len': 0,
        \ 'save_timer': v:null,
        \}

  " Open UI
  call gut_typist#ui#Open(l:source_lines)

  let l:ui = gut_typist#ui#GetState()

  " Apply initial untyped highlights
  let [l:top, l:bot] = gut_typist#ui#GetVisibleRange()
  call gut_typist#highlight#Apply(l:ui.source_buf, l:source_lines, 0, {}, l:top, l:bot)

  " If resuming, pre-fill typed text
  if a:resume_offset > 0
    let l:resume_text = strpart(l:flat_source, 0, a:resume_offset)
    let l:resume_lines = gut_typist#util#SplitLines(l:resume_text)
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
  augroup GutTypistEngine
    autocmd!
  augroup END
  execute 'autocmd GutTypistEngine TextChangedI,TextChanged <buffer=' . l:ui.typing_buf . '> call gut_typist#engine#OnTextChanged()'
  execute 'autocmd GutTypistEngine BufWinLeave <buffer=' . l:ui.typing_buf . '> call s:OnBufLeave()'
  execute 'autocmd GutTypistEngine BufWinLeave <buffer=' . l:ui.source_buf . '> call s:OnBufLeave()'

  " Debounced session save
  let l:cfg = gut_typist#config#Get()
  let s:state.save_timer = gut_typist#util#Debounce(function('s:SaveSession'), l:cfg.save_interval_ms)

  " Trigger initial display for resume
  if a:resume_offset > 0
    call timer_start(0, {-> gut_typist#engine#OnTextChanged()})
  endif
endfunction

function! s:OnBufLeave() abort
  if s:state.active
    call timer_start(0, {-> gut_typist#engine#Stop()})
  endif
endfunction

function! gut_typist#engine#OnTextChanged() abort
  if !s:state.active || !gut_typist#ui#IsOpen()
    return
  endif

  let l:ui = gut_typist#ui#GetState()

  " Read all typed text and flatten
  let l:typed_lines = getbufline(l:ui.typing_buf, 1, '$')
  let l:typed_text = gut_typist#util#FlattenLines(l:typed_lines)
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
    endif
    let l:i += 1
  endwhile

  " Update stats
  call gut_typist#stats#UpdateFromComparison(s:state.stats, l:typed_len, l:correct_count, s:state.prev_typed_len)
  let s:state.prev_typed_len = l:typed_len

  " Sync source scroll first so highlights apply to the post-scroll
  " visible range (avoids a one-frame unhighlighted blip on scroll).
  let l:pos = gut_typist#util#OffsetToPos(s:state.source_lines, min([l:typed_len, l:source_len - 1]))
  call gut_typist#ui#SyncSourceScroll(l:pos[0])

  " Apply highlights on visible range of source buffer
  let [l:top, l:bot] = gut_typist#ui#GetVisibleRange()
  call gut_typist#highlight#Apply(l:ui.source_buf, s:state.source_lines, l:typed_len, l:matches, l:top, l:bot)

  " Calculate and display stats
  let l:wpm = gut_typist#stats#Wpm(s:state.stats)
  let l:accuracy = gut_typist#stats#Accuracy(s:state.stats)
  let l:progress = 0.0
  if l:source_len > 0
    let l:progress = (l:typed_len * 100.0) / l:source_len
  endif
  call gut_typist#ui#UpdateStatsDisplay(l:wpm, l:accuracy, l:progress)

  " Trigger debounced save
  if s:state.save_timer isnot v:null
    call s:state.save_timer.call()
  endif
endfunction

function! s:SaveSession() abort
  if s:state.book_id is v:null
    return
  endif
  let l:ui = gut_typist#ui#GetState()
  let l:typed_lines = []
  if gut_typist#ui#IsOpen()
    let l:typed_lines = getbufline(l:ui.typing_buf, 1, '$')
  endif
  let l:typed_text = gut_typist#util#FlattenLines(l:typed_lines)

  call gut_typist#storage#SaveSession(s:state.book_id, {
        \ 'book_id': s:state.book_id,
        \ 'offset': strlen(l:typed_text),
        \ 'total_chars_typed': s:state.stats.total_chars_typed,
        \ 'correct_chars': s:state.stats.correct_chars,
        \})
endfunction

function! gut_typist#engine#Stop() abort
  if !s:state.active
    return
  endif

  " Save session before cleanup
  call s:SaveSession()

  " Update lifetime stats
  let l:lifetime = gut_typist#storage#LoadLifetimeStats()
  let l:lifetime.total_chars = l:lifetime.total_chars + s:state.stats.total_chars_typed
  let l:lifetime.correct_chars = l:lifetime.correct_chars + s:state.stats.correct_chars
  if s:state.stats.start_time isnot v:null
    let l:elapsed = reltimefloat(reltime()) - s:state.stats.start_time
    let l:lifetime.total_time_seconds = l:lifetime.total_time_seconds + l:elapsed
  endif
  let l:lifetime.sessions_count = l:lifetime.sessions_count + 1
  call gut_typist#storage#SaveLifetimeStats(l:lifetime)

  " Clear autocmds
  augroup GutTypistEngine
    autocmd!
  augroup END

  " Clean up debounce timer
  if s:state.save_timer isnot v:null
    call s:state.save_timer.close()
  endif

  " Clear highlights
  let l:ui = gut_typist#ui#GetState()
  if l:ui.source_buf != -1 && bufexists(l:ui.source_buf)
    call gut_typist#highlight#Clear(l:ui.source_buf)
  endif

  " Close UI
  call gut_typist#ui#Close()

  let s:state = {
        \ 'active': v:false,
        \ 'book_id': v:null,
        \ 'source_text': '',
        \ 'source_lines': [],
        \ 'stats': {},
        \ 'prev_typed_len': 0,
        \ 'save_timer': v:null,
        \}

  echomsg 'GutTypist: Session saved'
endfunction
