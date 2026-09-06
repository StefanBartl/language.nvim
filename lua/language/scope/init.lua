---@module 'language.scope'
---@brief Shared scope parser for both domains (spell + translate).
---@description
--- Turns raw command tokens into a single `LanguageScope` object, so no domain
--- module re-derives the target buffer/range/path.
--- Recognized scope tokens: `buffer`, `visible`, `cwd`, `path=<p>`, `selection`.
--- Any token that is not a scope token is returned in `rest` for the caller to
--- interpret (e.g. language code, flags).

require("language.@types")

local api = vim.api

local M = {}

---@type table<string, true>
--- `cword` is in the shared set although only `:Translate` acts on it, and the
--- alternative was worse: leaving it out means `:Translate DE cword` parses
--- `cword` as a *second language code* rather than as a scope, and the command
--- would quietly translate the whole buffer. `language.spell` declines it by
--- name instead, which is a refusal a reader can see.
local SCOPE_WORDS = { buffer = true, visible = true, cwd = true, selection = true, cword = true }

---@internal
--- The byte span of the word at `col` in `line`, or nil.
---
--- Not `'iskeyword'`, deliberately. That option is per-filetype and exists to
--- serve motions -- in Lua it excludes `-`, in CSS it includes it -- so the
--- same prose word would be a different word depending on which buffer it was
--- read in, and a translation is about the prose rather than the grammar.
--- What counts here is letters, digits, underscore, and every byte above
--- 0x7F, which is how the letters of every language written in UTF-8 arrive.
---@param line string
---@param col integer 0-based byte column
---@return integer|nil first 1-based, inclusive
---@return integer|nil last  1-based, inclusive
local function word_span(line, col)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local function is_word(i)
    local ch = line:sub(i, i)
    return ch ~= "" and (ch:match("[%w_]") ~= nil or ch:byte() >= 0x80)
  end

  local at = col + 1
  if at < 1 or at > #line or not is_word(at) then
    return nil
  end
  local first, last = at, at
  while first > 1 and is_word(first - 1) do
    first = first - 1
  end
  while last < #line and is_word(last + 1) do
    last = last + 1
  end

  -- A run with no letter in it -- `42`, `__`, `0x1f` -- is not a word anything
  -- can translate, and asking anyway would spend a network round trip to be
  -- told so. Bytes above 0x7F count as letters: this must not decline a word
  -- that is entirely non-ASCII.
  local run = line:sub(first, last)
  if not run:match("%a") and not run:find("[\128-\255]") then
    return nil
  end
  return first, last
end

--- The word at a position, or nil where there is none.
---
--- Positions are hover.nvim's convention -- 1-based row, 0-based column --
--- because that is the only caller that passes one it did not choose itself.
---@param bufnr integer
---@param row integer 1-based
---@param col integer 0-based
---@return string|nil
function M.cword_at(bufnr, row, col)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local line = (api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1]
  if not line then
    return nil
  end
  local first, last = word_span(line, col)
  if not first then
    return nil
  end
  return line:sub(first, last)
end

--- The word at a position as a character region, in the shape
--- `nvim_buf_get_text` and `language.translate.run_region` both take.
---@param bufnr integer
---@param row integer 1-based
---@param col integer 0-based
---@return { sr: integer, sc: integer, er: integer, ec: integer }|nil
function M.cword_region(bufnr, row, col)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local line = (api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1]
  if not line then
    return nil
  end
  local first, last = word_span(line, col)
  if not first then
    return nil
  end
  -- end-exclusive: `last` is the last byte of the word, so the region ends one
  -- past it.
  return { sr = row - 1, sc = first - 1, er = row - 1, ec = last }
end

---@internal
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
      elseif tok == "cword" then
        -- Read from the current window, the same assumption `visible_range`
        -- above already makes: a command was typed, so the cursor that was
        -- there when it was typed is the one meant.
        local pos = api.nvim_win_get_cursor(0)
        scope = {
          kind = "cword",
          bufnr = bufnr,
          region = M.cword_region(bufnr, pos[1], pos[2]),
        }
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
  elseif scope.kind == "cword" then
    local r = scope.region
    return r and ("cword:%d:%d"):format(r.sr + 1, r.sc) or "cword:none"
  elseif scope.kind == "selection" or scope.kind == "visible" then
    local r = scope.range or { s = 0, e = 0 }
    return ("%s:%d-%d"):format(scope.kind, r.s, r.e)
  end
  return scope.kind
end

return M
