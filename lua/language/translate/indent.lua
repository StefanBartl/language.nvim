---@module 'language.translate.indent'
---@brief Preserve per-line leading indentation across a translate round-trip.
---@description
--- Providers (notably Google's `gtx` endpoint) normalize away leading
--- whitespace, so a translated markdown list item like `    - foo` comes back
--- as `- bar` with the indent dropped to column 0. We capture each line's
--- leading whitespace, translate the dedented text, then re-prepend the
--- captured indent to the matching output line — only when line counts match,
--- since a provider merging/splitting lines makes the 1:1 mapping meaningless.

local M = {}

---@param lines string[]
---@return string[] dedented, string[] indents
function M.strip(lines)
  local dedented, indents = {}, {}
  for i, line in ipairs(lines) do
    local ws, rest = line:match("^(%s*)(.*)$")
    indents[i] = ws
    dedented[i] = rest
  end
  return dedented, indents
end

---@param lines string[]
---@param indents string[]
---@return string[]
function M.restore(lines, indents)
  if #lines ~= #indents then
    return lines
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = indents[i] .. line
  end
  return out
end

return M
