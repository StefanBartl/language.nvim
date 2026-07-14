---@module 'language.spell.providers.util'
---@brief Shared helpers for external CLI spell providers.
---@description
--- Path resolution and buffer lookup used by the typos/cspell/codespell
--- providers so each doesn't re-implement the same normalization.

local fn = vim.fn
local api = vim.api

local M = {}

---@param p string
---@return boolean
function M.is_absolute(p)
  return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\]") ~= nil
end

---Resolve a CLI-reported path (possibly relative to `base`) to an absolute path.
---@param path string
---@param base string|nil
---@return string
function M.resolve_path(path, base)
  if base and not M.is_absolute(path) then
    path = base .. "/" .. path:gsub("^%.[/\\]", "")
  end
  return fn.fnamemodify(path, ":p")
end

---Return a valid, loaded buffer handle for `path`, or nil.
---@param path string
---@return integer|nil
function M.bufnr_for(path)
  local buf = fn.bufnr(path)
  if buf > 0 and api.nvim_buf_is_valid(buf) then
    return buf
  end
  return nil
end

return M
