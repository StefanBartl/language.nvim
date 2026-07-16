---@module 'language.translate.files'
---@brief Multi-file translation for cwd/path scopes.
---@description
--- Gathers translatable files under a directory, lets the user pick several via
--- the kit multi-select chooser (<Tab> to toggle), then translates each file
--- sequentially (progress feedback) and writes the result according to the
--- output mode:
---   "suffix"  → sibling file  name.<TARGET>.ext  (default, non-destructive)
---   "replace" → overwrite the file in place (asks for confirmation first)
---   "buffers" → open each translation in a scratch buffer (no disk write)
---
--- Note: `--nocode` and per-range code-skipping apply to buffer/selection
--- translation only; whole files are translated as one block here.

require("language.@types")
require("language.translate.@types")

local api = vim.api
local fn = vim.fn

local notify = require("lib.nvim.notify").create("[language.translate]")

local M = {}

---Directory names never descended into.
---@type table<string, true>
local IGNORE_DIR = {
  [".git"] = true,
  node_modules = true,
  [".venv"] = true,
  venv = true,
  dist = true,
  build = true,
  target = true,
  [".cache"] = true,
  ["__pycache__"] = true,
}

---@return LanguageTranslateCfg
local function cfg()
  return require("language.config").get().translate
end

---Gather translatable files (by extension + size) under `dir`.
---@param dir string
---@param c LanguageTranslateCfg
---@return { rel: string, abs: string }[]
function M.gather(dir, c)
  local exts = {}
  for _, e in ipairs((c.files and c.files.extensions) or {}) do
    exts[e:lower()] = true
  end
  local max_bytes = ((c.files and c.files.max_kb) or 512) * 1024

  ---@type { rel: string, abs: string }[]
  local out = {}
  pcall(function()
    for name, typ in vim.fs.dir(dir, { depth = 24 }) do
      if typ == "file" then
        local skip = false
        for seg in name:gmatch("[^/\\]+") do
          if IGNORE_DIR[seg] then
            skip = true
            break
          end
        end
        local ext = name:match("%.([^.\\/]+)$")
        if not skip and ext and exts[ext:lower()] then
          local abs = fn.fnamemodify(dir .. "/" .. name, ":p")
          local sz = fn.getfsize(abs)
          if sz >= 0 and sz <= max_bytes then
            out[#out + 1] = { rel = name:gsub("\\", "/"), abs = abs }
          end
        end
      end
    end
  end)
  table.sort(out, function(a, b)
    return a.rel < b.rel
  end)
  return out
end

---Sibling path with the target language inserted before the extension.
---@param abs string
---@param target string
---@return string
local function suffix_path(abs, target)
  local dir = fn.fnamemodify(abs, ":h")
  local stem = fn.fnamemodify(abs, ":t:r")
  local ext = fn.fnamemodify(abs, ":e")
  return dir .. "/" .. stem .. "." .. target .. (ext ~= "" and ("." .. ext) or "")
end

---Deliver one file's translation according to `mode`.
---@param mode string
---@param abs string
---@param result string[]
---@param target string
---@return string|nil written_path, integer|nil bufnr
local function deliver(mode, abs, result, target)
  if mode == "buffers" then
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_lines(buf, 0, -1, false, result)
    pcall(api.nvim_buf_set_name, buf, suffix_path(abs, target))
    local ft = vim.filetype.match({ filename = abs })
    if ft then
      vim.bo[buf].filetype = ft
    end
    return nil, buf
  elseif mode == "replace" then
    pcall(fn.writefile, result, abs)
    return abs, nil
  else -- suffix
    local dst = suffix_path(abs, target)
    pcall(fn.writefile, result, dst)
    return dst, nil
  end
end

---Translate the picked files sequentially, then finish. Public for testing.
---@param provider LanguageTranslateProvider
---@param picked { rel: string, abs: string }[]
---@param target string
---@param mode string
---@param on_done fun()|nil
function M.process(provider, picked, target, mode, on_done)
  local prog = require("lib.nvim.progress").create({ title = "[language]" })
  local c = cfg()
  local i = 0
  local first_buf_shown = false

  local function step()
    i = i + 1
    if i > #picked then
      prog:finish(("translated %d file(s) → %s"):format(#picked, target))
      if on_done then
        on_done()
      end
      return
    end
    prog:update({ text = "translating " .. picked[i].rel, current = i, total = #picked })

    local ok, lines = pcall(fn.readfile, picked[i].abs)
    if not ok or type(lines) ~= "table" then
      vim.schedule(step)
      return
    end

    provider.translate(lines, target, nil, c, function(ok2, result)
      if ok2 and type(result) == "table" then
        local written, buf = deliver(mode, picked[i].abs, result, target)
        if mode == "buffers" and buf and not first_buf_shown then
          -- Show the first translated buffer; the rest stay listed.
          pcall(api.nvim_set_current_buf, buf)
          first_buf_shown = true
        end
        require("language.translate.history").record({
          input = { picked[i].rel },
          output = written and { written } or result,
          target = target,
        })
      else
        notify.error(("translate failed: %s (%s)"):format(picked[i].rel, tostring(result)))
      end
      vim.schedule(step)
    end)
  end

  step()
end

---Run multi-file translation under `dir`.
---@param target string
---@param opts { dir: string, mode?: string }
---@return nil
function M.run(target, opts)
  if type(target) ~= "string" or target == "" then
    notify.warn("Please specify a target language, e.g. :Translate DE cwd")
    return
  end
  local c = cfg()
  local provider, err = require("language.translate.providers.registry").resolve(c)
  if not provider then
    notify.error(err or "no translate engine available")
    return
  end

  local dir = fn.fnamemodify(opts.dir or fn.getcwd(), ":p")
  local files = M.gather(dir, c)
  if #files == 0 then
    notify.info("No translatable files under " .. dir)
    return
  end

  local mode = opts.mode or (c.files and c.files.output) or "suffix"

  local items = {}
  for idx, f in ipairs(files) do
    items[idx] = f.rel
  end

  require("lib.nvim.ui.kit").select({
    items = items,
    multi = true,
    title = ("Translate → %s  (<Tab> select, <CR> confirm) [%s]"):format(target, mode),
    on_select = function(_, idxs)
      ---@type { rel: string, abs: string }[]
      local picked = {}
      for _, i in ipairs(idxs or {}) do
        if files[i] then
          picked[#picked + 1] = files[i]
        end
      end
      if #picked == 0 then
        return
      end
      if mode == "replace" then
        local ans = fn.confirm(
          ("Overwrite %d file(s) in place with the %s translation?"):format(#picked, target),
          "&Yes\n&No",
          2
        )
        if ans ~= 1 then
          notify.info("cancelled")
          return
        end
      end
      M.process(provider, picked, target, mode)
    end,
  })
end

return M
