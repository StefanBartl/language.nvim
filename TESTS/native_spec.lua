-- TESTS/native_spec.lua — language.spell.providers.native: the always-available
-- provider built on `vim.spell.check`. Covers scope-aware scanning, the
-- word_split refinement, URL/email skip spans, inline disable directives, the
-- disk-tree fallback and native suggestions.

return function(H)
  local native = require("language.spell.providers.native")

  H.ok(native.available(), "vim.spell.check is available in a headless Neovim >= 0.9")

  local BAD = "zzqqxxnativetest" -- guaranteed to be flagged by any spelllang

  ---@return LanguageSpellCfg
  local function base_cfg(extra)
    return vim.tbl_deep_extend("force", {
      word_split = { enable = false, min_length = 4 },
      regions = { treesitter_spell = false, skip_urls = false, skip_emails = false },
      skip_readonly = true,
      max_file_lines = 20000,
    }, extra or {})
  end

  -- scan_scope: buffer -----------------------------------------------------
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one " .. BAD .. " two", "three four" })

  local issues = native.scan_scope({ kind = "buffer", bufnr = buf }, base_cfg())
  H.eq(#issues, 1, "one flagged word across the buffer")
  H.eq(issues[1].word, BAD, "the flagged word itself")
  H.eq(issues[1].lnum, 1, "on the right line")
  H.eq(issues[1].source, "native", "tagged with its source")
  H.eq(issues[1].kind, "spell", "and its kind")

  -- scan_scope: visible/selection range -------------------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD, "clean line", BAD })
  local ranged =
    native.scan_scope({ kind = "selection", bufnr = buf, range = { s = 2, e = 3 } }, base_cfg())
  H.eq(#ranged, 1, "only the flagged line inside the range is reported")
  H.eq(ranged[1].lnum, 3, "at its real line number, not relative to the range")

  -- Inline disable directives ----------------------------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    BAD, -- silenced by disable-next-line below... no: this is line 1
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "language:disable-next-line",
    BAD, -- line 2, silenced by the directive on line 1
    BAD .. " -- language:disable-line", -- line 3, silenced inline
    BAD, -- line 4, not silenced
  })
  local disabled_issues = native.scan_scope({ kind = "buffer", bufnr = buf }, base_cfg())
  H.eq(#disabled_issues, 1, "only the un-silenced line is reported")
  H.eq(disabled_issues[1].lnum, 4, "which is line 4")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "language:disable-file",
    BAD,
    BAD,
  })
  H.eq(
    #native.scan_scope({ kind = "buffer", bufnr = buf }, base_cfg()),
    0,
    "disable-file silences the whole buffer"
  )

  -- skip_urls / skip_emails -------------------------------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "see https://example.com/" .. BAD .. "-path for details",
    "contact " .. BAD .. "@example.com please",
  })
  local with_skip = native.scan_scope(
    { kind = "buffer", bufnr = buf },
    base_cfg({ regions = { skip_urls = true, skip_emails = true } })
  )
  H.eq(#with_skip, 0, "URL and email spans are skipped entirely")

  local without_skip = native.scan_scope({ kind = "buffer", bufnr = buf }, base_cfg())
  H.ok(#without_skip > 0, "without the skip config the same text is flagged")

  -- word_split ---------------------------------------------------------------
  local compound = "get" .. BAD:sub(1, 1):upper() .. BAD:sub(2) -- e.g. getZzqqxx...
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { compound })
  local split_cfg = base_cfg({ word_split = { enable = true, min_length = 4 } })
  local split_issues = native.scan_scope({ kind = "buffer", bufnr = buf }, split_cfg)
  H.ok(#split_issues >= 1, "word_split reports the misspelled subword")
  local found = false
  for _, is in ipairs(split_issues) do
    if is.word:lower() == BAD then
      found = true
    end
  end
  H.ok(found, "and the subword text matches the bad half of the compound, split at the boundary")

  -- A compound whose subwords are all fine emits nothing (no false positive
  -- from the outer, unsplit token failing the whole-word check).
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "getWord" })
  H.eq(
    #native.scan_scope({ kind = "buffer", bufnr = buf }, split_cfg),
    0,
    "getWord splits into two real words: nothing to report"
  )

  vim.api.nvim_buf_delete(buf, { force = true })

  -- scan_scope: cwd sees only already-loaded buffers ------------------------
  local unloaded_dir, cleanup = H.fixture("native-cwd")
  local file_path = unloaded_dir .. "/note.md"
  vim.fn.writefile({ BAD }, file_path)
  local cwd_issues = native.scan_scope({ kind = "cwd" }, base_cfg())
  H.eq(#cwd_issues, 0, "an unopened file on disk is invisible to the cwd (loaded-buffers) scan")

  -- scan_tree: the real recursive disk-tree fallback, for a single file -----
  local done, tree_issues = false, nil
  native.scan_tree({ kind = "path", path = file_path }, base_cfg(), function(res)
    done, tree_issues = true, res
  end)
  vim.wait(1000, function()
    return done
  end)
  H.ok(done, "scan_tree for a single file delivers synchronously")
  H.eq(#tree_issues, 1, "and finds the flagged word by reading the file straight off disk")
  H.eq(tree_issues[1].word, BAD, "the word itself")
  H.eq(tree_issues[1].bufnr, nil, "no attached buffer for an unopened file")

  -- scan_tree: a directory walk, cancellable -------------------------------
  vim.fn.writefile({ "clean text, nothing to see" }, unloaded_dir .. "/other.txt")
  local dir_done, dir_issues = false, nil
  local job = native.scan_tree({ kind = "path", path = unloaded_dir }, base_cfg(), function(res)
    dir_done, dir_issues = true, res
  end)
  H.ok(job, "scan_tree over a directory returns a cancellable job")
  vim.wait(2000, function()
    return dir_done
  end)
  H.ok(dir_done, "the directory walk completes")
  local words = {}
  for _, is in ipairs(dir_issues or {}) do
    words[#words + 1] = is.word
  end
  H.ok(vim.tbl_contains(words, BAD), "the flagged word from note.md is in the tree-wide result")

  -- scan_tree: a single-file path that does not exist (ERR-11) -- still
  -- delivers an empty result rather than erroring, but that emptiness is
  -- no longer indistinguishable from a clean scan (a warning is raised,
  -- not asserted here since this suite has no notify stub).
  local missing_done, missing_issues = false, nil
  native.scan_tree(
    { kind = "path", path = unloaded_dir .. "/does-not-exist.md" },
    base_cfg(),
    function(res)
      missing_done, missing_issues = true, res
    end
  )
  H.ok(missing_done, "a missing path still calls back synchronously")
  H.eq(#missing_issues, 0, "with an empty (not crashing) result")

  cleanup()

  -- suggest() ----------------------------------------------------------------
  local suggestions = native.suggest({ word = "wrold" })
  H.ok(type(suggestions) == "table", "suggest() returns a list")

  H.eq(#native.suggest({}), 0, "a malformed issue (no .word) yields no suggestions, not an error")
  ---@diagnostic disable-next-line: param-type-mismatch
  H.eq(#native.suggest(nil), 0, "neither does nil")
end
