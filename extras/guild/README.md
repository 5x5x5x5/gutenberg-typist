# Optional guild publishing

Enable the companion after installing gutenberg-typist:

```vim
runtime extras/guild/plugin/gt_guild.vim
let g:gt_hub_url = 'https://your-guild.example'
let g:gt_hub_token = 'gt_...'
```

Get the actual URL and token from your board's `/account` page. Run
`:GTGuildPublish` to export closed sessions and upload the bundle asynchronously.
The response is available as `g:gt_hub_last`. HTTP and transport failures are
reported; failed uploads can be retried safely because records merge by id.

This command replaces `:GT publish`. Export/import and all typing features work
without loading this companion. You can also upload a `:GT export` file manually
on the board's account page.
