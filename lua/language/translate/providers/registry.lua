---@module 'language.translate.providers.registry'
---@brief Resolves the active translate provider from config, with fallback.
---@description
--- Registered engines: `google` (keyless default), `deepl` (official API, key
--- from config/env), `shell` (translate-shell `trans`), `ai` (ai.nvim, a soft
--- dependency) and `custom` (any CLI via a user-supplied cmd/parse). `resolve` tries the configured engine, then
--- the fallback chain, returning the first whose `available()` is true. The
--- returned providers split large inputs into line-aligned blocks
--- (`language.translate.chunk`).

require("language.translate.@types")

local chunk = require("language.translate.chunk")

local M = {}

-- Every engine is wrapped once here, so oversized inputs are split into
-- provider-sized blocks for all callers (command, operator, window, hover,
-- multi-file) in one place instead of inside each provider.
---@type table<string, LanguageTranslateProvider>
local PROVIDERS = {
  google = chunk.wrap(require("language.translate.providers.google")),
  deepl = chunk.wrap(require("language.translate.providers.deepl")),
  shell = chunk.wrap(require("language.translate.providers.shell")),
  custom = chunk.wrap(require("language.translate.providers.custom")),
  ai = chunk.wrap(require("language.translate.providers.ai")),
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

  for i, name in ipairs(order) do
    local p = PROVIDERS[name]
    if p and p.available(cfg) then
      return p, nil
    end
    -- An engine that sends the text to a model the user chose (`ai`) is not
    -- replaced silently by a keyless third party when it is the configured one:
    -- the reason is reported instead.
    if i == 1 and p and type(p.blocked) == "function" then
      local ok, why = pcall(p.blocked, cfg)
      if ok and type(why) == "string" then
        return nil, ("translate engine '%s' is not usable: %s"):format(name, why)
      end
    end
  end
  return nil, ("no available translate engine (tried: %s)"):format(table.concat(order, ", "))
end

return M
