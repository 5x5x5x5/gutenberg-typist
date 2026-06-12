let s:base_dir = ''

function! s:GetBaseDir() abort
  if s:base_dir ==# ''
    let s:base_dir = expand('~/.vim/gutenberg-typist')
  endif
  return s:base_dir
endfunction

function! s:EnsureDir(path) abort
  if !isdirectory(a:path)
    call mkdir(a:path, 'p')
  endif
endfunction

function! s:ReadJson(path) abort
  if !filereadable(a:path)
    return v:null
  endif
  try
    let l:content = join(readfile(a:path), "\n")
    if l:content ==# ''
      return v:null
    endif
    return json_decode(l:content)
  catch
    return v:null
  endtry
endfunction

function! s:WriteJson(path, data) abort
  call s:EnsureDir(fnamemodify(a:path, ':h'))
  try
    let l:encoded = json_encode(a:data)
    call writefile([l:encoded], a:path)
    return v:true
  catch
    return v:false
  endtry
endfunction

function! s:ReadFile(path) abort
  if !filereadable(a:path)
    return v:null
  endif
  return join(readfile(a:path, 'b'), "\n")
endfunction

function! s:WriteFile(path, content) abort
  call s:EnsureDir(fnamemodify(a:path, ':h'))
  call writefile(split(a:content, "\n", 1), a:path, 'b')
  return v:true
endfunction

" Book text

function! s:BookDir(book_id) abort
  return s:GetBaseDir() . '/books/' . a:book_id
endfunction

function! gt#storage#SaveBookText(book_id, text) abort
  return s:WriteFile(s:BookDir(a:book_id) . '/text.txt', a:text)
endfunction

function! gt#storage#LoadBookText(book_id) abort
  return s:ReadFile(s:BookDir(a:book_id) . '/text.txt')
endfunction

function! gt#storage#SaveBookMetadata(book_id, metadata) abort
  return s:WriteJson(s:BookDir(a:book_id) . '/metadata.json', a:metadata)
endfunction

function! gt#storage#LoadBookMetadata(book_id) abort
  return s:ReadJson(s:BookDir(a:book_id) . '/metadata.json')
endfunction

" Sessions

function! s:SessionPath(book_id) abort
  return s:GetBaseDir() . '/sessions/' . a:book_id . '.json'
endfunction

function! gt#storage#SaveSession(book_id, session) abort
  let a:session.last_active = localtime()
  return s:WriteJson(s:SessionPath(a:book_id), a:session)
endfunction

function! gt#storage#LoadSession(book_id) abort
  return s:ReadJson(s:SessionPath(a:book_id))
endfunction

function! gt#storage#LastSession() abort
  let l:sessions_dir = s:GetBaseDir() . '/sessions'
  if !isdirectory(l:sessions_dir)
    return v:null
  endif
  let l:files = glob(l:sessions_dir . '/*.json', 0, 1)
  if empty(l:files)
    return v:null
  endif
  let l:latest = v:null
  let l:latest_time = 0
  for l:file in l:files
    let l:data = s:ReadJson(l:file)
    if l:data isnot v:null && has_key(l:data, 'last_active') && l:data.last_active > l:latest_time
      let l:latest = l:data
      let l:latest_time = l:data.last_active
    endif
  endfor
  return l:latest
endfunction

" Lifetime stats

function! s:StatsPath() abort
  return s:GetBaseDir() . '/lifetime_stats.json'
endfunction

function! gt#storage#LoadLifetimeStats() abort
  let l:data = s:ReadJson(s:StatsPath())
  if l:data is v:null
    return {
          \ 'total_chars': 0,
          \ 'correct_chars': 0,
          \ 'total_time_seconds': 0,
          \ 'sessions_count': 0,
          \}
  endif
  return l:data
endfunction

function! gt#storage#SaveLifetimeStats(stats) abort
  return s:WriteJson(s:StatsPath(), a:stats)
endfunction

" List cached books

function! gt#storage#ListCachedBooks() abort
  let l:books_dir = s:GetBaseDir() . '/books'
  if !isdirectory(l:books_dir)
    return []
  endif
  let l:dirs = glob(l:books_dir . '/*', 0, 1)
  let l:books = []
  for l:dir in l:dirs
    let l:id = fnamemodify(l:dir, ':t')
    let l:meta = gt#storage#LoadBookMetadata(l:id)
    if l:meta isnot v:null
      let l:meta.id = l:id
      call add(l:books, l:meta)
    endif
  endfor
  return l:books
endfunction
