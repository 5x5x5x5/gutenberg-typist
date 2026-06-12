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

function! gt#util#WrapText(text, ...) abort
  let l:width = get(a:, 1, 80)
  let l:lines = gt#util#SplitLines(a:text)
  let l:result = []
  for l:line in l:lines
    if strlen(l:line) == 0
      call add(l:result, '')
    elseif strlen(l:line) <= l:width
      call add(l:result, l:line)
    else
      let l:pos = 0
      while l:pos < strlen(l:line)
        if l:pos + l:width >= strlen(l:line)
          call add(l:result, strpart(l:line, l:pos))
          break
        endif
        let l:chunk = strpart(l:line, l:pos, l:width)
        " Find last space within chunk
        let l:wrap_at = strridx(l:chunk, ' ')
        if l:wrap_at > 0
          call add(l:result, strpart(l:line, l:pos, l:wrap_at))
          let l:pos += l:wrap_at + 1
        else
          call add(l:result, l:chunk)
          let l:pos += l:width
        endif
      endwhile
    endif
  endfor
  return l:result
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
