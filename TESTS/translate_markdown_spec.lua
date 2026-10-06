-- TESTS/translate_markdown_spec.lua -- the public API `translate_markdown(lines, opts, cb)`
-- against a fake engine: golden documents (fences, tables, lists, quotes, inline
-- code, anchors, front matter, HTML), the invariant #out == #in, validation with
-- one retry and the fall back to the original unit, the cache (a failure is never
-- cached), batching and concurrency, progress events, cancellation, stale tokens
-- and `cb` exactly once. No network, no curl.

return function(H)
  local md = require("language.translate.markdown")
  local cache = md.cache
  local helpers = dofile(vim.fn.getcwd() .. "/TESTS/markdown_helpers.lua")
  local run, fake, kinds = helpers.run, helpers.fake, helpers.kinds

  cache._reset()

  local DICT = { Einleitung = "Introduction", Installation = "Setup", Verwendung = "Usage" }
  --- A deterministic "translation": dictionary words, every other long word reversed.
  local function scramble(text)
    return (
      text:gsub("%a+", function(w)
        if DICT[w] then
          return DICT[w]
        end
        if #w >= 4 then
          return w:reverse()
        end
      end)
    )
  end
  local function expand(text)
    return scramble(text) .. " and some extra words"
  end
  local function shrink(text)
    local words = {}
    for w in scramble(text):gmatch("%S+") do
      words[#words + 1] = w
    end
    return table.concat(words, " ", 1, math.max(1, math.ceil(#words / 2)))
  end

  ---@param lines string[]
  ---@return table<integer, boolean>
  local function front_set(lines)
    local set = {}
    local d = lines[1] and (lines[1]:match("^(%-%-%-)$") or lines[1]:match("^(%+%+%+)$"))
    if d then
      for j = 2, #lines do
        if lines[j] == d then
          for i = 1, j do
            set[i] = true
          end
          break
        end
      end
    end
    return set
  end

  local function same_lines(res, lines, set, what)
    for i in pairs(set) do
      if res[i] ~= lines[i] then
        error(("%s: line %d changed: %q -> %q"):format(what, i, lines[i], tostring(res[i])))
      end
    end
  end

  local function leftover_placeholders(res, lines)
    local had = 0
    for _, l in ipairs(lines) do
      for _ in l:gmatch("{%d+}") do
        had = had + 1
      end
    end
    local now = 0
    for _, l in ipairs(res) do
      for _ in l:gmatch("{%d+}") do
        now = now + 1
      end
    end
    return now - had
  end

  -- Golden documents ---------------------------------------------------------------------------
  for _, name in ipairs({ "readme_de.md", "edge_de.md" }) do
    local lines = helpers.fixture(name)
    for mode, fn in pairs({ scramble = scramble, expand = expand, shrink = shrink }) do
      local what = name .. "/" .. mode
      local p = fake(fn)
      local r = run(lines, { provider = p })
      H.ok(r.ok, what .. ": ok (" .. tostring(r.res) .. ")")
      H.eq(r.calls, 1, what .. ": cb exactly once")
      local res = r.res
      H.eq(#res, #lines, what .. ": #out == #in")
      same_lines(res, lines, helpers.fence_set(lines), what .. " fences byte-identical")
      same_lines(res, lines, front_set(lines), what .. " front matter")
      H.eq(leftover_placeholders(res, lines), 0, what .. ": every placeholder restored")

      local before, after = helpers.protected(lines), helpers.protected(res)
      for span, n in pairs(before) do
        H.eq(after[span], n, what .. ": protected text kept: " .. span)
      end

      if mode ~= "shrink" then
        H.eq(r.info.failed, 0, what .. ": nothing failed")
        local ka, kb = kinds(lines), kinds(res)
        for i = 1, #lines do
          H.eq(
            kb[i],
            ka[i],
            ("%s: line %d keeps its block type (%q -> %q)"):format(what, i, lines[i], res[i])
          )
        end
        H.ok(
          table.concat(res, "\n") ~= table.concat(lines, "\n"),
          what .. ": something was translated"
        )
      end

      -- everything the engine saw is ASCII for an ASCII source: no Unicode placeholder
      for _, sent in ipairs(p.calls) do
        for _, l in ipairs(sent) do
          H.falsy(l:find("[\128-\255]"), what .. ": the engine saw a non-ASCII byte in " .. l)
          H.falsy(l:find("`"), what .. ": inline code never reaches the engine: " .. l)
          H.falsy(l:find("](", 1, true), what .. ": a link target never reaches the engine: " .. l)
        end
      end
    end
  end

  -- What the engine receives and what comes back, in detail ------------------------------------
  do
    local lines = {
      "# Einleitung",
      "",
      "Ein `code` mit [Link](https://x.y/a) und Neovim.",
      "",
      "```lua",
      "local geheim = 1",
      "```",
    }
    local p = fake(scramble)
    local r = run(lines, { provider = p, keep = { "Neovim" } })
    local sent = p.calls[1]
    H.eq(#p.calls, 1, "one request for the whole document")
    H.eq(sent[1], "Einleitung", "the heading is sent first")
    H.eq(sent[2], "Ein {1} mit {2}Link{3} und {4}.", "masked text is what the engine sees")
    H.eq(#sent, 2, "fences are never sent")
    H.eq(r.res[3], "Ein `code` mit [kniL](https://x.y/a) und Neovim.", "and restored afterwards")
    H.eq(r.res[1], "# Introduction")
    H.eq(r.res[6], "local geheim = 1")
  end

  -- The dash rule through the whole pipeline ----------------------------------------------------
  for _, tok in ipairs({ "-", "*", "+", "1.", "#", ">", "|", "```", "---" }) do
    local lines = {
      "Erste Zeile des Absatzes hier",
      "zweite Zeile des Absatzes hier",
      "dritte Zeile des Absatzes hier",
      "",
      "Danach kommt noch ein Absatz.",
    }
    -- the engine puts the token exactly where an even split would cut
    local p = fake(function(text)
      if text:find("Erste") then
        return "alpha bravo charlie delta echo foxtrot "
          .. tok
          .. " golf hotel india juliet kilo lima"
          .. " mike november oscar papa "
          .. tok
          .. " quebec romeo sierra tango uniform"
      end
      return scramble(text)
    end)
    local r = run(lines, { provider = p })
    H.ok(r.ok and r.info.failed == 0, "token " .. tok .. ": translated")
    H.eq(#r.res, #lines, "token " .. tok .. ": #out == #in")
    local k = kinds(r.res)
    local ka = kinds(lines)
    for i = 1, #lines do
      H.eq(k[i], ka[i], ("token %s line %d: %q"):format(tok, i, r.res[i]))
    end
    for i = 2, 3 do
      H.ok(
        not r.res[i]:match("^%s*" .. vim.pesc(tok) .. "%s"),
        "token " .. tok .. ": no break in front of it: " .. r.res[i]
      )
    end
    local joined = table.concat(vim.list_slice(r.res, 1, 3), " ")
    H.ok(joined:find(" " .. tok .. " ", 1, true), "token " .. tok .. " is still in the text")
  end

  -- Anchors -----------------------------------------------------------------------------------------
  do
    local lines = {
      "# Einleitung",
      "",
      "Siehe [Installation](#installation), [oben](#einleitung) und [nix](#gibt-es-nicht).",
      'Auch [a](#installation "Titel") und [b](other.md#installation).',
      "",
      "## Installation",
      "",
      "[zur Einleitung]: #einleitung",
    }
    local r = run(lines, { provider = fake(scramble) })
    H.ok(r.ok)
    H.eq(r.res[3], "eheiS [Setup](#setup), [nebo](#introduction) und [nix](#gibt-es-nicht).")
    H.eq(
      r.res[4],
      'hcuA [a](#setup "Titel") und [b](other.md#installation).',
      "a title is kept, another file's anchor is none of ours"
    )
    H.eq(r.res[8], "[zur Einleitung]: #introduction", "a reference definition follows too")
    H.ok(r.info.anchors_changed >= 4, "counted: " .. r.info.anchors_changed)
    H.eq(r.res[1], "# Introduction")
    H.eq(r.res[6], "## Setup")

    -- a heading that stays German keeps its anchor
    local p = fake(function(text)
      if text == "Installation" then
        return ""
      end
      return scramble(text)
    end)
    r = run(lines, { provider = p })
    H.eq(r.info.failed, 1, "the empty answer for the heading is refused")
    H.eq(r.res[6], "## Installation", "so the heading stays as it was")
    H.ok(r.res[3]:find("(#installation)", 1, true), "and its anchor is not rewritten: " .. r.res[3])
    H.ok(r.res[3]:find("(#introduction)", 1, true), "while the translated heading's is")
  end

  -- Validation, one retry, fall back to the original unit -----------------------------------------------
  do
    local lines = {
      "Ein Absatz mit `code` darin.",
      "",
      "Dieser Absatz geht kaputt.",
      "",
      "Noch ein Absatz mit [Link](#x) darin.",
    }
    local broken = fake(function(text)
      if text:find("kaputt") then
        return "this one lost its words" -- fine text, but ok: no placeholder in it
      end
      if text:find("{", 1, true) then
        return "answer without placeholders"
      end
      return scramble(text)
    end)
    local r = run(lines, { provider = broken })
    H.ok(r.ok)
    H.eq(r.res[1], lines[1], "a unit that lost a placeholder stays original")
    H.eq(r.res[5], lines[5], "also the second one")
    H.eq(r.res[3], "this one lost its words", "a unit without placeholders is fine")
    H.eq(r.info.failed, 2)
    H.eq(r.info.retries, 2, "each one retried once")
    H.eq(#broken.calls, 2, "the retry is one more request, not one per unit")
    H.ok(#r.info.errors > 0, "and the reason is reported")

    -- a failure is never cached, a success is: the second run asks for the failed unit only
    cache._reset()
    local p = fake(function(text)
      if text:find("kaputt") then
        return ""
      end
      return scramble(text)
    end)
    local opts = { provider = p, cache = true, target = "EN" }
    r = run(lines, opts)
    H.eq(r.info.failed, 1)
    H.eq(r.info.translated, 2)
    local first = #p.calls
    r = run(lines, opts)
    H.eq(r.info.cached, 2, "the successful units come from the cache")
    H.eq(r.info.failed, 1)
    local second = vim.list_slice(p.calls, first + 1)
    H.eq(#second, 2, "the failed unit is asked again (and retried)")
    for _, req in ipairs(second) do
      H.eq(#req, 1, "alone")
      H.ok(req[1]:find("kaputt"), "it is exactly the failed one")
    end
    H.eq(r.res[3], lines[3])
    cache._reset()
  end

  -- transient error: one retry saves the unit -----------------------------------------------------------------------
  do
    local lines = { "Erster Absatz.", "", "Zweiter Absatz." }
    local p = fake(nil, {
      on_request = function(req, cb, call)
        vim.schedule(function()
          if call == 1 then
            cb(false, "HTTP 429")
          else
            local out = {}
            for i, l in ipairs(req) do
              out[i] = scramble(l)
            end
            cb(true, out)
          end
        end)
      end,
    })
    local r = run(lines, { provider = p })
    H.ok(r.ok)
    H.eq(r.info.failed, 0)
    H.eq(r.info.retries, 2, "both units were in the one retried request")
    H.eq(r.info.requests, 2)
    H.ok(r.res[1] ~= lines[1], "translated after the retry")
  end

  -- an engine that answers the wrong number of lines -----------------------------------------------------------------
  do
    local lines = { "Erster Absatz.", "", "Zweiter Absatz.", "", "Dritter Absatz." }
    local p = fake(nil, {
      on_request = function(req, cb)
        vim.schedule(function()
          if #req > 1 then
            cb(true, { scramble(req[1]) }) -- a batch answered with one line
          else
            cb(true, { scramble(req[1]) })
          end
        end)
      end,
    })
    local r = run(lines, { provider = p })
    H.ok(r.ok)
    H.eq(r.info.failed, 0, "after the batch is split into single requests everything arrives")
    H.eq(r.info.translated, 3)
    H.eq(r.info.requests, 4, "one batch, then one request per unit")

    -- a single unit answered with several lines: they are joined
    p = fake(nil, {
      on_request = function(_, cb)
        vim.schedule(function()
          cb(true, { "Erste Haelfte", "zweite Haelfte" })
        end)
      end,
    })
    r = run({ "Nur ein Absatz." }, { provider = p })
    H.eq(
      r.res[1],
      "Erste Haelfte zweite Haelfte",
      "a line break inside the answer for one unit becomes a space"
    )
  end

  -- an engine that is down: bounded effort, the document comes back untouched ---------------------------------------------
  do
    local lines = {}
    for i = 1, 12 do
      lines[#lines + 1] = "Absatz Nummer " .. i .. "."
      lines[#lines + 1] = ""
    end
    local p = fake(nil, {
      on_request = function(_, cb)
        vim.schedule(function()
          cb(false, "connection refused")
        end)
      end,
    })
    local r = run(lines, { provider = p, max_units = 1, concurrency = 1 })
    H.ok(r.ok, "an engine failure is not an error of the call")
    H.eq(#r.res, #lines)
    for i = 1, #lines do
      H.eq(r.res[i], lines[i], "everything stays original")
    end
    H.eq(r.info.failed, 12)
    H.eq(r.info.requests, 3, "three failures in a row stop the run")
    H.ok(r.info.errors[1]:find("connection refused", 1, true))

    -- a provider that throws
    p = fake(nil, {
      on_request = function()
        error("boom")
      end,
    })
    r = run({ "Ein Absatz." }, { provider = p })
    H.ok(
      r.ok and r.res[1] == "Ein Absatz." and r.info.failed == 1,
      "a throwing engine is a failed unit, not a crash"
    )
  end

  -- implausible answers ----------------------------------------------------------------------------------------------------------
  do
    local lines =
      { "Dies ist ein ziemlich langer Absatz, der sicher mehr als zwanzig Zeichen hat." }
    local r = run(lines, { provider = fake(function()
      return "x"
    end) })
    H.eq(r.res[1], lines[1], "a one-letter answer for a long paragraph is not a translation")
    H.eq(r.info.failed, 1)
    r = run(lines, { provider = fake(function(t)
      return t:rep(8, " ")
    end) })
    H.eq(r.res[1], lines[1], "an answer many times longer is refused")
  end

  -- an answer the wrapping cannot hold stays original, but is a good translation (cached) -------------------------------
  do
    local lines = { "Absatz eins hier", "und Zeile zwei hier" }
    local p = fake(function()
      return "- starts like a list"
    end)
    local r = run(lines, { provider = p })
    H.eq(r.res[1], lines[1], "a paragraph whose translation would start a list stays original")
    H.eq(r.res[2], lines[2])
    H.eq(r.info.reflow_failed, 1)
    H.eq(r.info.failed, 0, "it was a valid translation, only not safe to place")
  end

  -- fewer words than lines -----------------------------------------------------------------------------------------------------------
  do
    local cjk = "\228\184\173\230\150\135" -- one "word" without spaces
    local p = fake(function()
      return cjk
    end)
    local r = run(
      { "Para eins", "para zwei", "para drei", "", "- Punkt eins", "  Punkt zwei", "  Punkt drei" },
      { provider = p }
    )
    H.eq(#r.res, 7)
    H.eq(r.res[1], cjk)
    H.eq(r.res[2], "", "a plain paragraph is padded with blank lines")
    H.eq(r.res[3], "")
    H.eq(r.res[5], "- " .. cjk)
    H.eq(
      r.res[6],
      "  \226\128\139",
      "an item is padded with an invisible line: it must stay one item"
    )
    H.eq(r.res[7], "  \226\128\139")
    local k = kinds({ "- a", "  b", "  c" })
    H.eq(table.concat(k, ","), "item,text,text")
    H.eq(
      table.concat(kinds(vim.list_slice(r.res, 5, 7)), ","),
      "item,text,text",
      "so the block structure is intact"
    )
  end

  -- tables: cellwise, pipes stay ------------------------------------------------------------------------------------------------------------
  do
    local lines = {
      "| Name | Beschreibung |",
      "|------|--------------|",
      "| Alpha | Der erste Eintrag |",
      "",
      "Danach Text.",
    }
    local p = fake(scramble)
    local r = run(lines, { provider = p })
    H.eq(r.res[1], "| emaN | gnubierhcseB |")
    H.eq(r.res[2], lines[2], "the delimiter row is never touched")
    H.eq(r.res[3], "| ahplA | Der etsre gartniE |")
    local texts = {}
    for _, req in ipairs(p.calls) do
      vim.list_extend(texts, req)
    end
    H.ok(
      vim.tbl_contains(texts, "Name") and vim.tbl_contains(texts, "Beschreibung"),
      "every cell is a unit of its own"
    )
  end

  -- CRLF input ---------------------------------------------------------------------------------------------------------------------------------
  do
    local r = run(
      { "Erste Zeile\r", "zweite Zeile\r", "\r", "# Titel\r" },
      { provider = fake(scramble) }
    )
    H.eq(#r.res, 4)
    H.eq(r.res[1], "etsrE elieZ\r", "the carriage return stays at the end of its line")
    H.eq(r.res[2], "etiewz elieZ\r")
    H.eq(r.res[4], "# letiT\r")
  end

  -- nothing to translate: the engine is not asked ---------------------------------------------------------------------------------------------------
  do
    local p = fake(scramble)
    local lines = { "```", "code", "```", "", "`x`", "", "12345", "", "[2024](b)" }
    local r = run(lines, { provider = p })
    H.ok(r.ok)
    H.eq(#p.calls, 0, "no request")
    H.eq(table.concat(r.res, "\n"), table.concat(lines, "\n"))
    r = run({}, { provider = p })
    H.ok(r.ok and #r.res == 0, "an empty document")
  end

  -- duplicate units are sent once ---------------------------------------------------------------------------------------------------------------------------
  do
    local p = fake(scramble)
    local lines = {}
    for _ = 1, 5 do
      lines[#lines + 1] = "Der gleiche Absatz."
      lines[#lines + 1] = ""
    end
    local r = run(lines, { provider = p })
    local n = 0
    for _, req in ipairs(p.calls) do
      n = n + #req
    end
    H.eq(n, 1, "five identical paragraphs, one text sent")
    H.eq(r.res[9], r.res[1], "all five are translated")
    H.eq(r.info.translated, 5)
  end

  -- batching and concurrency -----------------------------------------------------------------------------------------------------------------------------------
  do
    local lines = {}
    for i = 1, 30 do
      lines[#lines + 1] = ("Absatz Nummer %02d mit einigem Text damit er etwas Platz braucht."):format(
        i
      )
      lines[#lines + 1] = ""
    end
    local p = fake(scramble)
    local r = run(lines, { provider = p, max_chars = 500 })
    H.ok(#p.calls >= 4, "split into several requests: " .. #p.calls)
    for _, req in ipairs(p.calls) do
      local cost = 0
      for _, l in ipairs(req) do
        cost = cost + #l + 8
      end
      H.ok(cost <= 500 or #req == 1, "a request stays within max_chars: " .. cost)
    end
    H.eq(r.info.failed, 0)

    p = fake(scramble)
    run(lines, { provider = p, max_units = 4 })
    for _, req in ipairs(p.calls) do
      H.ok(#req <= 4, "max_units")
    end
    H.eq(#p.calls, 8, "30 units in requests of at most 4")

    p = fake(scramble, { delay_ms = 15 })
    r = run(lines, { provider = p, max_units = 3, concurrency = 2 })
    H.eq(p.max_inflight, 2, "two requests in flight, never more")
    H.eq(r.info.failed, 0)
    p = fake(scramble, { delay_ms = 15 })
    run(lines, { provider = p, max_units = 3, concurrency = 1 })
    H.eq(p.max_inflight, 1, "concurrency = 1 is serial")
  end

  -- progress events ---------------------------------------------------------------------------------------------------------------------------------------------------
  do
    local lines = helpers.fixture("readme_de.md")
    local patched = vim.deepcopy(lines)
    local last_done = 0
    local r = run(lines, {
      provider = fake(scramble),
      max_units = 5,
      concurrency = 2,
      on_unit = function(ev)
        H.eq(#ev.lines, ev.last - ev.first + 1, "an event carries exactly the block's lines")
        H.ok(ev.done > last_done and ev.done <= ev.total, "progress counts up")
        last_done = ev.done
        for i, l in ipairs(ev.lines) do
          patched[ev.first + i - 1] = l
        end
      end,
    })
    H.ok(#r.units > 5, "one event per translated block: " .. #r.units)
    for i = 1, #lines do
      if lines[i]:match("^%[[^%]^][^%]]*%]:") then
        -- a reference definition is no block: only the final result carries its rewritten anchor
        H.eq(patched[i], lines[i], "events leave definitions alone (line " .. i .. ")")
      else
        H.eq(
          patched[i],
          r.res[i],
          "the events, applied one by one, build the final result (line " .. i .. ")"
        )
      end
    end
    H.eq(last_done, r.units[#r.units].total, "every block was reported")
  end

  -- cache_only: stale-while-revalidate building block --------------------------------------------------------------------------------------------------------------------
  do
    cache._reset()
    local lines = { "Erster Absatz.", "", "Zweiter Absatz." }
    local p = fake(scramble)
    local base = { provider = p, cache = true }
    local r = run(lines, base)
    H.eq(r.info.translated, 2)
    local changed = { "Erster Absatz.", "", "Ein ganz neuer Absatz." }
    local q = fake(function()
      error("must not be asked")
    end)
    r = run(changed, { provider = q, cache = true, cache_only = true })
    H.ok(r.ok)
    H.eq(#q.calls, 0, "cache_only never asks the engine")
    H.eq(r.res[1], scramble(lines[1]), "a cached unit is translated")
    H.eq(r.res[3], changed[3], "an unknown one stays original")
    H.eq(r.info.pending, 1)
    H.eq(r.info.cached, 1)

    -- only the changed unit goes out the next time
    local before = #p.calls
    r = run(changed, base)
    H.eq(#p.calls - before, 1, "one request")
    H.eq(#p.calls[#p.calls], 1, "for one unit")
    H.eq(r.info.cached, 1)
    H.eq(r.info.translated, 1)

    -- the target is part of the key
    before = #p.calls
    r = run(lines, { provider = p, cache = true, target = "FR" })
    H.eq(r.info.cached, 0, "another target language: nothing cached")
    H.ok(#p.calls > before)

    -- and a cache entry that no longer fits the unit is not trusted
    cache._reset()
    local hash = cache.key("fake", nil, "EN", nil, "Erster Absatz.")
    cache.set(hash, "poisoned {1}")
    r = run({ "Erster Absatz." }, { provider = p, cache = true })
    H.eq(
      r.res[1],
      scramble("Erster Absatz."),
      "a cached value failing the placeholder check is ignored"
    )
    cache._reset()
  end

  -- cancellation, stale tokens, cb exactly once ------------------------------------------------------------------------------------------------------------------------------
  do
    local lines = { "Erster Absatz.", "", "Zweiter Absatz." }

    -- cancel while a request is in flight
    local killed = false
    local replies = {}
    local p = fake(nil, {
      on_request = function(req, cb)
        replies[#replies + 1] = function()
          local out = {}
          for i, l in ipairs(req) do
            out[i] = scramble(l)
          end
          cb(true, out)
        end
        return {
          cancel = function()
            killed = true
          end,
        }
      end,
    })
    local calls, got_ok, got_res = 0, nil, nil
    local h = md.translate_markdown(
      lines,
      { target = "EN", provider = p, cache = false, cfg = { markdown = { disk_cache = false } } },
      function(ok, res)
        calls = calls + 1
        got_ok, got_res = ok, res
      end
    )
    vim.wait(2000, function()
      return #replies > 0
    end, 2)
    H.eq(calls, 0, "no callback while the request is out")
    h.cancel()
    H.eq(calls, 1, "cancel() reports once")
    H.eq(got_ok, false)
    H.eq(got_res, "cancelled")
    H.ok(killed, "the running request is killed")
    replies[1]()
    h.cancel()
    vim.wait(30)
    H.eq(calls, 1, "a late answer or a second cancel() does not call back again")

    -- cancel before anything started
    p = fake(scramble)
    calls = 0
    h = md.translate_markdown(
      lines,
      { target = "EN", provider = p, cache = false },
      function(_, res)
        calls = calls + 1
        got_res = res
      end
    )
    h.cancel()
    vim.wait(40)
    H.eq(calls, 1)
    H.eq(got_res, "cancelled")
    H.eq(#p.calls, 0, "the engine was never asked")

    -- a generation counter: a newer run makes this one stale
    local gen = 1
    p = fake(scramble, { delay_ms = 20 })
    local r = run(lines, {
      provider = p,
      token = {
        generation = 1,
        current = function()
          return gen
        end,
      },
      max_units = 1,
      concurrency = 1,
      on_unit = function()
        gen = 2
      end,
    })
    H.eq(r.ok, false)
    H.eq(r.res, "stale")
    H.eq(r.calls, 1, "a stale run still calls back exactly once")
    H.ok(#p.calls < 3, "and stops asking")

    -- a token that is already stale never starts
    p = fake(scramble)
    r = run(lines, {
      provider = p,
      token = {
        generation = 1,
        current = function()
          return 2
        end,
      },
    })
    H.eq(r.res, "stale")
    H.eq(#p.calls, 0)
    r = run(lines, { provider = p, token = { generation = 1, cancelled = true } })
    H.eq(r.res, "stale")

    -- a synchronous engine: the callback still comes later, once
    p = fake(scramble, { sync = true })
    local order = {}
    calls = 0
    md.translate_markdown(
      lines,
      { target = "EN", provider = p, cache = false, cfg = { markdown = { disk_cache = false } } },
      function(ok)
        calls = calls + 1
        order[#order + 1] = "cb"
        H.ok(ok)
      end
    )
    order[#order + 1] = "returned"
    vim.wait(1000, function()
      return calls > 0
    end, 2)
    H.eq(table.concat(order, ","), "returned,cb", "cb never runs before the function has returned")
    vim.wait(30)
    H.eq(calls, 1)
  end

  -- bad arguments and no engine ----------------------------------------------------------------------------------------------------------------------------------------------------
  do
    local r = run("not a table", { provider = fake(scramble) })
    H.eq(r.ok, false)
    H.ok(r.res:find("lines"))
    r = run({ "a", 5 }, { provider = fake(scramble) })
    H.eq(r.ok, false)
    H.ok(r.res:find("lines%[2%]"))
    r = run({ "a" }, { provider = fake(scramble), target = "" })
    H.eq(r.ok, false)
    H.ok(r.res:find("target"))
    local ok_err = pcall(md.translate_markdown, { "a" }, { target = "EN" }, nil)
    H.falsy(ok_err, "a missing callback is a programming error")

    r = run({ "Ein Absatz." }, { cfg = { engine = "custom", fallback = {} } })
    H.eq(r.ok, false, "no usable engine: the call fails up front")
    H.ok(r.res:find("no available translate engine"), tostring(r.res))
    H.eq(r.calls, 1)
  end

  -- the public facade --------------------------------------------------------------------------------------------------------------------------------------------------------------------
  do
    local language = require("language")
    H.eq(type(language.translate_markdown), "function")
    local done
    language.translate_markdown({ "Ein Absatz." }, {
      target = "EN",
      provider = fake(scramble),
      cache = false,
      cfg = { markdown = { disk_cache = false } },
    }, function(ok, res)
      done = { ok, res }
    end)
    vim.wait(1000, function()
      return done ~= nil
    end, 2)
    H.ok(
      done and done[1] and done[2][1] == "nielE ztasbA." or done[2][1] == scramble("Ein Absatz.")
    )
  end

  -- Fuzz: random documents, random misbehaviour, the invariants hold ----------------------------------------------------------------------------------------------------------------
  do
    math.randomseed(20261007)
    local pool = {
      "# Titel eins",
      "Text mit `code` und [Link](#titel-eins) und mehr Woertern.",
      "",
      "- Punkt eins",
      "  Folgezeile hier",
      "1. Eins",
      "> Zitat Zeile",
      "> zweite Zeile",
      "```lua",
      "local x = 1",
      "```",
      "| a | b |",
      "|---|---|",
      "| x | y |",
      "<div>",
      "<!-- c -->",
      "---",
      "[ref]: /x",
      "    eingerueckt",
      "Zeile mit Umbruch  ",
      "naechste Zeile",
      "Backslash\\",
      "Ein Absatz in drei",
      "Zeilen mit vielen Woertern",
      "und noch mehr Text darin.",
      "## Zweiter Titel",
      "![Bild](a.png) Text",
      "- [ ] Aufgabe",
      "Fussnote[^1] hier",
      "[^1]: Notiz",
      "~~~",
    }
    local modes = {
      scramble,
      expand,
      shrink,
      function(t)
        return t:gsub("{%d+}", "")
      end,
      function(t)
        return t .. "\n" .. t
      end,
      function()
        return "- - -"
      end,
      function()
        return "\228\184\173"
      end,
      function()
        return nil
      end,
    }
    for iter = 1, 250 do
      local doc = {}
      if math.random() < 0.2 then
        doc = { "---", "title: x", "---" }
      end
      for _ = 1, math.random(1, 22) do
        doc[#doc + 1] = pool[math.random(#pool)]
      end
      local fn = modes[math.random(#modes)]
      local r = run(doc, { provider = fake(fn, { sync = true }), max_units = math.random(1, 6) })
      local what = ("fuzz %d: %s"):format(iter, table.concat(doc, "\\n"))
      H.ok(r.ok, what .. " -> " .. tostring(r.res))
      H.eq(r.calls, 1, what)
      H.eq(#r.res, #doc, "#out == #in: " .. what)
      if not vim.tbl_contains(doc, "<div>") then
        -- inside an HTML block a fence marker is only text: the naive fence finder would disagree
        same_lines(r.res, doc, helpers.fence_set(doc), "fences " .. what)
      end
      same_lines(r.res, doc, front_set(doc), "front matter " .. what)
      for i, l in ipairs(r.res) do
        H.falsy(l:find("[\r\n]"), "no newline inside a line: " .. what)
        H.eq(type(l), "string", what .. " line " .. i)
      end
    end
  end

  cache._reset()
end
