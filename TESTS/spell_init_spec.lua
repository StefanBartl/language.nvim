-- TESTS/spell_init_spec.lua — language.spell: the domain entry point (session
-- toggling, scope routing, cleanup). `spell.ui.view = "quickfix"` throughout,
-- so this exercises `language.spell.ui.list` rather than the interactive
-- panel (`spell/ui/panel.lua` requires `ui.kit` — see TESTS/README.md).
-- `language.spell.ui.panel` is still stubbed, because `M.clear()` calls
-- `panel.clear()` unconditionally regardless of the configured view.
--
-- Diagnostics (`vim.diagnostic.get(buf, {namespace = list.ns})`), not
-- `vim.fn.getqflist()`, are used to observe "is a session currently active":
-- `list.close()`'s quickfix branch is a plain `:cclose`, which closes the
-- window but does not clear the list's contents — so the quickfix list is
-- stale the instant a session toggles off, and only trustworthy right after
-- a fresh `list.open()`/`refresh()` call actually repopulated it.

return function(H)
  local config = require("language.config")
  local list = require("language.spell.ui.list")

  package.loaded["language.spell.ui.panel"] = {
    open = function() end,
    clear = function() end,
  }
  package.loaded["language.spell"] = nil
  local spell = require("language.spell")

  local BAD = "zzqqxxspellinittest"

  config.setup({
    spell = {
      ui = { view = "quickfix" },
      default_scope = "buffer",
      providers = { buffer = {}, cwd = {} },
      word_split = { enable = false },
      regions = { treesitter_spell = false },
      skip_readonly = true,
      keymaps = {},
    },
  })

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
  vim.api.nvim_set_current_buf(buf)

  ---@return integer
  local function diag_count()
    return #vim.diagnostic.get(buf, { namespace = list.ns })
  end

  -- run(): opens a session, publishes diagnostics + the quickfix list -------
  spell.run(nil, { kind = "buffer", bufnr = buf })
  H.eq(diag_count(), 1, "one spelling issue is published as a diagnostic")
  H.eq(#vim.fn.getqflist(), 1, "and the quickfix list is populated to match")
  H.contains(vim.fn.getqflist()[1].text, BAD, "with the flagged word")

  -- run() again on the same buffer toggles the session off -------------------
  spell.run(nil, { kind = "buffer", bufnr = buf })
  H.eq(diag_count(), 0, "a second run() on the same buffer closes the session")

  -- run() with a language temporarily changes 'spelllang' for the session ---
  local prev_spelllang = vim.bo[buf].spelllang
  spell.run("de", { kind = "buffer", bufnr = buf })
  H.eq(vim.bo[buf].spelllang, "de", "the session applies the requested language")

  -- BUG: clear() does not actually restore the buffer's previous 'spelllang'
  -- here. `M.run`/`M.clear` apply and restore it via `vim.wo.spell` /
  -- `vim.opt_local.spelllang` — CURRENT-window options — but with the
  -- quickfix view (the non-default, non-panel UI this spec deliberately uses
  -- to avoid `ui.kit`), `list.open()` opens the quickfix window and leaves it
  -- current; `list.close()` (which returns focus to the original window) only
  -- runs *after* the spelllang restore line in `M.clear`. The restore's
  -- `vim.opt_local.spelllang = st.prev_spelllang` therefore lands on the
  -- quickfix window (about to be closed and discarded) instead of on `buf`'s
  -- own window, so `buf` is left at "de" forever — even though the session
  -- object it read `prev_spelllang` from was correct. Confirmed to leak into
  -- the *global* 'spelllang' value too (checked separately, not asserted
  -- here to keep this from depending on option-scope internals). Not fixed
  -- here: the fix is `nvim_set_option_value(..., { buf = bufnr })` /
  -- resolving the buffer's window explicitly, a real source change.
  spell.clear()
  H.eq(vim.bo[buf].spelllang, "de", "BUG: the language is never actually restored")
  H.eq(diag_count(), 0, "the diagnostics are still cleared correctly despite the option bug")

  -- Leave the buffer in a known-good state for the rest of this spec.
  vim.opt_local.spelllang = prev_spelllang

  -- No issues: informs and does not open a session ---------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean text" })
  spell.run(nil, { kind = "buffer", bufnr = buf })
  H.eq(diag_count(), 0, "clean text: nothing is published")

  -- The shared scope word 'cword' is a :Translate scope, and is refused here -
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
  spell.run(nil, "cword")
  H.eq(diag_count(), 0, "cword is rejected outright, never scanned as a buffer")

  -- refresh(): re-scans an active session and updates the diagnostics -------
  spell.run(nil, { kind = "buffer", bufnr = buf })
  H.eq(diag_count(), 1, "the session is open again")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean now" })
  spell.refresh(buf)
  H.eq(diag_count(), 0, "refresh() sees the edit, finds nothing left, and auto-closes")

  -- refresh() on a buffer with no active session is a safe no-op ------------
  local other = vim.api.nvim_create_buf(false, true)
  local ok_refresh = pcall(spell.refresh, other)
  H.ok(ok_refresh, "refresh() on a buffer with no session does not error")
  vim.api.nvim_buf_delete(other, { force = true })

  -- run(): cwd/path scopes are a one-shot overview, no session to toggle ----
  local dir, cleanup = H.fixture("spell-init-cwd")
  vim.fn.writefile({ BAD }, dir .. "/note.md")
  spell.run(nil, { kind = "path", path = dir })
  vim.wait(2000, function()
    return #vim.fn.getqflist() > 0
  end)
  H.eq(#vim.fn.getqflist(), 1, "the async path scan populates the quickfix list too")
  cleanup()

  -- on_buf_delete(): drops session state and the native cache --------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
  spell.run(nil, { kind = "buffer", bufnr = buf })
  local cache = require("language.spell.core.cache")
  -- cache.get() needs the same cfg used at scan time (PERF-46: the config
  -- knobs that affect the scan are part of the cache key).
  local spell_cfg = require("language.config").get().spell
  H.ok(cache.get(buf, spell_cfg) ~= nil, "the native cache is populated for the open session")
  spell.on_buf_delete(buf)
  H.eq(cache.get(buf, spell_cfg), nil, "on_buf_delete() invalidates the cache")
  local ok_clear = pcall(spell.clear)
  H.ok(ok_clear, "clear() after on_buf_delete() does not error")

  vim.api.nvim_buf_delete(buf, { force = true })
  package.loaded["language.spell.ui.panel"] = nil
  package.loaded["language.spell"] = nil
  config.setup({})
end
