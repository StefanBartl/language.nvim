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
---@field degraded? boolean            -- the scan budget ran out: a look-ahead was skipped, the masking is not to be trusted

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
---Spend `n` of the unit's scan budget; false once it is used up. Every look-ahead
---(a closing bracket, a closing parenthesis, a closing backtick run) runs to the
---end of the unit when it finds nothing, so `[a [a [a ...` would cost n * n. The
---budget keeps the whole mask linear; what it cuts off stays literal text, and the mask
---is marked `degraded` (the caller leaves such a unit alone).
---@param ctx table
---@param n integer
---@return boolean
local function spend(ctx, n)
  ctx.budget = ctx.budget - n
  return ctx.budget >= 0
end

-- Punctuation that ends a sentence, not an address: of `https://a.b/c.` the address is
-- `https://a.b/c`. A set of bytes.
local TRAIL = {}
for b in (".,;:!?)]'\""):gmatch(".") do
  TRAIL[b:byte()] = true
end

---@internal
---The last index in `first..last` of `s` that is not trailing sentence punctuation. A byte
---scan from the end, not `gsub("[...]+$", "")`: that restarts at every byte of a long run of
---punctuation and costs run^2.
---@param s string
---@param first integer
---@param last integer
---@return integer
local function trim_tail(s, first, last)
  while last >= first and TRAIL[s:byte(last)] do
    last = last - 1
  end
  return last
end

