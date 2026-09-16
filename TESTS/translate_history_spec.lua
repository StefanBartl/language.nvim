-- TESTS/translate_history_spec.lua — language.translate.history: the
-- recent-translation ring, plus its optional JSON persistence (redirected to
-- a fixture file rather than the real `stdpath("state")` one).

return function(H)
  local config = require("language.config")
  local dir, cleanup = H.fixture("translate-history")
  local hist_file = dir .. "/translate_history.json"

  config.setup({
    translate = { history = { enable = true, max = 3, persist = true, file = hist_file } },
  })
  package.loaded["language.translate.history"] = nil
  local history = require("language.translate.history")

  H.eq(#history.entries(), 0, "starts empty")

  history.record({ input = { "hello" }, output = { "bonjour" }, target = "FR" })
  H.eq(#history.entries(), 1, "one entry recorded")
  H.eq(history.entries()[1].output[1], "bonjour", "with the translated output")
  H.ok(history.entries()[1].time, "record() stamps a time when the caller omits one")

  -- A record with no output is not a translation worth remembering.
  history.record({ input = { "x" }, output = {}, target = "FR" })
  H.eq(#history.entries(), 1, "an empty-output record is ignored")
  ---@diagnostic disable-next-line: missing-fields
  history.record({ input = { "x" } })
  H.eq(#history.entries(), 1, "a malformed record (no output at all) is ignored too")

  -- Re-recording the same (input, target) moves it to the front rather than
  -- duplicating it.
  history.record({ input = { "second" }, output = { "deuxieme" }, target = "FR" })
  history.record({ input = { "hello" }, output = { "salut" }, target = "FR" })
  H.eq(#history.entries(), 2, "the repeated (input, target) replaces, not appends")
  H.eq(history.entries()[1].output[1], "salut", "the newest version is at the front")

  -- Capped at `max` -----------------------------------------------------------
  history.record({ input = { "third" }, output = { "troisieme" }, target = "FR" })
  history.record({ input = { "fourth" }, output = { "quatrieme" }, target = "FR" })
  H.eq(#history.entries(), 3, "the ring never exceeds translate.history.max")
  H.eq(history.entries()[1].output[1], "quatrieme", "newest first")

  -- Persistence: written to the fixture file, reloaded by a fresh module ----
  H.ok(vim.fn.filereadable(hist_file) == 1, "persist = true writes the history to disk")
  package.loaded["language.translate.history"] = nil
  local reloaded = require("language.translate.history")
  H.eq(#reloaded.entries(), 3, "a fresh module instance reloads the persisted ring")
  H.eq(reloaded.entries()[1].output[1], "quatrieme", "in the same order")

  -- label() ------------------------------------------------------------------
  local label = history.label({ input = { "hi" }, output = { "salut" }, target = "FR" })
  H.eq(label, "[FR] hi \226\134\146 salut", "target, clipped input, arrow, clipped output")

  local long = ("word "):rep(20)
  local clipped = history.label({ input = { long }, output = { "ok" }, target = "EN" })
  H.ok(
    #clipped < #("[EN] " .. long .. " \226\134\146 ok"),
    "a long input is clipped with an ellipsis"
  )

  -- clear() -------------------------------------------------------------------
  history.clear()
  H.eq(#history.entries(), 0, "clear() empties the ring")
  H.eq(H.read(hist_file), "[]", "and persists the empty ring to disk")

  -- disabled: record() is a no-op ---------------------------------------------
  config.setup({ translate = { history = { enable = false, max = 3, persist = false, file = "" } } })
  package.loaded["language.translate.history"] = nil
  local disabled = require("language.translate.history")
  disabled.record({ input = { "x" }, output = { "y" }, target = "EN" })
  H.eq(#disabled.entries(), 0, "history.enable = false: record() does nothing")

  package.loaded["language.translate.history"] = nil
  config.setup({})
  cleanup()
end
