# language.nvim — Roadmap

Status of the phased build. ✅ done · 🔜 planned.

## Done

- ✅ **Phase 1 — Scaffold**: plugin entry, `setup()`, config tree (`spell` +
  `translate`), central `@types` (incl. `LanguageScope`), `health.lua`.
- ✅ **Phase 2 — Spell core (native)**: `vim.spell` provider, per-buffer
  session (z= fix-and-advance, spelllang restore), diagnostics namespace,
  Trouble/quickfix fallback. Shared scope parser.
- ✅ **Phase 3 — Translate core (native Google)**: keyless gtx endpoint, async
  via the argv job runner, fenced/inline-code filter, `--nocode`.
  (Originally `:Translate` defaulted to `replace`; superseded below — see
  "Translate/TranslateReplace role split".)
- ✅ **Phase 4 — Review panel + async foundation**: `lib.nvim.ui.kit` picker +
  per-issue action menu (`spell/ui/{panel,item_menu}`), `spell/core/{collect,
  actions,ignore}`, cancellable/timed job runner.
- ✅ **Phase 5 — Perf/code features**: CamelCase/snake_case splitting
  (`spell/core/split`), Treesitter `@spell` region filter (`spell/core/
  regions`), URL/email skip, readonly skip, `max_highlights`/`max_file_lines`
  caps, opt-in programming dictionary.
- ✅ **Phase 6 — More providers**: translate `deepl`/`shell`/`custom` + fallback
  chain; spell `typos` (async cwd/path) and LSP grammar harvest
  (harper_ls/ltex); `collect.gather` async-capable collection.
- ✅ **cspell & codespell adapters**: async CLI spell providers for cwd/path,
  dispatched generically via `collect.gather` (`spell/providers/{cspell,
  codespell,util}`).
- ✅ **Grammar fixes in the panel**: grammar/style issues (harper/ltex) offer
  an "Apply LSP fix…" action that runs the language server's code actions at the
  issue location; suggestion-based actions are reserved for spelling issues.
- ✅ **Live scan** (`spell/live`): opt-in (`spell.live`), debounced, decoupled
  from the panel/session; scans configured filetypes and, by default, only the
  visible range (`live_scope = "visible"`, follows the viewport on scroll),
  honouring the filetype/`max_file_lines`/readonly/`max_highlights` gates.
- ✅ **Translate motion/visual maps** (`translate/motion`): a `g@` operator
  translates the moved-over text object and an x-mode map translates the visual
  selection; target is `translate.default_target` or a quick picker. Opt-in via
  `translate.keymaps.{operator,visual}`.
- ✅ **Interactive translate window** (`translate/window`): `:Translate!` opens a
  two-pane float (editable input + live output) that translates as you type;
  `<C-l>` retarget, `<C-y>` copy, q/`<Esc>`/`<C-c>` close. Prefilled from a range.
- ✅ **Phase 7 — Config integration**: replaced the in-config
  `config/trouble/spell` and `config/translate` modules with the standalone
  plugin.
- ✅ **Phase 8 — Docs**: `doc/language.txt`, this roadmap, README.
- ✅ **Reverse / round-trip** (window `<C-r>`): promotes the translation to the
  input and picks a new target, so a result can be translated back or onward.
- ✅ **Query history** (`translate/history`): records `:Translate` results and
  window copies (newest-first ring, optional JSON persistence); recall via the
  window `<C-h>` picker or `require("language").translate_history()`.
- ✅ **Column-precise selection** (`translate.run_region`): char-wise motions
  (`<lhs>iw`) and char-wise visual selections translate the exact byte span
  (multibyte-safe via getregionpos) and replace it in place; line/block-wise
  still use the line range.
- ✅ **Thesaurus / synonyms** (`thesaurus/`): replace the word under the cursor
  with a synonym from the free, keyless Datamuse API (async) or a `custom`
  source; opt-in `thesaurus.keymap` / `require("language").synonyms()`.
- ✅ **cspell long-lived process** (`node/cspell_server.js` +
  `spell/providers/cspell_server`): a persistent Node sidecar keeps cspell-lib
  loaded and checks the buffer over stdin/stdout (~instant, no per-scan cold
  start) — code-aware, live-capable. Opt in with `"cspell_server"` in
  `spell.providers.buffer` (needs node + cspell).

