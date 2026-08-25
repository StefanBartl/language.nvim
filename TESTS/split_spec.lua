-- TESTS/split_spec.lua — language.spell.core.split: breaking an identifier into
-- the words a dictionary can actually be asked about.
--
-- This is what keeps `getUserName` from being reported as one unknown word.
-- Every subword carries its offset inside the original token, because that is
-- what turns a dictionary hit back into a highlight at the right column.

return function(H)
  local split = require("language.spell.core.split")

  local function subs(word)
    local out = {}
    for _, s in ipairs(split.split(word)) do
      out[#out + 1] = s.sub
    end
    return out
  end

  -- Plain words ---------------------------------------------------------------
  H.eq(#split.split("hello"), 1, "a plain word is one subword")
  H.eq(split.split("hello")[1].sub, "hello", "unchanged")
  H.eq(split.split("hello")[1].offset, 0, "at offset 0")

  -- camelCase / PascalCase ----------------------------------------------------
  H.eq(table.concat(subs("getName"), "|"), "get|Name", "lower to upper is a boundary")
  H.eq(table.concat(subs("GetName"), "|"), "Get|Name", "PascalCase splits the same way")

  -- The acronym rule ----------------------------------------------------------
  -- `HTTPServer` must be HTTP|Server, not H|T|T|P|Server: the boundary is an
  -- uppercase run followed by an uppercase-then-lowercase pair.
  H.eq(table.concat(subs("HTTPServer"), "|"), "HTTP|Server", "an acronym stays whole")
  H.eq(table.concat(subs("HTTP"), "|"), "HTTP", "a bare acronym is one word")

  -- Separators ----------------------------------------------------------------
  H.eq(table.concat(subs("snake_case_word"), "|"), "snake|case|word", "underscores separate")
  H.eq(table.concat(subs("kebab-case"), "|"), "kebab|case", "so do dashes")
  H.eq(table.concat(subs("utf8Encode"), "|"), "utf|Encode", "digits separate too")

  -- Offsets --------------------------------------------------------------------
  -- The offset is what a caller needs to place a highlight, so it has to point
  -- into the *original* token, separators included.
  local parts = split.split("get_name")
  H.eq(parts[1].offset, 0, "the first subword starts at 0")
  H.eq(parts[2].offset, 4, "and the second after the separator, not after the first word")

  -- Nothing to split -----------------------------------------------------------
  H.eq(#split.split(""), 0, "an empty token has no subwords")
  H.eq(#split.split("123"), 0, "and neither does one with no letters at all")

  -- is_compound ----------------------------------------------------------------
  -- The cheap pre-check that decides whether the full split is worth running.
  H.falsy(split.is_compound("hello"), "a plain word is not compound")
  H.ok(split.is_compound("getName"), "camelCase is")
  H.ok(split.is_compound("snake_case"), "an underscore is")
  H.ok(split.is_compound("utf8"), "a digit is")
  H.ok(split.is_compound("HTTPServer"), "and so is the acronym boundary")

  -- The pre-check must never say "no" where split() would have done work --
  -- that is the only way it can cost a real finding.
  for _, w in ipairs({ "getName", "HTTPServer", "snake_case", "kebab-case", "utf8Encode" }) do
    if #subs(w) > 1 then
      H.ok(split.is_compound(w), w .. ": is_compound agrees with split")
    end
  end
end
