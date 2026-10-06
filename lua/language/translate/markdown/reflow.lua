---@module 'language.translate.markdown.reflow'
---@brief Distributes a translated text over exactly the original number of lines.
---@description
--- A soft line break inside a paragraph is invisible in the rendered HTML, so a
--- unit's translation can be wrapped onto the same number of lines as the
--- source. That keeps every line-based mapping of the previewer (scroll sync,
--- cursor marker, click-to-navigate, checkbox sync) valid without a client
--- change. `#out == #in` is the invariant the whole feature stands on.
---
--- Words are spread in proportion to the width of the original lines. A break
--- never lands in front of a word that the Markdown parser would read as the
--- start of a block (`-`, `*`, `+`, `1.`, `#`, `>`, `|`, a fence, ...): spike
--- 2026-10-06, a dash at the beginning of a line turned a sentence into a list
--- item and the document went from 98 to 102 blocks.
---
--- Fewer words than lines (a short translation of a long hard-wrapped
--- paragraph): one word per line, the surplus lines are returned as "" and the
--- caller decides what a padding line looks like.

local M = {}

local NOT_WS = "[^ \t\r\n\f\v]+"

---Would `word`, placed at the start of a line, begin a new Markdown block?
---@param word string
---@return boolean
function M.starts_block(word)
  if word == "-" or word == "*" or word == "+" then
    return true
  end
  if word:match("^[-=]+$") then
    return true
  end
  if #word >= 3 and word:match("^[*_]+$") then
    return true
  end
  if #word <= 10 and word:match("^%d+[.)]$") then
    return true
  end
  if #word <= 6 and word:match("^#+$") then
    return true
  end
  local c = word:sub(1, 1)
  if c == ">" or c == "|" or c == "<" then
    return true
  end
  -- The cell of a table's delimiter row: `:-:`, `--:`.
  if word:match("^[:%-]+$") then
    return true
  end
  if word:match("^```") or word:match("^~~~") or word:match("^%$%$") or word:match("^:::") then
    return true
  end
  -- A reference or footnote definition: `[label]:`.
  return word:match("^%[[^%]]*%]:") ~= nil
end

---Does `line` look like the delimiter row of a table (`| --- | :-: |`)? A wrap that
---makes one out of a line of text turns the paragraph above it into a table.
---@param line string
---@return boolean
function M.is_table_rule(line)
  return line:find("-", 1, true) ~= nil
    and line:find("|", 1, true) ~= nil
    and line:match("^[ \t>|:%-]+$") ~= nil
end

---Split `text` at white space.
---@param text string
---@return string[]
function M.words(text)
  local words, n = {}, 0
  for w in text:gmatch(NOT_WS) do
    n = n + 1
    words[n] = w
  end
  return words
end

---Wrap `text` onto `#weights` lines.
---@param text string
---@param weights integer[]                 -- width of each original line (its share of the words)
---@param opts? { guard_first?: boolean, unsafe?: fun(word: string): boolean }
---`guard_first`: line 1 follows no block marker of its own, so its first word
---is checked as well. `unsafe` replaces `starts_block` (the caller expands
---placeholders first).
---@return string[]|nil lines, string|nil err  -- exactly `#weights` lines (padding lines are "")
function M.reflow(text, weights, opts)
  opts = opts or {}
  local unsafe = opts.unsafe or M.starts_block
  local n = #weights
  local words = M.words(text)
  local m = #words
  if m == 0 then
    return nil, "empty translation"
  end
  if opts.guard_first and unsafe(words[1]) then
    return nil, "the translation would start a block on its first line"
  end
  if n <= 1 then
    return { table.concat(words, " ") }
  end

  local safe = {}
  local function ok_start(c)
    local v = safe[c]
    if v == nil then
      v = not unsafe(words[c])
      safe[c] = v
    end
    return v
  end

  ---@type integer[]
  local starts = { 1 }
  if m < n then
    for k = 2, m do
      if not ok_start(k) then
        return nil, "no safe line break"
      end
      starts[k] = k
    end
  else
    local prefix, acc = {}, 0
    for i = 1, m do
      acc = acc + #words[i] + (i > 1 and 1 or 0)
      prefix[i] = acc
    end
    local sum = 0
    for k = 1, n do
      sum = sum + math.max(weights[k], 1)
    end
    local cum = 0
    for k = 1, n - 1 do
      cum = cum + math.max(weights[k], 1)
      local target = acc * cum / sum
      local lo, hi = starts[k] + 1, m - (n - k - 1)
      -- `prefix` grows with every word, so the distance to `target` is V-shaped:
      -- the best break is the nearest safe word on either side of the first word
      -- that reaches it. (A scan over the whole range would make a paragraph of
      -- n lines and m words cost n * m.)
      local a, b = lo, hi
      while a < b do
        local mid = math.floor((a + b) / 2)
        if prefix[mid - 1] >= target then
          b = mid
        else
          a = mid + 1
        end
      end
      local best, best_d
      for c = a - 1, lo, -1 do
        if ok_start(c) then
          best, best_d = c, math.abs(prefix[c - 1] - target)
          break
        end
      end
      for c = a, hi do
        if ok_start(c) then
          if not best_d or math.abs(prefix[c - 1] - target) < best_d then
            best = c
          end
          break
        end
      end
      if not best then
        return nil, "no safe line break"
      end
      starts[k + 1] = best
    end
  end

  local out = {}
  for k = 1, n do
    if starts[k] then
      local first = starts[k]
      local last = (starts[k + 1] or (m + 1)) - 1
      out[k] = table.concat(words, " ", first, last)
    else
      out[k] = ""
    end
  end
  return out
end

return M
