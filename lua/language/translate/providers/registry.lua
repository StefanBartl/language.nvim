---@module 'language.translate.providers.registry'
---@brief Resolves the active translate provider from config, with fallback.
---@description
--- Phase-3 ships the keyless `google` provider. `deepl`, `shell` and a
--- user-defined `custom` engine are registered in a later phase; the registry
--- shape is already in place so adding them is a one-line change.

require("language.translate.@types")

local M = {}

---@type table<string, LanguageTranslateProvider>
local PROVIDERS = {
  google = require("language.translate.providers.google"),
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
