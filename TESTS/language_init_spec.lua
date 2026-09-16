-- TESTS/language_init_spec.lua — language.init: the setup() entry point that
-- wires config, commands, keymaps, autocmds and the optional hover.nvim
-- integration together. This drives the real setup() end to end (no
-- stubbing) and asserts on the observable, checkable side effects: whether
-- the commands exist, and that setup() never errors regardless of the
-- gating flags.

return function(H)
  local language = require("language")

  -- A clean slate regardless of what other specs registered first: this spec
  -- asserts on presence/absence of the three commands, so it cannot rely on
  -- run.lua's ordering to guarantee none of them exist yet.
  for _, name in ipairs({ "Spellcheck", "Translate", "TranslateReplace" }) do
    pcall(vim.api.nvim_del_user_command, name)
  end

  -- commands = false: no :Spellcheck/:Translate/:TranslateReplace ------------
  local ok1 = pcall(language.setup, { commands = false, deps_popup = false, hover = false })
  H.ok(ok1, "setup() with commands = false does not error")
  H.eq(vim.fn.exists(":Spellcheck"), 0, "commands = false: :Spellcheck is not registered")
  H.eq(vim.fn.exists(":Translate"), 0, "nor :Translate")

  -- commands = true (default): all three are registered ---------------------
  local ok2 = pcall(language.setup, { commands = true, deps_popup = false, hover = false })
  H.ok(ok2, "setup() with commands = true does not error")
  H.eq(vim.fn.exists(":Spellcheck"), 2, ":Spellcheck is registered (2 = a user command)")
  H.eq(vim.fn.exists(":Translate"), 2, ":Translate is registered")
  H.eq(vim.fn.exists(":TranslateReplace"), 2, ":TranslateReplace is registered")

  -- setup() is safe to call again (idempotent-ish, per its own docstring) ---
  local ok3 = pcall(language.setup, { commands = true, deps_popup = false, hover = false })
  H.ok(ok3, "a second setup() call does not error")

  -- The Lua facade delegates into the same submodules the commands do -------
  H.eq(type(language.spellcheck), "function", "M.spellcheck exists")
  H.eq(type(language.translate), "function", "M.translate exists")
  H.eq(type(language.translate_replace), "function", "M.translate_replace exists")
  H.eq(type(language.synonyms), "function", "M.synonyms exists")
  H.eq(type(language.open_panel), "function", "M.open_panel exists")

  -- M.health is a lazy façade over language.health, not the module itself --
  H.eq(type(language.health.check), "function", "M.health.check resolves lazily")

  -- programming_dict / extra_wordlists gating: must not error either way ----
  local ok4 = pcall(language.setup, {
    commands = true,
    deps_popup = false,
    hover = false,
    spell = { programming_dict = true, extra_wordlists = { t = { "abc" } } },
  })
  H.ok(ok4, "setup() with programming_dict/extra_wordlists enabled does not error")

  require("language.config").setup({})
end
