-- TESTS/translate_providers_spec.lua — the translate engines: registry
-- resolution/fallback, and each provider's request-building and
-- response-parsing logic. `language.util.job` is stubbed so this never
-- spawns curl/trans/a real network request — the same "stub the collaborator,
-- assert on the call and the result" technique hover_spec.lua already uses
-- for the translate provider registry.

return function(H)
  ---@type table[]
  local calls = {}

  --- Replace `language.util.job` with a fake that records the argv/opts it
  --- was given and answers synchronously with a canned (ok, out, err).
  ---@param ok boolean
  ---@param out string
  ---@param err string|nil
  local function stub_job(ok, out, err)
    calls = {}
    package.loaded["language.util.job"] = {
      run = function(argv, opts)
        calls[#calls + 1] = { argv = argv, opts = opts }
        opts.on_done(ok, out, err or "")
        return { cancel = function() end }
      end,
    }
  end

  --- Force a fresh require of a provider module so it picks up the just-set
  --- `language.util.job` stub instead of a cached reference to the real one.
  ---@param name string
  ---@return table
  local function reload(name)
    package.loaded[name] = nil
    return require(name)
  end

  -- google.lua ------------------------------------------------------------
  -- available() checks the real `fn.executable("curl")` (not stubbed by
  -- `language.util.job`), so this asserts against the actual environment
  -- rather than assuming curl is installed.
  local curl_present = vim.fn.executable("curl") == 1

  stub_job(true, '[[["Bonjour","hello",null,null,1]],null,"en"]')
  local google = reload("language.translate.providers.google")
  H.eq(google.available({}), curl_present, "available() tracks whether curl is on PATH")

  local done, ok_r, result_r = false, nil, nil
  google.translate({ "hello" }, "FR", nil, { timeout_ms = 1000 }, function(ok2, result)
    done, ok_r, result_r = true, ok2, result
  end)
  H.ok(done, "translate() resolves via the stubbed job synchronously")
  H.ok(ok_r, "a well-formed gtx response is a success")
  H.eq(result_r[1], "Bonjour", "the first segment's translated text is extracted")
  H.eq(calls[1].argv[1], "curl", "curl is the argv[1]")
  H.contains(table.concat(calls[1].argv, " "), "tl=FR", "the target language is in the query")
  -- The text is a POST body on stdin (`--data-urlencode q@-`): not in the URL, so
  -- no percent-encoding budget, and not in argv, so no command-line limit.
  H.contains(
    table.concat(calls[1].argv, " "),
    "q@-",
    "curl url-encodes the body it reads from stdin"
  )
  H.eq(calls[1].opts.stdin, "hello", "the source text is the stdin of the request")
  H.excludes(table.concat(calls[1].argv, " "), "hello", "and not an argv element")
  H.excludes(table.concat(calls[1].argv, " "), " -G", "it is a POST, not a GET with a query")

  -- Embedded newlines (blank lines included) reach the endpoint untouched.
  google.translate({ "a", "", "b & c=d" }, "FR", nil, {}, function() end)
  H.eq(
    calls[#calls].opts.stdin,
    "a\n\nb & c=d",
    "lines are joined with newlines, nothing else changes"
  )

  -- Whitespace-only text has nothing to translate: no request, the lines come back as they are.
  local nc = #calls
  local blank_ok, blank_res
  google.translate({ "" }, "FR", nil, {}, function(ok_b, res_b)
    blank_ok, blank_res = ok_b, res_b
  end)
  H.ok(blank_ok, "a blank line is not an error")
  H.eq(#blank_res, 1, "one line in, one line out (not an empty list)")
  H.eq(blank_res[1], "", "unchanged")
  H.eq(#calls, nc, "without a request")

  H.eq(google.limits.max_bytes, 15000, "the budget is the raw body size")
  H.eq(google.limits.cost, nil, "plain bytes, no percent-encoding cost")

  stub_job(true, "not json at all")
  google = reload("language.translate.providers.google")
  local done2, ok2r, err2r = false, nil, nil
  google.translate({ "hi" }, "FR", nil, {}, function(ok3, result)
    done2, ok2r, err2r = true, ok3, result
  end)
  H.ok(done2, "resolves")
  H.falsy(ok2r, "malformed JSON is a failure")
  H.contains(err2r, "invalid translation response", "with a specific reason")

  stub_job(false, "", "curl: connection refused")
  google = reload("language.translate.providers.google")
  local done3, ok3r, err3r = false, nil, nil
  google.translate({ "hi" }, "FR", nil, {}, function(ok4, result)
    done3, ok3r, err3r = true, ok4, result
  end)
  H.ok(done3, "resolves")
  H.falsy(ok3r, "a job failure is passed through as a failure")
  H.eq(err3r, "curl: connection refused", "with the underlying error text, not relabelled")

  stub_job(true, "")
  google = reload("language.translate.providers.google")
  local empty_done, empty_ok, empty_result = false, nil, nil
  google.translate({}, "FR", nil, {}, function(ok5, result)
    empty_done, empty_ok, empty_result = true, ok5, result
  end)
  H.ok(empty_done, "empty input short-circuits without a job at all")
  H.ok(empty_ok, "trivially successful")
  H.eq(#empty_result, 0, "with an empty result")
  H.eq(#calls, 0, "and job.run was never called for empty input")

  -- deepl.lua ---------------------------------------------------------------
  stub_job(true, [[{"translations":[{"text":"Bonjour"}]}]])
  local deepl = reload("language.translate.providers.deepl")
  H.falsy(deepl.available({}), "no key configured (and no env var): unavailable")
  H.eq(
    deepl.available({ deepl = { api_key = "abc123" } }),
    curl_present,
    "a configured key makes it available iff curl also is"
  )

  local d_done, d_ok, d_result = false, nil, nil
  deepl.translate(
    { "hello" },
    "FR",
    nil,
    { deepl = { api_key = "abc123:fx" } },
    function(ok6, result)
      d_done, d_ok, d_result = true, ok6, result
    end
  )
  H.ok(d_done, "resolves")
  H.ok(d_ok, "a well-formed response is a success")
  H.eq(d_result[1], "Bonjour", "translations[1].text is extracted")
  H.contains(
    table.concat(calls[1].argv, " "),
    "api-free.deepl.com",
    "a ':fx' key hits the free host"
  )

  -- SEC-10: the auth key must never be an argv element (visible via the
  -- process list); it travels as a curl `-K -` config read from stdin.
  H.excludes(table.concat(calls[1].argv, " "), "abc123:fx", "the key is not in argv at all")
  H.contains(table.concat(calls[1].argv, " "), "-K -", "curl is told to read a config from stdin")
  H.contains(
    calls[1].opts.stdin,
    "Authorization: DeepL-Auth-Key abc123:fx",
    "the key travels as the stdin-piped curl config instead"
  )

  -- The JSON body travels on stdin too (a large body as one argv element hits
  -- the Windows command-line limit and shows the text in the process list).
  H.excludes(table.concat(calls[1].argv, " "), "hello", "the text is not in argv either")
  H.excludes(table.concat(calls[1].argv, " "), "-d", "no -d body argument")
  -- LUA-02: the quoting of that config is lib.nvim's one copy. A stand-in proves
  -- DeepL goes through it instead of carrying an escaper of its own.
  local real_curl = package.loaded["lib.nvim.net.curl"]
  package.loaded["lib.nvim.net.curl"] = {
    config_quote = function(value)
      return "<" .. value .. ">"
    end,
  }
  stub_job(true, [[{"translations":[{"text":"x"}]}]])
  local deepl_lib = reload("language.translate.providers.deepl")
  deepl_lib.translate({ "hi" }, "FR", nil, { deepl = { api_key = "k1" } }, function() end)
  H.contains(
    calls[1].opts.stdin,
    "header = <Authorization: DeepL-Auth-Key k1>",
    "the header is quoted by lib.nvim.net.curl.config_quote"
  )
  H.contains(calls[1].opts.stdin, "data = <{", "and so is the body")
  package.loaded["lib.nvim.net.curl"] = { config_quote = "not a function" }
  stub_job(true, "{}")
  deepl_lib = reload("language.translate.providers.deepl")
  local old_ok, old_err
  deepl_lib.translate({ "hi" }, "FR", nil, { deepl = { api_key = "k1" } }, function(ok_o, err_o)
    old_ok, old_err = ok_o, err_o
  end)
  H.falsy(old_ok, "an old lib.nvim without config_quote is a failure ...")
  H.contains(old_err, "lib.nvim", "... that says what to update")
  H.eq(#calls, 0, "and no request was made")
  package.loaded["lib.nvim.net.curl"] = real_curl
  stub_job(true, [[{"translations":[{"text":"Bonjour"}]}]])
  deepl = reload("language.translate.providers.deepl")
  deepl.translate({ "hello" }, "FR", nil, { deepl = { api_key = "abc123:fx" } }, function() end)

  H.contains(calls[1].opts.stdin, 'data = "{', "the body is a `data` line of the stdin config")
  H.contains(calls[1].opts.stdin, [=[\"text\":[\"hello\"]]=], "with the JSON quoted for curl")
  H.eq(
    #vim.split(calls[1].opts.stdin, "\n", { plain = true }),
    3,
    "two settings, then the final newline"
  )

  stub_job(true, [[{"translations":[{"text":"x"}]}]])
  deepl = reload("language.translate.providers.deepl")
  deepl.translate({ "hi" }, "FR", nil, { deepl = { api_key = "abc123" } }, function() end)
  H.contains(
    table.concat(calls[1].argv, " "),
    "api.deepl.com",
    "a non-':fx' key hits the paid host"
  )

  stub_job(true, [[{"message":"Quota exceeded"}]])
  deepl = reload("language.translate.providers.deepl")
  local q_done, q_ok, q_err = false, nil, nil
  deepl.translate({ "hi" }, "FR", nil, { deepl = { api_key = "abc123" } }, function(ok7, result)
    q_done, q_ok, q_err = true, ok7, result
  end)
  H.ok(q_done, "resolves")
  H.falsy(q_ok, "a {message=...} body is DeepL reporting an error, not a translation")
  H.contains(q_err, "Quota exceeded", "the message is surfaced")

  local nokey_done, nokey_ok, nokey_err = false, nil, nil
  deepl.translate({ "hi" }, "FR", nil, {}, function(ok8, result)
    nokey_done, nokey_ok, nokey_err = true, ok8, result
  end)
  H.ok(nokey_done, "no key at all: resolves without even calling job.run")
  H.falsy(nokey_ok, "as a failure")
  H.contains(nokey_err, "DEEPL_API_KEY", "naming the env var escape hatch")

  vim.env.DEEPL_API_KEY = "env-key"
  H.eq(
    deepl.available({}),
    curl_present,
    "DEEPL_API_KEY in the environment also makes it available (modulo curl)"
  )
  vim.env.DEEPL_API_KEY = nil

  -- shell.lua (translate-shell) ----------------------------------------------
  stub_job(true, "Bonjour le monde\n")
  local shell = reload("language.translate.providers.shell")
  local s_done, s_ok, s_result = false, nil, nil
  shell.translate({ "hello world" }, "FR", "EN", {}, function(ok9, result)
    s_done, s_ok, s_result = true, ok9, result
  end)
  H.ok(s_done, "resolves")
  H.ok(s_ok, "success")
  H.eq(s_result[1], "Bonjour le monde", "trailing whitespace is trimmed")
  H.contains(table.concat(calls[1].argv, " "), "EN:FR", "source:target spec is built correctly")

  stub_job(true, "x")
  shell = reload("language.translate.providers.shell")
  shell.translate({ "hi" }, "FR", nil, {}, function() end)
  H.contains(
    table.concat(calls[1].argv, " "),
    ":FR",
    "no source: spec starts empty, just ':target'"
  )

  local empty_s_done, empty_s_result = false, nil
  shell.translate({}, "FR", nil, {}, function(_, result)
    empty_s_done, empty_s_result = true, result
  end)
  H.ok(empty_s_done, "empty input short-circuits")
  H.eq(#empty_s_result, 0, "with nothing")

  local blank_calls = #calls
  local blank_s
  shell.translate({ "", "" }, "FR", nil, {}, function(_, result)
    blank_s = result
  end)
  H.eq(#blank_s, 2, "blank lines come back as the same number of lines")
  H.eq(#calls, blank_calls, "without starting trans")

  H.eq(
    shell.limits.max_bytes,
    vim.fn.has("win32") == 1 and 6000 or 20000,
    "the argv budget follows the platform (Windows: shim limit, elsewhere: 128 KiB per argument)"
  )

  -- custom.lua (translate) ---------------------------------------------------
  local custom = reload("language.translate.providers.custom")
  H.falsy(custom.available({}), "no custom.cmd configured: unavailable")
  H.ok(
    custom.available({ custom = { cmd = function() end } }),
    "a cmd function alone is enough to be 'available'"
  )

  stub_job(true, "OUT1\nOUT2")
  custom = reload("language.translate.providers.custom")
  local seen_cmd_args
  local c_done, c_ok, c_result = false, nil, nil
  custom.translate({ "a", "b" }, "FR", "EN", {
    custom = {
      cmd = function(lines, target, source)
        seen_cmd_args = { lines = lines, target = target, source = source }
        return { "my-translator", "--to", target }
      end,
    },
  }, function(ok10, result)
    c_done, c_ok, c_result = true, ok10, result
  end)
  H.ok(c_done, "resolves")
  H.ok(c_ok, "success")
  H.eq(seen_cmd_args.target, "FR", "cmd() receives the target language")
  H.eq(calls[1].argv[1], "my-translator", "cmd()'s argv is really what gets run")
  H.eq(c_result[1], "OUT1", "with no parse(), stdout is split into lines")
  H.eq(c_result[2], "OUT2", "both of them")

  stub_job(true, "raw output")
  custom = reload("language.translate.providers.custom")
  local p_done, p_result = false, nil
  custom.translate({ "a" }, "FR", nil, {
    custom = {
      cmd = function()
        return { "cmd" }
      end,
      parse = function(out)
        return { "parsed:" .. out }
      end,
    },
  }, function(_, result)
    p_done, p_result = true, result
  end)
  H.ok(p_done, "resolves")
  H.eq(p_result[1], "parsed:raw output", "a custom parse() is used when given")

  H.eq(
    custom.limits.max_bytes,
    vim.fn.has("win32") == 1 and 6000 or 20000,
    "custom starts at the same budget as shell"
  )
  H.eq(custom.limits.override({}), nil, "no custom config: no override")
  H.eq(
    custom.limits.override({ custom = { max_bytes = 90000 } }),
    90000,
    "translate.custom.max_bytes raises it for a cmd that does not use argv"
  )
  local chunk_mod = require("language.translate.chunk")
  H.eq(
    chunk_mod.limits_for(custom, { custom = { max_bytes = 90000 } }).max_bytes,
    90000,
    "limits_for honours the override"
  )
  H.eq(
    chunk_mod.limits_for(custom, { custom = { max_bytes = 90000 }, max_chars = 500 }).max_bytes,
    500,
    "while max_chars still wins when lower"
  )

  local bad_cmd_done, bad_cmd_ok, bad_cmd_err = false, nil, nil
  custom.translate({ "a" }, "FR", nil, { custom = { cmd = function() end } }, function(ok11, err)
    bad_cmd_done, bad_cmd_ok, bad_cmd_err = true, ok11, err
  end)
  H.ok(bad_cmd_done, "a cmd() returning nothing usable resolves immediately")
  H.falsy(bad_cmd_ok, "as a failure")
  H.contains(bad_cmd_err, "did not return an argv", "explaining why")

  -- registry.lua --------------------------------------------------------------
  local registry = reload("language.translate.providers.registry")
  H.ok(registry.get("google"), "known engines resolve by name")
  H.eq(registry.get("nonexistent"), nil, "an unknown name resolves to nil")

  local resolved, rerr = registry.resolve({
    engine = "custom",
    fallback = {},
    custom = { cmd = function() end },
  })
  H.eq(resolved, registry.get("custom"), "the configured engine wins when available")
  H.eq(rerr, nil, "with no error")

  local resolved2 = registry.resolve({
    engine = "nonexistent-engine",
    fallback = { "custom" },
    custom = { cmd = function() end },
  })
  H.eq(
    resolved2,
    registry.get("custom"),
    "an unavailable engine falls through to the fallback chain"
  )

  local resolved3, rerr3 = registry.resolve({ engine = "nonexistent-engine", fallback = {} })
  H.eq(resolved3, nil, "nothing available at all: nil")
  H.contains(rerr3, "nonexistent-engine", "the error names what was tried")
  H.contains(rerr3, "no available translate engine", "and why")

  package.loaded["language.util.job"] = nil
  package.loaded["language.translate.providers.google"] = nil
  package.loaded["language.translate.providers.deepl"] = nil
  package.loaded["language.translate.providers.shell"] = nil
  package.loaded["language.translate.providers.custom"] = nil
  package.loaded["language.translate.providers.registry"] = nil
end
