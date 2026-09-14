# Requirements

## Required

| | |
| --- | --- |
| Neovim | **0.9+** (0.10+ recommended, for `vim.system`) |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | the command composer, the bindings layer and the shared helpers |
| `curl` | required for translation and thesaurus — carries the HTTP requests |

## Optional

Each detected at runtime and degrading to nothing when absent:

| | |
| --- | --- |
| `node` | Keeps the persistent cspell sidecar alive, so buffer and live checks skip process startup |
| `cspell`, `codespell`, `typos` | External spell providers, code-aware where the native check is not |
| A grammar LSP | Grammar findings in the same session list as the spelling ones |
| `trans` (translate-shell) | An engine in the fallback chain, alongside Google and DeepL |
| [trouble.nvim](https://github.com/folke/trouble.nvim) | A nicer list for the session's diagnostics |
| [hover.nvim](https://github.com/StefanBartl/hover.nvim) | The word under the cursor, translated in a float |
| [ui.nvim](https://github.com/StefanBartl/ui.nvim) | Backs `ui.kit` -- the spell issue panel/item menu and the translate history/window/output pickers. Everything else (the checks themselves, `:checkhealth`) works without it; only opening one of those UIs needs it |

`curl` and `node` are declared in [install.json](install.json) and
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
