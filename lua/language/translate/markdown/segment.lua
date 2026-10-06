---@module 'language.translate.markdown.segment'
---@brief Cuts a Markdown document into literal lines and translation units.
---@description
--- Never translated (kept byte for byte): front matter, fenced and indented
--- code, math blocks, HTML blocks, reference definitions, thematic breaks,
--- setext underlines, blank lines and table delimiter rows. Translated:
--- headings, paragraphs, list items, block quotes, footnote definitions and
--- every table cell, each as a unit of its own.
---
--- The result is a line template. Every input line has one entry: either the
--- literal string, or a list of parts (strings and `{ u = unit, k = line }`
--- references) from which the line is rebuilt. A unit remembers the original
--- text of each of its lines, so rendering it back unchanged reproduces the
--- source exactly -- that is the fallback for a unit whose translation failed
--- validation.
---
--- Markdown is parsed here line by line, not completely (no inline parsing,
--- no lazy-continuation corner cases): the parser errs on the side of
--- skipping. It does follow CommonMark where a wrong guess would make code
--- text: a fence ends with its quote or list item, a block in the first column
--- ends a list, a list item is indented at most three columns beyond the item
--- it sits in (more is indented code), an ordered list that does not start at
--- 1 cannot interrupt a paragraph, a table ends at a quote or a list item, and
--- a CR before the line end counts as white space. (Checked against the
--- previewer's renderer on random documents and a corpus of real ones.) A line taken for code that was prose stays German, a line taken
--- for prose that was code is caught by the placeholder and plausibility
--- checks. Hard line breaks (two trailing spaces or a backslash) end a unit,
--- since the reflow would otherwise move them.

local M = {}

---@class LanguageMdUnit
---@field id integer
---@field block "heading"|"para"|"item"|"quote"|"cell"|"footnote"
---@field text string                       -- the content, lines joined by one space
---@field orig string[]                     -- content of each line (without prefix/suffix)
---@field weights integer[]                 -- width of each original line
---@field lines integer
---@field guard_first boolean               -- line 1 is not preceded by a block marker of its own
---@field pad "blank"|"zwsp"                -- how a surplus line of a short translation looks

---@class LanguageMdBlock
---@field first integer
---@field last integer
---@field units integer[]

---@class LanguageMdSegmentation
---@field tpl table<integer, string|table>
---@field units LanguageMdUnit[]
---@field blocks LanguageMdBlock[]
---@field headings integer[]                -- unit ids of headings, in document order
---@field defs table<string, boolean>       -- normalised reference-definition labels
---@field refdefs integer[]                 -- lines holding a reference definition

local BLOCK_TAGS = {}
for name in
  ([[address article aside base basefont blockquote body caption center col colgroup dd details
  dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head
  header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p param
  section source summary table tbody td tfoot th thead title tr track ul]]):gmatch("%S+")
do
  BLOCK_TAGS[name] = true
end

-- U+200B, the invisible padding of a surplus line.
local ZWSP = "\226\128\139"

local RAW_TAGS = { pre = true, script = true, style = true, textarea = true }

---@internal
---@param s string
---@return string content, string suffix
local function trim_right(s)
  local content = s:match("^(.-)[ \t\r\f\v]*$")
  return content, s:sub(#content + 1)
end

---@internal
---@param line string
---@return boolean
local function is_blank(line)
  return line:match("^[ \t\r\f\v]*$") ~= nil
end

---@internal
---Strip leading block-quote markers.
---@param line string
---@return string prefix, integer depth, string rest
local function strip_quotes(line)
  local pfx, depth, rest = "", 0, line
  while true do
    local a, b, tail = rest:match("^( ? ? ?>)( ?)(.*)$")
    if not a then
      break
    end
    pfx = pfx .. a .. b
    depth = depth + 1
    rest = tail
  end
  return pfx, depth, rest
end

---@internal
---Width of the leading white space (a tab counts four).
---@param s string
---@return integer
local function indent_width(s)
  local w = 0
  for c in s:match("^[ \t]*"):gmatch(".") do
    w = w + (c == "\t" and 4 or 1)
  end
  return w
end

---@internal
---@param rest string
---@return string|nil ch, integer|nil len
local function fence_open(rest)
  local f = rest:match("^ *(```+)([^`]*)$")
  if f then
    return "`", #f
  end
  local t = rest:match("^ *(~~~+)")
  if t then
    return "~", #t
  end
  return nil
end

---@internal
---@param rest string
---@param ch string
---@param len integer
---@return boolean
local function fence_close(rest, ch, len)
  local f
  if ch == "`" then
    f = rest:match("^ *(```+)[ \t\r]*$")
  else
    f = rest:match("^ *(~~~+)[ \t\r]*$")
  end
  return f ~= nil and #f >= len
end

---@internal
---@param rest string
---@return boolean
local function is_hr(rest)
  local indent = #rest:match("^ *")
  if indent > 3 then
    return false
  end
  local s = rest:gsub("[ \t\r]", "")
  return #s >= 3 and (s:match("^%-+$") ~= nil or s:match("^%*+$") ~= nil or s:match("^_+$") ~= nil)
end

---@internal
---Start of an HTML block: kind of block and how it ends.
---@param rest string
---@param para_open boolean
---@return { kind: string, tag?: string }|nil
local function html_start(rest, para_open)
  local body = rest:match("^ ? ? ?(<.*)$")
  if not body then
    return nil
  end
  if body:sub(1, 4) == "<!--" then
    return { kind = "comment" }
  end
  if body:match("^<%?") then
    return { kind = "pi" }
  end
  if body:match("^<![%a]") then
    return { kind = "decl" }
  end
  local name = body:match("^</?(%a[%w-]*)")
  if not name then
    return nil
  end
  local lname = name:lower()
  local closing = body:sub(2, 2) == "/"
  local after = body:sub(#name + (closing and 3 or 2))
  if not closing and RAW_TAGS[lname] and (after == "" or after:match("^[ \t>]")) then
    return { kind = "raw", tag = lname }
  end
  if BLOCK_TAGS[lname] and (after == "" or after:match("^[ \t>/]")) then
    return { kind = "blank" }
  end
  if not para_open and body:match("^</?%a[%w-]*[^<>]*>[ \t\r]*$") then
    return { kind = "blank" }
  end
  return nil
end

---@internal
---Does `line` end the HTML block `h`?
---@param h table
---@param line string
---@return boolean
local function html_ends(h, line)
  if h.kind == "comment" then
    return line:find("-->", 1, true) ~= nil
  elseif h.kind == "pi" then
    return line:find("?>", 1, true) ~= nil
  elseif h.kind == "decl" then
    return line:find(">", 1, true) ~= nil
  elseif h.kind == "raw" then
    return line:lower():find("</" .. h.tag, 1, true) ~= nil
  end
  return false
end

---@internal
---Split a table row at its unescaped pipes.
---@param s string
---@return integer[] pipes
local function pipes(s)
  local out, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "|" then
      out[#out + 1] = i
    end
    i = i + 1
  end
  return out
end

---@internal
---Is `line` the delimiter row of a table (`|---|:--:|`)?
---@param line string
---@return boolean
local function is_delimiter(line)
  if not line:find("|", 1, true) or not line:find("-", 1, true) then
    return false
  end
  local s = line:gsub("^ ? ? ?>? ?", ""):gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^|", ""):gsub("|$", "")
  if s == "" then
    return false
  end
  for cell in (s .. "|"):gmatch("([^|]*)|") do
    if not cell:match("^%s*:?%-+:?%s*$") then
      return false
    end
  end
  return true
end

---Segment a document.
---@param lines string[]
---@return LanguageMdSegmentation
function M.segment(lines)
  local n = #lines
  ---@type LanguageMdSegmentation
  local seg = { tpl = {}, units = {}, blocks = {}, headings = {}, defs = {}, refdefs = {} }
  local tpl, units, blocks = seg.tpl, seg.units, seg.blocks

  local para ---@type table|nil
  local fence, html, math_open, in_table
  local in_list = false
  local prev_qdepth = 0
  local items = {} ---@type integer[] -- content indents of the open list items, innermost last

  ---Does a list item with `iw` columns of indent belong to the container it is in? Up to
  ---three columns beyond the content of the item it would be nested in (the root has
  ---none): four make it indented code (outside of an item) or plain text.
  ---@param iw integer
  ---@return boolean
  local function item_fits(iw)
    local c = 0
    if in_list then
      for _, v in ipairs(items) do
        if v <= iw then
          c = v
        end
      end
    end
    return iw - c <= 3
  end

  ---An item opens: the ones at its level or deeper end, it becomes the innermost.
  ---@param iw integer
  ---@param cind integer  -- the content indent of the new item
  local function open_item(iw, cind)
    if not in_list then
      items = {}
    end
    while #items > 0 and items[#items] > iw do
      items[#items] = nil
    end
    items[#items + 1] = cind
  end
  local item_cind = 0 -- content indent of the latest list item
  local list_q = 0 -- quote depth of the list that `in_list` stands for
  local no_close_after ---@type integer|nil -- no `$$` below this line: a `$$` opens no block

  ---@param u table
  ---@return LanguageMdUnit
  local function add_unit(u)
    units[#units + 1] = u
    u.id = #units
    return u
  end

  local function close_para()
    local p = para
    if not p then
      return
    end
    para = nil
    local runs, cur = {}, {}
    for i, ln in ipairs(p.lines) do
      cur[#cur + 1] = ln
      if ln.hard and i < #p.lines then
        runs[#runs + 1] = cur
        cur = {}
      end
    end
    runs[#runs + 1] = cur
    local blk = { first = p.lines[1].L, last = p.lines[#p.lines].L, units = {} }
    for ri, run in ipairs(runs) do
      local u = add_unit({
        block = p.kind,
        lines = #run,
        orig = {},
        weights = {},
        -- A setext heading has no marker in front of its first line: guard it like text.
        guard_first = p.kind ~= "heading" or p.setext == true,
        pad = (
          p.kind == "para"
          and not p.listctx
          and p.qdepth == 0
          and ri == #runs
          and not run[#run].hard
        )
            and "blank"
          or "zwsp",
      })
      for k, ln in ipairs(run) do
        u.orig[k] = ln.content
        u.weights[k] = math.max(#ln.content, 1)
        tpl[ln.L] = { ln.prefix, { u = u.id, k = k }, ln.suffix }
      end
      u.text = table.concat(u.orig, " ")
      blk.units[#blk.units + 1] = u.id
      if p.kind == "heading" then
        seg.headings[#seg.headings + 1] = u.id
      end
    end
    blocks[#blocks + 1] = blk
  end

  ---@param L integer
  ---@param prefix string
  ---@param body string
  ---@return table
  local function make_line(L, prefix, body)
    local content, suffix = trim_right(body)
    local hard = false
    local bs = #content:match("\\*$")
    if bs % 2 == 1 and #content > 1 then
      hard = true
      content = content:sub(1, -2)
      suffix = "\\" .. suffix
    elseif #suffix >= 2 and suffix:sub(1, 2) == "  " then
      hard = true
    end
    return { L = L, prefix = prefix, content = content, suffix = suffix, hard = hard }
  end

  ---@param L integer
  ---@param kind string
  ---@param prefix string
  ---@param body string
  ---@param qdepth integer
  local function open_para(L, kind, prefix, body, qdepth)
    para =
      { kind = kind, lines = { make_line(L, prefix, body) }, qdepth = qdepth, listctx = in_list }
  end

  ---Literal line, ends whatever paragraph or table was open.
  ---@param L integer
  local function literal(L)
    close_para()
    in_table = nil
    tpl[L] = lines[L]
  end

  ---A heading of a single line.
  local function heading_unit(L, prefix, content, suffix)
    local u = add_unit({
      block = "heading",
      lines = 1,
      orig = { content },
      weights = { math.max(#content, 1) },
      guard_first = false,
      pad = "zwsp",
      text = content,
    })
    tpl[L] = { prefix, { u = u.id, k = 1 }, suffix }
    blocks[#blocks + 1] = { first = L, last = L, units = { u.id } }
    seg.headings[#seg.headings + 1] = u.id
  end

  ---A table row: every non-empty cell is a unit.
  local function table_row(L, qpfx, rest)
    local ps = pipes(rest)
    local parts, ids = { qpfx }, {}
    local from = 1
    local function cell(a, b)
      local seg_text = rest:sub(a, b)
      local lead, body = seg_text:match("^([ \t]*)(.*)$")
      local content, tail = trim_right(body)
      parts[#parts + 1] = lead
      if content ~= "" then
        local u = add_unit({
          block = "cell",
          lines = 1,
          orig = { content },
          weights = { math.max(#content, 1) },
          -- The first cell of a row without a leading pipe starts the line itself.
          guard_first = from == 1,
          pad = "zwsp",
          text = content,
        })
        parts[#parts + 1] = { u = u.id, k = 1 }
        ids[#ids + 1] = u.id
      end
      parts[#parts + 1] = tail
    end
    for _, p in ipairs(ps) do
      cell(from, p - 1)
      parts[#parts + 1] = "|"
      from = p + 1
    end
    cell(from, #rest)
    tpl[L] = parts
    if #ids > 0 then
      blocks[#blocks + 1] = { first = L, last = L, units = ids }
    else
      tpl[L] = lines[L]
    end
  end

  local L = 1

  -- Front matter: `---` ... `---`/`...`, or `+++` ... `+++`, at the very top.
  do
    local delim = lines[1]
      and (lines[1]:match("^(%-%-%-)[ \t\r]*$") or lines[1]:match("^(%+%+%+)[ \t\r]*$"))
    if delim then
      for j = 2, n do
        local l = lines[j]
        if
          l:match("^" .. delim:gsub("%p", "%%%0") .. "[ \t\r]*$")
          or (delim == "---" and l:match("^%.%.%.[ \t\r]*$"))
        then
          -- `---` is front matter only when it opens with a `key:` line (the
          -- previewer's rule): a horizontal rule at the top of a document, with
          -- another one far below, must not make the text in between "metadata".
          local first
          for i = 2, j - 1 do
            if not is_blank(lines[i]) then
              first = lines[i]
              break
            end
          end
          if delim == "---" and not (first and first:match("^[^%s:][^%s:]*:")) then
            break
          end
          for i = 1, j do
            tpl[i] = lines[i]
          end
          L = j + 1
          break
        end
      end
    end
  end

  while L <= n do
    local line = lines[L]
    repeat
      if fence then
        local _, qd, frest = strip_quotes(line)
        -- A fence lives inside its container: a line outside of it (fewer `>`, or
        -- less indented than the list item's content) ends the fence, as it ends
        -- the container, and is read as a line of its own.
        if
          qd < fence.qdepth
          or (fence.cindent > 0 and not is_blank(frest) and indent_width(frest) < fence.cindent)
        then
          fence = nil
        else
          tpl[L] = line
          -- Only a closing line of the fence's own quote depth closes it.
          if qd == fence.qdepth and fence_close(frest, fence.ch, fence.len) then
            fence = nil
          end
          break
        end
      end
      if math_open then
        tpl[L] = line
        if line:find("$$", 1, true) then
          math_open = nil
        end
        break
      end
      if html then
        if html.kind == "blank" and is_blank(line) then
          html = nil
        elseif html.kind ~= "blank" and html_ends(html, line) then
          html = nil
        end
        tpl[L] = line
        break
      end

      local qpfx, qdepth, rest = strip_quotes(line)
      if qdepth > 0 and prev_qdepth == 0 and #qpfx:match("^ *") < 2 then
        in_list = false -- a quote that starts in the first columns ends the list
      end
      prev_qdepth = qdepth
      -- A list inside a quote ends with the quote: at a blank line, or at a line that
      -- starts something of its own, with fewer `>` (text is a lazy continuation).
      if in_list and qdepth < list_q and (is_blank(rest) or not para) then
        in_list = false
      end
      -- A block that starts in the first columns ends a list: what follows (an
      -- indented code block, say) is no longer a continuation of an item.
      local function leave_list()
        if qdepth ~= list_q or indent_width(rest) < math.max(item_cind, 2) then
          in_list = false
        end
      end

      if is_blank(rest) then
        literal(L)
        break
      end

      -- Fenced code.
      local fch, flen = fence_open(rest)
      if fch then
        literal(L)
        leave_list()
        fence = {
          ch = fch,
          len = flen,
          qdepth = qdepth,
          -- Inside a list item (indented to its content) the fence ends with the item.
          cindent = (in_list and list_q == qdepth and indent_width(rest) >= item_cind)
              and item_cind
            or 0,
        }
        break
      end

      -- Math block.
      if rest:match("^ *%$%$") then
        local first = rest:find("$$", 1, true)
        local closed = rest:find("$$", first + 2, true) ~= nil
        local later = false
        -- A block that opens here must be closed somewhere below: a stray `$$` (a
        -- price, say) is text and must not turn the rest of the document into math.
        if not closed and not (no_close_after and L >= no_close_after) then
          for j = L + 1, n do
            if lines[j]:find("$$", 1, true) then
              later = true
              break
            end
          end
          if not later then
            no_close_after = L
          end
        end
        if closed or later then
          literal(L)
          leave_list()
          math_open = later or nil
          break
        end
      end

      -- HTML block.
      local h = html_start(rest, para ~= nil)
      if h then
        literal(L)
        leave_list()
        if h.kind == "blank" or not html_ends(h, rest:sub(2)) then
          html = h
        end
        break
      end

      -- Setext underline: turns the paragraph above into a heading.
      if
        para
        and para.kind == "para"
        and (rest:match("^ ? ? ?=+[ \t\r]*$") or rest:match("^ ? ? ?%-+[ \t\r]*$"))
      then
        para.kind = "heading"
        para.setext = true
        close_para()
        tpl[L] = line
        break
      end

      if is_hr(rest) then
        literal(L)
        in_list = false
        break
      end

      -- ATX heading.
      local indent, hashes, hsp, htext = rest:match("^( ? ? ?)(#+)([ \t]+)(.*)$")
      if hashes and #hashes <= 6 then
        close_para()
        in_table = nil
        in_list = false
        local body = htext:match("^(.-)[ \t]+#+[ \t\r]*$")
        local content, suffix
        if body then
          content, suffix = trim_right(body)
          suffix = suffix .. htext:sub(#body + 1)
        else
          content, suffix = trim_right(htext)
        end
        if content == "" then
          tpl[L] = line
        else
          heading_unit(L, qpfx .. indent .. hashes .. hsp, content, suffix)
        end
        break
      end
      if rest:match("^ ? ? ?#+[ \t\r]*$") then
        literal(L)
        in_list = false
        break
      end

      -- Table: a header row followed by a delimiter row, then body rows. Another
      -- block (a quote, a list item) ends it.
      if
        in_table
        and (
          in_table.qdepth ~= qdepth
          or (
            in_table.seen_delim
            and (rest:match("^ ? ? ?[-*+][ \t]") or rest:match("^ ? ? ?%d+[.)][ \t]"))
          )
        )
      then
        in_table = nil
      end
      if in_table then
        if is_delimiter(line) and not in_table.seen_delim then
          in_table.seen_delim = true
          tpl[L] = line
          break
        end
        table_row(L, qpfx, rest)
        break
      end
      if rest:find("|", 1, true) and lines[L + 1] and is_delimiter(lines[L + 1]) then
        close_para()
        leave_list()
        in_table = { seen_delim = false, qdepth = qdepth }
        table_row(L, qpfx, rest)
        break
      end

      -- Reference / footnote definition.
      local rindent, caret, label, rtail = rest:match("^( ? ? ?)%[(%^?)([^%]]+)%]:(.*)$")
      if rindent and (caret == "^" or not para) then
        if caret == "^" then
          local sp, body = rtail:match("^([ \t]*)(.*)$")
          if not is_blank(body) then
            close_para()
            in_list = true
            list_q = qdepth
            item_cind = 4 -- a footnote continues with four spaces
            open_para(L, "footnote", qpfx .. rindent .. "[^" .. label .. "]:" .. sp, body, qdepth)
            break
          end
          literal(L)
          break
        end
        literal(L)
        leave_list()
        seg.defs[require("language.translate.markdown.mask")._norm_label(label)] = true
        seg.refdefs[#seg.refdefs + 1] = L
        local nxt = lines[L + 1]
        -- `[label]:` alone: the destination is on the next line. That line stays as it
        -- is: a translation that came out as one word would become the destination
        -- and swallow the paragraph. (A line that starts a block is none.)
        if
          is_blank(rtail)
          and nxt
          and nxt:match("^[ \t]*[^ \t\r#>|<`*+%-]")
          and not fence_open(nxt)
        then
          tpl[L + 1] = nxt
          L = L + 1
          nxt = lines[L + 1]
        end
        if nxt and nxt:match("^[ \t]+[\"'(]") then
          tpl[L + 1] = nxt
          L = L + 1
        end
        break
      end

      -- List item.
      local ind, marker, sp, body = rest:match("^([ \t]*)([-*+])([ \t]+)(.*)$")
      if not ind then
        ind, marker, sp, body = rest:match("^([ \t]*)(%d%d?%d?%d?%d?%d?%d?%d?%d?[.)])([ \t]+)(.*)$")
      end
      -- An ordered list may interrupt a paragraph only when it starts at 1.
      if
        ind
        and para
        and para.qdepth == qdepth
        and para.kind ~= "item"
        and para.kind ~= "footnote"
      then
        local num = marker:match("^(%d+)[.)]$")
        if num and tonumber(num) ~= 1 then
          ind = nil
        end
      end
      local iw = ind and indent_width(ind) or 0
      if
        not ind
        and (rest:match("^[ \t]*[-*+][ \t\r]*$") or rest:match("^[ \t]*%d+[.)][ \t\r]*$"))
      then
        -- A marker alone on its line: an empty item, or a setext underline for the
        -- paragraph above. Either way it is no text, and it stays where it is.
        local after_para = para ~= nil and para.kind ~= "item" and para.kind ~= "footnote"
        literal(L)
        if not after_para then
          -- No content indent: what follows a blank line is no part of the item.
          in_list, list_q, item_cind = true, qdepth, 0
        end
        break
      end
      -- Four columns of indent make a list item only inside another one; outside, it
      -- is an indented code block.
      if ind and item_fits(iw) and is_blank(body) then
        local after_para = para ~= nil and para.kind ~= "item" and para.kind ~= "footnote"
        literal(L)
        if not after_para then
          open_item(iw, iw + #marker + 1)
          in_list, list_q, item_cind = true, qdepth, 0
        end
        break
      end
      if ind and item_fits(iw) then
        close_para()
        open_item(iw, iw + #marker + (#sp > 4 and 1 or #sp))
        local task
        task, body = body:match("^(%[[ xX]%][ \t]+)(.*)$")
        if not task then
          task, body = "", rest:match("^[ \t]*[-*+%d.)]+[ \t]+(.*)$")
        end
        local bfch, bflen = fence_open(body)
        if bfch then
          literal(L)
          item_cind = iw + #marker + (#sp > 4 and 1 or #sp)
          fence = { ch = bfch, len = bflen, qdepth = qdepth, cindent = item_cind }
          in_list = true
          list_q = qdepth
          break
        end
        if is_blank(body) then
          literal(L)
          break
        end
        in_list = true
        list_q = qdepth
        item_cind = iw + #marker + (#sp > 4 and 1 or #sp)
        open_para(L, "item", qpfx .. ind .. marker .. sp .. task, body, qdepth)
        break
      end

      -- Plain text.
      local lead, text = rest:match("^([ \t]*)(.*)$")
      if para then
        if qdepth > para.qdepth then
          close_para()
          open_para(L, "quote", qpfx .. lead, text, qdepth)
        else
          para.lines[#para.lines + 1] = make_line(L, qpfx .. lead, text)
        end
        break
      end
      local lw = indent_width(lead)
      -- Text that is not indented to the item's content starts a paragraph of its own.
      if in_list and lw < math.max(item_cind, 2) then
        in_list = false
      end
      if not in_list and lw >= 4 then
        literal(L)
        break
      end
      -- Four columns beyond the item's content: an indented code block inside it.
      if in_list and lw >= item_cind + 4 then
        literal(L)
        break
      end
      local kind = qdepth > 0 and "quote" or (in_list and "item" or "para")
      open_para(L, kind, qpfx .. lead, text, qdepth)
    until true
    L = L + 1
  end
  close_para()

  for i = 1, n do
    if tpl[i] == nil then
      tpl[i] = lines[i]
    end
  end
  return seg
end

---Render lines `first..last` of the template. `content[u]` holds the lines of
---unit `u` (without prefix and suffix); a unit without an entry is rendered
---as it was in the source.
---@param seg LanguageMdSegmentation
---@param content table<integer, string[]>
---@param first? integer
---@param last? integer
---@return string[]
function M.render(seg, content, first, last)
  local out, n = {}, 0
  for L = first or 1, last or #seg.tpl do
    local t = seg.tpl[L]
    n = n + 1
    if type(t) == "string" then
      out[n] = t
    else
      local buf = {}
      for i, part in ipairs(t) do
        if type(part) == "string" then
          buf[i] = part
        else
          local c = content[part.u]
          if c then
            local v = c[part.k]
            if v == "" and seg.units[part.u].pad == "zwsp" then
              v = ZWSP
            end
            buf[i] = v
          else
            buf[i] = seg.units[part.u].orig[part.k]
          end
        end
      end
      out[n] = table.concat(buf)
    end
  end
  return out
end

return M
