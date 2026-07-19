# language.nvim

Language tools for Neovim in **one** plugin: check **spelling & grammar** and
act on it directly, plus **translate text** — with a unified scope model
(buffer / visible range / cwd / path / selection) and fully asynchronous
throughout.

Built on [lib.nvim](https://github.com/StefanBartl/lib.nvim) as a
deliberately shared dependency. Translation needs **no** external Neovim
plugin — just `curl` (Google engine, keyless, works with zero configuration).

> Status: **Beta** — the spell panel, grammar (LSP), multiple providers, and
> multiple translation engines all work. More ideas: see the
> [ROADMAP](docs/ROADMAP/ROADMAP.md).

---

## Requirements

- Neovim ≥ 0.9 (0.10+ recommended for `vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim)
- `curl` (for translation)
- optional: `folke/trouble.nvim` (nicer list), external spell CLIs/LSP (see
  [Features](docs/features.md))

## Installation (lazy.nvim)

```lua
{
  "StefanBartl/language.nvim",
  dependencies = { "StefanBartl/lib.nvim", "folke/trouble.nvim" }, -- trouble optional
  event = "VeryLazy",
  config = function()
    require("language").setup({})
  end,
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

## Documentation

- [Features](docs/features.md) — spellcheck, grammar, translate, thesaurus, highlights, scoping, and async behavior.
- [Configuration](docs/configuration.md) — all `setup()` options with defaults and comments.
- [Usage](docs/usage.md) — full command reference and default keymaps.
- [Roadmap](docs/ROADMAP/ROADMAP.md) — build phases done and future ideas.
- [Bindings](docs/BINDINGS.md) — every keymap, user command, and autocmd.
