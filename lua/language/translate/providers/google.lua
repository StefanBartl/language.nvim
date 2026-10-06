---@module 'language.translate.providers.google'
---@brief Google Translate provider via the keyless `gtx` endpoint.
---@description
--- Uses `translate.googleapis.com/translate_a/single?client=gtx` — the
--- established keyless endpoint used by translate-shell and many CLI tools —
--- instead of the fragile private Apps-Script relay of the original
--- uga-rosa/translate.nvim. Requires only `curl`. The request is built as an
--- argv list (via language.util.job) so the payload is never shell-interpolated.
--- The text is a POST body handed to curl on stdin (`--data-urlencode q@-`), so
--- it is neither part of the URL (no URL-length limit, no percent-encoding
--- budget) nor of the command line (no Windows command-line limit).
---
--- Response shape: `[[["translated","source",...],[...]], ...]`. The first
--- element is a list of segments; segment[1] holds each translated chunk.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "google"

---@internal
---A block is a POST body, so a line costs its raw bytes (+1 for the separator,
---the default cost). 15 000 is conservative: the endpoint answered complete
---translations for bodies of 57 000 bytes in a measurement (multi-line ASCII,
---Cyrillic, one 15 000-byte Japanese line). A line above it is cut at sentence
---or word boundaries by `translate/chunk.lua`.
---@type LanguageTranslateLimits
M.limits = { max_bytes = 15000 }

local ENDPOINT = "https://translate.googleapis.com/translate_a/single"

---curl is the only requirement.
---@see LanguageTranslateProvider
---@param _cfg LanguageTranslateCfg
---@return boolean
function M.available(_cfg)
  return vim.fn.executable("curl") == 1
end

---@internal
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
  if text:match("^[ \t\r\n\f\v]*$") then
    -- Nothing to translate (the endpoint would answer with nothing, too): the
    -- lines come back as they are, so the line count survives.
    cb(true, vim.list_slice(lines))
    return nil
  end

  local url = ("%s?client=gtx&sl=%s&tl=%s&dt=t"):format(
    ENDPOINT,
    (source and source ~= "") and source or "auto",
    target
  )

  -- `q@-`: curl reads the value from stdin and url-encodes it (newlines kept).
  local argv = {
    "curl",
    "-s",
    "--compressed",
    "--data-urlencode",
    "q@-",
    url,
  }

  return job.run(argv, {
    timeout_ms = cfg.timeout_ms or 8000,
    stdin = text,
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
