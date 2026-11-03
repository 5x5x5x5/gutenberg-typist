" Optional guild publishing. Load with :runtime extras/guild/plugin/gt_guild.vim
if exists('g:loaded_gt_guild')
  finish
endif
let g:loaded_gt_guild = 1
execute 'set runtimepath+=' . escape(fnamemodify(expand('<sfile>:p'), ':h:h'), ' ,')
command! GTGuildPublish call gt#hub#Publish()
