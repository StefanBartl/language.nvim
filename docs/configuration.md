# Configuration

`setup()` merges over the defaults (see `lua/language/config/DEFAULTS.lua`).
Excerpt:

```lua
require("language").setup({
  spell = {
    default_scope = "buffer",
    live = false,                -- true = continuous inline diagnostics while typing
    live_scope = "visible",      -- "visible" (visible range only) | "buffer"
    scan_debounce_ms = 400,
    ui = { view = "picker", preview = true }, -- "quickfix" forces the qf fallback

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
    timeout_ms = 8000,
    deepl = { api_key = nil },   -- or $DEEPL_API_KEY
    -- Opt-in motion/visual keymaps (off by default, to avoid claiming keys):
    --   operator: <lhs>{motion} translates the text object (e.g. gtrip)
    --   visual:   <lhs> translates the selection
    keymaps = { operator = false, visual = false },
    -- custom = { cmd = function(lines, target) return { "trans", "-b", ... } end,
    --           parse = function(out) return vim.split(out, "\n") end },
  },
})
```
