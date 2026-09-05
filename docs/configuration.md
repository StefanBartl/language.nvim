# Configuration

`setup()` merges over the defaults (see `lua/language/config/DEFAULTS.lua`).
Excerpt:

```lua
require("language").setup({
  -- Register an on-request position preview with hover.nvim: `:Hover show`
  -- over a word answers with its translation. Never on hover's automatic
  -- trigger -- every answer is a network request carrying that word. A no-op
  -- without hover.nvim installed. See docs/FEATURES/HOVER.md.
  hover = true,
  spell = {
    default_scope = "buffer",
    live = false,                -- true = continuous inline diagnostics while typing
    live_scope = "visible",      -- "visible" (visible range only) | "buffer"
    scan_debounce_ms = 400,
    ui = {
      view = "picker",        -- "quickfix" forces the qf fallback
      preview = true,
      -- How long to wait after an LSP code action before re-reading the
      -- buffer. There is no completion signal to hook, so this is a guess at
      -- the server's latency -- raise it for a slow one.
      lsp_refresh_delay_ms = 500,
    },

    -- Code features
    word_split = { enable = true, min_length = 4 }, -- split CamelCase/snake_case into sub-words
    regions = { treesitter_spell = true, skip_urls = true, skip_emails = true },
    programming_dict = false, -- opt-in: technical word list (git, kubernetes, treesitter, …)

    -- Performance/safety caps
    max_highlights = 100,   -- max inline diagnostics per buffer (panel still shows all of them)
    max_file_lines = 20000, -- above this: no live scan
    skip_readonly = true,

    -- Opt-in: additionally mark issues directly in the buffer via extmark,
    -- independent of vim.diagnostic.config().
    highlights = { enable = false, style = "underline" }, -- style: "underline"|"undercurl"

    keymaps = { panel = "<leader>ss", next = "]s", fix = "<leader>z=", fix1 = "<leader>z1" },
  },
  translate = {
    engine = "google",           -- "google" (keyless) | "deepl" | "shell" | "custom"
    fallback = { "google" },     -- engine chain used if the selected engine is unavailable
    default_output = "popup",    -- popup | replace | buffer | vsplit | split | tab | insert | clipboard | notify
    default_target = nil,        -- fixed target language for motion/visual maps; nil = selection
                                 -- (the hover falls back to "EN" instead: it has nowhere to ask from)
    timeout_ms = 8000,
    deepl = { api_key = nil },   -- or $DEEPL_API_KEY
    -- Opt-in motion/visual keymaps (off by default, to avoid claiming keys):
    --   operator: <lhs>{motion} translates the text object (e.g. gtrip)
    --   visual:   <lhs> translates the selection
    keymaps = { operator = false, visual = false },
    -- custom = { cmd = function(lines, target) return { "trans", "-b", ... } end,
    --           parse = function(out) return vim.split(out, "\n") end },
  },
  thesaurus = {
    enable = true,
    source = "datamuse", -- "datamuse" | "custom"
    max = 20,
    timeout_ms = 6000,
    keymap = false, -- opt-in: replace the word under the cursor with a synonym
    -- custom = function(word, cb) cb({ "syn1", "syn2" }) end,
  },

  commands = true,           -- false = register no user commands at all
  which_key = { enable = true },

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See README "Health".
  deps_popup = true,
})
```
