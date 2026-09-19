-- TESTS/wordlists_spec.lua — language.spell.programming_dict +
-- language.spell.extra_dict: session wordlists applied via `:spellgood!`.
--
-- Both modules schedule their `:spellgood!` calls with vim.schedule, so the
-- actual dictionary mutation is drained with vim.wait rather than asserted
-- synchronously.

return function(H)
  -- extra_dict: applies once per list name, guards against non-table input --
  local extra = require("language.spell.extra_dict")

  extra.ensure("not-a-table") -- must not error
  extra.ensure(nil) -- must not error

  local WORD = "zzqqxxextradicttest"
  extra.ensure({ mylist = { WORD, "" } }) -- an empty string entry must not error either
  vim.wait(200, function()
    local errs = vim.spell.check(WORD)[1]
    return not (errs and errs[1] == WORD)
  end)
  H.falsy(
    (vim.spell.check(WORD)[1] or {})[1] == WORD,
    "the wordlist word is no longer flagged as bad"
  )

  -- Idempotent per list name: a second call with the same name is a no-op —
  -- exercised as "does not error and does not un-apply anything", since there
  -- is no externally observable difference between "already applied" and
  -- "applied again" other than not re-running :spellgood!.
  extra.ensure({ mylist = { WORD } })

  -- A second, distinct list name is applied independently.
  local WORD2 = "zzqqxxextradicttesttwo"
  extra.ensure({ otherlist = { WORD2 } })
  vim.wait(200, function()
    local errs = vim.spell.check(WORD2)[1]
    return not (errs and errs[1] == WORD2)
  end)
  H.falsy((vim.spell.check(WORD2)[1] or {})[1] == WORD2, "the second list's word is applied too")

  -- SEC-35: an entry containing `|` must not chain a second Ex command -- it
  -- is passed as a real API argument (table-form vim.cmd), never spliced
  -- into a command string.
  vim.g.sec35_extra_dict_leaked = nil
  extra.ensure({ injection = { "evil|let g:sec35_extra_dict_leaked=1" } })
  vim.wait(200)
  H.falsy(vim.g.sec35_extra_dict_leaked, "the '|' did not chain a second Ex command")

  -- programming_dict: loads the bundled wordlist, once ------------------------
  local prog = require("language.spell.programming_dict")
  local words = require("language.spell.data.programming")
  H.ok(type(words) == "table" and #words > 0, "the bundled wordlist is a non-empty list")

  local sample = words[1]
  prog.ensure()
  vim.wait(300, function()
    local errs = vim.spell.check(sample)[1]
    return not (errs and errs[1] == sample)
  end)
  H.falsy(
    (vim.spell.check(sample)[1] or {})[1] == sample,
    "a word from the bundled list is no longer flagged after ensure()"
  )

  prog.ensure() -- idempotent: must not error or double-schedule
end
