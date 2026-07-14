---@module 'language.bindings.keymaps'
---@brief Optional global keymaps derived from the config.
---@description
--- Global entry points only: toggle the spell panel/session, and (opt-in)
--- translate motion/visual maps. Session-local keymaps (fix / next while a
--- session is active) are attached per-buffer by the spell module. Any keymap
--- set to `false` is skipped.
local M = {}

---Register a keymap via lib.nvim.map, falling back to vim.keymap.set.
---@param modes string|string[]
---@param lhs string
---@param rhs string|function
---@param desc string
---@param opts table|nil  extra keymap options (e.g. { expr = true })
local function map(modes, lhs, rhs, desc, opts)
  opts = opts or {}
  local ok, libmap = pcall(require, "lib.nvim.map")
  if ok and type(libmap) == "function" then
    libmap(modes, lhs, rhs, opts, desc)
  else
    vim.keymap.set(
      modes,
      lhs,
      rhs,
      vim.tbl_extend("force", { desc = desc, silent = true, noremap = true }, opts)
    )
  end
end

---@param cfg LanguageConfig
---@return nil
function M.setup(cfg)
  local sk = (cfg.spell and cfg.spell.keymaps) or {}
  if type(sk.panel) == "string" and sk.panel ~= "" then
    map("n", sk.panel, function()
      require("language.spell").run()
    end, "[language] Toggle spell session (current buffer)")
  end

  local tk = (cfg.translate and cfg.translate.keymaps) or {}
  -- Operator: `<lhs>{motion}` translates the moved-over text.
  if type(tk.operator) == "string" and tk.operator ~= "" then
    map("n", tk.operator, function()
      return require("language.translate.motion").expr()
    end, "[language] Translate motion", { expr = true })
  end
  -- Visual: translate the current selection.
  if type(tk.visual) == "string" and tk.visual ~= "" then
    map("x", tk.visual, function()
      require("language.translate.motion").visual()
    end, "[language] Translate selection")
  end
end

return M
