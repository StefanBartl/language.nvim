---@module 'language.translate.providers.registry'
---@brief Resolves the active translate provider from config, with fallback.
---@description
--- Registered engines: `google` (keyless default), `deepl` (official API, key
--- from config/env), `shell` (translate-shell `trans`), and `custom` (any CLI
--- via a user-supplied cmd/parse). `resolve` tries the configured engine, then
--- the fallback chain, returning the first whose `available()` is true.

require("language.translate.@types")

local M = {}

---@type table<string, LanguageTranslateProvider>
local PROVIDERS = {
  google = require("language.translate.providers.google"),
  deepl = require("language.translate.providers.deepl"),
  shell = require("language.translate.providers.shell"),
  custom = require("language.translate.providers.custom"),
}

---Return a provider by name (or nil if unknown).
---@param name string
---@return LanguageTranslateProvider|nil
function M.get(name)
  return PROVIDERS[name]
end

---Resolve the first available provider: the configured engine, then the
---fallback chain.
---@param cfg LanguageTranslateCfg
---@return LanguageTranslateProvider|nil provider, string|nil err
function M.resolve(cfg)
  local order = {}
  if type(cfg.engine) == "string" then
    order[#order + 1] = cfg.engine
  end
  for _, name in ipairs(cfg.fallback or {}) do
    order[#order + 1] = name
  end

  for _, name in ipairs(order) do
    local p = PROVIDERS[name]
    if p and p.available(cfg) then
      return p, nil
    end
  end
  return nil, ("no available translate engine (tried: %s)"):format(table.concat(order, ", "))
end

return M
