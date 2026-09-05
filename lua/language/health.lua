---@module 'language.health'
---@brief `:checkhealth language` — reports dependencies and provider availability.
local M = {}

local ok_s = vim.health.ok or vim.health.report_ok
local warn_s = vim.health.warn or vim.health.report_warn
local err_s = vim.health.error or vim.health.report_error
local info_s = vim.health.info or vim.health.report_info
local start_s = vim.health.start or vim.health.report_start

---@internal
---@param bin string
---@return boolean
local function exe(bin)
  return vim.fn.executable(bin) == 1
end

---@internal
---Reports Neovim version and native spell-check availability.
---@return nil
local function check_neovim()
  start_s("Neovim")
  local v = vim.version()
  if v.major > 0 or v.minor >= 9 then
    ok_s(string.format("Neovim %d.%d.%d (>= 0.9 required)", v.major, v.minor, v.patch))
  else
    err_s(
      string.format("Neovim %d.%d.%d — language.nvim requires 0.9+", v.major, v.minor, v.patch),
      { "Upgrade Neovim to 0.9+" }
    )
  end
  if type(vim.spell) == "table" and type(vim.spell.check) == "function" then
    ok_s("vim.spell.check available (native spell provider)")
  else
    err_s("vim.spell.check missing — native spell provider unavailable", {
      "Upgrade Neovim — vim.spell.check is the native spell backend",
    })
  end
end

---@internal
---Reports whether lib.nvim and its usercmd composer are installed.
---@return nil
local function check_lib()
  start_s("lib.nvim (required dependency)")
  if pcall(require, "lib.nvim.notify") then
    ok_s("lib.nvim installed (notify + cross-platform helpers)")
  else
    err_s("lib.nvim not found", { "Install StefanBartl/lib.nvim as a dependency" })
  end
  if pcall(require, "lib.nvim.bindings.usercmd.composer") then
    ok_s("lib.nvim.bindings.usercmd.composer available (:Spellcheck/:Translate/:TranslateReplace)")
  else
    err_s("lib.nvim.bindings.usercmd.composer not found — commands will fail to register", {
      "Update StefanBartl/lib.nvim",
    })
  end
end

---@internal
---Reports which optional external spell tools (typos/cspell/codespell) are on PATH.
---@return nil
local function check_spell_tools()
  start_s("Spell providers (optional external tools)")
  if exe("typos") then
    ok_s("typos — fast tree-wide spell scan available")
  else
    info_s("typos not found (optional; native provider handles cwd via chunked scan)")
  end
  if exe("cspell") then
    ok_s("cspell — CamelCase/snake_case-aware spell checking available")
  else
    info_s("cspell not found (optional)")
  end
  if exe("codespell") then
    ok_s("codespell — available")
  else
    info_s("codespell not found (optional)")
  end
  -- Persistent cspell sidecar (fast, code-aware buffer/live checks).
  if exe("cspell") and exe("node") then
    ok_s('cspell sidecar ready (node + cspell) — add "cspell_server" to spell.providers.buffer')
  elseif exe("cspell") then
    info_s("node not found — persistent cspell sidecar unavailable (one-shot cspell still works)")
  end
end

