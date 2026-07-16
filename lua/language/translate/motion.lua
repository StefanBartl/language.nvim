---@module 'language.translate.motion'
---@brief Operator + visual mappings to translate a text object / selection.
---@description
--- Provides a `g@`-based operator (translate the text you move over, e.g.
--- `<lhs>ip` for a paragraph) and a visual-mode translator. The target language
--- is `translate.default_target` when set, otherwise chosen from
--- `translate.default_langs` via a small picker. These are rewrite-in-place
--- operators (like `gu`/`gq`), so they always replace — independent of
--- `translate.default_output` (which only affects `:Translate`). Idea from
--- pantran.nvim.

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

---Translate a line range in `bufnr`, replacing it in place (rewrite operator).
---@param bufnr integer
---@param s integer
---@param e integer
local function translate_range(bufnr, s, e)
  choose_target(function(lang)
    require("language.translate").run(lang, {
      output = "replace",
      scope = { kind = "selection", bufnr = bufnr, range = { s = s, e = e } },
    })
  end)
end

---Translate a precise character-wise region, replacing it in place (0-based,
---end-exclusive).
---@param bufnr integer
---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
local function translate_region(bufnr, sr, sc, er, ec)
  choose_target(function(lang)
    require("language.translate").run_region(lang, {
      bufnr = bufnr,
      sr = sr,
      sc = sc,
      er = er,
      ec = ec,
      output = "replace",
    })
  end)
end

---Resolve two getpos-style positions into a bounding char-wise byte span using
---getregionpos (multibyte-safe). Returns 0-based rows/cols, end-exclusive, or
---nil when unavailable.
---@param pos1 integer[]
---@param pos2 integer[]
---@param mode_type string  "v" | "V" | "\22"
---@return integer?, integer?, integer?, integer?
local function region_bounds(pos1, pos2, mode_type)
  if type(vim.fn.getregionpos) ~= "function" then
    return nil
  end
  local ok, segs = pcall(vim.fn.getregionpos, pos1, pos2, { type = mode_type })
  if not ok or type(segs) ~= "table" or #segs == 0 then
    return nil
  end
  local s = segs[1][1] -- {bufnum, lnum, col(1-based byte), off}
  local e = segs[#segs][2]
  -- getregionpos end col is the last byte (1-based, inclusive) → 0-based
  -- exclusive is that same number.
  return s[2] - 1, s[3] - 1, e[2] - 1, e[3]
end

---operatorfunc target: translate the text spanned by the last motion.
---Char-wise motions translate the exact byte span; line/block motions use the
---line range.
---@param motion_type string  "line"|"char"|"block"
---@return nil
function M.operator(motion_type)
  local bufnr = api.nvim_get_current_buf()
  local a = api.nvim_buf_get_mark(bufnr, "[")
  local b = api.nvim_buf_get_mark(bufnr, "]")

  if motion_type == "char" then
    local p1 = { 0, a[1], a[2] + 1, 0 }
    local p2 = { 0, b[1], b[2] + 1, 0 }
    local sr, sc, er, ec = region_bounds(p1, p2, "v")
    if sr then
      translate_region(bufnr, sr, sc, er, ec)
      return
    end
  end

  local s, e = a[1], b[1]
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

---Translate the current visual selection. Char-wise (v) translates the exact
---byte span; line-wise (V) and block-wise fall back to the line range.
---@return nil
function M.visual()
  local bufnr = api.nvim_get_current_buf()
  local mode_type = vim.fn.mode()
  local p1 = vim.fn.getpos("v")
  local p2 = vim.fn.getpos(".")

  -- Leave visual mode so the range/marks are stable while the picker is open.
  api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

  if mode_type == "v" then
    local sr, sc, er, ec = region_bounds(p1, p2, "v")
    if sr then
      translate_region(bufnr, sr, sc, er, ec)
      return
    end
  end

  local s, e = p1[2], p2[2]
  if s > e then
    s, e = e, s
  end
  translate_range(bufnr, s, e)
end

return M
