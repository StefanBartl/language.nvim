-- TESTS/translate_output_spec.lua — language.translate.output: delivering
-- translated text to its destination. Every mode except "popup" is exercised
-- directly; "popup" is the only one that reaches `ui.kit` (not available in
-- this suite's CI checkout — see TESTS/README.md) and is left untested.

return function(H)
  local output = require("language.translate.output")

  ---@param bufnr integer
  ---@return string
  local function lines_of(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "|")
  end

  -- replace -------------------------------------------------------------------
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  output.apply("replace", { "TWO", "TOO" }, { bufnr = buf, s = 2, e = 2 })
  H.eq(
    lines_of(buf),
    "one|TWO|TOO|three",
    "replace overwrites the [s,e] line range with the translated lines"
  )

  -- insert ----------------------------------------------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  output.apply("insert", { "TWO" }, { bufnr = buf, s = 2, e = 2 })
  H.eq(
    lines_of(buf),
    "one|two|TWO|three",
    "insert adds the translated lines just below the range, leaving it intact"
  )

  -- buffer/vsplit/split/tab: a fresh, writable buffer, filetype inherited ---
  vim.bo[buf].filetype = "markdown"
  local before_wins = #vim.api.nvim_list_wins()
  output.apply("buffer", { "translated" }, { bufnr = buf, s = 1, e = 1 })
  H.eq(#vim.api.nvim_list_wins(), before_wins, "'buffer' mode reuses the current window")
  local new_buf = vim.api.nvim_get_current_buf()
  H.eq(lines_of(new_buf), "translated", "with the new content")
  H.eq(vim.bo[new_buf].filetype, "markdown", "and the source buffer's filetype")
  H.ok(vim.bo[new_buf].modifiable, "the new buffer is a normal, writable one")

  output.apply("vsplit", { "vsplit output" }, { bufnr = buf, s = 1, e = 1 })
  H.eq(#vim.api.nvim_list_wins(), before_wins + 1, "'vsplit' opens exactly one new window")
  vim.cmd("close")

  output.apply("split", { "split output" }, { bufnr = buf, s = 1, e = 1 })
  H.eq(#vim.api.nvim_list_wins(), before_wins + 1, "'split' likewise")
  vim.cmd("close")

  local before_tabs = vim.fn.tabpagenr("$")
  output.apply("tab", { "tab output" }, { bufnr = buf, s = 1, e = 1 })
  H.eq(vim.fn.tabpagenr("$"), before_tabs + 1, "'tab' opens exactly one new tab")
  vim.cmd("tabclose")

  -- clipboard ---------------------------------------------------------------
  output.apply("clipboard", { "clip one", "clip two" }, { bufnr = buf, s = 1, e = 1 })
  H.eq(vim.fn.getreg("+"), "clip one\nclip two", 'the "+" register receives the joined lines')
  H.eq(vim.fn.getreg('"'), "clip one\nclip two", "the unnamed register too")

  -- notify --------------------------------------------------------------------
  -- No direct return value to assert on; this only has to not error.
  output.apply("notify", { "a translated note" }, { bufnr = buf, s = 1, e = 1 })

  vim.api.nvim_buf_delete(buf, { force = true })
end
