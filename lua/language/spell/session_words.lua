---@module 'language.spell.session_words'
---@brief Adds many words to the session word list for the price of two.
---@description
--- `:spellgood!` appends one word to Neovim's internal word list -- a temp
--- file -- and then recompiles the WHOLE list. One command per word is one
--- compile per word: 310 words measured 1.2 s, in a single callback on the
--- main loop, at every start. The same words compiled once take 4 ms.
---
--- There is no command that takes a list, so the list is built in three steps:
---   1. the first word goes through `:spellgood!`, which creates the list file;
---   2. the words in between are appended to that file directly;
---   3. the last word goes through `:spellgood!` again, which appends it and
---      compiles everything that is in the file by then.
--- The result is exactly what one command per word would have left behind
--- (same file, same lines), so the semantics stay those of `zG`: session-only,
--- every 'spelllang', the user's 'spellfile' untouched.
---
--- Step 2 depends on finding the list file, which Neovim does not expose. It
--- is identified by what step 1 must have produced and confirmed by what step
--- 3 must have produced; whenever either check fails, the words go through
--- `:spellgood!` one at a time after all -- in slices, so that the slow path
--- costs time but never freezes the editor.

local M = {}

--- Longest stretch of main loop one slice of the slow path may take.
local SLICE_MS = 8

--- Neovim refuses longer words (MAXWLEN in spell_defs.h is 254 bytes).
local MAX_WORD_BYTES = 250

---@type string[]
local pending = {}
---@type table<string, true>
local seen = {}
---@type boolean
local scheduled = false

---The same test `:spellgood` applies (`valid_spell_word()`), because words
---written to the list file directly do not pass through it.
---@param word any
---@return boolean
local function valid(word)
  return type(word) == "string"
    and word ~= ""
    and #word <= MAX_WORD_BYTES
    and not word:find("%c")
    and word:sub(-1) ~= "/"
end

---@param word string
---@return boolean ok
local function spellgood(word)
  -- Table form: `word` is a real argument, never text spliced into a command
  -- line, so an entry like `x|let g:y=1` cannot chain a second Ex command.
  local command = { cmd = "spellgood", bang = true, args = { word }, mods = { silent = true } }
  return (pcall(vim.cmd, command))
end

---@param path string
---@return string[]|nil lines
local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

---Find the internal word list: the file in Neovim's temp directory that has a
---compiled sibling and ends with the word `:spellgood!` has just added.
---A field, so a test can make the lookup fail.
---@param last_word string
---@return string|nil path
function M._find_list(last_word)
  local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
  local suffix = "." .. vim.o.encoding .. ".spl"
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    if kind == "file" and name:sub(-4) ~= ".spl" and vim.uv.fs_stat(path .. suffix) then
      local lines = read(path)
      if lines and lines[#lines] == last_word then
        return path
      end
    end
  end
  return nil
end

---One `:spellgood!` per word, at most SLICE_MS at a time.
---@param words string[]
---@param from integer
---@return nil
local function add_slowly(words, from)
  local deadline = vim.uv.hrtime() + SLICE_MS * 1e6
  for i = from, #words do
    spellgood(words[i])
    if i < #words and vim.uv.hrtime() > deadline then
      vim.schedule(function()
        add_slowly(words, i + 1)
      end)
      return
    end
  end
end

---@param path string
---@param words string[]
---@param first integer
---@param last integer
---@return boolean ok
local function append(path, words, first, last)
  -- Binary mode: the list is read back with LF line ends on every platform.
  local fd = io.open(path, "ab")
  if not fd then
    return false
  end
  local ok = fd:write(table.concat(words, "\n", first, last), "\n")
  fd:close()
  return ok ~= nil
end

---@param words string[] valid, without duplicates, at least one
---@return nil
local function add_now(words)
  local n = #words
  if n < 3 or not spellgood(words[1]) then
    return add_slowly(words, 1)
  end

  local path = M._find_list(words[1])
  local before = path and read(path)
  if not (path and before and append(path, words, 2, n - 1)) then
    return add_slowly(words, 2)
  end

  -- Compiles the file, including what was appended to it, and tells whether
  -- `path` really is the list: Neovim has just written `words[n]` to the list,
  -- so it is the list exactly if that line arrived behind the appended ones.
  spellgood(words[n])
  local after = read(path)
  if not (after and #after == #before + n - 1 and after[#after] == words[n]) then
    return add_slowly(words, 2)
  end
end

---@return nil
local function flush()
  scheduled = false
  local words = pending
  pending = {}
  if #words > 0 then
    add_now(words)
  end
end

---Add words to the session word list (like `zG`, for every 'spelllang').
---Returns at once; the words arrive on the next main-loop tick, together with
---those of every other call made before it. Words already added in this
---session, and entries Neovim would refuse, are skipped.
---@param words any[]|nil
---@return nil
function M.add(words)
  if type(words) ~= "table" then
    return
  end
  for _, word in ipairs(words) do
    if valid(word) and not seen[word] then
      seen[word] = true
      pending[#pending + 1] = word
    end
  end
  if #pending > 0 and not scheduled then
    scheduled = true
    vim.schedule(flush)
  end
end

return M
