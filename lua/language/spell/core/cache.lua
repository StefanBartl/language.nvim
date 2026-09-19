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
---@field sig string
---@field issues LanguageSpellIssue[]

---@type table<integer, Language.SpellCacheEntry>
local store = {}

---@internal
---A signature covering every parameter besides `changedtick` that affects a
---native buffer scan's result -- `spelllang` (via `vim.spell.check`) plus the
---config knobs `scan_lines`/`region_predicate` read (`word_split.enable`/
---`.min_length`, `regions.skip_urls`/`.skip_emails`/`.treesitter_spell`).
---Without it, a `spelllang`/config change while a buffer stays cached would
---silently keep serving issues computed for the previous configuration.
---@param bufnr integer
---@param cfg LanguageSpellCfg|nil
---@return string
local function signature(bufnr, cfg)
  cfg = cfg or {}
  local ws = cfg.word_split or {}
  local regions = cfg.regions or {}
  local ok, spelllang = pcall(function()
    return vim.bo[bufnr].spelllang
  end)
  return table.concat({
    ok and spelllang or "",
    tostring(ws.enable),
    tostring(ws.min_length),
    tostring(regions.skip_urls),
    tostring(regions.skip_emails),
    tostring(regions.treesitter_spell),
  }, "\0")
end

---Return cached native issues for `bufnr` if still valid, else nil.
---@param bufnr integer
---@param cfg LanguageSpellCfg|nil  omit only where no config-dependent
---           parameter can have changed (e.g. tests)
---@return LanguageSpellIssue[]|nil
function M.get(bufnr, cfg)
  local e = store[bufnr]
  if not e or not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if e.tick ~= api.nvim_buf_get_changedtick(bufnr) then
    return nil
  end
  if e.sig ~= signature(bufnr, cfg) then
    return nil
  end
  return e.issues
end

---Store native issues for `bufnr` at its current `changedtick` + signature.
---@param bufnr integer
---@param issues LanguageSpellIssue[]
---@param cfg LanguageSpellCfg|nil
---@return nil
function M.set(bufnr, issues, cfg)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  store[bufnr] = {
    tick = api.nvim_buf_get_changedtick(bufnr),
    sig = signature(bufnr, cfg),
    issues = issues,
  }
end

---Drop the cache entry for `bufnr`.
---@param bufnr integer
---@return nil
function M.invalidate(bufnr)
  store[bufnr] = nil
end

return M
