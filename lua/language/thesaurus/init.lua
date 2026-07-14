---@module 'language.thesaurus'
---@brief Synonym lookup + replace the word under the cursor (writing aid).
---@description
--- Looks up synonyms for a word and lets you replace the word under the cursor
--- with a chosen one. Default source is the free, keyless Datamuse API
--- (`rel_syn`), queried async via the argv job runner; set `thesaurus.custom`
--- for a different source/language. Idea from vim-lexical.

local api = vim.api

local M = {}

---@return LanguageThesaurusCfg
local function cfg()
  return require("language.config").get().thesaurus
end

---Parse Datamuse JSON (`[{"word":...}, ...]`) into a synonym list.
---@param body string
---@param max integer
---@return string[]
function M.parse_datamuse(body, max)
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  local out = {}
  for i = 1, #decoded do
    local w = decoded[i] and decoded[i].word
    if type(w) == "string" and w ~= "" then
      out[#out + 1] = w
      if #out >= max then
        break
      end
    end
  end
  return out
end

---Fetch synonyms for `word`, delivering them via `cb`.
---@param word string
---@param cb fun(synonyms: string[])
---@return nil
function M.synonyms(word, cb)
  local c = cfg()
  if type(word) ~= "string" or word == "" then
    cb({})
    return
  end

  if c.source == "custom" and type(c.custom) == "function" then
    local ok = pcall(c.custom, word, function(syns)
      cb(type(syns) == "table" and syns or {})
    end)
    if not ok then
      cb({})
    end
    return
  end

  if vim.fn.executable("curl") ~= 1 then
    require("lib.nvim.notify").create("[language.thesaurus]").error("curl not found")
    cb({})
    return
  end

  -- `-G` appends the url-encoded rel_syn as a query param; the base URL must not
  -- already contain rel_syn or Datamuse sees a duplicate (empty) one first.
  local url = ("https://api.datamuse.com/words?max=%d"):format(c.max or 20)
  local argv = { "curl", "-s", "-G", "--data-urlencode", "rel_syn=" .. word, url }
  require("language.util.job").run(argv, {
    timeout_ms = c.timeout_ms or 6000,
    on_done = function(ok, out, _err)
      if not ok then
        cb({})
        return
      end
      cb(M.parse_datamuse(out or "", c.max or 20))
    end,
  })
end

---Find the word under the cursor and its byte span on the current line.
---@return string word, integer sr, integer sc, integer er, integer ec  -- 0-based, end-exclusive
function M.word_under_cursor()
  local pos = api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local line = api.nvim_get_current_line()
  if line == "" then
    return "", row, col, row, col
  end
  -- Expand [%w_'] around the cursor (1-based string indexing).
  local i = col + 1
  local n = #line
  local function is_word(ch)
    return ch ~= "" and ch:match("[%w_']") ~= nil
  end
  -- If the cursor sits just past the word end, step back onto it.
  if not is_word(line:sub(i, i)) and i > 1 and is_word(line:sub(i - 1, i - 1)) then
    i = i - 1
  end
  local s = i
  while s > 1 and is_word(line:sub(s - 1, s - 1)) do
    s = s - 1
  end
  local e = i
  while e < n and is_word(line:sub(e + 1, e + 1)) do
    e = e + 1
  end
  if not is_word(line:sub(i, i)) then
    return "", row, col, row, col
  end
  return line:sub(s, e), row, s - 1, row, e
end

---Replace the word under the cursor with a synonym picked from a list.
---@return nil
function M.replace_under_cursor()
  if not cfg().enable then
    return
  end
  local notify = require("lib.nvim.notify").create("[language.thesaurus]")
  local word, sr, sc, er, ec = M.word_under_cursor()
  if word == "" then
    notify.info("No word under cursor")
    return
  end
  local bufnr = api.nvim_get_current_buf()
  M.synonyms(word, function(syns)
    if #syns == 0 then
      notify.info(("No synonyms for '%s'"):format(word))
      return
    end
    require("lib.nvim.ui.kit").select({
      items = syns,
      title = "Synonyms for '" .. word .. "'",
      on_select = function(item)
        if type(item) == "string" and item ~= "" and api.nvim_buf_is_valid(bufnr) then
          pcall(api.nvim_buf_set_text, bufnr, sr, sc, er, ec, { item })
        end
      end,
    })
  end)
end

return M
