---@module 'language.spell.core.split'
---@brief Split code identifiers (CamelCase / snake_case / digits) into subwords.
---@description
--- Neovim's spell checker treats `getUserName` or `user_name` as single tokens
--- and flags them wholesale. This module breaks a flagged token into its
--- constituent subwords — each with its byte offset inside the original token —
--- so the caller can re-check only the real words and report precise spans.
--- Idea from spelunker.vim / fastspell / cspell.

local M = {}

---@class Language.Subword
---@field sub    string   -- the subword
---@field offset integer  -- 0-based byte offset within the original word

---Split a maximal alphabetic run into CamelCase/PascalCase pieces.
---Boundaries: lower→upper (`getName`), and UPPER→Upperlower (`HTTPServer`).
---@param run string
---@param base integer   0-based offset of `run` within the original word
---@param out Language.Subword[]
local function split_alpha(run, base, out)
  local start = 1
  local len = #run
  for i = 2, len do
    local prev = run:sub(i - 1, i - 1)
    local cur = run:sub(i, i)
    local nxt = run:sub(i + 1, i + 1)
    local boundary = false
    -- lower/digit → Upper  (getName → get|Name)
    if prev:match("%l") and cur:match("%u") then
      boundary = true
    -- Upper → Upper followed by lower  (HTTPServer → HTTP|Server)
    elseif prev:match("%u") and cur:match("%u") and nxt:match("%l") then
      boundary = true
    end
    if boundary then
      out[#out + 1] = { sub = run:sub(start, i - 1), offset = base + start - 1 }
      start = i
    end
  end
  out[#out + 1] = { sub = run:sub(start), offset = base + start - 1 }
end

---Split a token into subwords. Separators (`_`, `-`, digits, other non-letters)
---delimit alphabetic runs; each run is further split on CamelCase boundaries.
---@param word string
---@return Language.Subword[]
function M.split(word)
  ---@type Language.Subword[]
  local out = {}
  local i = 1
  local n = #word
  while i <= n do
    local c = word:sub(i, i)
    if c:match("%a") then
      local j = i
      while j <= n and word:sub(j, j):match("%a") do
        j = j + 1
      end
      split_alpha(word:sub(i, j - 1), i - 1, out)
      i = j
    else
      i = i + 1
    end
  end
  return out
end

---Is the token compound (worth splitting)? Cheap pre-check to skip re-work on
---plain words.
---@param word string
---@return boolean
function M.is_compound(word)
  -- contains a separator/digit, or a camelCase boundary
  if word:find("[%_%-%d]") then
    return true
  end
  return word:find("%l%u") ~= nil or word:find("%u%u%l") ~= nil
end

return M
