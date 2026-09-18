-- TESTS/spell_providers_cspell_server_spec.lua — language.spell.providers.
-- cspell_server: the persistent Node/cspell-lib sidecar client.
--
-- TESTS/README.md previously excluded this module outright, reasoning it
-- "needs a real Node install and a global cspell package present". True for
-- M.available() and for actually running node/cspell-lib -- but the module
-- itself never shells out directly except through two already-stubbable
-- seams: `language.util.job` for the one-shot `npm root -g` lookup (the same
-- seam spell_providers_cli_spec.lua already stubs for the other providers),
-- and `vim.fn.jobstart`/`chansend`/`jobstop` for the persistent process
-- (plain Neovim globals, monkeypatchable directly like `vim.fn.executable`
-- elsewhere in this suite). Every real external dependency this module has
-- is stubbed below; nothing here spawns node or talks to a real cspell-lib.
--
-- `state` (module-level) persists across calls, so each scenario that needs
-- a clean slate reloads the module fresh -- same technique
-- TESTS/hover_spec.lua and TESTS/translate_init_spec.lua use for their own
-- module-level state.

return function(H)
  -- The VimLeavePre kill-on-exit autocmd is registered directly in the
  -- module body (not inside a function), so it has to be captured via a
  -- stub in place *before* the (fresh) require -- same ordering constraint
  -- TESTS/health_spec.lua documents for vim.health.*.
  local autocmd_cb
  package.loaded["lib.nvim.bindings.autocmd"] = {
    create = function(event, cb)
      if event == "VimLeavePre" then
        autocmd_cb = cb
      end
    end,
  }

  local function reload()
    package.loaded["language.spell.providers.cspell_server"] = nil
    return require("language.spell.providers.cspell_server")
  end

  local cspell_server = reload()

  local orig_executable = vim.fn.executable
  local orig_jobstart = vim.fn.jobstart
  local orig_chansend = vim.fn.chansend
  local orig_jobstop = vim.fn.jobstop

  ---@param present table<string, boolean>
  local function stub_executable(present)
    vim.fn.executable = function(bin)
      if present[bin] ~= nil then
        return present[bin] and 1 or 0
      end
      return orig_executable(bin)
    end
  end

  -- available(): node + cspell + not-failed ----------------------------------
  stub_executable({ node = true, cspell = true })
  H.ok(cspell_server.available(), "node and cspell both present, sidecar never failed: available")
  stub_executable({ node = false, cspell = true })
  H.falsy(cspell_server.available(), "no node: not available")
  stub_executable({ node = true, cspell = false })
  H.falsy(cspell_server.available(), "no cspell: not available")
  stub_executable({ node = true, cspell = true })

  local buf = vim.api.nvim_create_buf(false, true)

  -- The happy path: resolve() finds the nested (npm-global) candidate,
  -- ensure_started() spawns the sidecar, the {"ready":true} line unblocks
  -- the pending check(), the request is sent, and a matching reply comes
  -- back tagged as this provider's own issue. -----------------------------
  local root, cleanup_root = H.fixture("cspell-server-root")
  vim.fn.mkdir(root .. "/cspell/node_modules/cspell-lib/dist", "p")
  vim.fn.writefile({ "" }, root .. "/cspell/node_modules/cspell-lib/dist/index.js")

  package.loaded["language.util.job"] = {
    run = function(argv, opts)
      H.eq(table.concat(argv, " "), "npm root -g", "resolve() asks npm for the global root")
      opts.on_done(true, root .. "\n")
    end,
  }

  local captured_opts
  vim.fn.jobstart = function(argv, opts)
    H.eq(argv[1], "node", "the sidecar is spawned with node")
    H.contains(argv[2], "cspell_server.js", "running this repo's own sidecar script")
    H.eq(
      argv[3],
      root .. "/cspell/node_modules/cspell-lib/dist/index.js",
      "pointed at the resolved cspell-lib entry"
    )
    H.eq(
      opts.cwd,
      root .. "/cspell/node_modules",
      "cwd is three levels up from the entry file, where cspell-lib's dicts resolve"
    )
    captured_opts = opts
    return 4242
  end

  local sent = {}
  vim.fn.chansend = function(jid, data)
    sent[#sent + 1] = { jid = jid, data = data }
  end

  local got_issues
  cspell_server.check({ bufnr = buf }, {}, function(issues)
    got_issues = issues
  end)
  H.falsy(got_issues, "check() has not resolved yet -- still waiting on the sidecar's ready line")
  H.eq(#sent, 0, "and nothing was sent to it yet either")

  captured_opts.on_stdout(4242, { vim.json.encode({ ready = true }) .. "\n" })
  H.eq(#sent, 1, "the ready line unblocks the queued request")
  H.eq(sent[1].jid, 4242, "sent to the sidecar's own job id")
  local req = vim.json.decode(vim.trim(sent[1].data))
  H.eq(req.suggestions, true, "suggestions are requested")
  H.ok(type(req.id) == "number", "the request carries an id to match the reply by")

  captured_opts.on_stdout(4242, {
    vim.json.encode({ id = req.id, issues = { { word = "foo", lnum = 0 } } }) .. "\n",
  })
  H.ok(got_issues ~= nil, "the matching reply resolves check()'s callback")
  ---@cast got_issues -nil
  H.eq(#got_issues, 1, "one issue came back")
  H.eq(got_issues[1].word, "foo", "the word survives the round trip")
  H.eq(got_issues[1].bufnr, buf, "tagged with the checked buffer")
  H.eq(got_issues[1].kind, "spell", "tagged as a spell issue")
  H.eq(
    got_issues[1].source,
    "cspell",
    "tagged with this provider's name, not the raw sidecar's own"
  )

  -- A line split across two stdout chunks is still one dispatch, not two --
  -- exercises on_stdout's own buffering, separately from handle_line.
  sent = {}
  local got_split
  cspell_server.check({ bufnr = buf }, {}, function(issues)
    got_split = issues
  end)
  local id_split = vim.json.decode(vim.trim(sent[1].data)).id
  local whole = vim.json.encode({ id = id_split, issues = { { word = "split" } } })
  local cut = math.floor(#whole / 2)
  captured_opts.on_stdout(4242, { whole:sub(1, cut) })
  H.falsy(got_split, "half a line is not enough to dispatch anything yet")
  captured_opts.on_stdout(4242, { whole:sub(cut + 1) .. "\n" })
  H.ok(got_split ~= nil, "the second chunk completes the line and dispatches it")
  ---@cast got_split -nil
  H.eq(got_split[1].word, "split", "reassembled correctly across the chunk boundary")

  -- The VimLeavePre handler kills the sidecar's real job id -----------------
  H.ok(autocmd_cb ~= nil, "the kill-on-exit autocmd was registered at module load")
  local jobstop_calls = {}
  vim.fn.jobstop = function(jid)
    jobstop_calls[#jobstop_calls + 1] = jid
  end
  autocmd_cb()
  H.eq(#jobstop_calls, 1, "VimLeavePre stops exactly the sidecar's own job")
  H.eq(jobstop_calls[1], 4242, "not some other id")

  -- cancel() before a reply arrives drops it silently ------------------------
  sent = {}
  local got_cancelled
  local handle = cspell_server.check({ bufnr = buf }, {}, function(issues)
    got_cancelled = issues
  end)
  local id_cancelled = vim.json.decode(vim.trim(sent[1].data)).id
  handle.cancel()
  captured_opts.on_stdout(4242, {
    vim.json.encode({ id = id_cancelled, issues = { { word = "late" } } }) .. "\n",
  })
  H.falsy(
    got_cancelled,
    "a cancelled request's callback never fires, even if the sidecar still answers"
  )

  -- on_exit() drops every request still pending, with an empty result -------
  sent = {}
  local got_on_exit
  cspell_server.check({ bufnr = buf }, {}, function(issues)
    got_on_exit = issues
  end)
  H.eq(#sent, 1, "the request went out before the sidecar exited")
  captured_opts.on_exit()
  H.ok(got_on_exit ~= nil, "on_exit still calls back rather than leaving the caller hanging")
  ---@cast got_on_exit -nil
  H.eq(#got_on_exit, 0, "...with nothing to report, since the sidecar never actually replied")

  cleanup_root()

  -- resolve(): the hoisted candidate, when the nested one is absent ---------
  local root2, cleanup_root2 = H.fixture("cspell-server-root2")
  vim.fn.mkdir(root2 .. "/cspell-lib/dist", "p")
  vim.fn.writefile({ "" }, root2 .. "/cspell-lib/dist/index.js")

  package.loaded["language.util.job"] = {
    run = function(_, opts)
      opts.on_done(true, root2 .. "\n")
    end,
  }
  local jobstart_argv
  cspell_server = reload()
  vim.fn.jobstart = function(argv)
    jobstart_argv = argv
    return 99
  end
  cspell_server.check({ bufnr = buf }, {}, function() end)
  H.ok(
    jobstart_argv ~= nil,
    "resolution succeeded via the hoisted candidate, so the sidecar was spawned"
  )
  ---@cast jobstart_argv -nil
  H.eq(
    jobstart_argv[3],
    root2 .. "/cspell-lib/dist/index.js",
    "the hoisted layout is used when the nested npm-global one does not exist"
  )
  cleanup_root2()

  -- resolve(): neither candidate exists -- fails closed, does not hang ------
  local root3, cleanup_root3 = H.fixture("cspell-server-root3")
  package.loaded["language.util.job"] = {
    run = function(_, opts)
      opts.on_done(true, root3 .. "\n")
    end,
  }
  cspell_server = reload()
  local got_unresolved
  cspell_server.check({ bufnr = buf }, {}, function(issues)
    got_unresolved = issues
  end)
  H.ok(
    got_unresolved ~= nil,
    "an unresolved cspell-lib still calls back rather than hanging forever"
  )
  ---@cast got_unresolved -nil
  H.eq(#got_unresolved, 0, "...with nothing to report")
  stub_executable({ node = true, cspell = true })
  H.falsy(cspell_server.available(), "and available() now reports failed, so callers stop retrying")
  cleanup_root3()

  -- ensure_started(): jobstart itself fails (jid <= 0) -----------------------
  local root4, cleanup_root4 = H.fixture("cspell-server-root4")
  vim.fn.mkdir(root4 .. "/cspell-lib/dist", "p")
  vim.fn.writefile({ "" }, root4 .. "/cspell-lib/dist/index.js")
  package.loaded["language.util.job"] = {
    run = function(_, opts)
      opts.on_done(true, root4 .. "\n")
    end,
  }
  cspell_server = reload()
  vim.fn.jobstart = function()
    return 0
  end
  local got_jobstart_fail
  cspell_server.check({ bufnr = buf }, {}, function(issues)
    got_jobstart_fail = issues
  end)
  H.ok(got_jobstart_fail ~= nil, "a jobstart failure still calls back rather than hanging")
  ---@cast got_jobstart_fail -nil
  H.eq(#got_jobstart_fail, 0, "...with nothing to report")
  stub_executable({ node = true, cspell = true })
  H.falsy(cspell_server.available(), "and is recorded as failed too")
  cleanup_root4()

  -- Teardown ------------------------------------------------------------------
  vim.fn.executable = orig_executable
  vim.fn.jobstart = orig_jobstart
  vim.fn.chansend = orig_chansend
  vim.fn.jobstop = orig_jobstop
  vim.api.nvim_buf_delete(buf, { force = true })
  package.loaded["language.util.job"] = nil
  package.loaded["lib.nvim.bindings.autocmd"] = nil
  package.loaded["language.spell.providers.cspell_server"] = nil
end
