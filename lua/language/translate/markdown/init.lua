---@module 'language.translate.markdown'
---@brief `translate_markdown(lines, opts, cb)`: a Markdown-safe, line-true translation.
---@description
--- Translates a whole Markdown document through the configured engine and
--- returns exactly as many lines as it got: `#out == #in`, always.
---
---   segment   cut into literal lines (front matter, fences, HTML, reference
---             definitions, ...) and units (headings, paragraphs, list items,
---             quotes, table cells)
---   mask      inline code, link targets, autolinks, ... become `{n}`
---   cache     a unit seen before (same text, target, source, engine, model)
---             is not sent again
---   batch     the remaining units go to the engine in requests of at most
---             `max_chars` / `max_units`, `concurrency` of them at a time
---   validate  every answer is checked (placeholders complete, plausible
---             length); one retry; then the ORIGINAL unit stays
---   reflow    each translation is wrapped onto the line count of its source,
---             never breaking in front of a block-start token
---   anchors   `](#old-slug)` is rewritten to the slug of the translated heading
---
--- A unit that could not be translated is never an error of the call: it stays
--- German (original) and is counted in `info.failed`. The call itself fails only
--- when it cannot start (no engine, bad arguments), when it is cancelled, or
--- when its token went stale.
---
--- Every callback runs on the main loop, never before `translate_markdown`
--- has returned. `cb` runs exactly once.

require("language.translate.@types")
require("language.translate.markdown.@types")

local anchors = require("language.translate.markdown.anchors")
local cache = require("language.translate.markdown.cache")
local mask = require("language.translate.markdown.mask")
local reflow = require("language.translate.markdown.reflow")
local segment = require("language.translate.markdown.segment")

local M = {}

M.cache = cache

local DEFAULT_MAX_UNITS = 40
local MAX_ERRORS = 5
local ABORT_AFTER = 3

---@internal
---@param v any
---@param default integer
---@param lo integer
---@param hi integer
---@return integer
local function int(v, default, lo, hi)
  if type(v) ~= "number" or v ~= v then
    return default
  end
  return math.max(lo, math.min(hi, math.floor(v)))
end

