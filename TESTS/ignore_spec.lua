-- TESTS/ignore_spec.lua — language.spell.core.ignore: the set of words the
-- user has told the spellchecker to stop reporting, and the filter that
-- applies it to a result list.
--
-- Only the session half is covered. `add_persistent` writes to
-- `stdpath("data")`, and a suite that ran on every push must not accumulate
-- entries in the developer's real ignore file.

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
end
