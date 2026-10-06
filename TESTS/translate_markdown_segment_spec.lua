-- TESTS/translate_markdown_segment_spec.lua -- translate/markdown/segment.lua:
-- what is never translated (front matter, fences, HTML, reference definitions,
-- code), what is a unit (headings, paragraphs, items, quotes, table cells), and
-- the round trip: rendering a segmentation unchanged reproduces the source.

return function(H)
  local segment = require("language.translate.markdown.segment")
  local helpers = dofile(vim.fn.getcwd() .. "/TESTS/markdown_helpers.lua")

  ---@param lines string[]
  ---@return LanguageMdSegmentation
  local function seg_of(lines)
    return segment.segment(lines)
  end

  local function texts(seg)
    local out = {}
    for _, u in ipairs(seg.units) do
      out[#out + 1] = u.text
    end
    return out
  end

  local function literal(seg, L)
    return type(seg.tpl[L]) == "string"
  end

  -- identity on the fixtures: every line has a template, rendering reproduces the input
  for _, name in ipairs({ "readme_de.md", "edge_de.md" }) do
    local lines = helpers.fixture(name)
    local seg = seg_of(lines)
    for L = 1, #lines do
      H.ok(seg.tpl[L] ~= nil, name .. ": line " .. L .. " has a template")
    end
    local out = segment.render(seg, {})
    H.eq(#out, #lines, name .. ": render keeps the line count")
    for L = 1, #lines do
      H.eq(out[L], lines[L], name .. ": line " .. L .. " is reproduced byte for byte")
    end
  end

  -- front matter, fences, HTML and definitions are literal ---------------------
  do
    local lines = helpers.fixture("readme_de.md")
    local seg = seg_of(lines)
    for L = 1, 4 do
      H.ok(literal(seg, L), "front matter line " .. L .. " is literal")
    end
    local fences = helpers.fence_set(lines)
    local seen = 0
    for L in pairs(fences) do
      seen = seen + 1
      H.ok(literal(seg, L), "fence line " .. L .. " is literal")
    end
    H.ok(seen >= 5, "the fixture has a fence to check")
    for L, l in ipairs(lines) do
      if l:match("^<") or l:match("^%[[^%]^]+%]:") or l:match("^    eingeruec") or l == "---" then
        H.ok(literal(seg, L), ("line %d (%s) is literal"):format(L, l))
      end
    end
    H.ok(seg.defs["doku"] and seg.defs["zurueck"], "reference definition labels are collected")
    H.eq(#seg.refdefs, 2, "and their lines")
  end

  -- units of a small document ------------------------------------------------------
  do
    local seg = seg_of({
      "# Titel",
      "",
      "Erste Zeile",
      "zweite Zeile.",
      "",
      "- Punkt",
      "  mit Folgezeile",
      "",
      "> Zitat",
      "",
      "| A | B |",
      "|---|---|",
      "| x | y |",
    })
    local t = texts(seg)
    H.eq(t[1], "Titel", "heading text without its marker")
    H.eq(t[2], "Erste Zeile zweite Zeile.", "paragraph lines joined by one space")
    H.eq(t[3], "Punkt mit Folgezeile", "list item with its continuation line")
    H.eq(t[4], "Zitat", "quote text without its marker")
    H.eq(t[5] .. t[6] .. t[7] .. t[8], "ABxy", "every table cell is a unit")
    H.eq(seg.units[1].block, "heading", "block kinds")
    H.eq(seg.units[2].block, "para")
    H.eq(seg.units[3].block, "item")
    H.eq(seg.units[4].block, "quote")
    H.eq(seg.units[5].block, "cell")
    H.eq(seg.units[2].lines, 2, "a unit knows its line count")
    H.eq(seg.units[2].weights[1], #"Erste Zeile", "and the width of each line")
    H.ok(literal(seg, 12), "the table delimiter row is literal")
    H.eq(#seg.headings, 1, "headings are listed")
    H.eq(seg.units[2].pad, "blank", "a plain paragraph pads with blank lines")
    H.eq(seg.units[3].pad, "zwsp", "an item pads with an invisible line, never a blank one")
    H.ok(seg.units[2].guard_first and not seg.units[1].guard_first, "headings do not guard line 1")
  end

  -- prefixes are kept apart from the content ----------------------------------------
  do
    local seg = seg_of({ "  - [ ] Aufgabe offen", "> > tief", "## Titel ##", "1) Eins" })
    local t = texts(seg)
    H.eq(t[1], "Aufgabe offen", "a task checkbox belongs to the prefix")
    H.eq(t[2], "tief", "nested quote markers belong to the prefix")
    H.eq(t[3], "Titel", "the closing hashes of an ATX heading are not text")
    H.eq(t[4], "Eins", "an ordered marker with ) is a marker")
    local out = segment.render(seg, { [3] = { "Title" } })
    H.eq(out[3], "## Title ##", "the closing hashes survive a changed heading")
    H.eq(out[1], "  - [ ] Aufgabe offen", "units without content render as in the source")
  end

  -- setext heading: the underline is literal -----------------------------------------
  do
    local seg = seg_of({ "Ueberschrift", "============", "", "Absatz", "---" })
    H.eq(seg.units[1].block, "heading", "paragraph + === is a heading")
    H.ok(literal(seg, 2), "the underline is literal")
    H.eq(seg.units[2].block, "heading", "paragraph + --- is a heading, not a rule")
    H.eq(#seg.headings, 2)
  end

  -- hard line break ends a unit ------------------------------------------------------
  do
    local seg = seg_of({ "Eins  ", "zwei\\", "drei" })
    H.eq(#seg.units, 3, "each hard break splits the paragraph")
    local out = segment.render(seg, { [1] = { "One" }, [2] = { "two" }, [3] = { "three" } })
    H.eq(out[1], "One  ", "two trailing spaces are kept")
    H.eq(out[2], "two\\", "a trailing backslash is kept")
    H.eq(out[3], "three")
    H.eq(seg.units[3].pad, "blank", "only the last unit of a paragraph pads with blank lines")
    H.eq(seg.units[1].pad, "zwsp")
  end

  -- code is never text -----------------------------------------------------------------
  do
    local seg = seg_of({
      "Absatz",
      "",
      "    Einrueckung",
      "",
      "```",
      "# kein Heading",
      "```",
      "",
      "~~~~",
      "```",
      "~~~~",
      "",
      "$$",
      "x",
      "$$",
      "",
      "<div>",
      "text im Block",
      "",
      "danach",
    })
    local t = texts(seg)
    H.eq(table.concat(t, "|"), "Absatz|danach", "only prose becomes a unit")
    H.ok(literal(seg, 3) and literal(seg, 6) and literal(seg, 10) and literal(seg, 14))
    H.ok(literal(seg, 17) and literal(seg, 18), "an HTML block lasts until the blank line")
  end

  -- ambiguous lines are unit boundaries or literals, never text a reflow could move ----------
  do
    local seg = seg_of({ "Absatz", "[^1]: Notiz", "- Punkt", "  -  ", "-", "2." })
    H.eq(
      table.concat(texts(seg), "|"),
      "Absatz|Notiz|Punkt",
      "a footnote definition interrupts a paragraph"
    )
    H.ok(
      literal(seg, 4) and literal(seg, 5) and literal(seg, 6),
      "a marker without content is literal"
    )
    local out = segment.render(seg, { [1] = { "Para" }, [2] = { "Note" }, [3] = { "Item" } })
    H.eq(table.concat(out, "|"), "Para|[^1]: Note|- Item|  -  |-|2.")
  end

  -- an unclosed fence runs to the end ---------------------------------------------------
  do
    local seg = seg_of({ "```", "a", "b" })
    H.eq(#seg.units, 0, "an unclosed fence swallows the rest")
  end

  -- tables: pipes and escaped pipes -----------------------------------------------------
  do
    local seg = seg_of({ "a | b", "--|--", "x \\| y | z" })
    local t = texts(seg)
    H.eq(table.concat(t, ","), "a,b,x \\| y,z", "an escaped pipe does not split the cell")
    local out = segment.render(seg, { [3] = { "X" } })
    H.eq(out[1], "a | b", "pipes and cell padding are kept")
    H.eq(out[3], "X | z", "the replaced cell sits between the original pipes")
    H.eq(segment.render(seg, {})[3], "x \\| y | z")
  end

  -- front matter without a closing line is just text ------------------------------------
  do
    local seg = seg_of({ "---", "kein Ende" })
    H.ok(#seg.units >= 1, "an unclosed --- block is not front matter")
  end

  -- empty input -----------------------------------------------------------------------------
  do
    local seg = seg_of({})
    H.eq(#seg.units, 0)
    H.eq(#segment.render(seg, {}), 0)
  end

  -- a setext heading has no marker in front of its first line: guard it like text -----------
  do
    local seg = seg_of({ "Titel", "=====" })
    H.eq(seg.units[1].block, "heading")
    H.eq(seg.units[1].guard_first, true, "a translation that starts with `- ` would make a list")
    H.eq(seg_of({ "# Titel" }).units[1].guard_first, false, "an ATX heading has its `#` in front")
  end

  -- a block in the first column ends a list: the indented line after it is code -----------
  do
    local closers = {
      { "<div>", "</div>" },
      { "```", "x", "```" },
      { "$$", "x", "$$" },
      { "#" },
      { "> Zitat" },
      { "[ref]: /x" },
      { "| a | b |", "|---|---|" },
    }
    for _, closer in ipairs(closers) do
      local doc = { "- Punkt", "" }
      vim.list_extend(doc, closer)
      vim.list_extend(doc, { "", "    code" })
      local seg = seg_of(doc)
      H.ok(literal(seg, #doc), "an indented line after " .. closer[1] .. " is code, not item text")
    end
    local seg = seg_of({ "- Punkt", "", "    Folge" })
    H.falsy(literal(seg, 3), "inside the list the same line is a continuation of the item")
  end

  -- a fence lives inside its container: a line outside of it ends the fence ------------------
  do
    local seg = seg_of({ "- item", "  ```", "  code", "text danach" })
    H.ok(literal(seg, 3), "the code of a fence in an item is literal")
    H.falsy(literal(seg, 4), "a line left of the item's content ends the fence")
    seg = seg_of({ "- ```", "  code", "text danach" })
    H.falsy(literal(seg, 3), "same for a fence on the marker line")
    seg = seg_of({ "> ```", "> code", "text danach" })
    H.falsy(literal(seg, 3), "and for a fence in a quote, once the quote ends")
    seg = seg_of({ "```", "> ```", "x", "```", "y" })
    H.ok(literal(seg, 3), "a quoted fence line does not close a fence outside of the quote")
    H.falsy(literal(seg, 5))
  end

  -- a table ends where a quote or a list begins -------------------------------------------------
  do
    local seg = seg_of({ "| a | b |", "|---|---|", "| c | d |", "> Zitat" })
    H.eq(seg.units[#seg.units].block, "quote")
    seg = seg_of({ "| a | b |", "|---|---|", "| c | d |", "- Punkt" })
    H.eq(seg.units[#seg.units].block, "item")
    seg = seg_of({ "a | b", "---|---" })
    H.eq(seg.units[1].guard_first, true, "a cell with no pipe in front starts the line")
    H.eq(seg.units[2].guard_first, false)
  end

  -- front matter opens with a `key:` line, as in the previewer --------------------------------
  do
    local seg = seg_of({ "---", "Text", "", "viel Text", "---", "Text" })
    H.falsy(literal(seg, 2), "a rule, text and a rule is no metadata")
    seg = seg_of({ "---", "title: x", "---", "Text" })
    H.ok(literal(seg, 2) and literal(seg, 3))
  end

  -- a `$$` that nothing closes is text ----------------------------------------------------------------
  do
    local seg = seg_of({ "Preis", "", "$$ nur Text" })
    H.falsy(literal(seg, 3), "no closing line below: no math block")
    seg = seg_of({ "$$", "x", "$$", "Text" })
    H.ok(literal(seg, 1) and literal(seg, 2) and literal(seg, 3))
    H.falsy(literal(seg, 4))
  end

  -- list and code edge cases ---------------------------------------------------------------------------------
  do
    H.ok(literal(seg_of({ "    - c" }), 1), "four spaces outside of a list: indented code")
    local seg = seg_of({ "Absatz", "10. zehn" })
    H.eq(#seg.units, 1, "an ordered list that does not start at 1 cannot interrupt a paragraph")
    H.eq(#seg_of({ "Absatz", "1. eins" }).units, 2, "one that starts at 1 can")
    seg = seg_of({ "> Zitat", "10. zehn" })
    H.eq(#seg.units, 2, "but a quote's paragraph is another container")
    H.eq(#seg_of({ "- a", "\t- b" }).units, 2, "a tab-indented line is a nested item")
    H.ok(literal(seg_of({ "a\r", "\r", "*\r" }), 3), "a marker alone, with a CR behind it")
    H.ok(literal(seg_of({ "a\r", "\r", "1.\r" }), 3))
    seg = seg_of({ "[ref]:", "/x", "Text" })
    H.ok(literal(seg, 2), "the destination on the line after `[label]:` stays as it is")
    seg = seg_of({ "[ref]:", "# Titel" })
    H.falsy(literal(seg, 2), "a heading is no destination")
    seg = seg_of({ "- leer", "-", "", "    code" })
    H.ok(literal(seg, 4), "an empty item has no content for an indented line to continue")
  end

  -- a hard break inside a code span is part of the code ------------------------------------------
  do
    local seg = seg_of({ "Text `a\\", "b` mehr" })
    H.eq(#seg.units, 1, "a backslash at the end of a line inside a span is no break")
    H.eq(seg.units[1].orig[1], "Text `a\\", "and it stays in the content")
    H.eq(#seg_of({ "Text `a  ", "b` mehr" }).units, 1, "neither are two spaces")
    H.eq(#seg_of({ "Text a\\", "b mehr" }).units, 2, "outside of a span it still is")
    H.eq(#seg_of({ "Text `a\\", "b mehr" }).units, 2, "a backtick with no partner is text")
    H.eq(#seg_of({ "`a` und `b\\", "c`" }).units, 1, "spans are paired from the left")
    H.eq(#seg_of({ "Text \\`a\\", "b` mehr" }).units, 2, "an escaped backtick opens nothing")
  end

  -- fuzz: any mixture of fragments round-trips and keeps its line count ------------------------
  do
    math.randomseed(20261006)
    local pool = {
      "# Titel",
      "Text mit `code` und [Link](#titel).",
      "",
      "- Punkt",
      "  Folge",
      "1. Eins",
      "> Zitat",
      "```",
      "~~~",
      "| a | b |",
      "|---|---|",
      "<div>",
      "<!-- c -->",
      "---",
      "===",
      "[ref]: /x",
      "    code",
      "$$",
      "Zeile mit Umbruch  ",
      "Backslash\\",
      "***",
      "\t- tab",
    }
    for iter = 1, 300 do
      local doc = {}
      for i = 1, math.random(1, 25) do
        doc[i] = pool[math.random(#pool)]
      end
      local seg = seg_of(doc)
      local out = segment.render(seg, {})
      H.eq(#out, #doc, "fuzz " .. iter .. ": line count")
      for i = 1, #doc do
        if out[i] ~= doc[i] then
          error(("fuzz %d line %d: %q became %q"):format(iter, i, doc[i], out[i]))
        end
      end
    end
  end
  -- Container rules, found against the previewer's renderer (independent review) ----
  do
    local function units_of(lines)
      return texts(seg_of(lines))
    end

    -- A closing fence indented four columns is text of the code block, not its end.
    local s = seg_of({ "- item", "", "    ```", "    code", "    ```", "", "Absatz" })
    H.ok(literal(s, 4), "a fence in an item: its code stays literal")
    H.eq(#s.units, 2, "...and only the item and the paragraph are units")
    s = seg_of({ "```text", "code", "    ```", "noch Code", "```", "", "Absatz" })
    H.ok(literal(s, 4), "an over-indented closing fence does not close")
    H.ok(literal(s, 3), "...so the lines behind it are still code")
    H.eq(units_of({ "```text", "code", "    ```", "noch Code", "```", "", "Absatz" })[1], "Absatz")

    -- A fence indented four columns is indented code: no fence opens, nothing is hidden.
    s = seg_of({ "    ```lua", "    x", "    ```", "", "Absatz eins", "", "Absatz zwei" })
    H.eq(
      table.concat(units_of({ "    ```lua", "    x", "    ```", "", "Absatz eins" }), "|"),
      "Absatz eins",
      "an indented fence line opens no fence (the text behind it is still text)"
    )
    H.eq(#s.units, 2)
    s = seg_of({ "    ```lua", "Text danach", "", "Mehr" })
    H.eq(#s.units, 2, "...also when no blank line follows")

    -- A tab-indented fence inside a list item is a fence of that item.
    s = seg_of({ "+ Ubuntu:", "\t```bash", "\tsudo apt install x", "\t```", "Danach" })
    H.ok(
      literal(s, 2) and literal(s, 3) and literal(s, 4),
      "a tab-indented fence in an item is code"
    )
    H.eq(
      units_of({ "+ Ubuntu:", "\t```bash", "\tsudo apt install x", "\t```", "Danach" })[2],
      "Danach"
    )

    -- `>` inside a fence is text, wherever it stands (conflict markers, prompts).
    s = seg_of({
      "* Beispiel:",
      "",
      "  ```diff",
      "  <<<<<<< HEAD",
      "  >>>>>>> feature",
      "  ```",
      "",
      "Danach",
    })
    H.ok(literal(s, 5), "a `>` line inside a fence of an item stays code")
    H.eq(units_of({ "* Beispiel:", "", "  ```diff", "  >>>>>>> feature", "  ```" })[2], nil)

    -- A table does not start at, and ends before, an indented line.
    s = seg_of({ "    | a | b |", "    |---|---|", "    | c | d |", "", "Text" })
    H.eq(#s.units, 1, "an indented table is code, not a table")
    s = seg_of({ "| a | b |", "|---|---|", "| c | d |", "    code Zeile", "", "Text" })
    H.ok(literal(s, 4), "an indented line after table rows is code, no row")

    -- Text indented to an outer item belongs to that item: the next marker is an item.
    s = seg_of({
      "2. Zwei",
      "   - innen",
      "",
      "   Weiter im Absatz",
      "3. Drei",
      "4. Vier",
    })
    local t = texts(s)
    H.eq(t[#t - 1], "Drei", "a list item after text of an outer item is an item of its own")
    H.eq(t[#t], "Vier")
  end

  -- Linear time on one long line ---------------------------------------------------------
  do
    local function seconds(lines)
      local t0 = vim.uv.hrtime()
      local s = seg_of(lines)
      H.eq(#segment.render(s, {}), #lines)
      return (vim.uv.hrtime() - t0) / 1e9
    end
    local n = 60000
    local t = seconds({ "a" .. string.rep(" ", n) .. "b" })
    H.ok(t < 2, ("a run of spaces inside a line (%.2f s)"):format(t))
    t = seconds({ string.rep("\\", n) .. "x" })
    H.ok(t < 2, ("a run of backslashes (%.2f s)"):format(t))
    t = seconds({ string.rep("`a ", n / 3) })
    H.ok(t < 2, ("many backtick runs (%.2f s)"):format(t))
    t = seconds({ "# " .. string.rep(" ", n) .. "x" .. string.rep(" ", n) })
    H.ok(t < 2, ("a heading with long runs of spaces (%.2f s)"):format(t))
    t = seconds({ "| a | b |", "|---|---|", "| " .. string.rep(" ", n) .. " | x |" })
    H.ok(t < 2, ("a table cell with a long run of spaces (%.2f s)"):format(t))
  end
end
