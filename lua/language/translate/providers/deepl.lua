---@module 'language.translate.providers.deepl'
---@brief DeepL translation provider (official REST API).
---@description
--- Uses the official DeepL API. The auth key is read from `translate.deepl.
--- api_key` or the `DEEPL_API_KEY` environment variable (never a global). Free
--- keys (suffix ":fx") hit api-free.deepl.com, paid keys hit api.deepl.com.
--- The request is an argv curl call (no shell interpolation); the JSON body is
--- built with vim.json and sent as a single `-d` argument.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "deepl"

---Resolve the API key from config or environment.
---@param cfg LanguageTranslateCfg
---@return string|nil
local function api_key(cfg)
  local key = cfg.deepl and cfg.deepl.api_key
  if type(key) == "string" and key ~= "" then
    return key
  end
  local env = vim.env.DEEPL_API_KEY
  if type(env) == "string" and env ~= "" then
    return env
  end
  return nil
end

---Available when curl exists and a key is configured.
---@param cfg LanguageTranslateCfg
---@return boolean
function M.available(cfg)
  return vim.fn.executable("curl") == 1 and api_key(cfg) ~= nil
end

---@param key string
---@return string
local function host(key)
  return key:sub(-3) == ":fx" and "https://api-free.deepl.com/v2/translate"
    or "https://api.deepl.com/v2/translate"
end

---Translate lines. DeepL returns one translation per input element, so the
---result stays aligned with the input lines.
---@param lines string[]
---@param target string
---@param source string|nil
---@param cfg LanguageTranslateCfg
---@param cb fun(ok: boolean, result: string[]|string)
---@return Language.Job|nil
function M.translate(lines, target, source, cfg, cb)
  local key = api_key(cfg)
  if not key then
    cb(false, "no DeepL API key (set translate.deepl.api_key or $DEEPL_API_KEY)")
    return nil
  end

  local body = vim.json.encode({
    text = lines,
    target_lang = target,
    source_lang = (source and source ~= "") and source or nil,
  })

  local argv = {
    "curl",
    "-s",
    "-X",
    "POST",
    host(key),
    "-H",
    "Authorization: DeepL-Auth-Key " .. key,
    "-H",
    "Content-Type: application/json",
    "-d",
    body,
  }

  return job.run(argv, {
    timeout_ms = cfg.timeout_ms or 8000,
    on_done = function(ok, out, err)
      if not ok then
        cb(false, err ~= "" and err or "DeepL request failed")
        return
      end
      local decoded_ok, decoded = pcall(vim.json.decode, out)
      if not decoded_ok or type(decoded) ~= "table" then
        cb(false, "invalid DeepL response")
        return
      end
      if decoded.message then
        cb(false, "DeepL: " .. tostring(decoded.message))
        return
      end
      local translations = decoded.translations
      if type(translations) ~= "table" then
        cb(false, "unexpected DeepL response shape")
        return
      end
      local result = {}
      for i = 1, #translations do
        result[i] = translations[i].text or ""
      end
      cb(true, result)
    end,
  })
end

return M
