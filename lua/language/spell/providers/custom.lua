---@module 'language.spell.providers.custom'
---@brief User-defined spellchecker CLI, for cwd/path scans (async).
---@description
--- Escape hatch for a checker language.nvim doesn't ship an adapter for
--- (anything besides native/typos/cspell/codespell). Configure
--- `spell.providers.custom = { cmd = fun(scope, cfg) -> argv, parse = fun(out,
--- base) -> partial-issue[] }`, then add `"custom"` to `spell.providers.cwd`
--- (or `.order`). `cmd` builds the argv to run over `scope`; `parse` turns its
--- stdout into a list of `{ path, lnum, col, end_col?, word, kind?, message?,
--- suggestions? }` — `bufnr`/`source` are filled in automatically. Mirrors
--- `translate.custom`'s pattern (niuiic/translate.nvim-style), applied to spell.

require("language.@types")
require("language.spell.@types")

local job = require("language.util.job")
local putil = require("language.spell.providers.util")

local M = {}

M.name = "custom"
M.supports = { buffer = false, cwd = true, grammar = false }

---@param cfg LanguageSpellCfg
---@return boolean
function M.available(cfg)
  local custom = cfg and cfg.providers and cfg.providers.custom
  return type(custom) == "table"
    and type(custom.cmd) == "function"
    and type(custom.parse) == "function"
end

---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job|nil
function M.scan_async(scope, cfg, cb)
  local custom = cfg and cfg.providers and cfg.providers.custom
  if
    not (
      type(custom) == "table"
      and type(custom.cmd) == "function"
      and type(custom.parse) == "function"
    )
  then
    cb({})
    return nil
  end

  local ok_cmd, argv = pcall(custom.cmd, scope, cfg)
  if not ok_cmd or type(argv) ~= "table" or #argv == 0 then
    cb({})
    return nil
  end

  local base = (scope.kind == "path" and scope.path and vim.fn.isdirectory(scope.path) == 1)
      and scope.path
    or vim.fn.getcwd()

  return job.run(argv, {
    cwd = base,
    timeout_ms = 20000,
    on_done = function(_ok, out, _err)
      local ok_parse, parsed = pcall(custom.parse, out or "", base)
      if not ok_parse or type(parsed) ~= "table" then
        cb({})
        return
      end

      ---@type LanguageSpellIssue[]
      local issues = {}
      for _, item in ipairs(parsed) do
        if
          type(item) == "table"
          and type(item.word) == "string"
          and type(item.path) == "string"
        then
          local path = putil.resolve_path(item.path, base)
          local col = item.col or 1
          issues[#issues + 1] = {
            bufnr = putil.bufnr_for(path),
            path = path,
            lnum = item.lnum or 1,
            col = col,
            end_col = item.end_col or (col + #item.word),
            word = item.word,
            kind = item.kind or "spell",
            source = "custom",
            message = item.message,
            suggestions = item.suggestions,
          }
        end
      end
      cb(issues)
    end,
  })
end

return M
