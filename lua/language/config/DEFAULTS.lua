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
    ui = { view = "picker", preview = true, group_by = "file", dedupe = true },
    dictionary = {
      ignore_file = vim.fn.stdpath("state") .. "/language/spell_ignore.txt",
      use_spellfile = true,
      replace_all = true, -- apply suggestion to all identical errors in scope
    },
    guard = { block_write_on_error = false }, -- opt-in: abort :w on spelling errors
    keymaps = {
      panel = "<leader>ss",
      next = "]s",
      fix = "<leader>z=",
      fix1 = "<leader>z1",
    },
  },

  translate = {
    engine = "google", -- "google"|"deepl"|"shell"|<custom>
    fallback = { "google" }, -- engine fallback chain (graceful degradation)
    default_output = "replace", -- "replace"|"float"|"notify"|"clipboard"|"insert"
    default_input = "selection", -- selection|clipboard|input
    default_langs = { "EN", "DE", "FR", "ZH", "JA" },
    default_target = nil, -- fixed target for motion/visual maps; nil = prompt
    nocode_default = false,
    timeout_ms = 8000, -- network timeout per job
    deepl = { api_key = nil }, -- or ENV "DEEPL_API_KEY"
    custom = nil, -- { cmd = function(text, target) ... end, parse = function(out) ... end }
    -- Opt-in motion/visual keymaps (off by default to avoid clobbering keys):
    --   operator: `<lhs>{motion}` translates the moved-over text (e.g. gtrip)
    --   visual:   `<lhs>` translates the visual selection
    keymaps = { operator = false, visual = false },
  },

  commands = true,
}

return defaults
