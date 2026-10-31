-- TESTS/harness.lua — tiny assertion helper shared by the spec files.
-- Handed to each spec by testing.nvim (dialect "h", see .testing.lua).

local H = {}

--- Assert equality; raises a descriptive error on mismatch (caught by the runner).
---@param a any # actual
---@param b any # expected
---@param msg string|nil
function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

--- Assert a truthy value.
---@param v any
---@param msg string|nil
function H.ok(v, msg)
  if not v then
    error(("FAIL %s: expected truthy, got %q"):format(msg or "", tostring(v)), 2)
  end
end

--- Assert a falsy value.
---@param v any
---@param msg string|nil
function H.falsy(v, msg)
  if v then
    error(("FAIL %s: expected falsy, got %q"):format(msg or "", tostring(v)), 2)
  end
end

--- Assert that `haystack` contains `needle` as a literal substring.
---@param haystack string
---@param needle string
---@param msg string|nil
function H.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(("FAIL %s: %q does not contain %q"):format(msg or "", tostring(haystack), needle), 2)
  end
end

--- Assert that `haystack` does NOT contain `needle`.
---@param haystack string
---@param needle string
---@param msg string|nil
function H.excludes(haystack, needle, msg)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error(("FAIL %s: %q still contains %q"):format(msg or "", tostring(haystack), needle), 2)
  end
end

--- A scratch directory inside the repository, removed by `cleanup()`.
---
--- Inside the repo rather than in `vim.fn.tempname()` on purpose: on Windows
--- the temp path carries an 8.3 short component (`STEFAN~1`), which several
--- Vim path builtins do not see through -- a fixture there would pass on Linux
--- and quietly assert nothing locally.
---@param name string
---@return string dir, fun() cleanup
function H.fixture(name)
  local dir = vim.fs.normalize(vim.fn.getcwd()) .. "/TESTS/.fixture-" .. name
  vim.fn.delete(dir, "rf")
  vim.fn.mkdir(dir, "p")
  return dir, function()
    vim.fn.delete(dir, "rf")
  end
end

local KEYMAP_MODES = { "n", "i", "x", "s", "o", "c", "t", "l" }

---@return table<string, true>
local function keymap_set()
  local set = {}
  for _, mode in ipairs(KEYMAP_MODES) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      set[mode .. "\0" .. m.lhs] = true
    end
  end
  return set
end

---@return table<integer, true>
local function autocmd_ids()
  local set = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
    if a.id then
      set[a.id] = true
    end
  end
  return set
end

---@generic T
---@param list T[]
---@return table<T, true>
local function to_set(list)
  local set = {}
  for _, v in ipairs(list) do
    set[v] = true
  end
  return set
end

--- Record the editor state a spec is about to change, and return a function
--- that puts it back: buffers and windows created since are wiped / closed,
--- user commands, global keymaps and autocmds created since are deleted, and
--- the named global options get their old value back.
---
--- The suite runs every spec file in one editor (`isolated = "none"`), so what
--- one file leaves (`setup()`'s :Commands, the language_nvim autocmds, scratch
--- buffers) would otherwise reach the next one; the state guard of
--- testing.nvim reports it as a leak.
---@param opts? { options?: string[] }
---@return fun()
function H.track(opts)
  local options = {}
  for _, name in ipairs((opts or {}).options or {}) do
    options[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  local wins = to_set(vim.api.nvim_list_wins())
  local bufs = to_set(vim.api.nvim_list_bufs())
  local cmds = vim.api.nvim_get_commands({})
  local maps = keymap_set()
  local aus = autocmd_ids()
  local start_win = vim.api.nvim_get_current_win()

  return function()
    if vim.api.nvim_win_is_valid(start_win) then
      pcall(vim.api.nvim_set_current_win, start_win)
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if not wins[win] then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not bufs[buf] then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    for name in pairs(vim.api.nvim_get_commands({})) do
      if not cmds[name] then
        pcall(vim.api.nvim_del_user_command, name)
      end
    end
    for _, mode in ipairs(KEYMAP_MODES) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        if not maps[mode .. "\0" .. m.lhs] then
          pcall(vim.api.nvim_del_keymap, mode, m.lhs)
        end
      end
    end
    for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
      if a.id and not aus[a.id] then
        pcall(vim.api.nvim_del_autocmd, a.id)
      end
    end
    for name, value in pairs(options) do
      vim.api.nvim_set_option_value(name, value, { scope = "global" })
    end
  end
end

--- Read a file back as one string.
---@param path string
---@return string
function H.read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return table.concat(lines, "\n")
end

return H
