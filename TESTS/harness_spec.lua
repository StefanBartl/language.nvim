-- TESTS/harness_spec.lua — the harness's own state helpers: H.track puts back
-- global keymaps and user commands a spec replaced or removed (not only the
-- ones it added), and H.tracked restores even when the body fails half-way.

return function(H)
  local LHS = "<Plug>(language-harness-probe)"
  local CMD = "LanguageHarnessProbe"

  ---@return table|nil
  local function probe_map()
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == LHS then
        return m
      end
    end
  end

  local function original_map() end
  local function original_cmd() end

  -- A pre-existing global map and command, as another plugin would own them.
  vim.keymap.set("n", LHS, original_map, { desc = "original map" })
  vim.api.nvim_create_user_command(
    CMD,
    original_cmd,
    { nargs = "?", bang = true, desc = "original cmd" }
  )

  -- Replaced inside the tracked window: the original comes back ------------
  local restore = H.track()
  vim.keymap.set("n", LHS, function() end, { desc = "replacement" })
  vim.api.nvim_create_user_command(CMD, function() end, { desc = "replacement" })
  restore()
  H.eq(
    probe_map() and probe_map().callback,
    original_map,
    "a replaced map gets its old callback back"
  )
  H.eq(probe_map() and probe_map().desc, "original map", "and its old desc")
  local cmd = vim.api.nvim_get_commands({})[CMD]
  H.eq(cmd and cmd.callback, original_cmd, "a replaced command gets its old callback back")
  H.eq(cmd and cmd.nargs, "?", "with its old nargs")
  H.eq(cmd and cmd.bang, true, "and its old bang")

  -- Removed inside the tracked window: it is set again ---------------------
  restore = H.track()
  vim.api.nvim_del_keymap("n", LHS)
  vim.api.nvim_del_user_command(CMD)
  restore()
  H.eq(probe_map() and probe_map().callback, original_map, "a removed map is set again")
  cmd = vim.api.nvim_get_commands({})[CMD]
  H.eq(cmd and cmd.callback, original_cmd, "a removed command is created again")
  H.eq(cmd and cmd.definition, "original cmd", "with its desc")

  -- H.tracked: a failing body is still restored, and its error survives ----
  local bufs = #vim.api.nvim_list_bufs()
  local opfunc = vim.o.operatorfunc
  local ok, err = pcall(H.tracked, { options = { "operatorfunc" } }, function()
    vim.api.nvim_create_buf(false, true)
    vim.o.operatorfunc = "v:lua.harness_probe"
    vim.keymap.set("n", LHS, function() end)
    vim.api.nvim_create_user_command("LanguageHarnessProbeAdded", "echo", {})
    vim.api.nvim_create_autocmd(
      "User",
      { pattern = "LanguageHarnessProbe", callback = function() end }
    )
    H.eq(1, 2, "deliberate")
  end)
  H.falsy(ok, "H.tracked raises the body's error again")
  H.contains(tostring(err), "FAIL deliberate", "unchanged")
  H.eq(#vim.api.nvim_list_bufs(), bufs, "the scratch buffer of the failed body is gone")
  H.eq(vim.o.operatorfunc, opfunc, "the option is back")
  H.eq(probe_map() and probe_map().callback, original_map, "the map is back")
  H.eq(vim.fn.exists(":LanguageHarnessProbeAdded"), 0, "the added command is gone")
  H.eq(
    #vim.api.nvim_get_autocmds({ event = "User", pattern = "LanguageHarnessProbe" }),
    0,
    "the autocmd is gone"
  )

  -- A passing body runs, once, without opts.
  local runs = 0
  H.tracked(function()
    runs = runs + 1
  end)
  H.eq(runs, 1, "H.tracked runs the body once")

  vim.api.nvim_del_keymap("n", LHS)
  vim.api.nvim_del_user_command(CMD)
end
