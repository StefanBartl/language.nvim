-- TESTS/translate_markdown_slice_sites_spec.lua -- the places where translate_markdown can be
-- interrupted, pinned one by one. Cheap on purpose (no big document, no stall measurement: that is
-- translate_markdown_slice_spec.lua): the ticks are COUNTED between markers of the pipeline, so a
-- removed `tick()` call shows as a smaller number, whatever the machine. The rest: the slicer never
-- reading the clock with an unlimited budget, what counts as a small document, the booking of an
-- answer for a text that occurs thousands of times, and what the order of `on_unit` guarantees.
-- No network, no curl.

return function(H)
  local md = require("language.translate.markdown")
  local slice = require("language.translate.markdown.slice")
  local segment = require("language.translate.markdown.segment")
  local anchors = require("language.translate.markdown.anchors")
  local mask = require("language.translate.markdown.mask")
  local cache = require("language.translate.markdown.cache")
  local reflow = require("language.translate.markdown.reflow")
  local helpers = dofile(vim.fn.getcwd() .. "/TESTS/markdown_helpers.lua")
  local run, fake = helpers.run, helpers.fake
  local uv = vim.uv or vim.loop

  md.cache._reset()

  --- A deterministic "translation": every long word reversed (placeholders `{n}` stay).
  local function scramble(text)
    return (text:gsub("%a%a%a+", function(w)
      return w:reverse()
    end))
  end

  ---Replace fields of `tbl` while `fn` runs; they are put back whatever happens.
  ---@param tbl table
  ---@param repl table<string, any>
  ---@param fn fun()
  local function patched(tbl, repl, fn)
    local saved = {}
    for k in pairs(repl) do
      saved[k] = tbl[k]
    end
    for k, v in pairs(repl) do
      tbl[k] = v
    end
    local ok, err = pcall(fn)
    for k, v in pairs(saved) do
      tbl[k] = v
    end
    if not ok then
      error(err, 0)
    end
  end

  -- an unlimited budget does not read the clock ---------------------------------------------------

  ---How often the clock was read while a computation of 1000 interruption points ran.
  ---@param budget number
  ---@return integer
  local function clock_reads(budget)
    local reads, real = 0, uv.hrtime
    local ran = false
    patched(uv, {
      hrtime = function()
        reads = reads + 1
        return real()
      end,
    }, function()
      local sl = slice.new({
        budget_ms = budget,
        stop = function()
          return false
        end,
        on_error = error,
      })
      sl.run(function()
        for _ = 1, 1000 do
          sl.tick()
        end
        ran = true
      end)
    end)
    H.ok(ran, "the computation ran to its end inside run()")
    return reads
  end

  H.eq(
    clock_reads(math.huge),
    0,
    "an unlimited budget reads the clock neither at an interruption point nor when a slice starts"
  )
  H.ok(clock_reads(1e9) >= 1000, "a finite budget, however generous, reads it at every point")

  -- what counts as a small document -----------------------------------------------------------------

  ---The `budget_ms` that translate_markdown hands to its slicer for `lines`.
  ---@param lines string[]
  ---@param opts? table
  ---@return number|string budget  -- "default" when it leaves the choice to the slicer
  local function budget_of(lines, opts)
    local seen = "never built"
    local real_new = slice.new
    patched(slice, {
      new = function(o)
        seen = o.budget_ms == nil and "default" or o.budget_ms
        return real_new(o)
      end,
    }, function()
      local r = run(
        lines,
        vim.tbl_extend("force", { provider = fake(scramble, { sync = true }) }, opts or {})
      )
      H.ok(r.ok, "the document is translated: " .. tostring(r.res))
    end)
    return seen
  end

  ---@param count integer
  ---@param bytes integer  -- per line
  ---@return string[]
  local function paragraphs(count, bytes)
    local out = {}
    local text = ("word "):rep(math.ceil(bytes / 5)):sub(1, bytes)
    for i = 1, count do
      out[#out + 1] = text
      if i < count then
        out[#out + 1] = ""
      end
    end
    return out
  end

  do
    local short = {}
    for i = 1, 1999 do
      short[i] = (i % 2 == 0) and "" or "x"
    end
    H.eq(budget_of(short), math.huge, "1 999 short lines are one piece of work")
    short[2000] = "x"
    H.eq(budget_of(short), "default", "2 000 lines are sliced, however short")
    -- the bytes decide, too: 100 paragraphs of 2.5 kB are 200 lines and a quarter of a megabyte
    H.eq(budget_of(paragraphs(100, 2500)), "default", "200 lines of 2.5 kB are sliced")
    -- 63 x 1 024 bytes are under 64 kB, 64 x 1 024 are 64 kB (blank lines add lines, not bytes)
    H.eq(budget_of(paragraphs(63, 1024)), math.huge, "under 64 kB is one piece of work")
    H.eq(budget_of(paragraphs(64, 1024)), "default", "64 kB is sliced")
    -- an explicit slice_ms wins over the size, in both directions
    H.eq(
      budget_of({ "Ein Satz." }, { slice_ms = 3 }),
      3,
      "a small document with slice_ms is sliced"
    )
    H.eq(
      budget_of(paragraphs(64, 1024), { slice_ms = 1e9 }),
      1e9,
      "and a big one with slice_ms is not"
    )
  end

  -- the cost follows the units: a table under both old limits is not small ---------------------------------
  do
    ---@param rows integer
    ---@param cols integer
    ---@return string[]
    local function table_doc(rows, cols)
      local out = { "# Tabelle", "" }
      local head, rule = {}, {}
      for c = 1, cols do
        head[c], rule[c] = "K" .. c, "---"
      end
      out[#out + 1] = "| " .. table.concat(head, " | ") .. " |"
      out[#out + 1] = "| " .. table.concat(rule, " | ") .. " |"
      for r = 1, rows do
        local cells = {}
        for c = 1, cols do
          cells[c] = "z" .. ((r * 7 + c) % 100)
        end
        out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
      end
      return out
    end

    local big = table_doc(1100, 8)
    local bytes = 0
    for _, l in ipairs(big) do
      bytes = bytes + #l
    end
    H.ok(#big < 2000 and bytes < 64 * 1024, "the table is under both old limits: " .. bytes)
    local n_units = #segment.segment(big).units
    H.ok(n_units >= 8000, "and holds a unit for every cell: " .. n_units)
    H.eq(budget_of(big), "default", "8 800 cells are sliced, whatever the lines and bytes say")
    local r = run(big, { provider = fake(scramble, { sync = true }) })
    H.ok(r.ok and r.info.slices > 0, "and the work is really handed back")
    -- a small table is still one piece of work
    H.eq(budget_of(table_doc(100, 4)), math.huge, "a table of 400 cells is not sliced")
    -- the pipes count wherever they stand: the estimate is an upper bound, cheap to take
    local piped = {}
    for i = 1, 400 do
      piped[i] = "a | b | c | d | e | f | g | h | i | j | k | l | m | n | o | p"
    end
    H.eq(budget_of(piped), "default", "6 400 pipes in 400 lines are sliced")
    -- a line is a unit, too: 1 500 list items (under 2 000 lines and 64 kB) cost about 40 ms
    local items = {}
    for i = 1, 1500 do
      items[i] = ("- Punkt %04d mit Text daran"):format(i)
    end
    H.eq(budget_of(items), "default", "1 500 list items are sliced")
    H.eq(
      budget_of(vim.list_slice(items, 1, 800)),
      math.huge,
      "800 list items are one piece of work"
    )
  end

  -- the ticks of the pipeline, counted between markers ------------------------------------------------

  local DOC = {
    "# Einleitung",
    "",
    "Ein Absatz mit einem [Link](#fazit) und `code` darin,",
    "der ueber zwei Zeilen geht.",
    "",
    "- Punkt eins mit Text",
    "- Punkt zwei mit Text",
    "",
    "| Spalte eins | Spalte zwei |",
    "| --- | --- |",
    "| Zelle eins | Zelle zwei |",
    "",
    "## Fazit",
    "",
    "Ein Schlusssatz mit mehreren Woertern.",
    "",
    "[ref]: #einleitung",
  }

  ---Translate `lines` with every call of `tick` counted, and note the count at the markers of the
  ---pipeline. Nothing yields (the budget is unlimited): the numbers are the same on every machine.
  ---@param lines string[]
  ---@return table log
  local function probe(lines)
    local t = 0
    local log = {
      translate = {},
      get = {},
      mask = {},
      unmask = {},
      reflow = {},
    }
    local real_new = slice.new
    local real_segment, real_render = segment.segment, segment.render
    local real_build_map = anchors.build_map
    local real_mask, real_unmask, real_get = mask.mask, mask.unmask, cache.get
    local real_reflow = reflow.reflow
    local p = fake(scramble, { sync = true })
    local real_translate = p.translate
    p.translate = function(...)
      log.translate[#log.translate + 1] = t
      return real_translate(...)
    end
    md.cache._reset()
    patched(slice, {
      new = function(o)
        local sl = real_new(o)
        local inner = sl.tick
        sl.tick = function()
          t = t + 1
          return inner()
        end
        return sl
      end,
    }, function()
      patched(segment, {
        segment = function(...)
          log.segment_in = t
          local seg = real_segment(...)
          log.segment_end = t
          return seg
        end,
        render = function(seg, content, first, last, tick)
          if not tick then
            return real_render(seg, content, first, last)
          end
          log.render_in = t
          local out = real_render(seg, content, first, last, tick)
          log.render_out = t
          return out
        end,
      }, function()
        patched(anchors, {
          build_map = function(...)
            log.map_in = t
            local a, b, c = real_build_map(...)
            log.map_out = t
            return a, b, c
          end,
        }, function()
          patched(mask, {
            mask = function(...)
              log.mask[#log.mask + 1] = t
              return real_mask(...)
            end,
            unmask = function(...)
              log.unmask[#log.unmask + 1] = t
              return real_unmask(...)
            end,
          }, function()
            patched(cache, {
              get = function(...)
                log.get[#log.get + 1] = t
                return real_get(...)
              end,
            }, function()
              patched(reflow, {
                reflow = function(...)
                  log.reflow[#log.reflow + 1] = t
                  return real_reflow(...)
                end,
              }, function()
                -- (not helpers.run: it asks for progress events, and every event renders a block)
                local r
                md.translate_markdown(lines, {
                  target = "EN",
                  provider = p,
                  cache = true,
                  cfg = { markdown = { disk_cache = false } },
                  slice_ms = 1e9,
                }, function(ok, res, info)
                  r = { ok = ok, res = res, info = info }
                end)
                vim.wait(10000, function()
                  return r ~= nil
                end, 1)
                H.ok(r and r.ok, "the probe run: " .. tostring(r and r.res))
                H.eq(r.info.slices, 0, "the probe never yields")
                log.result = r
              end)
            end)
          end)
        end)
      end)
    end)
    log.cb = t
    md.cache._reset()
    return log
  end

  do
    local seg = segment.segment(DOC)
    local n_units, n_blocks = #seg.units, #seg.blocks
    local n_heads, n_refdefs = #seg.headings, #seg.refdefs
    H.ok(n_blocks >= 6 and n_heads == 2 and n_refdefs == 1, "the document has what the probe needs")
    local log = probe(DOC)
    local n_gets = #log.get
    H.eq(n_gets, n_units, "every unit is a different text: one cache lookup each")

    H.ok(
      log.segment_end - log.segment_in >= #DOC,
      ("the segmenter gets the tick (one for every line): %d ticks for %d lines"):format(
        log.segment_end - log.segment_in,
        #DOC
      )
    )

    H.ok(
      log.mask[1] - log.segment_end >= 2 * n_blocks + 1,
      ("the loops over the blocks (unit_block, bstate) and the first unit: %d ticks for %d blocks"):format(
        log.mask[1] - log.segment_end,
        n_blocks
      )
    )
    H.ok(
      log.get[1] - log.mask[#log.mask] >= n_blocks + n_heads + 1,
      ("the loops over the blocks and the headings and the first entry: %d ticks"):format(
        log.get[1] - log.mask[#log.mask]
      )
    )
    for k = 2, n_gets do
      H.ok(
        log.get[k] - log.get[k - 1] >= 1,
        "the cache pass ticks at every entry (lookup " .. k .. ")"
      )
    end
    H.ok(
      log.translate[1] - log.get[n_gets] >= 3 * n_gets + 1,
      ("the partition, the pending count and the batching tick at every entry, and the pump once: %d ticks for %d entries"):format(
        log.translate[1] - log.get[n_gets],
        n_gets
      )
    )
    for k = 2, n_heads do
      -- (the first calls of unmask are the ones of the anchor map)
      H.ok(log.unmask[k] - log.unmask[k - 1] >= 1, "the anchor map loop ticks at every heading")
    end
    H.ok(log.map_out - log.map_in >= n_heads, "and the map builder gets the tick, too")
    H.ok(
      log.render_in - log.reflow[1] >= n_units,
      ("the content loop of the finalisation ticks at every unit: %d ticks for %d units"):format(
        log.render_in - log.reflow[1],
        n_units
      )
    )
    H.ok(
      log.render_out - log.render_in >= #DOC,
      ("the final render gets the tick (one for every line): %d ticks for %d lines"):format(
        log.render_out - log.render_in,
        #DOC
      )
    )
    H.ok(
      log.cb - log.render_out >= n_refdefs + n_units,
      ("the loops over the reference definitions and the units after the render: %d ticks"):format(
        log.cb - log.render_out
      )
    )
  end

  -- the cache pass books the units of one entry one by one
  do
    local doc = {}
    for _ = 1, 6 do
      doc[#doc + 1] = "- Derselbe Text in jedem Punkt"
    end
    local cfg = { markdown = { disk_cache = false } }
    md.cache._reset()
    local warm = run(doc, { provider = fake(scramble, { sync = true }), cache = true, cfg = cfg })
    H.ok(warm.ok, "warming the cache")
    local t = 0
    local real_new = slice.new
    local at = {}
    patched(slice, {
      new = function(o)
        local sl = real_new(o)
        local inner = sl.tick
        sl.tick = function()
          t = t + 1
          return inner()
        end
        return sl
      end,
    }, function()
      local r = run(doc, {
        provider = fake(function()
          error("a cached unit must not be sent again")
        end, { sync = true }),
        cache = true,
        cache_only = true,
        cfg = cfg,
        slice_ms = 1e9,
        on_unit = function()
          at[#at + 1] = t
        end,
      })
      H.ok(r.ok and r.info.cached == 6, "answered from the cache")
    end)
    H.eq(#at, 6, "one event for every item")
    for k = 2, #at do
      H.ok(
        at[k] - at[k - 1] >= 1,
        "a tick between two units of the same cached entry (" .. k .. ")"
      )
    end
    md.cache._reset()
  end

  -- a text that occurs thousands of times: its answer is booked in slices --------------------------------

  ---Burn `ms` of wall-clock time (a block that is expensive to report, on any machine).
  ---@param ms number
  local function spin(ms)
    local stop = uv.hrtime() + ms * 1e6
    while uv.hrtime() < stop do
    end
  end

  ---Translate `lines` and say over how many turns of the event loop the calls of `on_unit` were
  ---spread (each one burns 0.5 ms; with a slice of 0.2 ms the work has to give way after each).
  ---@param lines string[]
  ---@param opts table
  ---@return table r, integer spread
  local function spread_of(lines, opts)
    local turn, first, last = 0, nil, nil
    local check = assert(uv.new_check())
    check:start(function()
      turn = turn + 1
    end)
    local r = run(
      lines,
      vim.tbl_extend("force", {
        slice_ms = 0.2,
        on_unit = function()
          spin(0.5)
          first = first or turn
          last = turn
        end,
      }, opts)
    )
    check:stop()
    check:close()
    return r, (last or 0) - (first or 0)
  end

  do
    local N = 600
    local doc = {}
    for i = 1, N do
      doc[i] = "- the same list item text with more words"
    end
    local r, spread = spread_of(doc, { provider = fake(scramble, { delay_ms = 0 }) })
    H.ok(r.ok, "one text 600 times: " .. tostring(r.res))
    H.eq(r.calls, 1, "cb exactly once")
    H.eq(#r.units, N, "every item was reported before the call ended")
    H.eq(r.info.translated, N)
    H.ok(
      spread >= N / 2,
      ("the answer for 600 identical units is booked over many turns of the loop: %d"):format(
        spread
      )
    )
    H.eq(r.res[1], scramble(doc[1]), "and the result is the translation")
    H.eq(r.res[N], scramble(doc[N]))
  end

  -- the bound of an answer is the answer, not its entries: 40 entries of 30 units are 1 200 -----------

  ---Translate `lines` and say how many calls of `on_unit` came in one turn of the event loop at
  ---most (each call burns 0.3 ms; a slice is 0.2 ms, so a booking that gives way yields after each).
  ---@param lines string[]
  ---@param opts table
  ---@return table r, integer longest
  local function longest_turn(lines, opts)
    local turn, longest, in_turn, seen = 0, 0, 0, -1
    local check = assert(uv.new_check())
    check:start(function()
      turn = turn + 1
    end)
    local r = run(
      lines,
      vim.tbl_extend("force", {
        slice_ms = 0.2,
        on_unit = function()
          spin(0.3)
          if turn ~= seen then
            seen, in_turn = turn, 0
          end
          in_turn = in_turn + 1
          longest = math.max(longest, in_turn)
        end,
      }, opts)
    )
    check:stop()
    check:close()
    return r, longest
  end

  do
    local KINDS, REPEAT = 40, 30
    local doc = {}
    for _ = 1, REPEAT do
      for k = 1, KINDS do
        doc[#doc + 1] = ("- entry number %d with a few words behind it"):format(k)
      end
    end
    local r, longest = longest_turn(doc, {
      provider = fake(scramble, { delay_ms = 0 }),
      max_units = KINDS,
    })
    H.ok(r.ok, "40 texts 30 times each: " .. tostring(r.res))
    H.eq(r.calls, 1, "cb exactly once")
    H.eq(r.info.requests, 1, "one answer holds all 40 entries")
    H.eq(#r.units, KINDS * REPEAT, "every item was reported before the call ended")
    H.ok(
      longest <= 256,
      ("one answer of 1 200 units (40 entries of 30, each under the per-entry bound) is booked in slices: %d reports in one turn"):format(
        longest
      )
    )
    local plain = run(doc, {
      provider = fake(scramble, { sync = true }),
      max_units = KINDS,
      slice_ms = 1e9,
    })
    H.ok(vim.deep_equal(r.res, plain.res), "and the result is the one of the unsliced run")
  end

  -- an error in the booking of an answer ends the call -------------------------------------------------

  do
    local doc = { "Ein Absatz mit Worten.", "", "- Punkt eins" }
    for _, slice_ms in ipairs({ 1e9, 0 }) do
      for _, async in ipairs({ false, true }) do
        local what = ("slice_ms %s, %s engine"):format(
          tostring(slice_ms),
          async and "async" or "sync"
        )
        local armed = false
        -- (arms itself with the answer: the first thing that unmasks after it is the booking)
        local provider = {
          name = "chaos",
          available = function()
            return true
          end,
          translate = function(lines, _, _, _, cb)
            local out = {}
            for i, l in ipairs(lines) do
              out[i] = scramble(l)
            end
            local function reply()
              armed = true
              cb(true, out)
            end
            if async then
              vim.defer_fn(reply, 0)
            else
              reply()
            end
            return { cancel = function() end }
          end,
        }
        local real_unmask = mask.unmask
        local calls, ok, res = 0, nil, nil
        patched(mask, {
          unmask = function(...)
            if armed then
              -- once: the other entry of the answer is not booked then, and a call that goes on as
              -- if nothing had happened would be a hang or a silent loss
              armed = false
              error("boom in the booking", 0)
            end
            return real_unmask(...)
          end,
        }, function()
          md.translate_markdown(doc, {
            target = "EN",
            cache = false,
            cfg = { markdown = { disk_cache = false } },
            provider = provider,
            slice_ms = slice_ms,
            on_unit = function() end,
          }, function(o, r)
            calls = calls + 1
            ok, res = o, r
          end)
          vim.wait(1500, function()
            return calls > 0
          end, 1)
          -- a second call would arrive within a few turns
          vim.wait(30, function()
            return calls > 1
          end, 1)
        end)
        H.eq(
          calls,
          1,
          what .. ": cb exactly once (a throw in the booking must not leave the call hanging)"
        )
        H.eq(ok, false, what .. ": the call failed")
        H.ok(
          type(res) == "string" and res:find("^translate_markdown: ") and res:find("boom", 1, true),
          what .. ": with the error contract of translate_markdown: " .. tostring(res)
        )
      end
    end
  end

  -- the blocks that waited for the anchor map are reported in slices, too
  do
    local N = 600
    local function anchored(heading)
      local d = { "# " .. heading, "" }
      for i = 1, N do
        d[#d + 1] = ("Paragraph number %d has some words and a [link](#alpha-heading)."):format(i)
        d[#d + 1] = ""
      end
      return d
    end
    local cfg = { markdown = { disk_cache = false } }
    md.cache._reset()
    local warm = run(anchored("Alpha Heading"), {
      provider = fake(scramble, { sync = true }),
      cache = true,
      cfg = cfg,
    })
    H.ok(warm.ok, "warming the cache")
    -- (the paragraphs come from the cache and wait for the map; the changed heading goes to the engine)
    local r, spread = spread_of(anchored("Beta Heading"), {
      provider = fake(scramble, { delay_ms = 0 }),
      cache = true,
      cfg = cfg,
    })
    H.ok(r.ok, "the paragraphs wait for the heading: " .. tostring(r.res))
    H.eq(#r.units, N + 1, "every paragraph and the heading was reported")
    H.eq(r.info.cached, N, "the paragraphs came from the cache")
    H.ok(
      spread >= N / 2,
      ("the reports of the waiting blocks are spread over many turns of the loop: %d"):format(
        spread
      )
    )
    md.cache._reset()
  end

  -- what the order of on_unit guarantees ------------------------------------------------------------------

  do
    local doc = { "# Eins [zwei](#zwei)", "", "# Zwei", "", "Ein Absatz." }
    local cases = {}
    for _, slice_ms in ipairs({ 1e9, 0 }) do
      for _, max_units in ipairs({ 1, 40 }) do
        for _, async in ipairs({ false, true }) do
          cases[#cases + 1] = { slice_ms = slice_ms, max_units = max_units, async = async }
        end
      end
    end
    for _, c in ipairs(cases) do
      local what = ("slice_ms %s, max_units %d, %s engine"):format(
        tostring(c.slice_ms),
        c.max_units,
        c.async and "async" or "sync"
      )
      local r = run(doc, {
        provider = fake(scramble, { sync = not c.async, delay_ms = c.async and 0 or nil }),
        slice_ms = c.slice_ms,
        max_units = c.max_units,
      })
      H.ok(r.ok, what)
      H.eq(#r.units, 3, what .. ": one event for every block")
      local at = {}
      for i, ev in ipairs(r.units) do
        H.eq(ev.done, i, what .. ": done counts in the order of the calls")
        H.eq(ev.total, 3, what .. ": total")
        at[ev.first] = i
      end
      H.ok(at[1] and at[3] and at[5], what .. ": all three blocks")
      -- the heading that completes the map comes after the block that waited for it
      H.ok(
        at[1] < at[3],
        what .. ": the block that waited for the map comes before the heading that completed it"
      )
      -- (and what it says is the final text: the link follows the translated heading)
      H.eq(
        r.units[at[1]].lines[1],
        "# sniE [iewz](#iewz)",
        what .. ": the waiting block has the new anchor"
      )
    end
  end

  -- the events of the fixtures: exactly once each, whatever the cuts
  for _, name in ipairs({ "edge_de.md", "readme_de.md" }) do
    local lines = helpers.fixture(name)
    for _, slice_ms in ipairs({ 1e9, 0 }) do
      for _, async in ipairs({ false, true }) do
        local what = ("%s, slice_ms %s, %s engine"):format(
          name,
          tostring(slice_ms),
          async and "async" or "sync"
        )
        local r = run(lines, {
          provider = fake(scramble, { sync = not async, delay_ms = async and 0 or nil }),
          slice_ms = slice_ms,
        })
        H.ok(r.ok, what)
        local seen, total = {}, nil
        for i, ev in ipairs(r.units) do
          H.eq(ev.done, i, what .. ": done counts 1.. in the order of the calls")
          total = total or ev.total
          H.eq(ev.total, total, what .. ": total does not change")
          H.falsy(seen[ev.first], what .. ": block " .. ev.first .. " reported twice")
          seen[ev.first] = true
        end
        H.ok(#r.units > 0 and #r.units <= total, what .. ": events")
      end
    end
  end
end
