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
---     provider (typos/cspell/codespell) when configured and available, else
---     falls back to a real recursive native disk-tree scan (async, chunked —
---     not just already-loaded buffers). Delivers issues via callback. Used by
---     wide scopes and the panel.

require("language.@types")
require("language.spell.@types")

local native = require("language.spell.providers.native")
local lsp = require("language.spell.providers.lsp")
local ignore = require("language.spell.core.ignore")
local cache = require("language.spell.core.cache")

---In-flight async jobs, keyed so a new scan for the same target cancels the
---previous one (live scan while typing, panel re-open, …).
---@type table<string, Language.Job>
local active = {}

---@param key string
local function cancel_key(key)
  local j = active[key]
  if j then
    pcall(j.cancel)
    active[key] = nil
  end
end

---@param scope LanguageScope
---@return string
local function cancel_key_for(scope)
  if scope.kind == "cwd" or scope.kind == "path" then
    return "wide:" .. (scope.path or "cwd")
  end
  return "buf:" .. tostring(scope.bufnr or 0)
end

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

---Native scan for a single-buffer scope, with whole-buffer caching.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
local function native_cached(scope, cfg)
  if scope.kind == "buffer" and scope.bufnr then
    local hit = cache.get(scope.bufnr)
    if hit then
      return hit
    end
    local issues = native.scan_scope(scope, cfg)
    cache.set(scope.bufnr, issues)
    return issues
  end
  return native.scan_scope(scope, cfg)
end

---Raw synchronous collection for a single-buffer scope: native spelling (cached)
---plus fresh LSP grammar harvest (no post-processing). Returns a new list so
---post-processing never mutates the cached native issues in place.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
local function raw_buffer(scope, cfg)
  ---@type LanguageSpellIssue[]
  local issues = {}
  vim.list_extend(issues, native_cached(scope, cfg))
  local buffer_providers = cfg.providers and cfg.providers.buffer
  if provider_enabled(cfg, buffer_providers, "lsp") and lsp.available() then
    vim.list_extend(issues, lsp.scan_scope(scope, cfg))
  end
  return issues
end

---Synchronous scan: native spelling plus LSP grammar harvest for single-buffer
---scopes. For cwd/path this uses the native loaded-buffer scan only (fast, but
---blind to files that aren't open) — use `gather` for a full disk-tree scan.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan(scope, cfg)
  if is_single_buffer(scope) then
    return post(raw_buffer(scope, cfg), cfg)
  end
  return post(native.scan_scope(scope, cfg), cfg)
end

---Native async recursive disk-tree scan for a cwd/path scope (real fallback
---when no external CLI spell provider is available), with progress feedback.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param key string
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job|nil
local function native_tree(scope, cfg, key, cb)
  local prog = require("lib.nvim.progress").create({ title = "[language]" })
  prog:update({ text = ("spell-scanning %s (native)…"):format(scope.kind) })
  active[key] = native.scan_tree(scope, cfg, function(issues)
    active[key] = nil
    local result = post(issues, cfg)
    prog:finish(("%d spelling issue(s)"):format(#result))
    cb(result)
  end)
  return active[key]
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
  local key = cancel_key_for(scope)
  -- A new scan for the same target supersedes any in-flight one.
  cancel_key(key)

  if is_single_buffer(scope) then
    local raw = raw_buffer(scope, cfg)
    local buffer_providers = cfg.providers and cfg.providers.buffer
    if provider_enabled(cfg, buffer_providers, "cspell_server") then
      local server = require("language.spell.providers.cspell_server")
      if server.available() then
        active[key] = server.check(scope, cfg, function(server_issues)
          active[key] = nil
          vim.list_extend(raw, server_issues)
          cb(post(raw, cfg))
        end)
        return active[key]
      end
    end
    cb(post(raw, cfg))
    return nil
  end

  -- cwd/path: first available external CLI provider, else a real recursive
  -- native disk-tree scan (async, chunked) — not just already-loaded buffers.
  for _, name in ipairs((cfg.providers and cfg.providers.cwd) or { "native" }) do
    local mod_path = CLI_MODULES[name]
    if mod_path then
      local provider = require(mod_path)
      if provider.available() then
        local prog = require("lib.nvim.progress").create({
          title = "[language]",
        })
        prog:update({ text = ("spell-scanning %s (%s)…"):format(scope.kind, name) })
        active[key] = provider.scan_async(scope, cfg, function(issues)
          active[key] = nil
          local result = post(issues, cfg)
          prog:finish(("%d spelling issue(s)"):format(#result))
          cb(result)
        end)
        return active[key]
      end
    elseif name == "native" then
      return native_tree(scope, cfg, key, cb)
    end
  end

  -- Nothing in `providers.cwd` matched/available: still do a real tree scan.
  return native_tree(scope, cfg, key, cb)
end

return M
