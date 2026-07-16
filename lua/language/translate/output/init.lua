---@module 'language.translate.output'
---@brief Delivers translated text to its destination (popup/replace/buffer/…).
---@description
--- `popup` (the default) is read-only and non-mutating, shown via
--- `lib.nvim.ui.kit` (hard dependency, matches the rest of the plugin's UI).
--- `replace`/`insert` mutate the source buffer; `buffer`/`vsplit`/`split`/`tab`
--- open the translation in a new, normal (writable, named-on-save) buffer;
--- `clipboard`/`notify` are non-mutating side channels.

require("language.config.@types")

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

---Show translated lines in a read-only, cursor-anchored kit popup. Focusable
---(scrollable/yankable) and closes with q/<Esc> (kit's `nice_quit`).
---@param lines string[]
---@param title string|nil
local function out_popup(lines, title)
  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))

  require("lib.nvim.ui.kit").surface.open({
    lines = lines,
    title = title and (" " .. title .. " ") or nil,
    relative = "cursor",
    width = math.max(width, 10),
    height = math.max(height, 1),
    enter = true,
    nice_quit = true,
    modifiable = false,
    filetype = "language-translate-popup",
  })
end

---Open `lines` in a fresh, normal (writable) unnamed buffer, optionally inside
---a new split/tab first. Inherits the source buffer's filetype when given.
---@param lines string[]
---@param layout "buffer"|"vsplit"|"split"|"tab"
---@param source_bufnr integer|nil
local function out_new_buffer(lines, layout, source_bufnr)
  if layout == "vsplit" then
    vim.cmd("vsplit")
  elseif layout == "split" then
    vim.cmd("split")
  elseif layout == "tab" then
    vim.cmd("tabnew")
  end

  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_win_set_buf(0, buf)

  if source_bufnr and api.nvim_buf_is_valid(source_bufnr) then
    local ft = api.nvim_get_option_value("filetype", { buf = source_bufnr })
    if ft and ft ~= "" then
      vim.bo[buf].filetype = ft
    end
  end
end

---Deliver `lines` via `mode`.
---@param mode LanguageTranslateOutput
---@param lines string[]
---@param ctx { bufnr: integer, s: integer, e: integer, target?: string }
---@return nil
function M.apply(mode, lines, ctx)
  if mode == "replace" then
    out_replace(ctx.bufnr, ctx.s, ctx.e, lines)
  elseif mode == "insert" then
    out_insert(ctx.bufnr, ctx.s, ctx.e, lines)
  elseif mode == "buffer" or mode == "vsplit" or mode == "split" or mode == "tab" then
    out_new_buffer(lines, mode, ctx.bufnr)
  elseif mode == "clipboard" then
    local text = table.concat(lines, "\n")
    pcall(vim.fn.setreg, "+", text)
    pcall(vim.fn.setreg, '"', text)
  elseif mode == "notify" then
    require("lib.nvim.notify").create("[language.translate]").info(table.concat(lines, "\n"))
  else -- "popup" and any unknown mode
    out_popup(lines, ctx.target)
  end
end

return M
