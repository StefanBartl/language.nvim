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

---@param scope LanguageScope
---@return boolean
local function is_single_buffer(scope)
  return scope.kind == "buffer" or scope.kind == "visible" or scope.kind == "selection"
end

---Raw synchronous collection for a single-buffer scope: native spelling plus
---LSP grammar harvest (no post-processing).
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
local function raw_buffer(scope, cfg)
  local issues = native.scan_scope(scope, cfg)
  local buffer_providers = cfg.providers and cfg.providers.buffer
  if provider_enabled(cfg, buffer_providers, "lsp") and lsp.available() then
    vim.list_extend(issues, lsp.scan_scope(scope, cfg))
  end
  return issues
end

---Synchronous scan: native spelling plus LSP grammar harvest for single-buffer
---scopes. For cwd/path this uses the native loaded-buffer scan. Does not include
---the async cspell sidecar (use `gather` for that).
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan(scope, cfg)
  if is_single_buffer(scope) then
    return post(raw_buffer(scope, cfg), cfg)
  end
  return post(native.scan_scope(scope, cfg), cfg)
end

---Async-capable scan; always delivers via `cb`.
---  • single-buffer scopes: native + LSP (sync), plus the persistent cspell
---    sidecar (async) when "cspell_server" is in `providers.buffer`.
---  • cwd/path scopes: the first available external CLI provider in
---    `providers.cwd`, else the synchronous native scan.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job|nil
function M.gather(scope, cfg, cb)
  if is_single_buffer(scope) then
    local raw = raw_buffer(scope, cfg)
    local buffer_providers = cfg.providers and cfg.providers.buffer
    if provider_enabled(cfg, buffer_providers, "cspell_server") then
      local server = require("language.spell.providers.cspell_server")
      if server.available() then
        return server.check(scope, cfg, function(server_issues)
          vim.list_extend(raw, server_issues)
          cb(post(raw, cfg))
        end)
      end
    end
    cb(post(raw, cfg))
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

  cb(M.scan(scope, cfg))
  return nil
end

return M
