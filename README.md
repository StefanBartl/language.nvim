> **Alpha stage — active development.** This repository is in its development phase — breaking changes are to be expected at any time. Pin a commit or tag if you depend on it.

# language.nvim

```
 _               _   _  _____ _    _         _____ ______
| |        /\   | \ | |/ ____| |  | |  /\   / ____|  ____|
| |       /  \  |  \| | |  __| |  | | /  \ | |  __| |__
| |      / /\ \ | . ` | | |_ | |  | |/ /\ \| | |_ |  __|
| |____ / ____ \| |\  | |__| | |__| / ____ \ |__| | |____
|______/_/    \_\_| \_|\_____|\____/_/    \_\_____|______|
                                                     .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-alpha-red)

> Pairs well with [sessions.nvim](https://github.com/StefanBartl/sessions.nvim):
> sessions.nvim restores your workspace by project + branch, so your
> spell/translate settings pick up right where you left off.

Language tools for Neovim in **one** plugin: check **spelling & grammar** and
act on it directly, **translate text**, and look up **synonyms** to replace
the word under the cursor — with a unified scope model (buffer / visible
range / cwd / path / selection) and fully asynchronous throughout.

Built on [lib.nvim](https://github.com/StefanBartl/lib.nvim) as a
deliberately shared dependency. Translation needs **no** external Neovim
plugin — just `curl` (Google engine, keyless, works with zero configuration).

> **What already works:** the spell panel, grammar (LSP), multiple providers,
> and multiple translation engines.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [Health](#health)
- [Documentation](#documentation)

---

## Requirements

- Neovim >= 0.9 (0.10+ recommended for `vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim)
- `curl` (for translation)
- optional: `folke/trouble.nvim` (nicer list), external spell CLIs/LSP (see
  [Features](docs/FEATURES/README.md))

## Installation

For packer.nvim, vim-plug and the full prerequisite list, see
[docs/installation.md](docs/installation.md).

lazy.nvim:

```lua
{
  "StefanBartl/language.nvim",
  dependencies = { "StefanBartl/lib.nvim", "folke/trouble.nvim" }, -- trouble optional
  event = "VeryLazy",
  opts = {},
}
```

## Quickstart

```vim
:Spellcheck                 " check the current buffer (toggle session on/off)
:'<,'>Translate DE           " popup with the translation, buffer untouched
:'<,'>TranslateReplace DE    " selection to German, REPLACES the text
:Translate DE cword          " just the word under the cursor
:Hover show                  " the same word, in a hover.nvim float (optional)
```

See [Usage](docs/usage.md) for the full command reference.

## Health

```vim
:checkhealth language
```

The optional external tools installable through your system's package
manager — `curl` and `node` — are declared in
[`docs/install.json`](docs/install.json), parsed by
[lib.nvim](https://github.com/StefanBartl/lib.nvim)'s
[`deps` module](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/deps/README.md).
A popup shows what's missing and why the first time `setup()` runs after
installing this plugin; `:Lib deps show language.nvim` repeats it any time,
`:Lib deps install language.nvim` composes and confirms an install command.
Disable it **right in this plugin's own spec**:
`require("language").setup({ deps_popup = false })`.
`vim.g.lib_nvim_deps_disable_first_run = true` (every plugin) /
`vim.g.lib_nvim_deps_disabled_plugins = { "language.nvim" }` also still
work, for turning it off without touching any plugin's config.

The provider CLIs — `trans`, `cspell`, `codespell`, `typos` — are **not** in
that spec yet; `:checkhealth language` is where they are reported. Two of
them (`cspell`, `typos`) live in npm and cargo rather than in any of the
nine OS package managers the spec composes commands for, so declaring the
set is not the one-line addition it looks like.

See [docs/health.md](docs/health.md) for what each of the nine sections
actually checks.

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which
question each page answers.

- [Features](docs/FEATURES/README.md) — spellcheck, grammar, translate, thesaurus, highlights, scoping, and async behavior.
- [Configuration](docs/configuration.md) — all `setup()` options with defaults and comments.
- [Health](docs/health.md) — the nine `:checkhealth language` sections, and which findings are actually problems.
- [Usage](docs/usage.md) — full command reference and default keymaps.
- [Bindings](docs/BINDINGS.md) — every keymap, user command, and autocmd.
- [Workflow](docs/WORKFLOW.md) — how the pieces combine into a habit rather than three commands you reach for once something is already wrong.
- [Hover](docs/FEATURES/HOVER.md) — the word under the cursor, translated into a
  [hover.nvim](https://github.com/StefanBartl/hover.nvim) float: why it is asked
  only on request, and what a measurement found behind the keyless endpoint.

## License

MIT — see [LICENSE](LICENSE).
