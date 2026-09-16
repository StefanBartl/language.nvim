-- TESTS/regions_spec.lua — language.spell.core.regions: the Treesitter
-- @spell/@nospell region predicate, and the fail-open path when there is
-- nothing to restrict against.

return function(H)
  local regions = require("language.spell.core.regions")

  -- build() fails open (returns nil) whenever there is no usable parser --
  -- a buffer with no filetype is the cheapest way to hit that without needing
  -- a real Treesitter grammar installed in the test environment.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  H.eq(regions.build(buf), nil, "no filetype: build() returns nil (treat everything as spellable)")

  vim.bo[buf].filetype = "some-unknown-filetype-xyz"
  H.eq(regions.build(buf), nil, "an unresolvable filetype also returns nil")

  vim.api.nvim_buf_delete(buf, { force = true })

  -- is_spellable is pure and independent of Treesitter: exercise it directly
  -- against a hand-built regions table.
  ---@type Language.SpellRegions
  local built = {
    spell = { { 0, 5, 0, 10 } }, -- row 0, cols [5,10)
    nospell = { { 0, 0, 0, 5 } }, -- row 0, cols [0,5)
  }

  H.ok(regions.is_spellable(built, 1, 6), "col 6 (1-based) falls inside the @spell range")
  H.falsy(regions.is_spellable(built, 1, 1), "col 1 falls inside @nospell")
  H.falsy(regions.is_spellable(built, 1, 20), "outside both ranges is not spellable")

  -- @nospell wins over @spell when both would otherwise match — the region
  -- predicate is a carve-out, not a second vote.
  local overlapping = {
    spell = { { 0, 0, 0, 10 } },
    nospell = { { 0, 2, 0, 4 } },
  }
  H.ok(regions.is_spellable(overlapping, 1, 1), "before the nospell carve-out: spellable")
  H.falsy(regions.is_spellable(overlapping, 1, 3), "inside the nospell carve-out: not spellable")
  H.ok(regions.is_spellable(overlapping, 1, 5), "after the nospell carve-out: spellable again")

  H.falsy(
    regions.is_spellable({ spell = {}, nospell = {} }, 1, 1),
    "no @spell ranges at all: nothing is spellable"
  )
end
