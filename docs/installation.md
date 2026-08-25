# Installation

## Prerequisites

- Neovim 0.9+ (0.10+ recommended, for `vim.system`)
- [`lib.nvim`](https://github.com/StefanBartl/lib.nvim) — **required**;
  `:Spellcheck`, `:Translate` and `:TranslateReplace` are registered through
  `lib.nvim.usercmd.composer`, and the notify/cross-platform helpers come from
  there too.
- `curl` — required for translation only; everything else works without it.
- Optional: [trouble.nvim](https://github.com/folke/trouble.nvim) for a nicer
  result list, and external spell CLIs or an LSP — see
  [Features](FEATURES/README.md).

Run `:checkhealth language` after installing: it reports each dependency
separately, with what it is used for, so a missing optional one is not
mistaken for a broken install.

## lazy.nvim

```lua
{
  "StefanBartl/language.nvim",
  dependencies = { "StefanBartl/lib.nvim" },
  event = "VeryLazy",
  opts = {},
}
```

A command trigger (`cmd = { "Spellcheck", "Translate", "TranslateReplace" }`)
works too, and is the leaner choice if you only ever use the commands. Prefer
`event = "VeryLazy"` if you turn on the opt-in live spell scan (`spell.live`):
that one attaches its debounced scanner in `setup()`, so it can only report on
buffers opened after the plugin loaded.

## packer.nvim

```lua
use {
  "StefanBartl/language.nvim",
  requires = { "StefanBartl/lib.nvim" }, -- required
  config = function()
    require("language").setup()
  end,
}
```

## vim-plug

```vim
Plug 'StefanBartl/lib.nvim' " required
Plug 'StefanBartl/language.nvim'

lua require("language").setup()
```

## Verifying the installation

```vim
:checkhealth language
:Spellcheck
:Translate
```
