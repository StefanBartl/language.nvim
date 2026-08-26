# language.nvim — Bindings

All keymaps are opt-in (disable any of them by setting the config key to
`false`) and carry a `desc`, so they show up in which-key (if installed) and
`:map` without further work. Group labels ("Spell", "Grammar fix") are
registered with which-key automatically when `which_key.enable = true`
(default), on whatever prefix the keys you configured actually share.

Every entry below is a **named action**, declared through
[`lib.nvim.bindings.keymap`](https://github.com/StefanBartl/lib.nvim): the
config key is the action's name, an lhs may be a list of keys
(`panel = { "<leader>ss", "z=" }`), and a misspelled name is reported with
its nearest match instead of silently binding nothing. `to` becomes one
action per language, named `to_<LANG>`.

## Keymaps

| Mode | Default lhs        | Config key                | Action                                            |
|------|---------------------|---------------------------|----------------------------------------------------|
| n    | `<leader>ss`         | `spell.keymaps.panel`     | Toggle spell session (current buffer)              |
| n    | `]s`                 | `spell.keymaps.next`      | Jump to next spelling/grammar issue (session-local) |
| n    | `<leader>z=`         | `spell.keymaps.fix`       | Apply/pick a fix for the issue under cursor (session-local) |
| n    | `<leader>z1`         | `spell.keymaps.fix1`      | Apply the first suggestion directly (session-local) |
| n    | *(off by default)*   | `translate.keymaps.operator` | Operator: `{lhs}{motion}` translates the moved-over text |
| x    | *(off by default)*   | `translate.keymaps.visual`   | Translate the current visual selection            |
| n, x | *(off by default)*   | `translate.keymaps.to.<LANG>` | Translate into that language for one run, whatever `default_target` says |
| n    | *(off by default)*   | `thesaurus.keymap`        | Replace word under cursor with a synonym; `3{lhs}` takes the third directly |

### Picking a translation target (2026-08-24)

With `default_target` set the operator always used it and never asked;
without one it always asked. Neither is "translate this bit into Spanish,
just now".

`translate.keymaps.to` is one key per language — `to = { EN = "<leader>tE",
DE = "<leader>tD" }` — forcing that target for a single run in both normal
(operator) and visual mode. The force is one-shot: it is consumed by the next
run, so it never leaks into the following unforced one.

A count could not carry the language here. On an operator the count belongs
to the motion (`3{lhs}w` is three words), which is the whole point of having
an operator — so it is a key per language, which is what the audit suggested
too. Unset by default.

### Taking the Nth synonym (2026-08-24)

`3{thesaurus.keymap}` replaces the word with the third synonym without
opening the menu, the way `3z=` takes the third spelling suggestion. The list
already exists at that point; the menu was only ever the way to choose from
it.

`vim.v.count` is read raw, since 0 has to stay distinguishable from 1 — no
count opens the menu, `1` takes the first synonym outright. Out of range is
reported rather than clamped: substituting a different word than the one you
counted would be an edit you did not ask for, and `z=` errors too.

`next`, `fix`, and `fix1` are attached per-buffer while a spell session is
active (see `lua/language/spell/init.lua`); the rest are global, registered
once in `lua/language/bindings/keymaps/init.lua`.

## User commands

Each is its own [`lib.nvim.bindings.usercmd.composer`](https://github.com/StefanBartl/lib.nvim)
verb (a flat `path = {}` root route — no subcommand tree), defined in
`lua/language/bindings/usrcmds/init.lua`.

| Command             | Defined in                          | Purpose |
|----------------------|--------------------------------------|---------|
| `:Spellcheck`        | `lua/language/bindings/usrcmds/init.lua`  | Spell/grammar review — `[lang] [buffer\|visible\|cwd\|path=<p>\|clear\|refresh]` |
| `:Translate`         | `lua/language/bindings/usrcmds/init.lua`  | Translate (popup by default) — `<lang> [--nocode\|--output=<m>\|--files=<m>] [scope]`; `!` opens the interactive window |
| `:TranslateReplace`  | `lua/language/bindings/usrcmds/init.lua`  | Translate and replace in place — `<lang> [--nocode] [selection\|buffer\|cwd\|path=<p>]` |

All three support tab-completion for language codes, scopes, and flags. Set
`commands = false` in `setup()` to skip registering them entirely.

An unrecognized `--flag` on `:Translate`/`:TranslateReplace` now reports a
clear error (composer's declared-flags gate runs before the handler) instead
of being silently ignored, as it was pre-composer. Actual dispatch for valid
input is otherwise unchanged — the handlers still parse the raw argument
string themselves rather than composer's bound positional args, since the
grammar classifies tokens by shape in any order (scope word, `path=<p>`,
`--flag[=value]`, or the bare language code), not strict positional slots.

## Autocmds

All grouped under the `language_nvim` augroup (`lua/language/bindings/autocmds/init.lua`).

| Event(s)                    | Condition                            | Purpose |
|------------------------------|----------------------------------------|---------|
| `BufDelete`                  | always                                 | GC per-buffer spell-session state; detach live diagnostics |
| `BufWinEnter`, `FileType`    | `spell.live = true`                    | Initial live spell scan when a matching buffer becomes visible |
| `TextChanged`, `InsertLeave` | `spell.live = true`                    | Debounced live spell rescan on edits |
| `WinScrolled`                | `spell.live = true` and `spell.live_scope = "visible"` | Rescan as the viewport moves |
| `BufWritePre`                | `spell.guard.block_write_on_error = true` | Abort `:w` while spelling errors remain on a matching filetype (bypass with `:noautocmd w`) |
