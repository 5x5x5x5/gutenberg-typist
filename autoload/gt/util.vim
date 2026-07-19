function! gt#util#SplitLines(str) abort
  return split(a:str, "\n", 1)
endfunction

function! gt#util#FlattenLines(lines) abort
  return join(a:lines, "\n")
endfunction

" Convert linear character offset to [line, col] (both 0-indexed)
function! gt#util#OffsetToPos(lines, offset) abort
  let l:remaining = a:offset
  let l:i = 0
  for l:line in a:lines
    let l:len = strlen(l:line) + 1  " +1 for \n
    if l:remaining < l:len
      return [l:i, l:remaining]
    endif
    let l:remaining -= l:len
    let l:i += 1
  endfor
  " Past the end
  let l:last = len(a:lines)
  if l:last == 0
    return [0, 0]
  endif
  return [l:last - 1, strlen(a:lines[l:last - 1])]
endfunction

" Debounce: returns a dict with .call(...) and .close() methods
function! gt#util#Debounce(Fn, delay_ms) abort
  let l:state = {'timer': -1, 'Fn': a:Fn, 'delay': a:delay_ms}

  function! l:state.call(...) abort
    if self.timer != -1
      call timer_stop(self.timer)
    endif
    let l:Callback = self.Fn
    let self.timer = timer_start(self.delay, {-> l:Callback()})
  endfunction

  function! l:state.close() abort
    if self.timer != -1
      call timer_stop(self.timer)
      let self.timer = -1
    endif
  endfunction

  return l:state
endfunction

function! gt#util#UriEncode(str) abort
  return substitute(a:str, '[^A-Za-z0-9_.~-]',
        \ '\=printf("%%%02X", char2nr(submatch(0)))', 'g')
endfunction

" Session identity (SPEC.md schema 1). Seeded once per Vim instance.
let s:uuid_seed = srand()

function! gt#util#Uuid4() abort
  let l:h = '0123456789abcdef'
  let l:s = ''
  for l:i in range(36)
    if index([8, 13, 18, 23], l:i) >= 0
      let l:s .= '-'
    elseif l:i == 14
      let l:s .= '4'
    elseif l:i == 19
      let l:s .= l:h[8 + rand(s:uuid_seed) % 4]
    else
      let l:s .= l:h[rand(s:uuid_seed) % 16]
    endif
  endfor
  return l:s
endfunction

" Deterministic legacy-record id per SPEC.md §9: SHA-256 of
" namespace + NL + machine + NL + "legacy-v0", sliced into UUID shape
" with forced version/variant nibbles. Same machine -> same id, always.
function! gt#util#LegacyUuid(machine) abort
  let l:d = sha256("8c8f6a1e-2b7d-4f5a-9c3e-747970697374\n"
        \ . a:machine . "\nlegacy-v0")
  let l:v = printf('%x', or(and(str2nr(l:d[16], 16), 3), 8))
  return l:d[0:7] . '-' . l:d[8:11] . '-8' . l:d[13:15] . '-'
        \ . l:v . l:d[17:19] . '-' . l:d[20:31]
endfunction
