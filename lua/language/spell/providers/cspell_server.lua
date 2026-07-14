---@module 'language.spell.providers.cspell_server'
---@brief Persistent cspell sidecar client (fast, code-aware buffer checks).
---@description
--- Keeps a Node process (`node/cspell_server.js`) alive that has cspell-lib
--- loaded, so buffer spell-checks avoid the ~200-400 ms cspell/Node cold start
--- — fast enough for live scanning. Talks newline-delimited JSON over the job's
--- stdin/stdout, matching responses by id (supports cancellation + timeout).
--- Used for single-buffer scopes when "cspell_server" is in `providers.buffer`.
---
--- cspell-lib is ESM and resolves its bundled dictionaries relative to the
--- process cwd, so the sidecar is spawned with cwd inside the cspell install
--- (derived from `npm root -g`).

require("language.@types")
require("language.spell.@types")

local api = vim.api
local fn = vim.fn

local M = {}

M.name = "cspell"
M.supports = { buffer = true, cwd = false, grammar = false }

---@class Language.CspellServerState
local state = {
  jid = nil, ---@type integer|nil
  ready = false,
  failed = false,
  starting = false,
  resolving = false,
  resolved = false,
  entry = nil, ---@type string|nil   cspell-lib dist/index.js
  cwd = nil, ---@type string|nil     node_modules dir containing cspell-lib
  next_id = 0,
  pending = {}, ---@type table<integer, fun(issues: LanguageSpellIssue[])>
  start_cbs = {}, ---@type fun(ok: boolean)[]
  resolve_cbs = {}, ---@type fun(ok: boolean)[]
  stdout_buf = "",
}

---node + cspell must be present, and the sidecar must not have failed.
---@return boolean
function M.available()
  return fn.executable("node") == 1 and fn.executable("cspell") == 1 and not state.failed
end

-- ── Resolution: find cspell-lib's entry + a cwd where its dicts resolve ──────

---@param cb fun(ok: boolean)
local function resolve(cb)
  if state.resolved then
    cb(true)
    return
  end
  state.resolve_cbs[#state.resolve_cbs + 1] = cb
  if state.resolving then
    return
  end
  state.resolving = true

  require("language.util.job").run({ "npm", "root", "-g" }, {
    timeout_ms = 8000,
    on_done = function(ok, out)
      local root = ok and vim.trim(out or "") or ""
      if root ~= "" then
        local candidates = {
          root .. "/cspell/node_modules/cspell-lib/dist/index.js", -- nested (npm global)
          root .. "/cspell-lib/dist/index.js", -- hoisted
        }
        for _, cand in ipairs(candidates) do
          if fn.filereadable(cand) == 1 then
            state.entry = cand
            state.cwd = fn.fnamemodify(cand, ":h:h:h") -- .../node_modules (holds cspell-lib + @cspell)
            state.resolved = true
            break
          end
        end
      end
      local cbs = state.resolve_cbs
      state.resolve_cbs = {}
      state.resolving = false
      for _, c in ipairs(cbs) do
        c(state.resolved)
      end
    end,
  })
end

-- ── Process lifecycle ───────────────────────────────────────────────────────

local function flush_start(ok)
  local cbs = state.start_cbs
  state.start_cbs = {}
  state.starting = false
  for _, c in ipairs(cbs) do
    c(ok)
  end
end

---Dispatch one complete JSON line from the sidecar.
---@param line string
local function handle_line(line)
  if line == "" then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.ready then
    state.ready = true
    flush_start(true)
    return
  end
  if msg.error and not msg.id then
    state.failed = true
    require("lib.nvim.notify")
      .create("[language.spell]")
      .error("cspell server: " .. tostring(msg.error))
    flush_start(false)
    return
  end
  if msg.id then
    local pcb = state.pending[msg.id]
    state.pending[msg.id] = nil
    if pcb then
      pcb(msg.issues or {})
    end
  end
end

local function on_stdout(_, data)
  if not data then
    return
  end
  state.stdout_buf = state.stdout_buf .. table.concat(data, "\n")
  while true do
    local nl = state.stdout_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = state.stdout_buf:sub(1, nl - 1)
    state.stdout_buf = state.stdout_buf:sub(nl + 1)
    handle_line(line)
  end
end

---@param cfg LanguageSpellCfg
---@return string
local function language(cfg)
  local sl = (cfg.providers and cfg.providers.native and cfg.providers.native.spelllang)
    or vim.o.spelllang
    or "en"
  return (tostring(sl):match("%a%a")) or "en"
end

---Ensure the sidecar is running, then call `cb(ok)`.
---@param cfg LanguageSpellCfg
---@param cb fun(ok: boolean)
local function ensure_started(cfg, cb)
  if state.ready then
    cb(true)
    return
  end
  if state.failed then
    cb(false)
    return
  end
  state.start_cbs[#state.start_cbs + 1] = cb
  if state.starting then
    return
  end
  state.starting = true

  resolve(function(ok)
    if not ok or not state.entry then
      state.failed = true
      flush_start(false)
      return
    end
    local script = api.nvim_get_runtime_file("node/cspell_server.js", false)[1]
    if not script then
      state.failed = true
      flush_start(false)
      return
    end
    local jid = fn.jobstart({ "node", script, state.entry }, {
      cwd = state.cwd,
      env = { CSPELL_LANG = language(cfg) },
      on_stdout = on_stdout,
      on_exit = function()
        state.ready = false
        state.jid = nil
        -- Drop any waiting requests.
        for id, pcb in pairs(state.pending) do
          state.pending[id] = nil
          pcb({})
        end
      end,
    })
    if not jid or jid <= 0 then
      state.failed = true
      flush_start(false)
      return
    end
    state.jid = jid
    -- `flush_start(true)` fires when the {ready:true} line arrives (on_stdout).
  end)
end

-- Kill the sidecar when Neovim exits.
api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if state.jid and state.jid > 0 then
      pcall(fn.jobstop, state.jid)
    end
  end,
  desc = "[language] stop cspell sidecar",
})

-- ── Public: check a buffer scope ────────────────────────────────────────────

---Check the buffer of `scope` via the sidecar. Delivers issues through `cb`.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param cb fun(issues: LanguageSpellIssue[])
---@return Language.Job
function M.check(scope, cfg, cb)
  local handle = { cancelled = false, cancel = function() end }

  ensure_started(cfg, function(ok)
    if handle.cancelled then
      return
    end
    local bufnr = scope.bufnr or api.nvim_get_current_buf()
    if not ok or not (state.jid and api.nvim_buf_is_valid(bufnr)) then
      cb({})
      return
    end

    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local path = api.nvim_buf_get_name(bufnr)
    state.next_id = state.next_id + 1
    local id = state.next_id

    handle.cancel = function()
      state.pending[id] = nil
    end

    local timer = vim.uv.new_timer()
    state.pending[id] = function(raw_issues)
      pcall(function()
        timer:stop()
        timer:close()
      end)
      ---@type LanguageSpellIssue[]
      local out = {}
      for _, is in ipairs(raw_issues) do
        is.bufnr = bufnr
        is.path = path
        is.kind = "spell"
        is.source = "cspell"
        out[#out + 1] = is
      end
      cb(out)
    end

    timer:start(cfg.scan_debounce_ms and 6000 or 6000, 0, function()
      vim.schedule(function()
        if state.pending[id] then
          state.pending[id] = nil
          cb({})
        end
      end)
    end)

    fn.chansend(
      state.jid,
      vim.json.encode({ id = id, text = table.concat(lines, "\n"), path = path, suggestions = true })
        .. "\n"
    )
  end)

  return handle
end

return M
