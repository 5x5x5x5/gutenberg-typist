function! gt#stats#New() abort
  return {
        \ 'start_time': v:null,
        \ 'total_chars_typed': 0,
        \ 'correct_chars': 0,
        \ 'samples': [],
        \ 'sample_index': 0,
        \}
endfunction

function! gt#stats#UpdateFromComparison(state, typed_len, correct_count, prev_typed_len) abort
  let l:now = reltimefloat(reltime())

  if a:state.start_time is v:null
    let a:state.start_time = l:now
  endif

  " Track incremental changes
  if a:typed_len > a:prev_typed_len
    let a:state.total_chars_typed += a:typed_len - a:prev_typed_len
  endif

  " Correct chars is the current snapshot
  let a:state.correct_chars = a:correct_count

  " Add rolling sample
  let a:state.sample_index += 1
  call add(a:state.samples, {'time': l:now, 'typed': a:typed_len})
endfunction

function! gt#stats#Wpm(state) abort
  if a:state.start_time is v:null || a:state.sample_index < 2
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
  if a:state.total_chars_typed == 0
    return 100.0
  endif
  return (a:state.correct_chars * 100.0) / a:state.total_chars_typed
endfunction
