---@module 'language.translate.providers.deepl'
---@brief DeepL translation provider (official REST API).
---@description
--- Uses the official DeepL API. The auth key is read from `translate.deepl.
--- api_key` or the `DEEPL_API_KEY` environment variable (never a global). Free
--- keys (suffix ":fx") hit api-free.deepl.com, paid keys hit api.deepl.com.
--- The request is an argv curl call (no shell interpolation); the JSON body is
--- built with vim.json and, like the auth header, handed to curl on stdin (a
--- `-K -` config), so neither the key nor the text is ever an argv element.

require("language.translate.@types")

local job = require("language.util.job")

local M = {}

M.name = "deepl"

---@internal
---DeepL accepts at most 50 texts per request and a request body of 128 KiB;
---the cost leaves room for the JSON quoting/escaping of each text.
---@type LanguageTranslateLimits
M.limits = {
  max_bytes = 60000,
  max_lines = 50,
  cost = function(line)
    return #line + 8
  end,
}

---@internal
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
---@see LanguageTranslateProvider
---@param cfg LanguageTranslateCfg
---@return boolean
function M.available(cfg)
  return vim.fn.executable("curl") == 1 and api_key(cfg) ~= nil
end

---@internal
---@param key string
---@return string
local function host(key)
  return key:sub(-3) == ":fx" and "https://api-free.deepl.com/v2/translate"
    or "https://api.deepl.com/v2/translate"
end

---@internal
---Build a curl `-K -` config (read from stdin) carrying the Authorization
---header and the JSON request body. SEC-10: the auth key must never be an argv
---element -- the process list (`ps auxww`, `/proc/<pid>/cmdline`,
---`Get-CimInstance Win32_Process`) is readable by any co-resident process,
---stdin is not. The body goes the same way: a large body as one argv element
---would exceed the Windows command-line limit (ENAMETOOLONG) and expose the
---translated text in the process list.
---@param quote fun(value: string): string  -- lib.nvim.net.curl.config_quote
---@param key string
---@param body string
---@return string
local function request_config(quote, key, body)
  return ("header = %s\ndata = %s\n"):format(
    quote("Authorization: DeepL-Auth-Key " .. key),
    quote(body)
  )
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
  -- The config quoting is lib.nvim's (LUA-02: one copy of the escaping that
  -- carries the secret), required here so only a DeepL request loads it; an old
  -- lib.nvim without it is reported instead of crashing the call (LUA-05).
  local ok_curl, curl = pcall(require, "lib.nvim.net.curl")
  if not ok_curl or type(curl) ~= "table" or type(curl.config_quote) ~= "function" then
    cb(false, "DeepL needs a newer lib.nvim (lib.nvim.net.curl.config_quote); please update it")
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
    "Content-Type: application/json",
    "-K",
    "-",
  }

  return job.run(argv, {
    timeout_ms = cfg.timeout_ms or 8000,
    stdin = request_config(curl.config_quote, key, body),
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
