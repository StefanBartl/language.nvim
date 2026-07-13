---@meta
---@module 'language.@types'
---@brief Central shared type definitions for language.nvim.
---@description
--- Types that cross domain boundaries live here (scope model, public facade).
--- Domain-local types live in `language/spell/@types` and
--- `language/translate/@types`. Every `@types` module returns an empty table.

-- #####################################################################
-- Scope model (shared by both domains)
-- #####################################################################

---@alias LanguageScopeKind
---| "buffer"    # Whole current buffer (default for :Spellcheck)
---| "visible"   # Only the visible window range (perf mode for live scan)
---| "cwd"       # Recursively across the project working directory (always async)
---| "path"      # A given file OR directory (recursive) passed as `path=<p>`
---| "selection" # A visual/line range (mainly :Translate)

---@class LanguageScope
--- A single, explicit description of *where* an action operates. Parsed once
--- from the command arguments and threaded through scan/translate so no module
--- re-derives the target (Zentrale-Prinzipien §3: context over repeated API calls).
---@field kind  LanguageScopeKind
---@field bufnr integer|nil                    -- set for buffer/visible/selection
---@field path  string|nil                     -- set for path: file or directory
---@field range { s: integer, e: integer }|nil -- set for selection/visible (1-based, inclusive)

-- #####################################################################
-- Public facade
-- #####################################################################

---@class Language.Module
---@field setup       fun(opts?: LanguageConfig): nil
---@field spellcheck  fun(lang?: string, scope?: string): nil
---@field translate   fun(lang: string, opts?: table): nil
---@field open_panel  fun(scope?: string): nil
---@field health      table

return {}