---@internal
---The index of the last byte of the run of non-blank bytes (no white space, `<` or `>`) that
---`i` is in. Looked up once per run and kept: a run of many `https://` candidates would
---otherwise search (and copy) to its end once per candidate, run^2.
---@param ctx table
---@param i integer
---@return integer
local function run_end(ctx, i)
  local r = ctx.run
  if r.from > i or r.stop < i then
    local e = ctx.s:find("[%s<>]", i)
    r.from, r.stop = i, (e or #ctx.s + 1) - 1
  end
  return r.stop
end

---@internal
---The inline HTML tag that opens at `i` (a `<`): `<name ...>` or `</name ...>`, up to the first
---`>`. Only the first `<` or `>` after the name decides, so one find: a pattern with a name
---class in front of `[^<>]*` backtracks over the name once per byte and costs run^2.
---@param s string
---@param i integer
---@return string|nil
local function tag_at(s, i)
  if s:match("^</?%a", i) then
    local e = s:find("[<>]", i + 1)
    if e and s:byte(e) == 62 then
      return s:sub(i, e)
    end
  end
  return nil
end

---@internal
---The `]` that closes the footnote reference `[^label]` at `b`, or nil. The label is at least
---one byte and has no `]` or white space, so the first such byte after `[^` decides; it is
---remembered, as a text of many `[^` without a `]` would search to its end once per `[^`.
---@param ctx table
---@param b integer
---@return integer|nil
local function footnote_end(ctx, b)
  local s = ctx.s
  if s:sub(b, b + 1) ~= "[^" then
    return nil
  end
  local from = b + 2
  local fn = ctx.fn
  if not fn or fn.from > from or fn.pos < from then
    fn = { from = from, pos = s:find("[%]%s]", from) or math.huge }
    ctx.fn = fn
  end
  local e = fn.pos
  if e ~= math.huge and e > from and s:byte(e) == 93 then
    return e
  end
  return nil
end

---@internal
---Position of the backtick run closing a span opened by `k` backticks at `from`.
---@param ctx table
---@param s string
---@param from integer
---@param k integer
---@param j integer
---@return integer|nil
local function span_end(ctx, s, from, k, j)
  local q = from
  while true do
    local a, b = s:find("`+", q)
    if not a or a > j or not spend(ctx, 4) then
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
---@param ctx table
---@param s string
---@param i integer
---@param j integer
---@return integer|nil
local function find_close(ctx, s, i, j)
  local depth, p = 1, i + 1
  while p <= j do
    if not spend(ctx, 1) then
      return nil
    end
    local c = s:sub(p, p)
    if c == "\\" then
      p = p + 2
    elseif c == "`" then
      local run = s:match("^`+", p)
      local e = span_end(ctx, s, p + #run, #run, j)
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
---@param ctx table
---@param s string
---@param p integer
---@param j integer
---@return integer|nil
local function parse_dest(ctx, s, p, j)
  local depth, i, quote = 1, p + 1, nil
  while i <= j do
    if not spend(ctx, 1) then
      return nil
    end
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
    local fe = footnote_end(ctx, b)
    if fe and fe <= j then
      tok(ctx, s:sub(b, fe))
      return fe + 1
    end
  end
  local close = find_close(ctx, s, b, j)
  if not close then
    return nil
  end
  local nx = s:sub(close + 1, close + 1)
  local stop
  if nx == "(" then
    stop = parse_dest(ctx, s, close + 1, j)
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
    -- The next special character at or after `i`. Looked up once and kept: a text with few
    -- of them but many bare addresses would otherwise search to the end of the unit once per
    -- address (n addresses cost n * length).
    local p
    local sp = ctx.sp
    if sp and sp.from <= i and sp.pos >= i then
      p = sp.pos ~= math.huge and sp.pos or nil
    else
      p = s:find(ctx.special, i)
      ctx.sp = { from = i, pos = p or math.huge }
    end
    -- A bare address before the next special character (or in place of the text up to
    -- the end) is taken whole: its pieces would otherwise be cut by the `h` of a host.
    local bare = ctx.bare
    while bare[ctx.bi] and bare[ctx.bi][1] < i do
      ctx.bi = ctx.bi + 1
    end
    local br = bare[ctx.bi]
    local blast
    if br and br[1] <= j and (not p or br[1] <= p) then
      blast = br[2]
      if blast > j then
        -- A `www.` address that runs on past the text of a link, into its `](dest)`: the part
        -- inside the text is the address (an e-mail address cannot straddle a `]`).
        blast = br[3] and trim_tail(s, br[1], j) or nil
        if blast and blast - br[1] + 1 <= 6 then
          blast = nil
        end
      end
    end
    if blast then
      lit(ctx, s:sub(i, br[1] - 1))
      tok(ctx, s:sub(br[1], blast))
      ctx.bi = ctx.bi + 1
      i = blast + 1
    else
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
        local e = span_end(ctx, s, i + #run, #run, j)
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
          -- The first `-->` at or after `i + 4`, remembered: a unit with many `<!--` and
          -- no closing `-->` (or one beyond `j`) would search to its end once per opener.
          local ce = ctx.close_at
          local e
          if ce and ce.from <= i + 4 and (ce.pos == false or ce.pos >= i + 4) then
            e = ce.pos or nil
          else
            e = s:find("-->", i + 4, true)
            ctx.close_at = { from = i + 4, pos = e or false }
          end
          m = e and e + 2 <= j and s:sub(i, e + 2) or nil
        else
          m = tag_at(s, i)
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
        if boundary and c == "h" and s:match("^https?://", i) then
          -- Up to the next white space, `<` or `>`, but not past the text of the link it stands
          -- in (`[https://a.b](https://a.b)`: the visible address is an address, too), and
          -- without the punctuation of the sentence. The run is not copied before it is known
          -- to be taken.
          local last = trim_tail(s, i, math.min(run_end(ctx, i), j))
          if last - i + 1 > 8 then
            tok(ctx, s:sub(i, last))
            nxt = last + 1
            taken = true
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
end

---@internal
---Bare e-mail addresses and `www.` addresses, as `{ first, last, www }` byte ranges in
---order (`www` is true for a `www.` address). The previewer links both (GFM autolinks); an
---engine that "translates" `john.doe@example.com` breaks the link.
---@param text string
---@return table[]
local function bare_ranges(text)
  local out = {}
  if text:find("@", 1, true) then
    -- Anchored at each `@` (the local part is taken backwards, the domain forwards): a
    -- find for the whole address from every byte of a long run of letters costs run^2.
    local init = 1
    while true do
      local at = text:find("@", init, true)
      if not at then
        break
      end
      local a = at
      while a > init and at - a <= 256 and text:sub(a - 1, a - 1):match("[%w%._%%%+%-]") do
        a = a - 1
      end
      local dom = text:match("^[%w%-]+%.[%w%.%-]*%w", at + 1)
      if a < at and dom then
        local b = at + #dom
        if a == 1 or not text:sub(a - 1, a - 1):match("[%w_]") then
          out[#out + 1] = { a, b }
        end
        init = b + 1
      else
        init = at + 1
      end
    end
  end
  if text:find("www.", 1, true) then
    local init = 1
    while true do
      local a, b = text:find("www%.[%w%-]+%.[^%s<>]*", init)
      if not a then
        break
      end
      init = b + 1
      if a == 1 or not text:sub(a - 1, a - 1):match("[%w_]") then
        local last = trim_tail(text, a, b)
        if last - a + 1 > 6 then
          -- The third field: it may be cut short at the end of a link text (see `scan`).
          out[#out + 1] = { a, last, true }
        end
      end
    end
  end
  table.sort(out, function(x, y)
    return x[1] < y[1]
  end)
  -- Overlapping ranges (an address in an address): the first one wins.
  local clean, last = {}, 0
  for _, r in ipairs(out) do
    if r[1] > last then
      clean[#clean + 1] = r
      last = r[2]
    end
  end
  return clean
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
    budget = 64 * #text + 4096,
    bare = bare_ranges(text),
    bi = 1,
    run = { from = 1, stop = 0 },
    special = "[`\\!%[<&{h" .. table.concat(extra) .. "]",
  }
  scan(ctx, 1, #text)
  -- A look-ahead that was cut off left a link or a code span as plain text. The
  -- caller keeps such a unit as it is: translating it would let the engine touch
  -- syntax that was not protected.
  return table.concat(ctx.out),
    { toks = ctx.toks, pair = ctx.pair, degraded = ctx.budget < 0 or nil }
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
    local a, b = pos[open], pos[close]
    if a and b and a > b then
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
