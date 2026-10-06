---@module 'language.translate.chunk'
---@brief Splits large translate inputs into provider-sized, line-aligned blocks.
---@description
--- Every translate provider hands its payload to an external process. A single
--- oversized argv element makes the spawn fail (Windows: ENAMETOOLONG at about
--- 32 700 characters for the whole command line), and the remote engines have
--- request limits of their own (gtx: URL length, DeepL: 50 texts and a request
--- size). This module is the one place that handles it: `wrap` returns a
--- provider with the same `name`/`available`/`translate` signature whose
--- `translate` cuts the input into blocks on line boundaries (preferring blank
--- lines), runs them one after the other through the wrapped provider and
--- joins the results again, so the line count of each block -- and with it the
--- indent restoration in `translate/indent.lua` -- is untouched.
---
--- A provider declares its budget with an optional `limits` field
--- (`LanguageTranslateLimits`). `translate.max_chars` can only lower it.
--- A failed block fails the whole call, and `cb` still runs exactly once.

require("language.translate.@types")

local M = {}

---@class LanguageTranslateLimits
---@field max_bytes integer                     -- budget per block, in `cost` units (bytes by default)
---@field max_lines? integer                    -- most lines per block (DeepL: 50 texts per request)
---@field cost? fun(line: string): integer      -- cost of one line incl. its separator; default `#line + 1`

---@internal
---@param line string
---@return integer
local function default_cost(line)
  return #line + 1
end

---Effective limits: the provider's own budget, lowered by `cfg.max_chars`.
---@param provider LanguageTranslateProvider
---@param cfg LanguageTranslateCfg|table
---@return LanguageTranslateLimits|nil
function M.limits_for(provider, cfg)
  local base = provider.limits
  if type(base) ~= "table" then
    return nil
  end
  local max_bytes = base.max_bytes
  local user = cfg and cfg.max_chars
  if type(user) == "number" and user > 0 and user < max_bytes then
    max_bytes = math.floor(user)
  end
  return { max_bytes = max_bytes, max_lines = base.max_lines, cost = base.cost }
end

---@internal
---Cut `lines[first .. last]` where a block would overflow: back at the last
---blank line when that keeps at least half of the block, else right here.
---@param lines string[]
---@param first integer   -- first line of the block being closed
---@param last integer    -- last line that still fits
---@return integer end_line
local function pick_cut(lines, first, last)
  local floor = first + math.floor((last - first + 1) / 2) - 1
  for i = last, floor + 1, -1 do
    if lines[i] == "" or lines[i]:match("^%s*$") then
      return i
    end
  end
  return last
end

---Split `lines` into blocks that respect `limits`.
---@param lines string[]
---@param limits LanguageTranslateLimits
---@return { first: integer, last: integer }[]|nil blocks, string|nil err
function M.split(lines, limits)
  local cost = limits.cost or default_cost
  local max_bytes, max_lines = limits.max_bytes, limits.max_lines
  ---@type { first: integer, last: integer }[]
  local blocks = {}
  local first, used = 1, 0
  local i = 1
  while i <= #lines do
    local c = cost(lines[i])
    if c > max_bytes then
      return nil,
        ("line %d is too long to translate (%d, limit %d); it cannot be split without changing the line layout"):format(
          i,
          c,
          max_bytes
        )
    end
    local count = i - first
    if used + c > max_bytes or (max_lines and count >= max_lines) then
      local cut = pick_cut(lines, first, i - 1)
      blocks[#blocks + 1] = { first = first, last = cut }
      first, used, i = cut + 1, 0, cut + 1
    else
      used = used + c
      i = i + 1
    end
  end
  if first <= #lines then
    blocks[#blocks + 1] = { first = first, last = #lines }
  end
  return blocks, nil
end

---Wrap `provider` so oversized inputs are translated block by block. The
---provider's own `translate` is called unchanged for each block; an input that
---fits in one block goes straight through.
---@param provider LanguageTranslateProvider
---@return LanguageTranslateProvider
function M.wrap(provider)
  if type(provider.limits) ~= "table" then
    return provider
  end
  local inner = provider.translate
  local wrapped = vim.tbl_extend("force", {}, provider)

  ---@type LanguageTranslateFn
  wrapped.translate = function(lines, target, source, cfg, cb)
    local limits = M.limits_for(provider, cfg)
    if not limits or #lines == 0 then
      return inner(lines, target, source, cfg, cb)
    end
    local blocks, err = M.split(lines, limits)
    if not blocks then
      cb(false, ("%s: %s"):format(provider.name, err or "input too large"))
      return nil
    end
    if #blocks <= 1 then
      return inner(lines, target, source, cfg, cb)
    end

    local cancelled, settled = false, false
    local current, active = 0, nil
    ---@type string[]
    local out = {}

    ---@param ok boolean
    ---@param result string[]|string
    local function settle(ok, result)
      if settled or cancelled then
        return
      end
      settled = true
      cb(ok, result)
    end

    local step
    step = function(n)
      if cancelled or settled then
        return
      end
      if n > #blocks then
        settle(true, out)
        return
      end
      current = n
      local b = blocks[n]
      local sub = vim.list_slice(lines, b.first, b.last)
      local started, job = pcall(inner, sub, target, source, cfg, function(ok, result)
        if cancelled or settled then
          return
        end
        if not ok then
          settle(
            false,
            ("block %d/%d (lines %d-%d): %s"):format(n, #blocks, b.first, b.last, tostring(result))
          )
          return
        end
        if type(result) ~= "table" then
          settle(false, ("block %d/%d returned no lines"):format(n, #blocks))
          return
        end
        vim.list_extend(out, result)
        step(n + 1)
      end)
      if not started then
        settle(false, ("block %d/%d: %s"):format(n, #blocks, tostring(job)))
        return
      end
      -- A synchronous callback has already moved on to the next block.
      if current == n then
        active = job
      end
    end

    step(1)

    return {
      cancel = function()
        cancelled = true
        if active and type(active.cancel) == "function" then
          pcall(active.cancel)
        end
      end,
    }
  end

  return wrapped
end

return M
