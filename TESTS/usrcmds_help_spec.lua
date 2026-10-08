-- TESTS/usrcmds_help_spec.lua -- every flag and positional argument of `:Translate`,
-- `:TranslateReplace` and `:Spellcheck` has a line in lib.nvim's option float.
--
-- The flag text comes from the `desc` of each FlagSpec in language.bindings.usrcmds, the argument
-- text from the text of its type (`TRANSLATE_LANG`, `TRANSLATE_SCOPE`, `SPELL_LANG`,
-- `SPELL_SCOPE`: written once, shown for every argument of that type). A new flag or argument
-- without one shows up as a bare row in the cheatsheet, so this fails until it is described.

return function(H)
  local ok, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  H.ok(ok, "the composer loads")

  -- A lib.nvim older than `help.undocumented` cannot answer the question; that is a missing
  -- feature of the dependency, not a defect of this plugin.
  if type(composer.help.undocumented) ~= "function" then
    return
  end

  require("language.bindings.usrcmds").setup()

  for _, name in ipairs({ "Spellcheck", "Translate", "TranslateReplace" }) do
    H.ok(composer.registry()[name] ~= nil, ":" .. name .. " is registered through the composer")

    local missing = {}
    for _, m in ipairs(composer.help.undocumented(name)) do
      missing[#missing + 1] = m.name
    end
    H.eq(
      #missing,
      0,
      ":" .. name .. " options without a help text: " .. table.concat(missing, ", ")
    )

    local missing_args = {}
    for _, m in ipairs(composer.help.undocumented(name, { args = true })) do
      missing_args[#missing_args + 1] = m.kind .. ":" .. m.name
    end
    H.eq(
      #missing_args,
      0,
      ":" .. name .. " entries without a help text: " .. table.concat(missing_args, ", ")
    )
  end

  -- The type texts follow the house style: one line, no trailing period, at most 80 characters.
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  for _, type_name in ipairs({ "TRANSLATE_LANG", "TRANSLATE_SCOPE", "SPELL_LANG", "SPELL_SCOPE" }) do
    local text = argtypes.get(type_name).desc or ""
    H.ok(text ~= "", type_name .. " has a help text")
    H.ok(
      not text:find("\n", 1, true) and text:sub(-1) ~= "." and #text <= 80,
      type_name .. " text is one line, without a trailing period, <= 80 characters: " .. text
    )
  end
end
