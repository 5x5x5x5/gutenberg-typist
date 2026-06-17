let s:initialized = v:false

function! s:EnsureTypes() abort
  if s:initialized
    return
  endif
  let s:initialized = v:true
  for l:name in ['GTCorrect', 'GTWrong', 'GTUntyped', 'GTCursor']
    if empty(prop_type_get(l:name))
      call prop_type_add(l:name, {'highlight': l:name, 'priority': 100})
    endif
  endfor
endfunction

function! gt#highlight#Apply(source_buf, source_lines, typed_len, matches, visible_top, visible_bot) abort
  call s:EnsureTypes()

  let l:cfg = gt#config#Get()
  let l:hl = l:cfg.highlights

  " Clear existing props in buffer
  for l:type_name in [l:hl.correct, l:hl.wrong, l:hl.untyped, l:hl.cursor]
    call prop_remove({'type': l:type_name, 'bufnr': a:source_buf, 'all': v:true})
  endfor

  " Calculate character offset for visible_top (0-indexed)
  let l:offset = 0
  let l:i = 0
  while l:i < a:visible_top
    if l:i < len(a:source_lines)
      let l:offset += strlen(a:source_lines[l:i]) + 1  " +1 for \n
    endif
    let l:i += 1
  endwhile

  " Check if we can use prop_add_list for batching
  let l:has_batch = exists('*prop_add_list')
  let l:batch = {}
  if l:has_batch
    let l:batch[l:hl.correct] = []
    let l:batch[l:hl.wrong] = []
    let l:batch[l:hl.untyped] = []
    let l:batch[l:hl.cursor] = []
  endif

  let l:line_idx = a:visible_top
  while l:line_idx <= a:visible_bot
    let l:line_num = l:line_idx + 1  " 1-indexed into source_lines
    if l:line_num > len(a:source_lines)
      break
    endif
    let l:line = a:source_lines[l:line_idx]
    let l:line_offset = l:offset

    let l:col = 0
    " l:col walks byte offsets (text properties are byte-addressed); \zs
    " splits on character boundaries so strlen gives each char's byte length.
    for l:ch in split(l:line, '\zs')
      let l:char_len = strlen(l:ch)
      let l:char_pos = l:line_offset + l:col + 1  " 1-indexed into matches

      if l:char_pos == a:typed_len + 1
        let l:hl_group = l:hl.cursor
      elseif l:char_pos <= a:typed_len
        if has_key(a:matches, l:char_pos) && a:matches[l:char_pos]
          let l:hl_group = l:hl.correct
        else
          let l:hl_group = l:hl.wrong
        endif
      else
        let l:hl_group = l:hl.untyped
      endif

      " prop_add uses 1-based line, 1-based column
      let l:prop_line = l:line_idx + 1
      let l:prop_col = l:col + 1

      if l:has_batch
        call add(l:batch[l:hl_group], [l:prop_line, l:prop_col, l:prop_line, l:prop_col + l:char_len])
      else
        call prop_add(l:prop_line, l:prop_col, {
              \ 'type': l:hl_group,
              \ 'length': l:char_len,
              \ 'bufnr': a:source_buf,
              \})
      endif

      let l:col += l:char_len
    endfor

    let l:offset += strlen(l:line) + 1  " +1 for \n
    let l:line_idx += 1
  endwhile

  " Flush batches
  if l:has_batch
    for [l:type_name, l:positions] in items(l:batch)
      if !empty(l:positions)
        call prop_add_list({'type': l:type_name, 'bufnr': a:source_buf}, l:positions)
      endif
    endfor
  endif
endfunction

function! gt#highlight#Clear(source_buf) abort
  call s:EnsureTypes()
  for l:name in ['GTCorrect', 'GTWrong', 'GTUntyped', 'GTCursor']
    call prop_remove({'type': l:name, 'bufnr': a:source_buf, 'all': v:true})
  endfor
endfunction
