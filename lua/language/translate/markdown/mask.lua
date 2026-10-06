---@module 'language.translate.markdown.mask'
---@brief Protects inline Markdown syntax from the translation engine.
---@description
--- Before a unit goes to an engine, everything that must survive byte for byte
--- is replaced by a numbered placeholder `{n}` and put back afterwards:
---   * inline code spans, autolinks and inline HTML (tags, comments),
---   * the two halves of a link or image (`[`/`![` and `](dest "title")` or
---     `][label]`) -- the link TEXT stays translatable --, bare URLs,
---     footnote references `[^x]`, shortcut/collapsed references whose label
---     has a definition (translating the text would break the link),
---   * HTML entities, `{#id}`/`{.class}` attribute lists, a literal `{3}` of
---     the source itself, and the caller's "keep" words (proper names).
---
--- The placeholder is plain ASCII on purpose. Measured (spike 2026-10-06): on
--- the Windows curl path the Unicode pair U+27E6/U+27E7 came back as `?1?` for
--- 25 % of the units, `{n}` for none.
---
--- An engine may still mangle a placeholder, so `check` is the gate: every
--- placeholder must be present exactly once, and the open half of a link must
--- stay in front of its close half. A unit that fails it is never accepted.

local M = {}

---@class LanguageMdMask
---@field toks string[]               -- the protected text of placeholder n
---@field pair table<integer, integer> -- open placeholder -> its closing placeholder

-- Fullwidth braces: an engine translating into CJK likes to "localise" `{1}`.
local FW_OPEN = "\239\189\155"
local FW_CLOSE = "\239\189\157"

