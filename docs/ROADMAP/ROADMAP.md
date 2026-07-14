# language.nvim — Roadmap

Status of the phased build. ✅ done · 🔜 planned.

## Done

- ✅ **Phase 1 — Scaffold**: plugin entry, `setup()`, config tree (`spell` +
  `translate`), central `@types` (incl. `LanguageScope`), `health.lua`.
- ✅ **Phase 2 — Spell core (native)**: `vim.spell` provider, per-buffer
  session (z= fix-and-advance, spelllang restore), diagnostics namespace,
  Trouble/quickfix fallback. Shared scope parser.
- ✅ **Phase 3 — Translate core (native Google)**: keyless gtx endpoint, async
  via the argv job runner, fenced/inline-code filter, `--nocode`,
  `:Translate` with `replace` default (parity with the old `:TranslateReplace`).
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

## Planned

_All roadmap items implemented._ Future ideas welcome.
