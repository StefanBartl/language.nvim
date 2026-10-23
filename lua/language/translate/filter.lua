---@module 'language.translate.filter'
---@brief Computes line ranges that are safe to translate (skip code).
---@description
--- Pure function (ported from the prior config/translate/filter). Given a
--- buffer and a start/end line, returns contiguous 1-based line ranges that do
--- NOT belong to fenced code blocks (```) and do NOT contain inline code
--- (backticks). Used for the `--nocode` translate mode.

local M = {}

---@param bufnr integer
---@param start_line integer  1-based inclusive
---@param end_line integer    1-based inclusive
---@return { s: integer, e: integer }[]
function M.translatable_ranges(bufnr, start_line, end_line)
  if not bufnr or not start_line or not end_line then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  ---@type { s: integer, e: integer }[]
  local ranges = {}
  local in_fence = false
  local cur_s, cur_e = nil, nil

  local function flush(last)
    if cur_s and last >= cur_s then
      ranges[#ranges + 1] = { s = cur_s, e = last }
    end
    cur_s, cur_e = nil, nil
  end

  for i, line in ipairs(lines) do
    local lnum = start_line + i - 1
    if line:match("^%s*```") then
      in_fence = not in_fence
      flush(lnum - 1)
    elseif not in_fence then
      -- outside a fenced block: track inline code / plain-text runs
      if line:find("`", 1, true) then
        flush(lnum - 1)
      else
        if not cur_s then
          cur_s = lnum
        end
        cur_e = lnum
      end
    end
  end

  if cur_s then
    flush(cur_e or cur_s)
  end

  return ranges
end

---Line ranges of the cue text of an SRT/WebVTT buffer inside `[start_line, end_line]`:
---one range per cue, never an index, timing, header or `NOTE`/`STYLE` line. The kind
---comes from the buffer (file name, filetype, content), there is no switch.
---@param bufnr integer
---@param start_line integer  1-based inclusive
---@param end_line integer    1-based inclusive
---@return { s: integer, e: integer }[]
function M.subtitle_ranges(bufnr, start_line, end_line)
  if not bufnr or not start_line or not end_line then
    return {}
  end
  local subtitle = require("language.translate.subtitle")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kind = subtitle.detect(vim.api.nvim_buf_get_name(bufnr), vim.bo[bufnr].filetype, lines)
  if not kind then
    return {}
  end
  ---@type { s: integer, e: integer }[]
  local ranges = {}
  for _, r in ipairs(subtitle.cue_ranges(lines, kind)) do
    local s, e = math.max(r.s, start_line), math.min(r.e, end_line)
    if s <= e then
      ranges[#ranges + 1] = { s = s, e = e }
    end
  end
  return ranges
end

return M
