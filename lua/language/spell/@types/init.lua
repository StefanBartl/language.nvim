---@meta
---@module 'language.spell.@types'
---@brief Type definitions for the spell/grammar domain.

-- #####################################################################
-- Issue model
-- #####################################################################

---@alias LanguageSpellKind "spell"|"grammar"|"style"|"rare"|"caps"
---@alias LanguageSpellSource "native"|"typos"|"codespell"|"cspell"|"harper"|"ltex"|"custom"

---@class LanguageSpellIssue
---@field bufnr       integer|nil        -- set when the source is an open buffer
---@field path        string             -- absolute path (or buffer name)
---@field lnum        integer            -- 1-based line
---@field col         integer            -- 1-based byte column (word start)
---@field end_col     integer            -- exclusive
---@field word        string             -- offending word (or subword after split)
---@field kind        LanguageSpellKind
---@field source      LanguageSpellSource
---@field message     string|nil         -- provider explanation (grammar)
---@field rule        string|nil         -- rule id (harper/ltex → "disable rule")
---@field suggestions string[]|nil       -- lazy: filled on demand
---@field occurrences integer|nil        -- count of identical errors in scope (dedupe)

-- #####################################################################
-- Provider interface
-- #####################################################################

---@class LanguageSpellProvider
---@field name        LanguageSpellSource
---@field available   fun(): boolean
---@field scan_scope  fun(scope: LanguageScope, cfg: LanguageSpellCfg): LanguageSpellIssue[]
---@field suggest     fun(issue: LanguageSpellIssue): string[]
---@field supports    table<"buffer"|"cwd"|"grammar", boolean>

-- #####################################################################
-- Per-buffer session state
-- #####################################################################

---@class LanguageSpellBufState
---@field spell_was_on    boolean
---@field prev_spelllang  string
---@field lang            string

return {}
