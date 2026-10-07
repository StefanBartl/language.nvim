-- TESTS/usrcmds_help_spec.lua -- every flag of `:Translate` and `:TranslateReplace` has a line in
-- lib.nvim's option float (`:Spellcheck` declares none, and is held to the same rule).
--
-- The text comes from the `desc` of each FlagSpec in language.bindings.usrcmds. A new flag without
-- one shows up as a bare row in the cheatsheet, so this fails until it is described.

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
  end
end
