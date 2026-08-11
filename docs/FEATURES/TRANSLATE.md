# Translate

Translating text with a choice of engines and output destinations, none of
which require an external Neovim plugin — only `curl` for the default
keyless engine.

## `:Translate` / `:TranslateReplace`

`:Translate` translates a range/selection and, by default, shows the
result in a read-only, focusable `lib.nvim.ui.kit` popup — the buffer
stays untouched. `--output=` selects an alternative destination:
`replace`/`buffer`/`vsplit`/`split`/`tab`/`insert`/`clipboard`/`notify`.
`:TranslateReplace` is the direct, mutating counterpart — always
`replace`, no `--output=` flag — restoring the classic "select, translate,
replace" workflow under its own name. `--nocode` skips fenced and inline
code spans (relevant to replace-style output only).

- **Tab:** true
- **Module:** `translate/init.lua`, `translate/output/init.lua`
- **Usercmds:** `:Translate <lang> [--nocode|--output=<m>|--files=<m>] [scope]`, `:TranslateReplace <lang> [--nocode] [selection|buffer|cwd|path=<p>]` — [user commands](../BINDINGS.md#user-commands)
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

## Custom translate provider

`translate.custom = { cmd = function(lines, target) return {"trans", "-b", ...} end, parse = function(out) return vim.split(out, "\n") end }` —
an escape hatch mirroring `spell.providers.custom`.

- **Module:** `translate/providers/custom.lua`
- **Config:** `opts.translate.custom`

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
- **Config:** `opts.translate.keymaps.operator` (default `false`), `opts.translate.keymaps.visual` (default `false`), `opts.translate.default_target`

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
the target, multi-selects via the `lib.nvim.ui.kit` chooser (`<Tab>`), and
translates each — writing a language-suffixed sibling file by default
(`name.DE.ext`), overwriting in place with `--files=replace` (confirmed),
or opening scratch buffers with `--files=buffers`.
`:TranslateReplace <lang> cwd` forces file-mode `replace`.

- **Module:** `translate/files.lua`
- **Config:** `opts.translate.files.output`
