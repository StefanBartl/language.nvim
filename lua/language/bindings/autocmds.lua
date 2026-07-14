---@module 'language.bindings.autocmds'
---@brief Autocommands: per-buffer spell-session GC and optional live scan.
---@description
--- Event-bundled under a single augroup (Zentrale-Prinzipien §1/§4). The live
--- scan is opt-in (`spell.live`) and debounced; it is only armed when enabled
--- so there is no overhead otherwise. Live scanning is decoupled from the
--- on-demand panel/session — it keeps inline diagnostics fresh for configured
--- filetypes as you edit (see `language.spell.live`).
local M = {}

---@param cfg LanguageConfig
---@return nil
function M.setup(cfg)
  local spell_cfg = cfg.spell or {}
  local group = vim.api.nvim_create_augroup("language_nvim", { clear = true })

  -- Garbage-collect per-buffer spell-session state when a buffer is deleted,
  -- and detach any live diagnostics.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      local ok, spell = pcall(require, "language.spell")
      if ok and type(spell.on_buf_delete) == "function" then
        spell.on_buf_delete(ev.buf)
      end
      local ok_live, live = pcall(require, "language.spell.live")
      if ok_live then
        live.detach(ev.buf)
      end
    end,
    desc = "[language] GC spell state / detach live diagnostics",
  })

  -- Optional debounced live scan (opt-in). Decoupled from sessions: it scans
  -- configured filetypes and publishes inline diagnostics as you edit.
  if spell_cfg.live then
    local function live_scan(ev)
      local ok, live = pcall(require, "language.spell.live")
      if ok then
        live.scan(ev.buf)
      end
    end
    local function live_change(ev)
      local ok, live = pcall(require, "language.spell.live")
      if ok then
        live.on_change(ev.buf)
      end
    end

    -- Initial scan when a matching buffer becomes visible / gets its filetype.
    vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType" }, {
      group = group,
      callback = function(ev)
        vim.schedule(function()
          live_scan(ev)
        end)
      end,
      desc = "[language] Live spell scan on enter",
    })

    -- Rescan on edits.
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      group = group,
      callback = live_change,
      desc = "[language] Debounced live spell scan on change",
    })

    -- Follow the viewport when scanning only the visible range.
    if spell_cfg.live_scope == "visible" then
      vim.api.nvim_create_autocmd("WinScrolled", {
        group = group,
        callback = live_change,
        desc = "[language] Live spell rescan on scroll (visible scope)",
      })
    end
  end
end

return M
