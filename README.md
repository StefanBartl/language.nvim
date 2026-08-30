> **Active development.** This repository is in its development phase — breaking changes are to be expected at any time. Pin a commit or tag if you depend on it.

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

[![Neovim](https://img.shields.io/badge/Neovim-0.9+-57A143?logo=neovim&logoColor=white)](https://neovim.io)

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

> Status: **Beta** — the spell panel, grammar (LSP), multiple providers, and
> multiple translation engines all work.

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
```

See [Usage](docs/usage.md) for the full command reference.

## Health

```vim
:checkhealth language
```

Optional external tools (`curl`, `trans`, spell/grammar CLIs) are declared
in [`docs/install.json`](docs/install.json) — parsed by
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

## Documentation

- [Features](docs/FEATURES/README.md) — spellcheck, grammar, translate, thesaurus, highlights, scoping, and async behavior.
- [Configuration](docs/configuration.md) — all `setup()` options with defaults and comments.
- [Usage](docs/usage.md) — full command reference and default keymaps.
- [Bindings](docs/BINDINGS.md) — every keymap, user command, and autocmd.

## License

MIT — see [LICENSE](LICENSE).
