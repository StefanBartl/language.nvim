---@module 'language.spell.live'
---@brief Always-on, debounced inline spell diagnostics (opt-in).
---@description
--- When `spell.live = true`, configured filetypes get continuously updated
--- spelling/grammar diagnostics as you edit — independent of the on-demand
--- panel/session. Scanning is debounced and, by default, restricted to the
--- visible window range (`spell.live_scope = "visible"`) so large files stay
--- responsive. Perf/safety gates: filetype allow-list, `max_file_lines`,
--- readonly skip (native), and `max_highlights` cap on published diagnostics.

local api = vim.api

local list = require("language.spell.ui.list")
local collect = require("language.spell.core.collect")

local M = {}

local SOURCE = "language.spell"

---Debounce timers per buffer.
---@type table<integer, uv.uv_timer_t>
local timers = {}

---Buffers currently carrying live diagnostics.
---@type table<integer, true>
local attached = {}

---@return LanguageSpellCfg
local function cfg()
  return require("language.config").get().spell
end

---@param bufnr integer
---@return boolean
local function ft_enabled(bufnr)
  local ft = vim.bo[bufnr].filetype
  for _, f in ipairs(cfg().filetypes or {}) do
    if f == ft then
      return true
    end
  end
  return false
end

---Should this buffer be live-scanned right now?
---@param bufnr integer
---@return boolean
function M.should_scan(bufnr)
  local c = cfg()
  if not c.live then
    return false
  end
  if not (bufnr and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr)) then
    return false
  end
  if api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
    return false
  end
  if not ft_enabled(bufnr) then
    return false
  end
  local max = c.max_file_lines
  if max and api.nvim_buf_line_count(bufnr) > max then
    return false
  end
  return true
end

---Build the scope for a live scan (visible range when configured & focused).
---@param bufnr integer
---@return LanguageScope
local function build_scope(bufnr)
  local c = cfg()
  if c.live_scope == "visible" and bufnr == api.nvim_get_current_buf() then
    return {
      kind = "visible",
      bufnr = bufnr,
      range = { s = vim.fn.line("w0"), e = vim.fn.line("w$") },
    }
  end
  return { kind = "buffer", bufnr = bufnr }
end

---Scan `bufnr` now and (re)publish its live diagnostics. Collection is
---async-capable (the cspell sidecar), so publishing happens in the callback.
---@param bufnr integer
---@return nil
function M.scan(bufnr)
  if not M.should_scan(bufnr) then
    return
  end
  collect.gather(build_scope(bufnr), cfg(), function(issues)
    if not api.nvim_buf_is_valid(bufnr) then
      return
    end
    list.clear({ [bufnr] = true })
    list.publish(issues, SOURCE, cfg().max_highlights, cfg().highlights)
    attached[bufnr] = true
  end)
end

---Debounced live rescan trigger.
---@param bufnr integer
---@return nil
function M.on_change(bufnr)
  if not M.should_scan(bufnr) then
    return
  end
  local delay = cfg().scan_debounce_ms or 400
  local t = timers[bufnr]
  if not t then
    t = vim.uv.new_timer()
    timers[bufnr] = t
  end
  t:stop()
  t:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if api.nvim_buf_is_valid(bufnr) then
        M.scan(bufnr)
      end
    end)
  )
end

---Stop live scanning `bufnr` and clear its diagnostics.
---@param bufnr integer
---@return nil
function M.detach(bufnr)
  local t = timers[bufnr]
  if t then
    pcall(function()
      t:stop()
      t:close()
    end)
    timers[bufnr] = nil
  end
  if attached[bufnr] then
    if api.nvim_buf_is_valid(bufnr) then
      list.clear({ [bufnr] = true })
    end
    attached[bufnr] = nil
  end
end

return M
