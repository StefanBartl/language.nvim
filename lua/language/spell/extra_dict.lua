---@module 'language.spell.extra_dict'
---@brief Loads user-supplied session wordlists (`spell.extra_wordlists`).
---@description
--- Same mechanism as `programming_dict` (`:spellgood!`, session-only, applied
--- once per list name), but for arbitrary caller-supplied vocabulary instead
--- of the bundled technical list — e.g. domain jargon that keeps getting
--- flagged when writing non-English technical prose (`:Spellcheck de` full of
--- nvim/Lua identifiers, or a company's product/support terminology). Each
--- list is independent and named only for idempotency bookkeeping; nothing
--- here needs to know what the words mean.
---
--- Gating a list to a specific machine (e.g. "only load the work-specific
--- list on my work laptop") is the caller's job: build the `extra_wordlists`
--- table conditionally in your own config before passing it to `setup()`.

local M = {}

---@type table<string, true>
local applied = {}

---Add every list in `wordlists` to the session dictionary. Idempotent per
---list name — calling again with the same names is a no-op for those,
---so callers can call this on every `setup()` without worrying about
---duplicate `:spellgood!` calls.
---@param wordlists table<string, string[]>|nil
---@return nil
function M.ensure(wordlists)
  if type(wordlists) ~= "table" then
    return
  end

  ---@type string[]
  local pending = {}
  for name, words in pairs(wordlists) do
    if not applied[name] and type(words) == "table" then
      applied[name] = true
      vim.list_extend(pending, words)
    end
  end
  if #pending == 0 then
    return
  end

  vim.schedule(function()
    for _, w in ipairs(pending) do
      if type(w) == "string" and w ~= "" then
        pcall(vim.cmd, "silent spellgood! " .. w)
      end
    end
  end)
end

return M
