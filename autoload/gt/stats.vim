function! gt#stats#New() abort
  return {
        \ 'start_time': v:null,
        \ 'total_chars_typed': 0,
        \ 'correct_chars': 0,
        \ 'samples': [],
        \ 'active_ms': 0,
        \ 'last_event': v:null,
        \ 'ever_wrong': {},
        \ 'resume_base': 0,
        \ 'rel_typed': 0,
        \ 'rel_correct': 0,
        \}
endfunction

" a:now is injected by the caller (engine passes the real clock, the test
" harness passes synthetic times) so the SPEC §5.1 active-time rule is
" verifiable without real sleeps.
function! gt#stats#UpdateFromComparison(state, typed_len, correct_count, prev_typed_len, now) abort
  if a:state.start_time is v:null
    let a:state.start_time = a:now
  endif

  " Active time (SPEC §5.1): gaps between input events longer than 5 s are
  " excluded in full, shorter gaps count entirely.
  if a:state.last_event isnot v:null
    let l:gap = a:now - a:state.last_event
    if l:gap > 0 && l:gap <= 5.0
      let a:state.active_ms += float2nr(round(l:gap * 1000))
    endif
  endif
  let a:state.last_event = a:now

  " Track incremental changes
  if a:typed_len > a:prev_typed_len
    let a:state.total_chars_typed += a:typed_len - a:prev_typed_len
  endif

  " Snapshots of the current transcript (session-relative)
  let a:state.correct_chars = a:correct_count
  let a:state.rel_typed = a:typed_len
  let a:state.rel_correct = a:correct_count

  " Add rolling sample
  call add(a:state.samples, {'time': a:now, 'typed': a:typed_len})
  " Keep enough history for the configured rolling window, plus one older
  " point to anchor its elapsed interval.
  let l:cutoff = a:now - max([gt#config#Get().wpm_window_seconds, 1]) - 1.0
  while len(a:state.samples) > 2 && a:state.samples[1].time < l:cutoff
    call remove(a:state.samples, 0)
  endwhile
endfunction

function! gt#stats#Wpm(state) abort
  if a:state.start_time is v:null || len(a:state.samples) < 2
    return 0.0
  endif

  let l:now = reltimefloat(reltime())
  let l:cfg = gt#config#Get()
  let l:window = l:cfg.wpm_window_seconds
  let l:cutoff = l:now - l:window

  " Find sample closest to window seconds ago
  let l:start_sample = v:null
  let l:i = len(a:state.samples) - 1
  while l:i >= 0
    let l:s = a:state.samples[l:i]
    if has_key(l:s, 'time') && l:s.time <= l:cutoff
      let l:start_sample = l:s
      break
    endif
    let l:i -= 1
  endwhile

  let l:current = a:state.samples[-1]

  if l:start_sample isnot v:null && has_key(l:start_sample, 'typed') && has_key(l:current, 'typed')
    let l:chars = l:current.typed - l:start_sample.typed
    let l:elapsed = l:current.time - l:start_sample.time
    if l:elapsed > 0
      return (l:chars / 5.0) / (l:elapsed / 60.0)
    endif
  endif

  " Fallback: overall WPM from start
  let l:elapsed = l:now - a:state.start_time
  if l:elapsed > 0 && has_key(l:current, 'typed')
    return (l:current.typed / 5.0) / (l:elapsed / 60.0)
  endif

  return 0.0
endfunction

function! gt#stats#Accuracy(state) abort
  let l:chars = get(a:state, 'rel_typed', 0)
  let l:errors = max([l:chars - get(a:state, 'rel_correct', 0), 0])
  let l:ever = 0
  let l:limit = get(a:state, 'resume_base', 0) + l:chars
  for l:pos in keys(get(a:state, 'ever_wrong', {}))
    if str2nr(l:pos) <= l:limit
      let l:ever += 1
    endif
  endfor
  let l:corrections = get(a:state, 'corrections', max([l:ever - l:errors, 0]))
  if l:chars + l:corrections == 0
    return 100.0
  endif
  return ((l:chars - l:errors) * 100.0) / (l:chars + l:corrections)
endfunction
