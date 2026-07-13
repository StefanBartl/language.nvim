---@module 'language.translate.providers.google'
---@brief Google Translate provider via the keyless `gtx` endpoint.
---@description
--- Uses `translate.googleapis.com/translate_a/single?client=gtx` — the
--- established keyless endpoint used by translate-shell and many CLI tools —
--- instead of the fragile private Apps-Script relay of the original
--- uga-rosa/translate.nvim. Requires only `curl`. The request is built as an
--- argv list (via language.util.job) so the payload is never shell-interpolated;
--- the text is passed through `curl --data-urlencode` for safe encoding.
---
--- Response shape: `[[["translated","source",...],[...]], ...]`. The first
--- element is a list of segments; segment[1] holds each translated chunk.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "google"

local ENDPOINT = "https://translate.googleapis.com/translate_a/single"

---curl is the only requirement.
---@param _cfg LanguageTranslateCfg
---@return boolean
function M.available(_cfg)
  return vim.fn.executable("curl") == 1
end

---Parse the gtx JSON response into a single translated string.
---@param body string
---@return string|nil text, string|nil err
local function parse(body)
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "invalid translation response"
  end
  local segments = decoded[1]
  if type(segments) ~= "table" then
    return nil, "unexpected translation response shape"
  end
  local parts = {}
  for i = 1, #segments do
    local seg = segments[i]
    if type(seg) == "table" and type(seg[1]) == "string" then
      parts[#parts + 1] = seg[1]
    end
  end
  return table.concat(parts), nil
end

---Translate lines to `target`. Joins the block into one request (preserving
---embedded newlines) and splits the result back into lines.
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

  local url = ("%s?client=gtx&sl=%s&tl=%s&dt=t"):format(
    ENDPOINT,
    (source and source ~= "") and source or "auto",
    target
  )

  local argv = {
    "curl",
    "-s",
    "--compressed",
    "-G",
    "--data-urlencode",
    "q=" .. text,
    url,
  }

  return job.run(argv, {
    timeout_ms = cfg.timeout_ms or 8000,
    on_done = function(ok, out, err)
      if not ok then
        cb(false, err ~= "" and err or "translation request failed")
        return
      end
      local translated, perr = parse(out)
      if not translated then
        cb(false, perr or "could not parse translation")
        return
      end
      cb(true, vim.split(translated, "\n", { plain = true }))
    end,
  })
end

return M
