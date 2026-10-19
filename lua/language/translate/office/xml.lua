---@module 'language.translate.office.xml'
---@brief Text runs of an OOXML part (PowerPoint / Word): collect them, put translated ones back.
---@description
--- A paragraph (`<a:p>` in PowerPoint, `<w:p>` in Word) is one sentence for the engine even when it is cut
--- into several runs (bold in the middle of a sentence): the texts of its runs are joined, with a numbered
--- placeholder `{k}` where one run ends and the next begins, and the translated text is split at those
--- placeholders again. Only the text inside `<a:t>` / `<w:t>` changes; every other byte of the part stays, so
--- formatting, fields (`w:instrText`), pictures, animations and relations are untouched.
---
--- A translation that lost, repeated or reordered a placeholder is never split guessing: the whole text goes
--- into the first run and the other runs of that paragraph become empty (no text is lost, the formatting of
--- that one paragraph is).
---
--- The module is pure (strings in, strings out) and has no XML parser: the parts are machine written, the
--- text elements never nest, and nothing but the text between a `t` tag and its end tag is read or written.

local M = {}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

---@internal
---@param cp integer
---@return string
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 262144),
    0x80 + math.floor(cp / 4096) % 64,
    0x80 + math.floor(cp / 64) % 64,
    0x80 + cp % 64
  )
end

---Decode the five predefined entities and numeric references. An entity that is not known stays as written
---(`&foo;`), so it is written back as it was.
---@param s string
---@return string
function M.decode(s)
  return (
    s:gsub("&(#?[%w]+);", function(name)
      if ENTITIES[name] then
        return ENTITIES[name]
      end
      local hex = name:match("^#[xX](%x+)$")
      local dec = name:match("^#(%d+)$")
      local cp = hex and tonumber(hex, 16) or dec and tonumber(dec, 10)
      if cp and cp > 0 and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF) then
        return utf8_char(cp)
      end
      return nil
    end)
  )
end

---Escape text for an element body.
---@param s string
---@return string
function M.encode(s)
  return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

---@class LanguageOfficeRun
---@field text string  -- decoded text of the run

---@class LanguageOfficePara
---@field runs string[]     -- decoded texts of the `t` elements, in order
---@field line? string      -- the text for the engine (nil: nothing to translate in this paragraph)
---@field slots? integer[]  -- indexes (into runs) of the runs that carry text, in order
---@field edges? { [1]: string, [2]: string }[]  -- leading / trailing white space of each slot

---@internal
---@param s string
---@return boolean
local function has_letter(s)
  -- A byte >= 128 is part of a multi-byte letter or symbol: worth translating; digits, space and ASCII
  -- punctuation alone are not.
  return s:find("[%a\128-\255]") ~= nil
end

