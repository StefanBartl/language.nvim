-- TESTS/wordlists_spec.lua — language.spell.programming_dict +
-- language.spell.extra_dict: session wordlists, and language.spell.
-- session_words, which adds them without one `:spellgood!` per word.
--
-- The words arrive on a later main-loop tick (vim.schedule), so the actual
-- dictionary mutation is drained with vim.wait rather than asserted
-- synchronously.

---@param word string
---@return boolean
local function flagged(word)
  local errs = vim.spell.check(word)[1]
  return errs ~= nil and errs[1] == word
end

---Count the `:spellgood` commands `fn` causes, including scheduled ones.
---`vim.cmd` is restored whatever `fn` does: a failing assert in here must not
---leave the counter installed for every spec that runs after this one.
---@param fn fun()
---@param done fun(): boolean
---@return integer
local function count_spellgood(fn, done)
  local orig, n = vim.cmd, 0
  vim.cmd = setmetatable({}, {
    __index = orig,
    __call = function(_, command)
      if type(command) == "table" and command.cmd == "spellgood" then
        n = n + 1
      end
      return orig(command)
    end,
  })
  local ok, err = pcall(function()
    fn()
    -- vim.wait tests its condition BEFORE it runs any event: with a `done` that is
    -- true at once it would return before the flush `fn` scheduled has run, and
    -- the count would be read too early. The queue is FIFO, so a sentinel
    -- scheduled now runs after everything `fn` scheduled.
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    vim.wait(2000, function()
      return drained
    end, 5)
    vim.wait(2000, done, 5)
  end)
  vim.cmd = orig
  if not ok then
    error(err, 0)
  end
  return n
end

