---@module 'language.translate.providers.ai'
---@brief Translation through ai.nvim (Claude, Ollama, OpenAI, Gemini, ...).
---@description
--- A soft companion: ai.nvim is never required at load time, only when a
--- request is made (`pcall(require, "ai")`). The text goes out through the
--- bulk profile of `ai.ask` (`req.bulk`), which enforces the size and budget
--- caps, the concurrency and the strict policy for document text; this module
--- adds the translation task on top and never decides about the policy itself:
---   * request: a system prompt (target, optional source, optional glossary and
---     style) and the lines as a JSON array; the answer must be a JSON array of
---     the same number of strings, every `{n}` placeholder of an element kept.
---   * strict parse: a Markdown fence around the array is tolerated, nothing
---     else. A deviation is asked again once (with the reason); then the call
---     fails and the caller decides (the Markdown API keeps the original unit).
---   * a policy refusal or a bulk limit is an error with a clear message, never
---     a retry and never another engine; the registry does not move on from a
---     configured `ai` engine either (`blocked`).
---   * the bulk label is shared by the calls of one run (a document is many
---     calls), so `concurrency` and `max_total_chars` hold for the document.
---   * `cache_id` names provider, model, prompt version and glossary/style for
---     the unit cache of `translate_markdown`, so a model switch never serves
---     old translations.

require("language.translate.@types")

local M = {}

M.name = "ai"

-- Bump when SYSTEM changes in a way that changes translations: it is part of
-- the cache identity.
local PROMPT_VERSION = 1

---@type { provider: string|nil, model: string|nil, glossary: table|nil, style: string|nil, max_chars: integer, concurrency: integer, max_total_chars: integer|nil }
local FALLBACK = { max_chars = 6000, concurrency = 2, max_total_chars = 500000 }

-- Room kept in a request for the target/source names, the retry note and the
-- JSON brackets, on top of the system prompt of the configured glossary.
local RESERVE = 400
-- A larger array makes the model lose count; the chunk wrapper cuts at this.
local MAX_LINES = 60
-- A call within this many ms of the previous one still belongs to its run.
local RUN_GRACE_NS = 5 * 1e9

---Positive integer from config, else `default`.
---@param v any
---@param default integer
---@return integer
local function pos_int(v, default)
  if type(v) == "number" and v >= 1 then
    return math.floor(v)
  end
  return default
end

---Normalised `translate.ai` (a malformed value degrades to the default).
---@param cfg table|nil
---@return table
local function settings(cfg)
  local a = type(cfg) == "table" and type(cfg.ai) == "table" and cfg.ai or {}
  local total = a.max_total_chars
  if total == nil then
    total = FALLBACK.max_total_chars
  elseif total == false or total == 0 then
    total = nil
  else
    total = pos_int(total, FALLBACK.max_total_chars)
  end
  local glossary = a.glossary
  if type(glossary) ~= "table" or next(glossary) == nil then
    glossary = nil
  end
  return {
    provider = (type(a.provider) == "string" and a.provider ~= "") and a.provider or nil,
    model = (type(a.model) == "string" and a.model ~= "") and a.model or nil,
    glossary = glossary,
    style = (type(a.style) == "string" and a.style ~= "") and a.style or nil,
    max_chars = pos_int(a.max_chars, FALLBACK.max_chars),
    concurrency = math.min(pos_int(a.concurrency, FALLBACK.concurrency), 16),
    max_total_chars = total,
  }
end

