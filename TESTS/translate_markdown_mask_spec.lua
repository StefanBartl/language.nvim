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
end
