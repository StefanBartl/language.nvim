---@module 'language.spell.providers.native'
---@brief Native spell provider built on Neovim's own `vim.spell.check`.
---@description
--- Always available (no external tools). Respects the window `spelllang`.
--- Scope-aware: buffer/visible/selection scan line ranges of an open buffer;
--- cwd/path scan text files (open buffers preferred; unopened files are read
--- with `vim.fn.readfile`).
---
--- Phase-5 additions (all config-gated):
---   • word_split — split CamelCase/snake_case tokens and only report real
---     misspelled subwords (precise spans), dropping code-identifier false
---     positives.
---   • regions.skip_urls / skip_emails — drop errors inside URL/email spans.
---   • skip_readonly — never scan readonly buffers.

require("language.spell.@types")

local api = vim.api
local fn = vim.fn

local split = require("language.spell.core.split")

local M = {}

M.name = "native"
M.supports = { buffer = true, cwd = true, grammar = false }

---Map a `vim.spell.check` error type to the issue `kind`.
---@type table<string, LanguageSpellKind>
local KIND = { bad = "spell", rare = "rare", caps = "caps", ["local"] = "spell" }

---Text-file extensions considered when scanning cwd/path directories.
---@type table<string, true>
local TEXT_EXT = {
  lua = true,
  md = true,
  txt = true,
  rst = true,
  vim = true,
  toml = true,
  yaml = true,
  yml = true,
  json = true,
  ts = true,
  js = true,
  py = true,
  sh = true,
  zsh = true,
  fish = true,
  c = true,
  cpp = true,
  h = true,
  go = true,
  rs = true,
  java = true,
  rb = true,
  html = true,
  css = true,
  tex = true,
  bib = true,
  adoc = true,
  asciidoc = true,
}

---Is the native spell API present?
---@return boolean
function M.available()
  return type(vim.spell) == "table" and type(vim.spell.check) == "function"
end

---Whole-word "is this misspelled" check for a lone (sub)word.
---@param word string
---@return boolean
local function is_bad(word)
  local errs = vim.spell.check(word)
  return #errs > 0 and errs[1][1] == word
end

