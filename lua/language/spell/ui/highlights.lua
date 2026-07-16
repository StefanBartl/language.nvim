---@module 'language.spell.ui.highlights'
---@brief Opt-in buffer-local highlight extmarks for spell/grammar issues.
---@description
--- `vim.diagnostic` (namespace in `spell/ui/list.lua`) already renders issues,
--- but its appearance follows the user's global `vim.diagnostic.config()` —
--- some setups mute virtual text/underline, or diagnostics are used for LSP
--- only and get filtered out of `:Trouble`. When `spell.highlights.enable` is
--- on, issues are additionally marked directly in the buffer via
--- `nvim_buf_set_extmark`, independent of the diagnostics config, using
--- dedicated highlight groups the user (or a colorscheme) can restyle:
--- `LanguageSpellHighlight` (spelling/rare/caps) and `LanguageGrammarHighlight`
--- (grammar/style).

require("language.spell.@types")

local api = vim.api

local M = {}

---@type integer
M.ns = api.nvim_create_namespace("language_spell_highlights")

---@type boolean
local hl_defined = false

---@param style "underline"|"undercurl"
---@return nil
local function define_hl(style)
  local attr = style == "undercurl" and "undercurl" or "underline"
  api.nvim_set_hl(0, "LanguageSpellHighlight", { [attr] = true, sp = "Orange", default = true })
  api.nvim_set_hl(0, "LanguageGrammarHighlight", { [attr] = true, sp = "Blue", default = true })
  hl_defined = true
end

---@param kind LanguageSpellKind
---@return string
local function hl_group(kind)
  if kind == "grammar" or kind == "style" then
    return "LanguageGrammarHighlight"
  end
  return "LanguageSpellHighlight"
end

---Publish highlight extmarks for `issues`, grouped per buffer. No-op unless
---`cfg.enable` is true. Returns the set of touched buffers (mirrors
---`list.publish`'s return shape, so callers can reuse it for `clear`).
---@param issues LanguageSpellIssue[]
---@param cfg { enable: boolean, style: "underline"|"undercurl" }|nil
---@return table<integer, true> touched_bufs
function M.publish(issues, cfg)
  if not (cfg and cfg.enable) then
    return {}
  end
  if not hl_defined then
    define_hl(cfg.style)
  end

  ---@type table<integer, true>
  local by_buf = {}
  for _, issue in ipairs(issues) do
    local b = issue.bufnr
    if b and api.nvim_buf_is_valid(b) then
      by_buf[b] = true
    end
  end
  for b in pairs(by_buf) do
    api.nvim_buf_clear_namespace(b, M.ns, 0, -1)
  end
  for _, issue in ipairs(issues) do
    local b = issue.bufnr
    if b and api.nvim_buf_is_valid(b) and issue.end_col > issue.col then
      pcall(api.nvim_buf_set_extmark, b, M.ns, issue.lnum - 1, issue.col - 1, {
        end_col = issue.end_col - 1,
        hl_group = hl_group(issue.kind),
      })
    end
  end
  return by_buf
end

---Clear highlight extmarks for the given buffers, or every buffer when `bufs`
---is nil.
---@param bufs table<integer, true>|nil
---@return nil
function M.clear(bufs)
  if bufs then
    for b in pairs(bufs) do
      if api.nvim_buf_is_valid(b) then
        api.nvim_buf_clear_namespace(b, M.ns, 0, -1)
      end
    end
    return
  end
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) then
      api.nvim_buf_clear_namespace(b, M.ns, 0, -1)
    end
  end
end

return M
