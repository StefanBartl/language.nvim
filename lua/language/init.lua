---@module 'language'
---@brief language.nvim — spelling, grammar and translation tooling for Neovim.
---@description
--- Two independent domains behind two top-level commands:
---   :Spellcheck [lang] [buffer|visible|cwd|path=<p>|clear|refresh]
---   :Translate  <lang> [--nocode] [--output=<mode>] [selection|buffer|path=<p>]
---
--- Both share a common scope model (see `language/@types`) and are built on
--- lib.nvim as a deliberate shared dependency.
---
---   require("language").setup({ ... })
---
---@class Language.Module
local M = {}

---Configure and activate the plugin. Idempotent-ish: re-runs merge config.
---@param opts LanguageConfig|table|nil
---@return nil
function M.setup(opts)
  require("language.config").setup(opts or {})

  local cfg = require("language.config").get()

  if cfg.commands ~= false then
    require("language.bindings.usrcmds").setup()
  end

  require("language.bindings.keymaps").setup(
    cfg,
    not (cfg.which_key and cfg.which_key.enable == false)
  )
  require("language.bindings.autocmds").setup(cfg)

  if cfg.spell and cfg.spell.programming_dict then
    require("language.spell.programming_dict").ensure()
  end
  if cfg.spell and cfg.spell.extra_wordlists then
    require("language.spell.extra_dict").ensure(cfg.spell.extra_wordlists)
  end

  -- One-time (persisted across restarts) popup on the first setup() after
  -- installing this plugin: which CLI tools unlock which provider, and why
  -- (docs/install.json). `:Lib deps show language.nvim` thereafter.
  -- `cfg.deps_popup = false` (set right in the setup() spec,
  -- config/DEFAULTS.lua) disables it for this plugin specifically. pcall'd:
  -- an older lib.nvim without lib.nvim.deps mustn't break setup() over an
  -- informational popup.
  if cfg.deps_popup ~= false then
    local ok_deps, deps = pcall(require, "lib.nvim.deps")
    if ok_deps then
      deps.show_once("language.nvim")
    end
  end
end

-- Public façade for direct Lua use ------------------------------------------------

---Run a spell-check session.
---@param lang?  string  e.g. "en", "de", "en,de"
---@param scope? string  "buffer"|"visible"|"cwd"|"path=<p>"|"clear"|"refresh"
---@return nil
function M.spellcheck(lang, scope)
  require("language.spell").run(lang, scope)
end

---Translate a range/selection. Default output is `translate.default_output`
---(popup, non-mutating). Use `M.translate_replace` to force in-place replace.
---@see M.translate_replace
---@param lang string  target language, e.g. "EN", "DE"
---@param opts table|nil  { nocode?, output?, scope? }
---@return nil
function M.translate(lang, opts)
  require("language.translate").run(lang, opts)
end

---Translate a range/selection and replace it in place (`:TranslateReplace`).
---@see M.translate
---@param lang string  target language, e.g. "EN", "DE"
---@param opts table|nil  { nocode?, scope? }
---@return nil
function M.translate_replace(lang, opts)
  require("language.translate").run(
    lang,
    vim.tbl_extend("force", opts or {}, { output = "replace" })
  )
end

---Open the interactive translation window.
---@param opts table|nil  { target?, source_lines? }
---@return nil
function M.translate_window(opts)
  require("language.translate.window").open(opts)
end

---Open the translation-history picker; the chosen entry opens in the window.
---@return nil
function M.translate_history()
  require("language.translate.history").pick(function(entry)
    require("language.translate.window").open({
      target = entry.target,
      source_lines = entry.input,
    })
  end)
end

---Replace the word under the cursor with a synonym (thesaurus lookup).
---@return nil
function M.synonyms()
  require("language.thesaurus").replace_under_cursor()
end

---Open the spell review panel.
---@param scope? string
---@return nil
function M.open_panel(scope)
  require("language.spell").open_panel(scope)
end

M.health = setmetatable({}, {
  __index = function(_, k)
    return require("language.health")[k]
  end,
})

return M
