---@module 'language.spell.providers.codespell'
---@brief Spell scanning via the `codespell` CLI (async).
---@description
--- codespell prints `path:line: typo ==> corrections` (no column). Used for
--- cwd/path scopes when configured. codespell exits non-zero when it finds
--- typos, so the exit code is ignored and stdout is parsed. Common vendor
--- directories are skipped.

require("language.@types")
require("language.spell.@types")

local fn = vim.fn
local job = require("language.util.job")
local putil = require("language.spell.providers.util")

local M = {}

M.name = "codespell"
M.supports = { buffer = false, cwd = true, grammar = false }

---@return boolean
function M.available()
  return fn.executable("codespell") == 1
end

---Parse codespell output into issues. Public for testing.
---@param out string
---@param base string|nil
---@return LanguageSpellIssue[]
function M.parse(out, base)
  ---@type LanguageSpellIssue[]
  local issues = {}
  for line in out:gmatch("[^\r\n]+") do
    -- "path:line: typo ==> correction[, correction...]"
    local path, lnum, word, corr = line:match("^(.-):(%d+):%s*(%S+)%s*==>%s*(.+)$")
    if path and word then
      local abs = putil.resolve_path(path, base)
      ---@type string[]
      local suggestions = {}
      for s in tostring(corr):gmatch("[^,]+") do
        suggestions[#suggestions + 1] = vim.trim(s)
      end
      ---@type LanguageSpellIssue
      local issue = {
        bufnr = putil.bufnr_for(abs),
        path = abs,
        lnum = tonumber(lnum) or 1,
        col = 1,
        end_col = 1 + #word,
        word = word,
        kind = "spell",
        source = "codespell",
        suggestions = #suggestions > 0 and suggestions or nil,
      }
      issues[#issues + 1] = issue
    end
  end
  return issues
end

---Async scan of a cwd/path scope.
---@param scope LanguageScope
---@param _cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job|nil
function M.scan_async(scope, _cfg, cb)
  if not M.available() then
    cb({})
    return nil
  end

  local skip = { "--skip=.git,node_modules,.venv,dist,build,target,*.min.*,*.lock" }
  local base, argv
  if scope.kind == "path" and scope.path then
    if fn.isdirectory(scope.path) == 1 then
      base, argv = scope.path, { "codespell", "." }
    else
      base, argv = nil, { "codespell", scope.path }
    end
  else
    base, argv = fn.getcwd(), { "codespell", "." }
  end
  vim.list_extend(argv, skip)

  return job.run(argv, {
    cwd = base,
    timeout_ms = 20000,
    on_done = function(_ok, out, _err)
      cb(M.parse(out or "", base))
    end,
  })
end

return M
