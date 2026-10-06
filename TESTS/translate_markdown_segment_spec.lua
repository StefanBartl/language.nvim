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
end