- ✅ **Gap-closing round** — wired the pieces the plan declared but hadn't built:
  per-buffer native scan **cache** (`spell/core/cache`, keyed by `changedtick`);
  **`lib.nvim.progress`** feedback on cwd/path CLI scans; **cancellation** of
  in-flight spell scans (a new scan for the same target supersedes the old one,
  in `collect.gather`); wired **`dictionary.replace_all`** (Choose suggestion →
  all occurrences) and **`guard.block_write_on_error`** (opt-in `:w` abort);
  inline **`language:disable-line` / `-next-line` / `-file`** directives.

- ✅ **Multi-file translation** (`translate/files`): `:Translate <lang> cwd` (or
  `path=<dir>`) gathers translatable files, multi-selects via the kit chooser
  (`<Tab>`), and translates each — writing a language-suffixed sibling
  (default), overwriting in place (`--files=replace`, with confirmation), or
  opening scratch buffers (`--files=buffers`). Default via `translate.files.output`.
- ✅ **`:Translate` / `:TranslateReplace` role split**: `translate.default_output`
  changed to `popup` (default) — `:Translate` now shows the result in a
  read-only, focusable `lib.nvim.ui.kit` popup (via `surface.open`, hard
  dependency) without touching the buffer; `--output=` gained `buffer`/
  `vsplit`/`split`/`tab` alongside the existing `replace`/`insert`/`clipboard`/
  `notify` (dropped the old ad-hoc `float`). New `:TranslateReplace` command is
  the direct mutating counterpart (always `replace`, forces file-mode
  `replace` for `cwd`/`path=<dir>`) — restores the classic `:TranslateReplace`
  workflow under its original name. Motion/visual maps (`translate/motion`)
  now hardcode `replace` (rewrite-in-place operator semantics), independent of
  the popup default.
- ✅ **Native recursive disk-tree scan for cwd/path** (`native.scan_tree` +
  `collect.native_tree`): closed a real gap — the native cwd/path fallback
  previously only checked already-open buffers (`collect_loaded_under`),
  silently skipping any file not currently loaded in the session. Now, when no
  external CLI provider (typos/cspell/codespell) is available, native
  recursively walks the directory on disk (async, 20 files/tick via
  `vim.schedule`, cancellable, `lib.nvim.progress` feedback), preferring live
  buffer content for open files and reading closed files fresh from disk.
  Skips vendor dirs (.git/node_modules/.venv/dist/build/target/.cache/
  __pycache__), files >5MB, and files over `spell.max_file_lines`.

- ✅ **Buffer highlights + custom spell provider** (`spell/ui/highlights`,
  `spell/providers/custom`): closed the two gaps found while pruning the
  personal open-items doc. `spell.highlights.enable = true` marks issues
  directly in the buffer via `nvim_buf_set_extmark` (own
  `LanguageSpellHighlight`/`LanguageGrammarHighlight` groups, `default = true`
  so a colorscheme can override), independent of `vim.diagnostic.config()` —
  wired through `spell/ui/list.lua`'s existing `publish`/`clear` choke point
  so every call site (session, live scan, panel) gets it automatically.
  `spell.providers.custom = { cmd, parse }` is a cwd/path escape hatch for a
  checker without a bundled adapter, registered in `collect.lua`'s
  `CLI_MODULES` next to typos/cspell/codespell — add `"custom"` to
  `spell.providers.cwd` to use it. Mirrors `translate.custom`'s pattern.

- ✅ **Indent-preserving translate** (`translate/indent`): `:Translate`/
  `:TranslateReplace` now capture each line's leading whitespace, translate
  the dedented text, and re-prepend the indent to the matching output line —
  closes a round-trip gap where providers (notably Google's `gtx`) normalize
  away leading whitespace, dropping indented list items to column 0. Skipped
  when the provider merges/splits lines (line counts no longer match 1:1).
- ✅ **Bindings hardening**: split `lua/language/bindings/` into per-concern
  subfolders (`keymaps/`, `autocmds/`, `usrcmds/`, `which_key/`, each an
  `init.lua`); routed autocmd registration through `lib.nvim.autocmd` and the
  session fix-keymaps through `lib.nvim.map`; fixed a stale-buffer race in
  `fix_current`/`fix1` where the deferred refresh could resolve the wrong (or
  no) session if the current buffer changed during the 60ms window.

## Planned

_All roadmap items implemented._ Future ideas welcome.