---@internal
---@param tr table
---@param opts table
---@return table
local function settings(tr, opts)
  local m = type(tr.markdown) == "table" and tr.markdown or {}
  local keep = {}
  local function add(list)
    if type(list) == "table" then
      for _, w in ipairs(list) do
        keep[#keep + 1] = w
      end
    end
  end
  add(m.keep)
  add(opts.keep)
  return {
    concurrency = int(opts.concurrency, int(m.concurrency, 3, 1, 16), 1, 16),
    max_chars = int(opts.max_chars, int(m.max_chars, 3000, 200, 100000), 200, 100000),
    max_units = int(opts.max_units, DEFAULT_MAX_UNITS, 1, 50),
    disk = m.disk_cache ~= false,
    cache_max_kb = int(m.cache_max_kb, 2048, 16, 102400),
    cache_dir = type(m.cache_dir) == "string" and m.cache_dir or nil,
    keep = keep,
  }
end

---@internal
---Does `text` look like a plausible translation of `orig` (both masked)?
---@param orig string
---@param text string
---@return boolean
local function plausible(orig, text)
  local a, b = #orig, #text
  if b == 0 then
    return false
  end
  if a >= 20 then
    return b >= a * 0.12 and b <= a * 6
  end
  return b <= a * 8 + 40
end

---@internal
---Number of unescaped pipes in `s`.
---@param s string
---@return integer
local function pipe_count(s)
  local n, i = 0, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c == "|" then
      n = n + 1
    end
    i = i + 1
  end
  return n
end

---@internal
---Would `text` (the translation of the table cell `orig`) change the shape of
---the row: a pipe of its own, or a backslash that escapes the pipe behind it?
---@param orig string
---@param text string
---@return boolean
local function cell_breaks(orig, text)
  return pipe_count(text) ~= pipe_count(orig) or #text:match("\\*$") % 2 == 1
end

---Translate a Markdown document.
---@param lines string[]
---@param opts LanguageMdTranslateOpts
---@param cb LanguageMdTranslateCb
---@return { cancel: fun() } handle
function M.translate_markdown(lines, opts, cb)
  opts = opts or {}
  local finished = false
  ---@type table<table, boolean>
  local jobs = {}

  local function finish(ok, res, info)
    if finished then
      return
    end
    finished = true
    for job in pairs(jobs) do
      pcall(job.cancel)
    end
    jobs = {}
    cb(ok, res, info)
  end

  local handle = {
    cancel = function()
      finish(false, "cancelled")
    end,
  }

  if type(cb) ~= "function" then
    error("translate_markdown: cb must be a function", 2)
  end
  local bad
  if type(lines) ~= "table" then
    bad = "lines must be a list of strings"
  else
    for i = 1, #lines do
      if type(lines[i]) ~= "string" then
        bad = ("lines[%d] is not a string"):format(i)
        break
      end
    end
  end
  if not bad and (type(opts.target) ~= "string" or opts.target == "") then
    bad = "opts.target (the target language) is required"
  end
  if bad then
    vim.schedule(function()
      finish(false, bad)
    end)
    return handle
  end

  local function stale()
    local t = opts.token
    if type(t) ~= "table" then
      return false
    end
    if t.cancelled then
      return true
    end
    if type(t.current) == "function" then
      local ok, v = pcall(t.current)
      return ok and v ~= t.generation
    end
    return false
  end

  local function run()
    local t0 = vim.uv.hrtime()
    if stale() then
      finish(false, "stale")
      return
    end

    local tr = opts.cfg or require("language.config").get().translate or {}
    local st = settings(tr, opts)

    local provider, perr = opts.provider, nil
    if not provider then
      local reg = require("language.translate.providers.registry")
      local rcfg = tr
      if opts.engine then
        rcfg = vim.tbl_extend("force", tr, { engine = opts.engine, fallback = {} })
      end
      provider, perr = reg.resolve(rcfg)
    end
    if not provider and not opts.cache_only then
      finish(false, perr or "no available translate engine")
      return
    end
    local engine = provider and provider.name or opts.engine or tr.engine or "?"
    local target, source = opts.target, opts.source

    local use_cache = opts.cache ~= false
    if use_cache then
      cache.configure({ disk = st.disk, max_kb = st.cache_max_kb, dir = st.cache_dir })
    end

    local seg = segment.segment(lines)
    local units = seg.units

    ---@class LanguageMdUnitState
    ---@field masked string
    ---@field mk LanguageMdMask
    ---@field anchor boolean
    ---@field tr string|nil
    ---@field status string|nil
    ---@field reflow_failed boolean|string|nil
    ---@field counted boolean|nil
    ---@field entry table|nil
    ---@type LanguageMdUnitState[]
    local ust = {}
    local info = {
      units = #units,
      translated = 0,
      cached = 0,
      failed = 0,
      skipped = 0,
      pending = 0,
      reflow_failed = 0,
      requests = 0,
      retries = 0,
      anchors_changed = 0,
      errors = {},
      ms = 0,
    }

    ---@type table<string, table>
    local entries = {}
    ---@type table[]
    local todo = {}
    local unit_block = {}
    for bi, blk in ipairs(seg.blocks) do
      for _, id in ipairs(blk.units) do
        unit_block[id] = bi
      end
    end
    local bstate = {}
    for bi = 1, #seg.blocks do
      bstate[bi] = { pending = 0, changed = false, partial = false, cached_only = true }
    end
    local total_blocks, done_blocks = 0, 0
    local is_heading = {}
    for _, id in ipairs(seg.headings) do
      is_heading[id] = true
    end

    for id, u in ipairs(units) do
      local masked, mk = mask.mask(u.text, { defs = seg.defs, keep = st.keep })
      local s = { masked = masked, mk = mk, anchor = false }
      for _, t in ipairs(mk.toks) do
        if t:match("^%]%(<?#") then
          s.anchor = true
          break
        end
      end
      ust[id] = s
      if mask.has_text(masked) then
        local e = entries[masked]
        if not e then
          e = { masked = masked, mk = mk, units = {}, heading = false }
          entries[masked] = e
          todo[#todo + 1] = e
        end
        e.units[#e.units + 1] = id
        e.heading = e.heading or is_heading[id] == true
        e.cell = e.cell or u.block == "cell"
        s.entry = e
        local bs = bstate[unit_block[id]]
        bs.pending = bs.pending + 1
      else
        info.skipped = info.skipped + 1
      end
    end
    for _, bs in ipairs(bstate) do
      if bs.pending > 0 then
        total_blocks = total_blocks + 1
      end
    end

    -- Anchors ------------------------------------------------------------------
    local map = nil ---@type table<string, string>|nil
    local heading_pending = 0
    for _, id in ipairs(seg.headings) do
      if ust[id].entry then
        heading_pending = heading_pending + 1
      end
    end

    local function build_map()
      local old, new = {}, {}
      for i, id in ipairs(seg.headings) do
        old[i] = units[id].text
        local s = ust[id]
        new[i] = s.tr and mask.unmask(s.tr, s.mk) or units[id].text
      end
      map = anchors.build_map(old, new)
    end

    -- Content of a unit / a block -----------------------------------------------

    ---@param id integer
    ---@return string[]|nil
    local function unit_content(id)
      local s = ust[id]
      local text, mk = s.tr, s.mk
      if map and s.anchor then
        local toks, changed = {}, false
        for i, t in ipairs(mk.toks) do
          local new, c = anchors.rewrite_dest(t, map)
          toks[i], changed = new, changed or c
        end
        if changed then
          mk = { toks = toks, pair = mk.pair }
          -- A unit that stays as it is (nothing to translate, or its translation
          -- failed) still points at a heading whose slug changed: put it together
          -- again from its masked text, with the new targets.
          text = text or s.masked
        end
      end
      if not text then
        return nil
      end
      local u = units[id]
      local function unsafe(word)
        return reflow.starts_block(mask.unmask(word, mk))
      end
      local out, err =
        reflow.reflow(text, u.weights, { guard_first = u.guard_first, unsafe = unsafe })
      if not out then
        s.reflow_failed = s.tr and (err or true) or nil
        return nil
      end
      for k = 1, #out do
        out[k] = mask.unmask(out[k], mk)
        if k == #out and u.hard_backslash and out[k]:match("https?://[^%s]*$") then
          -- A bare address in front of the break would swallow its backslash.
          s.reflow_failed = s.tr and "the break would join an address" or nil
          return nil
        end
        if reflow.is_table_rule(out[k]) and not reflow.is_table_rule(u.orig[k]) then
          -- This wrap would make a delimiter row of a line of text.
          s.reflow_failed = s.tr and "the wrap would form a table" or nil
          return nil
        end
      end
      return out
    end

    ---@param bi integer
    ---@return string[]
    local function block_lines(bi)
      local blk = seg.blocks[bi]
      local content = {}
      for _, id in ipairs(blk.units) do
        content[id] = unit_content(id)
      end
      return segment.render(seg, content, blk.first, blk.last)
    end

    -- Progress -----------------------------------------------------------------
    local deferred = {}

    local function emit(bi)
      local bs = bstate[bi]
      -- Nothing after `cb`: a cancel from inside an earlier `on_unit` ends the stream.
      if finished or not bs.changed or not opts.on_unit then
        return
      end
      done_blocks = done_blocks + 1
      local blk = seg.blocks[bi]
      local out = block_lines(bi)
      pcall(opts.on_unit, {
        first = blk.first,
        last = blk.last,
        lines = out,
        status = bs.partial and "partial" or (bs.cached_only and "cached" or "translated"),
        done = done_blocks,
        total = total_blocks,
      })
    end

    local function block_ready(bi)
      local needs = false
      for _, id in ipairs(seg.blocks[bi].units) do
        if ust[id].anchor then
          needs = true
        end
      end
      if needs and not map then
        deferred[#deferred + 1] = bi
      else
        emit(bi)
      end
    end

    ---A unit got its final state (translated, cached or failed).
    ---@param id integer
    ---@param ok boolean
    ---@param from_cache boolean
    local function unit_done(id, ok, from_cache)
      local bi = unit_block[id]
      local bs = bstate[bi]
      if ok then
        bs.changed = true
        if not from_cache then
          bs.cached_only = false
        end
      else
        bs.partial = true
      end
      bs.pending = bs.pending - 1
      if is_heading[id] then
        heading_pending = heading_pending - 1
        if heading_pending == 0 then
          build_map()
          local list = deferred
          deferred = {}
          for _, d in ipairs(list) do
            emit(d)
          end
        end
      end
      if bs.pending == 0 then
        block_ready(bi)
      end
    end

    if heading_pending == 0 then
      build_map()
    end

    ---@param entry table
    ---@param value string
    ---@param from_cache boolean
    local function resolve_entry(entry, value, from_cache)
      entry.done = true
      for _, id in ipairs(entry.units) do
        ust[id].tr = value
        ust[id].status = from_cache and "cached" or "translated"
        if from_cache then
          info.cached = info.cached + 1
        else
          info.translated = info.translated + 1
        end
      end
      for _, id in ipairs(entry.units) do
        unit_done(id, true, from_cache)
      end
    end

    local remaining = 0

    ---@param entry table
    ---@param err string
    local function fail_entry(entry, err)
      entry.done = true
      remaining = remaining - 1
      if #info.errors < MAX_ERRORS then
        info.errors[#info.errors + 1] = err
      end
      for _ = 1, #entry.units do
        info.failed = info.failed + 1
      end
      for _, id in ipairs(entry.units) do
        unit_done(id, false, false)
      end
    end

    ---Validate an answer for `entry`.
    ---@param entry table
    ---@param text any
    ---@return string|nil value, string|nil err
    local function validate(entry, text)
      if type(text) ~= "string" then
        return nil, "the engine returned no text"
      end
      text = mask.normalize(text):gsub("%s*[\r\n]+%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
      if text == "" then
        return nil, "the engine returned an empty translation"
      end
      local ok, err = mask.check(text, entry.mk)
      if not ok then
        return nil, err
      end
      if not plausible(entry.masked, text) then
        return nil, "implausible length of the translation"
      end
      if entry.cell and cell_breaks(entry.masked, text) then
        return nil, "the translation would split or merge table cells"
      end
      return text
    end

    -- Cache pass ---------------------------------------------------------------
    local misses = {}
    for _, e in ipairs(todo) do
      e.key = use_cache and cache.key(engine, opts.model, target, source, e.masked) or nil
      local hit = e.key and cache.get(e.key)
      local value = hit and validate(e, hit)
      if value then
        resolve_entry(e, value, true)
      else
        misses[#misses + 1] = e
      end
    end

    -- Headings first, so the anchor map is known early; document order inside
    -- both groups (table.sort is not stable, hence the explicit index).
    do
      local order = {}
      for i, e in ipairs(todo) do
        order[e] = i
      end
      table.sort(misses, function(a, b)
        if a.heading ~= b.heading then
          return a.heading
        end
        return order[a] < order[b]
      end)
    end

    for _, e in ipairs(misses) do
      info.pending = info.pending + #e.units
    end

    -- Finalisation ---------------------------------------------------------------
    local function finalize()
      if finished then
        return
      end
      if stale() then
        finish(false, "stale")
        return
      end
      if not map then
        build_map()
      end
      local content = {}
      for id = 1, #units do
        content[id] = unit_content(id)
        if ust[id].reflow_failed and not ust[id].counted then
          ust[id].counted = true
          info.reflow_failed = info.reflow_failed + 1
        end
      end
      local out = segment.render(seg, content)
      local amap = map or {}
      for _, L in ipairs(seg.refdefs) do
        local new, changed = anchors.rewrite_refdef(out[L], amap)
        if changed then
          out[L] = new
          info.anchors_changed = info.anchors_changed + 1
        end
      end
      for id = 1, #units do
        if ust[id].anchor then
          for _, t in ipairs(ust[id].mk.toks) do
            local _, changed = anchors.rewrite_dest(t, amap)
            if changed then
              info.anchors_changed = info.anchors_changed + 1
            end
          end
        end
      end
      if #out ~= #lines then
        -- Cannot happen by construction; the invariant is hard, so the original wins.
        info.errors[#info.errors + 1] = "internal: line count changed, original returned"
        out = vim.list_slice(lines)
      end
      info.ms = (vim.uv.hrtime() - t0) / 1e6
      finish(true, out, info)
    end

    if opts.cache_only or #misses == 0 then
      finalize()
      return
    end
    info.pending = 0

    -- Requests -------------------------------------------------------------------
    remaining = #misses
    local pending = {} ---@type { entries: table[], attempt: integer }[]
    local active, consec_fail = 0, 0
    local pumping = false
    local pump

    do
      local cur, cost = {}, 0
      for _, e in ipairs(misses) do
        local c = #e.masked + 8
        if #cur > 0 and (cost + c > st.max_chars or #cur >= st.max_units) then
          pending[#pending + 1] = { entries = cur, attempt = 1 }
          cur, cost = {}, 0
        end
        cur[#cur + 1] = e
        cost = cost + c
      end
      if #cur > 0 then
        pending[#pending + 1] = { entries = cur, attempt = 1 }
      end
    end

    local function maybe_finish()
      if not finished and remaining == 0 and active == 0 and #pending == 0 then
        finalize()
      end
    end

    local function abort_rest(err)
      local list = pending
      pending = {}
      for _, req in ipairs(list) do
        for _, e in ipairs(req.entries) do
          fail_entry(e, "skipped after repeated failures: " .. err)
        end
      end
    end

    ---@param req table
    ---@param ok boolean
    ---@param res any
    local function handle_result(req, ok, res)
      local n = #req.entries
      if ok and type(res) ~= "table" then
        ok, res = false, "the engine returned no lines"
      end
      if not ok then
        consec_fail = consec_fail + 1
        local err = tostring(res)
        if req.attempt == 1 and consec_fail < ABORT_AFTER then
          info.retries = info.retries + n
          table.insert(pending, 1, { entries = req.entries, attempt = 2 })
        else
          for _, e in ipairs(req.entries) do
            fail_entry(e, err)
          end
          if consec_fail >= ABORT_AFTER then
            abort_rest(err)
          end
        end
        return
      end

      -- A parse of `out .. "\n"` may add one trailing empty line.
      local m = #res
      while m > n and res[m] == "" do
        m = m - 1
      end
      if m ~= n then
        if n == 1 then
          res = { table.concat(res, " ", 1, m) }
        elseif req.attempt == 1 then
          -- Cannot tell which unit grew a line break: one request per unit.
          info.retries = info.retries + n
          for i = n, 1, -1 do
            table.insert(pending, 1, { entries = { req.entries[i] }, attempt = 2 })
          end
          return
        else
          for _, e in ipairs(req.entries) do
            fail_entry(e, ("the engine returned %d lines for %d units"):format(m, n))
          end
          return
        end
      end

      local invalid, first_err = {}, nil
      for i, e in ipairs(req.entries) do
        local value, err = validate(e, res[i])
        if value then
          consec_fail = 0
          remaining = remaining - 1
          if use_cache then
            cache.set(e.key, value)
          end
          resolve_entry(e, value, false)
        else
          invalid[#invalid + 1] = e
          first_err = first_err or err
        end
      end
      if #invalid > 0 then
        if req.attempt == 1 then
          info.retries = info.retries + #invalid
          table.insert(pending, 1, { entries = invalid, attempt = 2 })
        else
          for _, e in ipairs(invalid) do
            fail_entry(e, first_err or "invalid translation")
          end
        end
      end
    end

    ---@param req table
    local function send(req)
      local texts = {}
      for i, e in ipairs(req.entries) do
        texts[i] = e.masked
      end
      active = active + 1
      info.requests = info.requests + 1
      local answered = false
      local job
      local function on_result(ok, res)
        if answered then
          return
        end
        answered = true
        active = active - 1
        if job then
          jobs[job] = nil
        end
        if finished then
          return
        end
        if stale() then
          finish(false, "stale")
          return
        end
        handle_result(req, ok, res)
        pump()
      end
      local started, j = pcall(provider.translate, texts, target, source, tr, on_result)
      if not started then
        on_result(false, tostring(j))
      elseif type(j) == "table" and not answered then
        job = j
        jobs[j] = true
      end
    end

    pump = function()
      if pumping then
        return
      end
      pumping = true
      while not finished and active < st.concurrency and #pending > 0 do
        if stale() then
          pumping = false
          finish(false, "stale")
          return
        end
        send(table.remove(pending, 1))
      end
      pumping = false
      maybe_finish()
    end

    pump()
  end

  vim.schedule(function()
    if finished then
      return
    end
    local ok, err = pcall(run)
    if not ok then
      finish(false, "translate_markdown: " .. tostring(err))
    end
  end)

  return handle
end

return M
