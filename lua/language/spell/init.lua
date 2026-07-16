---@module 'language.spell'
---@brief Spell/grammar domain entry point: sessions, scope orchestration, output.
---@description
--- Phase-2 scope: native provider + diagnostics + Trouble/quickfix output with
--- functional parity to the prior config/trouble/spell implementation, now
--- generalized over the shared scope model (buffer/visible/cwd/path). The
--- lib.nvim.ui.kit review panel and further providers arrive in later phases.
---
--- Buffer-scope runs a toggleable *session* (spell/spelllang saved & restored,
--- per-buffer fix keymaps). Wider scopes (cwd/path) produce a one-shot overview.

require("language.@types")
require("language.spell.@types")

local api = vim.api

local notify = require("lib.nvim.notify").create("[language.spell]")
local native = require("language.spell.providers.native")
local collect = require("language.spell.core.collect")
local list = require("language.spell.ui.list")

local M = {}

local SOURCE = "language.spell"

---Per-buffer session state.
---@type table<integer, LanguageSpellBufState>
local sessions = {}

---Buffers currently carrying our diagnostics (for cleanup).
---@type table<integer, true>
local touched = {}

-- ── Helpers ─────────────────────────────────────────────────────────────────

---@return LanguageSpellCfg
local function cfg()
  return require("language.config").get().spell
end

---@param bufnr integer
---@return boolean
local function buf_valid(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr)
end

---@return boolean
local function view_is_panel()
  local ui = cfg().ui
  return ui and ui.view == "picker"
end

---Temporarily set spelllang for the current window/buffer, returning the prior.
---@param lang string
---@return string prev
local function apply_lang(lang)
  local prev = vim.bo.spelllang
  if type(prev) ~= "string" or prev == "" then
    prev = "en"
  end
  vim.opt_local.spelllang = lang
  return prev
end

-- ── Fix keymaps (buffer-local, session scope) ───────────────────────────────

---@param bufnr integer
local function attach_keymaps(bufnr)
  local km = cfg().keymaps or {}
  local opts = { buffer = bufnr, silent = true }

  if type(km.fix) == "string" and km.fix ~= "" then
    vim.keymap.set("n", km.fix, function()
      M.fix_current()
    end, vim.tbl_extend("force", opts, { desc = "[language] Correct word & advance" }))
  end
  if type(km.fix1) == "string" and km.fix1 ~= "" then
    vim.keymap.set("n", km.fix1, function()
      vim.cmd("normal! 1z=")
      vim.defer_fn(function()
        M.refresh()
        M.goto_next()
      end, 60)
    end, vim.tbl_extend(
      "force",
      opts,
      { desc = "[language] Accept first suggestion & advance" }
    ))
  end
  if type(km.next) == "string" and km.next ~= "" then
    vim.keymap.set("n", km.next, function()
      M.goto_next()
    end, vim.tbl_extend("force", opts, { desc = "[language] Next spell error" }))
  end
end

---@param bufnr integer
local function detach_keymaps(bufnr)
  if not buf_valid(bufnr) then
    return
  end
  local km = cfg().keymaps or {}
  for _, lhs in ipairs({ km.fix, km.fix1, km.next }) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
end

-- ── Public API ──────────────────────────────────────────────────────────────

---Jump `count` diagnostics forward (negative = backward) in our namespace.
---@param count integer
---@return nil
local function diag_jump(count)
  local ok = pcall(function()
    vim.diagnostic.jump({ count = count, float = false, namespace = list.ns })
  end)
  if not ok then
    -- Older API fallback.
    if count > 0 then
      pcall(vim.diagnostic.goto_next, { namespace = list.ns, float = false })
    else
      pcall(vim.diagnostic.goto_prev, { namespace = list.ns, float = false })
    end
  end
end

---Jump to the next spell diagnostic in our namespace.
---@return nil
function M.goto_next()
  diag_jump(1)
end

---Jump to the previous spell diagnostic in our namespace.
---@return nil
function M.goto_prev()
  diag_jump(-1)
end

---Open the z= suggestion menu for the word under cursor, then refresh & advance.
---@return nil
function M.fix_current()
  vim.cmd("normal! z=")
  vim.defer_fn(function()
    M.refresh()
    M.goto_next()
  end, 60)
end

---Re-scan the current buffer session and update diagnostics + list.
---@return nil
function M.refresh()
  local bufnr = api.nvim_get_current_buf()
  if not buf_valid(bufnr) or not sessions[bufnr] then
    return
  end

  local scope = { kind = "buffer", bufnr = bufnr }
  local issues = collect.scan(scope, cfg())

  list.clear({ [bufnr] = true })
  touched = list.publish(issues, SOURCE, cfg().max_highlights, cfg().highlights)

  local use_trouble = cfg().ui and cfg().ui.view ~= "quickfix"
  list.refresh(issues, { use_trouble = use_trouble, source = SOURCE, title = "Spellcheck" })

  if #issues == 0 then
    notify.info("No spelling errors remaining — session closed")
    M.clear()
  end
end

