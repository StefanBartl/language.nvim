-- TESTS/translate_ai_provider_spec.lua -- the `ai` translate engine against a fake
-- `ai` module (package.loaded): request shape, strict parse, one retry, errors
-- for policy and bulk limits, cancel, chunking, registry behaviour and the model
-- in the unit cache key of translate_markdown. No ai.nvim, no network.

return function(H)
  local helpers = dofile(vim.fn.getcwd() .. "/TESTS/markdown_helpers.lua")
  local saved_ai, saved_bulk = package.loaded["ai"], package.loaded["ai.bulk"]
  local saved_prov = package.loaded["language.translate.providers.ai"]
  package.loaded["language.translate.providers.ai"] = nil
  package.loaded["language.translate.providers.registry"] = nil

  ---@type table
  local fake
  ---Install a fake ai module. `script(req, n)` returns ok, res (or nil: never answers).
  local function install(script, conf)
    fake = { requests = {}, killed = 0, policy_value = { allowed = nil, bulk_granted = {} } }
    fake.config_value = conf or { provider = nil, model = {} }
    local m = {}
    function m.config()
      return fake.config_value
    end
    function m.policy()
      return fake.policy_value
    end
    function m.ask(req, cb)
      fake.requests[#fake.requests + 1] = vim.deepcopy(req)
      local n = #fake.requests
      local dead = false
      vim.schedule(function()
        if dead then
          return
        end
        local ok, res = script(req, n)
        if ok ~= nil then
          cb(ok, res)
        end
      end)
      return {
        kill = function()
          fake.killed = fake.killed + 1
          dead = true
        end,
        is_closing = function()
          return dead
        end,
      }
    end
    package.loaded["ai"] = m
    package.loaded["ai.bulk"] = { reset = function() end }
  end

  local function ai_mod()
    package.loaded["language.translate.providers.ai"] = nil
    return require("language.translate.providers.ai")
  end

  local function call(p, lines, cfg)
    local r = { n = 0 }
    r.job = p.translate(lines, "DE", "EN", cfg or {}, function(ok, res)
      r.n = r.n + 1
      r.ok, r.res = ok, res
    end)
    vim.wait(2000, function()
      return r.n > 0
    end, 2)
    return r
  end

  local function answer(list, model)
    return true,
      {
        text = vim.json.encode(list),
        provider = "claude",
        bulk = { provider = "claude", model = model or "m1", label = "x" },
      }
  end

  -- valid answer + request shape ----------------------------------------------
  install(function(req)
    return answer(vim.json.decode(req.prompt))
  end)
  local ai = ai_mod()
  H.eq(ai.available({}), true, "available with a loadable ai and no policy")
  local r = call(
    ai,
    { "Hello {1}", "world" },
    { ai = { style = "formal", glossary = { Foo = "Bar" } } }
  )
  H.ok(r.ok, "a valid answer is a success")
  H.eq(vim.inspect(r.res), vim.inspect({ "Hello {1}", "world" }), "the elements come back in order")
  H.eq(#fake.requests, 1, "one request")
  local q = fake.requests[1]
  H.eq(q.prompt, '["Hello {1}","world"]', "the input is a JSON array")
  H.contains(q.system, "DE", "the target is in the system prompt")
  H.contains(q.system, "from EN", "the source is in the system prompt")
  H.contains(q.system, "{n}", "placeholders are named in the system prompt")
  H.contains(q.system, "Style: formal", "style is passed")
  H.contains(q.system, "Foo -> Bar", "glossary is passed")
  H.ok(
    q.bulk and q.bulk.label and q.bulk.max_chars == 6000,
    "a bulk profile with label and cap is sent"
  )
  H.eq(q.bulk.concurrency, 2, "concurrency from the defaults")
  H.eq(q.bulk.max_total_chars, 500000, "cumulative cap from the defaults")

  -- the label is shared inside one run
  call(ai, { "again" })
  H.eq(fake.requests[2].bulk.label, fake.requests[1].bulk.label, "calls of one run share the label")

  -- fenced JSON is tolerated, nothing else ------------------------------------
  install(function(req)
    return true,
      { text = "```json\n" .. req.prompt .. "\n```", bulk = { provider = "p", model = "m" } }
  end)
  ai = ai_mod()
  r = call(ai, { "a", "b" })
  H.ok(r.ok and #fake.requests == 1, "a fenced array is accepted without a retry")

  install(function(req)
    return true, { text = "Here you go: " .. req.prompt, bulk = { provider = "p", model = "m" } }
  end)
  ai = ai_mod()
  r = call(ai, { "a" })
  H.ok(not r.ok, "prose around the array is refused")
  H.eq(#fake.requests, 2, "...after exactly one retry")
  H.contains(fake.requests[2].system, "previous answer was refused", "the retry names the problem")

  -- wrong count: retry once, then a good answer -------------------------------
  install(function(req, n)
    local items = vim.json.decode(req.prompt)
    if n == 1 then
      table.remove(items)
    end
    return answer(items)
  end)
  ai = ai_mod()
  r = call(ai, { "a", "b", "c" })
  H.ok(r.ok, "the retry recovers a wrong count")
  H.eq(#fake.requests, 2, "two requests")
  H.contains(fake.requests[2].system, "3", "the retry states the expected count")

  -- wrong count twice: an error, no third try --------------------------------
  install(function()
    return answer({ "only one" })
  end)
  ai = ai_mod()
  r = call(ai, { "a", "b" })
  H.ok(not r.ok, "a second wrong count is an error")
  H.eq(#fake.requests, 2, "no third request")
  H.contains(r.res, "2", "the message names the count")

  -- broken JSON, wrong types, placeholders ------------------------------------
  install(function()
    return true, { text = "[not json", bulk = { provider = "p", model = "m" } }
  end)
  ai = ai_mod()
  r = call(ai, { "a" })
  H.ok(not r.ok and r.res:find("JSON", 1, true), "broken JSON is an error naming JSON")

  install(function()
    return true, { text = '[1, "x"]', bulk = { provider = "p", model = "m" } }
  end)
  ai = ai_mod()
  H.ok(not call(ai, { "a", "b" }).ok, "a non-string element is refused")

  install(function()
    return true, { text = '{"a": "x"}', bulk = { provider = "p", model = "m" } }
  end)
  ai = ai_mod()
  H.ok(not call(ai, { "a" }).ok, "an object is not an array")

  install(function()
    return answer({ "Hallo {2}" })
  end)
  ai = ai_mod()
  r = call(ai, { "Hello {1}" })
  H.ok(not r.ok and r.res:find("placeholder", 1, true), "a changed placeholder is refused")

  -- policy refusal and bulk limit: surfaced, never retried ---------------------
  install(function()
    return false,
      {
        kind = "provider_resolution",
        message = "provider 'claude' is not on this machine's allow-list",
      }
  end)
  ai = ai_mod()
  r = call(ai, { "a" })
  H.ok(not r.ok, "a policy refusal is an error")
  H.contains(r.res, "allow-list", "the message of ai.nvim is kept")
  H.eq(#fake.requests, 1, "a refusal is not retried")

  install(function()
    return false, { kind = "bulk_limit", message = "over bulk.max_total_chars (10)" }
  end)
  ai = ai_mod()
  r = call(ai, { "a" })
  H.ok(not r.ok and r.res:find("bulk_limit", 1, true), "bulk_limit is named")
  H.contains(r.res, "translate.ai.max_chars", "...with the option to change")
  H.eq(#fake.requests, 1, "a limit is not retried")

  -- availability / policy -------------------------------------------------------
  install(function() end, { provider = "claude", model = {} })
  fake.policy_value = { allowed = { "ollama" }, bulk_granted = {} }
  ai = ai_mod()
  H.eq(ai.available({}), false, "the configured provider outside the allow-list is unavailable")
  H.contains(ai.blocked({}), "allow-list", "and says why")
  H.eq(ai.available({ ai = { provider = "ollama" } }), true, "a listed provider is available")
  fake.policy_value = { allowed = { "ollama" }, bulk_granted = { "claude" } }
  H.eq(ai.available({}), true, "a bulk grant counts")
  fake.policy_value = { allowed = { "ollama" }, bulk_granted = {} }
  fake.requests = {}
  r = call(ai, { "a" }, {})
  H.ok(
    not r.ok and r.res:find("allow-list", 1, true),
    "translate itself refuses too, without a request"
  )
  H.eq(#fake.requests, 0, "...and sends nothing")

  package.loaded["ai"] = nil
  package.preload["ai"] = nil
  ai = ai_mod()
  local ok_req = pcall(require, "ai")
  if not ok_req then
    H.eq(ai.available({}), false, "without ai.nvim the engine is unavailable")
  end

  -- registry: a configured ai engine never falls back silently ------------------
  local reg = (function()
    package.loaded["language.translate.providers.registry"] = nil
    return require("language.translate.providers.registry")
  end)()
  if not ok_req then
    local p, err = reg.resolve({ engine = "ai", fallback = { "google" } })
    H.ok(
      p == nil and err and err:find("ai.nvim", 1, true),
      "engine = ai without ai.nvim is an error, not google"
    )
  end
  install(function() end)
  package.loaded["language.translate.providers.ai"] = nil
  package.loaded["language.translate.providers.registry"] = nil
  reg = require("language.translate.providers.registry")
  local p = reg.resolve({ engine = "ai", fallback = { "google" } })
  H.eq(p and p.name, "ai", "the registry resolves ai when it is usable")
  H.ok(type(p.limits) == "table", "ai declares limits (the chunk wrapper applies)")
  local g = reg.resolve({ engine = "google", fallback = {} })
  H.eq(g and g.name, "google", "other engines are unaffected")

  -- chunking by the bulk budget -----------------------------------------------
  install(function(req)
    return answer(vim.json.decode(req.prompt))
  end)
  package.loaded["language.translate.providers.ai"] = nil
  package.loaded["language.translate.providers.registry"] = nil
  reg = require("language.translate.providers.registry")
  p = reg.get("ai")
  local lines = {}
  for i = 1, 150 do
    lines[i] = ("line number %d"):format(i)
  end
  r = call(p, lines)
  H.ok(r.ok and #r.res == 150, "150 lines come back as 150 lines")
  H.ok(#fake.requests >= 3, "split at the line limit (60) into several requests")
  for _, req in ipairs(fake.requests) do
    H.ok(#vim.json.decode(req.prompt) <= 60, "no request over 60 elements")
    H.ok(#req.prompt + #req.system <= 6000, "every request fits max_chars")
  end
  fake.requests = {}
  local big = {}
  for i = 1, 40 do
    big[i] = ("word%d "):format(i):rep(40)
  end
  r = call(p, big, { max_chars = 0, ai = { max_chars = 3000 } })
  H.ok(r.ok and #r.res == 40, "a small max_chars still translates everything")
  for _, req in ipairs(fake.requests) do
    H.ok(#req.prompt + #req.system <= 3000, "every request fits translate.ai.max_chars")
    H.eq(req.bulk.max_chars, 3000, "the cap sent is the configured one")
  end

  -- cancel kills the running ai request, no callback ---------------------------
  install(function() end)
  ai = ai_mod()
  local fired = 0
  local job = ai.translate({ "a" }, "DE", nil, {}, function()
    fired = fired + 1
  end)
  job.cancel()
  vim.wait(50)
  H.eq(fake.killed, 1, "cancel kills the ai request")
  H.eq(fired, 0, "a cancelled call does not call back")

  -- cache identity: provider, model, prompt version, glossary/style -------------
  install(function() end, { provider = "claude", model = { claude = "m1" } })
  ai = ai_mod()
  local id1 = ai.cache_id({})
  H.contains(id1, "claude/m1", "the identity names provider and model")
  fake.config_value = { provider = "claude", model = { claude = "m2" } }
  local id2 = ai.cache_id({})
  H.ok(id1 ~= id2, "a model switch changes the identity")
  H.ok(ai.cache_id({ ai = { model = "m3" } }) ~= id2, "translate.ai.model changes it")
  H.ok(ai.cache_id({ ai = { style = "formal" } }) ~= id2, "a style changes it")
  H.ok(ai.cache_id({ ai = { glossary = { A = "B" } } }) ~= id2, "a glossary changes it")

  -- model in the cache key of translate_markdown -------------------------------
  local md = require("language.translate.markdown")
  md.cache._reset()
  local doc = { "# Titel", "", "Ein Absatz mit Text." }
  local model = "m1"
  install(function(req)
    local items = vim.json.decode(req.prompt)
    for i, s in ipairs(items) do
      items[i] = s:upper()
    end
    return answer(items, model)
  end, { provider = "claude", model = { claude = "m1" } })
  package.loaded["language.translate.providers.ai"] = nil
  package.loaded["language.translate.providers.registry"] = nil
  local cfg = { engine = "ai", fallback = {}, markdown = { disk_cache = false } }
  local function md_run()
    return helpers.run(doc, { target = "EN", cache = true, cfg = cfg })
  end
  local m1 = md_run()
  H.ok(m1.ok, "translate_markdown through the ai engine succeeds")
  H.eq(#m1.res, #doc, "line count kept")
  H.eq(m1.res[3], "EIN ABSATZ MIT TEXT.", "the answer is used")
  local first = #fake.requests
  md_run()
  H.eq(#fake.requests, first, "a second run is served from the cache")
  fake.config_value = { provider = "claude", model = { claude = "m2" } }
  model = "m2"
  md_run()
  H.ok(#fake.requests > first, "a model switch asks again instead of serving old translations")
  md.cache._reset()

  -- Independent review ------------------------------------------------------------------
  -- A new run never resets the label of the old one: bulk.reset(label) refunds that run's
  -- characters to ai.nvim's session cap, which must keep counting the whole session.
  do
    local resets = {}
    install(function(req)
      return answer(vim.json.decode(req.prompt))
    end)
    package.loaded["ai.bulk"] = {
      reset = function(label)
        resets[#resets + 1] = label
      end,
    }
    ai = ai_mod()
    local real_hrtime, offset = vim.uv.hrtime, 0
    vim.uv.hrtime = function()
      return real_hrtime() + offset
    end
    local r1 = call(ai, { "a" })
    offset = offset + 10 * 1e9
    local r2 = call(ai, { "b" })
    vim.uv.hrtime = real_hrtime
    H.ok(r1.ok and r2.ok, "both runs succeed")
    H.ok(
      fake.requests[2].bulk.label ~= fake.requests[1].bulk.label,
      "a run after the grace period has a label of its own"
    )
    H.eq(#resets, 0, "...and the old label is not reset (it would refund the session cap)")
  end

  -- A line break inside an element would shift every line behind it
  install(function(req)
    local items = vim.json.decode(req.prompt)
    items[1] = items[1] .. "\nextra"
    return answer(items)
  end)
  ai = ai_mod()
  r = call(ai, { "a", "b" })
  H.ok(not r.ok and r.res:find("line break", 1, true), "an element with a line break is refused")
  H.eq(#fake.requests, 2, "...after one retry")

  -- The note of the retry goes into the next request: a placeholder the model made up is cut
  install(function()
    return answer({ "Hallo {" .. ("9"):rep(5000) .. "}" })
  end)
  ai = ai_mod()
  r = call(ai, { "Hello" })
  H.ok(not r.ok and #r.res < 400, "the error message stays short")
  H.ok(#fake.requests[2].system < 2000, "...and so does the system prompt of the retry")

  -- An ai.nvim without ai.bulk would ignore req.bulk and send the document as a chat
  install(function() end)
  package.loaded["ai.bulk"] = nil
  package.preload["ai.bulk"] = function()
    error("no bulk here")
  end
  ai = ai_mod()
  H.eq(ai.available({}), false, "without ai.bulk the engine is unavailable")
  H.contains(ai.blocked({}), "bulk", "and says why")
  package.preload["ai.bulk"] = nil
  package.loaded["ai.bulk"] = { reset = function() end }

  -- The identity is what ai.nvim resolves now, not what an earlier answer said
  install(function() end, { provider = "auto", model = { claude = "m1" } })
  local resolved = { id = "claude", default_model = "dm" }
  package.loaded["ai.providers"] = {
    resolve = function()
      return resolved
    end,
  }
  ai = ai_mod()
  H.contains(
    ai.cache_id({}),
    "claude/m1",
    "provider auto: the model of the provider it resolves to"
  )
  fake.config_value = { provider = "auto", model = {} }
  H.contains(ai.cache_id({}), "claude/dm", "...else the provider's own default")
  resolved = { id = "ollama", default_model = "llama" }
  H.contains(ai.cache_id({}), "ollama/llama", "a changed provider order changes the identity")
  package.loaded["ai.providers"] = {
    resolve = function()
      return nil, { kind = "provider_resolution" }
    end,
  }
  H.contains(ai.cache_id({}), "auto/default", "when nothing resolves the configuration speaks")
  package.loaded["ai.providers"] = nil

  -- The session cap is named for what it is
  install(function()
    return false,
      { kind = "bulk_limit", message = "over the cap", data = { reason = "max_session_chars" } }
  end)
  ai = ai_mod()
  r = call(ai, { "a" })
  H.contains(r.res, "max_session_chars", "the hint names ai.nvim's session cap")

  package.loaded["ai"], package.loaded["ai.bulk"] = saved_ai, saved_bulk
  package.loaded["language.translate.providers.ai"] = saved_prov
  package.loaded["language.translate.providers.registry"] = nil
end
