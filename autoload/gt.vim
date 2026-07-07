function! gt#Setup(opts) abort
  call gt#config#Apply(a:opts)
endfunction

function! gt#Command(...) abort
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
  elseif l:subcmd ==# 'export'
    let l:path = a:0 >= 2 ? join(a:000[1:], ' ') : '~/gutenberg-typist-export.json'
    let l:res = gt#storage#ExportBundle(fnamemodify(l:path, ':p'))
    if l:res.ok
      echomsg 'GT: ' . l:res.msg
    else
      echohl WarningMsg | echomsg 'GT: ' . l:res.msg | echohl None
    endif
  elseif l:subcmd ==# 'import'
    if a:0 < 2
      echohl WarningMsg | echomsg 'GT: Usage: :GT import <file>' | echohl None
      return
    endif
    if gt#engine#IsActive()
      echohl WarningMsg | echomsg 'GT: Stop the current session (:GT stop) before importing' | echohl None
      return
    endif
    let l:res = gt#storage#ImportBundle(fnamemodify(join(a:000[1:], ' '), ':p'))
    if l:res.ok
      echomsg 'GT: ' . l:res.msg
    else
      echohl ErrorMsg | echomsg 'GT: ' . l:res.msg | echohl None
    endif
  else
    echohl ErrorMsg | echomsg 'GT: Unknown command: ' . l:subcmd | echohl None
  endif
endfunction

function! gt#Complete(arglead, cmdline, cursorpos) abort
  let l:subcmds = ['search', 'start', 'resume', 'stop', 'stats', 'library', 'export', 'import']
  let l:before = strpart(a:cmdline, 0, a:cursorpos)
  let l:parts = split(l:before, '\s\+')
  " Still typing the subcommand itself (no space after it yet)
  if len(l:parts) < 2 || (len(l:parts) == 2 && l:before !~# '\s$')
    return filter(copy(l:subcmds), 'v:val =~# "^" . a:arglead')
  endif
  if index(['export', 'import'], l:parts[1]) >= 0
    return getcompletion(a:arglead, 'file')
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
  let l:sessions = gt#storage#ListSessions()
  call filter(l:sessions, 'type(v:val) == v:t_dict && get(v:val, "offset", 0) > 0')
  if empty(l:sessions)
    echohl WarningMsg | echomsg 'GT: No previous session found' | echohl None
    return
  endif

  let l:items = []
  for [l:book_id, l:sess] in items(l:sessions)
    let l:meta = gt#storage#LoadBookMetadata(l:book_id)
    if l:meta is v:null
      let l:meta = {}
    endif
    call add(l:items, {
          \ 'id': str2nr(l:book_id),
          \ 'title': get(l:meta, 'title', 'Book ' . l:book_id),
          \ 'author': get(l:meta, 'author', join(get(l:meta, 'authors', []), ', ')),
          \ 'offset': l:sess.offset,
          \ 'last_active': get(l:sess, 'last_active', 0),
          \})
  endfor

  if len(l:items) == 1
    call s:StartWithMetadata(l:items[0].id, v:null)
    return
  endif

  call sort(l:items, {a, b -> b.last_active - a.last_active})
  call gt#ui#OpenPicker('Resume', l:items,
        \ function('s:FormatResumeItem'),
        \ function('s:OnResumeSelect'))
endfunction

function! s:FormatResumeItem(item, idx) abort
  let l:size = gt#storage#BookTextSize(a:item.id)
  let l:progress = l:size > 0
        \ ? printf('%.0f%%', (a:item.offset * 100.0) / l:size)
        \ : a:item.offset . ' chars'
  return printf('%d. [%d] %s — %s (%s, %s)', a:idx, a:item.id,
        \ a:item.title, a:item.author, l:progress, s:TimeAgo(a:item.last_active))
endfunction

function! s:TimeAgo(ts) abort
  if a:ts <= 0
    return 'unknown'
  endif
  let l:d = localtime() - a:ts
  if l:d < 3600
    return max([l:d / 60, 1]) . 'm ago'
  elseif l:d < 86400
    return (l:d / 3600) . 'h ago'
  endif
  return (l:d / 86400) . 'd ago'
endfunction

function! s:OnResumeSelect(item, _idx) abort
  call s:StartWithMetadata(a:item.id, v:null)
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
  if get(l:lifetime, 'machines_count', 1) > 1
    call add(l:lines, printf('  Machines:  %d', l:lifetime.machines_count))
  endif
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
  if get(l:lifetime, 'best_wpm', 0) > 0
    call add(l:lines, printf('  Best WPM:  %d', l:lifetime.best_wpm))
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
