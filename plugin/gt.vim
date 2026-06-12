" gutenberg-typist: Touch typing practice with Project Gutenberg books
" Requires Vim 8.2+

if exists('g:loaded_gt')
  finish
endif
let g:loaded_gt = 1

" Define highlight groups (default = user can override)
function! s:DefineHighlights() abort
  highlight default GTCorrect gui=bold guifg=#50fa7b cterm=bold ctermfg=Green
  highlight default GTWrong gui=bold guifg=#ff5555 guibg=#44475a cterm=bold ctermfg=Red ctermbg=DarkGray
  highlight default GTUntyped guifg=#6272a4 ctermfg=Gray
  highlight default GTCursor gui=bold guifg=#282a36 guibg=#f8f8f2 cterm=bold ctermfg=Black ctermbg=White
endfunction

call s:DefineHighlights()

augroup GTHighlights
  autocmd!
  autocmd ColorScheme * call s:DefineHighlights()
augroup END

command! -nargs=+ -complete=customlist,gt#Complete GT call gt#Command(<f-args>)
