-- TESTS/markdown_helpers.lua -- shared by the translate_markdown_* specs (not a spec itself).
-- A fake engine, a synchronous wrapper around the async API and an independent
-- line classifier: the specs must not judge the segmenter with the segmenter.

local M = {}

---@param name string
---@return string[]
function M.fixture(name)
  local lines = vim.fn.readfile(vim.fn.getcwd() .. "/TESTS/fixtures/markdown/" .. name)
  return lines
end

---A fake provider. `fn(text, i) -> string|nil` translates one line (nil = drop
---the answer's line); `p.calls` records every request (the lines sent).
---@param fn fun(text: string, i: integer, call: integer): string|nil
---@param opts? { name?: string, delay_ms?: integer, sync?: boolean, on_request?: fun(lines: string[], cb: function, call: integer): table|nil }
function M.fake(fn, opts)
  opts = opts or {}
  local p = { name = opts.name or "fake", calls = {}, inflight = 0, max_inflight = 0 }
  p.available = function()
    return true
  end
  p.translate = function(lines, _target, _source, _cfg, cb)
    p.calls[#p.calls + 1] = vim.deepcopy(lines)
    local call = #p.calls
    if opts.on_request then
      return opts.on_request(lines, cb, call)
    end
    local out = {}
    for i, l in ipairs(lines) do
      out[#out + 1] = fn(l, i, call)
    end
    p.inflight = p.inflight + 1
    p.max_inflight = math.max(p.max_inflight, p.inflight)
    local function reply()
      p.inflight = p.inflight - 1
      cb(true, out)
    end
    if opts.sync then
      reply()
    elseif opts.delay_ms then
      vim.defer_fn(reply, opts.delay_ms)
    else
      vim.schedule(reply)
    end
    return { cancel = function() end }
  end
  return p
end

---Run translate_markdown and wait for the callback; checks it runs exactly once.
---@param lines string[]
---@param opts table
---@return { ok: boolean, res: any, info: table|nil, calls: integer, units: table[] }
function M.run(lines, opts)
  local md = require("language.translate.markdown")
  local r = { calls = 0, units = {} }
  -- No disk cache unless a spec asks for one: it would write to the real stdpath("cache").
  opts = vim.tbl_extend(
    "force",
    { target = "EN", cache = false, cfg = { markdown = { disk_cache = false } } },
    opts
  )
  local user_on_unit = opts.on_unit
  opts.on_unit = function(ev)
    r.units[#r.units + 1] = ev
    if user_on_unit then
      user_on_unit(ev)
    end
  end
  r.handle = md.translate_markdown(lines, opts, function(ok, res, info)
    r.calls = r.calls + 1
    r.ok, r.res, r.info = ok, res, info
  end)
  vim.wait(10000, function()
    return r.calls > 0
  end, 2)
  -- A second callback would arrive within a few loop turns.
  vim.wait(12, function()
    return r.calls > 1
  end, 2)
  return r
end

---Kind of every line, judged by simple regexes: independent of the segmenter.
---@param lines string[]
---@return string[]
function M.kinds(lines)
  local out = {}
  local fence, fm, in_table = nil, false, false
  for i, l in ipairs(lines) do
    if l:match("^[ \t]*$") then
      in_table = false
    end
    local k
    if i == 1 and (l == "---" or l == "+++") then
      fm = l
      k = "front"
    elseif fm then
      k = "front"
      if l == fm or (fm == "---" and l == "...") then
        fm = nil
      end
    elseif fence then
      k = "code"
      if l:match("^ *" .. fence:sub(1, 1) .. "+ *$") and #l:match("^ *(%S+)") >= #fence then
        fence = nil
      end
    elseif l:match("^ *```") or l:match("^ *~~~") then
      fence = l:match("^ *(```+)") or l:match("^ *(~~~+)")
      k = "code"
    elseif l:match("^[ \t]*$") then
      k = "blank"
    elseif l:match("^ *#+ ") or l:match("^ *#+$") then
      k = "heading"
    elseif l:match("^ *>") then
      k = "quote"
    elseif l:match("^ *[-*+] ") or l:match("^ *%d+[.)] ") then
      k = "item"
    elseif
      l:match("^ *|")
      or (in_table and l:find("|", 1, true))
      or (l:find("|", 1, true) and (lines[i + 1] or ""):match("^[ |:-]*%-[ |:-]*$"))
    then
      k = "table"
      in_table = true
    elseif l:match("^ *<") then
      k = "html"
    elseif l:match("^ *%-%-%-+ *$") or l:match("^ *===+ *$") then
      k = "rule"
    elseif l:match("^ *%[[^%]]+%]:") then
      k = "def"
    else
      k = "text"
    end
    out[i] = k
  end
  return out
end

---Indices of the lines that sit inside (or on the border of) a fenced block.
---@param lines string[]
---@return table<integer, boolean>
function M.fence_set(lines)
  local set, fence = {}, nil
  for i, l in ipairs(lines) do
    if fence then
      set[i] = true
      if l:match("^ *" .. fence:sub(1, 1) .. "+ *$") and #l:match("^ *(%S+)") >= #fence then
        fence = nil
      end
    elseif l:match("^ *```") or l:match("^ *~~~") then
      fence = l:match("^ *(```+)") or l:match("^ *(~~~+)")
      set[i] = true
    end
  end
  return set
end

---Multiset of the inline-code spans and link/image targets of `lines`.
---@param lines string[]
---@return table<string, integer>
function M.protected(lines)
  local counts = {}
  local fences = M.fence_set(lines)
  for i, l in ipairs(lines) do
    if not fences[i] then
      for span in l:gmatch("`[^`]+`") do
        counts[span] = (counts[span] or 0) + 1
      end
      for dest in l:gmatch("%]%(([^)]*)%)") do
        if not dest:match("^#") then
          counts[dest] = (counts[dest] or 0) + 1
        end
      end
    end
  end
  return counts
end

return M
