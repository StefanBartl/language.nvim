---@meta
---@module 'language.translate.@types'
---@brief Type definitions for the translate domain.

-- #####################################################################
-- Provider interface
-- #####################################################################

---@class LanguageTranslateProvider
---@field name      string
---@field available fun(cfg: LanguageTranslateCfg): boolean
---@field translate LanguageTranslateFn

---@alias LanguageTranslateResultCb fun(ok: boolean, result: string[]|string)

--- Translate `lines` to `target` (optionally from `source`, else auto). Invokes
--- `cb` exactly once with the translated lines, or ok=false + an error message.
---@alias LanguageTranslateFn fun(lines: string[], target: string, source: string|nil, cfg: LanguageTranslateCfg, cb: LanguageTranslateResultCb): Language.Job?

-- #####################################################################
-- Run options
-- #####################################################################

---@class LanguageTranslateRunOpts
---@field nocode boolean|nil
---@field output LanguageTranslateOutput|nil
---@field scope  LanguageScope|nil

return {}
