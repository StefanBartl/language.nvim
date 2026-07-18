# Features

- **`:Spellcheck`** — spelling/grammar session via native `vim.spell`, output
  as diagnostics + [Trouble](https://github.com/folke/trouble.nvim) or
  quickfix fallback. `z=` fix with automatic advance to the next issue,
  per-buffer session state, spelllang restoration.
- **Grammar & providers** — grammar diagnostics from `harper_ls`/`ltex` appear
  in the same panel; optional external spell CLIs (`typos`, `cspell`,
  `codespell`) for cwd/path scans; an optional **persistent cspell sidecar**
  (`"cspell_server"` in `spell.providers.buffer`, requires node+cspell) for
  fast, code-aware, live buffer checks. Native detection splits
  CamelCase/snake_case and only checks Treesitter `@spell` regions
  (comments/strings/prose) — no false positives on identifiers.
- **`:Translate`** / **`:TranslateReplace`** — translate a range/selection.
  `:Translate` shows the result by default in a **popup** (`lib.nvim.ui.kit`,
  read-only, focusable/scrollable, `q`/`<Esc>` closes it) — the buffer stays
  untouched; alternatively `--output=replace|buffer|vsplit|split|tab|insert|
  clipboard|notify`. `:TranslateReplace` is the direct, mutating counterpart
  (always `replace`, no `--output=`) — the classic "select, translate,
  replace" behavior. Motion/visual mappings (`translate.keymaps`) always
  replace, regardless of the popup default. `--nocode` skips fenced and
  inline code (only relevant for replace). Engines: Google (keyless), DeepL,
  translate-shell, custom CLI — with a fallback chain. `:Translate <lang>
  cwd`/`path=<dir>` translates multiple files (multi-select via
  `lib.nvim.ui.kit`, output as a language suffix, in place or into a scratch
  buffer).
- **Thesaurus** — `require("language").synonyms()` replaces the word under
  the cursor with a synonym (Datamuse API, keyless; or your own
  source/language).
- **Silencing false positives** — inline directives `language:disable-line`
  / `-next-line` / `-file` (in a comment), a persistent ignore list,
  dictionary. Opt-in `spell.guard.block_write_on_error` aborts `:w` on typos.
- **Buffer highlights** (`spell.highlights.enable`) — additionally marks
  issues directly in the buffer via extmark (`underline`/`undercurl`),
  independent of the user's `vim.diagnostic` config. Dedicated highlight
  groups (`LanguageSpellHighlight`/`LanguageGrammarHighlight`, overridable
  per colorscheme).
- **Custom spell CLI** (`spell.providers.custom`) — an escape hatch for
  checkers without a built-in adapter (analogous to `translate.custom`):
  `{ cmd = function(scope, cfg) ... end, parse = function(out, base) ... end }`,
  activated via `"custom"` in `spell.providers.cwd`.
- **Scoping** — every action understands a scope: `buffer` (default),
  `visible`, `cwd`, `path=<file|folder>`, `selection`. For `cwd`/`path`,
  spell prefers an external CLI provider (`typos`/`cspell`/`codespell`, a
  single process across the whole tree); without a CLI, a real recursive,
  async chunk-based native directory walk runs instead (not just open
  buffers) — it skips `.git`/`node_modules`/etc., is cancellable, and shows
  progress.
- **Asynchronous & cancellable** — external processes (curl, etc.) run
  non-blocking via an argv-based job layer (no shell interpolation of text)
  with a timeout; a new invocation cancels the running one.
