" Async HTTP via job_start, accumulating stdout into a context dict

function! s:HttpGet(url, Callback) abort
  let l:ctx = {'data': '', 'Callback': a:Callback}

  function! l:ctx.on_out(_ch, msg) abort
    let self.data .= a:msg
  endfunction

  function! l:ctx.on_close(_ch) abort
    let l:result = self.data
    let l:Cb = self.Callback
    " Schedule callback to avoid channel-callback restrictions
    call timer_start(0, {-> l:Cb(l:result, v:null)})
  endfunction

  let l:job = job_start(['curl', '-sL', '--max-time', '30', a:url], {
        \ 'out_cb': l:ctx.on_out,
        \ 'close_cb': l:ctx.on_close,
        \ 'out_mode': 'raw',
        \})

  if job_status(l:job) ==# 'fail'
    call timer_start(0, {-> a:Callback(v:null, 'Failed to start curl')})
  endif
endfunction

function! gut_typist#gutenberg#Search(query, Callback) abort
  let l:cfg = gut_typist#config#Get()
  let l:params = [
        \ 'search=' . gut_typist#util#UriEncode(a:query),
        \ 'languages=en',
        \ 'mime_type=text%2Fplain',
        \]
  let l:url = l:cfg.gutenberg.search_url . '?' . join(l:params, '&')

  call s:HttpGet(l:url, function('s:OnSearchResult', [a:Callback]))
endfunction

function! s:OnSearchResult(Callback, body, err) abort
  if a:err isnot v:null
    call a:Callback(v:null, a:err)
    return
  endif
  try
    let l:data = json_decode(a:body)
  catch
    call a:Callback(v:null, 'Failed to parse search results')
    return
  endtry
  if type(l:data) != v:t_dict
    call a:Callback(v:null, 'Unexpected response from Gutenberg API')
    return
  endif
  let l:results = []
  for l:book in get(l:data, 'results', [])
    let l:authors = []
    for l:a in get(l:book, 'authors', [])
      call add(l:authors, l:a.name)
    endfor
    call add(l:results, {
          \ 'id': l:book.id,
          \ 'title': get(l:book, 'title', 'Untitled'),
          \ 'authors': l:authors,
          \ 'author': join(l:authors, ', '),
          \ 'download_count': get(l:book, 'download_count', 0),
          \})
  endfor
  call a:Callback(l:results, v:null)
endfunction

function! s:StripGutenbergHeaderFooter(text) abort
  let l:text = a:text
  " Strip header
  let l:start = match(l:text, '\*\*\* START OF TH[IE]S\= PROJECT GUTENBERG')
  if l:start >= 0
    let l:line_end = stridx(l:text, "\n", l:start)
    if l:line_end >= 0
      let l:text = strpart(l:text, l:line_end + 1)
    endif
  endif
  " Strip footer
  let l:end_pos = match(l:text, '\*\*\* END OF TH[IE]S\= PROJECT GUTENBERG')
  if l:end_pos >= 0
    let l:text = strpart(l:text, 0, l:end_pos)
  endif
  " Trim leading/trailing whitespace
  let l:text = substitute(l:text, '^\s\+', '', '')
  let l:text = substitute(l:text, '\s\+$', '', '')
  return l:text
endfunction

function! gut_typist#gutenberg#Download(book_id, Callback) abort
  " Check cache first
  let l:cached = gut_typist#storage#LoadBookText(a:book_id)
  if l:cached isnot v:null
    call a:Callback(l:cached, v:null)
    return
  endif

  let l:cfg = gut_typist#config#Get()
  let l:url = printf(l:cfg.gutenberg.book_url, a:book_id, a:book_id)

  call s:HttpGet(l:url, function('s:OnDownloadResult', [a:book_id, a:Callback]))
endfunction

function! s:OnDownloadResult(book_id, Callback, body, err) abort
  if a:err isnot v:null
    call a:Callback(v:null, a:err)
    return
  endif
  if a:body is v:null || strlen(a:body) == 0
    call a:Callback(v:null, 'Empty response from Gutenberg')
    return
  endif

  let l:cleaned = s:StripGutenbergHeaderFooter(a:body)
  " Normalize line endings
  let l:cleaned = substitute(l:cleaned, "\r\n", "\n", 'g')
  let l:cleaned = substitute(l:cleaned, "\r", "\n", 'g')

  " Cache locally
  call gut_typist#storage#SaveBookText(a:book_id, l:cleaned)

  call a:Callback(l:cleaned, v:null)
endfunction

function! gut_typist#gutenberg#DownloadWithMetadata(book_id, metadata, Callback) abort
  if a:metadata isnot v:null
    call gut_typist#storage#SaveBookMetadata(a:book_id, a:metadata)
  endif
  call gut_typist#gutenberg#Download(a:book_id, a:Callback)
endfunction

function! gut_typist#gutenberg#ListCached() abort
  return gut_typist#storage#ListCachedBooks()
endfunction
