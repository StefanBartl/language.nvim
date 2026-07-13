---@module 'language.translate.output'
---@brief Delivers translated text to its destination (replace/float/notify/…).
---@description
--- Replace mutates the buffer range in place; float/notify/clipboard/insert are
--- non-mutating alternatives. Float mechanic mirrors the prior translate.nvim
--- preset: a scratch buffer in a cursor-relative window that auto-closes on
--- cursor movement.

local api = vim.api

local M = {}

---Replace a buffer line range with translated lines.
---@param bufnr integer
---@param s integer            1-based inclusive
---@param e integer            1-based inclusive
---@param lines string[]
local function out_replace(bufnr, s, e, lines)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_set_lines(bufnr, s - 1, e, false, lines)
end

---Insert translated lines just below the range.
---@param bufnr integer
---@param _s integer
---@param e integer
---@param lines string[]
local function out_insert(bufnr, _s, e, lines)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_set_lines(bufnr, e, e, false, lines)
end

---Show translated lines in a cursor-anchored floating window.
---@param lines string[]
local function out_float(lines)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))

  local win = api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.max(width, 10),
    height = math.max(height, 1),
    style = "minimal",
    border = "rounded",
    zindex = 50,
  })

  local group = api.nvim_create_augroup("language_translate_float", { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = group,
    once = true,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })
end

---Deliver `lines` via `mode`.
---@param mode LanguageTranslateOutput
---@param lines string[]
---@param ctx { bufnr: integer, s: integer, e: integer }
---@return nil
function M.apply(mode, lines, ctx)
  if mode == "replace" then
    out_replace(ctx.bufnr, ctx.s, ctx.e, lines)
  elseif mode == "insert" then
    out_insert(ctx.bufnr, ctx.s, ctx.e, lines)
  elseif mode == "float" then
    out_float(lines)
  elseif mode == "clipboard" then
    local text = table.concat(lines, "\n")
    pcall(vim.fn.setreg, "+", text)
    pcall(vim.fn.setreg, '"', text)
  elseif mode == "notify" then
    require("lib.nvim.notify").create("[language.translate]").info(table.concat(lines, "\n"))
  else
    out_replace(ctx.bufnr, ctx.s, ctx.e, lines)
  end
end

return M
