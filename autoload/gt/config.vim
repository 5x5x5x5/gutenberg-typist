let s:defaults = {
      \ 'split_ratio': 0.5,
      \ 'gutenberg': {
      \   'search_url': 'https://gutendex.com/books',
      \   'book_url': 'https://www.gutenberg.org/cache/epub/%d/pg%d.txt',
      \ },
      \ 'highlights': {
      \   'correct': 'GTCorrect',
      \   'wrong': 'GTWrong',
      \   'untyped': 'GTUntyped',
      \   'cursor': 'GTCursor',
      \ },
      \ 'save_interval_ms': 5000,
      \ 'wpm_window_seconds': 10,
      \}

let s:values = deepcopy(s:defaults)

function! gt#config#Apply(opts) abort
  let s:values = s:DeepExtend(deepcopy(s:defaults), a:opts)
endfunction

function! gt#config#Get() abort
  return s:values
endfunction

function! s:DeepExtend(base, override) abort
  for [l:key, l:val] in items(a:override)
    if type(l:val) == v:t_dict && has_key(a:base, l:key) && type(a:base[l:key]) == v:t_dict
      let a:base[l:key] = s:DeepExtend(a:base[l:key], l:val)
    else
      let a:base[l:key] = l:val
    endif
  endfor
  return a:base
endfunction
