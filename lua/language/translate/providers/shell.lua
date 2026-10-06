---@module 'language.translate.providers.shell'
---@brief translate-shell (`trans`) provider.
---@description
--- Wraps the `trans` CLI (translate-shell) for users who want its extra
--- engines/dictionaries. Brief mode (`-b`) returns just the translation. The
--- whole block is sent as one argv argument (no shell interpolation) and the
--- result is split back into lines.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "shell"

---@internal
---The block is a single argv element. On Windows keep it far below the
---command-line limit (~32 700) and the 8 191 of a `cmd.exe /c` shim; elsewhere
---one argument may be 128 KiB (Linux MAX_ARG_STRLEN), so the budget is looser.
---A line above it is cut at sentence or word boundaries by `translate/chunk.lua`.
---@type LanguageTranslateLimits
M.limits = { max_bytes = vim.fn.has("win32") == 1 and 6000 or 20000 }

---@see LanguageTranslateProvider
---@param _cfg LanguageTranslateCfg
---@return boolean
function M.available(_cfg)
  return vim.fn.executable("trans") == 1
end

---@param lines string[]
---@param target string
---@param source string|nil
---@param cfg LanguageTranslateCfg
---@param cb fun(ok: boolean, result: string[]|string)
---@return Language.Job|nil
function M.translate(lines, target, source, cfg, cb)
  local text = table.concat(lines, "\n")
  if text:match("^[ \t\r\n\f\v]*$") then
    -- Nothing to translate: the lines come back as they are (same line count).
    cb(true, vim.list_slice(lines))
    return nil
  end

  local spec = ((source and source ~= "") and source or "") .. ":" .. target
  local argv = { "trans", "-b", "-no-warn", spec, text }

  return job.run(argv, {
    timeout_ms = cfg.timeout_ms or 8000,
    on_done = function(ok, out, err)
      if not ok then
        cb(false, err ~= "" and err or "trans request failed")
        return
      end
      cb(true, vim.split((out:gsub("%s+$", "")), "\n", { plain = true }))
    end,
  })
end

return M
