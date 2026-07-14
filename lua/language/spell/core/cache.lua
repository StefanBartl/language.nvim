---@module 'language.spell.core.cache'
---@brief Per-buffer cache of native whole-buffer scan results.
---@description
--- Caches the (relatively expensive) native `vim.spell` whole-buffer scan keyed
--- by buffer + `changedtick`, so re-opening the panel or re-scanning an
--- unchanged buffer is instant. Any edit bumps `changedtick` and invalidates
--- the entry automatically; buffers are also dropped on `BufDelete` (via
--- `language.spell.on_buf_delete`).
---
--- Only whole-buffer (`kind == "buffer"`) native results are cached — range
--- scopes (`visible`/`selection`) vary by range, and LSP grammar diagnostics
--- are re-harvested fresh each time (cheap; they change without `changedtick`).

local api = vim.api

local M = {}

---@class Language.SpellCacheEntry
---@field tick integer
---@field issues LanguageSpellIssue[]

---@type table<integer, Language.SpellCacheEntry>
local store = {}

---Return cached native issues for `bufnr` if still valid, else nil.
---@param bufnr integer
---@return LanguageSpellIssue[]|nil
function M.get(bufnr)
  local e = store[bufnr]
  if not e or not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if e.tick ~= api.nvim_buf_get_changedtick(bufnr) then
    return nil
  end
  return e.issues
end

---Store native issues for `bufnr` at its current `changedtick`.
---@param bufnr integer
---@param issues LanguageSpellIssue[]
---@return nil
function M.set(bufnr, issues)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  store[bufnr] = { tick = api.nvim_buf_get_changedtick(bufnr), issues = issues }
end

---Drop the cache entry for `bufnr`.
---@param bufnr integer
---@return nil
function M.invalidate(bufnr)
  store[bufnr] = nil
end

return M