---Compute 1-based [start,end) byte spans on `line` that should be skipped
---(URLs, emails) per config. Returns nil when nothing is configured.
---@param line string
---@param regions LanguageSpellRegionsCfg
---@return { [1]: integer, [2]: integer }[]|nil
local function skip_spans(line, regions)
  if not (regions and (regions.skip_urls or regions.skip_emails)) then
    return nil
  end
  local spans = {}
  if regions.skip_urls then
    for s, e in line:gmatch("()%a[%w+.%-]*://[%w./%-_?=&#%%~:@!$'()*+,;]+()") do
      spans[#spans + 1] = { s, e }
    end
    for s, e in line:gmatch("()www%.[%w./%-_?=&#%%~:@]+()") do
      spans[#spans + 1] = { s, e }
    end
  end
  if regions.skip_emails then
    for s, e in line:gmatch("()[%w._%%+%-]+@[%w.%-]+%.%a%a+()") do
      spans[#spans + 1] = { s, e }
    end
  end
  return #spans > 0 and spans or nil
end

---@param col integer                     1-based
---@param spans { [1]: integer, [2]: integer }[]|nil
---@return boolean
local function in_skip_span(col, spans)
  if not spans then
    return false
  end
  for _, sp in ipairs(spans) do
    if col >= sp[1] and col < sp[2] then
      return true
    end
  end
  return false
end

---Build a single issue.
---@param word string
---@param kind_key string
---@param col integer                     1-based byte column
---@param lnum integer
---@param bufnr integer|nil
---@param path string
---@return LanguageSpellIssue
local function make_issue(word, kind_key, col, lnum, bufnr, path)
  return {
    bufnr = bufnr,
    path = path,
    lnum = lnum,
    col = col,
    end_col = col + #word,
    word = word,
    kind = KIND[kind_key] or "spell",
    source = "native",
  }
end

---Expand a flagged token into precise subword issues (word_split). Returns true
---if at least one real misspelling was emitted; false means the token was a
---code-identifier false positive and should be dropped.
---@param word string
---@param kind_key string
---@param col integer
---@param lnum integer
---@param bufnr integer|nil
---@param path string
---@param min_length integer
---@param out LanguageSpellIssue[]
---@return boolean emitted
local function emit_split(word, kind_key, col, lnum, bufnr, path, min_length, out)
  local emitted = false
  for _, part in ipairs(split.split(word)) do
    if #part.sub >= min_length and is_bad(part.sub) then
      out[#out + 1] = make_issue(part.sub, kind_key, col + part.offset, lnum, bufnr, path)
      emitted = true
    end
  end
  return emitted
end

---Scan a list of lines, appending issues to `out`.
---@param lines string[]
---@param first_lnum integer
---@param bufnr integer|nil
---@param path string
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
---@param spellable? fun(lnum: integer, col: integer): boolean  # nil = treat all text as spellable
local function scan_lines(lines, first_lnum, bufnr, path, out, cfg, spellable)
  local check = vim.spell.check
  local ws = cfg.word_split or {}
  local do_split = ws.enable == true
  local min_length = ws.min_length or 4
  local regions = cfg.regions

  for i = 1, #lines do
    local line = lines[i]
    local errs = check(line)
    if #errs > 0 then
      local spans = skip_spans(line, regions)
      local lnum = first_lnum + i - 1
      for j = 1, #errs do
        local entry = errs[j]
        local word, kind_key, col = entry[1], entry[2], entry[3] or 1
        if col < 1 then
          col = 1
        end
        if not in_skip_span(col, spans) and (not spellable or spellable(lnum, col)) then
          if do_split and split.is_compound(word) then
            emit_split(word, kind_key, col, lnum, bufnr, path, min_length, out)
          else
            out[#out + 1] = make_issue(word, kind_key, col, lnum, bufnr, path)
          end
        end
      end
    end
  end
end

---Should this buffer be scanned at all (readonly gate)?
---@param bufnr integer
---@param cfg LanguageSpellCfg
---@return boolean
local function scannable(bufnr, cfg)
  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if cfg.skip_readonly then
    local ok, ro = pcall(api.nvim_get_option_value, "readonly", { buf = bufnr })
    if ok and ro then
      return false
    end
  end
  return true
end

---Build a spellable-position predicate from Treesitter @spell regions, or nil
---when region restriction is disabled/unavailable (then all text is spellable).
---@param bufnr integer
---@param cfg LanguageSpellCfg
---@return (fun(lnum: integer, col: integer): boolean)|nil
local function region_predicate(bufnr, cfg)
  if not (cfg.regions and cfg.regions.treesitter_spell) then
    return nil
  end
  local regions = require("language.spell.core.regions").build(bufnr)
  if not regions then
    return nil
  end
  local is_spellable = require("language.spell.core.regions").is_spellable
  return function(lnum, col)
    return is_spellable(regions, lnum, col)
  end
end

---Collect issues from a buffer line range (1-based, inclusive).
---@param bufnr integer
---@param s integer
---@param e integer
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
local function collect_buf_range(bufnr, s, e, out, cfg)
  if not scannable(bufnr, cfg) then
    return
  end
  local total = api.nvim_buf_line_count(bufnr)
  s = math.max(1, s)
  e = math.min(total, e)
  if e < s then
    return
  end
  local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local spellable = region_predicate(bufnr, cfg)
  scan_lines(lines, s, bufnr, api.nvim_buf_get_name(bufnr), out, cfg, spellable)
end

---Collect issues from a file on disk (not necessarily loaded).
---@param path string
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
local function collect_file(path, out, cfg)
  if fn.filereadable(path) ~= 1 then
    return
  end
  local ok, lines = pcall(fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return
  end
  -- Unloaded files have no attached parser; scan all text (no region predicate).
  scan_lines(lines, 1, nil, path, out, cfg, nil)
end

---Iterate loaded, listed buffers whose path is under `prefix`.
---@param prefix string
---@param out LanguageSpellIssue[]
---@param cfg LanguageSpellCfg
local function collect_loaded_under(prefix, out, cfg)
  prefix = prefix:gsub("[/\\]+$", "")
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      local bt = api.nvim_get_option_value("buftype", { buf = bufnr })
      local path = api.nvim_buf_get_name(bufnr)
      if bt == "" and path ~= "" and path:sub(1, #prefix) == prefix then
        local ext = path:match("%.([^.]+)$")
        if not ext or TEXT_EXT[ext] then
          collect_buf_range(bufnr, 1, api.nvim_buf_line_count(bufnr), out, cfg)
        end
      end
    end
  end
end

---Scan the given scope and return all native spell issues.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan_scope(scope, cfg)
  ---@type LanguageSpellIssue[]
  local out = {}
  local kind = scope.kind

  if kind == "buffer" then
    local b = scope.bufnr or api.nvim_get_current_buf()
    collect_buf_range(b, 1, api.nvim_buf_line_count(b), out, cfg)
  elseif kind == "visible" or kind == "selection" then
    local b = scope.bufnr or api.nvim_get_current_buf()
    local r = scope.range or { s = 1, e = api.nvim_buf_line_count(b) }
    collect_buf_range(b, r.s, r.e, out, cfg)
  elseif kind == "cwd" then
    collect_loaded_under(fn.getcwd(), out, cfg)
  elseif kind == "path" then
    local path = scope.path or fn.getcwd()
    if fn.isdirectory(path) == 1 then
      collect_loaded_under(path, out, cfg)
    else
      collect_file(path, out, cfg)
    end
  end

  return out
end

---Native suggestions for an issue's word via `spellsuggest`.
---@param issue LanguageSpellIssue
---@return string[]
function M.suggest(issue)
  if type(issue) ~= "table" or type(issue.word) ~= "string" then
    return {}
  end
  local ok, res = pcall(fn.spellsuggest, issue.word, 10)
  if ok and type(res) == "table" then
    return res
  end
  return {}
end

return M
