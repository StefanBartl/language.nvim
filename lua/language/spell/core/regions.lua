---@module 'language.spell.core.regions'
---@brief Treesitter @spell / @nospell region predicate.
---@description
--- Collects the byte ranges captured as `@spell` (and `@nospell`) by the active
--- language's highlights query, so scanning can be restricted to spellable
--- regions — comments/strings/prose — and skip code identifiers entirely.
---
--- Fail-open by design: if there is no parser, no highlights query, or the
--- query defines no `@spell` capture at all, `build` returns nil and the caller
--- checks everything (never silently drops valid words).

local M = {}

---@class Language.SpellRegions
---@field spell   integer[][]   -- { {sr, sc, er, ec}, ... } 0-based, end-exclusive
---@field nospell integer[][]

---Build the @spell/@nospell ranges for `bufnr`. Returns nil to mean "no region
---info — treat all text as spellable".
---@param bufnr integer
---@return Language.SpellRegions|nil
function M.build(bufnr)
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if not ok_ft or ft == "" then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then
    return nil
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return nil
  end

  -- Only bother if the query actually defines @spell.
  local has_spell = false
  for _, name in ipairs(query.captures) do
    if name == "spell" then
      has_spell = true
      break
    end
  end
  if not has_spell then
    return nil
  end

  ---@type Language.SpellRegions
  local regions = { spell = {}, nospell = {} }
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or type(trees) ~= "table" then
    return nil
  end

  for _, tree in ipairs(trees) do
    for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
      local name = query.captures[id]
      if name == "spell" or name == "nospell" then
        local sr, sc, er, ec = node:range()
        local bucket = name == "spell" and regions.spell or regions.nospell
        bucket[#bucket + 1] = { sr, sc, er, ec }
      end
    end
  end

  if #regions.spell == 0 then
    return nil
  end
  return regions
end

---Is position (row, col) — 0-based — inside any of `ranges`?
---@param ranges integer[][]
---@param row integer
---@param col integer
---@return boolean
local function within(ranges, row, col)
  for _, r in ipairs(ranges) do
    local sr, sc, er, ec = r[1], r[2], r[3], r[4]
    local after_start = row > sr or (row == sr and col >= sc)
    local before_end = row < er or (row == er and col < ec)
    if after_start and before_end then
      return true
    end
  end
  return false
end

---Predicate: is a 1-based (lnum, col) position spellable under `regions`?
---@param regions Language.SpellRegions
---@param lnum integer   1-based
---@param col integer    1-based byte column
---@return boolean
function M.is_spellable(regions, lnum, col)
  local row, c = lnum - 1, col - 1
  if within(regions.nospell, row, c) then
    return false
  end
  return within(regions.spell, row, c)
end

return M
