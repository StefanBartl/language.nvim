---@module 'language.util.job'
---@brief Cancellable, timed argv process runner (no shell interpolation).
---@description
--- Runs an external command from an argv list — never a shell string — so
--- arbitrary user text (translation payloads) cannot be shell-injected or
--- mis-quoted. Prefers `vim.system` (Neovim 0.10+) and falls back to
--- `jobstart` with a list command. Every job is cancellable and time-bounded;
--- this is the async foundation both domains build on.

local M = {}

---@class Language.Job
---@field cancel fun(): nil    -- kill the process and drop the callback

---Windows can't spawn `.cmd`/`.bat` shims (e.g. npm-installed `cspell`) directly
---via libuv — they must go through `cmd.exe /c`. Real executables (curl.exe …)
---are spawned unchanged. Returns the argv to actually spawn.
---@param argv string[]
---@return string[]
local function resolve_argv(argv)
  if vim.fn.has("win32") ~= 1 then
    return argv
  end
  local path = vim.fn.exepath(argv[1])
  if path == "" then
    return argv
  end
  -- Real executables (curl.exe, typos.exe, …) spawn directly. Anything else —
  -- npm shims (extensionless / .cmd / .bat / .ps1) — must go through cmd.exe,
  -- which resolves it via PATHEXT.
  local lower = path:lower()
  if lower:sub(-4) == ".exe" or lower:sub(-4) == ".com" then
    return argv
  end
  local out = { "cmd.exe", "/c", path }
  for i = 2, #argv do
    out[#out + 1] = argv[i]
  end
  return out
end

---Run `argv` and deliver the captured result to `on_done` exactly once.
---@param argv string[]                              command + arguments
---@param opts { timeout_ms?: integer, cwd?: string, on_done: fun(ok: boolean, out: string, err: string) }
---@return Language.Job
function M.run(argv, opts)
  opts = opts or {}
  argv = resolve_argv(argv)
  local on_done = opts.on_done or function() end
  local finished = false
  local timer

  ---@type Language.Job
  local job = { cancel = function() end }

  local function finish(ok, out, err)
    if finished then
      return
    end
    finished = true
    if timer then
      pcall(function()
        timer:stop()
        timer:close()
      end)
      timer = nil
    end
    vim.schedule(function()
      on_done(ok, out or "", err or "")
    end)
  end

  if vim.system then
    local proc = vim.system(argv, { text = true, cwd = opts.cwd }, function(o)
      finish(o.code == 0, o.stdout, o.stderr)
    end)
    job.cancel = function()
      if not finished then
        finished = true
        pcall(function()
          proc:kill("sigterm")
        end)
      end
    end
    if opts.timeout_ms and opts.timeout_ms > 0 then
      timer = vim.uv.new_timer()
      timer:start(opts.timeout_ms, 0, function()
        vim.schedule(function()
          if not finished then
            pcall(function()
              proc:kill("sigterm")
            end)
            finish(false, "", "timeout")
          end
        end)
      end)
    end
    return job
  end

  -- Legacy fallback: jobstart with a list command (no shell).
  local stdout, stderr = {}, {}
  local jid = vim.fn.jobstart(argv, {
    cwd = opts.cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code)
      finish(code == 0, table.concat(stdout, "\n"), table.concat(stderr, "\n"))
    end,
  })
  if jid <= 0 then
    finish(false, "", "jobstart failed")
    return job
  end
  job.cancel = function()
    if not finished then
      pcall(vim.fn.jobstop, jid)
    end
  end
  if opts.timeout_ms and opts.timeout_ms > 0 then
    timer = vim.uv.new_timer()
    timer:start(opts.timeout_ms, 0, function()
      vim.schedule(function()
        if not finished then
          pcall(vim.fn.jobstop, jid)
          finish(false, "", "timeout")
        end
      end)
    end)
  end
  return job
end

return M
