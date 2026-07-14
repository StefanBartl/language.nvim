---@module 'language.spell.providers.cspell'
---@brief Spell scanning via the `cspell` CLI (async, code-aware).
---@description
--- cspell understands CamelCase/snake_case and code out of the box. Output
--- (`cspell lint --no-color --no-summary --no-progress`) is one line per
--- finding: `path:line:col - Unknown word (word)`. Used for cwd/path scopes.
--- cspell exits non-zero when it finds issues, so the exit code is ignored.
--- Suggestions are not requested (the action menu falls back to native
--- spellsuggest).

require("language.@types")
require("language.spell.@types")

local fn = vim.fn
local job = require("language.util.job")
local putil = require("language.spell.providers.util")

local M = {}

M.name = "cspell"
M.supports = { buffer = false, cwd = true, grammar = false }

---@return boolean
function M.available()
  return fn.executable("cspell") == 1
end

---Parse cspell lint output into issues. Public for testing.
---@param out string
---@param base string|nil
---@return LanguageSpellIssue[]
function M.parse(out, base)
  ---@type LanguageSpellIssue[]
  local issues = {}
  for line in out:gmatch("[^\r\n]+") do
    -- "path:line:col - Unknown word (word)"
    local path, lnum, col, word = line:match("^(.-):(%d+):(%d+)%s*%-%s*Unknown word%s*%((.-)%)")
    if path and word then
      local abs = putil.resolve_path(path, base)
      local c = tonumber(col) or 1
      ---@type LanguageSpellIssue
      local issue = {
        bufnr = putil.bufnr_for(abs),
        path = abs,
        lnum = tonumber(lnum) or 1,
        col = c,
        end_col = c + #word,
        word = word,
        kind = "spell",
        source = "cspell",
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

  local flags = { "--no-color", "--no-summary", "--no-progress" }
  local base, argv
  if scope.kind == "path" and scope.path then
    if fn.isdirectory(scope.path) == 1 then
      base, argv = scope.path, { "cspell", "lint", "**" }
    else
      base, argv = nil, { "cspell", "lint", scope.path }
    end
  else
    base, argv = fn.getcwd(), { "cspell", "lint", "**" }
  end
  vim.list_extend(argv, flags)

  return job.run(argv, {
    cwd = base,
    timeout_ms = 30000,
    on_done = function(_ok, out, _err)
      cb(M.parse(out or "", base))
    end,
  })
end

return M