---@internal
---@param para LanguageOfficePara
local function build_line(para)
  local slots, edges, parts = {}, {}, {}
  for i, t in ipairs(para.runs) do
    if t:find("%S") then
      slots[#slots + 1] = i
      edges[#edges + 1] = { t:match("^%s*"), t:match("%s*$") }
      parts[#parts + 1] = (t:gsub("^%s+", ""):gsub("%s+$", ""))
    end
  end
  local joined = {}
  for k, p in ipairs(parts) do
    if k > 1 then
      joined[#joined + 1] = "{" .. (k - 1) .. "}"
    end
    joined[#joined + 1] = p
  end
  local line = table.concat(joined)
  if not has_letter(line) or line:find("[\r\n]") then
    return
  end
  -- A `{n}` of the source itself would be taken for a placeholder: that paragraph is left as it is.
  for _, p in ipairs(parts) do
    if p:find("{%d+}") then
      return
    end
  end
  para.line, para.slots, para.edges = line, slots, edges
end

-- `<a:p>` / `<w:p>` but not `<a:pPr>`, `<w:pict>`, ...; the body up to the next end tag of the same kind.
---@internal
---@param xml string
---@param fn fun(prefix: string, body: string, from: integer, to: integer)  -- from / to: the body inside xml
local function each_paragraph(xml, fn)
  local pos = 1
  while true do
    local s, e, prefix = xml:find("<([aw]):p[ >]", pos)
    if not s then
      return
    end
    local close = "</" .. prefix .. ":p>"
    local cs, ce = xml:find(close, e, true)
    if not cs then
      return
    end
    fn(prefix, xml:sub(e + 1, cs - 1), e + 1, cs - 1)
    pos = ce + 1
  end
end

---Collect the paragraphs of a part, in document order.
---@param xml string
---@return LanguageOfficePara[]
function M.collect(xml)
  local paras = {}
  each_paragraph(xml, function(prefix, body)
    local runs = {}
    for _, text in body:gmatch("<" .. prefix .. ":t(%s?[^>/]*)>([^<]*)</" .. prefix .. ":t>") do
      runs[#runs + 1] = M.decode(text)
    end
    if #runs > 0 then
      local para = { runs = runs }
      build_line(para)
      paras[#paras + 1] = para
    end
  end)
  return paras
end

---Split a translated line at the run placeholders.
---@param para LanguageOfficePara
---@param translated string
---@return string[]|nil segments  -- one per slot, or nil when a placeholder is missing, doubled or out of order
function M.split(para, translated)
  local want = #para.slots - 1
  local segs, pos = {}, 1
  for k = 1, want do
    local s, e = translated:find("{" .. k .. "}", pos, true)
    if not s then
      return nil
    end
    segs[#segs + 1] = translated:sub(pos, s - 1)
    pos = e + 1
  end
  local rest = translated:sub(pos)
  if rest:find("{%d+}") then
    return nil
  end
  segs[#segs + 1] = rest
  return segs
end

---The new texts of all runs of a paragraph, from the translated line.
---@param para LanguageOfficePara
---@param translated string
---@return string[] texts  -- one per run (same count and order as para.runs)
function M.distribute(para, translated)
  local texts = {}
  for i, t in ipairs(para.runs) do
    texts[i] = t
  end
  local segs = M.split(para, translated)
  if not segs then
    -- Lost placeholders: all the text into the first run that had text, no word dropped.
    local flat = vim.trim((translated:gsub("%s*{%d+}%s*", " ")))
    segs = { flat }
    for _ = 2, #para.slots do
      segs[#segs + 1] = ""
    end
  end
  for k, i in ipairs(para.slots) do
    local seg = vim.trim(segs[k] or "")
    if seg == "" then
      texts[i] = ""
    else
      texts[i] = para.edges[k][1] .. seg .. para.edges[k][2]
    end
  end
  return texts
end

---Put translated texts back. `translate` maps the line of a paragraph to its translation (or nil to leave the
---paragraph alone); the walk is the same as `collect`, so the paragraphs match one to one.
---@param xml string
---@param translate fun(line: string): string|nil
---@return string xml, integer changed
function M.apply(xml, translate)
  local out, last, changed = {}, 1, 0
  each_paragraph(xml, function(prefix, body, from, to)
    local runs = {}
    for _, text in body:gmatch("<" .. prefix .. ":t(%s?[^>/]*)>([^<]*)</" .. prefix .. ":t>") do
      runs[#runs + 1] = M.decode(text)
    end
    if #runs == 0 then
      return
    end
    local para = { runs = runs }
    build_line(para)
    local translated = para.line and translate(para.line)
    if not translated then
      return
    end
    local texts = M.distribute(para, translated)
    local k = 0
    local new_body = body:gsub(
      "<" .. prefix .. ":t(%s?[^>/]*)>([^<]*)</" .. prefix .. ":t>",
      function(attrs, _)
        k = k + 1
        local text = texts[k]
        -- Word drops the white space around a run unless it is told to keep it.
        -- (DrawingML keeps it by itself and allows no such attribute on `a:t`.)
        if prefix == "w" and (text:find("^%s") or text:find("%s$")) then
          if not attrs:find("xml:space", 1, true) then
            attrs = attrs .. ' xml:space="preserve"'
          end
        end
        return "<" .. prefix .. ":t" .. attrs .. ">" .. M.encode(text) .. "</" .. prefix .. ":t>"
      end
    )
    out[#out + 1] = xml:sub(last, from - 1)
    out[#out + 1] = new_body
    last = to + 1
    changed = changed + 1
  end)
  out[#out + 1] = xml:sub(last)
  return table.concat(out), changed
end

return M
