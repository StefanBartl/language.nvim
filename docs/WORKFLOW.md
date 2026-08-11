# Workflow — getting real use out of language.nvim day to day

Every feature here is documented on its own elsewhere (`docs/FEATURES/`,
`docs/configuration.md`, `docs/BINDINGS.md`). This is the different
question: once spell-checking, translation, and the thesaurus all exist in
one plugin, how do they actually combine into a habit worth keeping,
rather than three commands you only remember when something's already
wrong.

## Start a spell session before you start typing, not after

`<leader>ss` toggles a session on the current buffer. The point of doing
it *before* writing prose (a commit message, a README section, this file)
rather than after is that `]s` / `<leader>z=` / `<leader>z1` become a tight
loop you interleave with writing, instead of a cleanup pass at the end:
write a paragraph, `]s` through whatever got flagged, `<leader>z1` to
accept-and-advance on the obvious ones, `<leader>z=` when you want to see
the suggestion list first. `<leader>ss` again ends the session and
restores `spelllang` — cheap enough to toggle per file, not something to
leave running globally.

## Native vs LSP vs external CLI: three sources feeding one panel

It's easy to assume "spell checking" is one thing here; it's actually
three sources that land in the same session/panel, and knowing which is
answering matters when a fix looks wrong:

- **Native `vim.spell`** — the buffer-scope default, always available,
  CamelCase/snake_case aware, restricted to Treesitter `@spell` regions
  so identifiers outside comments/strings never get flagged.
- **`harper_ls`/`ltex` (LSP)** — grammar and style, merged into the same
  list. These get a different fix action in the panel: "Apply LSP fix…"
  runs the language server's code action, not a suggestion picker —
  because there's no fixed word list to suggest from for a grammar issue.
- **External CLIs (`typos`/`cspell`/`codespell`)** — only kick in for
  `cwd`/`path` scope, and only if configured in
  `spell.providers.cwd`/`.buffer`. Without one configured, `cwd`/`path`
  falls back to a real recursive native disk walk, not just already-open
  buffers — worth knowing before assuming `:Spellcheck en cwd` only
  checked what you had open.

## `:Spellcheck cwd` on a large repo: check what's actually configured first

`:Spellcheck en cwd` behaves very differently depending on whether a CLI
provider is configured:

| Providers configured | What runs |
|---|---|
| `typos`/`cspell`/`codespell` in `spell.providers.cwd` | A single external process across the whole tree — fast, one pass |
| None configured | Native async walk, 20 files/tick, cancellable, skips `.git`/`node_modules`/`.venv`/`dist`/`build`/`target`/`.cache`/`__pycache__`, files >5MB, files over `max_file_lines` |

The native fallback is genuinely usable on a mid-sized repo (it shows
`lib.nvim.progress`), but on something large, install `typos` or `cspell`
and add it to `spell.providers.cwd` rather than relying on the fallback
by default — it exists to close a real gap (files not currently open
used to be silently skipped), not to be the primary path.

## The cspell sidecar is for live/buffer scope only, not cwd scans

`"cspell_server"` goes in `spell.providers.buffer`, not `.cwd` — it's a
persistent Node process (`node/cspell_server.js`) kept warm specifically
to make **live scanning** and interactive buffer checks near-instant
(no per-scan cold start), code-aware the way the `cspell` CLI is. If you
want fast checks while typing in code files, this is worth the `node` +
`cspell` install; if you only ever run occasional `cwd` sweeps, the CLI
providers are the right tool and the sidecar buys nothing there.

## `:Translate` vs `:TranslateReplace`: the trap if you remember the old behavior

`:Translate`'s default changed to `popup` — it shows the translation in a
read-only float and leaves the buffer untouched. If muscle memory expects
the old "select, translate, replace in place" behavior, that's
`:TranslateReplace` now, not `:Translate`. The motion/visual keymaps
(`translate.keymaps.operator`/`.visual`, both opt-in) still hardcode
`replace` regardless of the popup default, so `gtrip`-style operator use
is unaffected by this split — only the two commands changed.

```vim
:'<,'>Translate DE            " popup, buffer untouched
:'<,'>TranslateReplace DE     " selection replaced in place, the classic behavior
:Translate FR --output=vsplit " translation in a vertical split instead of a popup
```

## `--nocode` only matters when something actually gets written back

`--nocode` skips fenced/inline code spans during translation. It's a
no-op for `--output=popup`/`notify`/`clipboard` (nothing in the buffer
changes anyway) — reach for it specifically on `--output=replace` /
`:TranslateReplace` when the selection is a mixed prose+code block (a
markdown file with inline `` `code` `` spans you don't want mangled).

## Multi-file translate: read the confirmation before `--files=replace`

`:Translate <lang> cwd` opens a multi-select file picker (`<Tab>` to
toggle) and, by default, writes a **new**, language-suffixed sibling file
per selection (`notes.md` → `notes.DE.md`) — non-destructive. `--files=
replace` overwrites the originals in place and asks for confirmation
first; `--files=buffers` opens scratch buffers instead of touching disk
at all, useful for reviewing a translation before deciding where it goes.
`:TranslateReplace <lang> cwd` skips the choice and forces `replace`
directly — the fast path once you already trust the output.

## Indent-preserving translate: know when it silently steps aside

Leading whitespace is captured and re-applied per line, which keeps
indented markdown/code-comment lists intact through a round trip through
Google's `gtx` (which normalizes whitespace away on its own). This is
skipped automatically when the provider's output has a different line
count than the input (some providers merge or split lines) — the
untouched-indent fallback is deliberate, not a bug, but it means a
translated block that came back with a different line count won't have
re-applied indentation, and is worth a glance before assuming the
round-trip is exact.

## The interactive window doubles as a scratchpad for iterating on phrasing

`:Translate!` (optionally seeded from a visual selection) is worth
reaching for over the popup/replace flow specifically when you're not
sure of the exact source text yet — type, watch the live output update,
`<C-l>` to try a different target language without leaving the float,
`<C-r>` to promote the current output back into the input and translate
*that* onward (chaining DE → EN → FR to sanity-check a round trip),
`<C-h>` to pull a past query back in via history, `<C-y>` to copy the
current result out without applying anything to the buffer.

## `guard.block_write_on_error`: know the bypass before you need it

Opt-in `spell.guard.block_write_on_error = true` aborts `:w` while
spelling errors remain on a matching filetype — a real forcing function
for finishing docs, not just checking them later. When it fires on a
false positive (a name, a term not in the dictionary yet), `:noautocmd w`
is the escape hatch — faster than turning the guard off, disabling the
session, or adding a directive you don't actually want long-term.

## Silencing without disabling the whole session

For a genuine one-off false positive inline, `language:disable-line` /
`-next-line` / `-file` in a comment beats toggling `highlights.enable` or
ending the session — it's scoped to exactly the line/file it's written
on and survives re-scans. Reserve the persistent ignore list and
`dictionary.replace_all` (from the fix picker) for words that are correct
*everywhere in this project* (identifiers, product names), not for a
single sentence's exception.

## Thesaurus is a single opt-in map, not a mode

`require("language").synonyms()` (or its opt-in keymap) replaces the word
under the cursor in place — there's no picker between multiple
candidates by default, it takes the API's top result. Worth binding if
you write prose regularly; not worth reaching for `:Translate` as a
thesaurus substitute (translating a word to the same language doesn't
reliably return synonyms the way Datamuse's `/words?rel_syn=` does).
