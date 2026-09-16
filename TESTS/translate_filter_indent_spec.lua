-- TESTS/translate_filter_indent_spec.lua — language.translate.filter (which
-- line ranges are safe to translate, skipping fenced/inline code) and
-- language.translate.indent (round-tripping leading whitespace). Both are
-- pure functions with no UI/network dependency.

return function(H)
  local filter = require("language.translate.filter")
  local indent = require("language.translate.indent")

  -- filter.translatable_ranges --------------------------------------------
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "prose line one", -- 1
    "prose line two", -- 2
    "```lua", -- 3  fence open
    "local x = 1", -- 4  code, skipped
    "```", -- 5  fence close
    "prose again", -- 6
    "a line with `inline code` in it", -- 7 skipped (has a backtick)
    "final prose", -- 8
  })

  local ranges = filter.translatable_ranges(buf, 1, 8)
  H.eq(#ranges, 3, "three contiguous prose runs, code fenced/inline excluded")
  H.eq(ranges[1].s, 1, "first run starts at line 1")
  H.eq(ranges[1].e, 2, "and ends at line 2 (before the fence)")
  H.eq(ranges[2].s, 6, "second run starts right after the closing fence")
  H.eq(ranges[2].e, 6, "and is one line (the inline-code line breaks it)")
  H.eq(ranges[3].s, 8, "third run is the final prose line")
  H.eq(ranges[3].e, 8, "alone")

  H.eq(#filter.translatable_ranges(buf, 3, 5), 0, "a range that is entirely fenced code: nothing")

  H.eq(#filter.translatable_ranges(nil, 1, 8), 0, "a nil buffer is a safe no-op, not an error")
  H.eq(#filter.translatable_ranges(buf, nil, 8), 0, "a nil start_line likewise")

  -- An unclosed fence: everything from the opening fence onward is treated
  -- as code (in_fence stays true), so nothing after it is translatable.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "prose",
    "```",
    "still fenced, never closed",
  })
  local unclosed = filter.translatable_ranges(buf, 1, 3)
  H.eq(#unclosed, 1, "only the prose line before the unclosed fence is translatable")
  H.eq(unclosed[1].s, 1, "line 1")
  H.eq(unclosed[1].e, 1, "alone")

  vim.api.nvim_buf_delete(buf, { force = true })

  -- indent.strip / indent.restore -------------------------------------------
  local lines = { "    - item one", "  - item two", "no indent" }
  local dedented, indents = indent.strip(lines)
  H.eq(dedented[1], "- item one", "leading whitespace is captured, not left in place")
  H.eq(indents[1], "    ", "and returned separately, per line")
  H.eq(dedented[3], "no indent", "a line with no leading whitespace is unchanged")
  H.eq(indents[3], "", "with an empty captured indent")

  local restored = indent.restore({ "- ITEM ONE", "- ITEM TWO", "NO INDENT" }, indents)
  H.eq(restored[1], "    - ITEM ONE", "the original indent is re-applied")
  H.eq(restored[2], "  - ITEM TWO", "per line")
  H.eq(restored[3], "NO INDENT", "and an empty indent changes nothing")

  -- A provider that merges/splits lines breaks the 1:1 mapping — restore()
  -- must give up rather than silently misapply indentation to the wrong line.
  local mismatched = indent.restore({ "one merged line" }, indents)
  H.eq(#mismatched, 1, "line-count mismatch: input is returned unchanged")
  H.eq(mismatched[1], "one merged line", "with no indent applied")
end
