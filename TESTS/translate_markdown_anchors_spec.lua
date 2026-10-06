-- TESTS/translate_markdown_anchors_spec.lua -- translate/markdown/anchors.lua:
-- the slug the mdview client resolves `#anchor` links with, the old-to-new map
-- built from translated headings, and the rewriting of link and definition targets.

return function(H)
  local anchors = require("language.translate.markdown.anchors")

  -- slug: the client's slugify (linkHover.ts) --------------------------------------------
  H.eq(anchors.slug("Installation"), "installation")
  H.eq(anchors.slug("Getting Started"), "getting-started")
  H.eq(anchors.slug("  Mehr   Platz  "), "mehr-platz", "white space collapses to one hyphen")
  H.eq(anchors.slug("A - B"), "a-b", "hyphens collapse")
  H.eq(anchors.slug("Was ist das?"), "was-ist-das", "punctuation is dropped")
  H.eq(
    anchors.slug("snake_case.name"),
    "snakecasename",
    "underscore and dot are dropped, as in the client"
  )
  H.eq(
    anchors.slug("\195\156bersicht \195\188ber alles"),
    "\195\188bersicht-\195\188ber-alles",
    "umlauts are letters and lower-cased"
  )
  H.eq(
    anchors.slug("\228\184\173\230\150\135 Titel"),
    "\228\184\173\230\150\135-titel",
    "CJK letters are kept"
  )
  H.eq(anchors.slug("Rocket \240\159\154\128 Launch"), "rocket-launch", "an emoji is dropped")
  H.eq(anchors.slug("123 Zahlen"), "123-zahlen")
  H.eq(anchors.slug(""), "")

  -- plain: Markdown out of a heading ------------------------------------------------------
  H.eq(anchors.plain("Der `code` im [Link](#x) und **fett**"), "Der code im Link und fett")
  H.eq(anchors.plain("Bild ![Alt](a.png) <b>x</b>"), "Bild Alt x")
  H.eq(
    anchors.slug(anchors.plain("`npm install` ausf\195\188hren")),
    "npm-install-ausf\195\188hren"
  )

  -- build_map ---------------------------------------------------------------------------------
  do
    local map, changed = anchors.build_map(
      { "Einleitung", "Installation", "Verwendung", "Kurz" },
      { "Introduction", "Setup", "Usage" }
    )
    H.eq(map["einleitung"], "introduction")
    H.eq(map["installation"], "setup")
    H.eq(map["verwendung"], "usage")
    H.eq(map["kurz"], nil, "a heading without a translation has no entry")
    H.eq(changed, 3)

    map, changed = anchors.build_map({ "API", "Beispiele" }, { "API", "Examples" })
    H.eq(map["api"], "api", "an unchanged heading maps to itself")
    H.eq(changed, 1, "and is not counted as changed")

    map = anchors.build_map({ "Gleich", "Gleich" }, { "Same", "Other" })
    H.eq(map["gleich"], "same", "the first heading with a slug wins, as in the client")

    map = anchors.build_map({ "???" }, { "!!!" })
    H.eq(next(map), nil, "a heading with an empty slug maps nothing")
  end

  -- rewrite_dest ---------------------------------------------------------------------------------
  do
    local map = { installation = "setup", ["\195\188bersicht"] = "overview", a = "b" }
    local t, changed = anchors.rewrite_dest("](#installation)", map)
    H.eq(t, "](#setup)")
    H.ok(changed)
    H.eq(
      (anchors.rewrite_dest('](#installation "Titel")', map)),
      '](#setup "Titel")',
      "a title is kept"
    )
    H.eq(
      (anchors.rewrite_dest("](<#installation>)", map)),
      "](<#setup>)",
      "angle brackets are kept"
    )
    H.eq(
      (anchors.rewrite_dest("](#Installation)", map)),
      "](#setup)",
      "the lookup is case-insensitive like the slug"
    )
    H.eq(
      (anchors.rewrite_dest("](#%C3%BCbersicht)", map)),
      "](#overview)",
      "a percent-encoded target is decoded first"
    )
    t, changed = anchors.rewrite_dest("](#unbekannt)", map)
    H.eq(t, "](#unbekannt)")
    H.falsy(changed)
    H.eq(
      (anchors.rewrite_dest("](other.md#installation)", map)),
      "](other.md#installation)",
      "another file's anchor is none of ours"
    )
    H.eq(
      (anchors.rewrite_dest("](https://x.y/#installation)", map)),
      "](https://x.y/#installation)"
    )
    H.eq(
      (anchors.rewrite_dest("][label]", map)),
      "][label]",
      "a reference label is not a destination"
    )
    H.eq((anchors.rewrite_dest("](#a)", { a = "a" })), "](#a)", "no change when old equals new")
  end

  -- rewrite_refdef ---------------------------------------------------------------------------------
  do
    local map = { installation = "setup" }
    local l, changed = anchors.rewrite_refdef("[zurueck]: #installation", map)
    H.eq(l, "[zurueck]: #setup")
    H.ok(changed)
    H.eq((anchors.rewrite_refdef('  [x]: <#installation> "T"', map)), '  [x]: <#setup> "T"')
    H.eq(
      (anchors.rewrite_refdef("[x]: https://e.org/#installation", map)),
      "[x]: https://e.org/#installation"
    )
    H.eq((anchors.rewrite_refdef("kein Def", map)), "kein Def")
  end
end
