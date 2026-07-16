---@module 'language.bindings.usrcmds'
---@brief Registers the top-level commands: :Spellcheck, :Translate,
---@brief :TranslateReplace.
---@description
--- All commands parse their target through `language.scope` and dispatch to
--- the respective domain module. Registration uses lib.nvim.usercmd when
--- available, falling back to the raw API otherwise.

require("language.config.@types")

local M = {}

local SPELL_SCOPES = { "buffer", "visible", "cwd", "clear", "refresh" }
local SPELL_LANGS = { "en", "de", "fr", "es", "it", "pt", "nl", "en,de" }
local TR_FLAGS = {
  "--nocode",
  "--output=popup",
  "--output=replace",
  "--output=buffer",
  "--output=vsplit",
  "--output=split",
  "--output=tab",
  "--output=insert",
  "--output=clipboard",
  "--output=notify",
  "--files=suffix",
  "--files=replace",
  "--files=buffers",
}
local TR_REPLACE_FLAGS = { "--nocode" }
local TR_LANGS = { "EN", "DE", "FR", "ZH", "JA", "ES", "IT" }
local TR_SCOPES = { "selection", "buffer", "cwd" }

---Register a command via lib.nvim.usercmd, falling back to the raw API.
---@param name string
---@param cb fun(o: table)
---@param opts table
local function usercmd(name, cb, opts)
  local ok, mod = pcall(require, "lib.nvim.usercmd")
  if ok and type(mod.create) == "function" then
    mod.create(name, cb, opts)
  else
    vim.api.nvim_create_user_command(name, cb, opts)
  end
end

---@param arglead string
---@param candidates string[]
---@return string[]
local function filter_prefix(arglead, candidates)
  local out = {}
  for _, c in ipairs(candidates) do
    if c:sub(1, #arglead) == arglead then
      out[#out + 1] = c
    end
  end
  return out
end

---Register both commands.
---@return nil
function M.setup()
  -- :Spellcheck [lang] [buffer|visible|cwd|path=<p>|clear|refresh]
  usercmd("Spellcheck", function(o)
    local spell = require("language.spell")
    local tokens = vim.split(o.args or "", "%s+", { trimempty = true })

    -- Session control verbs take precedence.
    for _, t in ipairs(tokens) do
      if t == "clear" then
        return spell.clear()
      elseif t == "refresh" then
        return spell.refresh()
      end
    end

    local scope, rest = require("language.scope").parse(tokens, {
      bufnr = vim.api.nvim_get_current_buf(),
      line1 = o.line1,
      line2 = o.line2,
      has_range = o.range and o.range > 0,
    })
    spell.run(rest[1], scope)
  end, {
    nargs = "*",
    range = true,
    force = true,
    desc = "Spell/grammar review  [lang] [buffer|visible|cwd|path=<p>|clear|refresh]",
    complete = function(arglead, line, _)
      local parts = vim.split(line, "%s+", { trimempty = true })
      local editing = line:sub(-1) ~= " "
      local pos = editing and #parts or #parts + 1
      if pos == 2 then
        return filter_prefix(arglead, SPELL_LANGS)
      end
      local out = filter_prefix(arglead, SPELL_SCOPES)
      if not arglead:match("^%-") then
        vim.list_extend(out, vim.fn.getcompletion(arglead, "dir"))
      end
      return out
    end,
  })

  -- Shared body for :Translate / :TranslateReplace. `force_output` (and
  -- `force_files_mode`) make :TranslateReplace always mutate, regardless of
  -- `--output=`/`--files=` or the configured default.
  ---@param o table
  ---@param force_output LanguageTranslateOutput|nil
  ---@param force_files_mode string|nil
  local function dispatch_translate(o, force_output, force_files_mode)
    local tokens = vim.split(o.args or "", "%s+", { trimempty = true })

    local nocode = false
    local output = force_output
    local files_mode = force_files_mode
    local kept = {}
    for _, t in ipairs(tokens) do
      if t == "--nocode" or t == "-nocode" then
        nocode = true
      elseif not force_output and t:match("^%-%-output=") then
        output = t:gsub("^%-%-output=", "")
      elseif not force_files_mode and t:match("^%-%-files=") then
        files_mode = t:gsub("^%-%-files=", "")
      elseif not t:match("^%-") then
        kept[#kept + 1] = t
      end
    end

    -- Bang → interactive window (:Translate! only; prefilled from a range).
    if o.bang and not force_output then
      local source_lines = nil
      if o.range and o.range > 0 then
        source_lines = vim.api.nvim_buf_get_lines(0, o.line1 - 1, o.line2, false)
      end
      require("language.translate.window").open({ target = kept[1], source_lines = source_lines })
      return
    end

    local scope, rest = require("language.scope").parse(kept, {
      bufnr = vim.api.nvim_get_current_buf(),
      line1 = o.line1,
      line2 = o.line2,
      has_range = o.range and o.range > 0,
    })

    -- cwd, or path=<directory> → multi-file translation (pick files, then
    -- write per translate.files.output / --files=<mode> / forced mode).
    local is_dir_path = scope.kind == "path" and scope.path and vim.fn.isdirectory(scope.path) == 1
    if scope.kind == "cwd" or is_dir_path then
      local dir = scope.kind == "cwd" and vim.fn.getcwd() or scope.path
      require("language.translate").run_files(rest[1], { dir = dir, mode = files_mode })
      return
    end

    require("language.translate").run(rest[1], { nocode = nocode, output = output, scope = scope })
  end

  -- :Translate <lang> [--nocode] [--output=<mode>] [selection|buffer|cwd|path=<p>]
  -- Default output is `translate.default_output` (popup: shows the result
  -- without touching the buffer). :Translate![lang] opens the interactive
  -- translation window instead.
  usercmd("Translate", function(o)
    dispatch_translate(o, nil, nil)
  end, {
    nargs = "*",
    range = true,
    bang = true,
    force = true,
    desc = "Translate (popup by default)  <lang> [--nocode|--output=<m>|--files=<m>] [scope]  (! = window)",
    complete = function(arglead, line, _)
      local parts = vim.split(line, "%s+", { trimempty = true })
      local editing = line:sub(-1) ~= " "
      local pos = editing and #parts or #parts + 1
      if pos == 2 then
        return filter_prefix(arglead, TR_LANGS)
      end
      local out = filter_prefix(arglead, TR_FLAGS)
      vim.list_extend(out, filter_prefix(arglead, TR_SCOPES))
      return out
    end,
  })

  -- :TranslateReplace <lang> [--nocode] [selection|buffer|cwd|path=<p>]
  -- Always mutates: replaces the source range/file(s) in place (the old
  -- `:TranslateReplace` behavior). No `--output=`/`--files=` — its whole
  -- purpose is to replace.
  usercmd("TranslateReplace", function(o)
    dispatch_translate(o, "replace", "replace")
  end, {
    nargs = "+",
    range = true,
    force = true,
    desc = "Translate and replace in place  <lang> [--nocode] [selection|buffer|cwd|path=<p>]",
    complete = function(arglead, line, _)
      local parts = vim.split(line, "%s+", { trimempty = true })
      local editing = line:sub(-1) ~= " "
      local pos = editing and #parts or #parts + 1
      if pos == 2 then
        return filter_prefix(arglead, TR_LANGS)
      end
      local out = filter_prefix(arglead, TR_REPLACE_FLAGS)
      vim.list_extend(out, filter_prefix(arglead, TR_SCOPES))
      return out
    end,
  })
end

return M
