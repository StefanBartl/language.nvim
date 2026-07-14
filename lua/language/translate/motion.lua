---@module 'language.translate.motion'
---@brief Operator + visual mappings to translate a text object / selection.
---@description
--- Provides a `g@`-based operator (translate the text you move over, e.g.
--- `<lhs>ip` for a paragraph) and a visual-mode translator. The target language
--- is `translate.default_target` when set, otherwise chosen from
--- `translate.default_langs` via a small picker. Results honour
--- `translate.default_output` (replace/float/…). Idea from pantran.nvim.

local api = vim.api

local M = {}

---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---Resolve the target language, then call `cb(lang)`.
---@param cb fun(lang: string)
local function choose_target(cb)
  local c = cfg()
  if type(c.default_target) == "string" and c.default_target ~= "" then
    cb(c.default_target)
    return
  end
  require("lib.nvim.ui.kit").select({
    items = c.default_langs or { "EN", "DE" },
    title = "Translate to…",
    on_select = function(item)
      if type(item) == "string" and item ~= "" then
        cb(item)
      end
    end,
  })
end

---Translate a line range in `bufnr` via the configured output.
---@param bufnr integer
---@param s integer
---@param e integer
local function translate_range(bufnr, s, e)
  choose_target(function(lang)
    require("language.translate").run(lang, {
      output = cfg().default_output,
      scope = { kind = "selection", bufnr = bufnr, range = { s = s, e = e } },
    })
  end)
end

---operatorfunc target: translate the text spanned by the last motion.
---@param _motion_type string  "line"|"char"|"block" (unused; line-range based)
---@return nil
function M.operator(_motion_type)
  local bufnr = api.nvim_get_current_buf()
  local s = api.nvim_buf_get_mark(bufnr, "[")[1]
  local e = api.nvim_buf_get_mark(bufnr, "]")[1]
  if s > e then
    s, e = e, s
  end
  translate_range(bufnr, s, e)
end

---Expr-mapping rhs for the normal-mode operator: arms operatorfunc, returns g@.
---@return string
function M.expr()
  vim.o.operatorfunc = "v:lua.require'language.translate.motion'.operator"
  return "g@"
end

---Translate the current visual selection (line-wise range).
---@return nil
function M.visual()
  local bufnr = api.nvim_get_current_buf()
  local s = vim.fn.line("v")
  local e = vim.fn.line(".")
  if s > e then
    s, e = e, s
  end
  -- Leave visual mode so the range is stable while the picker is open.
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  translate_range(bufnr, s, e)
end

return M
