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
---@field limits?    LanguageTranslateLimits      -- block budget; the registry splits larger inputs (`language.translate.chunk`)
---@field cache_id?  fun(cfg: LanguageTranslateCfg): string  -- identity (model, prompt version) that joins the unit cache key of `translate_markdown`
---@field blocked?   fun(cfg: LanguageTranslateCfg): string|nil -- why the engine is unusable although configured; the registry then reports it instead of falling back

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
