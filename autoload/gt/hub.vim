" Publish stats to the typist guild: export a v1 bundle to a temp file and
" POST it with async curl. The board's /account page issues the token.
" g:gt_hub_url exists for self-hosted guilds and the test harness.

let s:default_hub = 'https://typist-guild.example.workers.dev'

function! gt#hub#Url() abort
  return substitute(get(g:, 'gt_hub_url', s:default_hub), '/\+$', '', '')
endfunction

function! gt#hub#Publish() abort
  let l:token = get(g:, 'gt_hub_token', '')
  if l:token ==# ''
    echohl WarningMsg
    echomsg 'GT: Set g:gt_hub_token first — get one at ' . gt#hub#Url() . '/account'
    echohl None
    return
  endif

  let l:tmp = tempname() . '.json'
  let l:res = gt#storage#ExportBundle(l:tmp)
  if !l:res.ok
    echohl WarningMsg | echomsg 'GT: ' . l:res.msg | echohl None
    return
  endif

  let l:ctx = {'data': '', 'tmp': l:tmp}
  function! l:ctx.on_out(_ch, msg) abort
    let self.data .= a:msg
  endfunction
  function! l:ctx.on_close(_ch) abort
    call delete(self.tmp)
    let l:body = self.data
    " Schedule callback to avoid channel-callback restrictions
    call timer_start(0, {-> s:OnPublished(l:body)})
  endfunction

  let l:job = job_start(['curl', '-s', '--max-time', '30',
        \ '-X', 'POST', gt#hub#Url() . '/api/v1/upload',
        \ '-H', 'Authorization: Bearer ' . l:token,
        \ '-H', 'Content-Type: application/json',
        \ '--data-binary', '@' . l:tmp], {
        \ 'out_cb': l:ctx.on_out,
        \ 'close_cb': l:ctx.on_close,
        \ 'out_mode': 'raw',
        \})

  if job_status(l:job) ==# 'fail'
    call delete(l:tmp)
    echohl ErrorMsg | echomsg 'GT: Failed to start curl' | echohl None
  else
    echomsg 'GT: Publishing to ' . gt#hub#Url() . ' ...'
  endif
endfunction

function! s:OnPublished(body) abort
  try
    let l:data = json_decode(a:body)
  catch
    let l:data = v:null
  endtry
  if type(l:data) != v:t_dict
    echohl ErrorMsg
    echomsg 'GT: Publish failed — no response from the guild (offline?)'
    echohl None
    return
  endif
  " Kept for :echo g:gt_hub_last debugging and the test harness.
  let g:gt_hub_last = l:data
  if has_key(l:data, 'error')
    echohl WarningMsg | echomsg 'GT: Guild rejected the upload: ' . l:data.error | echohl None
    return
  endif
  let l:msg = printf('GT: Published %d new session(s) — #%d of %d (best %d wpm)',
        \ get(l:data, 'new_sessions', 0), l:data.rank, l:data.total_users, l:data.best_wpm)
  if get(l:data, 'suspicious', v:false)
    let l:msg .= ' — flagged as implausible (honor system!)'
  endif
  echomsg l:msg
endfunction
