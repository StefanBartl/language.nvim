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

  -- found with scripts/markdown_fuzz.lua against the previewer's renderer ---------------------------
  do
    local seg = seg_of({ "1.     code" })
    H.ok(
      literal(seg, 1),
      "five columns behind the marker: the item starts with an indented code block"
    )
    H.falsy(
      literal(seg_of({ "1.    text" }), 1),
      "four columns behind it are still the item's text"
    )
    H.ok(literal(seg_of({ "-     code" }), 1), "the same for a bullet")
    seg = seg_of({ "- item", ">     code" })
    H.ok(
      literal(seg, 2),
      "a quote that starts behind a list item judges its first line on its own: indented code"
    )
    H.eq(
      #seg_of({ "> 1. <div>", string.char(9) .. "2) two" }).units,
      0,
      "an HTML block behind an item marker is literal, and so is the tab-indented line after it"
    )
    H.eq(#seg_of({ "- <div>", "  two words here" }).units, 0, "its next lines too")
    seg = seg_of({ "- [ref]: /x" })
    H.ok(literal(seg, 1), "a link reference definition behind a list marker is a definition")
    seg = seg_of({ "- word word word", "  ===" })
    H.ok(literal(seg, 2), "the underline of a setext heading inside an item stays as it is")
    H.eq(#seg.units, 1, "and the text above it is one unit")
    seg = seg_of({ "> quote text here", "> ===" })
    H.ok(literal(seg, 2), "the same inside a quote")
    H.falsy(
      literal(seg_of({ "- item", "===" }), 1),
      "an underline that is not indented to the item is no part of it"
    )
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
    -- A tag-like line: the name is not matched once per byte of it.
    t = seconds({ "<" .. string.rep("a", n) })
    H.ok(t < 2, ("a `<` and a long name without a `>` (%.2f s)"):format(t))
    t = seconds({ "<" .. string.rep("a", n) .. ">x" })
    H.ok(t < 2, ("a long tag name with text behind the `>` (%.2f s)"):format(t))
    t = seconds({ "<a " .. string.rep("b", n) })
    H.ok(t < 2, ("a tag whose attributes never end (%.2f s)"):format(t))
  end

  -- A tag on a line of its own is an HTML block (nothing to translate); text is not ------------
  do
    local function units(line)
      return #seg_of({ line }).units
    end
    H.eq(units("<span>"), 0, "a complete tag on its own line")
    H.eq(units("</span>  "), 0, "a closing tag, white space behind it")
    H.eq(units('<a href="x" class="y">'), 0, "a tag with attributes")
    H.eq(units("<span> Text"), 1, "text behind the tag")
    H.eq(units("<span"), 1, "a tag that is not closed")
    H.eq(units("<a <b>"), 1, "a `<` inside the tag")
    H.eq(units("<1>"), 1, "a tag name starts with a letter")
  end

  -- An HTML block behind a list marker ends with the item ------------------------------------
  do
    local function units(lines)
      return #seg_of(lines).units
    end
    H.eq(units({ "- <div>", "text" }), 1, "a line that is not indented to the item is a paragraph")
    H.eq(units({ "- <div>", "- item" }), 1, "the next item is an item, not part of the block")
    H.eq(
      units({ "- <div>", "  inner", "text" }),
      1,
      "an indented line stays in the block, the next one does not"
    )
    H.eq(units({ "- <div>", "  inner", "", "para" }), 1, "a blank line ends the block as before")
    H.eq(units({ "- <div>", "  inner" }), 0, "an indented line is part of the block")
  end

  -- The column of an item inside a quote counts from the start of the line -------------------
  do
    local tab = string.char(9)
    local function units(line)
      return #seg_of({ line }).units
    end
    H.eq(
      units("> -" .. tab .. "  code"),
      1,
      "in a quote the tab stop is two columns further: 3 columns, text"
    )
    H.eq(
      units("-" .. tab .. "  code"),
      0,
      "at the start of the line the same gap is 5 columns: code"
    )
  end

  -- The containers are a stack (CommonMark): what continues, what is lazy, what ends -----------
  do
    local function units(lines)
      return #seg_of(lines).units
    end
    local seg = seg_of({ "- a", "lazy" })
    H.eq(#seg.units, 1, "a line without indent continues the paragraph of the item (lazy)")
    H.eq(seg.units[1].lines, 2)
    seg = seg_of({ "- a", "", "lazy" })
    H.eq(
      seg.units[2].block,
      "para",
      "after a blank line it is a paragraph of its own, outside of the item"
    )
    seg = seg_of({ "- a", "", "  b" })
    H.eq(seg.units[2].block, "item", "an indented line after a blank one is part of the item")
    seg = seg_of({ "-", "", "  b" })
    H.eq(
      seg.units[1].block,
      "para",
      "an empty item ends at a blank line: what follows is no part of it"
    )
    seg = seg_of({ "> - a", ">   more", "> - b" })
    H.eq(#seg.units, 2, "a list in a quote: the second line continues the first item")
    H.eq(seg.units[1].lines, 2)
    seg = seg_of({ "1. a", "   2. b" })
    H.eq(#seg.units, 1, "2. cannot interrupt a paragraph (it is text of the item)")
    seg = seg_of({ "- a", "  - b", "    ```", "    c", "    ```", "  - d" })
    H.eq(#seg.units, 3, "a fence in a nested item ends with the item")
    H.ok(literal(seg, 4), "its content is code")
    H.eq(
      units({ "- a", "      - b" }),
      1,
      "a marker six columns in is text of the paragraph, not an item"
    )
  end

  -- Tables: the header is the last line of the paragraph above, the cells must match --------------
  do
    local function cells(lines)
      local n = 0
      for _, u in ipairs(seg_of(lines).units) do
        if u.block == "cell" then
          n = n + 1
        end
      end
      return n
    end
    H.eq(cells({ "a", "|-|", "x" }), 2, "a header without pipe is a header")
    H.eq(cells({ "| a | b |", "|-|" }), 0, "another cell count: no table, a paragraph")
    H.eq(cells({ "| a |", "|---|", "| b |" }), 2, "header and body row")
    local seg = seg_of({ "intro", "h1|h2", "--|--", "x|y" })
    H.eq(seg.units[1].text, "intro", "the lines above the header stay a paragraph")
    H.eq(cells({ "intro", "h1|h2", "--|--", "x|y" }), 4)
    seg = seg_of({ "a | b", "- | -" })
    H.eq(seg.units[2].block, "item", "`- | -` is a list item before it is a delimiter row")
    H.eq(cells({ "| a |", "|---|", "    code" }), 1, "an indented line ends the table")
    H.eq(cells({ "> | a |", "> |---|", "| c |" }), 1, "a row outside of the quote is no row")
  end

  -- `$$` lives inside a paragraph (no block of its own), so a block start ends it ---------------------
  do
    local seg = seg_of({ "text", "$$", "x", "$$", "more" })
    H.eq(
      table.concat(texts(seg), "|"),
      "text|more",
      "math lines inside a paragraph stay as they are"
    )
    H.ok(literal(seg, 2) and literal(seg, 3) and literal(seg, 4))
    seg = seg_of({ "$$", "```lua", "$$", "text" })
    H.eq(#seg.units, 0, "a fence inside the 'math' starts a fence: everything below is code")
    H.ok(seg.units[1] == nil and literal(seg, 4))
    seg = seg_of({ "text", "$$", "x", "", "more", "$$" })
    H.eq(
      table.concat(texts(seg), "|"),
      "text|more $$",
      "a blank line ends the paragraph, and the math with it"
    )
  end

  -- A reference definition starts a paragraph (comrak cuts it off when the paragraph ends) ----------
  do
    local seg = seg_of({ "[ref]: /x", "2) two" })
    H.ok(literal(seg, 1), "the definition stays as it is")
    H.eq(
      table.concat(texts(seg), "|"),
      "2) two",
      "2) cannot interrupt the paragraph the definition began"
    )
    seg = seg_of({ "[a]: /x", "[b]: /y", "text" })
    H.ok(literal(seg, 1) and literal(seg, 2), "definitions in a row")
    H.eq(table.concat(texts(seg), "|"), "text")
    seg = seg_of({ "text", "[ref]: /x" })
    H.eq(
      table.concat(texts(seg), "|"),
      "text [ref]: /x",
      "a definition cannot interrupt a paragraph"
    )
    seg = seg_of({ "> [ref]: /x", "lazy" })
    H.eq(seg.units[1].block, "quote", "the text below goes on in the quote (lazy)")
    H.eq(seg.units[1].text, "lazy")
  end

  -- Many containers on one line are linear work -------------------------------------------------------
  do
    local n = 40000
    local t0 = (vim.uv or vim.loop).hrtime()
    seg_of({ string.rep("- ", n) .. "x" })
    seg_of({ string.rep("> ", n) .. "x" })
    seg_of({ string.rep("1. ", n) .. "x" })
    local ms = ((vim.uv or vim.loop).hrtime() - t0) / 1e6
    H.ok(
      ms < 1500,
      ("40000 nested containers on a line take %d ms (quadratic work would take seconds)"):format(
        ms
      )
    )
  end

  -- Review findings (wide fuzz, 2026-10-20) ---------------------------------------------------------
  do
    -- the width of an item is counted from where its container has content on THIS line: a quote prefix of
    -- another width is another column
    local seg = seg_of({ "> - text", "  > 0. zero" })
    H.eq(#seg.units, 2, "`  > 0.` is a new item, not the second line of the one above")
    H.eq(seg.units[2].text, "zero")

    -- a header that does not match its delimiter row in cells is no table, but a translation could make one of
    -- it (a dropped pipe): both lines stay as they are
    seg = seg_of({ "a | b", "|-|", "text" })
    H.ok(literal(seg, 1) and literal(seg, 2), "header and delimiter row of a non-table stay")
    H.eq(table.concat(texts(seg), "|"), "text")
    for _, u in ipairs(seg.units) do
      H.falsy(u.block == "cell", "and are no cells")
    end

    -- a footnote goes on at an empty line or one indented like its text, not at one of one to three spaces
    seg = seg_of({ "[^1]: note", "", "    more" })
    H.eq(seg.units[2].text, "more", "an empty line: the footnote goes on")
    seg = seg_of({ "[^1]: note", "  ", "     /url" })
    H.ok(literal(seg, 3), "two spaces end it: what follows is indented code")
    seg = seg_of({ "[^1]: note", "    ", "    more" })
    H.eq(seg.units[2].text, "more", "four spaces keep it open")

    -- the destination line of a bare `[label]:` is no list item
    seg = seg_of({ "1. [ref]:", "1. text" })
    H.eq(table.concat(texts(seg), "|"), "text", "an ordered item below is an item")
    seg = seg_of({ "[ref]:", "/x", "text" })
    H.ok(literal(seg, 2), "while a plain destination line stays")

    -- the lines of a paragraph lose their indent: a definition below definitions is one at any indent
    seg = seg_of({ "[a]: /x", "    [b]: /y", "text" })
    H.ok(literal(seg, 1) and literal(seg, 2), "definitions in a row, whatever the indent")
    H.ok(seg.defs["a"] and seg.defs["b"])

    -- a raw HTML block (`<script>`, `<pre>`, ...) ends at any of the four end tags, not only at its own, and
    -- only at the complete tag
    seg = seg_of({ "<script>", "</pre>", "text *a*" })
    H.ok(literal(seg, 1) and literal(seg, 2), "the block is literal up to the foreign end tag")
    H.eq(table.concat(texts(seg), "|"), "text *a*", "the line after </pre> is text again")
    seg = seg_of({ "<pre>", "x </prefix> y", "", "text", "</PRE>", "", "*b*" })
    H.ok(literal(seg, 4), "</prefix> is no end tag: the blank line does not end the block either")
    H.eq(table.concat(texts(seg), "|"), "*b*", "</PRE> ends it, whatever the case")

    -- the destination line of a bare `[label]:` in a quote is read without its quote markers, also when it is a
    -- lazy continuation, and `-->` is a destination, no bullet
    seg = seg_of({ "> [ref]:", "> /url", "> text" })
    H.ok(literal(seg, 2), "the destination in a quote stays")
    H.eq(table.concat(texts(seg), "|"), "text", "the text below it is translated")
    seg = seg_of({ "> > - [ref]:", "> dest", "" })
    H.ok(literal(seg, 2), "a lazy destination line stays")
    seg = seg_of({ "[ref]:", "-->", "text" })
    H.ok(literal(seg, 2), "--> is a destination")
    seg = seg_of({ "> [ref]:", "> - item" })
    H.eq(table.concat(texts(seg), "|"), "item", "a bullet in the quote is no destination")

    -- a pipe right behind a backslash is no cell border, also behind an escaped backslash (`\\|`, as comrak reads
    -- it): the code span in the cell stays whole
    seg = seg_of({ "| h1 | h2 |", "| -- | -- |", "| `a \\\\| b` | c |", "| x \\\\ | y |" })
    H.eq(table.concat(texts(seg), "#"), "h1#h2#`a \\\\| b`#c#x \\\\#y")
    -- the same rule counts the header cells: `a \\| b` is one cell, so the header matches its delimiter row and
    -- the table is a table (its rows are translated)
    seg = seg_of({ "| a \\\\| b | c |", "| - | - |", "| x | y |" })
    H.eq(table.concat(texts(seg), "#"), "a \\\\| b#c#x#y", "a header with \\\\| is a table header")

    -- a task box with nothing behind it is still the item's paragraph: the line below goes on with it, and a list
    -- that interrupts it is a list
    seg = seg_of({ "- [ ] ", "?>", "\t- + item" })
    H.ok(literal(seg, 1), "the box stays")
    H.eq(table.concat(texts(seg), "|"), "?>|item", "the nested list is no continuation of the text")

    -- below a paragraph of nothing but definitions an underline is text, and a `-` below it is its underline: the
    -- tab-indented line after that is indented code, no item
    seg = seg_of({ "   [ref]: /x", "   ===", "-", "\t> quote" })
    H.ok(literal(seg, 2) and literal(seg, 3), "underline text and underline stay")
    H.ok(literal(seg, 4), "the indented line is code")
    H.eq(#seg.units, 0)
  end
end
