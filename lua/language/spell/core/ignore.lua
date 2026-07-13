---@module 'language.spell.core.ignore'
---@brief Session + persistent ignore list for spell words.
---@description
--- Words the user chose to ignore are dropped from scan results. Session
--- ignores live only in memory; persistent ignores are additionally written to
--- `spell.dictionary.ignore_file` (one word per line) and loaded lazily on
--- first use.

local M = {}

---@type table<string, true>|nil
local set = nil

---@return string
local function ignore_path()
  return require("language.config").get().spell.dictionary.ignore_file
end

---Load the persistent ignore file into the in-memory set (once).
---@return table<string, true>
local function ensure_loaded()
  if set then
    return set
  end
  set = {}
  local path = ignore_path()
  if vim.fn.filereadable(path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok and type(lines) == "table" then
      for _, w in ipairs(lines) do
        w = vim.trim(w)
        if w ~= "" then
          set[w] = true
        end
      end
    end
  end
  return set
end

---Is a word currently ignored?
---@param word string
---@return boolean
function M.has(word)
  return ensure_loaded()[word] == true
end

---Add a word to the session ignore set (not persisted).
---@param word string
---@return nil
function M.add_session(word)
  if type(word) ~= "string" or word == "" then
    return
  end
  ensure_loaded()[word] = true
end

---Add a word to the ignore set and persist it to disk.
---@param word string
---@return boolean ok, string|nil err
function M.add_persistent(word)
  if type(word) ~= "string" or word == "" then
    return false, "empty word"
  end
  ensure_loaded()[word] = true

  local path = ignore_path()
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local existing = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    existing[#existing + 1] = word
    vim.fn.writefile(existing, path)
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---Remove ignored issues from a list (returns a new filtered list).
---@param issues LanguageSpellIssue[]
---@return LanguageSpellIssue[]
function M.filter(issues)
  local s = ensure_loaded()
  ---@type LanguageSpellIssue[]
  local out = {}
  for _, issue in ipairs(issues) do
    if not s[issue.word] then
      out[#out + 1] = issue
    end
  end
  return out
end

return M
