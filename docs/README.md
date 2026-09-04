# language.nvim documentation

What is here, and which question each page answers. [The README](../README.md)
is the short version of all of it.

## Getting it running

| Page | Answers |
| --- | --- |
| [installation.md](installation.md) | What has to be there before this works — the Neovim version, `lib.nvim` as a hard dependency, and which external tools are optional — then a spec per plugin manager and how to check that it took |
| [configuration.md](configuration.md) | Every option `setup()` takes, over the defaults in `lua/language/config/DEFAULTS.lua` |

## Using it

| Page | Answers |
| --- | --- |
| [usage.md](usage.md) | The commands on one screen: what to type for a spell session, a scope, a translation, and how to end each again |
| [BINDINGS.md](BINDINGS.md) | Every keymap, user command and autocmd — all keys opt-in, all carrying a `desc`, so which-key and `:map` describe them without further work |
| [WORKFLOW.md](WORKFLOW.md) | The different question: not what each feature does but how they combine into a habit. Why a spell session starts before the typing rather than after it, which of the three issue sources is answering, and the two traps — `:Translate` against `:TranslateReplace`, and reading the confirmation before `--files=replace` |

## Why it is the way it is

| Page | Answers |
| --- | --- |
| [FEATURES/](FEATURES/README.md) | One page per theme — spell, translate, thesaurus, the shared core, and the hover integration — each about what the feature is for rather than only that it exists |

## Here, but not prose

**`install.json`** declares the external tools this plugin can use, machine-readably,
for `:Lib deps show language.nvim`. What each tool is *for* is in
[installation.md](installation.md).

## Not here at all

**Planning material.** What is considered and not built yet — the media-to-text
concept, for one — answers a question the author has rather than one a reader of
this plugin has. It lives outside the repository.
