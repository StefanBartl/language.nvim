---@module 'language.bindings.autocmds'
---@brief Autocommands: per-buffer spell-session GC and optional live scan.
---@description
--- Event-bundled under a single augroup (Zentrale-Prinzipien §1/§4). The live
--- scan is opt-in (`spell.live`) and debounced; it is only armed when enabled
--- to avoid overhead on every buffer.
local M = {}

---@param cfg LanguageConfig
---@return nil
function M.setup(cfg)
  local spell_cfg = cfg.spell or {}

  local group = vim.api.nvim_create_augroup("language_nvim", { clear = true })

  -- Garbage-collect per-buffer spell state when a buffer is deleted.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      local ok, spell = pcall(require, "language.spell")
      if ok and type(spell.on_buf_delete) == "function" then
        spell.on_buf_delete(ev.buf)
      end
    end,
    desc = "[language] GC spell state for deleted buffers",
  })

  -- Optional debounced live scan (opt-in).
  if spell_cfg.live then
    vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
      group = group,
      callback = function(ev)
        local ok, spell = pcall(require, "language.spell")
        if ok and type(spell.on_text_changed) == "function" then
          spell.on_text_changed(ev.buf)
        end
      end,
      desc = "[language] Debounced live spell scan",
    })
  end
end

return M
