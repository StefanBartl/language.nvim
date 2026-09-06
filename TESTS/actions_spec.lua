-- TESTS/actions_spec.lua — language.spell.core.actions.replace_at: the
-- single-occurrence fix applied from the suggestion picker.
--
-- The issue's byte range is computed by a scan that can be stale by the time
-- this runs (item_menu.lua opens an async suggestion picker in between, and
-- the buffer may change underneath it — an edit in another window, undo, an
-- LSP fix). replace_at must re-verify the range still holds the original word
-- right before writing, and refuse (not silently overwrite unrelated text)
-- when it does not.

return function(H)
  local actions = require("language.spell.core.actions")

  -- A fresh match applies cleanly -----------------------------------------------
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "the qick brown fox" })

  local issue = {
    bufnr = buf,
    lnum = 1,
    col = 5, -- 1-based, "qick" starts at byte 5
    end_col = 9, -- exclusive
    word = "qick",
  }

  local ok, err = actions.replace_at(issue, "quick")
  H.ok(ok, "a fresh, unstale match applies")
  H.eq(err, nil, "no error on success")
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "the quick brown fox",
    "the word is replaced in place"
  )

  -- A stale match (buffer changed since the scan) is refused, not overwritten --
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "the qick brown fox" })

  local stale_issue = {
    bufnr = buf2,
    lnum = 1,
    col = 5,
    end_col = 9,
    word = "qick", -- what the scan saw
  }

  -- Something else touches the buffer between scan and apply (another window,
  -- undo, an LSP fix) — the range now denotes different text.
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "the slow brown fox" })

  local ok2, err2 = actions.replace_at(stale_issue, "quick")
  H.falsy(ok2, "a stale match is refused")
  H.ok(type(err2) == "string" and err2:find("stale"), "the error says why: " .. tostring(err2))
  H.eq(
    vim.api.nvim_buf_get_lines(buf2, 0, -1, false)[1],
    "the slow brown fox",
    "the buffer is untouched — no blind overwrite of unrelated text"
  )

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(buf2, { force = true })
end
