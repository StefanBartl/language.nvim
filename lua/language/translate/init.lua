---@module 'language.translate'
---@brief Translate domain entry point: scope → provider → output.
---@description
--- Phase-3 scope: keyless Google provider, async and cancellable, over the
--- shared scope model. Default output `replace` reproduces the prior
--- `:TranslateReplace` behavior. `--nocode` translates only the prose ranges of
--- a selection (fenced/inline code preserved), applied bottom-up so line
--- numbers stay valid across replacements.

require("language.@types")
require("language.translate.@types")

local api = vim.api

local notify = require("lib.nvim.notify").create("[language.translate]")
local registry = require("language.translate.providers.registry")
local output = require("language.translate.output")
local filter = require("language.translate.filter")

local M = {}

---In-flight jobs, cancelled when a new run starts.
---@type Language.Job[]
local active = {}

---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---Cancel any in-flight jobs.
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
  local mode = opts.output or c.default_output or "replace"

  local job = provider.translate(lines, target, nil, c, function(ok, result)
    if not ok then
      notify.error(tostring(result))
      return
    end
    ---@cast result string[]
    if mode == "replace" then
      pcall(api.nvim_buf_set_text, bufnr, opts.sr, opts.sc, opts.er, opts.ec, result)
    else
      output.apply(mode, result, { bufnr = bufnr, s = opts.sr + 1, e = opts.er + 1 })
    end
    require("language.translate.history").record({ input = lines, output = result, target = target })
  end)
  if job then
    active[#active + 1] = job
  end
end

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
  -- buffer (default). cwd/path file translation is a later phase.
  return bufnr, 1, total
end

---Translate a range and deliver via `mode`.
---@param provider LanguageTranslateProvider
---@param bufnr integer
---@param s integer
---@param e integer
---@param target string
---@param mode LanguageTranslateOutput
local function translate_range(provider, bufnr, s, e, target, mode)
  local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local jobref
  jobref = provider.translate(lines, target, nil, cfg(), function(ok, result)
    if not ok then
      notify.error(tostring(result))
      return
    end
    ---@cast result string[]
    output.apply(mode, result, { bufnr = bufnr, s = s, e = e })
    require("language.translate.history").record({ input = lines, output = result, target = target })
  end)
  if jobref then
    active[#active + 1] = jobref
  end
end

---Translate the prose sub-ranges of [s,e] (skip code), replacing bottom-up.
---@param provider LanguageTranslateProvider
---@param bufnr integer
---@param s integer
---@param e integer
---@param target string
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

  for idx = 1, #ranges do
    local r = ranges[idx]
    local lines = api.nvim_buf_get_lines(bufnr, r.s - 1, r.e, false)
    local jobref
    jobref = provider.translate(lines, target, nil, cfg(), function(ok, result)
      pending = pending - 1
      if ok then
        ---@cast result string[]
        results[idx] = result
      else
        notify.error(tostring(result))
      end
      if pending == 0 then
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

  local c = cfg()
  local provider, err = registry.resolve(c)
  if not provider then
    notify.error(err or "no translate engine available")
    return
  end

  local scope = opts.scope
  if scope and (scope.kind == "cwd" or scope.kind == "path") then
    notify.warn("Translate over cwd/path is not supported yet — use a buffer or selection")
    return
  end

  local bufnr, s, e = scope_range(scope)
  if not bufnr then
    notify.warn("Current buffer is invalid")
    return
  end

  -- A new run supersedes any in-flight one.
  cancel_active()

  local mode = opts.output or c.default_output or "replace"
  local nocode = opts.nocode
  if nocode == nil then
    nocode = c.nocode_default
  end

  if nocode and mode == "replace" then
    translate_nocode(provider, bufnr, s, e, lang)
  else
    translate_range(provider, bufnr, s, e, lang, mode)
  end
end

return M
