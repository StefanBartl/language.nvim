---@module 'language.spell.providers.typos'
---@brief Fast tree-wide spell scanning via the `typos` CLI (async).
---@description
--- `typos --format json` emits one JSON object per finding (JSON Lines) and is
--- very fast over a whole directory tree (respecting .gitignore). Used for
--- cwd/path scopes so we never load every file into a scratch buffer. Runs
--- through the argv job runner (non-blocking, cancellable). `typos` exits
--- non-zero when it finds typos, so the exit code is ignored and stdout is
--- always parsed.

require("language.@types")
require("language.spell.@types")

local fn = vim.fn
local job = require("language.util.job")

local M = {}

M.name = "typos"
M.supports = { buffer = false, cwd = true, grammar = false }

---@return boolean
function M.available()
  return fn.executable("typos") == 1
end

---@param p string
---@return boolean
local function is_absolute(p)
  return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\]") ~= nil
end

---Parse typos JSON-lines output into issues.
---@param out string
---@param base string|nil    directory the paths are relative to (nil = absolute)
---@return LanguageSpellIssue[]
local function parse(out, base)
  ---@type LanguageSpellIssue[]
  local issues = {}
  for line in out:gmatch("[^\r\n]+") do
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" and obj.type == "typo" and type(obj.typo) == "string" then
      local path = obj.path or ""
      if base and not is_absolute(path) then
        path = base .. "/" .. path:gsub("^%.[/\\]", "")
      end
      path = fn.fnamemodify(path, ":p")
      local buf = fn.bufnr(path)
      local col = (obj.byte_offset or 0) + 1
      issues[#issues + 1] = {
        bufnr = (buf > 0 and vim.api.nvim_buf_is_valid(buf)) and buf or nil,
        path = path,
        lnum = obj.line_num or 1,
        col = col,
        end_col = col + #obj.typo,
        word = obj.typo,
        kind = "spell",
        source = "typos",
        suggestions = type(obj.corrections) == "table" and obj.corrections or nil,
      }
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

  local base, argv
  if scope.kind == "path" and scope.path then
    if fn.isdirectory(scope.path) == 1 then
      base = scope.path
      argv = { "typos", "--format", "json" }
    else
      base = nil
      argv = { "typos", "--format", "json", scope.path }
    end
  else
    base = fn.getcwd()
    argv = { "typos", "--format", "json" }
  end

  return job.run(argv, {
    cwd = base,
    timeout_ms = 20000,
    on_done = function(_ok, out, _err)
      cb(parse(out or "", base))
    end,
  })
end

return M
