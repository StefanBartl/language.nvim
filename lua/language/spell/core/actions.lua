---@module 'language.spell.core.actions'
---@brief Buffer-mutating operations on spell issues (pure, guarded, ok/err).
---@description
--- All actions validate the target buffer and return `ok, err` — no silent
--- failures, no notifications (that is the UI layer's job). Replacements use
--- byte columns from the issue; callers re-scan afterwards so shifted columns
--- of later issues on the same line never go stale.

local api = vim.api

local M = {}

---@param bufnr integer|nil
---@return boolean
local function editable(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr)
end

---Replace the exact word occurrence described by `issue` with `word`.
---@param issue LanguageSpellIssue
---@param word string
---@return boolean ok, string|nil err
function M.replace_at(issue, word)
  if not editable(issue.bufnr) then
    return false, "issue is not in an editable buffer"
  end
  if type(word) ~= "string" or word == "" then
    return false, "invalid replacement"
  end
  local lnum = issue.lnum - 1
  local ok, err = pcall(
    api.nvim_buf_set_text,
    issue.bufnr,
    lnum,
    issue.col - 1,
    lnum,
    issue.end_col - 1,
    { word }
  )
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

---Replace every whole-word occurrence of `issue.word` with `word` in `bufnr`.
---@param bufnr integer
---@param from string
---@param word string
---@return boolean ok, integer|string count_or_err
function M.replace_all_in_buffer(bufnr, from, word)
  if not editable(bufnr) then
    return false, "not an editable buffer"
  end
  if type(from) ~= "string" or from == "" or type(word) ~= "string" then
    return false, "invalid arguments"
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pat = "%f[%w]" .. vim.pesc(from) .. "%f[%W]"
  local count = 0
  for i = 1, #lines do
    local new, n = lines[i]:gsub(pat, (word:gsub("%%", "%%%%")))
    if n > 0 then
      lines[i] = new
      count = count + n
    end
  end
  if count > 0 then
    local ok, err = pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    if not ok then
      return false, tostring(err)
    end
  end
  return true, count
end

---Add a word to the dictionary. With `use_spellfile` (default) this persists to
---the native spellfile like `zg`; otherwise it stays session-only like `zG`.
---@param word string
---@return boolean ok, string|nil err
function M.add_to_dict(word)
  if type(word) ~= "string" or word == "" then
    return false, "empty word"
  end
  local use_spellfile = require("language.config").get().spell.dictionary.use_spellfile
  -- `:spellgood`  writes to the spellfile (persistent, like zg)
  -- `:spellgood!` adds to the internal word list only (session, like zG)
  local cmd = use_spellfile and "silent spellgood " or "silent spellgood! "
  local ok, err = pcall(vim.cmd, cmd .. word)
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

return M
