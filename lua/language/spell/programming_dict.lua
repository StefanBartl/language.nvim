---@module 'language.spell.programming_dict'
---@brief Loads the curated programming vocabulary into the session word list.
---@description
--- When `spell.programming_dict = true`, the bundled wordlist is added via
--- `:spellgood!` (session-only, does not touch the user's spellfile) so
--- technical terms stop being flagged. Applied once, scheduled off the setup
--- hot path.

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

  vim.schedule(function()
    for _, w in ipairs(words) do
      -- Table form passes `w` as a real argv element, not a string spliced
      -- into a command line -- see spell/extra_dict.lua / spell/core/
      -- actions.lua's `add_to_dict` for the same fix and its rationale.
      pcall(function()
        vim.cmd({ cmd = "spellgood", bang = true, args = { w }, mods = { silent = true } })
      end)
    end
  end)
end

return M