---Glossary lines, sorted: `{ "term" }` or `{ "term" = "translation" }`.
---@param glossary table|nil
---@return string[]
local function glossary_lines(glossary)
  local out = {}
  if not glossary then
    return out
  end
  for k, v in pairs(glossary) do
    if type(k) == "number" and type(v) == "string" then
      out[#out + 1] = ("%s -> %s (unchanged)"):format(v, v)
    elseif type(k) == "string" and type(v) == "string" then
      out[#out + 1] = ("%s -> %s"):format(k, v)
    end
  end
  table.sort(out)
  return out
end

---@param target string
---@param source string|nil
---@param a table
---@param note string|nil  -- why the previous answer was refused (retry)
---@return string
local function build_system(target, source, a, note)
  local parts = {
    ("Translate every element of the JSON array you receive to %s%s."):format(
      target,
      (source and source ~= "") and (" (from " .. source .. ")") or ""
    ),
    "Keep code, identifiers, URLs, `{n}` placeholders (such as {1} or {12}) and Markdown "
      .. "syntax unchanged, byte for byte.",
    "Return exactly the same number of elements, in the same order, one translation per "
      .. "element, and nothing else: a JSON array of strings, no explanation.",
  }
  if a.style then
    parts[#parts + 1] = "Style: " .. a.style
  end
  local g = glossary_lines(a.glossary)
  if #g > 0 then
    parts[#parts + 1] = "Glossary (use these translations, one per line):\n"
      .. table.concat(g, "\n")
  end
  if note then
    parts[#parts + 1] = "Your previous answer was refused: " .. note .. " Answer again."
  end
  return table.concat(parts, "\n")
end

---Budget per block for the chunk wrapper: the request cap minus what the
---system prompt takes.
---@param cfg table|nil
---@return integer|nil
local function block_budget(cfg)
  local a = settings(cfg)
  local room = a.max_chars - #build_system("", nil, a) - RESERVE
  if room < 200 then
    return nil
  end
  return room
end

---Block budget (see `language.translate.chunk`): lines are counted as they
---appear in the JSON array.
---@type LanguageTranslateLimits
M.limits = {
  max_bytes = FALLBACK.max_chars - 1200,
  max_lines = MAX_LINES,
  cost = function(line)
    local ok, enc = pcall(vim.json.encode, line)
    return ok and (#enc + 1) or (#line * 2 + 4)
  end,
  override = block_budget,
}

---Load ai.nvim, or nil.
---@return table|nil
local function load_ai()
  local ok, ai = pcall(require, "ai")
  if ok and type(ai) == "table" and type(ai.ask) == "function" then
    return ai
  end
  return nil
end

---Why `translate.ai` cannot be used, or nil when it can: ai.nvim missing, or
---the explicitly named provider outside the machine's allow-list (for a bulk
---request, `bulk_granted` counts). With provider `auto` the list itself is
---enough: ai.nvim walks only listed providers.
---@param cfg table|nil
---@return string|nil
function M.blocked(cfg)
  local ai = load_ai()
  if not ai then
    return "the ai engine needs ai.nvim, which is not installed or fails to load"
  end
  local a = settings(cfg)
  local ok_c, aicfg = pcall(function()
    return type(ai.config) == "function" and ai.config() or {}
  end)
  local id = a.provider or (ok_c and type(aicfg) == "table" and aicfg.provider) or "auto"
  if type(ai.policy) ~= "function" then
    return nil
  end
  local ok_p, pol = pcall(ai.policy)
  if not ok_p or type(pol) ~= "table" then
    return nil
  end
  local allowed = pol.allowed
  if type(allowed) ~= "table" or id == "auto" then
    if type(allowed) == "table" and #allowed == 0 then
      return "ai.nvim's policy lists no provider"
    end
    return nil
  end
  if vim.tbl_contains(allowed, id) or vim.tbl_contains(pol.bulk_granted or {}, id) then
    return nil
  end
  return (
    "provider '%s' is not on ai.nvim's allow-list (%s); document text is not sent. "
    .. "Confirm it with require('ai.policy').grant_bulk('%s') or choose a listed provider "
    .. "(translate.ai.provider)"
  ):format(id, table.concat(allowed, ", "), id)
end

---Available when ai.nvim loads and the policy admits a provider.
---@see LanguageTranslateProvider
---@param cfg LanguageTranslateCfg
---@return boolean
function M.available(cfg)
  return M.blocked(cfg) == nil
end

-- Resolved identities seen in answers (`res.bulk`), per request signature.
---@type table<string, string>
local seen = {}

---@param a table
---@return string
local function signature(a)
  return (a.provider or "") .. "|" .. (a.model or "")
end

---Cache identity of an answer: provider/model (what the last answer said, else
---what the config names), the prompt version and a hash of glossary and style.
---@param cfg table|nil
---@return string
function M.cache_id(cfg)
  local a = settings(cfg)
  local who
  do
    local provider, model = a.provider, a.model
    local ai = load_ai()
    if ai then
      local ok, aicfg = pcall(function()
        return type(ai.config) == "function" and ai.config() or {}
      end)
      if ok and type(aicfg) == "table" then
        provider = provider or aicfg.provider
        model = model
          or (type(aicfg.model) == "table" and provider and aicfg.model[provider])
          or nil
      end
    end
    -- Only a model that nothing names (the provider's own default, or the
    -- choice of provider "auto") is taken from what an answer said.
    who = model and ((provider or "auto") .. "/" .. model)
      or seen[signature(a)]
      or ((provider or "auto") .. "/default")
  end
  local extra =
    vim.fn.sha256(table.concat(glossary_lines(a.glossary), "\n") .. "\0" .. (a.style or ""))
  return ("ai:%s:p%d:%s"):format(who, PROMPT_VERSION, extra:sub(1, 12))
end

-- One bulk label per run, so concurrency and `max_total_chars` hold for a whole
-- document although it arrives as many calls.
local run = { n = 0, label = nil, active = 0, last_end = 0 }

---@return string
local function enter_run()
  local now = vim.uv.hrtime()
  if run.active == 0 and (not run.label or now - run.last_end > RUN_GRACE_NS) then
    if run.label then
      local ok, bulk = pcall(require, "ai.bulk")
      if ok and type(bulk.reset) == "function" then
        pcall(bulk.reset, run.label)
      end
    end
    run.n = run.n + 1
    run.label = ("language.nvim:translate:%d:%d"):format(vim.uv.os_getpid(), run.n)
  end
  run.active = run.active + 1
  return run.label
end

local function leave_run()
  run.active = math.max(0, run.active - 1)
  run.last_end = vim.uv.hrtime()
end

---@internal
---Placeholder tokens `{n}` of a text, as a multiset.
---@param s string
---@return table<string, integer>
local function placeholders(s)
  local t = {}
  for tok in s:gmatch("{%d+}") do
    t[tok] = (t[tok] or 0) + 1
  end
  return t
end

---Strip one Markdown fence around the whole answer (and nothing else).
---@param text string
---@return string
local function unfence(text)
  local s = vim.trim(text)
  local body = s:match("^```[%w_-]*[ \t]*\r?\n(.-)\r?\n?```$")
  if body then
    return vim.trim(body)
  end
  return s
end

---Strictly parse the model's answer for `lines`.
---@param text any
---@param lines string[]
---@return string[]|nil result, string|nil reason
function M.parse(text, lines)
  if type(text) ~= "string" then
    return nil, "the answer is not text."
  end
  local ok, decoded = pcall(vim.json.decode, unfence(text))
  if not ok then
    return nil, "the answer is not valid JSON; return only a JSON array of strings."
  end
  if type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil, "the answer is not a JSON array."
  end
  if #decoded ~= #lines then
    return nil, ("the answer has %d elements, expected exactly %d."):format(#decoded, #lines)
  end
  for i, v in ipairs(decoded) do
    if type(v) ~= "string" then
      return nil, ("element %d is not a string."):format(i)
    end
    local want, got = placeholders(lines[i]), placeholders(v)
    for tok, n in pairs(want) do
      if got[tok] ~= n then
        return nil, ("element %d does not keep the placeholder %s unchanged."):format(i, tok)
      end
    end
    for tok in pairs(got) do
      if not want[tok] then
        return nil, ("element %d has the placeholder %s that the input has not."):format(i, tok)
      end
    end
  end
  return decoded, nil
end

---A readable message for an ai.nvim error value.
---@param err any
---@return string
local function describe(err)
  if type(err) ~= "table" then
    return "ai: " .. tostring(err)
  end
  local kind = err.kind or (type(err.type) == "string" and err.type) or nil
  local msg = err.message or err.msg or "request failed"
  local text = kind and ("ai (%s): %s"):format(kind, msg) or ("ai: " .. tostring(msg))
  if kind == "bulk_limit" then
    text = text .. " -- see translate.ai.max_chars / max_total_chars"
  end
  return text
end

---Translate lines. One request per call, asked again once when the answer
---deviates; the chunk wrapper keeps every call inside the bulk budget.
---@param lines string[]
---@param target string
---@param source string|nil
---@param cfg LanguageTranslateCfg
---@param cb LanguageTranslateResultCb
---@return Language.Job|nil
function M.translate(lines, target, source, cfg, cb)
  local blocked = M.blocked(cfg)
  if blocked then
    cb(false, "ai: " .. blocked)
    return nil
  end
  local ai = load_ai() --[[@as table]]
  local a = settings(cfg)
  local sig = signature(a)
  local label = enter_run()

  local cancelled, finished = false, false
  local handle ---@type table|nil

  ---@param ok boolean
  ---@param result string[]|string
  local function finish(ok, result)
    if finished then
      return
    end
    finished = true
    leave_run()
    if not cancelled then
      cb(ok, result)
    end
  end

  local json_ok, input = pcall(vim.json.encode, lines)
  if not json_ok then
    finish(false, "ai: the text cannot be encoded as JSON")
    return { cancel = function() end }
  end

  local ask
  ---@param attempt integer
  ---@param note string|nil
  ask = function(attempt, note)
    local req = {
      prompt = input,
      system = build_system(target, source, a, note),
      provider = a.provider,
      model = a.model,
      bulk = {
        label = label,
        max_chars = a.max_chars,
        concurrency = a.concurrency,
        max_total_chars = a.max_total_chars,
      },
    }
    local started, h = pcall(ai.ask, req, function(ok, res)
      if cancelled or finished then
        return
      end
      if not ok then
        finish(false, describe(res))
        return
      end
      if type(res) == "table" and type(res.bulk) == "table" and res.bulk.provider then
        seen[sig] = ("%s/%s"):format(res.bulk.provider, res.bulk.model or "default")
      end
      local parsed, why = M.parse(type(res) == "table" and res.text or nil, lines)
      if parsed then
        finish(true, parsed)
      elseif attempt < 2 then
        ask(attempt + 1, why)
      else
        finish(false, "ai: unusable answer after a retry: " .. tostring(why))
      end
    end)
    if not started then
      finish(false, "ai: " .. tostring(h))
      return
    end
    handle = h
  end
  ask(1, nil)

  return {
    cancel = function()
      if cancelled or finished then
        return
      end
      cancelled = true
      leave_run()
      if handle and type(handle.kill) == "function" then
        pcall(handle.kill, handle)
      end
    end,
  }
end

return M
