---@meta
---@module 'language.config.@types'
---@brief Type definitions for the language.nvim configuration tree.
---@description
--- The config is split into two independent domain subtrees (`spell`,
--- `translate`) plus a couple of top-level switches. See config/DEFAULTS.lua
--- for the concrete default values.

-- #####################################################################
-- Spell subtree
-- #####################################################################

---@class LanguageSpellProvidersCfg
---@field order  string[]                       -- provider resolution order
---@field buffer string[]                       -- providers used for buffer/visible scope
---@field cwd    string[]                        -- providers used for cwd/path scope (CLI preferred)
---@field native { spelllang: string|nil }       -- nil = inherit vim 'spelllang'
---@field lsp    { enable: boolean, servers: string[] }

---@class LanguageSpellWordSplitCfg
---@field enable     boolean                     -- split CamelCase/snake_case into subwords
---@field min_length integer                     -- ignore subwords shorter than this

---@class LanguageSpellRegionsCfg
---@field treesitter_spell boolean               -- only check Treesitter @spell regions when available
---@field skip_urls        boolean
---@field skip_emails      boolean

---@class LanguageSpellDictionaryCfg
---@field ignore_file   string                   -- persistent ignore list path
---@field use_spellfile boolean                  -- also write to nvim spellfile on add-to-dict
---@field replace_all   boolean                  -- apply a chosen suggestion to all identical errors in scope

---@class LanguageSpellUiCfg
---@field view     "picker"|"select"|"quickfix"
---@field preview  boolean
---@field group_by "file"|"none"
---@field dedupe   boolean

---@class LanguageSpellCfg
---@field providers        LanguageSpellProvidersCfg
---@field filetypes        string[]
---@field default_scope    LanguageScopeKind
---@field live             boolean
---@field live_scope       LanguageScopeKind
---@field scan_debounce_ms integer
---@field word_split       LanguageSpellWordSplitCfg
---@field max_highlights   integer
---@field max_file_lines   integer
---@field skip_readonly    boolean
---@field regions          LanguageSpellRegionsCfg
---@field programming_dict boolean
---@field ui               LanguageSpellUiCfg
---@field dictionary       LanguageSpellDictionaryCfg
---@field guard            { block_write_on_error: boolean }
---@field keymaps          table<string, string|false>

-- #####################################################################
-- Translate subtree
-- #####################################################################

---@alias LanguageTranslateOutput "replace"|"float"|"notify"|"clipboard"|"insert"
---@alias LanguageTranslateInput  "selection"|"clipboard"|"input"

---@class LanguageTranslateCfg
---@field engine         string                  -- "google"|"deepl"|"shell"|<custom key>
---@field fallback       string[]                -- engine fallback chain
---@field default_output LanguageTranslateOutput
---@field default_input  LanguageTranslateInput
---@field default_langs  string[]
---@field default_target string|nil              -- fixed target for motion/visual maps; nil = prompt
---@field nocode_default boolean
---@field timeout_ms     integer
---@field deepl          { api_key: string|nil }
---@field custom         { cmd: fun(text: string[], target: string): string[], parse: fun(out: string): string[] }|nil
---@field keymaps        { operator: string|false, visual: string|false }

-- #####################################################################
-- Root
-- #####################################################################

---@class LanguageConfig
---@field spell     LanguageSpellCfg
---@field translate LanguageTranslateCfg
---@field commands  boolean

return {}
