-- TESTS/translate_chunk_spec.lua — language.translate.chunk: splitting large
-- translate inputs into provider-sized, line-aligned blocks, and the wrapper
-- every registry provider goes through. A fake provider/runner only: no curl,
-- no network. The wrapper's contract is what the callers rely on: line count
-- preserved, `cb` exactly once, a failed block fails the call, cancel stops it.

return function(H)
  local chunk = require("language.translate.chunk")

  --- A fake provider that "translates" by upper-casing and records each call.
  ---@param limits table
  ---@param on_call? fun(lines: string[], cb: function, n: integer): table|nil
  local function fake(limits, on_call)
    local p = { name = "fake", limits = limits, calls = {} }
    p.available = function()
      return true
    end
    p.translate = function(lines, _t, _s, _c, cb)
      p.calls[#p.calls + 1] = lines
      if on_call then
        return on_call(lines, cb, #p.calls)
      end
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = l:upper()
      end
      cb(true, out)
      return { cancel = function() end }
    end
    return p
  end

  local function run(provider, lines, cfg)
    local wrapped = chunk.wrap(provider)
    local calls, ok, result = 0, nil, nil
    local job = wrapped.translate(lines, "DE", nil, cfg or {}, function(o, r)
      calls, ok, result = calls + 1, o, r
    end)
    return {
      calls = function()
        return calls
      end,
      ok = function()
        return ok
      end,
      result = function()
        return result
      end,
      job = job,
    }
  end

  -- split(): boundaries --------------------------------------------------------
  local blocks = chunk.split({ "aaaa", "bbbb", "cccc", "dddd" }, { max_bytes = 10 })
  H.eq(#blocks, 2, "4 lines of cost 5 under a budget of 10: two blocks")
  H.eq(blocks[1].last, 2, "the first block ends after line 2")
  H.eq(blocks[2].first, 3, "and the next one starts right after it")

  local para = { "one", "two", "", "three", "four", "five", "six" }
  local pb = chunk.split(para, { max_bytes = 21 })
  H.eq(pb[1].last, 3, "a cut prefers the blank line (paragraph boundary)")
  H.eq(pb[2].first, 4, "so the next paragraph starts a block")

  local covered = 0
  for _, b in ipairs(chunk.split(vim.fn.split(string.rep("x\n", 50), "\n"), { max_bytes = 7 })) do
    covered = covered + (b.last - b.first + 1)
  end
  H.eq(covered, 50, "the blocks cover every line exactly once")

  local capped = chunk.split({ "a", "b", "c", "d", "e" }, { max_bytes = 1000, max_lines = 2 })
  H.eq(#capped, 3, "max_lines caps the block size (DeepL: 50 texts per request)")

  local bad, err = chunk.split({ "ok", string.rep("y", 50) }, { max_bytes = 10 })
  H.eq(bad, nil, "a single line over the budget cannot be split")
  H.contains(err, "line 2", "the message names the line")

  -- limits_for(): max_chars only lowers ------------------------------------------
  local p0 = fake({ max_bytes = 100 })
  H.eq(chunk.limits_for(p0, { max_chars = 40 }).max_bytes, 40, "max_chars lowers the budget")
  H.eq(chunk.limits_for(p0, { max_chars = 400 }).max_bytes, 100, "but never raises it")
  H.eq(chunk.limits_for(p0, { max_chars = 0 }).max_bytes, 100, "0 means the engine default")
  H.eq(chunk.limits_for({ name = "x" }, {}), nil, "no limits declared: nothing to enforce")

  -- wrap(): >32 700 characters never reach the provider as one payload ----------
  local big = {}
  for i = 1, 800 do
    big[i] = ("line %04d "):format(i) .. string.rep("w", 40)
  end
  local total = #table.concat(big, "\n")
  H.ok(total > 32700, "fixture is above the Windows command-line limit (" .. total .. ")")
  local pbig = fake({ max_bytes = 6000 })
  local r = run(pbig, big)
  H.ok(r.ok(), "the oversized input is translated")
  H.eq(r.calls(), 1, "cb runs exactly once")
  H.ok(#pbig.calls > 1, "in several blocks")
  for _, c in ipairs(pbig.calls) do
    H.ok(#table.concat(c, "\n") <= 6000, "every block respects the budget")
  end
  H.eq(#r.result(), 800, "the line count is preserved")
  H.eq(r.result()[1], big[1]:upper(), "first line is in place")
  H.eq(r.result()[800], big[800]:upper(), "and so is the last, in order")
  local flat = {}
  for _, c in ipairs(pbig.calls) do
    vim.list_extend(flat, c)
  end
  H.eq(table.concat(flat, "\n"), table.concat(big, "\n"), "blocks together are exactly the input")

  -- an input that fits goes straight through (same job, no wrapping effects) -----
  local pfit = fake({ max_bytes = 1000 })
  local rf = run(pfit, { "a", "b" })
  H.eq(#pfit.calls, 1, "small input: one provider call")
  H.eq(rf.result()[2], "B", "result is the provider's")

  -- a failing block fails the whole call, cb once -----------------------------
  local pfail = fake({ max_bytes = 10 }, function(lines, cb, n)
    if n == 2 then
      cb(false, "HTTP 429")
    else
      cb(true, lines)
    end
  end)
  local rfail = run(pfail, { "aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff" })
  H.falsy(rfail.ok(), "a failed block fails the call")
  H.contains(rfail.result(), "HTTP 429", "with the provider's message")
  H.contains(rfail.result(), "block 2/", "and the block that failed")
  H.eq(rfail.calls(), 1, "cb exactly once")
  H.eq(#pfail.calls, 2, "later blocks are not sent")

  -- a provider that throws is reported, not raised -----------------------------
  local pending
  local pthrow = fake({ max_bytes = 10 }, function(lines, cb, n)
    if n == 2 then
      error("spawn exploded")
    end
    pending = function()
      cb(true, lines)
    end
    return { cancel = function() end }
  end)
  local rthrow_calls, rthrow_ok, rthrow_msg = 0, nil, nil
  local okcall = pcall(function()
    chunk.wrap(pthrow).translate({ "aaaa", "bbbb", "cccc", "dddd" }, "DE", nil, {}, function(o, m)
      rthrow_calls, rthrow_ok, rthrow_msg = rthrow_calls + 1, o, m
    end)
    pending() -- block 1 finishes; sending block 2 throws
  end)
  H.ok(okcall, "a throwing provider does not raise out of the wrapper")
  H.falsy(rthrow_ok, "it fails the call")
  H.contains(rthrow_msg, "spawn exploded", "with the error text")
  H.eq(rthrow_calls, 1, "once")

  -- a single over-long line: a clear message, provider never called -----------------
  local plong = fake({ max_bytes = 10 })
  local rlong = run(plong, { "ok", string.rep("z", 30) })
  H.falsy(rlong.ok(), "an unsplittable line fails the call")
  H.contains(rlong.result(), "line 2", "naming the line")
  H.contains(rlong.result(), "fake", "and the engine")
  H.eq(#plong.calls, 0, "without spawning anything")
  H.eq(rlong.calls(), 1, "cb exactly once")

  -- cancel() mid-run stops the active block and sends no further ones -------------
  local pending_cb, cancelled_jobs = nil, 0
  local pcancel = fake({ max_bytes = 10 }, function(_, cb, _)
    pending_cb = cb
    return {
      cancel = function()
        cancelled_jobs = cancelled_jobs + 1
      end,
    }
  end)
  local rc = run(pcancel, { "aaaa", "bbbb", "cccc", "dddd" })
  H.eq(#pcancel.calls, 1, "the first block is in flight")
  rc.job.cancel()
  H.eq(cancelled_jobs, 1, "cancel() cancels the running block")
  pending_cb(true, { "AAAA", "BBBB" })
  H.eq(#pcancel.calls, 1, "a late result does not start the next block")
  H.eq(rc.calls(), 0, "and the callback is dropped, like a cancelled job")

  -- asynchronous blocks complete in order -------------------------------------------
  local queue = {}
  local pasync = fake({ max_bytes = 10 }, function(lines, cb)
    queue[#queue + 1] = function()
      cb(true, vim.tbl_map(string.upper, lines))
    end
    return { cancel = function() end }
  end)
  local ra = run(pasync, { "aaaa", "bbbb", "cccc", "dddd" })
  H.eq(ra.calls(), 0, "nothing is delivered before the blocks finish")
  while #queue > 0 do
    table.remove(queue, 1)()
  end
  H.ok(ra.ok(), "all blocks done: success")
  H.eq(table.concat(ra.result(), ","), "AAAA,BBBB,CCCC,DDDD", "joined in order")
  H.eq(ra.calls(), 1, "cb exactly once")

  -- limits_for(): an engine's own config may raise its budget ------------------------
  local pov = fake({
    max_bytes = 100,
    override = function(c)
      return c.custom and c.custom.max_bytes
    end,
  })
  H.eq(chunk.limits_for(pov, {}).max_bytes, 100, "no engine config: the declared budget")
  H.eq(
    chunk.limits_for(pov, { custom = { max_bytes = 5000 } }).max_bytes,
    5000,
    "the engine's own option can raise it"
  )
  H.eq(
    chunk.limits_for(pov, { custom = { max_bytes = 5000 }, max_chars = 40 }).max_bytes,
    40,
    "translate.max_chars still lowers whatever applies"
  )

  -- blank lines at a block edge survive an engine that trims them ----------------------
  -- gtx drops leading/trailing newlines of the whole text, `trans -b` output is
  -- right-trimmed, the documented custom parse `vim.split(out, "\n")` adds one
  -- trailing "" of its own. The block cut prefers a blank line, so without the
  -- wrapper's edge handling every cut loses a line (and indent.restore() then
  -- skips the whole range, and TranslateReplace glues paragraphs together).
  ---@param limits table
  ---@param trailing? boolean   -- append "\n" before splitting, like `vim.split(out .. "\n", ...)`
  local function trimming(limits, trailing)
    local p = { name = "trim", limits = limits, calls = {} }
    p.available = function()
      return true
    end
    p.translate = function(lines, _t, _s, _c, cb)
      p.calls[#p.calls + 1] = lines
      local text = table.concat(lines, "\n"):upper():gsub("^%s+", ""):gsub("%s+$", "")
      if trailing then
        text = text .. "\n"
      end
      cb(true, vim.split(text, "\n", { plain = true }))
      return { cancel = function() end }
    end
    return p
  end

  local doc = {
    "alpha one",
    "alpha two",
    "",
    "beta one",
    "beta two",
    "",
    "gamma one",
    "",
    "",
    "delta one",
    "delta two",
  }
  local doc_up = vim.tbl_map(string.upper, doc)
  local doc_blocks = chunk.split(doc, { max_bytes = 30 })
  local cuts_on_blank = 0
  for _, b in ipairs(doc_blocks) do
    if doc[b.last] == "" then
      cuts_on_blank = cuts_on_blank + 1
    end
  end
  H.ok(cuts_on_blank > 0, "fixture: at least one block ends on a blank line")

  local ptrim = trimming({ max_bytes = 30 })
  local rtrim = run(ptrim, doc)
  H.ok(rtrim.ok(), "the chunked document is translated")
  H.eq(#rtrim.result(), #doc, "the line count is preserved against an engine that trims")
  H.eq(
    table.concat(rtrim.result(), "\n"),
    table.concat(doc_up, "\n"),
    "blank separators stay in place"
  )
  for _, c in ipairs(ptrim.calls) do
    H.falsy(c[1]:match("^%s*$"), "no block is sent with a leading blank line")
    H.falsy(c[#c]:match("^%s*$"), "nor with a trailing one")
  end

  local ptrail = trimming({ max_bytes = 30 }, true)
  local rtrail = run(ptrail, doc)
  H.eq(#rtrail.result(), #doc, "a parse that appends a trailing empty line does not add lines")
  H.eq(table.concat(rtrail.result(), "\n"), table.concat(doc_up, "\n"), "and nothing moves")

  -- the single-block path has the same trimming problem (selection ending in a blank line)
  local psingle = trimming({ max_bytes = 1000 })
  local rsingle = run(psingle, { "", "a", "b", "", "" })
  H.eq(table.concat(rsingle.result(), "|"), "|A|B||", "edges of a single block are put back too")
  H.eq(table.concat(psingle.calls[1], "|"), "a|b", "and were not sent")

  -- a block that is blank throughout is not sent at all
  local pblank = fake({ max_bytes = 10 })
  local rblank = run(pblank, { "aaaa", "", "", "", "", "", "", "bbbb" })
  H.ok(rblank.ok(), "blank runs in the middle are fine")
  H.eq(#rblank.result(), 8, "all lines come back")
  for _, c in ipairs(pblank.calls) do
    H.falsy(table.concat(c, ""):match("^%s*$"), "no provider call carries only blank lines")
  end
  local plone = fake({ max_bytes = 1000 })
  local rlone = run(plone, { "" })
  H.eq(#plone.calls, 0, "a lone blank line is not sent")
  H.eq(#rlone.result(), 1, "and comes back as one line (not as an empty list)")
  H.eq(rlone.result()[1], "", "unchanged")

  -- an over-long line is cut at sentence/word boundaries and stays ONE line ------------
  local prose =
    "First sentence is here. Second sentence follows it! Third one asks why? Fourth ends the line."
  local plong2 = fake({ max_bytes = 40 })
  local rlong2 = run(plong2, { "head", prose, "tail" })
  H.ok(rlong2.ok(), "an over-long line no longer fails the call")
  H.eq(#rlong2.result(), 3, "the line count is unchanged")
  H.eq(rlong2.result()[1], "HEAD", "the line before is in place")
  H.eq(rlong2.result()[2], prose:upper(), "the pieces are re-joined with a single space")
  H.eq(rlong2.result()[3], "TAIL", "the line after is in place")
  H.ok(#plong2.calls > 2, "the long line went out in several pieces")
  for _, c in ipairs(plong2.calls) do
    for _, l in ipairs(c) do
      H.ok(#l + 1 <= 40, "every piece fits the budget")
    end
  end
  for _, c in ipairs(plong2.calls) do
    H.ok(not (#c > 1 and c[1] == "head"), "pieces never share a block with other lines")
  end

  local words = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda"
  local pwords = fake({ max_bytes = 20 })
  local rwords = run(pwords, { words })
  H.ok(rwords.ok(), "a line without sentence ends is cut at white space")
  H.eq(#rwords.result(), 1, "one line out")
  H.eq(rwords.result()[1], words:upper(), "words intact")

  local jp = string.rep("これは文章です。", 20)
  local pjp = fake({ max_bytes = 100 })
  local rjp = run(pjp, { jp })
  H.ok(rjp.ok(), "CJK text without any white space is cut after the full stop")
  H.eq(#rjp.result(), 1, "one line out")
  H.eq(rjp.result()[1]:gsub(" ", ""), jp, "the characters are intact")
  for _, c in ipairs(pjp.calls) do
    for _, l in ipairs(c) do
      H.eq(l:sub(-3), "。", "no piece is cut inside a UTF-8 character")
    end
  end

  local pml = fake({ max_bytes = 30, max_lines = 2 })
  local rml = run(pml, { "aaaa bbbb cccc. dddd eeee ffff. gggg hhhh iiii. jjjj kkkk llll." })
  H.ok(rml.ok(), "pieces honour max_lines too")
  for _, c in ipairs(pml.calls) do
    H.ok(#c <= 2, "at most two pieces per block")
  end
  H.eq(#rml.result(), 1, "still one line")

  local ptok = fake({ max_bytes = 10 })
  local rtok = run(ptok, { "ok", string.rep("z", 30) })
  H.falsy(rtok.ok(), "a single token over the budget is still an error")
  H.contains(rtok.result(), "line 2", "that names the line")
  H.eq(#ptok.calls, 0, "before anything is sent")

  -- translate.max_blocks refuses an input that needs too many requests ------------------
  local six = { "aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff" }
  local pcap = fake({ max_bytes = 10 })
  local rcap = run(pcap, six, { max_blocks = 2 })
  H.falsy(rcap.ok(), "three requests are more than max_blocks = 2")
  H.contains(rcap.result(), "translate.max_blocks", "the message names the option")
  H.eq(#pcap.calls, 0, "nothing is sent")
  H.eq(rcap.calls(), 1, "cb exactly once")
  local pcap3 = fake({ max_bytes = 10 })
  H.ok(run(pcap3, six, { max_blocks = 3 }).ok(), "exactly max_blocks requests are fine")
  local pcap0 = fake({ max_bytes = 10 })
  H.ok(run(pcap0, six, { max_blocks = 0 }).ok(), "0 = no limit")
  H.eq(
    require("language.config.DEFAULTS").translate.max_blocks,
    50,
    "the shipped default caps one call at 50 requests"
  )

  -- a single request reports the engine's message as it is (no block prefix) ------------
  local pone = fake({ max_bytes = 1000 }, function(_, cb)
    cb(false, "HTTP 429")
    return nil
  end)
  local rone = run(pone, { "a", "b" })
  H.eq(rone.result(), "HTTP 429", "no 'block 1/1' decoration for a single request")

  -- registry: every engine is wrapped ---------------------------------------------------
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
  local runs, stdins = {}, {}
  local real_job = package.loaded["language.util.job"]
  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      runs[#runs + 1] = argv
      stdins[#stdins + 1] = opts.stdin
      opts.on_done(true, '[[["x","y"]]]', "")
      return { cancel = function() end }
    end,
  }
  local registry = require("language.translate.providers.registry")
  local google = registry.get("google")
  local g_lines = {}
  for i = 1, 1200 do
    g_lines[i] = ("line %04d "):format(i) .. string.rep("a", 60)
  end
  local gdone, gok, gres = 0, nil, nil
  google.translate(g_lines, "DE", nil, {}, function(o, rr)
    gdone, gok, gres = gdone + 1, o, rr
  end)
  H.ok(#runs > 1, "google through the registry: the input is split into several requests")
  for _, argv in ipairs(runs) do
    for _, a in ipairs(argv) do
      H.ok(#a < 32700, "no argv element comes near the Windows limit")
    end
  end
  for _, body in ipairs(stdins) do
    H.ok(#body <= 15000, "every request body stays within the google budget")
  end
  H.eq(gdone, 1, "cb exactly once")
  H.ok(gok, "success")
  H.eq(#gres, #runs, "one translated segment per block here, joined in order")

  -- google: single long lines (unwrapped markdown paragraphs, CJK) no longer fail ------
  -- Before the body moved to stdin the budget was the percent-encoded length 5000:
  -- a ~3 600 character prose line or a 600 character Japanese line was refused.
  local echo_runs = {}
  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      echo_runs[#echo_runs + 1] = { argv = argv, stdin = opts.stdin }
      opts.on_done(true, vim.json.encode({ { { (opts.stdin or ""):upper() } } }), "")
      return { cancel = function() end }
    end,
  }
  -- the providers hold the job module they were loaded with: load them afresh
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
  registry = require("language.translate.providers.registry")
  ---@param line string
  ---@return table result, integer requests
  local function google_one(line)
    echo_runs = {}
    local res
    registry.get("google").translate({ line }, "DE", nil, {}, function(o, got)
      res = { ok = o, result = got }
    end)
    return res, #echo_runs
  end

  local prose36 = string.rep("word ", 720):gsub(" $", "")
  local g1, n1 = google_one(prose36)
  H.ok(g1.ok, "a 3 600 character prose line is translated")
  H.eq(n1, 1, "in one request")
  H.eq(g1.result[1], prose36:upper(), "unchanged by the engine's echo")

  local jp600 = string.rep("これは文章です。", 75)
  local g2, n2 = google_one(jp600)
  H.ok(g2.ok, "a 600 character Japanese line is translated")
  H.eq(n2, 1, "in one request")

  local huge = string.rep("The quick brown fox jumps over the lazy dog. ", 900):gsub(" $", "")
  local g3, n3 = google_one(huge)
  H.ok(g3.ok, "a 40 000 byte single line is translated too")
  H.ok(n3 > 1, "in several requests")
  H.eq(#g3.result, 1, "and still comes back as one line")
  H.eq(g3.result[1], huge:upper(), "re-joined without losing a word")
  for _, req in ipairs(echo_runs) do
    H.ok(#req.stdin <= 15000, "each piece fits the request budget")
  end

  package.loaded["language.util.job"] = real_job
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
end
