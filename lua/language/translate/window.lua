---@module 'language.translate.window'
---@brief Interactive translation window (type source, see live translation).
---@description
--- Two stacked floating windows: an editable input (top) and a read-only output
--- (bottom). Typing debounces a translation via the configured engine and fills
--- the output. Idea from pantran.nvim.
---
--- Keys (input window): <C-y> copy translation, <C-l> change target language,
--- q / <Esc> (normal) or <C-c> (insert) close.

local api = vim.api

local M = {}

---@class Language.Translate.WinState
---@field input_buf integer|nil
---@field input_win integer|nil
---@field output_buf integer|nil
---@field output_win integer|nil
---@field target string|nil
---@field timer uv.uv_timer_t|nil
---@field job Language.Job|nil

---@type Language.Translate.WinState
local state = {}

---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---@param win integer|nil
local function win_valid(win)
  return win and api.nvim_win_is_valid(win)
end

---Tear down the window and all its resources (idempotent).
---@return nil
function M.close()
  if state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
  end
  if state.job then
    pcall(state.job.cancel)
  end
  for _, win in ipairs({ state.input_win, state.output_win }) do
    if win_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  state = {}
end

---@return boolean
function M.is_open()
  return win_valid(state.input_win) or win_valid(state.output_win)
end

---Internal state accessor (for tests).
---@return Language.Translate.WinState
function M._state()
  return state
end

---Set the output window's lines (read-only buffer).
---@param lines string[]
local function set_output(lines)
  if not (state.output_buf and api.nvim_buf_is_valid(state.output_buf)) then
    return
  end
  api.nvim_set_option_value("modifiable", true, { buf = state.output_buf })
  api.nvim_buf_set_lines(state.output_buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = state.output_buf })
end

---Translate the current input immediately into the output window.
---@return nil
function M.refresh()
  if not (state.input_buf and api.nvim_buf_is_valid(state.input_buf)) then
    return
  end
  local lines = api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    set_output({})
    return
  end

  local provider, err = require("language.translate.providers.registry").resolve(cfg())
  if not provider then
    set_output({ "(" .. (err or "no engine") .. ")" })
    return
  end

  if state.job then
    pcall(state.job.cancel)
  end
  set_output({ "…" })
  state.job = provider.translate(lines, state.target, nil, cfg(), function(ok, result)
    if not M.is_open() then
      return
    end
    if ok then
      ---@cast result string[]
      set_output(result)
    else
      set_output({ "(error: " .. tostring(result) .. ")" })
    end
  end)
end

---Debounced refresh on input change.
local function on_change()
  local delay = cfg().timeout_ms and 300 or 300
  if not state.timer then
    state.timer = vim.uv.new_timer()
  end
  state.timer:stop()
  state.timer:start(delay, 0, vim.schedule_wrap(M.refresh))
end

---Update the target language and re-translate.
---@param target string
function M.retarget(target)
  if type(target) ~= "string" or target == "" then
    return
  end
  state.target = target
  if win_valid(state.input_win) then
    pcall(api.nvim_win_set_config, state.input_win, { title = " Translate → " .. target .. " " })
  end
  M.refresh()
end

---Open a picker to change the target language.
local function pick_retarget()
  require("lib.nvim.ui.kit").select({
    items = cfg().default_langs or { "EN", "DE" },
    title = "Translate to…",
    on_select = function(item)
      if type(item) == "string" and item ~= "" then
        M.retarget(item)
      end
    end,
  })
end

---Create the two floating windows for `target`, prefilled with `source_lines`.
---@param target string
---@param source_lines string[]|nil
local function launch(target, source_lines)
  M.close()
  state.target = target

  local width = math.max(30, math.floor(vim.o.columns * 0.6))
  local height = math.max(3, math.floor(vim.o.lines * 0.25))
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - (2 * height + 4)) / 2)

  state.input_buf = api.nvim_create_buf(false, true)
  state.output_buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("modifiable", false, { buf = state.output_buf })
  if source_lines and #source_lines > 0 then
    api.nvim_buf_set_lines(state.input_buf, 0, -1, false, source_lines)
  end

  state.output_win = api.nvim_open_win(state.output_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row + height + 2,
    style = "minimal",
    border = "rounded",
    title = " translation ",
    zindex = 50,
  })
  state.input_win = api.nvim_open_win(state.input_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Translate → " .. target .. " ",
    zindex = 51,
  })

  local mo = { buffer = state.input_buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", M.close, mo)
  vim.keymap.set("n", "<Esc>", M.close, mo)
  vim.keymap.set("i", "<C-c>", M.close, mo)
  vim.keymap.set({ "n", "i" }, "<C-l>", pick_retarget, mo)
  vim.keymap.set({ "n", "i" }, "<C-y>", function()
    local out = api.nvim_buf_get_lines(state.output_buf, 0, -1, false)
    local text = table.concat(out, "\n")
    pcall(vim.fn.setreg, "+", text)
    pcall(vim.fn.setreg, '"', text)
    require("lib.nvim.notify").create("[language.translate]").info("Translation copied")
  end, mo)

  local group = api.nvim_create_augroup("language_translate_window", { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = state.input_buf,
    callback = on_change,
    desc = "[language] live translate on input change",
  })
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if tonumber(ev.match) == state.input_win then
        M.close()
      end
    end,
    desc = "[language] close translate window",
  })

  if source_lines and #source_lines > 0 then
    M.refresh()
  end
  vim.cmd("startinsert")
end

---Open the interactive translation window.
---@param opts { target?: string, source_lines?: string[] }|nil
---@return nil
function M.open(opts)
  opts = opts or {}
  local target = opts.target or cfg().default_target
  if type(target) == "string" and target ~= "" then
    launch(target, opts.source_lines)
    return
  end
  require("lib.nvim.ui.kit").select({
    items = cfg().default_langs or { "EN", "DE" },
    title = "Translate to…",
    on_select = function(item)
      if type(item) == "string" and item ~= "" then
        launch(item, opts.source_lines)
      end
    end,
  })
end

return M
