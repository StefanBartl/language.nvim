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
- ✅ **Phase 7 — Config integration**: replaced the in-config
  `config/trouble/spell` and `config/translate` modules with the standalone
  plugin.
- ✅ **Phase 8 — Docs**: `doc/language.txt`, this roadmap, README.

## Planned

- 🔜 **Spell providers**: `cspell` and `codespell` adapters (cspell as a
  long-lived process à la fastspell for ~instant checks).
- 🔜 **Grammar fixes**: apply LSP code actions from the panel (add-to-dict,
  disable-rule) instead of only surfacing/jumping.
- 🔜 **Live scan**: opt-in debounced scanning wired end-to-end with the
  `visible` scope default.
- 🔜 **Translate UX**: interactive floating window with live translation and
  motion mappings (pantran-style); reverse translation; query history.
- 🔜 **Fine-grained selection**: column-precise word/visual-block translation
  with UTF-8 handling (currently line-range based).
- 🔜 **Thesaurus/synonym** action in the item menu (vim-lexical-style).
