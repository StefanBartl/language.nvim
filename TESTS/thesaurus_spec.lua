-- TESTS/thesaurus_spec.lua — language.thesaurus: synonym lookup + replace the
-- word under the cursor. `language.util.job` is stubbed for the network call
-- (Datamuse); `replace_under_cursor` is only exercised with an explicit `nth`
-- (or a case with no synonyms/no word), which is exactly what keeps it off
-- the `ui.kit` picker branch — see TESTS/README.md.

return function(H)
  local config = require("language.config")
  local thesaurus = require("language.thesaurus")

  -- parse_datamuse -------------------------------------------------------------
  local syns = thesaurus.parse_datamuse('[{"word":"quick"},{"word":"fast"},{"word":"rapid"}]', 20)
  H.eq(table.concat(syns, ","), "quick,fast,rapid", "words extracted in order")

  H.eq(#thesaurus.parse_datamuse("not json", 20), 0, "malformed JSON: empty, not an error")
  H.eq(#thesaurus.parse_datamuse("[]", 20), 0, "an empty array: empty")
  H.eq(
    #thesaurus.parse_datamuse('[{"word":"a"},{"word":"b"},{"word":"c"}]', 2),
    2,
    "max caps the result"
  )
  H.eq(
    #thesaurus.parse_datamuse('[{"score":5},{"word":"ok"}]', 20),
    1,
    "an entry with no .word is skipped, not crashed on"
  )

  -- word_under_cursor -----------------------------------------------------
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "the quick brown fox", "", "it's fine" })
  vim.api.nvim_set_current_buf(buf)

  vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- inside "quick"
  local word, sr, sc, er, ec = thesaurus.word_under_cursor()
  H.eq(word, "quick", "the word the cursor sits inside")
  H.eq(sr, 0, "0-based row")
  H.eq(sc, 4, "start col at the word's first byte")
  H.eq(er, 0, "same row")
  H.eq(ec, 9, "end col one past the last byte")

  vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- just past "quick", on the space
  H.eq(thesaurus.word_under_cursor(), "quick", "the cursor just past a word steps back onto it")

  vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- an empty line
  H.eq(thesaurus.word_under_cursor(), "", "an empty line has no word")

  vim.api.nvim_win_set_cursor(0, { 3, 3 }) -- inside "it's" (apostrophe counts)
  H.eq(thesaurus.word_under_cursor(), "it's", "an apostrophe is part of the word")

  -- synonyms(): stubbed job, no real network -----------------------------------
  local calls = {}
  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      calls[#calls + 1] = argv
      opts.on_done(true, '[{"word":"speedy"},{"word":"fast"}]', "")
      return { cancel = function() end }
    end,
  }
  package.loaded["language.thesaurus"] = nil
  thesaurus = require("language.thesaurus")

  config.setup({ thesaurus = { enable = true, source = "datamuse", max = 20 } })
  local done, result = false, nil
  thesaurus.synonyms("quick", function(res)
    done, result = true, res
  end)
  H.ok(done, "synonyms() resolves via the stubbed job")
  H.eq(table.concat(result, ","), "speedy,fast", "with the parsed Datamuse response")
  H.contains(table.concat(calls[1], " "), "rel_syn=quick", "the word is sent as the rel_syn param")

  calls = {}
  local empty_done, empty_result = false, nil
  thesaurus.synonyms("", function(res)
    empty_done, empty_result = true, res
  end)
  H.ok(empty_done, "an empty word still resolves")
  H.eq(#empty_result, 0, "to an empty list")
  H.eq(#calls, 0, "without ever calling job.run")

  -- synonyms(): a custom source bypasses curl/Datamuse entirely --------------
  config.setup({
    thesaurus = {
      enable = true,
      source = "custom",
      custom = function(w, cb)
        cb({ "custom:" .. w })
      end,
    },
  })
  local c_done, c_result = false, nil
  thesaurus.synonyms("test", function(res)
    c_done, c_result = true, res
  end)
  H.ok(c_done, "a custom source resolves")
  H.eq(c_result[1], "custom:test", "via the injected function, not Datamuse")

  -- a custom function that errors degrades to an empty list, not a crash
  config.setup({
    thesaurus = {
      enable = true,
      source = "custom",
      custom = function()
        error("boom")
      end,
    },
  })
  local e_done, e_result = false, nil
  thesaurus.synonyms("test", function(res)
    e_done, e_result = true, res
  end)
  H.ok(e_done, "an erroring custom source still resolves")
  H.eq(#e_result, 0, "with an empty list")

  -- replace_under_cursor(): disabled, no word, nth out of range, and the
  -- direct-nth apply path (all off the ui.kit picker branch) ----------------
  config.setup({ thesaurus = { enable = false } })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "quick fox" })
  thesaurus.replace_under_cursor(1)
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "quick fox",
    "disabled: replace_under_cursor is a no-op"
  )

  config.setup({
    thesaurus = {
      enable = true,
      source = "custom",
      custom = function(_w, cb)
        cb({})
      end,
    },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- inside "quick" (line is "quick fox")
  thesaurus.replace_under_cursor(1)
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "quick fox",
    "no synonyms found: nothing is replaced"
  )

  config.setup({
    thesaurus = {
      enable = true,
      source = "custom",
      custom = function(_w, cb)
        cb({ "swift", "speedy" })
      end,
    },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- inside "quick"
  thesaurus.replace_under_cursor(2)
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "speedy fox",
    "nth = 2 applies the second synonym directly, no menu"
  )

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "quick fox" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  thesaurus.replace_under_cursor(99)
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "quick fox",
    "nth out of range: reported, not clamped to the nearest valid index"
  )

  -- replace_under_cursor(): ERR-30 -- a concurrent edit to the exact span,
  -- landing while the lookup was "in flight", is not blindly overwritten.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "quick fox" })
  config.setup({
    thesaurus = {
      enable = true,
      source = "custom",
      custom = function(_w, cb)
        -- Simulate a concurrent edit to the exact word span before the
        -- lookup resolves.
        vim.api.nvim_buf_set_text(buf, 0, 0, 0, 5, { "other" })
        cb({ "speedy" })
      end,
    },
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- inside "quick"
  thesaurus.replace_under_cursor(1)
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "other fox",
    "the concurrent edit survives -- the stale synonym was discarded, not written over it"
  )

  vim.api.nvim_buf_delete(buf, { force = true })
  package.loaded["language.util.job"] = nil
  package.loaded["language.thesaurus"] = nil
  config.setup({})
end
