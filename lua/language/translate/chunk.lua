---@module 'language.translate.chunk'
---@brief Splits large translate inputs into provider-sized, line-aligned blocks.
---@description
--- Every translate provider hands its payload to an external process (an argv
--- element or stdin), and the engines have request limits of their own (gtx:
--- request size, DeepL: 50 texts and a request size). This module is the one
--- place that handles it: `wrap` returns a provider with the same
--- `name`/`available`/`translate` signature whose `translate` cuts the input
--- into blocks on line boundaries (preferring blank lines), runs them one after
--- the other through the wrapped provider and joins the results again, so the
--- line count of the input -- and with it the indent restoration in
--- `translate/indent.lua` -- is untouched.
---
--- Three details keep that promise against real engines:
---   * Blank lines at the edge of a block are layout, not content. The engines
---     trim them (gtx drops leading/trailing newlines, `trans` output is
---     right-trimmed), so they are not sent; the wrapper puts them back around
---     the result. A block that is blank throughout is not sent at all.
---   * A line that is over the budget on its own is cut at sentence, then word
---     boundaries into pieces; the pieces are translated in blocks of their own
---     and re-joined with a single space, so it stays ONE line. Only a line
---     with no boundary inside the budget (one giant token) fails the call.
---   * `translate.max_blocks` refuses an input that would need an unreasonable
---     number of requests before the first one is sent.
---
--- A provider declares its budget with an optional `limits` field
--- (`LanguageTranslateLimits`). `translate.max_chars` can only lower it. A
--- failed block fails the whole call, and `cb` still runs exactly once. Every
--- request runs with the provider's own timeout, so `translate.timeout_ms` is
--- a budget per block, not per call.

require("language.translate.@types")

local M = {}

---@class LanguageTranslateLimits
---@field max_bytes integer                     -- budget per block, in `cost` units (bytes by default)
---@field max_lines? integer                    -- most lines per block (DeepL: 50 texts per request)
---@field cost? fun(line: string): integer      -- cost of one line incl. its separator; default `#line + 1`. Must grow with the line and never be below `#line` (the line splitter relies on both)
---@field override? fun(cfg: LanguageTranslateCfg|table): integer|nil -- budget from the engine's own config; may raise `max_bytes`

-- ASCII white space as explicit bytes: `%s` follows the C locale, which on some
-- Windows code pages classifies the 0xA0 byte inside UTF-8 sequences as a space.
local WS = "[ \t\r\n\f\v]"
local NOT_WS = "[^ \t\r\n\f\v]"
local BLANK = "^[ \t\r\n\f\v]*$"

-- Where an over-long line may be cut when no ASCII sentence end is in range.
local SENTENCE_MARKS = { "。", "！", "？", "；", "｡", "．" }
local CLAUSE_MARKS = { "，", "、", "：", "､" }

---@internal
---@param line string
---@return integer
local function default_cost(line)
  return #line + 1
end

---Effective limits: the provider's own budget, lowered by `cfg.max_chars`.
---@param provider LanguageTranslateProvider
---@param cfg LanguageTranslateCfg|table
---@return LanguageTranslateLimits|nil
function M.limits_for(provider, cfg)
  local base = provider.limits
  if type(base) ~= "table" then
    return nil
  end
  local max_bytes = base.max_bytes
  if type(base.override) == "function" then
    local ok, own = pcall(base.override, cfg)
    if ok and type(own) == "number" and own > 0 then
      max_bytes = math.floor(own)
    end
  end
  local user = cfg and cfg.max_chars
  if type(user) == "number" and user > 0 and user < max_bytes then
    max_bytes = math.floor(user)
  end
  return { max_bytes = max_bytes, max_lines = base.max_lines, cost = base.cost }
end

---@internal
---Cut `lines[first .. last]` where a block would overflow: back at the last
---blank line when that keeps at least half of the block, else right here.
---@param lines string[]
---@param first integer   -- first line of the block being closed
---@param last integer    -- last line that still fits
---@return integer end_line
local function pick_cut(lines, first, last)
  local floor = first + math.floor((last - first + 1) / 2) - 1
  for i = last, floor + 1, -1 do
    if lines[i]:match(BLANK) then
      return i
    end
  end
  return last
end

---@internal
---Largest byte index <= `limit` at which one of the literal `marks` ends in `s`.
---@param s string
---@param marks string[]
---@param limit integer
---@return integer|nil
local function last_mark_end(s, marks, limit)
  local best
  for _, mark in ipairs(marks) do
    local init = 1
    while true do
      local _, e = s:find(mark, init, true)
      if not e or e > limit then
        break
      end
      if not best or e > best then
        best = e
      end
      init = e + 1
    end
  end
  return best
end

