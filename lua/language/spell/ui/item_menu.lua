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

---Is this a grammar/style issue (fixed via LSP code actions, not spellsuggest)?
---@param issue LanguageSpellIssue
---@return boolean
local function is_grammar(issue)
  return issue.kind == "grammar"
    or issue.kind == "style"
    or issue.source == "harper"
    or issue.source == "ltex"
end

---Apply an LSP code action at the issue location. Delegates to Neovim's own
---code_action (which handles resolve/apply/offset-encoding and the picker), then
---schedules `on_done` so the panel refreshes after a fix is applied.
---@param issue LanguageSpellIssue
---@param on_done fun()
local function apply_lsp_fix(issue, on_done)
  jump_to(issue)
  local ok = pcall(vim.lsp.buf.code_action)
  if not ok then
    notify.warn("No LSP client provides code actions here")
    return
  end
  -- The action is applied asynchronously by the user's pick; refresh shortly.
  vim.defer_fn(on_done, 500)
end

---Build the action list for `issue`. Grammar/style issues (harper/ltex) are
---fixed via LSP code actions; spelling issues use suggestion replacement.
---Public for testing.
---@param issue LanguageSpellIssue
---@param on_done fun()
---@return { label: string, action: fun() }[]
function M._items(issue, on_done)
  local function done_msg(ok, err, ok_msg)
    if ok then
      notify.info(ok_msg)
      on_done()
    else
      notify.error(tostring(err))
    end
  end

  local ignore_items = {
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

  ---@type { label: string, action: fun() }[]
  local items

  if is_grammar(issue) then
    items = {
      {
        label = "Apply LSP fix…",
        action = function()
          apply_lsp_fix(issue, on_done)
        end,
      },
    }
  else
    items = {
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
    }
  end

  vim.list_extend(items, ignore_items)
  return items
end

---Open the action menu for `issue`. `on_done` runs after any mutating action.
---@param issue LanguageSpellIssue
---@param on_done fun()|nil
---@return nil
function M.open(issue, on_done)
  on_done = on_done or function() end
  local title = is_grammar(issue) and (issue.message or issue.word) or issue.word
  kit.menu({ title = title, items = M._items(issue, on_done) })
end

return M
