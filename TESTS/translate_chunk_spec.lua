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

  -- registry: every engine is wrapped ---------------------------------------------------
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
  local runs = {}
  local real_job = package.loaded["language.util.job"]
  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      runs[#runs + 1] = argv
      opts.on_done(true, '[[["x","y"]]]', "")
      return { cancel = function() end }
    end,
  }
  local registry = require("language.translate.providers.registry")
  local google = registry.get("google")
  local g_lines = {}
  for i = 1, 600 do
    g_lines[i] = ("line %03d "):format(i) .. string.rep("a", 60)
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
  H.eq(gdone, 1, "cb exactly once")
  H.ok(gok, "success")
  H.eq(#gres, #runs, "one translated segment per block here, joined in order")
  package.loaded["language.util.job"] = real_job
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate.providers.google"] = nil
end