---Run a spell check over `scope`. String scope kinds are also accepted for the
---Lua facade (`M.spellcheck`).
---@param lang? string
---@param scope? LanguageScope|string
---@return nil
function M.run(lang, scope)
  if not native.available() then
    notify.error("vim.spell.check requires Neovim >= 0.9")
    return
  end

  -- Normalize a string scope from the facade into a scope object.
  if type(scope) == "string" then
    if scope == "clear" then
      return M.clear()
    elseif scope == "refresh" then
      return M.refresh()
    end
    scope = require("language.scope").parse({ scope })
  end
  ---@cast scope LanguageScope|nil
  scope = scope or { kind = cfg().default_scope or "buffer", bufnr = api.nvim_get_current_buf() }

  lang = (type(lang) == "string" and lang ~= "") and lang or nil

  -- Panel view (default): apply the language, then open the interactive review
  -- panel over the scope. This is the flagship "work through the list" UI.
  if view_is_panel() then
    if lang and scope.kind ~= "cwd" and scope.kind ~= "path" then
      local b = scope.bufnr or api.nvim_get_current_buf()
      if buf_valid(b) then
        vim.opt_local.spelllang = lang
        vim.wo.spell = true
      end
    end
    require("language.spell.ui.panel").open(scope, cfg())
    return
  end

  local use_trouble = cfg().ui and cfg().ui.view ~= "quickfix"
  local scope_label = require("language.scope").label(scope)

  -- Wide scopes: one-shot overview (no per-buffer session toggling). Collection
  -- is async-capable (external CLI provider for cwd/path), so publish/open the
  -- list in the callback.
  if scope.kind == "cwd" or scope.kind == "path" then
    collect.gather(scope, cfg(), function(issues)
      if #issues == 0 then
        notify.info(("No spelling errors found (%s)"):format(scope_label))
        return
      end
      touched = list.publish(issues, SOURCE, cfg().max_highlights, cfg().highlights)
      list.open(
        issues,
        { use_trouble = use_trouble, source = SOURCE, title = "Spellcheck: " .. scope_label }
      )
      notify.info(("%d spelling issue(s) across %s"):format(#issues, scope_label))
    end)
    return
  end

  -- Buffer/visible/selection: session semantics on the target buffer.
  local bufnr = scope.bufnr or api.nvim_get_current_buf()
  if not buf_valid(bufnr) then
    notify.warn("Current buffer is invalid")
    return
  end

  -- Toggle off an active session.
  if sessions[bufnr] then
    return M.clear()
  end

  local spell_was_on = vim.wo.spell
  local prev_spelllang = lang and apply_lang(lang) or vim.bo.spelllang
  if not spell_was_on then
    vim.wo.spell = true
  end

  local issues = collect.scan(scope, cfg())

  if #issues == 0 then
    notify.info("No spelling errors found")
    vim.wo.spell = spell_was_on
    if lang then
      vim.opt_local.spelllang = prev_spelllang
    end
    return
  end

  sessions[bufnr] = {
    spell_was_on = spell_was_on,
    prev_spelllang = prev_spelllang,
    lang = lang or vim.bo.spelllang,
  }

  touched = list.publish(issues, SOURCE, cfg().max_highlights, cfg().highlights)
  attach_keymaps(bufnr)
  list.open(issues, { use_trouble = use_trouble, source = SOURCE, title = "Spellcheck" })
  notify.info(("%d spelling issue(s) found (%s)"):format(#issues, scope_label))
end

---Deactivate the session for the current buffer and restore options.
---@return nil
function M.clear()
  local bufnr = api.nvim_get_current_buf()
  local st = sessions[bufnr]

  list.clear(touched)
  touched = {}
  sessions[bufnr] = nil
  detach_keymaps(bufnr)

  if st then
    vim.wo.spell = st.spell_was_on
    if type(st.prev_spelllang) == "string" and st.prev_spelllang ~= "" then
      vim.opt_local.spelllang = st.prev_spelllang
    end
  end

  local use_trouble = cfg().ui and cfg().ui.view ~= "quickfix"
  list.close(use_trouble)
  notify.info("Spell checker deactivated")
end

---Open the interactive review panel over `scope` (default: current buffer).
---@param scope? LanguageScope|string
---@return nil
function M.open_panel(scope)
  if not native.available() then
    notify.error("vim.spell.check requires Neovim >= 0.9")
    return
  end
  if type(scope) == "string" then
    scope = require("language.scope").parse({ scope })
  end
  ---@cast scope LanguageScope|nil
  scope = scope or { kind = cfg().default_scope or "buffer", bufnr = api.nvim_get_current_buf() }
  require("language.spell.ui.panel").open(scope, cfg())
end

---GC hook: drop per-buffer session state + cached scan for a deleted buffer.
---(Live-scan timers are owned and cleaned up by `language.spell.live`.)
---@param bufnr integer
---@return nil
function M.on_buf_delete(bufnr)
  sessions[bufnr] = nil
  require("language.spell.core.cache").invalidate(bufnr)
end

return M
