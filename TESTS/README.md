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
| `spell_providers_cspell_server_spec.lua` | the persistent Node/cspell-lib sidecar (`cspell_server.lua`): `available()`, `resolve()`'s nested/hoisted candidate paths and its failure case, `ensure_started()`'s reentrancy and `jobstart` failure, `on_stdout`'s line buffering (including a line split across two chunks), the ready/error/id-reply dispatch, request/reply round-tripping with issue tagging, `cancel()`, `on_exit()` dropping pending requests, and the `VimLeavePre` kill handler — with `language.util.job` and `vim.fn.jobstart`/`chansend`/`jobstop` stubbed, never a real node or cspell-lib |
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
| `health_spec.lua` | `:checkhealth language` (`M.check()`) branch by branch: version/native-provider detection, every optional-tool present/absent pair (including the cspell-without-node middle case), the attached-grammar-client list, deepl-key resolution, the effective-config echo, and `check_hover()`'s four states — with every collaborator (tools, LSP clients, hover.nvim, which-key, `lib.nvim.deps.health`) stubbed or monkeypatched; also pins a real crash (see "Known bugs" below) |

Adding one: write `TESTS/<name>_spec.lua` returning `function(H) ... end`, then
list it in `run.lua`. `H` is the harness — `eq`, `ok`, `falsy`, `contains`,
`excludes`, `read` and `fixture`.

## Coverage

Every `lua/language/**/*.lua` file with real logic or branching that can be
required without `ui.kit` now has a dedicated real-assertion spec: both spell
cores (split/scope/regions/collect/cache/ignore/actions), the native,
CLI/LSP, and persistent-sidecar spell providers, live scanning, the
wordlists, `util/job`, every translate provider plus the registry's fallback
chain, translate's filter/indent/output/history/files/motion pieces, the
thesaurus, all three bindings modules, `language/init.lua`'s `setup()`, and
`health.lua`'s `M.check()` branch by branch (not just the lazy facade that
resolves it). `ignore.add_persistent`, previously excluded for writing into
the developer's real `stdpath("state")` ignore file, is covered too —
redirected to a fixture path via the existing `spell.dictionary.ignore_file`
config option, which needed no source change. `cspell_server.lua`, previously
excluded outright as needing a real Node/cspell install, is covered the same
way the other CLI providers are: every real external call it makes goes
through `language.util.job` or a plain `vim.fn.*` global, both stubbable, so
its own logic (candidate resolution, line buffering, request/reply matching)
is exercised without ever spawning node or cspell-lib for real.

### Known bugs pinned by these specs (not fixed here)

Some specs assert the *current*, buggy behavior on purpose rather than
silently patching it — grep any spec file for `BUG:` for the full reasoning
inline. As of this audit:

- **`job_spec.lua`** — a nonexistent executable makes `vim.system` raise
  synchronously instead of reaching `on_done(false, ...)`.
- **`spell_init_spec.lua`** — `spell.clear()` does not actually restore a
  buffer's previous `'spelllang'` when the quickfix view (not the panel) is
  in use; it restores the wrong window's option.
- **`health_spec.lua`** — `check_lib()` correctly detects and warns about a
  `lib.nvim` checkout missing `bindings.usercmd.composer`, but `M.check()`'s
  own tail calls straight into that same module a few lines later with no
  guard at all — so instead of degrading past the warning already given, an
  old `lib.nvim` crashes `:checkhealth language` outright, and everything
  after the "lib.nvim (required dependency)" section (translate/config/
  which-key/hover/deps) never renders.

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
- **`config/DEFAULTS.lua`** — a plain data table (`return { ... }`); its merge
  behavior is what `config_spec.lua` actually tests.
- **`@types` modules** (`language/@types`, `config/@types`,
  `spell/@types`, `translate/@types`) — `---@meta`-style annotation files, no
  runtime behavior.

Translation itself (`curl`/network), the shell-based spell providers, and the
persistent cspell sidecar's actual process stay stubbed at the `util/job` /
`vim.fn.*` boundary throughout — none of this suite spawns a real process,
a real Node runtime, or touches the network.
