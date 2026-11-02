---@module 'language.translate.providers.registry'
---@brief Resolves the active translate provider from config, with fallback.
---@description
--- Registered engines: `google` (keyless default), `deepl` (official API, key
--- from config/env), `shell` (translate-shell `trans`), `ai` (ai.nvim, a soft
--- dependency) and `custom` (any CLI via a user-supplied cmd/parse). `resolve` walks the configured engine, then
--- the fallback chain, and keeps every engine whose `available()` is true.
--- The returned providers split large inputs into line-aligned blocks
--- (`language.translate.chunk`).
---
--- **Failover.** With more than one available engine in the chain, the provider
--- `resolve` returns tries them in order: when a request fails (timeout, HTTP
--- error, a page instead of JSON, ...) the call goes on with the next engine of
--- the chain and only the last error is reported. The chain is exactly what the
--- author wrote in `translate.engine` and `translate.fallback`: text is never
--- handed to an engine that is not listed there. Not failed over: an error in
--- the input itself (marked `"input"` by the chunk wrapper: too large, too many
--- requests), a cancel, and the `ai` engine (a policy refusal or a bulk limit
--- is final, see `providers/ai.lua`). `opts.failover = false` returns the first
--- available engine alone (`translate_markdown`, whose unit cache is keyed by
--- the engine that translated).

require("language.translate.@types")

local chunk = require("language.translate.chunk")
local notify = require("lib.nvim.notify").create("[language.translate]")

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

---The provider that runs `chain` in order: the first engine that answers wins. See the
---module comment for what is, and what is not, a reason to go on.
---@param chain LanguageTranslateProvider[]  -- at least two
---@return LanguageTranslateProvider
local function with_failover(chain)
  local composite = vim.tbl_extend("force", {}, chain[1])
  ---@type LanguageTranslateFn
  composite.translate = function(lines, target, source, cfg, cb)
    local cancelled, settled = false, false
    local current, job = 0, nil

    ---@param ok boolean
    ---@param result string[]|string
    local function settle(ok, result)
      if settled or cancelled then
        return
      end
      settled = true
      cb(ok, result)
    end

    local try
    ---@param i integer
    try = function(i)
      current = i
      local member = chain[i]
      local answered = false
      local function on_result(ok, result, kind)
        if answered or cancelled or settled then
          return
        end
        answered = true
        if ok then
          if i > 1 then
            notify.info(
              ("translated by '%s' (%s failed)"):format(
                member.name,
                table.concat(
                  vim.tbl_map(function(p)
                    return "'" .. p.name .. "'"
                  end, vim.list_slice(chain, 1, i - 1)),
                  ", "
                )
              )
            )
          end
          settle(true, result)
        elseif i == #chain or kind == "input" or member.name == "ai" then
          settle(false, result)
        else
          try(i + 1)
        end
      end
      local started, h = pcall(member.translate, lines, target, source, cfg, on_result)
      if not started then
        on_result(false, tostring(h))
        return
      end
      -- a synchronous answer has moved on already: its handle is done
      if current == i and not answered then
        job = h
      end
    end
    try(1)

    return {
      cancel = function()
        if cancelled or settled then
          return
        end
        cancelled = true
        if job and type(job.cancel) == "function" then
          pcall(job.cancel)
        end
      end,
    }
  end
  return composite
end

---Resolve the provider for `cfg`: the configured engine, then the fallback chain. With several
---available engines the provider fails over from one to the next (see the module comment);
---`opts.failover = false` returns the first available one only.
---@param cfg LanguageTranslateCfg
---@param opts? { failover?: boolean }
---@return LanguageTranslateProvider|nil provider, string|nil err
function M.resolve(cfg, opts)
  local order = {}
  if type(cfg.engine) == "string" then
    order[#order + 1] = cfg.engine
  end
  for _, name in ipairs(cfg.fallback or {}) do
    order[#order + 1] = name
  end

  local chain, seen = {}, {}
  for i, name in ipairs(order) do
    local p = PROVIDERS[name]
    if p and not seen[name] and p.available(cfg) then
      seen[name] = true
      chain[#chain + 1] = p
    elseif i == 1 and #chain == 0 and p and type(p.blocked) == "function" then
      -- An engine that sends the text to a model the user chose (`ai`) is not
      -- replaced silently by a keyless third party when it is the configured one:
      -- the reason is reported instead.
      local ok, why = pcall(p.blocked, cfg)
      if ok and type(why) == "string" then
        return nil, ("translate engine '%s' is not usable: %s"):format(name, why)
      end
    end
    if #chain > 0 and (opts and opts.failover == false) then
      break
    end
  end
  if #chain == 0 then
    return nil, ("no available translate engine (tried: %s)"):format(table.concat(order, ", "))
  end
  if #chain == 1 then
    return chain[1], nil
  end
  return with_failover(chain), nil
end

return M
