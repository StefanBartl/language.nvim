---@module 'language.spell.ui.panel'
---@brief Interactive review panel over the scanned issues (lib.nvim.ui.kit).
---@description
--- Lists every issue in the scope as a navigable chooser; picking an item opens
--- its action menu. After any mutating action the panel re-scans and re-opens,
--- so the user can work through the list top-to-bottom. Diagnostics are
--- published alongside so the errors are also visible inline in the source.

local kit = require("lib.nvim.ui.kit")
local map = require("lib.nvim.bindings.keymap")
local notify = require("lib.nvim.notify").create("[language.spell]")
local collect = require("language.spell.core.collect")
local item_menu = require("language.spell.ui.item_menu")
local list = require("language.spell.ui.list")

local M = {}

local SOURCE = "language.spell"

---Direct, buffer-local keys on the panel list itself -- an issue's action
---menu (`<CR>`) still exists and still offers the same actions, this is
---just a faster path for the common ones (no submenu round-trip). Looked up
---by `id` against `item_menu._items(issue, ...)` so the action logic lives
---in exactly one place and can never drift between the two entry points.
---An `id` absent from an issue's item list (e.g. `add_dict` on a grammar
---issue) is reported rather than silently ignored.
---@type { keys: string[], id: string, legend: string, desc: string }[]
local PANEL_KEYMAPS = {
  {
    keys = { "a" },
    id = "add_dict",
    legend = "a Add",
    desc = "Add word under cursor to the dictionary",
  },
  {
    keys = { "i" },
    id = "ignore_session",
    legend = "i Ignore",
    desc = "Ignore word under cursor for this session",
  },
  {
    keys = { "I" },
    id = "ignore_persistent",
    legend = "I Ignore!",
    desc = "Ignore word under cursor permanently",
  },
  {
    keys = { "L" },
    id = "lsp_fix",
    legend = "L LSP fix",
    desc = "Apply an LSP code action for the issue under cursor",
  },
  {
    keys = { "gd", "o" },
    id = "jump",
    legend = "gd Jump",
    desc = "Jump to the word under cursor (closes the panel)",
  },
}

---Buffers carrying diagnostics/highlights published by this panel, across
---re-renders (each mutating action re-scans and re-opens). Tracked here
---because the panel view bypasses `language.spell`'s session/`touched`
---bookkeeping entirely (see `M.clear`).
---@type table<integer, true>
local touched = {}

---@internal
---@param path string
---@return string
local function file_tail(path)
  if not path or path == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(path, ":t")
end

---@internal
---Format one issue into a display row.
---@param issue LanguageSpellIssue
---@param multi_file boolean
---@return string
local function format_row(issue, multi_file)
  local occ = (issue.occurrences and issue.occurrences > 1)
      and ("  (x%d)"):format(issue.occurrences)
    or ""
  local where = multi_file and ("  %s:%d"):format(file_tail(issue.path), issue.lnum)
    or ("  :%d"):format(issue.lnum)
  return ("%-22s [%s]%s%s"):format(issue.word, issue.kind, occ, where)
end

---@internal
---Show a read-only cheatsheet of every key available on the panel list,
---including the chooser's own built-in navigation.
---@return nil
local function show_help()
  local widest = 0
  for _, entry in ipairs(PANEL_KEYMAPS) do
    local lhs = table.concat(entry.keys, ", ")
    widest = math.max(widest, #lhs)
  end
  widest = math.max(widest, #"<CR>")

  local lines = { "", " Spellcheck panel keys", "" }
  local function row(lhs, desc)
    lines[#lines + 1] = ("  %-" .. widest .. "s   %s"):format(lhs, desc)
  end
  row("j/k, <Up>/<Down>", "Move")
  row("<CR>", "Open the full action menu for the issue under cursor")
  for _, entry in ipairs(PANEL_KEYMAPS) do
    row(table.concat(entry.keys, ", "), entry.desc)
  end
  row("?", "Show this help")
  row("q, <Esc>", "Close the panel")
  lines[#lines + 1] = ""

  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  kit.viewer({
    lines = lines,
    title = "Spellcheck Panel Keys",
    filetype = "language-spell-help",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
  })
end

---@internal
---Wire the direct action keys (`PANEL_KEYMAPS`) and the `?` cheatsheet onto
---the chooser buffer. The chooser itself is closed before an action runs:
---`jump`/`lsp_fix` touch the underlying window/buffer directly, and would
---otherwise clobber the still-open floating list instead. Mutating actions
---(add/ignore) call `on_done`, which re-opens a fresh panel afterwards.
---@param bufnr integer
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param issues LanguageSpellIssue[]
---@return nil
local function attach_panel_keymaps(bufnr, scope, cfg, issues)
  local mo = { buffer = bufnr, nowait = true }

  for _, entry in ipairs(PANEL_KEYMAPS) do
    for _, lhs in ipairs(entry.keys) do
      map("n", lhs, function()
        local idx = kit.chooser.current_index()
        local issue = idx and issues[idx]
        if not issue then
          return
        end

        local on_done = function()
          vim.schedule(function()
            M.open(scope, cfg)
          end)
        end
        local items = item_menu._items(issue, on_done)

        local found
        for _, it in ipairs(items) do
          if it.id == entry.id then
            found = it
            break
          end
        end

        kit.chooser.close()
        if found then
          found.action()
        else
          notify.info(("Not available for '%s'"):format(issue.word))
        end
      end, mo, entry.desc)
    end
  end

  map("n", "?", show_help, mo, "Show every key available in this panel")
end

---Open (or re-open) the review panel for `scope`. Issue collection is
---async-capable (cwd/path may run an external CLI provider), so rendering
---happens in the gather callback.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return nil
function M.open(scope, cfg)
  collect.gather(scope, cfg, function(issues)
    M._render(scope, cfg, issues)
  end)
end

---Render the panel for already-collected issues.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@param issues LanguageSpellIssue[]
---@return nil
function M._render(scope, cfg, issues)
  if #issues == 0 then
    notify.info("No spelling issues — nothing to review")
    list.clear()
    return
  end

  -- Keep inline diagnostics in sync with the panel contents.
  local newly_touched = list.publish(issues, SOURCE, cfg.max_highlights, cfg.highlights)
  for b in pairs(newly_touched) do
    touched[b] = true
  end

  -- Detect whether the list spans multiple files (adjust row layout).
  local first_path = issues[1].path
  local multi_file = false
  for _, is in ipairs(issues) do
    if is.path ~= first_path then
      multi_file = true
      break
    end
  end

  local rows = {}
  for i, issue in ipairs(issues) do
    rows[i] = format_row(issue, multi_file)
  end

  local title = ("Spellcheck — %d issue(s) [%s]"):format(
    #issues,
    require("language.scope").label(scope)
  )

  local surf = kit.select({
    items = rows,
    title = title,
    on_select = function(_, idx)
      local issue = issues[idx]
      if not issue then
        return
      end
      item_menu.open(issue, function()
        -- Re-scan and re-open so the list reflects the mutation.
        vim.schedule(function()
          M.open(scope, cfg)
        end)
      end)
    end,
    on_cancel = M.clear,
  })

  if surf then
    attach_panel_keymaps(surf.bufnr, scope, cfg, issues)
  end
end

---Clear the diagnostics/highlights published by this panel across its
---renders. Called both when the picker is dismissed without a selection
---(`on_cancel` above) and from `language.spell.clear` (`:Spellcheck clear`),
---which otherwise has no visibility into buffers this view touched.
---@return nil
function M.clear()
  list.clear(touched)
  touched = {}
end

return M
