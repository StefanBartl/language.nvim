---@module 'language.translate.markdown.slice'
---@brief Cooperative time slicing of a long synchronous computation.
---@description
--- `translate_markdown` segments, masks, validates and renders in plain Lua; on a big document that is
--- seconds of CPU work in one go, with the event loop (redraws, keys, timers) blocked. A slicer runs
--- such a computation as a coroutine: the code calls `tick()` at points where it may be interrupted
--- (a line, a unit, an entry: always a spot where all state sits in locals or tables), `tick` gives
--- the control back once the current slice has used its budget, and the driver continues the work in
--- a zero-delay timer callback. The computation itself does not change: the same statements run in
--- the same order, only with gaps in between.
---
--- The contract of a slicer:
---   * Nothing changes while the work finishes inside its first slice: no timer, no extra turn of
---     the event loop, `run(body)` returns after `body` did.
---   * Before every slice, the first one included, `stop()` is asked. A `true` abandons the
---     computation: it is never started or resumed (the caller reported "stale" or "cancelled" from
---     `stop`).
---   * An error of `body` goes to `on_error`, whichever slice it came from.
---   * `tick` outside of a coroutine of this slicer is a no-op, so code shared with the
---     asynchronous paths (an answer of the engine arrives in a plain callback) can call it freely.
---   * Runs nest (a finalisation started from inside the setup of the same slicer): the inner one
---     shares the slice (and its deadline) of the outer one.

local M = {}

local uv = vim.uv or vim.loop

---Default length of a slice in milliseconds. A frame is 16 ms, a keystroke latency of 50 ms is
---still not noticed: 8 ms leaves room for the redraw in between.
M.BUDGET_MS = 8

---@class LanguageMdSlicerOpts
---@field budget_ms? number              -- length of a slice (default `M.BUDGET_MS`); `0` yields at every tick; `math.huge` never yields and never reads the clock
---@field stop fun(): boolean            -- asked before each resume; `true` abandons the computation
---@field on_error fun(err: any)         -- `body` threw

---@class LanguageMdSlicer
---@field tick fun()                      -- an interruption point
---@field run fun(body: fun())            -- start a computation
---@field yields fun(): integer           -- how often a computation gave the control away so far

---@param opts LanguageMdSlicerOpts
---@return LanguageMdSlicer
function M.new(opts)
  local budget = (opts.budget_ms or M.BUDGET_MS) * 1e6
  ---@type table<thread, boolean>
  local live = setmetatable({}, { __mode = "k" })
  local deadline = 0
  local depth = 0
  local yields = 0

  local function tick()
    local co = coroutine.running()
    if co and live[co] and uv.hrtime() >= deadline then
      yields = yields + 1
      coroutine.yield()
    end
  end

  -- An unlimited budget (a small document) never yields: the clock is not read at all, neither at
  -- an interruption point nor when a slice starts.
  local unlimited = budget == math.huge
  if unlimited then
    tick = function() end
  end

  local function run(body)
    local co = coroutine.create(body)
    live[co] = true
    local function step()
      if opts.stop() then
        live[co] = nil
        return
      end
      if depth == 0 and not unlimited then
        deadline = uv.hrtime() + budget
      end
      depth = depth + 1
      local ok, err = coroutine.resume(co)
      depth = depth - 1
      if not ok then
        live[co] = nil
        opts.on_error(err)
      elseif coroutine.status(co) == "suspended" then
        -- Not `vim.schedule`: Neovim drains its main-loop queue until it is empty, so a callback
        -- that schedules its successor never lets libuv (timers, input, the redraw) run in
        -- between. A zero timeout goes through the libuv loop once per slice.
        vim.defer_fn(step, 0)
      else
        live[co] = nil
      end
    end
    step()
  end

  return {
    tick = tick,
    run = run,
    yields = function()
      return yields
    end,
  }
end

return M
