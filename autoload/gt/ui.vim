let s:state = {
      \ 'tab': -1,
      \ 'source_buf': -1,
      \ 'source_win': -1,
      \ 'typing_buf': -1,
      \ 'typing_win': -1,
      \}

function! gt#ui#GetState() abort
  return s:state
endfunction

function! gt#ui#IsOpen() abort
  return s:state.tab != -1
        \ && s:state.typing_win != -1
        \ && win_id2win(s:state.typing_win) > 0
endfunction

function! gt#ui#Open(source_lines) abort
  " Open a new tab
  tabnew
  let s:state.tab = tabpagenr()

  " Current buffer becomes the source buffer
  let s:state.source_buf = bufnr('%')
  call setbufvar(s:state.source_buf, '&buftype', 'nofile')
  call setbufvar(s:state.source_buf, '&bufhidden', 'wipe')
  call setbufvar(s:state.source_buf, '&swapfile', 0)
  call setbufvar(s:state.source_buf, '&filetype', 'gt-source')
  call setline(1, a:source_lines)
  call setbufvar(s:state.source_buf, '&modifiable', 0)

  let s:state.source_win = win_getid()

  " Calculate split width
  let l:total_width = winwidth(0)
  let l:cfg = gt#config#Get()
  let l:source_width = float2nr(l:total_width * l:cfg.split_ratio)

  " Vertical split for typing pane on right
  vnew
  let s:state.typing_win = win_getid()
  let s:state.typing_buf = bufnr('%')
  call setbufvar(s:state.typing_buf, '&buftype', 'nofile')
  call setbufvar(s:state.typing_buf, '&bufhidden', 'wipe')
  call setbufvar(s:state.typing_buf, '&swapfile', 0)
  call setbufvar(s:state.typing_buf, '&filetype', 'gt-typing')

  " Set source pane width
  call win_execute(s:state.source_win, 'vertical resize ' . l:source_width)

  " Configure both windows
  call s:ConfigureWin(s:state.source_win)
  call s:ConfigureWin(s:state.typing_win)
  call setwinvar(s:state.source_win, '&statusline', '\ SOURCE')

  " Focus the typing pane
  call win_gotoid(s:state.typing_win)

  " Autocmd to redirect focus back to typing pane
  augroup GTUI
    autocmd!
    autocmd WinEnter * call s:OnWinEnter()
  augroup END

  " Initial stats display
  call gt#ui#UpdateStatsDisplay(0.0, 100.0, 0.0)
endfunction

function! s:ConfigureWin(winid) abort
  call setwinvar(a:winid, '&number', 0)
  call setwinvar(a:winid, '&relativenumber', 0)
  call setwinvar(a:winid, '&wrap', 1)
  call setwinvar(a:winid, '&linebreak', 1)
  call setwinvar(a:winid, '&scrolloff', 5)
  call setwinvar(a:winid, '&cursorline', 0)
  call setwinvar(a:winid, '&signcolumn', 'no')
  call setwinvar(a:winid, '&foldcolumn', 0)
endfunction

function! s:OnWinEnter() abort
  if !gt#ui#IsOpen()
    " Clean up autocmd
    augroup GTUI
      autocmd!
    augroup END
    return
  endif
  let l:cur_win = win_getid()
  if l:cur_win == s:state.source_win && win_id2win(s:state.typing_win) > 0
    call timer_start(0, {-> win_gotoid(s:state.typing_win)})
  endif
endfunction

function! gt#ui#UpdateStatsDisplay(wpm, accuracy, progress) abort
  if s:state.typing_win == -1 || win_id2win(s:state.typing_win) == 0
    return
  endif
  let l:text = printf(' WPM: %.0f  |  Accuracy: %.1f%%%%  |  Progress: %.1f%%%%',
        \ a:wpm, a:accuracy, a:progress)
  " Escape spaces for statusline
  let l:bar = substitute(l:text, ' ', '\\ ', 'g')
  call setwinvar(s:state.typing_win, '&statusline', l:bar)
endfunction