---@internal
---The byte index in `head` after which an over-long line is cut. `head` is the
---longest prefix that fits (`n` bytes) plus the byte after it, so a boundary
---exactly at the end of the budget is seen. Prefers a sentence end in the
---second half of the budget, then the last white space, then any sentence end,
---then a clause separator (CJK comma, colon).
---@param head string
---@param n integer
---@return integer|nil
local function pick_boundary(head, n)
  local sentence
  for after in head:gmatch("[%.!%?;]()" .. WS) do
    local stop = after - 1
    if stop <= n and (not sentence or stop > sentence) then
      sentence = stop
    end
  end
  local cjk = last_mark_end(head, SENTENCE_MARKS, n)
  if cjk and (not sentence or cjk > sentence) then
    sentence = cjk
  end
  if sentence and sentence * 2 >= n then
    return sentence
  end
  local ws = head:find(WS .. NOT_WS .. "*$")
  if ws and ws > 1 then
    return ws - 1
  end
  return sentence or last_mark_end(head, CLAUSE_MARKS, n)
end

---@internal
---Longest prefix of `line` (from byte `pos`) that still fits the budget.
---@param line string
---@param pos integer
---@param limits LanguageTranslateLimits
---@return integer n
local function fit(line, pos, limits)
  local cost = limits.cost or default_cost
  local lo, hi = 0, math.min(#line - pos + 1, limits.max_bytes)
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if cost(line:sub(pos, pos + mid - 1)) <= limits.max_bytes then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

---@internal
---Strip trailing ASCII white space in linear time (`gsub("%s+$", "")` retries a
---white-space run from every byte inside it, quadratic on a long run; `%s` is
---also locale-dependent, see WS).
---@param s string
---@return string
local function rtrim_ws(s)
  local e = #s
  while e > 0 do
    local b = s:byte(e)
    if b ~= 32 and (b < 9 or b > 13) then
      break
    end
    e = e - 1
  end
  return s:sub(1, e)
end

---@internal
---Cut one over-long line into pieces that each fit the budget, at sentence and
---word boundaries (never inside a UTF-8 character). White space at a cut is
---dropped; the caller re-joins the translated pieces with a single space.
---@param line string
---@param limits LanguageTranslateLimits
---@return string[]|nil pieces, string|nil err
local function split_line(line, limits)
  local pieces = {}
  local pos, len = 1, #line
  while true do
    pos = line:find(NOT_WS, pos)
    if not pos then
      break
    end
    local n = fit(line, pos, limits)
    local stop
    if n > 0 and pos + n - 1 >= len then
      stop = len
    else
      local cut = n > 0 and pick_boundary(line:sub(pos, pos + n), n) or nil
      if not cut then
        return nil, "no sentence or word boundary inside the budget"
      end
      stop = pos + cut - 1
    end
    pieces[#pieces + 1] = rtrim_ws(line:sub(pos, stop))
    if stop >= len then
      break
    end
    pos = stop + 1
  end
  return pieces, nil
end

---@internal
---Pack the pieces of line `i` into blocks of their own (never mixed with other
---lines, so re-joining them stays trivial).
---@param blocks table[]
---@param i integer
---@param pieces string[]
---@param limits LanguageTranslateLimits
local function pack_pieces(blocks, i, pieces, limits)
  local cost = limits.cost or default_cost
  local group, used = {}, 0
  for _, piece in ipairs(pieces) do
    local c = cost(piece)
    if
      #group > 0
      and (used + c > limits.max_bytes or (limits.max_lines and #group >= limits.max_lines))
    then
      blocks[#blocks + 1] = { first = i, last = i, pieces = group }
      group, used = {}, 0
    end
    group[#group + 1] = piece
    used = used + c
  end
  blocks[#blocks + 1] = { first = i, last = i, pieces = group, tail = true }
end

---@class LanguageTranslateBlock
---@field first integer           -- first input line of the block
---@field last integer            -- last input line of the block
---@field pieces? string[]        -- set when the block carries the pieces of ONE over-long line (`first == last`)
---@field tail? boolean           -- the last block of such a line: its output is complete

---Split `lines` into blocks that respect `limits`.
---@param lines string[]
---@param limits LanguageTranslateLimits
---@return LanguageTranslateBlock[]|nil blocks, string|nil err
function M.split(lines, limits)
  local cost = limits.cost or default_cost
  local max_bytes, max_lines = limits.max_bytes, limits.max_lines
  ---@type LanguageTranslateBlock[]
  local blocks = {}
  local first, used = 1, 0
  local i = 1
  while i <= #lines do
    local c = cost(lines[i])
    if c > max_bytes then
      if first < i then
        blocks[#blocks + 1] = { first = first, last = i - 1 }
      end
      local pieces, perr = split_line(lines[i], limits)
      if not pieces then
        return nil,
          ("line %d is too long to translate (%d, limit %d): %s"):format(i, c, max_bytes, perr)
      end
      if #pieces == 0 then
        blocks[#blocks + 1] = { first = i, last = i }
      else
        pack_pieces(blocks, i, pieces, limits)
      end
      first, used, i = i + 1, 0, i + 1
    else
      local count = i - first
      if used + c > max_bytes or (max_lines and count >= max_lines) then
        local cut = pick_cut(lines, first, i - 1)
        blocks[#blocks + 1] = { first = first, last = cut }
        first, used, i = cut + 1, 0, cut + 1
      else
        used = used + c
        i = i + 1
      end
    end
  end
  if first <= #lines then
    blocks[#blocks + 1] = { first = first, last = #lines }
  end
  return blocks, nil
end

---@internal
---First and last line of `lines[first .. last]` that carry text; `lo > hi` when
---the whole range is blank.
---@param lines string[]
---@param first integer
---@param last integer
---@return integer lo, integer hi
local function text_span(lines, first, last)
  local lo, hi = first, last
  while lo <= hi and lines[lo]:match(BLANK) do
    lo = lo + 1
  end
  while hi >= lo and lines[hi]:match(BLANK) do
    hi = hi - 1
  end
  return lo, hi
end

---Wrap `provider` so oversized inputs are translated block by block. The
---provider's own `translate` is called unchanged for each block.
---@param provider LanguageTranslateProvider
---@return LanguageTranslateProvider
function M.wrap(provider)
  if type(provider.limits) ~= "table" then
    return provider
  end
  local inner = provider.translate
  local wrapped = vim.tbl_extend("force", {}, provider)

  ---@type LanguageTranslateFn
  wrapped.translate = function(lines, target, source, cfg, cb)
    local limits = M.limits_for(provider, cfg)
    if not limits or #lines == 0 then
      return inner(lines, target, source, cfg, cb)
    end
    local blocks, err = M.split(lines, limits)
    if not blocks then
      cb(false, ("%s: %s"):format(provider.name, err or "input too large"))
      return nil
    end
    local total = #blocks
    local cap = cfg and cfg.max_blocks
    if type(cap) == "number" and cap > 0 and total > cap then
      cb(
        false,
        ("%s: the input needs %d requests, more than translate.max_blocks (%d); select less or raise the option"):format(
          provider.name,
          total,
          cap
        )
      )
      return nil
    end

    local cancelled, settled = false, false
    local current, active = 0, nil
    ---@type string[]
    local out = {}
    ---@type string[]
    local joined = {} -- translated pieces of the over-long line being re-joined

    ---@param ok boolean
    ---@param result string[]|string
    local function settle(ok, result)
      if settled or cancelled then
        return
      end
      settled = true
      cb(ok, result)
    end

    ---@param n integer
    ---@param msg any
    local function fail(n, msg)
      if total == 1 then
        settle(false, tostring(msg))
        return
      end
      local b = blocks[n]
      settle(
        false,
        ("block %d/%d (lines %d-%d): %s"):format(n, total, b.first, b.last, tostring(msg))
      )
    end

    local step

    ---Send block `n` to the provider. `lo`/`hi` bound its text lines (blank
    ---edges excluded); the pieces of an over-long line carry no edges.
    ---@param n integer
    ---@param lo integer
    ---@param hi integer
    local function send(n, lo, hi)
      local b = blocks[n]
      ---@type string[]
      local payload = b.pieces
        or ((lo == 1 and hi == #lines) and lines or vim.list_slice(lines, lo, hi))

      local started, job = pcall(inner, payload, target, source, cfg, function(ok, result)
        if cancelled or settled then
          return
        end
        if not ok then
          fail(n, result)
          return
        end
        if type(result) ~= "table" then
          fail(n, "the provider returned no lines")
          return
        end
        if b.pieces then
          for _, text in ipairs(result) do
            if text ~= "" then
              joined[#joined + 1] = text
            end
          end
          if b.tail then
            out[#out + 1] = table.concat(joined, " ")
            joined = {}
          end
        else
          -- A parse of `out .. "\n"` (the documented custom `vim.split(out, "\n")`)
          -- hands back one trailing "" more than lines went in.
          local m = #result
          while m > #payload and result[m] == "" do
            m = m - 1
          end
          vim.list_extend(out, lines, b.first, lo - 1)
          vim.list_extend(out, result, 1, m)
          vim.list_extend(out, lines, hi + 1, b.last)
        end
        step(n + 1)
      end)
      if not started then
        fail(n, job)
        return
      end
      -- A synchronous callback has already moved on to the next block.
      if current == n then
        active = job
      end
    end

    step = function(n)
      while not (cancelled or settled) do
        if n > total then
          settle(true, out)
          return
        end
        current = n
        local b = blocks[n]
        if b.pieces then
          send(n, 1, 0)
          return
        end
        local lo, hi = text_span(lines, b.first, b.last)
        if lo <= hi then
          send(n, lo, hi)
          return
        end
        -- Blank throughout: nothing to translate, keep the lines as they are.
        vim.list_extend(out, lines, b.first, b.last)
        n = n + 1
      end
    end

    step(1)

    return {
      cancel = function()
        cancelled = true
        if active and type(active.cancel) == "function" then
          pcall(active.cancel)
        end
      end,
    }
  end

  return wrapped
end

return M
