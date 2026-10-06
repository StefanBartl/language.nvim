---@module 'language.translate.markdown.cache'
---@brief Translation cache of the Markdown API: memory, plus an optional disk file.
---@description
--- Key = hash(engine, model, target, source, masked unit text). The value is the
--- translated MASKED text (placeholders still in it): two units that differ
--- only in a link target or an inline-code span share one entry, and the
--- restoration of the real text happens after the lookup.
---
--- Only a validated translation is ever stored (the caller's rule: a failed
--- unit is never cached, or the next run would not retry it -- the spike saw
--- 27 requests instead of 1 for a one-paragraph change).
---
--- Memory is bounded by `max_units` (the oldest tenth goes first). The disk
--- file (`stdpath("cache")/language.nvim/translate_markdown.json`, through
--- `lib.nvim.cache.disk`) is bounded by `max_kb`; it is read lazily on the
--- first lookup, written debounced after a change and once more at exit, and
--- merged with what another Neovim wrote in the meantime. A file that does not
--- decode, or entries of the wrong shape, are ignored: the disk is untrusted
--- input and every cached value goes through the same placeholder check as a
--- fresh answer.

local M = {}

local NAMESPACE = "translate_markdown"
local FLUSH_DELAY_MS = 2000

---@type table<string, { v: string, t: integer }>
local store = {}
local count, stamp = 0, 0
local loaded, dirty, scheduled = false, false, false

local conf = { disk = false, max_units = 20000, max_kb = 2048, dir = nil }

---@internal
---@return string
local function dir()
  return conf.dir or (vim.fn.stdpath("cache") .. "/language.nvim")
end

---@internal
---@return table|nil
local function disk()
  local ok, mod = pcall(require, "lib.nvim.cache.disk")
  return ok and mod or nil
end

---Set the limits and the disk switch. Cheap; called on every run.
---@param opts { disk?: boolean, max_units?: integer, max_kb?: integer, dir?: string }
function M.configure(opts)
  opts = opts or {}
  if opts.disk ~= nil then
    conf.disk = opts.disk == true
  end
  if type(opts.max_units) == "number" and opts.max_units >= 10 then
    conf.max_units = math.floor(opts.max_units)
  end
  if type(opts.max_kb) == "number" and opts.max_kb >= 16 then
    conf.max_kb = math.floor(opts.max_kb)
  end
  if type(opts.dir) == "string" and opts.dir ~= "" and opts.dir ~= conf.dir then
    conf.dir = opts.dir
    loaded = false
  end
end

---@internal
---Drop the oldest tenth.
local function evict()
  local keys = {}
  for k in pairs(store) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return store[a].t < store[b].t
  end)
  local drop = math.max(1, math.floor(#keys / 10))
  for i = 1, drop do
    store[keys[i]] = nil
    count = count - 1
  end
end

---@internal
---Entries of a decoded disk file that have the right shape, oldest first.
---@param data any
---@return { [1]: string, [2]: string }[]
local function entries_of(data)
  local out = {}
  if type(data) == "table" and data.v == 1 and type(data.e) == "table" then
    for _, e in ipairs(data.e) do
      if type(e) == "table" and type(e[1]) == "string" and type(e[2]) == "string" then
        out[#out + 1] = e
      end
    end
  end
  return out
end

---@internal
local function ensure_loaded()
  if loaded or not conf.disk then
    return
  end
  loaded = true
  local d = disk()
  if not d then
    return
  end
  local ok, data = pcall(d.load, NAMESPACE, { dir = dir() })
  if not ok then
    return
  end
  for _, e in ipairs(entries_of(data)) do
    if not store[e[1]] then
      stamp = stamp + 1
      store[e[1]] = { v = e[2], t = stamp }
      count = count + 1
    end
  end
  while count > conf.max_units do
    evict()
  end
end

---Hash of everything a translation depends on.
---@param engine string
---@param model string|nil
---@param target string
---@param source string|nil
---@param text string  -- the masked unit text
---@return string
function M.key(engine, model, target, source, text)
  local head = table.concat({ engine, model or "", target:lower(), (source or ""):lower() }, "\0")
  return vim.fn.sha256(head .. "\0" .. text):sub(1, 32)
end

---@param key string
---@return string|nil
function M.get(key)
  ensure_loaded()
  local e = store[key]
  if not e then
    return nil
  end
  stamp = stamp + 1
  e.t = stamp
  return e.v
end

---Write the disk file now (merged with what is there, trimmed to `max_kb`).
function M.flush()
  scheduled = false
  if not (dirty and conf.disk) then
    return
  end
  local d = disk()
  if not d then
    return
  end
  dirty = false
  local ok, data = pcall(d.load, NAMESPACE, { dir = dir() })
  local merged = {}
  if ok then
    for _, e in ipairs(entries_of(data)) do
      if not store[e[1]] then
        merged[#merged + 1] = e
      end
    end
  end
  local keys = {}
  for k in pairs(store) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return store[a].t < store[b].t
  end)
  for _, k in ipairs(keys) do
    merged[#merged + 1] = { k, store[k].v }
  end
  -- Newest last; cut the oldest until the estimate fits. JSON quoting adds a
  -- little to every string, hence the per-entry slack.
  local budget, size, first = conf.max_kb * 1024, 0, 1
  for _, e in ipairs(merged) do
    size = size + #e[1] + #e[2] + 12
  end
  while size > budget and first < #merged do
    size = size - (#merged[first][1] + #merged[first][2] + 12)
    first = first + 1
  end
  local out = {}
  for i = first, #merged do
    out[#out + 1] = merged[i]
  end
  pcall(d.save, NAMESPACE, { v = 1, e = out }, { dir = dir() })
end

---@internal
local function schedule_flush()
  if scheduled or not conf.disk then
    return
  end
  scheduled = true
  vim.defer_fn(M.flush, FLUSH_DELAY_MS)
  if not M._exit_hooked then
    M._exit_hooked = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("LanguageMarkdownCache", { clear = true }),
      callback = function()
        M.flush()
      end,
    })
  end
end

---Store a validated translation.
---@param key string
---@param value string
function M.set(key, value)
  ensure_loaded()
  stamp = stamp + 1
  if not store[key] then
    count = count + 1
  end
  store[key] = { v = value, t = stamp }
  if count > conf.max_units then
    evict()
  end
  dirty = true
  schedule_flush()
end

---Forget everything, in memory and (with `opts.disk`) on disk.
---@param opts? { disk?: boolean }
function M.clear(opts)
  store, count, dirty = {}, 0, false
  loaded = true
  if opts and opts.disk then
    local d = disk()
    if d then
      pcall(d.clear, NAMESPACE, { dir = dir() })
    end
  end
end

---@return { entries: integer, disk: boolean }
function M.stats()
  return { entries = count, disk = conf.disk }
end

---Test seam: back to the state of a fresh session.
function M._reset()
  store, count, stamp = {}, 0, 0
  loaded, dirty, scheduled = false, false, false
  conf = { disk = false, max_units = 20000, max_kb = 2048, dir = nil }
  pcall(vim.api.nvim_del_augroup_by_name, "LanguageMarkdownCache")
  M._exit_hooked = false
end

return M
