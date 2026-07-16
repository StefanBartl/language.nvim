---@module 'language.spell.ui.panel'
---@brief Interactive review panel over the scanned issues (lib.nvim.ui.kit).
---@description
--- Lists every issue in the scope as a navigable chooser; picking an item opens
--- its action menu. After any mutating action the panel re-scans and re-opens,
--- so the user can work through the list top-to-bottom. Diagnostics are
--- published alongside so the errors are also visible inline in the source.

local kit = require("lib.nvim.ui.kit")
local notify = require("lib.nvim.notify").create("[language.spell]")
local collect = require("language.spell.core.collect")
local item_menu = require("language.spell.ui.item_menu")
local list = require("language.spell.ui.list")

local M = {}

local SOURCE = "language.spell"

---@param path string
---@return string
local function file_tail(path)
  if not path or path == "" then
    return "[No Name]"
  end
  return vim.fn.fnamemodify(path, ":t")
end

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
  list.publish(issues, SOURCE, cfg.max_highlights, cfg.highlights)

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

  kit.select({
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
  })
end

return M
