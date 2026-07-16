---@module 'language.translate.history'
---@brief Recent-translation history (in-memory ring, optional persistence).
---@description
--- Records successful translations so they can be recalled via a picker. Newest
--- first, capped at `translate.history.max`. When `translate.history.persist` is
--- set, the ring is loaded on first use and saved to a JSON file after each
--- record. Idea from vim-translator's query history.

local json = require("lib.nvim.fs.json")

local M = {}

---@class Language.TranslateHistoryEntry
---@field input  string[]  -- source lines
---@field output string[]  -- translated lines
---@field target string    -- target language
---@field time   integer   -- os.time()

---@type Language.TranslateHistoryEntry[]|nil  -- newest first
local ring = nil

---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---@return { enable: boolean, max: integer, persist: boolean, file: string }
local function hcfg()
  return cfg().history or { enable = false, max = 50, persist = false, file = "" }
end

---Load persisted history into the ring (once).
---@return Language.TranslateHistoryEntry[]
local function ensure_loaded()
  if ring then
    return ring
  end
  ring = {}
  local h = hcfg()
  if h.persist and h.file and vim.fn.filereadable(h.file) == 1 then
    local decoded = json.read(h.file)
    if type(decoded) == "table" then
      ring = decoded
    end
  end
  return ring
end

---Persist the ring to disk (best-effort) when enabled.
local function save()
  local h = hcfg()
  if not (h.persist and h.file and h.file ~= "") then
    return
  end
  json.write(h.file, ring)
end

---Record a successful translation (newest first, capped, deduped by input+target).
---@param entry Language.TranslateHistoryEntry
---@return nil
function M.record(entry)
  local h = hcfg()
  if not h.enable then
    return
  end
  if type(entry) ~= "table" or type(entry.output) ~= "table" or #entry.output == 0 then
    return
  end
  entry.time = entry.time or os.time()

  local r = ensure_loaded()
  -- Drop an existing identical (input,target) so it moves to the front.
  local key = table.concat(entry.input or {}, "\n") .. "\0" .. tostring(entry.target)
  for i = #r, 1, -1 do
    if (table.concat(r[i].input or {}, "\n") .. "\0" .. tostring(r[i].target)) == key then
      table.remove(r, i)
    end
  end
  table.insert(r, 1, entry)

  local max = h.max or 50
  while #r > max do
    table.remove(r)
  end
  save()
end

---Return the history entries (newest first).
---@return Language.TranslateHistoryEntry[]
function M.entries()
  return ensure_loaded()
end

---Clear the history (memory + disk).
---@return nil
function M.clear()
  ring = {}
  save()
end

---One-line label for an entry.
---@param e Language.TranslateHistoryEntry
---@return string
function M.label(e)
  local inp = table.concat(e.input or {}, " "):gsub("%s+", " ")
  local out = table.concat(e.output or {}, " "):gsub("%s+", " ")
  local function clip(s, n)
    return #s > n and (s:sub(1, n - 1) .. "…") or s
  end
  return ("[%s] %s → %s"):format(tostring(e.target), clip(inp, 40), clip(out, 40))
end

---Open a picker over the history; calls `on_choose(entry)` on selection.
---@param on_choose fun(entry: Language.TranslateHistoryEntry)
---@return nil
function M.pick(on_choose)
  local r = M.entries()
  if #r == 0 then
    require("lib.nvim.notify").create("[language.translate]").info("No translation history yet")
    return
  end
  local items = {}
  for i, e in ipairs(r) do
    items[i] = M.label(e)
  end
  require("lib.nvim.ui.kit").select({
    items = items,
    title = "Translation history",
    on_select = function(_, idx)
      local e = r[idx]
      if e then
        on_choose(e)
      end
    end,
  })
end

return M
