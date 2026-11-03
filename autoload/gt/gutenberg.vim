" Async HTTP via job_start, accumulating stdout into a context dict

function! s:HttpGet(url, Callback) abort
  let l:ctx = {'data': '', 'Callback': a:Callback, 'done': 0, 'closed': 0, 'status': v:null}

  function! l:ctx.on_out(_ch, msg) abort
    let self.data .= a:msg
  endfunction

  function! l:ctx.finish() abort
    if self.done || !self.closed || self.status is v:null
      return
    endif
    let self.done = 1
    let l:result = self.data
    let l:Cb = self.Callback
    let l:status = self.status
    if l:status == 0
      call timer_start(0, {-> l:Cb(l:result, v:null)})
    else
      call timer_start(0, {-> l:Cb(v:null, 'curl failed (exit ' . l:status . ')')})
    endif
  endfunction

  function! l:ctx.on_close(_ch) abort
    let self.closed = 1
    call self.finish()
  endfunction

  function! l:ctx.on_exit(_job, code) abort
    let self.status = a:code
    call self.finish()
  endfunction

  try
    " --fail converts HTTP 4xx/5xx responses into a nonzero exit status.
    " curl also returns nonzero for interrupted/partial transfers.
    let l:job = job_start(['curl', '-sSL', '--fail', '--max-time', '30', a:url], {
          \ 'out_cb': l:ctx.on_out,
          \ 'close_cb': l:ctx.on_close,
          \ 'exit_cb': l:ctx.on_exit,
          \ 'out_mode': 'raw',
          \})
    if job_status(l:job) ==# 'fail'
      let l:ctx.status = 127
      let l:ctx.closed = 1
      call l:ctx.finish()
    endif
  catch
    let l:ctx.status = 127
    let l:ctx.closed = 1
    call l:ctx.finish()
  endtry
endfunction

function! s:PlainTextUrl(metadata) abort
  if type(a:metadata) != v:t_dict
    return ''
  endif
  let l:url = get(a:metadata, 'download_url', '')
  if type(l:url) == v:t_string && s:IsDownloadUrl(l:url)
    return l:url
  endif
  let l:formats = get(a:metadata, 'formats', {})
  if type(l:formats) != v:t_dict
    return ''
  endif
  " Gutendex format keys include parameters (for example charset=utf-8).
  " Keep only a URL advertised for text/plain.
  let l:keys = sort(keys(l:formats), {a, b -> s:FormatPriority(a) - s:FormatPriority(b)})
  for l:key in l:keys
    let l:candidate = l:formats[l:key]
    if l:key =~? '^text/plain\>' && type(l:candidate) == v:t_string && s:IsDownloadUrl(l:candidate)
      return l:candidate
    endif
  endfor
  return ''
endfunction

function! s:FormatPriority(key) abort
  if a:key !~? '^text/plain\>'
    return 2
  endif
  return a:key =~? 'charset=utf-8' ? 0 : 1
endfunction

function! s:IsDownloadUrl(url) abort
  if a:url !~# '^https\=://'
    return 0
  endif
  let l:path = tolower(split(a:url, '[?#]', 1)[0])
  return l:path !~# '\.zip$'
endfunction

function! gt#gutenberg#Search(query, Callback) abort
  let l:cfg = gt#config#Get()
  let l:params = [
        \ 'search=' . gt#util#UriEncode(a:query),
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
          \ 'download_url': s:PlainTextUrl(l:book),
          \ 'formats': get(l:book, 'formats', {}),
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

function! gt#gutenberg#Download(book_id, Callback) abort
  call s:DownloadUrl(a:book_id, '', a:Callback)
endfunction

function! s:DownloadUrl(book_id, url, Callback) abort
  " Check cache first
  let l:cached = gt#storage#LoadBookText(a:book_id)
  if l:cached isnot v:null
    call a:Callback(l:cached, v:null)
    return
  endif

  let l:cfg = gt#config#Get()
  let l:url = a:url !=# '' ? a:url : printf(l:cfg.gutenberg.book_url, a:book_id, a:book_id)

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
  try
    if !gt#storage#SaveBookText(a:book_id, l:cleaned)
      call a:Callback(v:null, 'Failed to cache downloaded book')
      return
    endif
  catch
    call a:Callback(v:null, 'Failed to cache downloaded book: ' . v:exception)
    return
  endtry

  call a:Callback(l:cleaned, v:null)
endfunction

function! gt#gutenberg#DownloadWithMetadata(book_id, metadata, Callback) abort
  let l:metadata = a:metadata
  if a:metadata isnot v:null
    call gt#storage#SaveBookMetadata(a:book_id, a:metadata)
  else
    let l:metadata = gt#storage#LoadBookMetadata(a:book_id)
  endif
  call s:DownloadUrl(a:book_id, s:PlainTextUrl(l:metadata), a:Callback)
endfunction

function! gt#gutenberg#ListCached() abort
  return gt#storage#ListCachedBooks()
endfunction
