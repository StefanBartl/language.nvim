---@module 'language.translate'
---@brief Translate domain entry point: scope → provider → output.
---@description
--- Keyless Google provider by default, async and cancellable, over the shared
--- scope model. Default output is `popup` (read-only, non-mutating) — see
--- `:Translate` vs `:TranslateReplace` in bindings/usrcmds.lua: `:Translate`
--- shows the result without touching the buffer; `:TranslateReplace` forces
--- `replace`. `--nocode` (replace mode only) translates only the prose ranges
--- of a selection (fenced/inline code preserved), applied bottom-up so line
--- numbers stay valid across replacements.

require("language.@types")
require("language.translate.@types")

local api = vim.api

local notify = require("lib.nvim.notify").create("[language.translate]")
local registry = require("language.translate.providers.registry")
local output = require("language.translate.output")
local filter = require("language.translate.filter")
local indent = require("language.translate.indent")

local M = {}

---In-flight jobs, cancelled when a new run starts.
---@type Language.Job[]
local active = {}

---@internal
---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---@internal
---Cancel any in-flight jobs.
---@return nil
local function cancel_active()
  for _, j in ipairs(active) do
    pcall(j.cancel)
  end
  active = {}
end

---Translate a precise character-wise region and (for replace) set the exact
---byte span. Coordinates are 0-based rows and byte columns, end-exclusive —
---the shape returned by `nvim_buf_get_text` / accepted by `nvim_buf_set_text`.
---@param target string
---@param opts { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, output?: LanguageTranslateOutput }
---@return nil
function M.run_region(target, opts)
  if type(target) ~= "string" or target == "" then
    notify.warn("Please specify a target language")
    return
  end
  local bufnr = opts.bufnr
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local c = cfg()
  local provider, err = registry.resolve(c)
  if not provider then
    notify.error(err or "no translate engine available")
    return
  end

  local ok_get, lines = pcall(api.nvim_buf_get_text, bufnr, opts.sr, opts.sc, opts.er, opts.ec, {})
  if not ok_get or type(lines) ~= "table" or #lines == 0 then
    notify.warn("Could not read the selected region")
    return
  end

  cancel_active()
  local mode = opts.output or c.default_output or "popup"

  local job = provider.translate(lines, target, nil, c, function(ok, result)
    if not ok then
      notify.error(tostring(result))
      return
    end
    ---@cast result string[]
    if mode == "replace" then
      -- The span was captured before the request; the request is a network
      -- round trip, so re-verify it still holds the translated text right
      -- before writing -- same reasoning as spell/core/actions.lua's
      -- `replace_at`, applied here to the translate domain.
      if not api.nvim_buf_is_valid(bufnr) then
        notify.warn("Translation discarded: the buffer no longer exists")
        return
      end
      local ok_reget, current =
        pcall(api.nvim_buf_get_text, bufnr, opts.sr, opts.sc, opts.er, opts.ec, {})
      if not ok_reget then
        notify.warn("Translation discarded: the target position is no longer valid")
        return
      end
      if table.concat(current, "\n") ~= table.concat(lines, "\n") then
        notify.warn("Translation discarded: the text changed while translating")
        return
      end
      local ok_set, set_err =
        pcall(api.nvim_buf_set_text, bufnr, opts.sr, opts.sc, opts.er, opts.ec, result)
      if not ok_set then
        notify.error("Could not write translation: " .. tostring(set_err))
        return
      end
    else
      output.apply(
        mode,
        result,
        { bufnr = bufnr, s = opts.sr + 1, e = opts.er + 1, target = target }
      )
    end
    require("language.translate.history").record({ input = lines, output = result, target = target })
  end)
  if job then
    active[#active + 1] = job
  end
end

---@internal
---Resolve a scope to a concrete { bufnr, s, e } line range on an open buffer.
---@param scope LanguageScope|nil
---@return integer|nil bufnr, integer s, integer e
local function scope_range(scope)
  local bufnr = (scope and scope.bufnr) or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then
    return nil, 0, 0
  end
  local total = api.nvim_buf_line_count(bufnr)
  if scope and (scope.kind == "selection" or scope.kind == "visible") and scope.range then
    return bufnr, math.max(1, scope.range.s), math.min(total, scope.range.e)
  end
  -- buffer (default). A cwd/path scope never reaches here: `M.run` (and the
  -- command layer before it) hands it to `run_files` before this call.
  return bufnr, 1, total
end

---@internal
---A line range was captured before a network round trip; before writing next
---to it (or over it), check it still holds the text that was translated --
---the line-based counterpart of the check in `run_region`. Warns on mismatch.
---@param bufnr integer
---@param s integer            1-based inclusive
---@param e integer            1-based inclusive
---@param lines string[]       the lines read when the request was made
---@return boolean unchanged
local function range_unchanged(bufnr, s, e, lines)
  if not api.nvim_buf_is_valid(bufnr) then
    notify.warn("Translation discarded: the buffer no longer exists")
    return false
  end
  local ok, current = pcall(api.nvim_buf_get_lines, bufnr, s - 1, e, false)
  local same = ok and #current == #lines
  if same then
    for i = 1, #lines do
      if current[i] ~= lines[i] then
        same = false
        break
      end
    end
  end
  if not same then
    notify.warn("Translation discarded: the text changed while translating")
    return false
  end
  return true
end

---@internal
---Translate a range and deliver via `mode`.
---@param provider LanguageTranslateProvider
---@param bufnr integer
---@param s integer
---@param e integer
---@param target string
---@param mode LanguageTranslateOutput
---@return nil
local function translate_range(provider, bufnr, s, e, target, mode)
  local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local dedented, indents = indent.strip(lines)
  local jobref
  jobref = provider.translate(dedented, target, nil, cfg(), function(ok, result)
    if not ok then
      notify.error(tostring(result))
      return
    end
    ---@cast result string[]
    result = indent.restore(result, indents)
    if (mode == "replace" or mode == "insert") and not range_unchanged(bufnr, s, e, lines) then
      return
    end
    output.apply(mode, result, { bufnr = bufnr, s = s, e = e, target = target })
    require("language.translate.history").record({ input = lines, output = result, target = target })
  end)
  if jobref then
    active[#active + 1] = jobref
  end
end

---@internal
---Translate the cue text of an SRT/WebVTT range and deliver via `mode`. Index,
---timing and header lines are copied, not sent (see `translate/subtitle.lua`).
---@param provider LanguageTranslateProvider
---@param bufnr integer
---@param s integer
---@param e integer
---@param target string
---@param mode LanguageTranslateOutput
---@param kind "srt"|"vtt"
---@return nil
local function translate_subtitle(provider, bufnr, s, e, target, mode, kind)
  local subtitle = require("language.translate.subtitle")
  local all = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local jobref = subtitle.translate(provider, all, kind, target, cfg(), function(ok, result, info)
    if not ok then
      notify.error(tostring(result))
      return
    end
    ---@cast result string[]
    if (mode == "replace" or mode == "insert") and not range_unchanged(bufnr, s, e, lines) then
      return
    end
    if info and info.kept > 0 then
      notify.warn(
        ("%d subtitle cue(s) kept in the source language (the engine broke a tag)"):format(
          info.kept
        )
      )
    end
    output.apply(mode, result, { bufnr = bufnr, s = s, e = e, target = target })
    require("language.translate.history").record({ input = lines, output = result, target = target })
  end, { s = s, e = e })
  if jobref then
    active[#active + 1] = jobref
  end
end

---@internal
---Translate the prose sub-ranges of [s,e] (skip code), replacing bottom-up.
---@param provider LanguageTranslateProvider
---@param bufnr integer
---@param s integer
---@param e integer
---@param target string
---@return nil
local function translate_nocode(provider, bufnr, s, e, target)
  local ranges = filter.translatable_ranges(bufnr, s, e)
  if #ranges == 0 then
    notify.info("No translatable text found (fenced/inline code skipped)")
    return
  end

  -- Translate all ranges concurrently, collect, then apply bottom-up so
  -- earlier (higher-line) replacements don't shift later indices.
  local pending = #ranges
  ---@type table<integer, string[]>
  local results = {}
  ---@type table<integer, string[]>
  local indents = {}
  ---@type table<integer, string[]>
  local sources = {}

  for idx = 1, #ranges do
    local r = ranges[idx]
    local lines = api.nvim_buf_get_lines(bufnr, r.s - 1, r.e, false)
    sources[idx] = lines
    local dedented
    dedented, indents[idx] = indent.strip(lines)
    local jobref
    jobref = provider.translate(dedented, target, nil, cfg(), function(ok, result)
      pending = pending - 1
      if ok then
        ---@cast result string[]
        results[idx] = indent.restore(result, indents[idx])
      else
        notify.error(tostring(result))
      end
      if pending == 0 then
        -- Every request failed (each already reported): nothing to write or discard.
        if next(results) == nil then
          return
        end
        -- All or nothing: one drifted range also shifts the others, so verify
        -- every range before the first write.
        for i = 1, #ranges do
          if not range_unchanged(bufnr, ranges[i].s, ranges[i].e, sources[i]) then
            return
          end
        end
        for i = #ranges, 1, -1 do
          if results[i] then
            output.apply("replace", results[i], { bufnr = bufnr, s = ranges[i].s, e = ranges[i].e })
          end
        end
      end
    end)
    if jobref then
      active[#active + 1] = jobref
    end
  end
end

---Run a translation.
---@param lang string
---@param opts LanguageTranslateRunOpts|nil
---@return nil
function M.run(lang, opts)
  opts = opts or {}

  if type(lang) ~= "string" or lang == "" then
    notify.warn("Please specify a target language, e.g. :Translate EN")
    return
  end

  local scope = opts.scope

  -- A cwd/path scope is whole files, not a buffer range: it goes the same
  -- way the command sends it, through `run_files` (a directory opens the
  -- picker, a single file is translated directly). The Lua facade
  -- (`require("language").translate`) reaches here with such a scope.
  if scope and (scope.kind == "cwd" or scope.kind == "path") then
    local target, terr = require("language.translate.files").target(scope)
    if not target then
      notify.error(("Translate: %s"):format(terr))
      return
    end
    local files_mode = opts.files or (opts.output == "replace" and "replace" or nil)
    M.run_files(lang, { dir = target.dir, file = target.file, mode = files_mode })
    return
  end

  local c = cfg()
  local provider, err = registry.resolve(c)
  if not provider then
    notify.error(err or "no translate engine available")
    return
  end

  -- A word is a character region, not a line range, so it does not go through
  -- `scope_range` at all -- it goes through `run_region`, which already exists
  -- for exactly this shape and is what the operator maps use. Rounding a word
  -- up to its line would translate the line, which is a different command.
  if scope and scope.kind == "cword" then
    -- Bound before it is tested rather than after: a guard on the *field*
    -- narrows nothing for a later read of it, and the four reads below would
    -- each be an unchecked nil (`need-check-nil` x4, found by the LuaLS scan
    -- after a green suite).
    local r = scope.region
    if not r then
      notify.warn("No word under the cursor")
      return
    end
    M.run_region(lang, {
      bufnr = scope.bufnr or api.nvim_get_current_buf(),
      sr = r.sr,
      sc = r.sc,
      er = r.er,
      ec = r.ec,
      output = opts.output,
    })
    return
  end

  local bufnr, s, e = scope_range(scope)
  if not bufnr then
    notify.warn("Current buffer is invalid")
    return
  end

  -- A new run supersedes any in-flight one.
  cancel_active()

  local mode = opts.output or c.default_output or "popup"
  local nocode = opts.nocode
  if nocode == nil then
    nocode = c.nocode_default
  end

  local subtitle_kind = require("language.translate.subtitle").detect(
    api.nvim_buf_get_name(bufnr),
    vim.bo[bufnr].filetype,
    api.nvim_buf_get_lines(bufnr, 0, -1, false)
  )
  if subtitle_kind then
    -- Always: timestamps must never be translated, so `--nocode` is not asked.
    translate_subtitle(provider, bufnr, s, e, lang, mode, subtitle_kind)
  elseif nocode and mode == "replace" then
    translate_nocode(provider, bufnr, s, e, lang)
  else
    translate_range(provider, bufnr, s, e, lang, mode)
  end
end

---Translate files for a cwd/path scope: `opts.dir` opens a multi-select
---picker over that directory, `opts.file` translates that one file directly.
---@see language.translate.files
---@param lang string
---@param opts { dir?: string, file?: string, mode?: string }
---@return nil
function M.run_files(lang, opts)
  require("language.translate.files").run(lang, opts)
end

return M
