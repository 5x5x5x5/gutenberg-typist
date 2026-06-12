function! gt#Setup(opts) abort
  call gt#config#Apply(a:opts)
endfunction

function! gt#Command(...) abort
  if a:0 < 1
    echohl WarningMsg | echomsg 'GT: Usage: :GT <search|start|resume|stop|stats|library>' | echohl None
    return
  endif

  let l:subcmd = a:1

  if l:subcmd ==# 'search'
    let l:query = join(a:000[1:], ' ')
    if l:query ==# ''
      echohl WarningMsg | echomsg 'GT: Usage: :GT search <query>' | echohl None
      return
    endif
    call s:Search(l:query)
  elseif l:subcmd ==# 'start'
    if a:0 < 2
      echohl WarningMsg | echomsg 'GT: Usage: :GT start <book_id>' | echohl None
      return
    endif
    call s:Start(str2nr(a:2))
  elseif l:subcmd ==# 'resume'
    call s:Resume()
  elseif l:subcmd ==# 'stop'
    call gt#engine#Stop()
  elseif l:subcmd ==# 'stats'
    call s:ShowStats()
  elseif l:subcmd ==# 'library'
    call s:Library()
  else
    echohl ErrorMsg | echomsg 'GT: Unknown command: ' . l:subcmd | echohl None
  endif
endfunction

function! gt#Complete(arglead, cmdline, cursorpos) abort
  let l:subcmds = ['search', 'start', 'resume', 'stop', 'stats', 'library']
  let l:parts = split(a:cmdline, '\s\+')
  if len(l:parts) <= 2
    return filter(copy(l:subcmds), 'v:val =~# "^" . a:arglead')
  endif
  return []
endfunction

function! s:Search(query) abort
  echomsg "GT: Searching for '" . a:query . "'..."

  call gt#gutenberg#Search(a:query, function('s:OnSearchResults'))
endfunction

function! s:OnSearchResults(results, err) abort
  if a:err isnot v:null
    echohl ErrorMsg | echomsg 'GT: Search failed: ' . a:err | echohl None
    return
  endif
  if a:results is v:null || empty(a:results)
    echohl WarningMsg | echomsg 'GT: No results found' | echohl None
    return
  endif

  call gt#ui#OpenPicker('Search Results', a:results,
        \ function('s:FormatSearchResult'),
        \ function('s:OnSearchSelect'))
endfunction

function! s:FormatSearchResult(item, idx) abort
  return printf('%d. [%d] %s — %s', a:idx, a:item.id, a:item.title, a:item.author)
endfunction

function! s:OnSearchSelect(item, _idx) abort
  call s:StartWithMetadata(a:item.id, {
        \ 'id': a:item.id,
        \ 'title': a:item.title,
        \ 'author': a:item.author,
        \ 'authors': a:item.authors,
        \})
endfunction

function! s:StartWithMetadata(book_id, metadata) abort
  echomsg 'GT: Loading book ' . a:book_id . '...'

  call gt#gutenberg#DownloadWithMetadata(a:book_id, a:metadata,
        \ function('s:OnBookDownloaded', [a:book_id]))
endfunction

function! s:OnBookDownloaded(book_id, text, err) abort
  if a:err isnot v:null
    echohl ErrorMsg | echomsg 'GT: Download failed: ' . a:err | echohl None
    return
  endif

  " Check for existing session
  let l:session = gt#storage#LoadSession(a:book_id)
  let l:offset = 0
  if l:session isnot v:null && has_key(l:session, 'offset') && l:session.offset > 0
    let l:answer = confirm(
          \ 'Resume from previous session? (offset: ' . l:session.offset . ')',
          \ "&Yes\n&No\n&Reset", 1)
    if l:answer == 1
      let l:offset = l:session.offset
    elseif l:answer == 3
      call gt#storage#SaveSession(a:book_id, {'book_id': a:book_id, 'offset': 0})
    endif
  endif

  call gt#engine#Start(a:book_id, a:text, l:offset)
endfunction

function! s:Start(book_id) abort
  call s:StartWithMetadata(a:book_id, v:null)
endfunction

function! s:Resume() abort
  let l:session = gt#storage#LastSession()
  if l:session is v:null || !has_key(l:session, 'book_id')
    echohl WarningMsg | echomsg 'GT: No previous session found' | echohl None
    return
  endif
  call s:StartWithMetadata(l:session.book_id, v:null)
endfunction

function! s:ShowStats() abort
  let l:lifetime = gt#storage#LoadLifetimeStats()

  let l:lines = ['=== GT Stats ===']

  " Current session stats
  if gt#engine#IsActive()
    let l:st = gt#engine#GetState().stats
    call add(l:lines, '')
    call add(l:lines, '-- Current Session --')
    call add(l:lines, printf('  WPM:      %.0f', gt#stats#Wpm(l:st)))
    call add(l:lines, printf('  Accuracy: %.1f%%', gt#stats#Accuracy(l:st)))
    call add(l:lines, printf('  Chars:    %d typed, %d correct', l:st.total_chars_typed, l:st.correct_chars))
  endif

  " Lifetime stats
  call add(l:lines, '')
  call add(l:lines, '-- Lifetime --')
  call add(l:lines, printf('  Sessions:  %d', l:lifetime.sessions_count))
  call add(l:lines, printf('  Chars:     %d typed, %d correct', l:lifetime.total_chars, l:lifetime.correct_chars))
  if l:lifetime.total_chars > 0
    call add(l:lines, printf('  Accuracy:  %.1f%%',
          \ (l:lifetime.correct_chars * 100.0) / l:lifetime.total_chars))
  endif
  if l:lifetime.total_time_seconds > 0
    let l:mins = l:lifetime.total_time_seconds / 60.0
    call add(l:lines, printf('  Time:      %.0f minutes', l:mins))
    if l:lifetime.total_chars > 0
      call add(l:lines, printf('  Avg WPM:   %.0f',
            \ (l:lifetime.total_chars / 5.0) / l:mins))
    endif
  endif

  " Show in popup window
  let l:width = 40
  for l:l in l:lines
    let l:width = max([l:width, strlen(l:l) + 4])
  endfor
  let l:height = len(l:lines)

  let l:row = (&lines - l:height) / 2
  let l:col = (&columns - l:width) / 2

  call popup_create(l:lines, {
        \ 'title': ' Stats ',
        \ 'line': l:row,
        \ 'col': l:col,
        \ 'minwidth': l:width,
        \ 'maxwidth': l:width,
        \ 'minheight': l:height,
        \ 'maxheight': l:height,
        \ 'border': [],
        \ 'mapping': 0,
        \ 'filter': {winid, key -> key ==# 'q' || key ==# "\<Esc>" ? popup_close(winid) || 1 : 0},
        \})
endfunction

function! s:Library() abort
  let l:books = gt#gutenberg#ListCached()
  if empty(l:books)
    echomsg 'GT: No cached books. Use :GT search <query> to find books.'
    return
  endif

  call gt#ui#OpenPicker('Library', l:books,
        \ function('s:FormatLibraryItem'),
        \ function('s:OnLibrarySelect'))
endfunction

function! s:FormatLibraryItem(item, idx) abort
  let l:author = get(a:item, 'author', join(get(a:item, 'authors', []), ', '))
  return printf('%d. [%s] %s — %s', a:idx, a:item.id, get(a:item, 'title', 'Untitled'), l:author)
endfunction

function! s:OnLibrarySelect(item, _idx) abort
  call s:StartWithMetadata(a:item.id, a:item)
endfunction
