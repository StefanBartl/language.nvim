---@meta
---@module 'language.translate.@types'
---@brief Type definitions for the translate domain.

-- #####################################################################
-- Provider interface
-- #####################################################################

---@class LanguageTranslateProvider
---@field name      string
---@field available fun(cfg: LanguageTranslateCfg): boolean
--- Translate `lines` to `target` (optionally from `source`, else auto). Invokes
--- `cb` exactly once with the translated lines, or ok=false + an error message.
---@field translate fun(lines: string[], target: string, source: string|nil, cfg: LanguageTranslateCfg, cb: fun(ok: boolean, result: string[]|string)): Language.Job|nil

-- #####################################################################
-- Run options
-- #####################################################################

---@class LanguageTranslateRunOpts
---@field nocode boolean|nil
---@field output LanguageTranslateOutput|nil
---@field scope  LanguageScope|nil

return {}
