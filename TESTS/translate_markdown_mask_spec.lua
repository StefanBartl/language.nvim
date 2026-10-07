-- TESTS/translate_markdown_mask_spec.lua -- translate/markdown/mask.lua: what is
-- protected, that the placeholder is ASCII, and the gate that decides whether an
-- engine's answer may be accepted.

return function(H)
  local mask = require("language.translate.markdown.mask")

  ---@param text string
  ---@param opts? table
  local function roundtrip(text, opts)
    local masked, mk = mask.mask(text, opts)
    return masked, mk, mask.unmask(masked, mk)
  end

  -- Whatever is masked comes back byte for byte.
  local samples = {
    "Ein `code` und ``zwei `ticks` drin`` ok",
    'Siehe [Text](https://x.y/a_(b) "Titel") und ![Alt](bild.png).',
    "Referenz [Text][ref] und [Kollaps][] und [kurz].",
    "Auto <https://example.org> und <mail@example.org> und <b>fett</b> und <!-- c -->.",
    "Entity &amp; und &#123; und {#id} und {.klasse} und {3}.",
    "Bare https://example.org/pfad?x=1. Ende und Fussnote[^1].",
    "Escaped \\`nicht\\` und \\[nicht\\](x) bleibt.",
    "[Verschachtelt ![Bild](a.png) im Text](https://x.y)",
    "Ungeschlossen `ticks und [klammer und <tag und &",
    "",
    "nur Text",
  }
  for _, s in ipairs(samples) do
    local _, _, back = roundtrip(s, { defs = { ["kurz"] = true } })
    H.eq(back, s, "round trip: " .. s)
  end

  -- inline code ----------------------------------------------------------------------
  do
    local masked, mk = mask.mask("Nutze `foo bar` jetzt")
    H.eq(masked, "Nutze {1} jetzt")
    H.eq(mk.toks[1], "`foo bar`")
    masked, mk = mask.mask("Doppelt ``a ` b`` hier")
    H.eq(masked, "Doppelt {1} hier", "a longer run closes only with a run of its own length")
    H.eq(mk.toks[1], "``a ` b``")
    masked = mask.mask("Offen `ticks bleiben")
    H.eq(masked, "Offen `ticks bleiben", "an unclosed backtick is plain text")
  end

  -- links: the text stays translatable, both halves are placeholders ------------------------
  do
    local masked, mk = mask.mask('Siehe [die Doku](https://x.y/z "Titel") jetzt')
    H.eq(masked, "Siehe {1}die Doku{2} jetzt")
    H.eq(mk.toks[1], "[")
    H.eq(mk.toks[2], '](https://x.y/z "Titel")')
    H.eq(mk.pair[1], 2, "the halves are paired")

    masked, mk = mask.mask("![Ein Bild](a.png)")
    H.eq(masked, "{1}Ein Bild{2}")
    H.eq(mk.toks[1], "![")

    masked = mask.mask("[Text](https://x.y/a_(b)) danach")
    H.eq(masked, "{1}Text{2} danach", "balanced parentheses in the destination")

    masked, mk = mask.mask("[`code` im Link](#abschnitt)")
    H.eq(masked, "{1}{2} im Link{3}", "code inside link text is masked on its own")
    H.eq(mk.toks[2], "`code`")

    masked = mask.mask("Ein [Text][ref] hier")
    H.eq(masked, "Ein {1}Text{2} hier", "a reference link masks its label half")

    masked = mask.mask("Das [Kollaps][] und [kurz] hier", { defs = { ["kurz"] = true } })
    H.eq(masked, "Das {1} und {2} hier", "collapsed and shortcut references are masked whole")

    masked = mask.mask("Eine [Klammer] ohne Definition")
    H.eq(masked, "Eine [Klammer] ohne Definition", "brackets without a target stay text")
  end

  -- the rest -------------------------------------------------------------------------------------
  do
    local masked = mask.mask("Hier <https://example.org> und <b>fett</b>.")
    H.eq(masked, "Hier {1} und {2}fett{3}.")
    masked = mask.mask("Auf https://example.org/a. ist Ende")
    H.eq(masked, "Auf {1}. ist Ende", "trailing punctuation is not part of a bare URL")
    masked = mask.mask("a &amp; b")
    H.eq(masked, "a {1} b")
    masked = mask.mask("Ein {3} Literal")
    H.eq(
      masked,
      "Ein {1} Literal",
      "a literal {3} of the source is a token, so it cannot be confused"
    )
    masked = mask.mask("Fussnote[^note] da")
    H.eq(masked, "Fussnote{1} da")
    masked = mask.mask("Das ist Neovim und mdview.nvim.", { keep = { "Neovim", "mdview.nvim" } })
    H.eq(masked, "Das ist {1} und {2}.", "keep words (proper names) are placeholders")
    masked = mask.mask("NeovimX bleibt", { keep = { "Neovim" } })
    H.eq(masked, "NeovimX bleibt", "a keep word only matches as a whole word")
    masked = mask.mask("Escaped \\`x\\` bleibt")
    H.eq(masked, "Escaped \\`x\\` bleibt", "an escaped backtick opens no span")
  end

  -- the placeholder is ASCII (spike: U+27E6/U+27E7 came back as `?1?` on Windows curl) -------------
  do
    local masked = mask.mask("a `b` c [d](e) f <g> h &i; j {#k} l https://m.n/o p")
    H.ok(not masked:find("[\128-\255]"), "the masked text of an ASCII source has no non-ASCII byte")
    H.ok(masked:find("{1}", 1, true), "and the placeholders have the form {n}")
  end

  -- has_text --------------------------------------------------------------------------------------
  do
    H.ok(mask.has_text("Hallo {1}"))
    H.ok(not mask.has_text("{1}"), "only a placeholder: nothing to translate")
    H.ok(
      not mask.has_text("{1} {2} 2024 - ."),
      "placeholders, digits and punctuation: nothing to translate"
    )
    H.ok(mask.has_text("\228\182"), "a non-ASCII letter is text")
  end

  -- check: the gate -----------------------------------------------------------------------------------
  do
    local _, mk = mask.mask("a [b](c) `d`")
    H.eq(#mk.toks, 3)
    H.ok(mask.check("x {1}y{2} {3}", mk), "complete")
    local ok, err = mask.check("x {1}y{2}", mk)
    H.ok(not ok and err:find("2 of 3"), "a lost placeholder is refused: " .. tostring(err))
    ok = mask.check("x {1}y{2} {3} {3}", mk)
    H.ok(not ok, "a repeated placeholder is refused")
    ok = mask.check("x {1}y{2} {9}", mk)
    H.ok(not ok, "an unknown placeholder is refused")
    ok, err = mask.check("x {2}y{1} {3}", mk)
    H.ok(not ok and err:find("halves"), "the halves of a link may not swap places")
  end

  -- normalize: what engines do to braces ----------------------------------------------------------------
  do
    H.eq(mask.normalize("a { 1 } b"), "a {1} b", "spaces inside a placeholder")
    H.eq(
      mask.normalize("a \239\189\1551\239\189\157 b"),
      "a {1} b",
      "fullwidth braces (CJK targets)"
    )
  end

  -- unmask --------------------------------------------------------------------------------------------------
  do
    local _, mk = mask.mask("a `x%1` b")
    H.eq(mask.unmask("so {1} da", mk), "so `x%1` da", "a % in the protected text is not a pattern")
  end

  -- bare e-mail and www addresses are linked by the previewer: masked whole ------------------
  do
    local masked, mk = mask.mask("Mail an john.doe@example.com und www.example.com/a. Ende")
    H.eq(masked, "Mail an {1} und {2}. Ende")
    H.eq(mk.toks[1], "john.doe@example.com")
    H.eq(mk.toks[2], "www.example.com/a")
    masked, mk = mask.mask("[x@y.de](mailto:x@y.de) und `a@b.cc` und Hallo@Welt")
    H.eq(
      masked,
      "{1}{2}{3} und {4} und Hallo@Welt",
      "an address in a link text, a span or half an address"
    )
    H.eq(mask.unmask(masked, mk), "[x@y.de](mailto:x@y.de) und `a@b.cc` und Hallo@Welt")
    masked = mask.mask("info@example.com")
    H.eq(masked, "{1}", "an address alone is a unit with nothing to translate")
  end

  -- look-ahead is bounded: a line of unclosed brackets or parentheses is linear -----
  do
    local function seconds(text)
      local t0 = vim.uv.hrtime()
      local masked, mk = mask.mask(text)
      H.eq(mask.unmask(masked, mk), text, "and the text still comes back whole")
      return (vim.uv.hrtime() - t0) / 1e9
    end
    local t = seconds(string.rep("[a ", 60000))
    H.ok(t < 2, ("unclosed brackets (%.2f s)"):format(t))
    t = seconds(string.rep("[a](", 40000))
    H.ok(t < 2, ("unclosed destinations (%.2f s)"):format(t))
    t = seconds(string.rep("`` `", 40000))
    H.ok(t < 2, ("unmatched backtick runs (%.2f s)"):format(t))
    local masked = mask.mask("[Text](a.md) und [Mehr](b.md)")
    H.eq(masked, "{1}Text{2} und {3}Mehr{4}", "ordinary links are not affected by the budget")
  end
  -- A look-ahead that was cut off is reported, and an address needs no quadratic scan --
  do
    local _, mk = mask.mask(string.rep("[a ", 60000))
    H.ok(mk.degraded, "a unit that used up the scan budget is marked degraded")
    _, mk = mask.mask("Ein [Link](a.md) und `Code` im Text.")
    H.falsy(mk.degraded, "an ordinary unit is not")

    local function seconds(text)
      local t0 = vim.uv.hrtime()
      local masked, m = mask.mask(text)
      H.eq(mask.unmask(masked, m), text, "the text still comes back whole")
      return (vim.uv.hrtime() - t0) / 1e9
    end
    local t = seconds(string.rep("a", 60000) .. " mail me@example.org")
    H.ok(t < 2, ("a long word before an address (%.2f s)"):format(t))
    t =
      seconds("mail me@example.org ![x](data:image/png;base64," .. string.rep("QUJD", 30000) .. ")")
    H.ok(t < 2, ("an address next to a data URI (%.2f s)"):format(t))
    local masked = mask.mask("Mail an max.muster@example.org oder _x@y.de, ok")
    H.eq(
      masked,
      "Mail an {1} oder {2}, ok",
      "an address is masked, one behind a word character is not"
    )
  end
  -- Many addresses, many comment openers: the search for the next special character and for
  -- `-->` is not repeated to the end of the unit once per address / opener -------------
  do
    local function seconds(text)
      local t0 = vim.uv.hrtime()
      local masked, m = mask.mask(text)
      H.eq(mask.unmask(masked, m), text, "the text still comes back whole")
      return (vim.uv.hrtime() - t0) / 1e9, masked, m
    end
    local t, masked, m = seconds(string.rep("foo@bar.com ", 12000))
    H.ok(t < 2, ("12000 addresses and no other special character (%.2f s)"):format(t))
    H.eq(#m.toks, 12000, "every address is masked")
    H.eq(masked:sub(1, 12), "{1} {2} {3} ", "and in order")
    t = seconds("Wort " .. string.rep("<!-- ", 30000))
    H.ok(t < 2, ("30000 unclosed comment openers (%.2f s)"):format(t))
    t = seconds("Wort [" .. string.rep("<!-- ", 20000) .. "](a.md) -->")
    H.ok(t < 2, ("comment openers whose `-->` lies beyond the link text (%.2f s)"):format(t))
    masked = mask.mask("a <!-- note --> b <!-- c --> d")
    H.eq(masked, "a {1} b {2} d", "closed comments are still masked, each by its own `-->`")
    masked = mask.mask("[x <!-- y](a.md) -->")
    H.eq(masked, "{1}x <!-- y{2} -->", "a comment that closes beyond the link text is not taken")
  end
  -- The end of a bare address, the match of a tag and of a footnote reference are linear, too:
  -- no gsub that restarts at every byte of a run of punctuation, no pattern that backtracks
  -- over a name, no search to the end of the run once per candidate ----------------------------
  do
    local function seconds(text)
      local t0 = vim.uv.hrtime()
      local masked, m = mask.mask(text)
      H.eq(mask.unmask(masked, m), text, "the text still comes back whole")
      return (vim.uv.hrtime() - t0) / 1e9
    end
    local rep = string.rep
    local cases = {
      { "`www.` address, a run of `)`, a letter", "www.a.b" .. rep(")", 40000) .. "x" },
      { "URL, a run of `)`, a letter", "https://a.b/" .. rep(")", 40000) .. "x" },
      { "URL, a run of `:`, a letter", "Text https://example.com/" .. rep(":", 50000) .. "x" },
      { "`https://` and a run of dots", "https://" .. rep(".", 50000) .. "x" },
      { "`www.a.` and a run of dots", "www.a." .. rep(".", 50000) .. "x" },
      { "`<`, a long name, no `>`", "<" .. rep("a", 40000) },
      { "`</`, a long name, no `>`", "</" .. rep("a", 40000) },
      { "`<a:a:a:...`", "<a" .. rep(":a", 20000) },
      { "many `https://` in the text of a link", "[" .. rep("https://", 8000) .. "](x)" },
      { "many `[^a` and no `]`", rep("[^a", 20000) },
      { "many `[^` and no `]`", rep("[^", 30000) },
    }
    for _, c in ipairs(cases) do
      local t = seconds(c[2])
      H.ok(t < 2, ("%s (%.2f s)"):format(c[1], t))
    end

    -- the trim of the sentence punctuation is what it was
    local masked, m = mask.mask("Siehe https://example.org/a.), und www.example.com/b?! Ende")
    H.eq(masked, "Siehe {1}.), und {2}?! Ende")
    H.eq(m.toks[1], "https://example.org/a")
    H.eq(m.toks[2], "www.example.com/b")
    masked = mask.mask("Nur http://x und https:// sind keine Adressen")
    H.eq(masked, "Nur http://x und https:// sind keine Adressen", "a scheme alone is no address")

    -- an address at the end of the text of a link is the visible address: masked, not
    -- left to an engine (and not counted as the source's own when its answer is checked)
    masked, m = mask.mask("Mehr unter [https://example.com](https://example.com) Danke.")
    H.eq(masked, "Mehr unter {1}{2}{3} Danke.")
    H.eq(m.toks[2], "https://example.com")
    H.eq(m.toks[3], "](https://example.com)")
    masked, m = mask.mask("[www.example.com](https://example.com)")
    H.eq(masked, "{1}{2}{3}")
    H.eq(m.toks[2], "www.example.com")
    masked, m = mask.mask("[Siehe https://a.b/c.](x.md)")
    H.eq(masked, "{1}Siehe {2}.{3}", "the dot of the sentence is not part of the address")
    H.eq(m.toks[2], "https://a.b/c")
    masked = mask.mask("[www.a.](x.md)")
    H.eq(masked, "{1}www.a.{2}", "a `www.` that is too short is no address, also at the end")
    masked = mask.mask("[Text www.example.com/a. und mehr](x.md)")
    H.eq(masked, "{1}Text {2}. und mehr{3}", "an address inside the text is as before")

    -- tags
    masked = mask.mask('Ein <a href="x">Link</a> und <b> fett </b>, a <b und <i> kursiv, a < b.')
    H.eq(
      masked,
      "Ein {1}Link{2} und {3} fett {4}, a <b und {5} kursiv, a < b.",
      "a tag is taken up to its first `>`, a `<` inside it ends the try"
    )
    masked = mask.mask("<a:b-c> und <1> und </ x>")
    H.eq(masked, "{1} und <1> und </ x>", "a name starts with a letter")

    -- footnote references
    masked = mask.mask("Eine [^a b] und [^] und [^x] Ende")
    H.eq(masked, "Eine [^a b] und [^] und {1} Ende", "a label has no white space and is not empty")
    masked = mask.mask("[^a [^b] c [^d]")
    H.eq(masked, "[^a {1} c {2}", "the remembered end of a label is not used for a later one")
  end
end
