---@module 'language.spell.ui.item_menu'
---@brief Cursor-anchored action menu for a single spell issue (lib.nvim.ui.kit).
---@description
--- Presents the per-issue actions (choose suggestion, replace all, add to
--- dictionary, ignore, jump). Each action mutates via language.spell.core.actions
--- / ignore and then calls `on_done` so the caller can re-scan and re-open the
--- review panel.

local api = vim.api

local kit = require("lib.nvim.ui.kit")
local notify = require("lib.nvim.notify").create("[language.spell]")
local actions = require("language.spell.core.actions")
local ignore = require("language.spell.core.ignore")
local native = require("language.spell.providers.native")

local M = {}

---Pick a suggestion for `issue`, then run `apply(chosen)`.
---@param issue LanguageSpellIssue
---@param title string
---@param apply fun(word: string)
local function pick_suggestion(issue, title, apply)
  local suggestions = issue.suggestions or native.suggest(issue)
  if #suggestions == 0 then
    notify.info(("No suggestions for '%s'"):format(issue.word))
    return
  end
  kit.select({
    items = suggestions,
    title = title,
    on_select = function(item)
      if type(item) == "string" and item ~= "" then
        apply(item)
      end
    end,
  })
end

---Jump the current window to an issue's location.
---@param issue LanguageSpellIssue
local function jump_to(issue)
  if issue.bufnr and api.nvim_buf_is_valid(issue.bufnr) then
    api.nvim_set_current_buf(issue.bufnr)
  elseif issue.path and issue.path ~= "" then
    vim.cmd("edit " .. vim.fn.fnameescape(issue.path))
  end
  pcall(api.nvim_win_set_cursor, 0, { issue.lnum, math.max(0, issue.col - 1) })
end

---Open the action menu for `issue`. `on_done` runs after any mutating action.
---@param issue LanguageSpellIssue
---@param on_done fun()|nil
---@return nil
function M.open(issue, on_done)
  on_done = on_done or function() end

  local function done_msg(ok, err, ok_msg)
    if ok then
      notify.info(ok_msg)
      on_done()
    else
      notify.error(tostring(err))
    end
  end

  local items = {
    {
      label = "Choose suggestion…",
      action = function()
        pick_suggestion(issue, "Replace '" .. issue.word .. "'", function(word)
          local ok, err = actions.replace_at(issue, word)
          if ok then
            notify.info(("Replaced with '%s'"):format(word))
            on_done()
          else
            notify.error(tostring(err))
          end
        end)
      end,
    },
    {
      label = "Replace all in buffer…",
      action = function()
        pick_suggestion(issue, "Replace all '" .. issue.word .. "'", function(word)
          local ok, count = actions.replace_all_in_buffer(issue.bufnr, issue.word, word)
          if ok then
            notify.info(("Replaced %d occurrence(s) with '%s'"):format(count, word))
            on_done()
          else
            notify.error(tostring(count))
          end
        end)
      end,
    },
    {
      label = "Add to dictionary",
      action = function()
        done_msg(
          actions.add_to_dict(issue.word),
          nil,
          ("Added '%s' to dictionary"):format(issue.word)
        )
      end,
    },
    {
      label = "Ignore (session)",
      action = function()
        ignore.add_session(issue.word)
        notify.info(("Ignoring '%s' this session"):format(issue.word))
        on_done()
      end,
    },
    {
      label = "Ignore (persistent)",
      action = function()
        done_msg(
          ignore.add_persistent(issue.word),
          nil,
          ("Ignoring '%s' permanently"):format(issue.word)
        )
      end,
    },
    {
      label = "Jump to location",
      action = function()
        jump_to(issue)
      end,
    },
  }

  kit.menu({ title = issue.word, items = items })
end

return M
