-- TESTS/translate_subtitle_spec.lua — language.translate.subtitle: SRT/WebVTT
-- files are translated cue text only. Index, timing, header, NOTE/STYLE lines
-- and tags must come out byte-identical; the engine never sees them.
--
-- The provider is a fake that marks every line it is given, so a line that
-- reached the engine can be told from one that did not.

return function(H)
  -- Every spec file shares one editor: put back what this one creates, also on failure (see H.tracked).
  H.tracked(function()
    local subtitle = require("language.translate.subtitle")
    local filter = require("language.translate.filter")
    local files = require("language.translate.files")
    local config = require("language.config")

    -- What `:Media transcribe out=srt` writes (media.nvim), plus a two-line cue
    -- with tags, a positioning override and a music cue.
    local SRT = {
      "1",
      "00:00:01,000 --> 00:00:03,500",
      "Hello there.",
      "",
      "2",
      "00:00:04,120 --> 00:00:07,300",
      "<i>This is the first line</i>",
      "and {\\an8}the second line.",
      "",
      "3",
      "00:00:08,000 --> 00:00:09,000",
      "♪",
      "",
    }

    local VTT = {
      "WEBVTT - the header text",
      "",
      "NOTE a comment",
      "with --> in it? no, never",
      "",
      "STYLE",
      "::cue { color: red }",
      "",
      "intro",
      "00:01.000 --> 00:03.000 align:start",
      "Welcome, <v Roger>friends</v>.",
      "",
      "00:04.000 --> 00:06.000",
      "At <00:05.000>last.",
    }

    ---@return string[] marked lines the fake saw, in order
    local seen
    --- A provider that prefixes every line it is given with `>>`.
    local function marking(mangle)
      seen = {}
      return {
        translate = function(lines, _target, _source, _cfg, cb)
          for _, l in ipairs(lines) do
            seen[#seen + 1] = l
          end
          local out = {}
          for i, l in ipairs(lines) do
            out[i] = l == "" and "" or (">>" .. (mangle and mangle(l) or l))
          end
          cb(true, out)
        end,
      }
    end

    local function run(provider, lines, kind, range)
      local got
      subtitle.translate(provider, lines, kind, "DE", {}, function(ok, result, info)
        got = { ok = ok, result = result, info = info }
      end, range)
      vim.wait(500, function()
        return got ~= nil
      end)
      H.ok(got, "the callback ran")
      return got
    end

    -- cue_ranges ------------------------------------------------------------
    local r = subtitle.cue_ranges(SRT, "srt")
    H.eq(#r, 3, "srt: three cues")
    H.eq(
      r[1].s .. "-" .. r[1].e,
      "3-3",
      "srt: the text of cue 1 is line 3, not the index or the timing"
    )
    H.eq(r[2].s .. "-" .. r[2].e, "7-8", "srt: a two-line cue is one range")

    r = subtitle.cue_ranges(VTT, "vtt")
    H.eq(#r, 2, "vtt: two cues; header, NOTE and STYLE are not cues")
    H.eq(r[1].s .. "-" .. r[1].e, "11-11", "vtt: the identifier line and the settings are skipped")
    H.eq(r[2].s .. "-" .. r[2].e, "14-14", "vtt: a cue without identifier")

    H.eq(
      #subtitle.cue_ranges({ "1", "00:00:01,000 --> 00:00:02,000", "", "2" }, "srt"),
      0,
      "a cue without text has no range"
    )

    -- a file that lost the blank line between two cues: split at the timing lines, none of them is cue text
    do
      local broken = {
        "1",
        "00:00:01,000 --> 00:00:02,000",
        "Hello",
        "2",
        "00:00:03,000 --> 00:00:04,000",
        "World",
        "3",
        "00:00:05,000 --> 00:00:06,000",
        "!",
      }
      local br = subtitle.cue_ranges(broken, "srt")
      H.eq(#br, 3, "no blank line: still three cues")
      H.eq(
        br[1].s .. "-" .. br[1].e,
        "3-3",
        "no blank line: the first text, without the next index"
      )
      H.eq(br[2].s .. "-" .. br[2].e, "6-6", "no blank line: the second text")
      for _, range in ipairs(br) do
        for l = range.s, range.e do
          H.ok(
            not broken[l]:find("-->", 1, true),
            "no blank line: a timing line is never in a text range"
          )
        end
      end
    end

    -- detection --------------------------------------------------------------
    H.eq(subtitle.detect("/x/movie.SRT", "", {}), "srt", "by extension, any case")
    H.eq(subtitle.detect("", "vtt", {}), "vtt", "by filetype")
    H.eq(subtitle.detect("", "", SRT), "srt", "a scratch buffer is recognised by its content")
    H.eq(subtitle.detect("", "", VTT), "vtt", "...by the WEBVTT header")
    H.eq(
      subtitle.detect("/x/notes.md", "markdown", { "10:30 --> 11:45 meeting" }),
      nil,
      "a Markdown file with an arrow line stays prose"
    )
    H.eq(subtitle.detect("", "", { "plain", "prose" }), nil, "prose is not a subtitle")

    -- translate: SRT ---------------------------------------------------------
    local got = run(marking(), SRT, "srt")
    H.ok(got.ok, "srt: translated")
    local out = got.result
    H.eq(#out, #SRT, "srt: same line count")
    for _, i in ipairs({ 1, 2, 4, 5, 6, 9, 10, 11, 13 }) do
      H.eq(out[i], SRT[i], ("srt: line %d (index, timing, blank) is byte-identical"):format(i))
    end
    H.eq(out[3], ">>Hello there.", "srt: cue text is translated")
    H.eq(out[7], ">><i>This is the first line</i>", "srt: tags come back in place")
    H.eq(out[8], ">>and {\\an8}the second line.", "srt: positioning override comes back")
    H.eq(out[12], "♪", "srt: a cue with only a music note is not sent")
    for _, l in ipairs(seen) do
      H.falsy(l:find("-->", 1, true), "the engine never sees a timing line")
      H.falsy(l:find("<i>", 1, true), "the engine never sees a tag")
      H.falsy(l:find("{\\an8}", 1, true), "the engine never sees an override")
    end
    H.eq(got.info.total, 3, "info: three cues")
    H.eq(got.info.sent, 2, "info: two went out")
    H.eq(got.info.kept, 0, "info: none kept")

    -- one request, cue boundaries are blank lines
    H.eq(
      table.concat(seen, "|"),
      "Hello there.||{1}This is the first line{2}|and {1}the second line.",
      "the payload: cue text only, blank line between cues"
    )
    H.eq(seen[3], "{1}This is the first line{2}", "tags are placeholders")

    -- translate: VTT ---------------------------------------------------------
    got = run(marking(), VTT, "vtt")
    out = got.result
    for _, i in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13 }) do
      H.eq(
        out[i],
        VTT[i],
        ("vtt: line %d (header, NOTE, STYLE, identifier, timing) is byte-identical"):format(i)
      )
    end
    H.eq(out[11], ">>Welcome, <v Roger>friends</v>.", "vtt: voice tag kept")
    H.eq(out[14], ">>At <00:05.000>last.", "vtt: timestamp tag kept")

    -- a range selects part of the document, cue boundaries still come from the whole
    got = run(marking(), SRT, "srt", { s = 7, e = 8 })
    H.eq(#got.result, 2, "range: only the requested lines come back")
    H.eq(got.result[1], ">><i>This is the first line</i>", "range: the cue inside is translated")
    got = run(marking(), SRT, "srt", { s = 2, e = 3 })
    H.eq(got.result[1], SRT[2], "range: a timing line inside the range stays")
    H.eq(got.result[2], ">>Hello there.", "range: the cue text is translated")

    -- a mangled placeholder keeps the cue in the source language
    got = run(
      marking(function(l)
        return (l:gsub("{1}", ""))
      end),
      SRT,
      "srt"
    )
    H.eq(got.result[7], SRT[7], "mangled: the cue keeps its source text")
    H.eq(got.result[8], SRT[8], "mangled: all lines of that cue")
    H.eq(got.result[3], ">>Hello there.", "mangled: other cues are translated")
    H.eq(got.info.kept, 1, "mangled: counted")

    -- an engine that changes the line structure writes nothing
    got = run({
      translate = function(_, _, _, _, cb)
        cb(true, { "only one line" })
      end,
    }, SRT, "srt")
    H.falsy(got.ok, "structure: an answer with another line count fails")
    H.contains(got.result, "nothing was written", "structure: and says so")

    got = run({
      translate = function(lines, _, _, _, cb)
        local o = {}
        for i, l in ipairs(lines) do
          o[i] = l == "" and "not blank" or l
        end
        cb(true, o)
      end,
    }, SRT, "srt")
    H.falsy(got.ok, "structure: a separator that did not come back blank fails")

    got = run({
      translate = function(lines, _, _, _, cb)
        local o = {}
        for i in ipairs(lines) do
          o[i] = i == 1 and 42 or lines[i]
        end
        cb(true, o)
      end,
    }, SRT, "srt")
    H.falsy(got.ok, "structure: a line that is no string fails, it does not raise")
    H.contains(got.result, "nothing was written", "structure: and says so, too")

    -- an engine error is passed on
    got = run({
      translate = function(_, _, _, _, cb)
        cb(false, "boom")
      end,
    }, SRT, "srt")
    H.falsy(got.ok, "error: passed on")
    H.eq(got.result, "boom", "error: unchanged")

    -- nothing to translate: no request
    local called = false
    got = run({
      translate = function()
        called = true
      end,
    }, { "1", "00:00:01,000 --> 00:00:02,000", "♪" }, "srt")
    H.ok(got.ok, "nothing to say: ok")
    H.falsy(called, "nothing to say: the engine is not asked")

    -- a literal {1} in the source cannot be confused with a placeholder
    got = run(marking(), { "1", "00:00:01,000 --> 00:00:02,000", "see {1} and <b>bold</b>" }, "srt")
    H.eq(got.result[3], ">>see {1} and <b>bold</b>", "a literal {1} survives")

    -- filter.subtitle_ranges --------------------------------------------------
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, SRT)
    local ranges = filter.subtitle_ranges(buf, 1, #SRT)
    H.eq(#ranges, 3, "filter: three cue ranges")
    H.eq(ranges[2].s .. "-" .. ranges[2].e, "7-8", "filter: a two-line cue is one range")
    ranges = filter.subtitle_ranges(buf, 8, 8)
    H.eq(#ranges, 1, "filter: a selection cuts a cue to the selected lines")
    H.eq(ranges[1].s .. "-" .. ranges[1].e, "8-8", "filter: ...to line 8")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "just prose" })
    H.eq(#filter.subtitle_ranges(buf, 1, 1), 0, "filter: prose has no cue ranges")

    -- translate.run on a subtitle buffer: replace keeps timing and index ------
    local sbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, SRT)
    vim.api.nvim_buf_set_name(sbuf, vim.fn.tempname() .. ".srt")
    package.loaded["language.translate.providers.registry"] = {
      resolve = function()
        return marking()
      end,
    }
    package.loaded["language.translate"] = nil
    local translate = require("language.translate")
    translate.run(
      "DE",
      { output = "replace", nocode = true, scope = { kind = "buffer", bufnr = sbuf } }
    )
    vim.wait(500, function()
      return vim.api.nvim_buf_get_lines(sbuf, 0, 3, false)[3] == ">>Hello there."
    end)
    local after = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
    H.eq(after[2], SRT[2], "run: the timing line is untouched")
    H.eq(after[3], ">>Hello there.", "run: the cue is translated, even with --nocode")
    H.eq(after[6], SRT[6], "run: the second timing line is untouched")
    package.loaded["language.translate.providers.registry"] = nil
    package.loaded["language.translate"] = nil

    -- files: .srt / .vtt are picked up and processed cue text only -------------
    local defaults = require("language.config.DEFAULTS")
    local have = {}
    for _, e in ipairs(defaults.translate.files.extensions) do
      have[e] = true
    end
    H.ok(have.srt and have.vtt, "files: srt and vtt are default extensions")

    local dir, cleanup = H.fixture("translate-subtitle")
    vim.fn.writefile(SRT, dir .. "/film.srt")
    vim.fn.writefile(VTT, dir .. "/film.vtt")
    config.setup({ translate = { history = { enable = false } } })
    local found = {}
    for _, f in
      ipairs(files.gather(dir, { files = { extensions = { "srt", "vtt" }, max_kb = 512 } }))
    do
      found[#found + 1] = f.rel
    end
    H.eq(table.concat(found, ","), "film.srt,film.vtt", "files: gathered")

    local done = false
    files.process(
      marking(),
      {
        { rel = "film.srt", abs = dir .. "/film.srt" },
        { rel = "film.vtt", abs = dir .. "/film.vtt" },
      },
      "DE",
      "suffix",
      function()
        done = true
      end
    )
    vim.wait(2000, function()
      return done
    end)
    H.ok(done, "files: processed")
    local srt_out = vim.fn.readfile(dir .. "/film.DE.srt")
    H.eq(srt_out[2], SRT[2], "files: the timing line of the .srt is byte-identical")
    H.eq(srt_out[3], ">>Hello there.", "files: the cue text of the .srt is translated")
    local vtt_out = vim.fn.readfile(dir .. "/film.DE.vtt")
    H.eq(vtt_out[1], VTT[1], "files: the WEBVTT header is byte-identical")
    H.eq(vtt_out[10], VTT[10], "files: the timing line with settings is byte-identical")
    H.eq(vtt_out[11], ">>Welcome, <v Roger>friends</v>.", "files: the vtt cue is translated")
    cleanup()
  end)
end
