---@module 'language.translate.providers.custom'
---@brief User-defined translation engine (arbitrary CLI).
---@description
--- Lets the user plug in any command-line translator without a code change.
--- Configure `translate.custom = { cmd = fun(lines, target, source) -> string[],
--- parse = fun(stdout) -> string[] }`. `cmd` returns the argv to run; `parse`
--- turns its stdout into translated lines. Idea from niuiic/translate.nvim.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "custom"

---@internal
---The user's argv builder usually puts the block into argv, so the budget is
---the one of the `shell` engine (6000 bytes on Windows, 20000 elsewhere). A
---`cmd` that does not use argv for the text (temp file, own stdin handling)
---can raise it with `translate.custom.max_bytes`; `translate.max_chars` still
---lowers whatever applies.
---@type LanguageTranslateLimits
M.limits = {
  max_bytes = vim.fn.has("win32") == 1 and 6000 or 20000,
  override = function(cfg)
    local custom = cfg and cfg.custom
    return type(custom) == "table" and custom.max_bytes or nil
  end,
}

---@see LanguageTranslateProvider
---@param cfg LanguageTranslateCfg
---@return boolean
function M.available(cfg)
  return type(cfg.custom) == "table" and type(cfg.custom.cmd) == "function"
end

---@param lines string[]
---@param target string
---@param source string|nil
---@param cfg LanguageTranslateCfg
---@param cb fun(ok: boolean, result: string[]|string)
---@return Language.Job|nil
function M.translate(lines, target, source, cfg, cb)
  local custom = cfg.custom
  if not (type(custom) == "table" and type(custom.cmd) == "function") then
    cb(false, "translate.custom.cmd is not configured")
    return nil
  end

  local ok_cmd, argv = pcall(custom.cmd, lines, target, source)
  if not ok_cmd or type(argv) ~= "table" or #argv == 0 then
    cb(false, "translate.custom.cmd did not return an argv list")
    return nil
  end

  return job.run(argv, {
    timeout_ms = cfg.timeout_ms or 8000,
    on_done = function(ok, out, err)
      if not ok then
        cb(false, err ~= "" and err or "custom command failed")
        return
      end
      local parse = custom.parse
      if type(parse) == "function" then
        local ok_parse, result = pcall(parse, out)
        if ok_parse and type(result) == "table" then
          cb(true, result)
        else
          cb(false, "translate.custom.parse failed")
        end
      else
        cb(true, vim.split((out:gsub("%s+$", "")), "\n", { plain = true }))
      end
    end,
  })
end

return M
