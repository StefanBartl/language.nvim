---@module 'language.config.DEFAULTS'
---@brief Plugin-side default configuration for language.nvim.
---@description
--- Overridden by user options passed to require("language").setup().
--- See config/@types for the full LanguageConfig type. The tree is split into
--- two independent domains: `spell` (spelling + grammar) and `translate`.

require("language.config.@types")

---@type LanguageConfig
local defaults = {
  spell = {
    providers = {
      order = { "native", "lsp", "typos", "cspell", "codespell" },
      buffer = { "native", "lsp" },
      cwd = { "typos", "native" }, -- CLI preferred for tree scan
      native = { spelllang = nil }, -- nil = inherit vim 'spelllang'
      lsp = { enable = true, servers = { "harper_ls", "ltex" } },
      -- Escape hatch for a spellchecker CLI without a bundled adapter: add
      -- "custom" to `providers.cwd` and set cmd/parse. Mirrors translate.custom.
      custom = nil, -- { cmd = function(scope, cfg) ... end, parse = function(out, base) ... end }
    },
    filetypes = { "markdown", "text", "gitcommit", "tex", "rst", "asciidoc", "help" },
    default_scope = "buffer", -- buffer|visible|cwd|path
    live = false, -- opt-in live scan
    live_scope = "visible", -- perf: live only within the visible range
    scan_debounce_ms = 400,
    -- Code-identifier splitting: break CamelCase & snake_case into subwords
    -- before checking against the dictionary.
    word_split = { enable = true, min_length = 4 },
    -- Perf/safety caps:
    max_highlights = 100, -- max highlighted errors per buffer
    max_file_lines = 20000, -- above this: no auto/live scan
    skip_readonly = true, -- do not scan readonly buffers
    -- Only check spellable regions (Treesitter @spell / predicate):
    regions = { treesitter_spell = true, skip_urls = true, skip_emails = true },
    programming_dict = false, -- opt-in: extra technical wordlist appended to spelllang
    -- User-supplied session wordlists, applied the same way as
    -- programming_dict (`:spellgood!`) but independent of it and of
    -- `spelllang` — e.g. domain vocabulary that keeps getting flagged when
    -- writing non-English technical prose. { ["my-list"] = { "word1", ... } }
    extra_wordlists = {},
    ui = {
      view = "picker",
      preview = true,
      group_by = "file",
      dedupe = true,
      -- How long to wait after an LSP code action before re-reading the
      -- buffer. There is no completion signal to hook, so this is a guess at
      -- the server's latency -- raise it for a slow one.
      lsp_refresh_delay_ms = 500,
    },
    dictionary = {
      ignore_file = vim.fn.stdpath("state") .. "/language/spell_ignore.txt",
      use_spellfile = true,
      replace_all = true, -- apply suggestion to all identical errors in scope
    },
    guard = { block_write_on_error = false }, -- opt-in: abort :w on spelling errors
    -- Opt-in: mark issues directly in the buffer via extmarks (LanguageSpellHighlight/
    -- LanguageGrammarHighlight highlight groups), independent of vim.diagnostic config.
    highlights = { enable = false, style = "underline" }, -- style: "underline"|"undercurl"
    keymaps = {
      panel = "<leader>ss",
      next = "]s",
      fix = "<leader>z=",
      fix1 = "<leader>z1",
    },
  },

  -- Register a position preview with hover.nvim, so `:Hover show` over a word
  -- answers with its translation. `on_request` there, so the automatic hover
  -- trigger never asks -- every answer is a network request carrying the word
  -- under the cursor, and that belongs to a deliberate press rather than to a
  -- quiet moment. A no-op without hover.nvim installed; see lua/language/hover.lua.
  hover = true,

  translate = {
    engine = "google", -- "google"|"deepl"|"shell"|<custom>
    fallback = { "google" }, -- engine fallback chain (graceful degradation)
    default_output = "popup", -- "popup"|"replace"|"buffer"|"vsplit"|"split"|"tab"|"insert"|"clipboard"|"notify"
    default_input = "selection", -- selection|clipboard|input
    default_langs = { "EN", "DE", "FR", "ZH", "JA" },
    default_target = nil, -- fixed target for motion/visual maps; nil = prompt
    nocode_default = false,
    timeout_ms = 8000, -- network timeout per job
    deepl = { api_key = nil }, -- or ENV "DEEPL_API_KEY"
    custom = nil, -- { cmd = function(text, target) ... end, parse = function(out) ... end }
    -- Recall previous translations (:Translate history picker / window <C-h>).
    history = {
      enable = true,
      max = 50, -- ring size
      persist = false, -- also save to disk (JSON) across sessions
      file = vim.fn.stdpath("state") .. "/language/translate_history.json",
    },
    -- Opt-in motion/visual keymaps (off by default to avoid clobbering keys):
    --   operator: `<lhs>{motion}` translates the moved-over text (e.g. gtrip)
    --   visual:   `<lhs>` translates the visual selection
    --   to:       one key per language, forcing that target for a single run
    --             (e.g. to = { EN = "<lhs>", DE = "<lhs>" }). Works in both
    --             normal (operator) and visual mode. Unset by default.
    --             A count cannot carry the language on an operator -- there it
    --             belongs to the motion -- hence a key per language.
    keymaps = { operator = false, visual = false, to = {} },
    -- Multi-file translation (:Translate cwd / path=<dir>): pick files (kit
    -- multi-select, <Tab>), then per file:
    --   "suffix"  → write a sibling file  name.<TARGET>.ext  (non-destructive, default)
    --   "replace" → overwrite the file in place (asks for confirmation first)
    --   "buffers" → open each translation in a scratch buffer (no disk write)
    -- Override per call with `--files=<mode>`.
    files = {
      output = "suffix",
      extensions = { "md", "markdown", "txt", "text", "rst", "adoc", "asciidoc", "tex", "org" },
      max_kb = 512,
    },
  },

  -- Thesaurus / synonyms (writing aid). Default source is the free, keyless
  -- Datamuse API (English). Set a `custom` function for another source/language.
  thesaurus = {
    enable = true,
    source = "datamuse", -- "datamuse" | "custom"
    max = 20,
    timeout_ms = 6000,
    keymap = false, -- opt-in: replace the word under the cursor with a synonym
    -- custom = function(word, cb) cb({ "syn1", "syn2" }) end,
  },

  commands = true,

  which_key = { enable = true },

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README "Health".
  deps_popup = true,
}

return defaults
