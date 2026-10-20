-- TESTS/translate_markdown_slice_spec.lua -- the cooperative slicing of translate_markdown:
-- a big document never blocks the event loop for long (a timer measures the gaps), the result
-- is the one of the unsliced run (fixtures and a fuzz, with a yield at every interruption
-- point), and the contract of the callback survives the gaps (exactly once, never before the
-- call returned, a cancel or a stale token between two slices ends the work).
-- No network, no curl.

return function(H)
  local md = require("language.translate.markdown")
  local slice = require("language.translate.markdown.slice")
  local helpers = dofile(vim.fn.getcwd() .. "/TESTS/markdown_helpers.lua")
  local run, fake = helpers.run, helpers.fake
  local uv = vim.uv or vim.loop

  md.cache._reset()

  ---Deep equality (`H.eq` compares by identity).
  ---@param a any
  ---@param b any
  ---@param msg string
  local function deq(a, b, msg)
    if not vim.deep_equal(a, b) then
      error(("FAIL %s: expected %s, got %s"):format(msg, vim.inspect(b), vim.inspect(a)), 2)
    end
  end

  --- A deterministic "translation": every long word reversed (placeholders `{n}` stay).
  local function scramble(text)
    return (text:gsub("%a%a%a+", function(w)
      return w:reverse()
    end))
  end

  -- slice.lua: the driver on its own ------------------------------------------------------------
  do
    local log = {}
    local stop = false
    local sl = slice.new({
      budget_ms = 0,
      stop = function()
        return stop
      end,
      on_error = function(err)
        log[#log + 1] = "error:" .. tostring(err):gsub("^.-:%d+: ", "")
      end,
    })
    sl.tick() -- outside of a computation: a no-op, not an error
    H.eq(sl.yields(), 0, "a tick outside of a computation yields nothing")

    sl.run(function()
      log[#log + 1] = "a"
      sl.tick()
      log[#log + 1] = "b"
      sl.tick()
      log[#log + 1] = "c"
    end)
    H.eq(table.concat(log, ","), "a", "with a budget of 0 the first tick gives the control away")
    vim.wait(500, function()
      return #log >= 3
    end, 1)
    H.eq(table.concat(log, ","), "a,b,c", "and the work goes on in later turns, in order")
    H.eq(sl.yields(), 2)

    -- stop() is asked before each resume: an abandoned computation never continues.
    log = {}
    sl.run(function()
      log[#log + 1] = "x"
      sl.tick()
      log[#log + 1] = "never"
    end)
    stop = true
    vim.wait(60, function()
      return false
    end, 5)
    H.eq(table.concat(log, ","), "x", "stop() = true abandons the computation")
    stop = false

    -- ... and before the FIRST slice, too: a token that tipped before run() never starts the body
    log = {}
    local asked = 0
    local early = slice.new({
      budget_ms = 0,
      stop = function()
        asked = asked + 1
        return true
      end,
      on_error = function(err)
        log[#log + 1] = "error:" .. tostring(err)
      end,
    })
    early.run(function()
      log[#log + 1] = "started"
    end)
    H.eq(asked, 1, "stop() is asked before the first slice")
    H.eq(table.concat(log, ","), "", "a stop before the first slice never starts the body")
    H.eq(early.yields(), 0)

    -- an error comes out through on_error, from the first and from a later slice
    log = {}
    sl.run(function()
      error("first", 0)
    end)
    H.eq(log[1], "error:first", "an error of the first slice")
    log = {}
    sl.run(function()
      sl.tick()
      error("later", 0)
    end)
    vim.wait(500, function()
      return #log > 0
    end, 1)
    H.eq(log[1], "error:later", "an error of a later slice")

    -- a generous budget never yields; the work is done when run() returns
    local big = slice.new({
      budget_ms = 1e9,
      stop = function()
        return false
      end,
      on_error = error,
    })
    local done = false
    big.run(function()
      for _ = 1, 1000 do
        big.tick()
      end
      done = true
    end)
    H.ok(done, "inside the first slice run() returns after the body did")
    H.eq(big.yields(), 0)
  end

  -- the interruption points of the phases (what a stall test on a document can not pin down: a
  -- phase that is cheap on the test document is still one that has to be able to give way) -------
  do
    local segment = require("language.translate.markdown.segment")
    local anchors = require("language.translate.markdown.anchors")
    local lines = {}
    for i = 1, 60 do
      lines[#lines + 1] = (i % 5 == 0) and "" or ("Zeile " .. i .. " mit `code`")
    end

    local n = 0
    local seg = segment.segment(lines, function()
      n = n + 1
    end)
    H.ok(n >= #lines, "segment: a tick for every line, " .. n .. " for " .. #lines)
    local n_edge = 0
    segment.segment(helpers.fixture("edge_de.md"), function()
      n_edge = n_edge + 1
    end)
    H.ok(n_edge > 30, "segment: and for a document with edge cases")
    deq(seg, segment.segment(lines), "segment: a tick changes nothing")

    n = 0
    local out = segment.render(seg, {}, nil, nil, function()
      n = n + 1
    end)
    H.eq(n, #lines, "render: a tick for every line")
    deq(out, segment.render(seg, {}), "render: a tick changes nothing")
    n = 0
    segment.render(seg, {}, 3, 7, function()
      n = n + 1
    end)
    H.eq(n, 5, "render: only for the lines asked for")

    n = 0
    local old, new = { "Alpha", "Beta", "Alpha", "Gamma" }, { "A", "B", "A", "B" }
    local map, changed, collisions = anchors.build_map(old, new, function()
      n = n + 1
    end)
    H.eq(n, #old, "build_map: a tick for every heading")
    local map2, changed2, collisions2 = anchors.build_map(old, new)
    deq({ map, changed, collisions }, { map2, changed2, collisions2 }, "build_map: no change")
  end

  -- the result is the one of the unsliced run -----------------------------------------------------

  ---@param lines string[]
  ---@param opts table
  ---@return table
  local function summary(lines, opts)
    local events = {}
    local r = run(
      lines,
      vim.tbl_extend("force", {
        on_unit = function(ev)
          events[ev.first] = ev.status .. "|" .. ev.last .. "|" .. table.concat(ev.lines, "\n")
        end,
      }, opts)
    )
    local info = vim.deepcopy(r.info or {})
    local slices = info.slices
    info.ms, info.slices = nil, nil
    return { ok = r.ok, res = r.res, calls = r.calls, info = info, events = events, slices = slices }
  end

  ---@param lines string[]
  ---@param make fun(): table  -- a fresh provider per run
  ---@param what string
  ---@param extra? table  -- more options of both runs
  local function same_as_unsliced(lines, make, what, extra)
    local a =
      summary(lines, vim.tbl_extend("force", extra or {}, { provider = make(), slice_ms = 1e9 }))
    local b =
      summary(lines, vim.tbl_extend("force", extra or {}, { provider = make(), slice_ms = 0 }))
    H.ok(a.ok, what .. ": the unsliced run ends well")
    H.eq(a.slices, 0, what .. ": a huge budget never yields")
    H.ok((b.slices or 0) > 0, what .. ": the sliced run did yield")
    H.eq(b.ok, a.ok, what)
    H.eq(b.calls, 1, what .. ": cb exactly once")
    H.eq(#b.res, #lines, what .. ": line count")
    for i = 1, #a.res do
      if a.res[i] ~= b.res[i] then
        error(("%s: line %d differs: %q vs %q"):format(what, i, a.res[i], tostring(b.res[i])))
      end
    end
    -- the order of `info.errors` is the order in which the work finished: it may differ (see the header of
    -- translate/markdown/init.lua), the set of messages may not
    table.sort(a.info.errors or {})
    table.sort(b.info.errors or {})
    deq(b.info, a.info, what .. ": info")
    deq(b.events, a.events, what .. ": the blocks reported")
  end

  do
    local fixtures = { "edge_de.md", "readme_de.md" }
    for _, name in ipairs(fixtures) do
      local lines = helpers.fixture(name)
      same_as_unsliced(lines, function()
        return fake(scramble, { sync = true })
      end, name .. " (sync engine)")
      same_as_unsliced(lines, function()
        return fake(scramble, { delay_ms = 0 })
      end, name .. " (async engine)")
    end
  end

  -- Warm cache: the cache pass slices too, and still reports everything.
  do
    local lines = helpers.fixture("readme_de.md")
    md.cache._reset()
    local cfg = { markdown = { disk_cache = false } }
    local first =
      run(lines, { provider = fake(scramble, { sync = true }), cache = true, cfg = cfg })
    H.ok(first.ok)
    -- (the engine is part of the cache key: the same provider, but one that must not be asked)
    local function never()
      return fake(function()
        error("a cached unit must not be sent again")
      end, { sync = true })
    end
    local opts = { cache_only = true, cache = true, cfg = cfg }
    local a = run(lines, vim.tbl_extend("force", opts, { slice_ms = 1e9, provider = never() }))
    local b = run(lines, vim.tbl_extend("force", opts, { slice_ms = 0, provider = never() }))
    H.ok(a.ok and b.ok)
    deq(b.res, a.res, "cache_only: the same lines")
    deq(b.res, first.res, "cache_only: what the engine said")
    H.eq(b.info.cached, a.info.cached)
    H.ok(b.info.slices > 0, "the cache pass of a warm cache yielded")
    H.eq(a.info.slices, 0)
    md.cache._reset()
  end

  -- fuzz: any mixture, a yield at every interruption point -----------------------------------------
  do
    math.randomseed(20261017)
    local pool = {
      "# Einleitung",
      "## Verwendung [siehe](#einleitung)",
      "## Installation",
      "Ein Absatz mit `code` und einem [Link](#installation) darin.",
      "Zweite Zeile des Absatzes mit vielen Woertern",
      "dritte Zeile mit noch mehr Text darin.",
      "",
      "",
      "- Listenpunkt eins mit Text",
      "- Listenpunkt zwei [Ziel](#verwendung)",
      "  - verschachtelt mit Einrueckung",
      "1. nummeriert mit Text",
      "> Zitat mit mehreren Woertern",
      "> und einer Fortsetzung",
      "| Spalte A | Spalte B |",
      "| --- | --- |",
      "| Zelle eins | Zelle zwei |",
      "```lua",
      "local x = 1",
      "```",
      "~~~",
      "<div>",
      "</div>",
      "Setext Titel",
      "=====",
      "[ref]: #einleitung",
      "Text mit Umbruch\\",
      "und Fortsetzung  ",
      "![Bild](a.png) Text",
      "Fussnote[^1] hier",
      "[^1]: Notiz zur Fussnote",
      "$$",
      "x = y",
      "$$",
    }
    local modes = {
      scramble,
      function(t)
        return scramble(t) .. " and some extra words"
      end,
      function(t)
        local words = {}
        for w in scramble(t):gmatch("%S+") do
          words[#words + 1] = w
        end
        return table.concat(words, " ", 1, math.max(1, math.ceil(#words / 2)))
      end,
      function()
        return "- - -"
      end,
      function(t)
        return t:find("Text", 1, true) and "" or scramble(t)
      end,
    }
    for iter = 1, 120 do
      local doc = {}
      if math.random() < 0.2 then
        doc = { "---", "title: x", "---" }
      end
      for _ = 1, math.random(1, 30) do
        doc[#doc + 1] = pool[math.random(#pool)]
      end
      local fn = modes[math.random(#modes)]
      local max_units = math.random(1, 6)
      local async = math.random() < 0.5
      local what = ("fuzz %d (%s)"):format(iter, table.concat(doc, "\\n"))
      same_as_unsliced(doc, function()
        return fake(fn, { sync = not async, delay_ms = async and 0 or nil })
      end, what, { max_units = max_units })
    end
  end

  -- a big document: the longest block of the event loop ---------------------------------------------

  ---A document of about `n` lines: paragraphs, lists, tables, fences, quotes, headings with links to
  ---each other.
  ---@param n integer
  ---@return string[]
  local function build(n)
    local out, i = {}, 0
    while #out < n do
      i = i + 1
      local k = i % 10
      if k == 0 then
        out[#out + 1] = "## Heading number " .. i
        out[#out + 1] = ""
      elseif k <= 3 then
        out[#out + 1] = ("Paragraph %d first line with `code` and [a link](https://example.com/%d)"):format(
          i,
          i
        )
        out[#out + 1] = "second line of paragraph " .. i .. " with more words in it"
        out[#out + 1] = ""
      elseif k <= 6 then
        out[#out + 1] = "- list item number "
          .. i
          .. " with some text and a [ref](#heading-number-"
          .. i
          .. ")"
      elseif k == 7 then
        out[#out + 1] = ""
        out[#out + 1] = "| col a | col b | col c |"
        out[#out + 1] = "| --- | --- | --- |"
        out[#out + 1] = "| cell " .. i .. " | cell two words | cell three |"
        out[#out + 1] = ""
      elseif k == 8 then
        out[#out + 1] = "```lua"
        out[#out + 1] = "local x = " .. i
        out[#out + 1] = "```"
      else
        out[#out + 1] = "> quote line " .. i .. " of the block"
        out[#out + 1] = ""
      end
    end
    return out
  end

  ---Translate `lines` and measure the longest time the event loop was not turned (a 1 ms timer).
  ---@param lines string[]
  ---@param opts table
  ---@return { calls: integer, ok: boolean, res: any, info: table|nil, sync: boolean, handle: table }, number worst_ms
  local function measured(lines, opts)
    local worst, last = 0, uv.hrtime()
    local timer = assert(uv.new_timer())
    timer:start(1, 1, function()
      local now = uv.hrtime()
      worst = math.max(worst, now - last)
      last = now
    end)
    local r = { calls = 0, sync = false }
    local returned = false
    r.handle = md.translate_markdown(
      lines,
      vim.tbl_extend(
        "force",
        { target = "EN", cache = false, cfg = { markdown = { disk_cache = false } } },
        opts
      ),
      function(ok, res, info)
        r.calls = r.calls + 1
        r.ok, r.res, r.info = ok, res, info
        r.sync = r.sync or not returned
      end
    )
    returned = true
    last = uv.hrtime()
    vim.wait(60000, function()
      return r.calls > 0
    end, 1)
    -- (the wait ends as soon as cb has run: a stall that ends with the last callback would
    -- otherwise never be seen by the timer)
    worst = math.max(worst, uv.hrtime() - last)
    timer:stop()
    timer:close()
    return r, worst / 1e6
  end

  local LIMIT_MS = 50

  ---One measurement can be hit by something outside of the code (a GC step, a busy CI machine):
  ---the better of two runs counts. A real stall of 200 ms shows in both.
  ---@param lines string[]
  ---@param make_opts fun(): table
  ---@return table r, number worst_ms
  local function best_of_two(lines, make_opts)
    local r, w = measured(lines, make_opts())
    if w >= LIMIT_MS then
      local r2, w2 = measured(lines, make_opts())
      if w2 < w then
        r, w = r2, w2
      end
    end
    return r, w
  end

  local BIG = build(20000)
  H.ok(#BIG >= 20000)
  local N_UNITS = #require("language.translate.markdown.segment").segment(BIG).units

  -- 10 000 headings (the anchor map has to look at each of them) and one text 20 000 times
  -- (one cache entry stands for 20 000 units). Half the size of the first version of this spec on
  -- purpose, so the file stays well inside the time a spec file may take (figures: docs/FEATURES/
  -- TRANSLATE.md, "Specs"). What a smaller document can no longer show in time is pinned by
  -- counting the ticks (translate_markdown_slice_sites_spec).
  local HEADINGS, SAME = {}, {}
  for i = 1, 10000 do
    HEADINGS[#HEADINGS + 1] = "## Abschnitt " .. i
    HEADINGS[#HEADINGS + 1] = ""
  end
  for i = 1, 20000 do
    SAME[i] = "- the same list item text with more words"
  end

  local cfg = { markdown = { disk_cache = false } }

  ---@param what string
  ---@param lines string[]
  ---@param modes string[]
  ---@param extra? table  -- more options of every run
  local function stall_free(what, lines, modes, extra)
    local base = summary(lines, { provider = fake(scramble, { sync = true }), slice_ms = 1e9 })
    H.ok(base.ok, what .. ": the unsliced reference run")
    local warm = false
    for _, mode in ipairs(modes) do
      local cached = mode == "cache pass" or mode == "cache_only"
      if cached and not warm then
        md.cache._reset()
        local w =
          run(lines, { provider = fake(scramble, { sync = true }), cache = true, cfg = cfg })
        H.ok(w.ok, what .. ": warming the cache")
        warm = true
      end
      local label = what .. ", " .. mode
      local r, worst = best_of_two(lines, function()
        return vim.tbl_extend("force", extra or {}, {
          target = "EN",
          cache = cached,
          cache_only = mode == "cache_only",
          cfg = cfg,
          provider = cached
              and fake(function()
                error("a cached unit must not be sent again")
              end, { sync = true })
            or (
              mode == "sync engine" and fake(scramble, { sync = true })
              or fake(scramble, {
                delay_ms = 0,
              })
            ),
        })
      end)
      H.ok(r.ok, label .. ": " .. tostring(r.res))
      H.falsy(r.sync, label .. ": cb never runs before translate_markdown has returned")
      H.eq(r.calls, 1, label .. ": cb exactly once")
      H.ok(
        worst < LIMIT_MS,
        ("%s: the event loop was blocked for %.1f ms at a time"):format(label, worst)
      )
      H.ok(r.info.slices >= 10, label .. ": the work was handed back " .. r.info.slices .. " times")
      if cached then
        H.ok(r.info.cached > 0 and r.info.requests == 0, label .. ": answered from the cache")
      end
      H.eq(#r.res, #lines)
      deq(r.res, base.res, label .. ": the unsliced result")
    end
    md.cache._reset()
  end

  stall_free("mixed", BIG, { "sync engine", "async engine", "cache pass", "cache_only" })
  stall_free("10 000 headings", HEADINGS, { "async engine", "cache_only" })
  -- (with a progress callback: every finished block is rendered for it)
  stall_free(
    "one text 20 000 times",
    SAME,
    { "async engine", "cache pass" },
    { on_unit = function() end }
  )

  -- a table under 2 000 lines and 64 kB is not a small document: a cell is a unit (8 800 of them) -------
  do
    local TABLE = { "| " .. ("K | "):rep(7) .. "K |", "| " .. ("--- | "):rep(7) .. "--- |" }
    for r = 1, 1100 do
      local cells = {}
      for c = 1, 8 do
        cells[c] = "z" .. ((r * 7 + c) % 100)
      end
      TABLE[#TABLE + 1] = "| " .. table.concat(cells, " | ") .. " |"
    end
    local bytes = 0
    for _, l in ipairs(TABLE) do
      bytes = bytes + #l
    end
    H.ok(#TABLE < 2000 and bytes < 64 * 1024, "under both limits of the lines and the bytes")
    local base = summary(TABLE, { provider = fake(scramble, { sync = true }), slice_ms = 1e9 })
    H.ok(base.ok, "the unsliced reference run")
    for _, mode in ipairs({ "sync engine", "async engine" }) do
      local label = "a table of 8 800 cells, " .. mode
      local r, worst = best_of_two(TABLE, function()
        return {
          target = "EN",
          cache = false,
          cfg = cfg,
          provider = mode == "sync engine" and fake(scramble, { sync = true })
            or fake(scramble, { delay_ms = 0 }),
        }
      end)
      H.ok(r.ok, label .. ": " .. tostring(r.res))
      H.falsy(r.sync, label .. ": cb never runs before translate_markdown has returned")
      H.eq(r.calls, 1, label .. ": cb exactly once")
      H.ok(r.info.slices > 0, label .. ": the work was handed back " .. r.info.slices .. " times")
      H.ok(
        worst < LIMIT_MS,
        ("%s: the event loop was blocked for %.1f ms at a time"):format(label, worst)
      )
      deq(r.res, base.res, label .. ": the unsliced result")
    end
  end

  -- a small document is not sliced ------------------------------------------------------------------
  do
    local small = build(1000)
    local bytes = 0
    for _, l in ipairs(small) do
      bytes = bytes + #l
    end
    H.ok(bytes < 64 * 1024, "the document is small by bytes, too: " .. bytes)
    local calls_sync = false
    local returned = false
    local got
    md.translate_markdown(small, {
      target = "EN",
      cache = false,
      cfg = { markdown = { disk_cache = false } },
      provider = fake(scramble, { sync = true }),
    }, function(ok, res, info)
      got = { ok = ok, res = res, info = info }
      calls_sync = calls_sync or not returned
    end)
    returned = true
    H.falsy(got, "never before translate_markdown has returned")
    -- One turn of the main loop: this probe is queued behind the one that starts the work, so a
    -- document that is worked on in the first slice has called back by the time it runs. A work
    -- that waits for a timer in between (a slice that was given away) would not have.
    local got_at_probe
    vim.schedule(function()
      got_at_probe = got ~= nil
    end)
    vim.wait(2000, function()
      return got ~= nil and got_at_probe ~= nil
    end, 1)
    H.ok(got and got.ok, "a small document is translated")
    H.eq(got.info.slices, 0, "under 2 000 lines and 64 kB the work is not sliced")
    H.eq(
      got_at_probe,
      true,
      "a small document calls back in the same turn of the loop, no timer in between"
    )
  end

  -- cancel and stale between two slices: the work really stops -----------------------------------------

  ---Count the calls of `mask.mask`, the one step that runs once per unit of the document (a phase
  ---that ends with the call being reported: tens of thousands of them are seconds of CPU).
  ---@return fun(): integer count, fun() restore
  local function count_mask()
    local mask = require("language.translate.markdown.mask")
    local orig, n = mask.mask, 0
    mask.mask = function(...)
      n = n + 1
      return orig(...)
    end
    return function()
      return n
    end, function()
      mask.mask = orig
    end
  end

  do
    local masked, restore = count_mask()
    local p = fake(scramble, { delay_ms = 0 })
    local r = { calls = 0 }
    local handle = md.translate_markdown(BIG, {
      target = "EN",
      cache = false,
      cfg = { markdown = { disk_cache = false } },
      provider = p,
      slice_ms = 2,
    }, function(ok, res, info)
      r.calls = r.calls + 1
      r.ok, r.res, r.info = ok, res, info
    end)
    -- (in the middle of the mask phase: the units of a big document are far more than a few slices)
    vim.wait(20000, function()
      return masked() >= 50
    end, 1)
    H.ok(masked() >= 50, "the mask phase is under way")
    H.ok(masked() < N_UNITS / 2, "and far from done: " .. masked())
    H.eq(r.calls, 0, "the document is still being worked on")
    handle.cancel()
    local at_cancel = masked()
    H.eq(r.calls, 1, "cancel() reports at once")
    H.eq(r.ok, false)
    H.eq(r.res, "cancelled")
    vim.wait(400, function()
      return false
    end, 10)
    restore()
    H.eq(r.calls, 1, "and never again")
    H.eq(masked(), at_cancel, "the abandoned work did not go on: not a single unit more was masked")
    H.eq(#p.calls, 0, "and did not go on to ask the engine")
  end

  do
    local masked, restore = count_mask()
    local p = fake(scramble, { delay_ms = 0 })
    local gen = 1
    local r = { calls = 0 }
    md.translate_markdown(BIG, {
      target = "EN",
      cache = false,
      cfg = { markdown = { disk_cache = false } },
      provider = p,
      slice_ms = 2,
      token = {
        generation = 1,
        current = function()
          return gen
        end,
      },
    }, function(ok, res, info)
      r.calls = r.calls + 1
      r.ok, r.res, r.info = ok, res, info
    end)
    vim.wait(20000, function()
      return masked() >= 50
    end, 1)
    H.ok(masked() >= 50, "the mask phase is under way")
    H.eq(r.calls, 0, "still working")
    gen = 2
    vim.wait(1500, function()
      return r.calls > 0
    end, 5)
    local at_stale = masked()
    vim.wait(400, function()
      return false
    end, 10)
    restore()
    H.eq(r.calls, 1, "a stale token ends the work between two slices, reported once")
    H.eq(r.ok, false)
    H.eq(r.res, "stale")
    H.ok(at_stale < N_UNITS / 2, "stopped in the middle of the mask phase: " .. at_stale)
    H.eq(masked(), at_stale, "the abandoned work did not go on: not a single unit more was masked")
    H.eq(#p.calls, 0, "without asking the engine")
  end

  -- an engine that fails for good, answered while pump() is given away -------------------------------
  -- (3 failures in a row end the rest of the requests: `pending` is emptied in the middle of a
  -- yield of the pump. A unit that could not be translated is never an error of the call.)
  for _, concurrency in ipairs({ 2, 3 }) do
    local doc = {}
    for i = 1, 40 do
      doc[#doc + 1] = "Paragraph number " .. i .. " has some words in it"
      doc[#doc + 1] = ""
    end
    local sent = 0
    local failing = fake(scramble, {
      on_request = function(_, cb)
        sent = sent + 1
        vim.schedule(function()
          cb(false, "HTTP 401")
        end)
        return { cancel = function() end }
      end,
    })
    local r = run(doc, {
      provider = failing,
      max_units = 1,
      concurrency = concurrency,
      slice_ms = 0,
    })
    local what = "a failing engine, concurrency " .. concurrency
    H.eq(r.calls, 1, what .. ": cb exactly once")
    H.ok(r.ok, what .. ": the call does not fail: " .. tostring(r.ok or r.res))
    deq(r.res, doc, what .. ": every unit stays the original")
    H.eq(r.info.failed, 40, what .. ": all units are counted as failed")
    H.ok(sent >= 3 and sent < 40, what .. ": the rest was given up after repeated failures")
  end

  -- errors ---------------------------------------------------------------------------------------------
  do
    -- on_unit runs under pcall: its error does not end the translation
    local r = { calls = 0 }
    md.translate_markdown(build(300), {
      target = "EN",
      cache = false,
      cfg = { markdown = { disk_cache = false } },
      slice_ms = 0,
      provider = fake(scramble, { delay_ms = 0 }),
      on_unit = function()
        error("boom")
      end,
    }, function(ok, res, info)
      r.calls = r.calls + 1
      r.ok, r.res, r.info = ok, res, info
    end)
    vim.wait(20000, function()
      return r.calls > 0
    end, 2)
    H.eq(r.calls, 1)
    H.ok(r.ok, "on_unit is called under pcall: its error does not end the translation")

    -- a bug inside a later slice ends the call with the message, once
    md.cache._reset()
    local orig_get = md.cache.get
    local n = 0
    md.cache.get = function(...)
      n = n + 1
      if n == 5 then
        error("cache exploded", 0)
      end
      return orig_get(...)
    end
    r = { calls = 0 }
    local ok_run = pcall(function()
      md.translate_markdown(build(300), {
        target = "EN",
        cache = true,
        cfg = { markdown = { disk_cache = false } },
        slice_ms = 0,
        provider = fake(scramble, { sync = true }),
      }, function(ok, res, info)
        r.calls = r.calls + 1
        r.ok, r.res, r.info = ok, res, info
      end)
      vim.wait(20000, function()
        return r.calls > 0
      end, 2)
    end)
    md.cache.get = orig_get
    H.ok(ok_run)
    H.eq(r.calls, 1, "an error of a later slice: cb exactly once")
    H.eq(r.ok, false)
    H.eq(r.res, "translate_markdown: cache exploded")
    md.cache._reset()

    -- an error thrown by cb itself is not swallowed
    local notified = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      notified[#notified + 1] = { msg = msg, level = level }
    end
    local called = 0
    md.translate_markdown(build(120), {
      target = "EN",
      cache = false,
      cfg = { markdown = { disk_cache = false } },
      slice_ms = 0,
      provider = fake(scramble, { delay_ms = 0 }),
    }, function()
      called = called + 1
      error("cb exploded", 0)
    end)
    vim.wait(20000, function()
      return called > 0
    end, 2)
    vim.wait(30, function()
      return false
    end, 5)
    vim.notify = orig_notify
    H.eq(called, 1, "cb ran once")
    H.eq(#notified, 1, "and its error was reported")
    H.contains(notified[1].msg, "cb exploded")
    H.eq(notified[1].level, vim.log.levels.ERROR)
  end
end
