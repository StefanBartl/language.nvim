---@module 'language.spell.core.collect'
---@brief Scan a scope and post-process (ignore filter + dedupe) in one place.
---@description
--- Shared by the session flow (`language.spell`) and the review panel
--- (`language.spell.ui.panel`) so both apply the exact same filtering and
--- deduplication. Currently backed by the native provider; the multi-provider
--- registry is wired in a later phase.

local native = require("language.spell.providers.native")
local ignore = require("language.spell.core.ignore")

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

---Scan a scope and return post-processed issues.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan(scope, cfg)
  local issues = native.scan_scope(scope, cfg)
  issues = ignore.filter(issues)
  if cfg.ui and cfg.ui.dedupe then
    issues = dedupe(issues)
  end
  return issues
end

return M
