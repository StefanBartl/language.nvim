# Contributing to language.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/StefanBartl/language.nvim/issues); pull
requests very welcome.

## Getting the repository into a session

Clone it and either symlink the checkout into your plugin directory or add it
to the runtime path directly:

```lua
vim.opt.rtp:prepend("/path/to/language.nvim")
require("language").setup({})
```

[lib.nvim](https://github.com/StefanBartl/lib.nvim) has to be on the runtime
path too — several modules require it at load time. `curl` has to be on `PATH`
for anything to translate.

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation, `stylua.toml` decides
  the rest.
- **One scope vocabulary.** `buffer`, `visible`, `cwd`, `path=<p>`,
  `selection` and `cword` are parsed in `lua/language/scope/` and mean the same
  thing to every command. A new feature that needs a target reuses that parser
  instead of inventing a synonym for a scope that already exists.
- **Nothing blocks.** Every provider call goes through `lua/language/util/job/`
  and is cancellable; starting a new scan ends the running one. A synchronous
  request over a directory tree is not an acceptable shortcut, and neither is
  one behind a hover — see [`FEATURES/HOVER.md`](FEATURES/HOVER.md) for what
  measurement found there.
- **Optional stays optional.** Every external tool is detected at runtime and
  its absence costs one feature, never the plugin. Declare tools that OS
  package managers actually carry in [`install.json`](install.json), and report
  on all of them in `health.lua`.
- **Mutation is asked for by name.** `:Translate` shows, `:TranslateReplace`
  edits. A flag that turns a showing command into an editing one is how the
  distinction gets lost — output modes that overwrite files confirm first.
- Commands are registered through `lib.nvim.bindings.usercmd.composer`, keymaps
  through `lib.nvim.bindings.keymap` as named actions. Every keymap is opt-in
  and carries a `desc`.
- Descriptive commit messages.

## Project layout

| Path | Contains |
| --- | --- |
| `lua/language/spell/` | The review session: `core/` (collect, split, regions, ignore, cache, actions), `providers/` (native, cspell, cspell_server, codespell, typos, lsp, custom), `ui/` (panel, list, item menu, highlights), `live.lua` |
| `lua/language/translate/` | `providers/` (google, deepl, shell, custom, registry), `output/`, the interactive `window.lua`, file mode, indent round trip, history |
| `lua/language/thesaurus/` | The synonym lookup and the cursor-word swap |
| `lua/language/scope/` | The one scope parser every command shares |
| `lua/language/bindings/` | `usrcmds/`, `keymaps/`, `autocmds/` |
| `lua/language/config/` | `DEFAULTS.lua`, `setup()` validation, and the option types |
| `lua/language/util/job/` | The cancellable async job layer |
| `lua/language/@types/` | Shared type aliases |
| `node/cspell_server.js` | The persistent cspell sidecar |
| `doc/language.txt` | The `:help` reference |
| `docs/` | Everything the README links to |
| `TESTS/` | The spec suite |

## Adding a provider

Spell and translate both resolve providers through a registry, so a new one is
a file plus a registration rather than a change to the call sites.

1. Add the module under `lua/language/spell/providers/` or
   `lua/language/translate/providers/`, modelled on the closest existing one.
2. Go through `lua/language/util/job/` — no blocking call, and honour
   cancellation.
3. Return findings as data. Rendering is `spell/ui/` and `translate/output/`,
   and a provider that writes to a buffer itself cannot be tested or reused.
4. Detect availability at runtime and report it in `lua/language/health.lua`.
   If the tool exists in OS package managers, declare it in
   [`install.json`](install.json) as well.
5. Add the option to `lua/language/config/DEFAULTS.lua` and its type to
   `lua/language/config/@types/`.
6. Add a spec under `TESTS/`.
7. Document it in the matching page under [`FEATURES/`](FEATURES/README.md),
   in [`configuration.md`](configuration.md), and — if it adds a command or a
   flag — in [`usage.md`](usage.md) and [`BINDINGS.md`](BINDINGS.md).

## Tests

`TESTS/` is a headless spec suite. Every spec drives a module directly: no
picker, no window, no external CLI, no network.

```
nvim --headless -u NONE -c "set rtp+=." -l TESTS/run.lua
```

Exit 0 is a pass. `run.lua` resolves lib.nvim from `$LIB_NVIM_PATH`, then a
sibling `../lib.nvim` checkout, then the lazy.nvim-managed copy — the sibling
wins on purpose, because testing against a stale lib.nvim gives misleading
failures. See [`../TESTS/README.md`](../TESTS/README.md).

[GitHub Actions](../.github/workflows/ci.yml) runs stylua, luacheck and this
suite on every push and pull request to `main`.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the affected pages under `docs/`.
4. Open a PR with a clear description of what changed and why.
