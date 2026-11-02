-- TESTS/translate_failover_spec.lua -- the engine chain of `translate.engine` + `translate.fallback`:
-- a request that FAILS goes on with the next engine the author listed, and only with those.
-- Fake engines only (package.loaded stand-ins for the provider modules): no curl, no network.

return function(H)
  local names = { "google", "deepl", "shell", "custom", "ai" }
  local saved = {}
  for _, n in ipairs(names) do
    saved[n] = package.loaded["language.translate.providers." .. n]
  end
  local saved_registry = package.loaded["language.translate.providers.registry"]

  ---@type table<string, table>
  local engines

  ---A fake engine. `script(lines, cb, n)` answers (or returns a job and answers later); the
  ---default answers with the upper-cased lines.
  local function engine(name, opts)
    opts = opts or {}
    local p = { name = name, calls = 0 }
    p.available = function()
      return opts.available ~= false
    end
    p.translate = function(lines, _t, _s, _c, cb)
      p.calls = p.calls + 1
      if opts.script then
        return opts.script(lines, cb, p.calls, p)
      end
      cb(true, vim.tbl_map(string.upper, lines))
      return { cancel = function() end }
    end
    return p
  end

  ---Install `set` (name -> fake engine; the others are unavailable fakes) and a fresh registry.
  local function install(set)
    engines = {}
    for _, n in ipairs(names) do
      engines[n] = set[n] or engine(n, { available = false })
      package.loaded["language.translate.providers." .. n] = engines[n]
    end
    package.loaded["language.translate.providers.registry"] = nil
    return require("language.translate.providers.registry")
  end

  ---@return table r { ok, result, calls }
  local function run(provider, lines)
    local r = { calls = 0 }
    r.job = provider.translate(lines or { "hello" }, "DE", nil, {}, function(ok, res)
      r.calls = r.calls + 1
      r.ok, r.result = ok, res
    end)
    return r
  end

  ---Collect what is notified while `fn` runs.
  local function notes(fn)
    local real, got = vim.notify, {}
    vim.notify = function(msg, level)
      got[#got + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(fn)
    vim.notify = real
    if not ok then
      error(err, 0)
    end
    return got
  end

  local function failing(msg)
    return function(_, cb)
      cb(false, msg)
      return { cancel = function() end }
    end
  end

  -- the default chain is one engine: the plain provider, nothing wrapped around it ----------------
  do
    local reg = install({ google = engine("google") })
    local p = reg.resolve({ engine = "google", fallback = { "google" } })
    H.eq(p, reg.get("google"), "engine = fallback = google is one engine: no failover wrapper")
  end

  -- first fails, second answers -----------------------------------------------------------------
  do
    local reg = install({
      google = engine("google", { script = failing("HTTP 429") }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    H.eq(p.name, "google", "the provider carries the name of the configured engine")
    local r
    local got = notes(function()
      r = run(p, { "a", "b" })
    end)
    H.ok(r.ok, "the call succeeds with the next engine")
    H.eq(table.concat(r.result, "|"), "A|B", "and delivers its answer")
    H.eq(r.calls, 1, "the callback runs exactly once")
    H.eq(engines.google.calls, 1, "the first engine was asked once")
    H.eq(engines.deepl.calls, 1, "and the second one took over")
    local text = table.concat(
      vim.tbl_map(function(n)
        return n.msg
      end, got),
      "\n"
    )
    H.contains(text, "deepl", "a hint names the engine that answered")
    H.contains(text, "google", "and the one that failed")
  end

  -- a first engine that answers: the second is never asked, nothing is notified --------------------
  do
    local reg = install({ google = engine("google"), deepl = engine("deepl") })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    local r
    local got = notes(function()
      r = run(p)
    end)
    H.ok(r.ok and engines.deepl.calls == 0, "the fallback stays unused while the engine works")
    H.eq(#got, 0, "and nothing is said")
  end

  -- everything fails: only the last error is reported ------------------------------------------
  do
    local reg = install({
      google = engine("google", { script = failing("first error") }),
      deepl = engine("deepl", { script = failing("second error") }),
      shell = engine("shell", { script = failing("last error") }),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl", "shell" } })
    local r = run(p)
    H.eq(r.ok, false, "the call fails")
    H.eq(r.result, "last error", "with the error of the last engine only")
    H.eq(r.calls, 1, "reported once")
    H.eq(engines.google.calls + engines.deepl.calls + engines.shell.calls, 3, "each tried once")
  end

  -- never to an engine the author did not list ---------------------------------------------------
  do
    local reg = install({
      google = engine("google", { script = failing("HTTP 429") }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = {} })
    local r = run(p)
    H.eq(r.ok, false, "an engine that is not in the chain does not rescue the call")
    H.eq(r.result, "HTTP 429")
    H.eq(engines.deepl.calls, 0, "the text was not handed to it")
  end

  -- an unavailable engine in the chain is skipped, an unknown name is ignored --------------------
  do
    local reg = install({
      google = engine("google", { script = failing("down") }),
      deepl = engine("deepl", { available = false }),
      shell = engine("shell"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl", "nonsense", "shell" } })
    local r = run(p)
    H.ok(r.ok, "the chain goes on to the next AVAILABLE engine")
    H.eq(engines.deepl.calls, 0, "the unavailable one is never asked")
    H.eq(engines.shell.calls, 1)
  end

  -- an error of the input does not switch ----------------------------------------------------------
  do
    local reg = install({
      google = engine("google", {
        script = function(_, cb)
          cb(false, "google: the input needs 9 requests", "input")
          return nil
        end,
      }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    local r = run(p)
    H.eq(r.ok, false)
    H.contains(r.result, "needs 9 requests", "the input error is reported as it is")
    H.eq(engines.deepl.calls, 0, "another engine would not help, so none is tried")
  end

  -- the chunk wrapper marks its own input errors the same way --------------------------------------
  do
    local limited = engine("google")
    limited.limits = { max_bytes = 10 }
    local reg = install({ google = limited, deepl = engine("deepl") })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    local r = run(p, { string.rep("x", 40) }) -- one token longer than any block: refused up front
    H.eq(r.ok, false, "a line that cannot be cut fails")
    H.eq(engines.deepl.calls, 0, "without trying the next engine")
  end

  -- ai: its failure is final (policy), even with a fallback; as a listed fallback it is used -------
  do
    local reg = install({
      ai = engine("ai", { script = failing("ai: policy refused") }),
      google = engine("google"),
    })
    local p = reg.resolve({ engine = "ai", fallback = { "google" } })
    local r = run(p)
    H.eq(r.ok, false, "a refusal of the ai engine does not hand the text to another engine")
    H.eq(r.result, "ai: policy refused")
    H.eq(engines.google.calls, 0)

    reg = install({
      google = engine("google", { script = failing("HTTP 429") }),
      ai = engine("ai"),
    })
    p = reg.resolve({ engine = "google", fallback = { "ai" } })
    r = run(p)
    H.ok(r.ok, "an ai engine the author listed after google may take over")
  end

  -- an engine that throws counts as a failure ----------------------------------------------------
  do
    local reg = install({
      google = engine("google", {
        script = function()
          error("boom")
        end,
      }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    local r = run(p)
    H.ok(r.ok, "a throwing engine does not take the call down")
  end

  -- cancel: the request in flight is cancelled, nothing is called back, no next engine ---------------
  do
    local cancelled = 0
    local reg = install({
      google = engine("google", {
        script = function()
          return {
            cancel = function()
              cancelled = cancelled + 1
            end,
          }
        end,
      }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    local r = run(p)
    r.job.cancel()
    H.eq(cancelled, 1, "the request of the first engine is cancelled")
    H.eq(r.calls, 0, "the callback never runs")
    H.eq(engines.deepl.calls, 0, "and the next engine is not started")
  end

  -- an answer that comes later (asynchronously) still moves on -------------------------------------
  do
    local late
    local reg = install({
      google = engine("google", {
        script = function(_, cb)
          late = cb
          return { cancel = function() end }
        end,
      }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } })
    local r = run(p)
    H.eq(r.calls, 0, "nothing yet while the first engine is out")
    late(false, "timeout")
    H.ok(r.ok, "its late failure hands the call to the next engine")
    late(true, { "again" }) -- a second answer of the same request is ignored
    H.eq(r.calls, 1, "exactly one callback")
  end

  -- opts.failover = false: the first available engine alone ------------------------------------------
  do
    local reg = install({
      google = engine("google", { script = failing("HTTP 429") }),
      deepl = engine("deepl"),
    })
    local p = reg.resolve({ engine = "google", fallback = { "deepl" } }, { failover = false })
    H.eq(p, reg.get("google"), "the plain provider, as translate_markdown asks for it")
    local r = run(p)
    H.eq(r.ok, false)
    H.eq(engines.deepl.calls, 0)
  end

  -- errors of resolve are unchanged ------------------------------------------------------------------------
  do
    local reg = install({})
    local p, err = reg.resolve({ engine = "google", fallback = { "deepl" } })
    H.eq(p, nil, "nothing available")
    H.contains(err or "", "no available translate engine (tried: google, deepl)")
  end

  for _, n in ipairs(names) do
    package.loaded["language.translate.providers." .. n] = saved[n]
  end
  package.loaded["language.translate.providers.registry"] = saved_registry
end