---@param prefix string
---@param n integer
---@return string[]
local function made_up_words(prefix, n)
  local words = {}
  for i = 1, n do
    -- Letters only: the native checker does not treat digits as word chars.
    local suffix = {}
    for digit in tostring(i):gmatch("%d") do
      suffix[#suffix + 1] = string.char(("a"):byte() + tonumber(digit))
    end
    words[i] = prefix .. table.concat(suffix)
  end
  return words
end

return function(H)
  -- session_words: many words, two compiles -----------------------------------
  local session = require("language.spell.session_words")

  session.add(nil) -- must not error
  session.add("not-a-table") -- must not error

  local many = made_up_words("zzqqxxfast", 300)
  local calls = count_spellgood(function()
    session.add(many)
  end, function()
    return not flagged(many[#many])
  end)
  H.ok(calls <= 2, ("300 words cost %d :spellgood! commands, not one each"):format(calls))
  for _, i in ipairs({ 1, 2, 150, 299, 300 }) do
    H.falsy(flagged(many[i]), ("word %d of the batch is known"):format(i))
  end

  -- Words added before are not added again, in the same call or a later one.
  calls = count_spellgood(function()
    session.add({ many[1], many[2], many[1] })
  end, function()
    return true
  end)
  H.eq(calls, 0, "known words cause no command at all")

  -- Entries Neovim would refuse are dropped, the rest of the batch still lands.
  local mixed = made_up_words("zzqqxxmixed", 5)
  -- The malformed UTF-8 entry sits in the MIDDLE on purpose: that is the part
  -- written to the list file without passing `:spellgood`'s own check, and one
  -- such line makes the compile of the whole file give up silently -- these
  -- words and every later one of the session would stay unknown.
  local batch = { mixed[1], "", 42, "ctrl\ncharacter", "trailing/", "zzqqxxbad\255\254utf" }
  vim.list_extend(batch, mixed, 2)
  local umlaut = "zzqqxxmixedüäö"
  table.insert(batch, #batch, umlaut)
  -- Counted: a control character that slipped through the filter would be
  -- written as two lines, the line count check after the last command would
  -- fail, and the batch would fall back to one command per word.
  local mixed_calls = count_spellgood(function()
    session.add(batch)
  end, function()
    return not flagged(mixed[5])
  end)
  H.ok(mixed_calls <= 2, ("a batch with invalid entries costs %d commands"):format(mixed_calls))
  for i = 1, 5 do
    H.falsy(flagged(mixed[i]), ("valid word %d next to invalid entries is known"):format(i))
  end
  H.falsy(flagged(umlaut), "a word with multi-byte characters passes the UTF-8 check")

  -- A blank-only entry (the Ex parser refuses it) and one with U+FEFF
  -- (readfile() strips it) cannot be the first or last word of the batch: the
  -- handshake would fail, and the whole batch would be added word by word --
  -- at the last position even twice. They are dropped before the batch is built.
  for _, edge in ipairs({ "first", "last" }) do
    for _, trap in ipairs({ "   ", "zzqqxxbom" .. edge .. "\239\187\191" }) do
      local good = made_up_words("zzqqxxedge" .. edge .. (trap:find("%S") and "bom" or "ws"), 6)
      local edge_words = vim.deepcopy(good)
      if edge == "first" then
        table.insert(edge_words, 1, trap)
      else
        edge_words[#edge_words + 1] = trap
      end
      local edge_calls = count_spellgood(function()
        session.add(edge_words)
      end, function()
        return not flagged(good[#good])
      end)
      H.ok(
        edge_calls <= 2,
        ("%q at the %s end of a batch costs %d commands"):format(trap, edge, edge_calls)
      )
      for i = 1, #good do
        H.falsy(
          flagged(good[i]),
          ("word %d next to %q at the %s end is known"):format(i, trap, edge)
        )
      end
    end
  end

  -- The list file cannot be found: one command per word, all of them still land.
  local slow = made_up_words("zzqqxxslow", 40)
  local find_list = session._find_list
  rawset(session, "_find_list", function()
    return nil
  end)
  local ok_slow, slow_calls = pcall(count_spellgood, function()
    session.add(slow)
  end, function()
    return not flagged(slow[#slow])
  end)
  rawset(session, "_find_list", find_list)
  H.ok(ok_slow, "the fallback path does not error: " .. tostring(slow_calls))
  H.eq(slow_calls, #slow, "without the list file every word takes its own command")
  for _, i in ipairs({ 1, 20, 40 }) do
    H.falsy(flagged(slow[i]), ("fallback word %d is known"):format(i))
  end

  -- A file that merely looks like the list (right last line, compiled sibling)
  -- is found out by the check after the final command, and the words go the
  -- slow way instead of being lost in it.
  local decoy_words = made_up_words("zzqqxxdecoy", 6)
  local decoy = vim.fn.tempname()
  vim.fn.writefile({ decoy_words[1] }, decoy)
  vim.fn.writefile({}, decoy .. "." .. vim.o.encoding .. ".spl")
  rawset(session, "_find_list", function()
    return decoy
  end)
  local ok_decoy, decoy_calls = pcall(count_spellgood, function()
    session.add(decoy_words)
  end, function()
    return not flagged(decoy_words[5])
  end)
  rawset(session, "_find_list", find_list)
  vim.fn.delete(decoy)
  vim.fn.delete(decoy .. "." .. vim.o.encoding .. ".spl")
  H.ok(ok_decoy, "a wrong list file does not error: " .. tostring(decoy_calls))
  for i = 1, 6 do
    H.falsy(flagged(decoy_words[i]), ("word %d is known despite the wrong list file"):format(i))
  end

  -- No temp dir (tempname() is ""): the lookup must not fall back to the cwd,
  -- where a file that merely looks like the list would be appended to.
  local nodir = vim.fn.tempname()
  vim.fn.mkdir(nodir, "p")
  local bait = nodir .. "/bait"
  vim.fn.writefile({ "zzqqxxnotmp" }, bait)
  vim.fn.writefile({}, bait .. "." .. vim.o.encoding .. ".spl")
  local old_cwd = vim.fn.getcwd()
  local real_tempname = vim.fn.tempname
  vim.cmd.cd(vim.fn.fnameescape(nodir))
  vim.fn.tempname = function()
    return ""
  end
  local ok_nt, found = pcall(session._find_list, "zzqqxxnotmp")
  vim.fn.tempname = real_tempname
  vim.cmd.cd(vim.fn.fnameescape(old_cwd))
  vim.fn.delete(nodir, "rf")
  H.ok(ok_nt, "lookup without a temp dir does not error")
  H.eq(found, nil, "lookup without a temp dir does not scan the cwd")

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

  -- Idempotent per list name: a second call with the same name is a no-op.
  -- A DIFFERENT word under the same name: with the same word, the dedup in
  -- session_words would hide a missing "applied" guard here.
  local again = count_spellgood(function()
    extra.ensure({ mylist = { "zzqqxxextradictother" } })
  end, function()
    return true
  end)
  H.eq(again, 0, "an applied list name is not applied again, whatever its words")

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
