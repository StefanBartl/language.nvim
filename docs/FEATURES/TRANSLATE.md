# Translate

Translating text with a choice of engines and output destinations, none of
which require an external Neovim plugin — only `curl` for the default
keyless engine.

## `:Translate` / `:TranslateReplace`

`:Translate` translates a range/selection and, by default, shows the
result in a read-only, focusable `ui.kit` popup — the buffer
stays untouched. `--output=` selects an alternative destination:
`replace`/`buffer`/`vsplit`/`split`/`tab`/`insert`/`clipboard`/`notify`.
`:TranslateReplace` is the direct, mutating counterpart — always
`replace`, no `--output=` flag — restoring the classic "select, translate,
replace" workflow under its own name. `--nocode` skips fenced and inline
code spans (relevant to replace-style output only).

- **Tab:** true
- **Module:** `translate/init.lua`, `translate/output/init.lua`
- **Usercmds:** `:Translate <lang> [--nocode|--output=<m>|--files=<m>] [cword|selection|buffer|cwd|path=<p>]`, `:TranslateReplace <lang> [--nocode] [selection|buffer|cwd|path=<p>]` — [user commands](../BINDINGS.md#user-commands)
- **One word:** the `cword` scope, and — with hover.nvim installed — `:Hover show` over a word. See [HOVER.md](HOVER.md).
- **Config:** `opts.translate.default_output` (default `"popup"`), `opts.translate.engine` (default `"google"`)

An unrecognized `--flag` is now a reported error (composer's declared-flags
gate runs before the handler), not silently ignored as it was
pre-composer.

## Engines with fallback chain

Google (keyless `gtx` endpoint, default, zero configuration), DeepL
(`deepl.api_key` or `$DEEPL_API_KEY`), `translate-shell`, or a custom CLI —
`opts.translate.fallback` is an ordered list tried if the selected engine
is unavailable.

- **Module:** `translate/providers/{google,deepl,shell,custom,registry}.lua`
- **Config:** `opts.translate.engine`, `opts.translate.fallback` (default `{"google"}`), `opts.translate.deepl.api_key`

### Large inputs: chunking

Windows rejects a command line above roughly 32 700 characters
(`ENAMETOOLONG`), and the engines have limits of their own, so no provider
ever receives an arbitrarily large payload. `providers/registry.lua` wraps
every engine with `translate/chunk.lua`, which cuts the input into blocks on
line boundaries (preferring blank lines), translates them one after the
other through the unchanged provider and joins the results; the line count
is preserved, which the indent restoration relies on. This applies to the
command, the operators, the window, the hover and multi-file translation.

The budget is counted in **cost units**, which are bytes of the text plus one
per line for the separator -- except DeepL, which counts 8 extra per line for
the JSON quoting of each text. This is the unit of `translate.max_chars`.

| Engine | Block budget (cost units) | Payload |
| --- | --- | --- |
| google | 15 000 | POST body on stdin (`--data-urlencode q@-`): neither in the URL nor in argv |
| shell | 6000 on Windows, 20 000 elsewhere | argv (one element) |
| custom | same as shell; `translate.custom.max_bytes` replaces it | whatever `cmd` builds |
| deepl | 50 lines, 60 000 | key **and** JSON body on stdin (`curl -K -`), never argv |

- **Blank lines at the edge of a block are layout, not content.** The engines
  trim them (gtx drops leading and trailing newlines, `trans` output is
  right-trimmed, a custom `vim.split(out, "\n")` adds a trailing empty
  string), so they are not sent and are put back around the result; a block
  that is blank throughout is not sent at all. Without this every cut at a
  paragraph break would lose a line and merge two paragraphs.
- **A single line over the budget is cut, not refused.** It is split at
  sentence ends (`. ! ? ;` before white space, and the CJK `。！？；`), else at
  white space, never inside a UTF-8 character; the pieces are translated in
  blocks of their own and re-joined with a single space, so the input line
  stays one output line. Only a line that has no such boundary inside the
  budget (one giant token, e.g. minified JSON or base64) fails the call, with
  a message naming the line.
- `opts.translate.max_chars` (cost units, `0` = engine default) can only lower
  the budget; `opts.translate.custom.max_bytes` is the one way to raise the
  `custom` budget, for a `cmd` that does not put the text into argv.
- `opts.translate.max_blocks` (default `50`, `0` = no limit) refuses an input
  that would need more requests than that, before the first one is sent, with
  a message naming the option. A large buffer or file is otherwise fired off
  request by request (the keyless gtx endpoint rate-limits), and everything
  sent before a late failure has already left the machine.
- `opts.translate.timeout_ms` applies to **each request**, not to the whole
  call: a chunked input can take up to `blocks * timeout_ms`.
- A failing block fails the whole call (one callback, with the block and
  line range in the message); `cancel` stops the running block and the rest.
- `util/job.run` reports a spawn failure through `on_done(false, ...)`
  instead of throwing, and `translate.files.process` turns a failure into a
  failed file while the remaining files carry on.
- **Windows launchers that are not `.exe`** (an npm-style or `.cmd`/`.bat`
  shim for `trans` or a custom engine) are started through `cmd.exe /c`, and
  its parser would interpret a `"`, `%`, `^`, `&`, `|`, `<`, `>` or line break
  inside the translated text. `util/job.run` refuses such a command with a
  message instead of running it; use an `.exe` for the engine (or one of the
  curl-based engines) to translate arbitrary text.

## Custom translate provider

`translate.custom = { cmd = function(lines, target) return {"trans", "-b", ...} end, parse = function(out) return vim.split(out, "\n") end }` —
an escape hatch mirroring `spell.providers.custom`. `cmd` receives one block
of lines (see [chunking](#large-inputs-chunking)); a trailing empty entry in
what `parse` returns is dropped when the block has gained a line.

- **Module:** `translate/providers/custom.lua`
- **Config:** `opts.translate.custom` (`cmd`, `parse`, optional `max_bytes`)

## Indent-preserving round trip

Each line's leading whitespace is captured before translating the dedented
text, then re-prepended to the matching output line — closes a gap where
providers (notably Google's `gtx`) normalize away leading whitespace,
which would otherwise drop indented list items to column 0. Skipped when
the provider merges or splits lines (line counts no longer match 1:1).

- **Module:** `translate/indent.lua`

## Column-precise selection

Char-wise motions (e.g. `<lhs>iw`) and char-wise visual selections
translate the exact byte span (multibyte-safe via `getregionpos`) and
replace it in place, rather than falling back to whole-line replacement.
Line-wise and block-wise selections still use the line range.

- **Module:** `translate/init.lua` (`run_region`)

## Motion/visual translate maps

Opt-in operator (`{lhs}{motion}` translates the moved-over text object,
e.g. `gtrip`) and visual-mode map (translates the current selection).
Target is `translate.default_target` if set, otherwise a quick picker.
Both always replace in place regardless of the popup default used by
`:Translate`.

- **Module:** `translate/motion.lua`
- **Config:** `opts.translate.keymaps.operator` (default `false`), `opts.translate.keymaps.visual` (default `false`), `opts.translate.keymaps.to` (default `{}`), `opts.translate.default_target`

### Choosing the target from the keymap (2026-08-24)

With `default_target` set the operator always used it and never asked;
without one it always asked. Neither is "translate this bit into Spanish,
just now" — the flag/option audit's entry.

`translate.keymaps.to` is one key per language:

```lua
translate = { keymaps = { to = { EN = "<leader>tE", DE = "<leader>tD" } } },
```

Each key works in normal (operator) and visual mode and forces that target
for a **single** run — the force is consumed by the next `choose_target`, so
it never leaks into the following unforced one.

A count could not carry the language: on an operator the count belongs to the
motion (`3{lhs}w` is three words), which is the whole point of having an
operator. Hence a key per language, which is what the audit suggested as well.
Unset by default.

- **Module:** `translate/motion.lua` (`force_target`, `choose_target`)

## Interactive translate window

`:Translate!` opens a two-pane float — editable input, live output —
that translates as you type. `<C-l>` retargets the language, `<C-y>`
copies the result, `<C-h>` opens the history picker, `<C-r>` promotes the
current translation to the input and picks a new target (round-trip/
reverse translation). `q`/`<Esc>`/`<C-c>` closes it. Prefilled from a
range/selection when given one (`:'<,'>Translate! DE`).

- **Module:** `translate/window.lua`
- **Usercmds:** `:Translate!` — [user commands](../BINDINGS.md#user-commands)

## Query history

Records `:Translate` results and window copies in a newest-first ring,
with optional JSON persistence across restarts. Recall via the window's
`<C-h>` picker or `require("language").translate_history()`.

- **Module:** `translate/history.lua`

## Multi-file translation

`:Translate <lang> cwd` (or `path=<dir>`) gathers translatable files under
the target, multi-selects via the `ui.kit` chooser (`<Tab>`), and
translates each — writing a language-suffixed sibling file by default
(`name.DE.ext`), overwriting in place with `--files=replace` (confirmed),
or opening scratch buffers with `--files=buffers`.
`:TranslateReplace <lang> cwd` forces file-mode `replace`.

- **Module:** `translate/files.lua`
- **Config:** `opts.translate.files.output`