function! gt#ui#SyncSourceScroll(line_0indexed) abort
  if s:state.source_win == -1 || win_id2win(s:state.source_win) == 0
    return
  endif
  let l:line_count = len(getbufline(s:state.source_buf, 1, '$'))
  let l:target = min([a:line_0indexed + 1, l:line_count])

  let l:info = getwininfo(s:state.source_win)
  if empty(l:info)
    return
  endif
  let l:topline = l:info[0].topline
  let l:botline = l:info[0].botline
  let l:scrolloff = 5

  " cursor() inside win_execute moves the cursor but does NOT update the
  " window's topline for an unfocused window, so the source pane stays
  " stuck on the first screen. Force a viewport update when the target
  " line is outside the scrolloff zone.
  if l:target > l:botline - l:scrolloff || l:target < l:topline + l:scrolloff
    call win_execute(s:state.source_win,
          \ printf('call cursor(%d, 1) | normal! zz', l:target))
  else
    call win_execute(s:state.source_win,
          \ printf('call cursor(%d, 1)', l:target))
  endif
endfunction

function! gt#ui#GetVisibleRange() abort
  if s:state.source_win == -1 || win_id2win(s:state.source_win) == 0
    return [0, 0]
  endif
  let l:info = getwininfo(s:state.source_win)
  if empty(l:info)
    return [0, 0]
  endif
  let l:top = l:info[0].topline - 1  " 0-indexed
  let l:bot = l:info[0].botline - 1
  let l:line_count = len(getbufline(s:state.source_buf, 1, '$'))
  let l:bot = min([l:bot, l:line_count - 1])
  return [l:top, l:bot]
endfunction

function! gt#ui#Close() abort
  " Remove autocmds
  augroup GTUI
    autocmd!
  augroup END

  " Close windows
  for l:w in [s:state.typing_win, s:state.source_win]
    if l:w != -1 && win_id2win(l:w) > 0
      call win_execute(l:w, 'quit!')
    endif
  endfor

  " Wipe buffers
  for l:b in [s:state.typing_buf, s:state.source_buf]
    if l:b != -1 && bufexists(l:b)
      try
        execute 'bwipeout! ' . l:b
      catch
      endtry
    endif
  endfor

  let s:state = {
        \ 'tab': -1,
        \ 'source_buf': -1,
        \ 'source_win': -1,
        \ 'typing_buf': -1,
        \ 'typing_win': -1,
        \}
endfunction

" Popup picker for search results / library

function! gt#ui#OpenPicker(title, items, FormatFn, OnSelectFn) abort
  let l:lines = []
  let l:i = 1
  for l:item in a:items
    call add(l:lines, a:FormatFn(l:item, l:i))
    let l:i += 1
  endfor

  let l:width = 60
  for l:line in l:lines
    let l:width = max([l:width, strlen(l:line) + 4])
  endfor
  let l:width = min([l:width, float2nr(&columns * 0.8)])
  let l:height = min([len(l:lines), float2nr(&lines * 0.6)])

  let l:row = (&lines - l:height) / 2
  let l:col = (&columns - l:width) / 2

  " Store callback context for the filter/callback
  let s:picker_items = a:items
  let s:picker_callback = a:OnSelectFn

  let l:winid = popup_create(l:lines, {
        \ 'title': ' ' . a:title . ' ',
        \ 'line': l:row,
        \ 'col': l:col,
        \ 'minwidth': l:width,
        \ 'maxwidth': l:width,
        \ 'minheight': l:height,
        \ 'maxheight': l:height,
        \ 'border': [],
        \ 'cursorline': 1,
        \ 'filter': function('s:PickerFilter'),
        \ 'callback': function('s:PickerCallback'),
        \ 'mapping': 0,
        \})
endfunction

function! s:PickerFilter(winid, key) abort
  if a:key ==# 'j' || a:key ==# "\<Down>"
    call win_execute(a:winid, 'normal! j')
    return 1
  elseif a:key ==# 'k' || a:key ==# "\<Up>"
    call win_execute(a:winid, 'normal! k')
    return 1
  elseif a:key ==# "\<CR>"
    " Get current line number (1-indexed)
    let l:pos = getcurpos(a:winid)
    let l:idx = l:pos[1]
    call popup_close(a:winid, l:idx)
    return 1
  elseif a:key ==# 'q' || a:key ==# "\<Esc>"
    call popup_close(a:winid, -1)
    return 1
  endif
  return 0
endfunction

function! s:PickerCallback(_winid, result) abort
  if a:result <= 0
    return
  endif
  if a:result >= 1 && a:result <= len(s:picker_items)
    let l:item = s:picker_items[a:result - 1]
    call s:picker_callback(l:item, a:result)
  endif
endfunction
