---@module 'language.spell.core.collect'
---@brief Runs the configured providers for a scope, then post-processes.
---@description
--- Central place both the session flow and the review panel go through, so
--- filtering and deduplication are identical everywhere.
---
--- Two entry points:
---   • `scan`   — synchronous. Native spelling (+ LSP grammar harvest for
---     single-buffer scopes). Used by the buffer session flow.
---   • `gather` — async-capable. For cwd/path scopes it prefers an external CLI
---     provider (typos) when configured and available, falling back to the
---     synchronous native scan. Delivers issues via callback. Used by wide
---     scopes and the panel.

require("language.@types")
require("language.spell.@types")

local native = require("language.spell.providers.native")
local lsp = require("language.spell.providers.lsp")
local ignore = require("language.spell.core.ignore")

---External CLI providers (async), keyed by config name. Each exposes
---`available()` and `scan_async(scope, cfg, cb)`.
---@type table<string, string>
local CLI_MODULES = {
  typos = "language.spell.providers.typos",
  cspell = "language.spell.providers.cspell",
  codespell = "language.spell.providers.codespell",
}

local M = {}

---Deduplicate issues by (path, word), counting occurrences; keeps first hit.
---@param issues LanguageSpellIssue[]
---@return LanguageSpellIssue[]
local function dedupe(issues)
  ---@type table<string, LanguageSpellIssue>
  local seen = {}
  ---@type LanguageSpellIssue[]
  local out = {}
  for _, issue in ipairs(issues) do
    local key = (issue.path or "") .. "\0" .. issue.word
    local hit = seen[key]
    if hit then
      hit.occurrences = (hit.occurrences or 1) + 1
    else
      issue.occurrences = 1
      seen[key] = issue
      out[#out + 1] = issue
    end
  end
  return out
end

---Apply ignore filter and (optional) dedupe.
---@param issues LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
local function post(issues, cfg)
  issues = ignore.filter(issues)
  if cfg.ui and cfg.ui.dedupe then
    issues = dedupe(issues)
  end
  return issues
end

---@param cfg LanguageSpellCfg
---@param list string[]|nil
---@param name string
---@return boolean
local function provider_enabled(cfg, list, name)
  for _, n in ipairs(list or {}) do
    if n == name then
      return true
    end
  end
  return false
end

---Synchronous scan: native spelling plus LSP grammar harvest for single-buffer
---scopes. For cwd/path this uses the native loaded-buffer scan.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan(scope, cfg)
  local issues = native.scan_scope(scope, cfg)

  local single_buffer = scope.kind == "buffer"
    or scope.kind == "visible"
    or scope.kind == "selection"
  local buffer_providers = cfg.providers and cfg.providers.buffer
  if single_buffer and provider_enabled(cfg, buffer_providers, "lsp") and lsp.available() then
    vim.list_extend(issues, lsp.scan_scope(scope, cfg))
  end

  return post(issues, cfg)
end

---Async-capable scan. For cwd/path, prefers the first available external CLI
---provider in `providers.cwd`, else falls back to the synchronous native scan.
---Always delivers via `cb`.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job|nil
function M.gather(scope, cfg, cb)
  if scope.kind ~= "cwd" and scope.kind ~= "path" then
    cb(M.scan(scope, cfg))
    return nil
  end

  for _, name in ipairs((cfg.providers and cfg.providers.cwd) or { "native" }) do
    local mod_path = CLI_MODULES[name]
    if mod_path then
      local provider = require(mod_path)
      if provider.available() then
        return provider.scan_async(scope, cfg, function(issues)
          cb(post(issues, cfg))
        end)
      end
    elseif name == "native" then
      cb(M.scan(scope, cfg))
      return nil
    end
  end

  -- Nothing matched: native fallback.
  cb(M.scan(scope, cfg))
  return nil
end

return M
