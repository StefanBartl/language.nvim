---@module 'language.bindings.which_key'
---@brief Optional, guarded which-key group labels for language.nvim's keymap groups.
---@description
--- which-key is a **soft** dependency: if it is not installed this is a no-op.
--- Individual keys already carry their own `desc` (see bindings/keymaps.lua),
--- so only group labels for the shared prefixes are registered. Supports both
--- the which-key v3 (`add`) and v2 (`register`) APIs.

local M = {}

---Register language.nvim group labels with which-key, if available.
---@param cfg LanguageConfig
---@return boolean registered
function M.setup(cfg)
  local ok, wk = pcall(require, "which-key")
  if not ok or type(wk) ~= "table" then
    return false
  end

  local groups = {}
  local sk = (cfg.spell and cfg.spell.keymaps) or {}
  if type(sk.panel) == "string" and sk.panel ~= "" then
    groups[#groups + 1] = { sk.panel:sub(1, -2), label = "Spell" }
  end
  if type(sk.fix) == "string" and sk.fix ~= "" then
    groups[#groups + 1] = { sk.fix:sub(1, -2), label = "Grammar fix" }
  end

  if #groups == 0 then
    return false
  end

  if type(wk.add) == "function" then
    -- which-key v3
    local specs = {}
    for _, g in ipairs(groups) do
      specs[#specs + 1] = { g[1], group = g.label }
    end
    wk.add(specs)
    return true
  elseif type(wk.register) == "function" then
    -- which-key v2
    local specs = {}
    for _, g in ipairs(groups) do
      specs[g[1]] = { name = "+" .. g.label }
    end
    wk.register(specs)
    return true
  end

  return false
end

---Whether which-key is installed (for :checkhealth reporting).
---@return boolean
function M.available()
  local ok, wk = pcall(require, "which-key")
  return ok and type(wk) == "table"
end

return M
