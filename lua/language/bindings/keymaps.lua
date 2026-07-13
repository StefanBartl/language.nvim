---@module 'language.bindings.keymaps'
---@brief Optional global keymaps derived from the config.
---@description
--- Only the global entry points are registered here (toggle a spell session /
--- open the panel). Session-local keymaps (fix / next while a session is
--- active) are attached per-buffer by the spell module. Any keymap set to
--- `false` is skipped.
local M = {}

---Register a keymap via lib.nvim.map, falling back to vim.keymap.set.
---@param modes string|string[]
---@param lhs string
---@param rhs string|function
---@param desc string
local function map(modes, lhs, rhs, desc)
  local ok, libmap = pcall(require, "lib.nvim.map")
  if ok and type(libmap) == "function" then
    libmap(modes, lhs, rhs, {}, desc)
  else
    vim.keymap.set(modes, lhs, rhs, { desc = desc, silent = true, noremap = true })
  end
end

---@param cfg LanguageConfig
---@return nil
function M.setup(cfg)
  local km = (cfg.spell and cfg.spell.keymaps) or {}

  if type(km.panel) == "string" and km.panel ~= "" then
    map("n", km.panel, function()
      require("language.spell").run()
    end, "[language] Toggle spell session (current buffer)")
  end
end

return M
