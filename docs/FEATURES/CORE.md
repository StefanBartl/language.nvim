# Core

Cross-cutting behavior shared by spell and translate.

## Unified scope model

Every action understands the same scope vocabulary: `buffer` (default),
`visible` (viewport range), `cwd`, `path=<file|folder>`, `selection`. The
scope parser is shared, so `:Spellcheck`, `:Translate`, and
`:TranslateReplace` all accept scope arguments the same way.

- **Module:** `scope/init.lua`
- **Config:** `opts.spell.default_scope` (default `"buffer"`)

## Async, cancellable job layer

External processes (`curl`, CLI checkers, `trans`, etc.) run non-blocking
through an argv-based job runner — no shell interpolation of user text —
with a configurable timeout. Starting a new invocation for the same target
cancels the one still in flight, rather than letting results race.

- **Module:** `util/job/init.lua`
- **Config:** `opts.translate.timeout_ms` (default `8000`)

## `lib.nvim.deps` install popup

Declares its optional external tools (`curl`, `trans`, spell/grammar CLIs)
in `docs/install.json`, parsed by `lib.nvim`'s `deps` module. A popup
explains what's missing the first time `setup()` runs after install;
`:Lib deps show language.nvim` repeats it, `:Lib deps install language.nvim`
composes and confirms an install command.

- **Config:** `opts.deps_popup` (default `true`), `vim.g.lib_nvim_deps_disable_first_run`, `vim.g.lib_nvim_deps_disabled_plugins`

## Bindings via `lib.nvim.usercmd.composer`

Every user command is a `lib.nvim.usercmd.composer` verb (a flat root
route, no subcommand tree) with tab-completion for language codes, scopes,
and flags, defined in `bindings/usrcmds/init.lua`. Keymaps carry a `desc`
and register with which-key automatically when `which_key.enable = true`
(default). Set `commands = false` in `setup()` to skip registering them.

- **Module:** `bindings/{keymaps,autocmds,usrcmds,which_key}/init.lua`
- **Config:** `opts.commands` (default `true`), `opts.which_key.enable` (default `true`)
