# gutenberg-typist

A Vim plugin for touch typing practice using books from [Project Gutenberg](https://www.gutenberg.org/).

Learned to type with [GNU gtypist](https://www.gnu.org/software/gtypist/)? This is the graduation: no more drills — keep your fingers sharp on the real thing, from *Moby-Dick* to *Ulysses*. Then compare notes at the [typist guild](https://5x5x5x5.github.io/typist-guild/).

Search for any book, and gutenberg-typist opens a split-pane view: the source text on the left with per-character color feedback, and a typing buffer on the right. Real-time WPM, accuracy, and progress are displayed in the statusline. Sessions are saved automatically so you can pick up where you left off.

## Requirements

- Vim 8.2+
- `curl` on PATH

## Installation

### Native Vim 8 packages (no plugin manager)

Works on a fresh Vim install — no extra tools required. Run from any directory:

```sh
mkdir -p ~/.vim/pack/plugins/start
git clone https://github.com/5x5x5x5/gutenberg-typist \
  ~/.vim/pack/plugins/start/gutenberg-typist
```

Restart Vim, then try it:

```vim
:GT search pride prejudice
```

For `:help gt`, generate the help tags once:

```vim
:helptags ALL
```

### vim-plug

```vim
Plug '5x5x5x5/gutenberg-typist'
```

Then run `:PlugInstall`.

### Manual (custom location)

Clone the repo anywhere and add it to your runtime path in `~/.vimrc`:

```vim
set rtp+=~/code/gutenberg-typist
```

No `Setup()` call is needed — the plugin loads itself. Only call
`gt#Setup({...})` if you want to override defaults (see Configuration).

## Usage

| Command | Description |
|---|---|
| `:GT search <query>` | Search Project Gutenberg and pick a book |
| `:GT start <book_id>` | Start typing a book by its Gutenberg ID |
| `:GT resume` | Resume an in-progress book (picker when there are several) |
| `:GT stop` | Save progress and close |
| `:GT stats` | Show session and lifetime statistics |
| `:GT library` | Browse previously downloaded books |
| `:GT export [file]` | Export stats and book progress to a portable bundle |
| `:GT import <file>` | Merge a bundle exported on another machine |

### Quick start

```vim
:GT search pride prejudice
```

Select a book from the picker, and start typing. Characters in the source pane turn green when correct, red when wrong. Press `:GT stop` to save and quit, `:GT resume` to continue later.

### Special characters

Books keep their original typography — em dashes, curly quotes, accented words like *fiancée*. Type them with Vim digraphs: `CTRL-K` plus two characters in insert mode (`CTRL-K -M` → —). See the [digraphs guide](https://5x5x5x5.github.io/gutenberg-typist/digraphs.html) or `:help gt-digraphs`.

## Highlights

These highlight groups are defined with `highlight default` so you can override them in your colorscheme:

| Group | Default | Purpose |
|---|---|---|
| `GTCorrect` | green, bold | Correctly typed character |
| `GTWrong` | red on dark bg, bold | Mistyped character |
| `GTUntyped` | gray | Not yet reached |
| `GTCursor` | inverse | Next character to type |

## Configuration

All options are optional. Defaults shown below:

```vim
call gt#Setup({
      \ 'split_ratio': 0.5,
      \ 'save_interval_ms': 5000,
      \ 'wpm_window_seconds': 10,
      \})
```

Progress is checkpointed every `save_interval_ms` while it changes, and saved
when a typing pane closes or Vim exits. A failed write is reported in Vim.
Character counts include Unicode characters, whitespace, and punctuation.
Accuracy is correct final characters divided by final characters plus corrections;
WPM uses five characters per word. Live WPM uses the rolling window; the final
recap uses active session time, excluding gaps longer than five seconds.

## Data storage

Books and session data default to `~/.vim/gutenberg-typist/`. To use another
location, set `let g:gt_data_dir = '/path/to/typing-data'` before using the plugin.

The directory contains:

```
books/{id}/text.txt        -- cleaned book text
books/{id}/metadata.json   -- title, author
sessions/{id}.json         -- typing progress
session_log.json           -- one immutable record per typing session
```

Each finished session appends one record: machine, date, book, characters,
errors, corrections, active typing time. No keystroke timings and no
clock times appear in session records — dates only. Portable bundles also carry
per-book `last_active` timestamps for resume conflict resolution. The full format is
[SPEC.md](https://github.com/5x5x5x5/typist-guild/blob/main/SPEC.md) in
the typist-guild repo.

## Syncing stats between machines

Sessions are recorded per machine and merge cleanly, so you can practice
on several machines and combine the results:

```vim
" On machine A:
:GT export                 " writes ~/gutenberg-typist-export.json
" ...copy the file to machine B (scp, Drive, USB)...
" On machine B:
:GT import ~/gutenberg-typist-export.json
```

Importing is set union: records are immutable and keyed by id, so
re-importing the same bundle, or an older one, adds nothing and never
double-counts. Book progress (for `:GT resume`) rides along and merges
newest-wins per book.

Machine identity defaults to `hostname()`. Override it if two of your
machines share a hostname, or to keep hostnames out of bundles you share:

```vim
let g:gt_machine_id = 'my-laptop'
```

Set it before your first session if you plan to use it: renaming an
existing machine starts a fresh record, and the old history stays under
the previous name (totals remain correct, shown as an extra machine in
`:GT stats`).

## The optional leaderboard companion

The core plugin exports portable bundles. Upload one on your guild board's
`/account` page, or enable the bundled companion for uploads from Vim:

```vim
runtime extras/guild/plugin/gt_guild.vim
let g:gt_hub_url = 'https://your-guild.example'
let g:gt_hub_token = 'gt_...'
```

Use the URL and token supplied by your board, then run `:GTGuildPublish`.
This replaces the former core `:GT publish` command. Publishing remains
idempotent: the guild merges immutable records by id. See
[the companion instructions](extras/guild/README.md).

## Development

Run the offline regression tests with Python 3 and Vim installed:

```sh
python3 -m unittest discover -s test -p 'test_*.py'
bash test/verify_portable_stats.sh
```

Tests use temporary data directories and fake curl processes; no live service
or token is needed.

## License

MIT
