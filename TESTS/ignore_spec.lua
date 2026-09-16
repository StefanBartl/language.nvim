-- TESTS/ignore_spec.lua — language.spell.core.ignore: the set of words the
-- user has told the spellchecker to stop reporting, and the filter that
-- applies it to a result list, plus the persistent half (redirected to a
-- fixture file rather than the developer's real `stdpath("state")` one).

return function(H)
  local ignore = require("language.spell.core.ignore")

  -- A word nobody ignored ------------------------------------------------------
  local unknown = "zzqqxx-not-a-real-word"
  H.falsy(ignore.has(unknown), "an unknown word is not ignored")

  -- Session additions -----------------------------------------------------------
  ignore.add_session(unknown)
  H.ok(ignore.has(unknown), "adding it to the session set takes effect immediately")

  -- Invalid input is a no-op rather than an error: `add_session` is reached
  -- from a keymap over whatever is under the cursor, which can be nothing.
  ignore.add_session("")
  ---@diagnostic disable-next-line: param-type-mismatch
  ignore.add_session(nil)
  H.falsy(ignore.has(""), "an empty word is not added")

  -- filter -----------------------------------------------------------------------
  local issues = {
    { word = unknown, lnum = 1, col = 0 },
    { word = "genuinelymisspelt", lnum = 2, col = 4 },
  }
  local kept = ignore.filter(issues)
  H.eq(#kept, 1, "an ignored word is filtered out")
  H.eq(kept[1].word, "genuinelymisspelt", "and the others survive")

  -- The filter returns a new list rather than editing in place: the caller may
  -- still want the unfiltered result (a count, a "N ignored" note).
  H.eq(#issues, 2, "the input list is not modified")

  H.eq(#ignore.filter({}), 0, "an empty list filters to an empty list")

  -- add_persistent -------------------------------------------------------------
  -- Redirected to a fixture file rather than the real `stdpath("state")` one,
  -- so this can run on every push without touching the developer's own ignore
  -- list. A fresh module instance is forced so `ensure_loaded()` reads the
  -- fixture path instead of whatever it already cached above.
  local dir, cleanup = H.fixture("ignore")
  local ignore_file = dir .. "/spell_ignore.txt"
  local config = require("language.config")
  config.setup({ spell = { dictionary = { ignore_file = ignore_file } } })

  package.loaded["language.spell.core.ignore"] = nil
  local fresh = require("language.spell.core.ignore")

  local ok_bad, err_bad = fresh.add_persistent("")
  H.falsy(ok_bad, "an empty word is rejected")
  H.eq(err_bad, "empty word", "with a specific reason")
  H.eq(vim.fn.filereadable(ignore_file), 0, "and no file is created for it")

  local ok_good, err_good = fresh.add_persistent("verboten")
  H.ok(ok_good, "a real word persists: " .. tostring(err_good))
  H.ok(fresh.has("verboten"), "and takes effect immediately in the in-memory set")
  H.contains(H.read(ignore_file), "verboten", "and is written to the ignore file")

  -- A second word appends rather than overwrites.
  fresh.add_persistent("dorff")
  local contents = H.read(ignore_file)
  H.contains(contents, "verboten", "the first word survives a second write")
  H.contains(contents, "dorff", "and the second is appended")

  package.loaded["language.spell.core.ignore"] = nil
  config.setup({})
  cleanup()
end