---@internal
---Reports whether a grammar LSP (harper_ls/ltex) is attached.
---@return nil
local function check_grammar()
  start_s("Grammar providers (optional LSP)")
  local clients = vim.lsp.get_clients and vim.lsp.get_clients() or {}
  local found = {}
  for _, c in ipairs(clients) do
    if c.name == "harper_ls" or c.name == "ltex" then
      found[#found + 1] = c.name
    end
  end
  if #found > 0 then
    ok_s("grammar LSP attached: " .. table.concat(found, ", "))
  else
    info_s("no grammar LSP (harper_ls / ltex) attached — grammar diagnostics disabled")
  end
end

---@internal
---Reports translate engine availability (curl, DeepL key, translate-shell).
---@return nil
local function check_translate()
  start_s("Translate engines")
  if exe("curl") then
    ok_s("curl — google (default, no key) + deepl engines ready")
  else
    err_s("curl not found — google/deepl translate engines will not work", { "Install curl" })
  end

  local ok, cfg_mod = pcall(require, "language.config")
  local key
  if ok then
    local t = cfg_mod.get().translate or {}
    key = (t.deepl and t.deepl.api_key) or nil
  end
  key = key or vim.env.DEEPL_API_KEY
  if key and key ~= "" then
    ok_s("DeepL API key configured (deepl engine usable)")
  else
    info_s("no DeepL key (set translate.deepl.api_key or $DEEPL_API_KEY) — deepl engine disabled")
  end

  if exe("trans") then
    ok_s("trans (translate-shell) — optional shell engine available")
  else
    info_s("trans not found (optional shell engine)")
  end
end

---@internal
---Reports the effective configuration and `'spelllang'` state.
---@return nil
local function check_config()
  start_s("Configuration")
  local ok, cfg_mod = pcall(require, "language.config")
  if not ok then
    err_s("cannot load language.config", { "Call require('language').setup() in your config" })
    return
  end
  local cfg = cfg_mod.get()
  local sp = cfg.spell or {}
  info_s("spell.default_scope = " .. tostring(sp.default_scope))
  info_s(
    "spell.live = " .. tostring(sp.live) .. " (live_scope = " .. tostring(sp.live_scope) .. ")"
  )
  info_s("spell.filetypes = " .. table.concat(sp.filetypes or {}, ", "))
  info_s("translate.engine = " .. tostring((cfg.translate or {}).engine))

  local sl = vim.o.spelllang
  if sl and sl ~= "" then
    ok_s("'spelllang' = " .. sl)
  else
    warn_s("'spelllang' is empty", { "Set it, e.g. `vim.o.spelllang = 'en'`" })
  end
end

---@internal
---Reports whether which-key is installed for group labels.
---@return nil
local function check_which_key()
  start_s("which-key (optional)")
  if pcall(require, "which-key") then
    ok_s("which-key installed — group labels registered")
  else
    info_s("which-key not found (optional; keymap `desc` fields still work standalone)")
  end
end

---@internal
---Reports language.nvim's own docs/install.json via lib.nvim.deps — the
---same `curl` check_translate() already probes, but with its declared
---`why` and a pointer to `:Lib deps show`. Does nothing if lib.nvim.deps
---is unavailable (older lib.nvim).
---@return nil
local function check_lib_deps()
  local ok, deps_health = pcall(require, "lib.nvim.deps.health")
  if not ok then
    return
  end
  start_s("declared tools (lib.nvim.deps)")
  deps_health.report_for("language.nvim")
end

---@internal
---The hover.nvim contribution, and the four states that look alike from outside.
---
--- "`:Hover show` says nothing over a word" has four unrelated causes and one
--- appearance, which is the whole reason this section exists: the switch is
--- off, hover.nvim is not installed, it is installed but too old to honour
--- `on_request`, or everything is wired and the endpoint is the problem. Only
--- the third is a defect, and the last one is reported by the float itself.
---@return nil
local function check_hover()
  start_s("hover.nvim integration (optional)")

  local ok_cfg, config = pcall(require, "language.config")
  if ok_cfg and config.get().hover == false then
    info_s("hover = false -- nothing registered")
    return
  end

  if not pcall(require, "hover.registry") then
    info_s("hover.nvim not installed -- nothing registered, nothing missing")
    return
  end

  local ok_mod, hover = pcall(require, "language.hover")
  if not ok_mod then
    err_s("language.hover failed to load -- the contribution cannot be registered", {
      "Reinstall language.nvim",
    })
    return
  end

  if not hover.registered() then
    warn_s("hover.nvim is installed, but nothing is registered", {
      "setup() registers this; call require('language').setup({}) if you have not.",
    })
    return
  end

  -- The flag is reported rather than assumed. An older hover.nvim ignores an
  -- unknown `on_request` and asks the contribution on the *automatic* trigger
  -- -- which would turn every quiet moment over a word into a request to a
  -- translation endpoint carrying that word. That is the one failure here
  -- nobody would notice from the outside, so it is checked rather than trusted.
  local honoured = false
  local ok_reg, registry = pcall(require, "hover.registry")
  if ok_reg and type(registry.contributors) == "function" then
    for _, c in ipairs(registry.contributors() or {}) do
      if c.name == "language.nvim" and (c.on_request or 0) > 0 then
        honoured = true
      end
    end
  end

  if not honoured then
    warn_s("hover.nvim does not report the contribution as on_request", {
      "This one is worth acting on: without the flag the automatic hover",
      "trigger asks for a translation, and every quiet moment over a word",
      "becomes a network request carrying that word. Update hover.nvim.",
    })
    return
  end

  ok_s(
    ("registered, on request only -- `:Hover show` over a word translates it to %s"):format(
      hover.target()
    )
  )
  if not (ok_cfg and type(config.get().translate.default_target) == "string") then
    info_s(
      "translate.default_target is unset, so the hover falls back to EN -- set it to translate into your own language"
    )
  end
end

---Run all `:checkhealth language` sections.
---@return nil
function M.check()
  check_neovim()
  check_lib()
  check_spell_tools()
  check_grammar()
  check_translate()
  check_config()
  check_which_key()
  check_hover()
  check_lib_deps()

  require("lib.nvim.bindings.usercmd.composer").checkhealth("Spellcheck")
  require("lib.nvim.bindings.usercmd.composer").checkhealth("Translate")
  require("lib.nvim.bindings.usercmd.composer").checkhealth("TranslateReplace")
end

return M
