---@module 'language.spell.ui.list'
---@brief Diagnostics publishing + Trouble/quickfix list output for spell issues.
---@description
--- Phase-2 output layer: publishes issues into an isolated diagnostics
--- namespace and opens either trouble.nvim (when available and enabled) or the
--- quickfix list. The richer lib.nvim.ui.kit review panel is added in a later
--- phase; this keeps functional parity with the prior implementation.

require("language.spell.@types")

local api = vim.api
local diag = vim.diagnostic
local highlights = require("language.spell.ui.highlights")

local M = {}

---@type integer
M.ns = api.nvim_create_namespace("language_spell")

---@type table<LanguageSpellKind, integer>
local SEVERITY = {
  spell = diag.severity.WARN,
  rare = diag.severity.HINT,
  caps = diag.severity.INFO,
  grammar = diag.severity.WARN,
  style = diag.severity.HINT,
}

---Convert an issue to a vim.Diagnostic (0-based line/col).
---@param issue LanguageSpellIssue
---@param source string
---@return vim.Diagnostic
local function to_diagnostic(issue, source)
  return {
    lnum = issue.lnum - 1,
    col = issue.col - 1,
    end_lnum = issue.lnum - 1,
    end_col = issue.end_col - 1,
    severity = SEVERITY[issue.kind] or diag.severity.WARN,
    source = source,
    message = issue.message or ("'%s' is not in the dictionary"):format(issue.word),
    user_data = { word = issue.word, kind = issue.kind },
  }
end

---Publish issues into the namespace, grouped per buffer. Returns the set of
---buffers that received diagnostics (so callers can reset them later). When
---`max` is given, at most `max` diagnostics are published per buffer (perf cap;
---the full issue list still reaches the panel/quickfix). When `highlights_cfg`
---has `enable = true`, buffer extmark highlights are published alongside the
---diagnostics (see `spell/ui/highlights.lua`) — independent of `max`, since
---they're a separate opt-in visibility channel, not a diagnostics fallback.
---@param issues LanguageSpellIssue[]
---@param source string
---@param max integer|nil
---@param highlights_cfg { enable: boolean, style: "underline"|"undercurl" }|nil
---@return table<integer, true> touched_bufs
function M.publish(issues, source, max, highlights_cfg)
  ---@type table<integer, vim.Diagnostic[]>
  local by_buf = {}
  for _, issue in ipairs(issues) do
    local b = issue.bufnr
    if b and api.nvim_buf_is_valid(b) then
      local list = by_buf[b]
      if not list then
        list = {}
        by_buf[b] = list
      end
      if not (max and #list >= max) then
        list[#list + 1] = to_diagnostic(issue, source)
      end
    end
  end

  local touched = {}
  for b, ds in pairs(by_buf) do
    diag.reset(M.ns, b)
    diag.set(M.ns, b, ds)
    touched[b] = true
  end
  highlights.publish(issues, highlights_cfg)
  return touched
end

---Reset diagnostics (and buffer highlight extmarks) in the namespace for the
---given buffers, or all.
---@param bufs table<integer, true>|nil
function M.clear(bufs)
  if bufs then
    for b in pairs(bufs) do
      if api.nvim_buf_is_valid(b) then
        diag.reset(M.ns, b)
      end
    end
  else
    diag.reset(M.ns)
  end
  highlights.clear(bufs)
end

---Build quickfix entries from issues.
---@param issues LanguageSpellIssue[]
---@return table[]
local function to_qf(issues)
  local entries = {}
  for i, issue in ipairs(issues) do
    entries[i] = {
      bufnr = issue.bufnr,
      filename = (not issue.bufnr) and issue.path or nil,
      lnum = issue.lnum,
      col = issue.col,
      text = (issue.occurrences and issue.occurrences > 1)
          and ("%s  (%dx)  %s"):format(issue.word, issue.occurrences, issue.message or "")
        or ("%s  %s"):format(issue.word, issue.message or ""),
      type = "W",
    }
  end
  return entries
end

---@return boolean
local function trouble_ok()
  return pcall(require, "trouble")
end

---Open the appropriate list backend.
---@param issues LanguageSpellIssue[]
---@param opts { use_trouble: boolean, source: string, title: string }
function M.open(issues, opts)
  if opts.use_trouble and trouble_ok() then
    local ok, trouble = pcall(require, "trouble")
    if ok then
      pcall(trouble.open, { mode = "diagnostics", filter = { source = opts.source } })
      return
    end
  end
  vim.fn.setqflist(to_qf(issues), "r")
  vim.fn.setqflist({}, "a", { title = opts.title })
  vim.cmd("copen")
end

---Refresh whichever list is open.
---@param issues LanguageSpellIssue[]
---@param opts { use_trouble: boolean, source: string, title: string }
function M.refresh(issues, opts)
  if opts.use_trouble and trouble_ok() then
    vim.schedule(function()
      pcall(function()
        require("trouble").refresh()
      end)
    end)
    return
  end
  vim.fn.setqflist(to_qf(issues), "r")
  vim.fn.setqflist({}, "a", { title = opts.title })
end

---Close whichever list is open.
---@param use_trouble boolean
function M.close(use_trouble)
  if use_trouble and trouble_ok() then
    pcall(function()
      require("trouble").close()
    end)
  else
    pcall(vim.cmd, "cclose")
  end
end

return M
