-- TESTS/live_spec.lua — language.spell.live: the always-on, debounced
-- diagnostics gate (should_scan) and the scan/detach lifecycle. Real timers,
-- real buffers — the debounce is exercised with vim.wait rather than mocked.

return function(H)
  local config = require("language.config")
  local live = require("language.spell.live")

  -- Not a scratch buffer: `should_scan` gates on buftype == "", and
  -- `nvim_create_buf(_, true)` would set buftype=nofile, which fails that
  -- gate before any of the assertions below get to exercise it.
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one two three" })

  -- should_scan gates ---------------------------------------------------------
  config.setup({ spell = { live = false } })
  H.falsy(live.should_scan(buf), "live = false: never scan")

  config.setup({
    spell = {
      live = true,
      filetypes = { "markdown" },
      max_file_lines = 20000,
    },
  })
  H.ok(live.should_scan(buf), "a matching filetype, under the line cap: scan")

  vim.bo[buf].filetype = "javascript"
  H.falsy(live.should_scan(buf), "an unconfigured filetype: do not scan")
  vim.bo[buf].filetype = "markdown"

  config.setup({ spell = { live = true, filetypes = { "markdown" }, max_file_lines = 0 } })
  H.falsy(live.should_scan(buf), "over max_file_lines: do not scan")

  config.setup({ spell = { live = true, filetypes = { "markdown" }, max_file_lines = 20000 } })
  H.falsy(live.should_scan(-1), "an invalid buffer is never scanned")

  local scratch_buftype = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch_buftype].filetype = "markdown"
  vim.bo[scratch_buftype].buftype = "nofile"
  H.falsy(live.should_scan(scratch_buftype), "a special buftype (nofile) is never scanned")
  vim.api.nvim_buf_delete(scratch_buftype, { force = true })

  -- scan() publishes diagnostics through the same namespace as list.lua -----
  local BAD = "zzqqxxlivetest"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
  local list = require("language.spell.ui.list")
  live.scan(buf)
  local diags = vim.diagnostic.get(buf, { namespace = list.ns })
  H.eq(#diags, 1, "scan() publishes the flagged word as a diagnostic")

  -- on_change debounces: scheduling twice in quick succession still only
  -- rescans once, after the configured delay.
  config.setup({
    spell = {
      live = true,
      filetypes = { "markdown" },
      max_file_lines = 20000,
      scan_debounce_ms = 30,
    },
  })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean now" })
  live.on_change(buf)
  live.on_change(buf) -- restarts the same timer rather than firing twice
  vim.wait(500, function()
    return #vim.diagnostic.get(buf, { namespace = list.ns }) == 0
  end)
  H.eq(#vim.diagnostic.get(buf, { namespace = list.ns }), 0, "the debounced rescan sees the edit")

  -- detach() clears diagnostics and stops the timer -------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD })
  live.scan(buf)
  H.ok(#vim.diagnostic.get(buf, { namespace = list.ns }) > 0, "re-scanned before detaching")
  live.detach(buf)
  H.eq(#vim.diagnostic.get(buf, { namespace = list.ns }), 0, "detach() clears the diagnostics")

  -- detach() on a buffer that was never attached is a safe no-op.
  local other = vim.api.nvim_create_buf(false, true)
  live.detach(other)
  vim.api.nvim_buf_delete(other, { force = true })

  vim.api.nvim_buf_delete(buf, { force = true })
  config.setup({})
end
