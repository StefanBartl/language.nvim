---@module 'language.spell.programming_dict'
---@brief Loads the curated programming vocabulary into the session word list.
---@description
--- When `spell.programming_dict = true`, the bundled wordlist is added to the
--- session word list (like `zG`: session-only, does not touch the user's
--- spellfile) so technical terms stop being flagged. Applied once, off the
--- setup hot path, and compiled in one go -- see `spell/session_words.lua` for
--- why that is not a `:spellgood!` per word.

local M = {}

---@type boolean
local applied = false

---Add the programming wordlist to the session dictionary (idempotent).
---@return nil
function M.ensure()
  if applied then
    return
  end
  applied = true

  local ok, words = pcall(require, "language.spell.data.programming")
  if not ok or type(words) ~= "table" then
    return
  end

  require("language.spell.session_words").add(words)
end

return M
