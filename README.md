> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

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
![Status](https://img.shields.io/badge/status-beta-orange)
[![CI](https://github.com/StefanBartl/language.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/language.nvim/actions/workflows/ci.yml)

Spelling, grammar, translation and synonyms in one plugin, all of it
asynchronous and all of it acting on the buffer you are already in.

Translation needs no external Neovim plugin — `curl` and the keyless Google
endpoint work with zero configuration. Everything else, from external spell
CLIs to a DeepL key, is optional and detected at runtime.

---

## Table of contents

- [Documentation](#documentation)
- [What it does](#what-it-does)
- [Around it](#around-it)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [What you get with the defaults](#what-you-get-with-the-defaults)
- [Health check](#health-check)
- [Contributing](#contributing)
- [Feedback](#feedback)
- [License](#license)

---

## Documentation

Start at [docs/README.md](docs/README.md), which says what is where and which
question each page answers.

- [Features](docs/FEATURES/README.md) — one page per theme: spell, translate, thesaurus, the shared core, and the hover contribution.
- [Installation](docs/installation.md) — requirements, every plugin manager, and how to check that it took.
- [Configuration](docs/configuration.md) — every `setup()` option over the defaults in `lua/language/config/DEFAULTS.lua`.
- [Usage](docs/usage.md) — the command reference: scopes, flags, and how to end each thing again.
- [Bindings](docs/BINDINGS.md) — every keymap, user command and autocmd, all of them opt-in and carrying a `desc`.
- [Workflow](docs/WORKFLOW.md) — how the pieces combine into a habit, and the two traps: `:Translate` against `:TranslateReplace`, and reading the confirmation before `--files=replace`.
- [Health](docs/health.md) — the nine `:checkhealth language` sections, and which findings are actually problems.
- [Contributing](docs/CONTRIBUTING.md) — ground rules, project layout, and how to add a provider.

`:help language` is the same reference inside the editor.

---

## What it does

Language work in an editor usually means leaving it: a browser tab for the
translation, a separate linter run for the spelling, a thesaurus site for the
word that is almost right. Each of those is a context switch out of the text
you were writing.

This plugin keeps all three in the buffer, over one shared scope vocabulary —
`buffer`, `visible`, `cwd`, `path=<p>`, `selection`, `cword` — so the same
word means the same thing to every command.

| Area | Does |
| --- | --- |
| **Spell** | A per-buffer review session with diagnostics you jump between and fix in place, native or through external providers (`cspell`, `codespell`, `typos`), code-aware, with a persistent cspell sidecar when `node` is there |
| **Grammar** | The same session fed from an LSP, so grammar findings land in the same list as spelling ones |
| **Translate** | `:Translate` into a popup that leaves the buffer alone, `:TranslateReplace` when you mean to mutate — eight output destinations, an engine fallback chain, and an interactive window with live translation while typing |
| **Thesaurus** | The word under the cursor swapped for a synonym, keyless via Datamuse; `3{lhs}` takes the third directly, the way `3z=` takes the third spelling suggestion |

Everything runs asynchronously and cancellably: a scan over a directory tree
does not block the editor, and starting a new one ends the old.

---

## Around it

> **[hover.nvim](https://github.com/StefanBartl/hover.nvim)** — the word under
> the cursor, translated into a float. It is asked only on request rather than
> on every hover, because the keyless endpoint answers a passive contribution
> with HTTP 429 — the measurement is in
> [docs/FEATURES/HOVER.md](docs/FEATURES/HOVER.md).
>
> **[sessions.nvim](https://github.com/StefanBartl/sessions.nvim)** — restores
> your workspace by project and branch, so a spell session and its target
> language come back where you left them instead of being set up again.
>
> **[trouble.nvim](https://github.com/folke/trouble.nvim)** — a nicer list for
> the diagnostics a spell session produces. The session works without it; the
> quickfix list is the fallback.
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/StefanBartl/lib.nvim) is the one real
> dependency — see [Requirements](#requirements).

---

## Requirements

| | |
| --- | --- |
| Neovim | **0.9+** (0.10+ recommended, for `vim.system`) |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | required — the command composer, the bindings layer and the shared helpers |
| `curl` | required for translation and thesaurus — carries the HTTP requests |

Optional, each detected at runtime and degrading to nothing when absent:

| | |
| --- | --- |
| `node` | Keeps the persistent cspell sidecar alive, so buffer and live checks skip process startup |
| `cspell`, `codespell`, `typos` | External spell providers, code-aware where the native check is not |
| A grammar LSP | Grammar findings in the same session list as the spelling ones |
| `trans` (translate-shell) | An engine in the fallback chain, alongside Google and DeepL |
| [trouble.nvim](https://github.com/folke/trouble.nvim) | A nicer list for the session's diagnostics |
| [hover.nvim](https://github.com/StefanBartl/hover.nvim) | The word under the cursor, translated in a float |

`curl` and `node` are declared in [docs/install.json](docs/install.json) and
read by lib.nvim's
[deps module](https://github.com/StefanBartl/lib.nvim/blob/main/lua/lib/nvim/deps/README.md).
A popup says what is missing the first time `setup()` runs after installing;
`:Lib deps show language.nvim` repeats it any time, and
`:Lib deps install language.nvim` composes and confirms an install command.
Turn the popup off in this plugin's own spec with
`require("language").setup({ deps_popup = false })`, or globally with
`vim.g.lib_nvim_deps_disable_first_run = true`.

The provider CLIs — `trans`, `cspell`, `codespell`, `typos` — are deliberately
**not** in that declaration; `:checkhealth language` is where they are
reported. Two of them live in npm and cargo rather than in any of the nine OS
package managers the spec composes commands for, so declaring the set is not
the one-line addition it looks like.

---

## Installation

```lua
-- lazy.nvim
{
  "StefanBartl/language.nvim",
  dependencies = { "StefanBartl/lib.nvim" },
  cmd = { "Spellcheck", "Translate", "TranslateReplace" },
  keys = { { "<leader>ss", desc = "Toggle spell session" } },
  opts = {},
}
```

`cmd` plus `keys`: the command trigger covers the translation you ask for, and
the key trigger covers the spell session you reach for without thinking about
which plugin provides it. Use `event = "VeryLazy"` instead if you want the
optional keymaps registered up front. Other plugin managers and the full
prerequisite list are in [docs/installation.md](docs/installation.md).

---

## Quickstart

Open a file with prose in it and start a spell session — it stays on until you
end it, and every finding becomes a diagnostic you can jump to:

```vim
:Spellcheck
```

Inside the session, `]s` jumps to the next issue, `<leader>z=` picks a fix and
advances, `<leader>z1` takes the first suggestion outright. Then:

```vim
:Spellcheck de path=~/notes   " a file or folder instead of this buffer
:Spellcheck clear             " end the session, remove the diagnostics

:'<,'>Translate DE            " popup with the translation, buffer untouched
:'<,'>TranslateReplace DE     " same selection, but REPLACES the text
:Translate DE cword           " just the word under the cursor
:Translate!                   " interactive window, live translation while typing
```

Verify your setup any time with:

```vim
:checkhealth language
```

---

## What you get with the defaults

| Command / key | Does |
| --- | --- |
| `:Spellcheck [lang] [scope]` | Start or toggle the review session over buffer, `visible`, `cwd` or `path=<p>` |
| `:Spellcheck clear` / `refresh` | End the session and drop the diagnostics, or rescan |
| `:Translate <lang> [scope]` | Translate into a popup; the buffer is not touched |
| `:Translate <lang> --output=<m>` | `popup`, `replace`, `buffer`, `vsplit`, `split`, `tab`, `insert`, `clipboard` or `notify` |
| `:Translate!` | Interactive window, translating live as you type; a range pre-fills it |
| `:TranslateReplace <lang> [scope]` | The mutating counterpart — always replaces, no `--output=` |
| `--nocode` | Skips fenced and inline code spans in replace-style output |
| `<leader>ss` | Toggle the spell session in the current buffer |
| `]s` · `<leader>z=` · `<leader>z1` | Next issue · fix and advance · take the first suggestion |

Every other key — the translate operator, the visual-mode map, one key per
target language, the thesaurus swap — is off by default and named in
[docs/BINDINGS.md](docs/BINDINGS.md). The full command surface, with all flags
and scopes, is [docs/usage.md](docs/usage.md).

---

## Health check

```vim
:checkhealth language
```

Nine sections: the Neovim version, `lib.nvim`, which spell providers and
grammar LSPs are reachable, which translate engines resolved, the configuration
as it was merged, which-key, the declared tools, and the hover integration.
[docs/health.md](docs/health.md) says which findings are actually problems —
most of the optional ones are informational and routinely misread as failures.

---

## Contributing

Clone the repository and either symlink it or add it to your runtime path.
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) has the ground rules and the
project layout, including where a new spell or translate provider plugs in.

Pull requests very welcome.

---

## Feedback

Your feedback is very welcome. Use the
[issue tracker](https://github.com/StefanBartl/language.nvim/issues) to report
bugs, suggest features or ask usage questions; anything more open-ended fits a
[discussion](https://github.com/StefanBartl/language.nvim/discussions).

If you find this plugin useful, a ⭐ on GitHub supports its development.

---

## License

MIT — see [LICENSE](LICENSE).
