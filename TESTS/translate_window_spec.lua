-- TESTS/translate_window_spec.lua — language.translate.window: the live
-- refresh on input change is debounced (one refresh per burst of edits) and
-- close() stops a pending one. Real timers, waited on with vim.wait.

return function(H)
  H.tracked(function()
    local window = require("language.translate.window")

    local refreshed = 0
    local real_refresh = window.refresh
    window.refresh = function()
      refreshed = refreshed + 1
    end

    window.open({ target = "EN" })
    local buf = window._state().input_buf
    H.ok(buf and vim.api.nvim_buf_is_valid(buf), "the input buffer exists")

    local function edit()
      vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    end

    -- A burst of edits costs one refresh, after the quiet period.
    edit()
    edit()
    edit()
    H.eq(refreshed, 0, "nothing refreshes while the edits keep coming")
    vim.wait(1000, function()
      return refreshed > 0
    end, 20)
    vim.wait(400)
    H.eq(refreshed, 1, "one refresh for the whole burst")

    -- close() cancels a pending refresh and may be called again.
    edit()
    window.close()
    vim.wait(600)
    H.eq(refreshed, 1, "a closed window does not refresh")
    window.close()

    window.refresh = real_refresh
  end)
end
