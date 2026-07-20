---@module 'language.bindings.usrcmds'
---@brief Registers the top-level commands: :Spellcheck, :Translate,
---@brief :TranslateReplace — built via lib.nvim.usercmd.composer.
---@description
--- Each is its own composer verb with a `path = {}` root route (a flat
--- grammar, no subcommand word — same trick pdfport.nvim/replacer.nvim use).
--- `args`/`flags` are declared purely to drive `<Tab>` completion; dispatch
--- bypasses composer's own bound `ctx.args`/`ctx.flags` entirely and re-runs
--- the ORIGINAL token-scanning logic against `ctx.raw` (composer's untouched
--- nvim-callback opts — same `.args`/`.bang`/`.range`/`.line1`/`.line2` shape
--- as before this migration). Reason: the real grammar classifies tokens by
--- shape in any order (a scope word, `path=<p>`, `--flag[=value]`, or the
--- bare language code) rather than binding strict positional slots, and
--- :Translate's `--nocode`/`-nocode` dual-prefix + silent-drop-unknown-flag
--- leniency predate this migration — reproducing that from composer's own
--- ctx.args/ctx.flags would either lose the dual prefix or require a second,
--- redundant parser. See `docs/NOTES/.../language.nvim.md` in the nvim config
--- repo for the full design writeup (mirrors replacer.nvim's identical
--- ctx.raw-bypass technique, `lua/replacer/command.lua`).

local composer = require("lib.nvim.usercmd.composer")

require("language.config.@types")

local M = {}

local SPELL_LANGS = { "en", "de", "fr", "es", "it", "pt", "nl", "en,de" }
local SPELL_SCOPES = { "buffer", "visible", "cwd", "clear", "refresh" }
local TR_LANGS = { "EN", "DE", "FR", "ZH", "JA", "ES", "IT" }
local TR_SCOPES = { "selection", "buffer", "cwd" }
local TR_OUTPUT_MODES = {
  "popup", "replace", "buffer", "vsplit", "split", "tab", "insert", "clipboard", "notify",
}
local TR_FILES_MODES = { "suffix", "replace", "buffers" }

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

-- 1st positional for :Spellcheck.
composer.register_type("SPELL_LANG", {
  validate = function(raw) return true, raw, nil end,
  complete = function(arglead) return filter_prefix(arglead, SPELL_LANGS) end,
})

-- 2nd+ positional for :Spellcheck: scope words + directory completion
-- (skipped once the lead looks like a flag, matching the original guard).
composer.register_type("SPELL_SCOPE", {
  validate = function(raw) return true, raw, nil end,
  complete = function(arglead)
    local out = filter_prefix(arglead, SPELL_SCOPES)
    if not arglead:match("^%-") then
      vim.list_extend(out, vim.fn.getcompletion(arglead, "dir"))
    end
    return out
  end,
})

-- 1st positional shared by :Translate / :TranslateReplace.
composer.register_type("TRANSLATE_LANG", {
  validate = function(raw) return true, raw, nil end,
  complete = function(arglead) return filter_prefix(arglead, TR_LANGS) end,
})

-- 2nd+ positional shared by :Translate / :TranslateReplace.
composer.register_type("TRANSLATE_SCOPE", {
  validate = function(raw) return true, raw, nil end,
  complete = function(arglead) return filter_prefix(arglead, TR_SCOPES) end,
})

---:Spellcheck [lang] [buffer|visible|cwd|path=<p>|clear|refresh]
---@param o table  composer's ctx.raw (same shape as the original nvim callback opts)
local function spellcheck_handler(o)
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
end

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

---Register all three commands.
---@return nil
function M.setup()
  composer.verb("Spellcheck", {
    desc = "Spell/grammar review  [lang] [buffer|visible|cwd|path=<p>|clear|refresh]",
    range = true,
    routes = {
      { path = {},
        args = {
          { name = "lang",  type = "SPELL_LANG",  optional = true },
          { name = "scope", type = "SPELL_SCOPE", optional = true },
        },
        range = true,
        desc = "Spell/grammar review",
        run  = function(ctx) spellcheck_handler(ctx.raw) end },
    },
  })

  -- Default output is `translate.default_output` (popup: shows the result
  -- without touching the buffer). :Translate![lang] opens the interactive
  -- translation window instead.
  composer.verb("Translate", {
    desc = "Translate (popup by default)  <lang> [--nocode|--output=<m>|--files=<m>] [scope]  (! = window)",
    bang = true,
    range = true,
    routes = {
      { path = {},
        args = {
          { name = "lang",  type = "TRANSLATE_LANG",  optional = true },
          { name = "scope", type = "TRANSLATE_SCOPE", optional = true },
        },
        flags = {
          { name = "nocode", bool = true },
          { name = "output", type = "STRING", enum = TR_OUTPUT_MODES },
          { name = "files",  type = "STRING", enum = TR_FILES_MODES },
        },
        range = true,
        bang  = true,
        desc  = "Translate (popup by default; ! = interactive window)",
        run   = function(ctx) dispatch_translate(ctx.raw, nil, nil) end },
    },
  })

  -- Always mutates: replaces the source range/file(s) in place (the old
  -- `:TranslateReplace` behavior). No `--output=`/`--files=` — its whole
  -- purpose is to replace.
  composer.verb("TranslateReplace", {
    desc = "Translate and replace in place  <lang> [--nocode] [selection|buffer|cwd|path=<p>]",
    range = true,
    routes = {
      { path = {},
        args = {
          { name = "lang",  type = "TRANSLATE_LANG",  optional = true },
          { name = "scope", type = "TRANSLATE_SCOPE", optional = true },
        },
        flags = {
          { name = "nocode", bool = true },
        },
        range = true,
        desc  = "Translate and replace in place",
        run   = function(ctx) dispatch_translate(ctx.raw, "replace", "replace") end },
    },
  })
end

return M
