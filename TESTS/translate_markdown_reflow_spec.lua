-- TESTS/translate_markdown_reflow_spec.lua -- translate/markdown/reflow.lua: a
-- translation wrapped onto exactly the original number of lines, and the rule
-- that no break lands in front of a block-start token. The rule has its own
-- golden test (spike 2026-10-06: a dash at the beginning of a line became a list
-- item, 98 blocks turned into 102), and a property test covers the invariants.

return function(H)
  local reflow = require("language.translate.markdown.reflow")

  local function never(_)
    return false
  end

  -- starts_block: the golden list -----------------------------------------------------
  for _, w in ipairs({
    "-",
    "*",
    "+",
    "1.",
    "12.",
    "3)",
    "#",
    "###",
    "######",
    ">",
    ">quote",
    "|",
    "|x",
    "```",
    "```lua",
    "~~~",
    "---",
    "--",
    "===",
    "***",
    "___",
    "<div>",
    "$$",
    ":::",
    "[x]:",
    "[^1]:",
  }) do
    H.ok(reflow.starts_block(w), "'" .. w .. "' starts a block")
  end
  for _, w in ipairs({
    "word",
    "-foo",

    "**bold**",
    "*em*",
    "1",
    "1.5",
    "v1.",
    "#tag",
    "#######",
    "a>b",
    "x|y",
    "`code`",
    "``",
    "{1}",
    "[link]",
    "[x]y",
    "2024-01-01",
  }) do
    H.ok(not reflow.starts_block(w), "'" .. w .. "' is safe at the start of a line")
  end

  -- the dash rule, golden: without the rule the cut lands in front of the dash --------------
  do
    local text = "aaaa bbbb cccc - dddd eeee ffff gggg"
    local weights = { 14, 22 }
    local naive = reflow.reflow(text, weights, { unsafe = never })
    H.ok(naive[2]:match("^%-"), "the test is meaningful: the naive cut starts line 2 with the dash")
    local safe = reflow.reflow(text, weights)
    H.eq(#safe, 2)
    H.ok(not safe[2]:match("^%-"), "line 2 does not start with the dash: " .. safe[2])
    H.ok(not safe[1]:match("^%-"))
    H.eq(table.concat(safe, " "), text, "no word is lost or reordered")

    -- every kind of block start
    for _, tok in ipairs({ "-", "*", "+", "1.", "#", ">", "|", "```" }) do
      local t = "aaaa bbbb cccc " .. tok .. " dddd eeee ffff gggg"
      local lines = reflow.reflow(t, { 14, 22 })
      H.ok(lines and #lines == 2, "two lines for " .. tok)
      H.ok(
        not reflow.starts_block(lines[2]:match("^%S+")),
        "line 2 of '" .. tok .. "' starts safely: " .. lines[2]
      )
    end
  end

  -- shape ---------------------------------------------------------------------------------------------
  do
    local out = reflow.reflow("alpha beta gamma delta", { 5 })
    H.eq(out[1], "alpha beta gamma delta", "one line stays one line")

    out = reflow.reflow("alpha beta gamma delta epsilon zeta", { 10, 10, 10 })
    H.eq(#out, 3)
    H.eq(table.concat(out, " "), "alpha beta gamma delta epsilon zeta")
    for k, l in ipairs(out) do
      H.ok(l ~= "", "line " .. k .. " is not empty")
    end

    -- widths steer the split
    out = reflow.reflow("a b c d e f g h", { 1, 7 })
    H.ok(#out[1] < #out[2], "the narrow original line gets the smaller share: " .. vim.inspect(out))

    -- surplus whitespace is normalised, newlines never survive
    out = reflow.reflow("  a \t b\nc  ", { 3, 3 })
    H.eq(table.concat(out, "|"), "a b|c")
    for _, l in ipairs(out) do
      H.falsy(l:find("[\r\n]"), "no line break inside a line")
    end
  end

  -- fewer words than lines: one word per line, the rest empty ---------------------------------------------
  do
    local out = reflow.reflow("one two", { 5, 5, 5, 5 })
    H.eq(table.concat(out, "|"), "one|two||")
    out = reflow.reflow("one", { 5, 5 })
    H.eq(table.concat(out, "|"), "one|")
    local none, err = reflow.reflow("one - two", { 5, 5, 5 })
    H.ok(
      none == nil and err,
      "a surplus line cannot hold the dash at its start: refused, not broken"
    )
  end

  -- refusals ------------------------------------------------------------------------------------------------
  do
    local out, err = reflow.reflow("   ", { 1, 1 })
    H.ok(out == nil and err, "an empty translation is refused")
    out, err = reflow.reflow("- foo bar", { 1, 1 }, { guard_first = true })
    H.ok(out == nil and err, "the first line is guarded when it has no marker of its own")
    out = reflow.reflow("- foo bar", { 1, 1 }, { guard_first = false })
    H.ok(out ~= nil, "and not guarded when a marker precedes it")
    -- every candidate break unsafe
    out = reflow.reflow("a - - - b", { 1, 1 })
    H.ok(out ~= nil and not out[2]:match("^%-"), "a safe word is chosen among unsafe ones")
    out, err = reflow.reflow("a - - -", { 1, 1 })
    H.ok(out == nil and err, "no safe word to start line 2: refused")
  end

  -- the expansion hook: placeholders are judged by what they stand for ----------------------------------------
  do
    local out = reflow.reflow("aaaa {1} cccc dddd", { 5, 5 }, {
      unsafe = function(w)
        return w == "{1}"
      end,
    })
    H.ok(
      not out[2]:match("^{1}") and not out[1]:match("^{1}%s*$"),
      "an unsafe placeholder does not start line 2"
    )
  end

  -- property / fuzz ----------------------------------------------------------------------------------------------
  do
    math.randomseed(1006)
    local pool = {
      "alpha",
      "beta",
      "gamma",
      "delta",
      "-",
      "*",
      "+",
      "1.",
      "#",
      ">",
      "|",
      "```",
      "---",
      "{1}",
      "{2}",
      "wort,",
      "x.",
      "ein",
      "lange_wort_ohne_ende_xxxxxxxxxxxxxxxxxxxx",
      "\195\188ber",
      "\228\184\173\230\150\135",
    }
    local refused, accepted = 0, 0
    for iter = 1, 3000 do
      local m = math.random(0, 14)
      local words = {}
      for i = 1, m do
        words[i] = pool[math.random(#pool)]
      end
      local n = math.random(1, 8)
      local weights = {}
      for k = 1, n do
        weights[k] = math.random(0, 60)
      end
      local guard = math.random() < 0.5
      local text = table.concat(words, math.random() < 0.3 and "  \t" or " ")
      local out, err = reflow.reflow(text, weights, { guard_first = guard })
      local what = ("iter %d (m=%d n=%d guard=%s): %s"):format(iter, m, n, tostring(guard), text)
      if m == 0 then
        H.ok(out == nil and err, "empty text is refused: " .. what)
      elseif out then
        accepted = accepted + 1
        H.eq(#out, n, "exactly n lines: " .. what)
        local joined = {}
        for k = 1, n do
          H.eq(type(out[k]), "string", "a string per line: " .. what)
          H.falsy(out[k]:find("[\r\n]"), "no newline in a line: " .. what)
          if out[k] ~= "" then
            joined[#joined + 1] = out[k]
            local first = out[k]:match("^%S+")
            if k > 1 or guard then
              H.ok(
                not reflow.starts_block(first),
                ("line %d starts with '%s': %s"):format(k, first, what)
              )
            end
          end
        end
        H.eq(
          table.concat(joined, " "),
          table.concat(words, " "),
          "all words, in order, nothing added: " .. what
        )
        -- padding lines are only ever at the end
        local seen_empty = false
        for k = 1, n do
          if out[k] == "" then
            seen_empty = true
          else
            H.falsy(seen_empty, "an empty line is never followed by text: " .. what)
          end
        end
        if m >= n then
          for k = 1, n do
            H.ok(out[k] ~= "", "with enough words no line is empty: " .. what)
          end
        end
        -- deterministic
        local again = reflow.reflow(text, weights, { guard_first = guard })
        H.eq(table.concat(again, "\0"), table.concat(out, "\0"), "same input, same output")
      else
        refused = refused + 1
        H.ok(type(err) == "string", "a refusal says why: " .. what)
      end
    end
    H.ok(accepted > 1000, "most random inputs wrap (" .. accepted .. " of 3000)")
    H.ok(refused > 0, "and some are refused, never broken")
  end

  -- The cell of a table's delimiter row is no word to start a line with ----------------
  do
    H.ok(reflow.starts_block(":-:"))
    H.ok(reflow.starts_block("--:"))
    H.ok(reflow.starts_block(":--:"))
    H.falsy(reflow.starts_block("a-b"))
    H.ok(reflow.is_table_rule("| --- | :-: |"))
    H.ok(reflow.is_table_rule(":-: | -"))
    H.ok(reflow.is_table_rule("> |---|"))
    H.falsy(reflow.is_table_rule("--- ---"), "no pipe: a rule, not a table")
    H.falsy(reflow.is_table_rule("a | --- | b"))
    H.falsy(reflow.is_table_rule("| a | b |"))
  end

  -- The break search looks at the neighbourhood of the ideal break, not at every word.
  -- Compared with the plain scan over the whole range it replaces. ---------------------
  do
    ---@param text string
    ---@param weights integer[]
    ---@param opts table
    local function reference(text, weights, opts)
      local unsafe = opts.unsafe or reflow.starts_block
      local n = #weights
      local words = reflow.words(text)
      local m = #words
      if m == 0 or (opts.guard_first and unsafe(words[1])) then
        return nil
      end
      if n <= 1 then
        return { table.concat(words, " ") }
      end
      local starts = { 1 }
      if m < n then
        for k = 2, m do
          if unsafe(words[k]) then
            return nil
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
          local best, best_d
          for c = starts[k] + 1, m - (n - k - 1) do
            if not unsafe(words[c]) then
              local d = math.abs(prefix[c - 1] - target)
              if not best_d or d < best_d then
                best, best_d = c, d
              end
            end
          end
          if not best then
            return nil
          end
          starts[k + 1] = best
        end
      end
      local out = {}
      for k = 1, n do
        out[k] = starts[k] and table.concat(words, " ", starts[k], (starts[k + 1] or (m + 1)) - 1)
          or ""
      end
      return out
    end

    math.randomseed(77)
    local pool =
      { "a", "bb", "ccc", "-", "1.", "dddd", "#", "x", "yy", "zzzzzz", ">", "|", "lorem" }
    for iter = 1, 3000 do
      local words = {}
      for i = 1, math.random(0, 25) do
        words[i] = pool[math.random(#pool)]
      end
      local weights = {}
      for i = 1, math.random(1, 12) do
        weights[i] = math.random(0, 40)
      end
      local opts = { guard_first = math.random() < 0.5 }
      local text = table.concat(words, " ")
      local got = reflow.reflow(text, weights, opts)
      local want = reference(text, weights, opts)
      H.eq(got == nil, want == nil, "same refusals: " .. text)
      if got and want then
        H.eq(
          table.concat(got, "\0"),
          table.concat(want, "\0"),
          "same breaks " .. iter .. ": " .. text
        )
      end
    end
  end
end
