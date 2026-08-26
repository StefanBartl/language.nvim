---@module 'language.bindings.keymaps'
---@brief Optional global keymaps derived from the config.
---@description
--- Global entry points only: toggle the spell panel/session, and (opt-in)
--- translate motion/visual maps. Session-local keymaps (fix / next while a
--- session is active) are attached per-buffer by the spell module. Any keymap
--- set to `false` is skipped.
local M = {}

---@internal
---Register a keymap via lib.nvim.bindings.keymap, falling back to vim.keymap.set.
---@param modes string|string[]
---@param lhs string
---@param rhs string|function
---@param desc string
---@param opts table|nil  extra keymap options (e.g. { expr = true })
---@return nil
local function map(modes, lhs, rhs, desc, opts)
  opts = opts or {}
  local ok, libmap = pcall(require, "lib.nvim.bindings.keymap")
  if ok and vim.is_callable(libmap) then
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

  -- Per-language operator/visual keys. With `default_target` set, the
  -- operator always used it and never asked; without one it always asked.
  -- Neither is "translate this bit into Spanish, just now".
  --
  -- A count could not carry the language here: on an operator the count
  -- belongs to the motion (`3<leader>tw` is three words), which is the whole
  -- point of having an operator. So it is a key per language, which is also
  -- what the audit suggested. Unset by default.
  for lang, lhs in pairs(tk.to or {}) do
    if type(lhs) == "string" and lhs ~= "" and type(lang) == "string" then
      map("n", lhs, function()
        require("language.translate.motion").force_target(lang)
        return require("language.translate.motion").expr()
      end, ("[language] Translate motion to %s"):format(lang), { expr = true })

      map("x", lhs, function()
        require("language.translate.motion").force_target(lang)
        require("language.translate.motion").visual()
      end, ("[language] Translate selection to %s"):format(lang))
    end
  end

  -- Thesaurus: replace the word under the cursor with a synonym.
  local th = (cfg.thesaurus and cfg.thesaurus.keymap) or false
  if type(th) == "string" and th ~= "" then
    map("n", th, function()
      -- Raw count: 0 means "no count" and has to stay distinguishable from
      -- 1, since no count opens the menu while `1` takes the first synonym
      -- outright.
      local n = vim.v.count
      require("language.thesaurus").replace_under_cursor(n > 0 and n or nil)
    end, "[language] Synonyms for word under cursor")
  end
end

return M
