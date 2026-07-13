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
    elseif in_fence then
      -- inside a fenced block: skip
    elseif line:find("`", 1, true) then
      flush(lnum - 1)
    else
      if not cur_s then
        cur_s = lnum
      end
      cur_e = lnum
    end
  end

  if cur_s then
    flush(cur_e or cur_s)
  end

  return ranges
end

return M
