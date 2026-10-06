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

  -- A missing executable (or any other spawn failure) makes `vim.system`
  -- throw; `job.run` catches it and reports it through `on_done(false, ...)`,
  -- like every other failure, so no caller can be crashed -- or a progress
  -- display left hanging -- by a typo'd binary name or an oversized argv.
  local missing_done, missing_calls, missing_ok, missing_err = false, 0, nil, nil
  local raised = not pcall(function()
    job.run({ "zzqqxx-nonexistent-executable-language-nvim" }, {
      on_done = function(ok, _out, err)
        missing_done, missing_ok, missing_err = true, ok, err
        missing_calls = missing_calls + 1
      end,
    })
  end)
  vim.wait(2000, function()
    return missing_done
  end)
  H.falsy(raised, "a nonexistent executable no longer raises out of job.run")
  H.ok(missing_done, "it is reported through on_done instead")
  H.falsy(missing_ok, "as a failure")
  H.contains(missing_err, "spawn failed", "with a spawn-failure message")
  vim.wait(100)
  H.eq(missing_calls, 1, "exactly once")

  -- Any spawn error (ENAMETOOLONG on an oversized command line, ...) takes the
  -- same path, simulated so it also runs on platforms where the OS accepts it.
  local real_system = vim.system
  vim.system = function()
    error("vim/_core/system.lua:326: ENAMETOOLONG")
  end
  local long_done, long_ok, long_err, long_calls = false, nil, nil, 0
  local long_raised = not pcall(function()
    job.run({ "curl", string.rep("a", 40000) }, {
      on_done = function(ok, _out, err)
        long_done, long_ok, long_err, long_calls = true, ok, err, long_calls + 1
      end,
    })
  end)
  vim.system = real_system
  vim.wait(2000, function()
    return long_done
  end)
  H.falsy(long_raised, "a throwing vim.system does not escape job.run")
  H.falsy(long_ok, "it is a failure")
  H.contains(long_err, "ENAMETOOLONG", "carrying the underlying error")
  vim.wait(100)
  H.eq(long_calls, 1, "reported exactly once")

  -- Windows launchers that are not real executables (.cmd/.bat shims, npm shims,
  -- extensionless scripts) go through `cmd.exe /c`. libuv escapes an embedded
  -- quote as \" which cmd.exe does not understand, and `%VAR%` expands even in
  -- quotes, so text like `x" & calc & "y` would run as a command: such an
  -- argument is refused instead. (The platform is injected so this runs everywhere.)
  local win_shim = {
    win32 = true,
    exepath = function()
      return [[C:\tools\trans.cmd]]
    end,
  }
  local win_exe = {
    win32 = true,
    exepath = function()
      return [[C:\tools\trans.exe]]
    end,
  }
  local linux = {
    win32 = false,
    exepath = function()
      return "/usr/bin/trans"
    end,
  }

  local safe = job._resolve_argv({ "trans", "-b", ":de", "hello world" }, win_shim)
  H.eq(
    table.concat(safe, "|"),
    [[cmd.exe|/c|C:\tools\trans.cmd|-b|:de|hello world]],
    "a plain argument goes through the shim as before"
  )
  for _, evil in ipairs({
    'x" & echo pwned>injected.flag & "y',
    "100%",
    "user is %USERNAME%",
    "a & b",
    "a | b",
    "a > b",
    "a < b",
    "a ^ b",
    "line one\nline two",
    "line one\rline two",
  }) do
    local out, why = job._resolve_argv({ "trans", "-b", ":de", evil }, win_shim)
    H.eq(out, nil, ("an argument that cmd.exe would interpret is refused: %q"):format(evil))
    H.contains(why, "argument 4", "the message names the argument")
    H.contains(why, "trans", "and the command")
  end
  H.ok(
    job._resolve_argv({ "trans", "-b", ":de", 'x" & y' }, win_exe),
    "a real .exe is spawned directly: libuv's quoting is enough there"
  )
  H.eq(
    job._resolve_argv({ "trans", 'x" & y' }, linux)[2],
    'x" & y',
    "and no other platform goes through cmd.exe at all"
  )

  -- end to end through job.run: refused through on_done, nothing is spawned
  local real_has, real_exepath, real_sys = vim.fn.has, vim.fn.exepath, vim.system
  local spawned = false
  vim.fn.has = function(what)
    if what == "win32" then
      return 1
    end
    return real_has(what)
  end
  vim.fn.exepath = function()
    return [[C:\tools\trans.cmd]]
  end
  vim.system = function()
    spawned = true
    error("must not be spawned")
  end
  local refuse_done, refuse_ok, refuse_err, refuse_calls = false, nil, nil, 0
  job.run({ "trans", "-b", ":de", 'x" & echo pwned>injected.flag & "y' }, {
    on_done = function(ok, _out, err)
      refuse_done, refuse_ok, refuse_err, refuse_calls = true, ok, err, refuse_calls + 1
    end,
  })
  vim.fn.has, vim.fn.exepath, vim.system = real_has, real_exepath, real_sys
  vim.wait(2000, function()
    return refuse_done
  end)
  H.ok(refuse_done, "a refused command is still reported through on_done")
  H.falsy(refuse_ok, "as a failure")
  H.contains(refuse_err, "refusing", "saying so")
  H.falsy(spawned, "without spawning anything")
  vim.wait(100)
  H.eq(refuse_calls, 1, "exactly once")

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

  -- `opts.stdin` (SEC-10: lets a caller hand a secret to a subprocess without
  -- it ever being an argv element) really reaches the process, on both the
  -- `vim.system` path and the legacy `jobstart` fallback. `nvim -` reads its
  -- first buffer from stdin; writing it back out proves the bytes arrived.
  local dir, cleanup = H.fixture("job-stdin")
  local function read_stdin_via(runner)
    local out_file = dir .. "/out.txt"
    vim.fn.delete(out_file)
    local stdin_done, stdin_ok = false, nil
    runner({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-",
      "-c",
      "silent write " .. out_file,
      "-c",
      "qa!",
    }, {
      stdin = "stdin-marker-xyz\n",
      timeout_ms = 5000,
      on_done = function(ok)
        stdin_done, stdin_ok = true, ok
      end,
    })
    vim.wait(5000, function()
      return stdin_done
    end)
    H.ok(stdin_done, "the process completes")
    H.ok(stdin_ok, "and exits successfully")
    H.contains(H.read(out_file), "stdin-marker-xyz", "the piped stdin content reached the process")
  end

  read_stdin_via(job.run)

  local orig_vim_system = vim.system
  vim.system = nil -- force the legacy jobstart fallback for this one call
  read_stdin_via(job.run)
  vim.system = orig_vim_system

  cleanup()
end
