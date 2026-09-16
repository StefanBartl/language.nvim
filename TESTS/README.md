# TESTS/

Headless spec suite. Every spec drives a module directly — no picker, no
window, no external spell CLI, no network.

```
nvim --headless -u NONE -c "set rtp+=." -l TESTS/run.lua
```

Exit 0 is a pass; the runner prints one line per spec and exits non-zero on the
first failure. CI runs exactly this command.

## lib.nvim

Several modules require lib.nvim at module load, so the suite cannot run
without it. `run.lua` resolves it in this order:

1. `$LIB_NVIM_PATH`
2. a sibling checkout, `../lib.nvim`
3. the lazy.nvim-managed copy under `stdpath("data")/lazy/lib.nvim`

A sibling wins over the plugin-manager copy on purpose: that one is often older
than the working checkout, and testing against a stale lib.nvim gives
misleading failures.

## The specs

| | |
| --- | --- |
| `split_spec.lua` | breaking an identifier into words a dictionary can be asked about — camelCase, acronyms, separators, and the offsets that turn a hit back into a highlight |
| `scope_spec.lua` | turning the words after a command into the region it acts on, and handing the caller's own arguments back |
| `ignore_spec.lua` | the session ignore set and the filter that applies it, plus the persistent list (redirected to a fixture file via `spell.dictionary.ignore_file`, never the developer's real one) |
| `actions_spec.lua` | `replace_all_in_buffer`'s whole-word boundary (not a substring match) and its empty-input/no-match paths, `add_to_dict`'s validation and its real `:spellgood` effect on `vim.spell.check` |
| `cache_spec.lua` | the per-buffer changedtick-keyed scan cache: hit, `changedtick`-invalidation on edit, explicit `invalidate`, and a deleted buffer never being a hit |
| `regions_spec.lua` | turning a scope into concrete byte/line ranges to scan |
| `native_spec.lua` | the native `:spellgood`/`z=`-backed provider |
| `collect_spec.lua` | gathering issues across providers/scopes and de-duplicating them |
| `spell_ui_spec.lua` | `ui/highlights.lua` and `ui/list.lua` (the two spell UI modules that do not require `ui.kit`) — diagnostic namespace, the per-buffer `max` cap |
| `live_spec.lua` | debounced live re-scanning on buffer change |
| `wordlists_spec.lua` | the built-in programming dictionary and extra-wordlist merging |
| `job_spec.lua` | `util/job`: argv/opts plumbing, `on_done`, and that `cancel()` before completion suppresses it |
| `spell_providers_cli_spec.lua` | the CLI/LSP spell providers (`codespell`, `cspell`, `custom`, `lsp`, `typos`) and their shared `util.lua`, all with the underlying process/LSP client stubbed |
| `translate_filter_indent_spec.lua` | the line filter that skips fenced code/front-matter, and re-indenting translated output to match the source |
| `translate_output_spec.lua` | applying translated output back to a buffer, register, or via notify |
| `translate_history_spec.lua` | recording/labelling/picking/clearing translation history, including label clipping for long input |
| `translate_providers_spec.lua` | the translate engines — registry resolution/fallback, and each provider's (`google`, `deepl`, `shell`, `custom`) request-building and response-parsing, with `util/job` stubbed so nothing hits curl or a real network |
| `translate_init_spec.lua` | `translate.run`'s scope handling and buffer replace |
| `translate_motion_spec.lua` | the operator/motion entry point into translate |
| `translate_files_spec.lua` | `translate.files.process`/`run` against a fake provider — suffix/replace/buffers output modes, error handling, and the early-return guards, all without reaching `ui.kit`'s file picker |
| `thesaurus_spec.lua` | looking up and applying a synonym under the cursor, off the `ui.kit` picker branch |
| `bindings_usrcmds_spec.lua` | `:Spellcheck`/`:Translate`/`:TranslateReplace` argument parsing and dispatch, with `language.spell`/`language.translate`/`language.translate.window` stubbed |
| `bindings_keymaps_autocmds_spec.lua` | keymap registration for spell/translate/thesaurus, and the autocmd wiring (including the live-scan debounce arm/disarm and the write guard) |
| `language_init_spec.lua` | `language.setup()` end to end — command registration gating, idempotency, the lazy `M.health` facade, and the programming_dict/extra_wordlists gate |
| `spell_init_spec.lua` | the top-level `language.spell` facade — starting/closing a session, `:Spellcheck`'s scope dispatch, panel stubbed (see "Deliberately left untested") |
| `config_spec.lua` | the merge, and that `DEFAULTS` survives it unmutated |
| `hover_spec.lua` | the word under the cursor as a hover.nvim float — the word finder, the target language, decline-vs-fail, the rate-limit failure path, and `on_request` registration (translate provider and hover.nvim both stubbed) |

Adding one: write `TESTS/<name>_spec.lua` returning `function(H) ... end`, then
list it in `run.lua`. `H` is the harness — `eq`, `ok`, `falsy`, `contains`,
`excludes`, `read` and `fixture`.

## Coverage

Every `lua/language/**/*.lua` file with real logic or branching that can be
required without `ui.kit` now has a dedicated real-assertion spec: both spell
cores (split/scope/regions/collect/cache/ignore/actions), the native and
CLI/LSP spell providers, live scanning, the wordlists, `util/job`, every
translate provider plus the registry's fallback chain, translate's
filter/indent/output/history/files/motion pieces, the thesaurus, all three
bindings modules, and `language/init.lua`'s `setup()` (which also exercises
`health.lua`'s lazy facade). `ignore.add_persistent`, previously excluded for
writing into the developer's real `stdpath("state")` ignore file, is now
covered too — redirected to a fixture path via the existing
`spell.dictionary.ignore_file` config option, which needed no source change.

### Deliberately left untested

- **`spell/ui/panel.lua`, `spell/ui/item_menu.lua`** — both `require("ui.kit")`
  at module load. This repo's CI (`.github/workflows/ci.yml`) checks out only
  `lib.nvim` as a sibling, not `ui.nvim`/`ui.kit` — so a spec that so much as
  `require`s either module would pass locally (where a `ui.nvim` checkout
  happens to be on disk) and fail in CI. `spell_init_spec.lua` stubs
  `language.spell.ui.panel` in `package.loaded` purely so `M.clear()`'s call
  into it does not error; the panel's own rendering logic is not exercised.
- **`translate/window.lua`** — the interactive `:Translate` (bang) window.
  `require("ui.kit")` is lazy (inside its functions, not at module top), so it
  does not fail CI's module-load, but exercising its actual picker/prompt flow
  needs `ui.kit` regardless. `bindings_usrcmds_spec.lua` only stubs it as a
  collaborator to assert that the bang form reaches it instead of
  `translate.run`.
- **`spell/providers/cspell_server.lua`** — spawns and talks
  newline-delimited JSON to a persistent Node process running `cspell-lib`
  (`node/cspell_server.js`), resolved via `npm root -g`. Like the other CLI
  spell providers (`codespell.lua`, `cspell.lua`, `custom.lua`, `lsp.lua`,
  `typos.lua`, all covered in `spell_providers_cli_spec.lua` with the
  underlying process/LSP client stubbed) this shells out, but unlike them it
  also needs a real Node install and a global `cspell` package present —
  state a push-triggered suite must not depend on.
- **`config/DEFAULTS.lua`** — a plain data table (`return { ... }`); its merge
  behavior is what `config_spec.lua` actually tests.
- **`health.lua`** — exercised indirectly through `language.setup()`'s lazy
  `M.health` facade in `language_init_spec.lua`; not tested branch-by-branch,
  since each branch is a declarative `vim.health.*` call with no computed
  value to assert on.
- **`@types` modules** (`language/@types`, `config/@types`,
  `spell/@types`, `translate/@types`) — `---@meta`-style annotation files, no
  runtime behavior.

Translation itself (`curl`/network) and the shell-based spell providers stay
stubbed at the `util/job` boundary throughout — none of this suite spawns a
real process or touches the network.
