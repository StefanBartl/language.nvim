---@module 'language.scope'
---@brief Shared scope parser for both domains (spell + translate).
---@description
--- Turns raw command tokens into a single `LanguageScope` object, so no domain
--- module re-derives the target buffer/range/path (Zentrale-Prinzipien §3).
--- Recognized scope tokens: `buffer`, `visible`, `cwd`, `path=<p>`, `selection`.
--- Any token that is not a scope token is returned in `rest` for the caller to
--- interpret (e.g. language code, flags).

require("language.@types")

local api = vim.api

local M = {}

---@type table<string, true>
local SCOPE_WORDS = { buffer = true, visible = true, cwd = true, selection = true }

---Build the visible line range of the current window (1-based, inclusive).
---@return integer s, integer e
local function visible_range()
  return vim.fn.line("w0"), vim.fn.line("w$")
end

---Parse tokens into a scope object plus the leftover (non-scope) tokens.
---@param tokens string[]                       raw whitespace-split arguments
---@param ctx { bufnr?: integer, line1?: integer, line2?: integer, has_range?: boolean }|nil
---@return LanguageScope scope
---@return string[] rest                         tokens that were not scope tokens
function M.parse(tokens, ctx)
  ctx = ctx or {}
  local bufnr = ctx.bufnr or api.nvim_get_current_buf()

  ---@type LanguageScope|nil
  local scope = nil
  ---@type string[]
  local rest = {}
  local n = 0

  for _, tok in ipairs(tokens or {}) do
    local path = tok:match("^path=(.+)$")
    if path then
      scope = { kind = "path", path = vim.fn.expand(path) }
    elseif SCOPE_WORDS[tok] then
      if tok == "visible" then
        local s, e = visible_range()
        scope = { kind = "visible", bufnr = bufnr, range = { s = s, e = e } }
      elseif tok == "selection" then
        scope = {
          kind = "selection",
          bufnr = bufnr,
          range = { s = ctx.line1 or 1, e = ctx.line2 or api.nvim_buf_line_count(bufnr) },
        }
      else
        scope = { kind = tok, bufnr = bufnr }
      end
    else
      n = n + 1
      rest[n] = tok
    end
  end

  -- Implicit selection when the command was given a range but no explicit scope.
  if not scope and ctx.has_range then
    scope = {
      kind = "selection",
      bufnr = bufnr,
      range = { s = ctx.line1 or 1, e = ctx.line2 or api.nvim_buf_line_count(bufnr) },
    }
  end

  scope = scope or { kind = "buffer", bufnr = bufnr }
  return scope, rest
end

---Human-readable label for notifications/titles.
---@param scope LanguageScope
---@return string
function M.label(scope)
  if scope.kind == "path" then
    return "path:" .. (scope.path or "?")
  elseif scope.kind == "selection" or scope.kind == "visible" then
    local r = scope.range or { s = 0, e = 0 }
    return ("%s:%d-%d"):format(scope.kind, r.s, r.e)
  end
  return scope.kind
end

return M
