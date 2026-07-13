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
  if text == "" then
    cb(true, {})
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
