---@module 'language.bindings.keymaps'
---@brief Optional global keymaps derived from the config.
---@description
--- Global entry points only: toggle the spell panel/session, the (opt-in)
--- translate motion/visual maps, and the thesaurus key. Session-local keymaps
--- (fix / fix1 / next while a spell session is active) are attached
--- per-buffer by the spell module -- they are declared there, next to the
--- code that binds them.
---
--- Declared through `lib.nvim.bindings.keymap`'s registry, which is what
--- turns "the config value is an lhs" into "the config value names an
--- action": a typo in `spell.keymaps` used to be indistinguishable from
--- leaving it unset, and now says so. The config shape is unchanged, except
--- that every lhs may also be a list of keys.
---
--- One register call per config table -- `spell.keymaps`, `translate.keymaps`
--- and `thesaurus.keymap` are three separate surfaces -- because a single
--- table of overrides is exactly what the registry reports typos against, and
--- merging three of them would make every name from one look like a typo in
--- the others.

local keymap = require("lib.nvim.bindings.keymap")

local M = {}

---@internal
--- `t` without `names`.
---
--- Subtractive rather than additive on purpose. The registry reports the keys
--- it does not recognize, which is the whole point of handing it the user's
--- table -- so picking out the names this surface knows would throw away
--- exactly the typos worth reporting. What has to go is only what another
--- surface owns: `spell.keymaps` also holds the session keys, which the spell
--- module declares beside the code that binds them, and `translate.keymaps`
--- holds `to`, which is expanded into one action per language below.
---@param t table
---@param names string[]
---@return table
local function omit(t, names)
  local out = {}
  local drop = {}
  for _, name in ipairs(names) do
    drop[name] = true
  end
  for k, v in pairs(t) do
    if not drop[k] then
      out[k] = v
    end
  end
  return out
end

--- Label the prefixes the configured keys sit under.
---
--- Computed from the lhs the user chose rather than fixed: these keymaps are
--- opt-in, so the plugin does not know where they live. `<leader>ss` makes
--- `<leader>s` "Spell"; a single-character lhs has no prefix to label.
---@internal
---@param cfg LanguageConfig
---@return nil
local function label_groups(cfg)
  local groups = {}
  local sk = (cfg.spell and cfg.spell.keymaps) or {}
  for name, label in pairs({ panel = "Spell", fix = "Grammar fix" }) do
    local lhs = sk[name]
    if type(lhs) == "table" then
      lhs = lhs[1]
    end
    if type(lhs) == "string" and #lhs > 1 then
      groups[#groups + 1] = { prefix = lhs:sub(1, -2), group = label }
    end
  end
  if #groups > 0 then
    require("lib.nvim.bindings.keymap.which_key").add_group(groups)
  end
end

---@param cfg LanguageConfig
---@param which_key? boolean  # `false` skips the group labels only.
---@return nil
function M.setup(cfg, which_key)
  local sk = (cfg.spell and cfg.spell.keymaps) or {}
  keymap.register("language", {
    order = { "panel" },
    actions = {
      panel = {
        rhs = function()
          require("language.spell").run()
        end,
        desc = "Toggle spell session (current buffer)",
        opts = { silent = true },
      },
    },
  }, omit(sk, { "fix", "fix1", "next" }), { surface = "spell" })

  local tk = (cfg.translate and cfg.translate.keymaps) or {}

  ---@type table<string, Lib.Keymap.Action>
  local translate = {
    -- Operator: `<lhs>{motion}` translates the moved-over text.
    operator = {
      rhs = function()
        return require("language.translate.motion").expr()
      end,
      desc = "Translate motion",
      opts = { expr = true, silent = true },
    },
    -- Visual: translate the current selection.
    visual = {
      mode = "x",
      rhs = function()
        require("language.translate.motion").visual()
      end,
      desc = "Translate selection",
      opts = { silent = true },
    },
  }
  local order = { "operator", "visual" }

  -- Per-language operator/visual keys. With `default_target` set, the
  -- operator always used it and never asked; without one it always asked.
  -- Neither is "translate this bit into Spanish, just now".
  --
  -- A count could not carry the language here: on an operator the count
  -- belongs to the motion (`3<leader>tw` is three words), which is the whole
  -- point of having an operator. So it is a key per language, which is also
  -- what the audit suggested. Unset by default.
  --
  -- One action per language, named `to_<LANG>`, rather than one action
  -- holding the whole table: that is what makes each of them separately
  -- reportable and separately overridable.
  ---@type table<string, string|string[]|false>
  local translate_user = omit(tk, { "to" })
  for lang, lhs in pairs(tk.to or {}) do
    if type(lang) == "string" then
      local name = "to_" .. lang
      translate[name] = {
        binds = {
          {
            mode = "n",
            rhs = function()
              require("language.translate.motion").force_target(lang)
              return require("language.translate.motion").expr()
            end,
            desc = ("Translate motion to %s"):format(lang),
            opts = { expr = true, silent = true },
          },
          {
            mode = "x",
            rhs = function()
              require("language.translate.motion").force_target(lang)
              require("language.translate.motion").visual()
            end,
            desc = ("Translate selection to %s"):format(lang),
            opts = { silent = true },
          },
        },
      }
      order[#order + 1] = name
      translate_user[name] = lhs
    end
  end

  keymap.register(
    "language",
    { order = order, actions = translate },
    translate_user,
    { surface = "translate" }
  )

  -- Thesaurus: replace the word under the cursor with a synonym.
  local th = (cfg.thesaurus and cfg.thesaurus.keymap) or nil
  keymap.register("language", {
    order = { "replace" },
    actions = {
      replace = {
        rhs = function()
          -- Raw count: 0 means "no count" and has to stay distinguishable
          -- from 1, since no count opens the menu while `1` takes the first
          -- synonym outright.
          local n = vim.v.count
          require("language.thesaurus").replace_under_cursor(n > 0 and n or nil)
        end,
        desc = "Synonyms for word under cursor",
        opts = { silent = true },
      },
    },
  }, { replace = th }, { surface = "thesaurus" })

  if which_key ~= false then
    label_groups(cfg)
  end
end

return M
