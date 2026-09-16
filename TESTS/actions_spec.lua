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

  -- replace_all_in_buffer: every whole-word occurrence, not a substring match --
  local buf3 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf3, 0, -1, false, {
    "teh cat sat on teh mat",
    "matteh is not teh, it must survive untouched",
  })
  local ok3, count3 = actions.replace_all_in_buffer(buf3, "teh", "the")
  H.ok(ok3, "replace_all_in_buffer succeeds")
  H.eq(count3, 3, "three whole-word occurrences of 'teh'")
  H.eq(
    vim.api.nvim_buf_get_lines(buf3, 0, -1, false)[1],
    "the cat sat on the mat",
    "both occurrences on the first line are replaced"
  )
  H.contains(
    vim.api.nvim_buf_get_lines(buf3, 0, -1, false)[2],
    "matteh",
    "a substring match ('matteh') is not touched — %f[%w] is a word boundary, not gsub-anywhere"
  )

  local ok_empty, err_empty = actions.replace_all_in_buffer(buf3, "nonexistent-word", "x")
  H.ok(ok_empty, "no matches is still a success, not an error")
  H.eq(err_empty, 0, "with a zero count")

  local ok_bad, err_bad = actions.replace_all_in_buffer(buf3, "", "x")
  H.falsy(ok_bad, "an empty search word is rejected")
  H.ok(type(err_bad) == "string", "with a string reason")

  vim.api.nvim_buf_delete(buf3, { force = true })

  -- add_to_dict: rejects empty input without touching the spellfile machinery.
  local ok_add, err_add = actions.add_to_dict("")
  H.falsy(ok_add, "an empty word is rejected")
  H.eq(err_add, "empty word", "with a specific reason")

  ---@diagnostic disable-next-line: param-type-mismatch
  local ok_add_nil = actions.add_to_dict(nil)
  H.falsy(ok_add_nil, "nil is rejected the same way")

  -- The success path really calls :spellgood — with use_spellfile = false so
  -- this stays session-only (like zG) rather than writing to the real
  -- spellfile on the machine running the suite.
  local config = require("language.config")
  config.setup({ spell = { dictionary = { use_spellfile = false } } })
  local word = "zzqqxxlanguagenvimtestword"
  local prev_bad = vim.spell.check(word)[1]
  H.ok(prev_bad and prev_bad[1] == word, "the test word is flagged before add_to_dict")

  local ok_good, err_good = actions.add_to_dict(word)
  H.ok(ok_good, "add_to_dict succeeds: " .. tostring(err_good))
  local after = vim.spell.check(word)[1]
  H.falsy(after and after[1] == word, "the word is no longer flagged after :spellgood!")

  config.setup({})
end
