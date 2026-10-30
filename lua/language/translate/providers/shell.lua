---@module 'language.translate.providers.shell'
---@brief translate-shell (`trans`) provider.
---@description
--- Wraps the `trans` CLI (translate-shell) for users who want its extra
--- engines/dictionaries. Brief mode (`-b`) returns just the translation. The
--- block goes to `trans` on stdin, never into argv: on Windows `trans` is often
--- a `.cmd`/`.bat` shim that `util/job` must start through `cmd.exe /c`, whose
--- parser would interpret `" % & | < > ^` in an argument (and `util/job`
--- therefore refuses such an argument). With no text argument translate-shell
--- reads its input line by line, translates every non-empty line as a request
--- of its own and echoes empty lines in brief mode, so the output has one line
--- per input line and is split back into lines.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "shell"

---@internal
---The block travels on stdin, so no command-line limit applies any more; the
---budget (kept from the argv era: 6000 on Windows, 20 000 elsewhere) bounds the
---lines per `trans` process and, since `trans` sends every line as its own
---request, the size of one request. A line above it is cut at sentence or word
---boundaries by `translate/chunk.lua`. `trans` uses the same keyless Google
---endpoint as the `google` engine, so the blocks get the same pause between them.
---@type LanguageTranslateLimits
M.limits = { max_bytes = vim.fn.has("win32") == 1 and 6000 or 20000, pause_ms = 300 }

---@see LanguageTranslateProvider
---@param _cfg LanguageTranslateCfg
---@return boolean
function M.available(_cfg)
  return vim.fn.executable("trans") == 1
end

---@internal
---The longest a `trans` process may run, however many requests it has: the budget of one request times their number
---is only the honest limit for a block of a few lines, and a block of thousands of short ones would otherwise wait for
---hours on a process that has hung. A single request keeps its own budget even above this.
M.MAX_PROCESS_MS = 10 * 60 * 1000

---@internal
---@param per_request integer  -- `translate.timeout_ms`
---@param requests integer
---@return integer
function M._process_timeout(per_request, requests)
  return math.max(per_request, math.min(per_request * requests, M.MAX_PROCESS_MS))
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
  -- No text in argv: `trans` reads it from stdin (see the module description).
  local argv = { "trans", "-b", "-no-warn", spec }

  -- `translate.timeout_ms` is a budget per request, and `trans` sends one per
  -- non-empty line, so the process gets that budget for each of them.
  local requests = 0
  for _, line in ipairs(lines) do
    if line ~= "" then
      requests = requests + 1
    end
  end

  return job.run(argv, {
    stdin = text .. "\n",
    timeout_ms = M._process_timeout(cfg.timeout_ms or 8000, requests),
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
