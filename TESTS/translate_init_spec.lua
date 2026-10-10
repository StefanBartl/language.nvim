-- TESTS/translate_init_spec.lua — language.translate: scope → provider →
-- output, the domain entry point. `language.translate.providers.registry` is
-- stubbed (the same technique hover_spec.lua uses for its provider), so this
-- exercises the real dispatch/scope logic without curl or a real engine.

return function(H)
  ---@type table[]
  local translate_calls

  --- Install a fake provider that answers synchronously via `answer`, and
  --- point the registry at it.
  ---@param ok boolean
  ---@param answer string[]|string
  local function stub_provider(ok, answer)
    translate_calls = {}
    package.loaded["language.translate.providers.registry"] = {
      resolve = function()
        return {
          translate = function(lines, target, source, cfg, cb)
            translate_calls[#translate_calls + 1] =
              { lines = lines, target = target, source = source, cfg = cfg }
            cb(ok, answer)
            return nil
          end,
        }
      end,
    }
  end

  local function stub_unavailable()
    package.loaded["language.translate.providers.registry"] = {
      resolve = function()
        return nil, "no available translate engine (tried: google)"
      end,
    }
  end

  local function reload_translate()
    package.loaded["language.translate"] = nil
    return require("language.translate")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })

  -- run(): guards -------------------------------------------------------------
  stub_provider(true, { "ONE" })
  local translate = reload_translate()
  translate.run("", { scope = { kind = "buffer", bufnr = buf } })
  H.eq(#translate_calls, 0, "an empty target language never reaches the provider")

  stub_unavailable()
  translate = reload_translate()
  translate.run("FR", { scope = { kind = "buffer", bufnr = buf } })
  -- No assertion beyond "did not error": there is no provider to have called.

  -- run(): buffer scope, replace mode -----------------------------------------
  stub_provider(true, { "ONE", "TWO", "THREE" })
  translate = reload_translate()
  translate.run("FR", { output = "replace", scope = { kind = "buffer", bufnr = buf } })
  H.eq(#translate_calls, 1, "one provider call for a whole-buffer replace")
  H.eq(translate_calls[1].target, "FR", "with the requested target")
  H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "ONE", "and the buffer is really replaced")

  -- run(): selection scope -----------------------------------------------------
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  stub_provider(true, { "TWO" })
  translate = reload_translate()
  translate.run(
    "FR",
    { output = "replace", scope = { kind = "selection", bufnr = buf, range = { s = 2, e = 2 } } }
  )
  H.eq(
    table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|"),
    "one|TWO|three",
    "only the selected line is replaced"
  )

  -- run(): cword scope goes through run_region, not the line-range path -----
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  stub_provider(true, { "HELLO" })
  translate = reload_translate()
  translate.run("FR", {
    output = "replace",
    scope = { kind = "cword", bufnr = buf, region = { sr = 0, sc = 0, er = 0, ec = 5 } },
  })
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "HELLO world",
    "only the word's byte span is replaced, not the whole line"
  )

  -- cword with no region under the cursor: declines rather than falling
  -- through to translate the whole buffer.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  stub_provider(true, { "X" })
  translate = reload_translate()
  translate.run("FR", { output = "replace", scope = { kind = "cword", bufnr = buf, region = nil } })
  H.eq(#translate_calls, 0, "no word under the cursor: the provider is never called")
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "hello world",
    "and the buffer is untouched"
  )

  -- run(): cwd/path is explicitly rejected here (routed to run_files instead,
  -- by the command layer, before M.run ever sees it) ------------------------
  stub_provider(true, { "X" })
  translate = reload_translate()
  translate.run("FR", { output = "replace", scope = { kind = "cwd" } })
  H.eq(#translate_calls, 0, "cwd is rejected, not silently translated as a buffer")

  -- run_region(): guards --------------------------------------------------
  stub_provider(true, { "X" })
  translate = reload_translate()
  translate.run_region("", { bufnr = buf, sr = 0, sc = 0, er = 0, ec = 1 })
  H.eq(#translate_calls, 0, "an empty target rejects before touching the provider")

  translate.run_region("FR", { bufnr = -1, sr = 0, sc = 0, er = 0, ec = 1 })
  H.eq(#translate_calls, 0, "an invalid buffer likewise")

  -- run_region(): non-replace output goes through language.translate.output,
  -- not a direct buffer edit.
  --
  -- Whether the "+" register actually receives it depends on the machine
  -- (see TESTS/translate_output_spec.lua's clipboard block for why), so
  -- it's probed here too rather than assumed.
  vim.fn.setreg("+", "")
  local clipboard_works = require("lib.nvim.cross.copy_to_clipboard")("init_spec_probe")
  vim.fn.setreg("+", "")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  stub_provider(true, { "clip text" })
  translate = reload_translate()
  translate.run_region("FR", { bufnr = buf, sr = 0, sc = 0, er = 0, ec = 5, output = "clipboard" })
  if clipboard_works then
    H.eq(vim.fn.getreg("+"), "clip text", "'clipboard' output really goes through output.apply")
  else
    H.eq(vim.fn.getreg("+"), "", "no clipboard provider means the register stays untouched")
  end
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "hello world",
    "and the buffer itself is untouched"
  )

  -- A failed provider call is reported, not silently swallowed (no direct
  -- assertion on the notification itself, just that nothing mutates and the
  -- call still completes without erroring).
  stub_provider(false, "engine exploded")
  translate = reload_translate()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  translate.run("FR", { output = "replace", scope = { kind = "buffer", bufnr = buf } })
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "hello world",
    "a failed translation leaves the buffer untouched"
  )

  -- run_region(): ERR-30 -- a concurrent edit to the exact span, landing
  -- while the request was "in flight", is not blindly overwritten.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  package.loaded["language.translate.providers.registry"] = {
    resolve = function()
      return {
        translate = function(_lines, _target, _source, _pcfg, cb)
          vim.api.nvim_buf_set_text(buf, 0, 0, 0, 5, { "edited" })
          cb(true, { "HELLO" })
        end,
      }
    end,
  }
  translate = reload_translate()
  translate.run_region("FR", { bufnr = buf, sr = 0, sc = 0, er = 0, ec = 5, output = "replace" })
  H.eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1],
    "edited world",
    "the concurrent edit survives -- the stale translation was discarded, not written over it"
  )

  -- line-based replace/insert/--nocode: the same guard against a buffer that
  -- changed while the request was in flight. The fake provider holds every
  -- callback; `release()` answers them once the test has edited the buffer.
  do
    local held, recorded
    package.loaded["language.translate.history"] = {
      record = function(entry)
        recorded[#recorded + 1] = entry
      end,
    }
    package.loaded["language.translate.providers.registry"] = {
      resolve = function()
        return {
          translate = function(lines, _t, _s, _c, cb)
            held[#held + 1] = function()
              local out = {}
              for i, l in ipairs(lines) do
                out[i] = l == "" and l or ("[FR] " .. l)
              end
              cb(true, out)
            end
          end,
        }
      end,
    }
    local function release()
      for _, f in ipairs(held) do
        f()
      end
    end
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
    end
    local function fresh(lines)
      held, recorded = {}, {}
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      translate = reload_translate()
    end
    local sel = { kind = "selection", bufnr = buf, range = { s = 3, e = 4 } }
    local five = { "one", "two", "three", "four", "five" }

    for _, mode in ipairs({ "replace", "insert" }) do
      fresh(five)
      translate.run("FR", { output = mode, scope = sel })
      release()
      H.eq(
        text(),
        mode == "replace" and "one|two|[FR] three|[FR] four|five"
          or "one|two|three|four|[FR] three|[FR] four|five",
        mode .. ": an untouched range is written as before"
      )
      H.eq(#recorded, 1, mode .. ": and recorded in the history")

      fresh(five)
      translate.run("FR", { output = mode, scope = sel })
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "NEW-A", "NEW-B" })
      release()
      H.eq(
        text(),
        "NEW-A|NEW-B|one|two|three|four|five",
        mode .. ": a line inserted above discards"
      )
      H.eq(#recorded, 0, mode .. ": and nothing is recorded")

      fresh(five)
      translate.run("FR", { output = mode, scope = sel })
      vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "edited" })
      release()
      H.eq(text(), "one|two|edited|four|five", mode .. ": an edit inside the range discards")

      fresh(five)
      translate.run("FR", { output = mode, scope = sel })
      vim.api.nvim_buf_set_lines(buf, 1, -1, false, {})
      release()
      H.eq(text(), "one", mode .. ": a range that no longer exists discards")
    end

    -- buffer wiped while waiting: nothing to write to, and no error
    local gone = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(gone, 0, -1, false, { "a", "b" })
    held, recorded = {}, {}
    translate = reload_translate()
    translate.run("FR", { output = "replace", scope = { kind = "buffer", bufnr = gone } })
    vim.api.nvim_buf_delete(gone, { force = true })
    H.ok(pcall(release), "a deleted buffer is survived")
    H.eq(#recorded, 0, "and not recorded")

    -- --nocode: all ranges or none
    local doc = { "alpha", "", "```", "code()", "```", "", "omega" }
    fresh(doc)
    translate.run(
      "FR",
      { output = "replace", nocode = true, scope = { kind = "buffer", bufnr = buf } }
    )
    H.ok(#held >= 2, "the prose around a fence is translated in separate requests")
    release()
    H.eq(
      text(),
      "[FR] alpha||```|code()|```||[FR] omega",
      "--nocode: untouched ranges are written, the fence is left alone"
    )

    fresh(doc)
    translate.run(
      "FR",
      { output = "replace", nocode = true, scope = { kind = "buffer", bufnr = buf } }
    )
    vim.api.nvim_buf_set_lines(buf, 6, 7, false, { "omega!" })
    release()
    H.eq(
      text(),
      "alpha||```|code()|```||omega!",
      "--nocode: one drifted range discards every range, nothing is half-translated"
    )

    fresh(doc)
    translate.run(
      "FR",
      { output = "replace", nocode = true, scope = { kind = "buffer", bufnr = buf } }
    )
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "NEW" })
    release()
    H.eq(text(), "NEW|alpha||```|code()|```||omega", "--nocode: a line inserted above discards")

    package.loaded["language.translate.history"] = nil
  end

  vim.api.nvim_buf_delete(buf, { force = true })
  package.loaded["language.translate.providers.registry"] = nil
  package.loaded["language.translate"] = nil
end
