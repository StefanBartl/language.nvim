-- TESTS/job_spec.lua — language.util.job: the cancellable, timed argv process
-- runner every provider builds on.
--
-- Real short-lived processes rather than mocked jobstart/vim.system — this is
-- infrastructure whose only job is to shell out correctly (argv, not a shell
-- string; timeout; cancel), so a mock of the thing it wraps would test the
-- mock, not the module. `vim.v.progpath` (the running Neovim itself) is used
-- as the subprocess: guaranteed present on every platform this suite runs on.

return function(H)
  local job = require("language.util.job")

  -- A real process, run to completion ----------------------------------------
  local done, ok_result, out_result = false, nil, nil
  job.run({ vim.v.progpath, "--version" }, {
    on_done = function(ok, out, _err)
      done, ok_result, out_result = true, ok, out
    end,
  })
  vim.wait(5000, function()
    return done
  end)
  H.ok(done, "a real subprocess reports back")
  H.ok(ok_result, "and exits successfully")
  H.contains(out_result, "NVIM", "stdout is really captured")

  -- on_done fires exactly once even if called defensively twice — guards
  -- against a double on_exit/on_stdout race some job backends can produce.
  local calls = 0
  local done2 = false
  job.run({ vim.v.progpath, "--version" }, {
    on_done = function()
      calls = calls + 1
      done2 = true
    end,
  })
  vim.wait(5000, function()
    return done2
  end)
  H.eq(calls, 1, "on_done fires exactly once")

  -- BUG: a missing executable does not report back through on_done at all --
  -- it raises synchronously instead. `M.run` calls `vim.system(argv, ...)`
  -- unguarded; on this build, spawning a nonexistent binary makes `vim.system`
  -- itself throw ENOENT before it ever returns, so the error propagates to
  -- whatever called `job.run` rather than reaching `on_done(false, ...)` the
  -- way every other failure in this module does (the legacy `jobstart`
  -- fallback below it, by contrast, already guards this exact case: `if jid
  -- <= 0 then finish(false, "", "jobstart failed") end`). Any caller of
  -- `job.run` that does not itself pcall the call — collect.lua, every spell/
  -- translate CLI provider — can be crashed by a typo'd or uninstalled binary
  -- name instead of getting the graceful `ok=false` failure they coded for.
  -- Pinned here rather than fixed: the fix (wrap the `vim.system(...)` call in
  -- the same `pcall` pattern already used for `proc:kill`/`timer:stop` a few
  -- lines below it) is a real source change, not a test one.
  local raised = not pcall(function()
    job.run({ "zzqqxx-nonexistent-executable-language-nvim" }, {
      on_done = function() end,
    })
  end)
  H.ok(raised, "a nonexistent executable raises instead of failing through on_done")

  -- cancel() before completion prevents on_done from ever firing later on a
  -- process that would otherwise still be running.
  local cancelled_done = false
  local slow = job.run(
    { vim.v.progpath, "--headless", "-u", "NONE", "-c", "sleep 3", "-c", "qa!" },
    {
      timeout_ms = 10000,
      on_done = function()
        cancelled_done = true
      end,
    }
  )
  slow.cancel()
  vim.wait(500) -- give the kill a moment; on_done must not have fired by cancel() itself
  H.falsy(cancelled_done, "cancel() does not itself invoke on_done")

  -- The timeout guard: a process that runs long is killed and reported as a
  -- timeout failure rather than left to hang the caller forever.
  local timeout_done, timeout_ok, timeout_err = false, nil, nil
  job.run({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "sleep 5", "-c", "qa!" }, {
    timeout_ms = 200,
    on_done = function(ok, _out, err)
      timeout_done, timeout_ok, timeout_err = true, ok, err
    end,
  })
  vim.wait(5000, function()
    return timeout_done
  end)
  H.ok(timeout_done, "a slow process is eventually reported")
  H.falsy(timeout_ok, "as a failure")
  H.eq(timeout_err, "timeout", "labelled as a timeout specifically")
end