---@internal
---@param ctx table
---@param text string
---@return integer
local function tok(ctx, text)
  local n = #ctx.toks + 1
  ctx.toks[n] = text
  ctx.out[#ctx.out + 1] = "{" .. n .. "}"
  return n
end

---@internal
---@param ctx table
---@param text string
local function lit(ctx, text)
  if text ~= "" then
    ctx.out[#ctx.out + 1] = text
  end
end

---@internal
---Position of the backtick run closing a span opened by `k` backticks at `from`.
---@param s string
---@param from integer
---@param k integer
---@param j integer
---@return integer|nil
local function span_end(s, from, k, j)
  local q = from
  while true do
    local a, b = s:find("`+", q)
    if not a or a > j then
      return nil
    end
    if b - a + 1 == k then
      return b
    end
    q = b + 1
  end
end

---@internal
---The `]` that closes the `[` at `i`: skips escapes, code spans and nested pairs.
---@param s string
---@param i integer
---@param j integer
---@return integer|nil
local function find_close(s, i, j)
  local depth, p = 1, i + 1
  while p <= j do
    local c = s:sub(p, p)
    if c == "\\" then
      p = p + 2
    elseif c == "`" then
      local run = s:match("^`+", p)
      local e = span_end(s, p + #run, #run, j)
      p = (e or (p + #run - 1)) + 1
    elseif c == "[" then
      depth = depth + 1
      p = p + 1
    elseif c == "]" then
      depth = depth - 1
      if depth == 0 then
        return p
      end
      p = p + 1
    else
      p = p + 1
    end
  end
  return nil
end

---@internal
---The `)` closing the destination that opens at `p` (a `(`): balanced
---parentheses, escapes, `<...>` and a quoted title are honoured.
---@param s string
---@param p integer
---@param j integer
---@return integer|nil
local function parse_dest(s, p, j)
  local depth, i, quote = 1, p + 1, nil
  while i <= j do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif quote then
      if c == quote then
        quote = nil
      end
    elseif (c == '"' or c == "'") and s:sub(i - 1, i - 1):match("[ \t]") then
      quote = c
    elseif c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
    i = i + 1
  end
  return nil
end

---@internal
---@param label string
---@return string
local function norm_label(label)
  return (label:lower():gsub("[ \t]+", " "):gsub("^ ", ""):gsub(" $", ""))
end
M._norm_label = norm_label

local scan

---@internal
---Try `[...]`/`![...]` at `i`. Returns the index after it, or nil when it is no link.
---@param ctx table
---@param i integer
---@param j integer
---@param img boolean
---@return integer|nil
local function try_bracket(ctx, i, j, img)
  local s = ctx.s
  local b = i + (img and 1 or 0)
  if not img then
    local fn = s:match("^%[%^[^%]%s]+%]", b)
    if fn and b + #fn - 1 <= j then
      tok(ctx, fn)
      return b + #fn
    end
  end
  local close = find_close(s, b, j)
  if not close then
    return nil
  end
  local nx = s:sub(close + 1, close + 1)
  local stop
  if nx == "(" then
    stop = parse_dest(s, close + 1, j)
  elseif nx == "[" then
    local lab = s:match("^%[[^%]]*%]", close + 1)
    if lab and close + #lab <= j then
      if lab == "[]" then
        -- `[text][]`: the text IS the label, it must not be translated.
        tok(ctx, s:sub(i, close + 2))
        return close + 3
      end
      stop = close + #lab
    end
  end
  if stop then
    local open = tok(ctx, s:sub(i, b))
    scan(ctx, b + 1, close - 1)
    ctx.pair[open] = tok(ctx, s:sub(close, stop))
    return stop + 1
  end
  -- `[label]` with a definition somewhere: translating it would break the link.
  if ctx.defs[norm_label(s:sub(b + 1, close - 1))] then
    tok(ctx, s:sub(i, close))
    return close + 1
  end
  return nil
end

---@internal
---@param ctx table
---@param i integer
---@param j integer
scan = function(ctx, i, j)
  local s = ctx.s
  while i <= j do
    local p = s:find(ctx.special, i)
    if not p or p > j then
      lit(ctx, s:sub(i, j))
      return
    end
    if p > i then
      lit(ctx, s:sub(i, p - 1))
    end
    i = p
    local c = s:sub(i, i)
    local nxt

    if c == "\\" then
      lit(ctx, s:sub(i, i + 1))
      nxt = i + 2
    elseif c == "`" then
      local run = s:match("^`+", i)
      local e = span_end(s, i + #run, #run, j)
      if e then
        tok(ctx, s:sub(i, e))
        nxt = e + 1
      else
        lit(ctx, run)
        nxt = i + #run
      end
    elseif c == "!" then
      if s:sub(i + 1, i + 1) == "[" then
        nxt = try_bracket(ctx, i, j, true)
      end
      if not nxt then
        lit(ctx, "!")
        nxt = i + 1
      end
    elseif c == "[" then
      nxt = try_bracket(ctx, i, j, false)
      if not nxt then
        lit(ctx, "[")
        nxt = i + 1
      end
    elseif c == "<" then
      local m
      if s:sub(i, i + 3) == "<!--" then
        local e = s:find("-->", i + 4, true)
        m = e and s:sub(i, e + 2)
      else
        m = s:match("^</?%a[%w:-]*[^<>]*>", i)
      end
      if m and i + #m - 1 <= j then
        tok(ctx, m)
        nxt = i + #m
      else
        lit(ctx, "<")
        nxt = i + 1
      end
    elseif c == "&" then
      local m = s:match("^&#?%w+;", i)
      if m and i + #m - 1 <= j then
        tok(ctx, m)
        nxt = i + #m
      else
        lit(ctx, "&")
        nxt = i + 1
      end
    elseif c == "{" then
      local m = s:match("^{%d+}", i) or s:match("^{[#.:][^{}]*}", i)
      if m and i + #m - 1 <= j then
        tok(ctx, m)
        nxt = i + #m
      else
        lit(ctx, "{")
        nxt = i + 1
      end
    end

    if not nxt then
      -- A "keep" word, or the `h` of a bare URL.
      local boundary = i == 1 or not s:sub(i - 1, i - 1):match("[%w_]")
      local taken
      if boundary and c == "h" then
        local u = s:match("^https?://[^%s<>]+", i)
        if u then
          u = u:gsub("[%.,;:!?%)%]'\"]+$", "")
          if #u > 8 and i + #u - 1 <= j then
            tok(ctx, u)
            nxt = i + #u
            taken = true
          end
        end
      end
      if not taken and boundary then
        for _, w in ipairs(ctx.keepby[c] or {}) do
          local e = i + #w - 1
          if e <= j and s:sub(i, e) == w and not s:sub(e + 1, e + 1):match("[%w_]") then
            tok(ctx, w)
            nxt = e + 1
            taken = true
            break
          end
        end
      end
      if not taken then
        lit(ctx, c)
        nxt = i + 1
      end
    end
    i = nxt
  end
end

---Mask `text`. `opts.defs` is the set of normalised reference-definition
---labels, `opts.keep` a list of words that must stay as they are.
---@param text string
---@param opts? { defs?: table<string, boolean>, keep?: string[] }
---@return string masked, LanguageMdMask mask
function M.mask(text, opts)
  opts = opts or {}
  local keepby, extra = {}, {}
  for _, w in ipairs(opts.keep or {}) do
    if type(w) == "string" and w ~= "" then
      local b = w:sub(1, 1)
      if not keepby[b] then
        keepby[b] = {}
        extra[#extra + 1] = b:match("%w") and b or ("%" .. b)
      end
      keepby[b][#keepby[b] + 1] = w
    end
  end
  local ctx = {
    s = text,
    out = {},
    toks = {},
    pair = {},
    defs = opts.defs or {},
    keepby = keepby,
    special = "[`\\!%[<&{h" .. table.concat(extra) .. "]",
  }
  scan(ctx, 1, #text)
  return table.concat(ctx.out), { toks = ctx.toks, pair = ctx.pair }
end

---Does `masked` carry anything to translate besides placeholders, digits and
---punctuation?
---@param masked string
---@return boolean
function M.has_text(masked)
  return (masked:gsub("{%d+}", "")):find("[%a\128-\255]") ~= nil
end

---Normalise what an engine returned: fullwidth braces and spaces inside a
---placeholder (`{ 3 }`) are put right.
---@param text string
---@return string
function M.normalize(text)
  text = text:gsub(FW_OPEN, "{"):gsub(FW_CLOSE, "}")
  return (text:gsub("{%s*(%d+)%s*}", "{%1}"))
end

---Every placeholder exactly once, an open half before its close half.
---@param text string  -- already normalised
---@param mask LanguageMdMask
---@return boolean ok, string|nil err
function M.check(text, mask)
  local n = #mask.toks
  local pos = {}
  local total = 0
  for from, d in text:gmatch("()%{(%d+)%}") do
    local k = tonumber(d)
    total = total + 1
    if k < 1 or k > n or pos[k] then
      return false, ("placeholder {%s} unexpected or repeated"):format(d)
    end
    pos[k] = from
  end
  if total ~= n then
    return false, ("%d of %d placeholders came back"):format(total, n)
  end
  for open, close in pairs(mask.pair) do
    if pos[open] > pos[close] then
      return false, "a link's halves changed places"
    end
  end
  return true
end

---Put the protected text back.
---@param text string
---@param mask LanguageMdMask
---@return string
function M.unmask(text, mask)
  return (text:gsub("{(%d+)}", function(d)
    return mask.toks[tonumber(d)]
  end))
end

return M
