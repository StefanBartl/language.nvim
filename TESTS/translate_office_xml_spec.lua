-- TESTS/translate_office_xml_spec.lua — language.translate.office.xml: the text runs of an OOXML part.
-- Pure strings in, strings out.

return function(H)
  local xml = require("language.translate.office.xml")

  -- entities ------------------------------------------------------------------
  H.eq(
    xml.decode("a &amp; b &lt;c&gt; &quot;d&quot; &#233; &#x20AC; &foo;"),
    'a & b <c> "d" é € &foo;',
    "decode"
  )
  H.eq(xml.encode("a & b <c>"), "a &amp; b &lt;c&gt;", "encode")
  H.eq(
    xml.decode("&#0; &#xD800; &#1114112;"),
    "&#0; &#xD800; &#1114112;",
    "invalid references stay as written"
  )

  -- a PowerPoint paragraph with a bold run in the middle ------------------------
  local slide = table.concat({
    '<p:sld><p:txBody><a:p><a:pPr algn="l"/>',
    '<a:r><a:rPr lang="en-US"/><a:t>The </a:t></a:r>',
    '<a:r><a:rPr b="1"/><a:t>quick</a:t></a:r>',
    "<a:r><a:rPr/><a:t> fox &amp; dog</a:t></a:r></a:p>",
    "<a:p><a:r><a:t>42</a:t></a:r></a:p>",
    "<a:p><a:endParaRPr/></a:p>",
    "</p:txBody></p:sld>",
  })
  local paras = xml.collect(slide)
  H.eq(#paras, 2, "two paragraphs with runs (the empty one has none)")
  H.eq(
    paras[1].line,
    "The{1}quick{2}fox & dog",
    "runs joined by numbered placeholders, edges trimmed"
  )
  H.eq(paras[2].line, nil, "digits only: nothing to translate")

  local out, changed = xml.apply(slide, function(line)
    return (line:upper())
  end)
  H.eq(changed, 1, "one paragraph changed")
  H.contains(out, "<a:t>THE </a:t>", "first run keeps its trailing space, no xml:space on a:t")
  H.contains(out, '<a:rPr b="1"/><a:t>QUICK</a:t>', "the bold run stays bold and holds its words")
  H.contains(out, "<a:t> FOX &amp; DOG</a:t>", "the ampersand is written escaped again")
  H.contains(out, '<a:pPr algn="l"/>', "everything but the text is as it was")
  H.contains(out, "<a:t>42</a:t>", "a paragraph that was not translated is untouched")

  -- placeholders lost: all the text into the first run, nothing dropped ---------
  local lost = xml.apply(slide, function()
    return "Der schnelle Fuchs"
  end)
  H.contains(lost, "<a:t>Der schnelle Fuchs </a:t>", "first run holds the whole text")
  H.contains(lost, '<a:rPr b="1"/><a:t></a:t>', "the others are empty")

  -- reordered placeholders count as lost
  local para = paras[1]
  H.eq(xml.split(para, "A{2}B{1}C"), nil, "out of order")
  H.eq(xml.split(para, "A{1}B{1}C"), nil, "doubled")
  H.eq(xml.split(para, "A{1}B"), nil, "missing")
  H.eq(table.concat(xml.split(para, "A{1}B{2}C"), "|"), "A|B|C", "in order")

  -- a Word run: white space needs xml:space="preserve" ---------------------------
  local doc = '<w:body><w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:t xml:space="preserve"> world </w:t></w:r></w:p>'
    .. "<w:p><w:r><w:instrText>PAGE</w:instrText></w:r></w:p></w:body>"
  local dp = xml.collect(doc)
  H.eq(#dp, 1, "a field instruction is no text run")
  local wout = xml.apply(doc, function()
    return "Hallo{1}Welt"
  end)
  H.contains(wout, "<w:t>Hallo</w:t>", "no preserve needed")
  H.contains(wout, '<w:t xml:space="preserve"> Welt </w:t>', "the white space around the run stays")
  H.contains(wout, "<w:instrText>PAGE</w:instrText>", "the field is untouched")

  -- a literal {n} in the source: the paragraph is left alone --------------------
  H.eq(
    xml.collect("<a:p><a:r><a:t>use {1} here</a:t></a:r></a:p>")[1].line,
    nil,
    "literal placeholder"
  )

  -- a pPr is not a paragraph ------------------------------------------------------
  H.eq(#xml.collect("<w:p><w:r><w:t>outer</w:t></w:r><w:pPr/></w:p>"), 1, "pPr is not a paragraph")
end
