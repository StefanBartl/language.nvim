---@module 'language.translate.office'
---@brief Translate a PowerPoint (.pptx) or Word (.docx) file into a copy next to it.
---@description
--- `translate_file(path, target, opts, cb)` unpacks the file (a ZIP archive, after `office.zip` looked at it),
--- takes the text paragraphs of the slides, notes, document, headers, footers and footnotes (`office.xml`),
--- translates them with the configured translate engine in batches, puts them back and packs
--- `name.<target>.<ext>` next to the original. The original is never written. Nothing of the file is run, and
--- the text goes to the engine only through `provider.translate`, i.e. with the engine's own notice.

local xml = require("language.translate.office.xml")
local zip = require("language.translate.office.zip")

local M = {}

M.BATCH = 40

---@internal
---@type table<string, string[]>  -- extension -> Lua patterns of the parts that hold text
local PARTS = {
  pptx = { "^ppt/slides/slide%d+%.xml$", "^ppt/notesSlides/notesSlide%d+%.xml$" },
  docx = {
    "^word/document%.xml$",
    "^word/header%d*%.xml$",
    "^word/footer%d*%.xml$",
    "^word/footnotes%.xml$",
    "^word/endnotes%.xml$",
  },
}

---@param name string
---@param ext string
---@return boolean
local function is_text_part(name, ext)
  for _, pat in ipairs(PARTS[ext] or {}) do
    if name:match(pat) then
      return true
    end
  end
  return false
end

---The name of the translated copy.
---@param path string
---@param target string
---@return string
function M.output_path(path, target)
  local base, ext = path:match("^(.*)%.([^./\\]+)$")
  return ("%s.%s.%s"):format(base, target, ext)
end

---@internal
---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

---@internal
---@param path string
---@param data string
---@return boolean
local function write(path, data)
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(data)
  f:close()
  return true
end

---Translate lines in batches; `cb(ok, translated_by_line)`.
---@internal
---@param provider LanguageTranslateProvider
---@param lines string[]
---@param target string
---@param cfg table
---@param opts { on_progress?: fun(done: integer, total: integer) }
---@param cb fun(ok: boolean, res: table<string, string>|string)
---@return { cancel: fun() }
local function translate_lines(provider, lines, target, cfg, opts, cb)
  local result, i, stopped = {}, 0, false
  local job
  local function step()
    if stopped then
      return
    end
    if i >= #lines then
      return cb(true, result)
    end
    local batch = vim.list_slice(lines, i + 1, math.min(i + M.BATCH, #lines))
    local settled = false
    local function got(ok, res)
      if settled or stopped then
        return
      end
      settled = true
      if not ok or type(res) ~= "table" or #res ~= #batch then
        stopped = true
        return cb(false, ok and "the engine returned another number of lines" or tostring(res))
      end
      for k, line in ipairs(batch) do
        result[line] = res[k]
      end
      i = i + #batch
      if opts.on_progress then
        opts.on_progress(i, #lines)
      end
      vim.schedule(step)
    end
    local started, thrown = pcall(function()
      job = provider.translate(batch, target, nil, cfg, got)
    end)
    if not started then
      got(false, thrown)
    end
  end
  step()
  return {
    cancel = function()
      if not stopped then
        stopped = true
        if type(job) == "table" and job.cancel then
          pcall(job.cancel)
        end
        cb(false, "cancelled")
      end
    end,
  }
end

---@class LanguageOfficeOpts
---@field out? string                -- where the copy goes (default: name.<target>.<ext>)
---@field provider? LanguageTranslateProvider  -- default: the configured engine
---@field cfg? table                 -- translate config (default: the plugin's)
---@field limits? table              -- { max_entries, max_bytes } of the archive
---@field tools? { unpack?: string, pack?: string }
---@field on_progress? fun(done: integer, total: integer)

---@param path string
---@param target string
---@param opts LanguageOfficeOpts|nil
---@param cb fun(ok: boolean, res: string)  -- the path of the copy, or the reason
---@return { cancel: fun() }
function M.translate_file(path, target, opts, cb)
  opts = opts or {}
  local finished = false
  local tmp
  -- What runs right now (the unpacking, the engine, the packing) and stops it.
  local stop_current = function() end
  local packing_started = false
  local function finish(ok, res)
    if finished then
      return
    end
    finished = true
    if tmp then
      pcall(vim.fn.delete, tmp, "rf")
    end
    cb(ok, res)
  end
  -- After this nothing that comes later is heard: finish() answers once.
  local handle = {
    cancel = function()
      if not finished then
        finish(false, "cancelled")
        pcall(stop_current)
      end
    end,
  }
  local function fail(msg)
    finish(false, msg)
  end

  local ext = (path:match("%.([^./\\]+)$") or ""):lower()
  if not PARTS[ext] then
    fail(("not a PowerPoint or Word file (.pptx, .docx): %s"):format(path))
    return handle
  end
  if type(target) ~= "string" or target == "" then
    fail("a target language is required")
    return handle
  end
  local out = opts.out or M.output_path(path, target)
  if
    vim.fs.normalize(vim.fn.fnamemodify(out, ":p"))
    == vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  then
    fail("the copy would overwrite the original")
    return handle
  end

  local cfg = opts.cfg or require("language.config").get().translate
  local provider = opts.provider
  if not provider then
    local err
    provider, err = require("language.translate.providers.registry").resolve(cfg)
    if not provider then
      fail(err or "no translate engine is available")
      return handle
    end
  end

  local entries, ierr = zip.inspect_file(path, opts.limits)
  if not entries then
    fail(ierr or "cannot read the file")
    return handle
  end

  tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local tools = opts.tools or {}
  local unpacking = zip.unpack(
    path,
    tmp,
    { tool = tools.unpack, limits = opts.limits, inspected = true },
    function(ok, uerr)
      if finished then
        return
      end
      if not ok then
        return fail(uerr)
      end
      local parts, lines, seen = {}, {}, {}
      for _, e in ipairs(entries) do
        if not e.dir and is_text_part(e.name, ext) then
          local file = tmp .. "/" .. e.name
          local data = read(file)
          if data then
            parts[#parts + 1] = { file = file, data = data }
            for _, para in ipairs(xml.collect(data)) do
              if para.line and not seen[para.line] then
                seen[para.line] = true
                lines[#lines + 1] = para.line
              end
            end
          end
        end
      end
      if #lines == 0 then
        return fail("no text to translate in the file")
      end
      local job = translate_lines(provider, lines, target, cfg, opts, function(tok, translated)
        if finished then
          return
        end
        if not tok then
          return fail(("translate failed: %s"):format(tostring(translated)))
        end
        for _, part in ipairs(parts) do
          local new = xml.apply(part.data, function(line)
            return translated[line]
          end)
          if not write(part.file, new) then
            return fail("cannot write " .. part.file)
          end
        end
        local packing = zip.pack(
          tmp,
          vim.fn.fnamemodify(out, ":p"),
          { tool = tools.pack },
          function(pok, perr)
            if finished then
              return
            end
            if not pok then
              return fail(perr)
            end
            finish(true, out)
          end
        )
        if packing then
          stop_current = packing.cancel
          packing_started = true
        end
      end)
      -- (an answer that came before this line has moved on to the packing, which then is what stops)
      if not packing_started then
        stop_current = job.cancel
      end
    end
  )
  if unpacking then
    stop_current = unpacking.cancel
  end
  return handle
end

return M
