---@module 'language.translate.subtitle'
---@brief Subtitle-aware translation of SRT and WebVTT text.
---@description
--- A subtitle file is not prose: index lines, timing lines (`00:00:04,120 -->
--- 00:00:07,300`), the `WEBVTT` header and `NOTE`/`STYLE`/`REGION` blocks must
--- reach the engine never, or the file is destroyed. Only the text lines of a
--- cue go out.
---
---   cue_ranges  the text lines of every cue, one range per cue (a cue of
---               several lines stays together, so the engine cannot cut a
---               sentence across cues)
---   mask        `<i>`, `<c.class>`, `<00:00:01.000>`, `<v Name>` and `{\an8}`
---               become `{n}` placeholders and are put back afterwards
---   translate   all cues in ONE provider call, separated by blank lines (the
---               chunker cuts on blank lines, so a request boundary is a cue
---               boundary); the answer must keep the line structure, or nothing
---               is written
---
--- A cue whose placeholders did not all come back exactly once keeps its
--- source text and is counted in `info.kept`: a half-translated tag is worse
--- than an untranslated cue. Timing lines and indices are copied, never
--- retyped, so they stay byte-identical.
---
--- There is no switch for this: translating timestamps along is never what
--- anyone wants. A sentence that runs across two cues is translated cue by
--- cue.

local M = {}

---@class LanguageSubtitleRange
---@field s integer  1-based first text line of the cue
---@field e integer  1-based last text line of the cue

---@class LanguageSubtitleInfo
---@field total integer  cues in the requested range
---@field sent integer   cues that went to the engine
---@field kept integer   cues that kept their source text because the engine broke a placeholder

local EXT = { srt = "srt", vtt = "vtt", webvtt = "vtt" }

-- `00:00:04,120 --> 00:00:07,300` (SRT) and `00:04.120 --> 00:07.300` or
-- `00:00:04.120 --> 00:00:07.300 align:start` (WebVTT).
local TIMING = "^%s*%d+:%d%d[%d:%.,]*%s*%-%->%s*%d+:%d%d"

---@param line string
---@return boolean
local function is_timing(line)
  return line:match(TIMING) ~= nil
end

---Subtitle kind by file name or filetype.
---@param name string|nil  a path, a file name, or a filetype
---@return "srt"|"vtt"|nil
function M.kind_of_name(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local ext = name:match("%.([^.\\/]+)$") or name
  return EXT[ext:lower()]
end

---@param line string
---@param word string
---@return boolean
local function opens_with(line, word)
  return line == word or line:sub(1, #word + 1):match("^" .. word .. "%s") ~= nil
end

---Subtitle kind by content. Covers scratch buffers and the translate window,
---which have no name.
---
---`vtt`: a `WEBVTT` header. `srt`: the text is built of cue blocks only. Every
---block of non-blank lines opens with a timing line, or with an index line
---(`^%d+$`) directly followed by one; `NOTE`/`STYLE`/`REGION` blocks are
---allowed too. One prose block, and it is prose: a single `10:30 --> 11:00`
---line among paragraphs must not turn the rest into untranslated "index"
---lines.
---@param lines string[]
---@return "srt"|"vtt"|nil
function M.sniff(lines)
  local first = lines[1]
  if type(first) == "string" and first:gsub("^\239\187\191", ""):match("^WEBVTT") then
    return "vtt"
  end
  local cues = 0
  local i, n = 1, #lines
  while i <= n do
    if lines[i]:match("^%s*$") then
      i = i + 1
    else
      local head = lines[i]
      if i == 1 then
        head = head:gsub("^\239\187\191", "")
      end
      local nxt = lines[i + 1]
      if is_timing(head) or (head:match("^%s*%d+%s*$") and nxt and is_timing(nxt)) then
        cues = cues + 1
      elseif
        not (opens_with(head, "NOTE") or opens_with(head, "STYLE") or opens_with(head, "REGION"))
      then
        return nil
      end
      while i <= n and not lines[i]:match("^%s*$") do
        i = i + 1
      end
    end
  end
  return cues > 0 and "srt" or nil
end

---Kind of a buffer's text: by name, then by filetype, then by content.
---
---Content is looked at only for text that claims to be nothing else: no name
---extension (or `.txt`) and an empty or `text` filetype. A Markdown file with a
---line like `10:30 --> 11:45` stays prose.
---@param name string|nil
---@param filetype string|nil
---@param lines string[]
---@return "srt"|"vtt"|nil
function M.detect(name, filetype, lines)
  local kind = M.kind_of_name(name) or M.kind_of_name(filetype)
  if kind then
    return kind
  end
  local ext = type(name) == "string" and name:match("%.([^.\\/]+)$") or nil
  local plain_name = ext == nil or ext:lower() == "txt" or ext:lower() == "text"
  local plain_ft = filetype == nil or filetype == "" or filetype == "text"
  if plain_name and plain_ft then
    return M.sniff(lines)
  end
  return nil
end

---Text-line ranges of every cue in `lines`, in order.
---
---A block is a run of non-blank lines. A block is a cue when it holds a timing
---line; its text is everything after that line. Lines before the timing line
---are the SRT index or the WebVTT identifier. In WebVTT a block opening with
---`NOTE`, `STYLE` or `REGION` is never a cue.
---@param lines string[]
---@param kind "srt"|"vtt"
---@return LanguageSubtitleRange[]
function M.cue_ranges(lines, kind)
  ---@type LanguageSubtitleRange[]
  local ranges = {}
  local i, n = 1, #lines
  while i <= n do
    if lines[i]:match("^%s*$") then
      i = i + 1
    else
      local first = i
      while i <= n and not lines[i]:match("^%s*$") do
        i = i + 1
      end
      local last = i - 1
      local skip = false
      if kind == "vtt" then
        local head = lines[first]:gsub("^\239\187\191", "")
        skip = opens_with(head, "NOTE")
          or opens_with(head, "STYLE")
          or opens_with(head, "REGION")
          or head:match("^WEBVTT") ~= nil
      end
      if not skip then
        -- A block normally holds one cue. A file that lost the blank line between two cues has several timing
        -- lines in one block: it is split there, and the line before the next timing line (that cue's index or
        -- identifier) is left out of the text. Better one untranslated line than a timing line sent to the engine.
        local timings = {}
        for t = first, last do
          if is_timing(lines[t]) then
            timings[#timings + 1] = t
          end
        end
        for k, t in ipairs(timings) do
          local stop = timings[k + 1] and (timings[k + 1] - 2) or last
          if t < stop then
            ranges[#ranges + 1] = { s = t + 1, e = stop }
          end
        end
      end
    end
  end
  return ranges
end

-- Placeholders are plain ASCII `{n}` (see translate/markdown/mask.lua for why).
local ENGINE_LETTERS = "[%w\128-\255]"
local NOTES = { "\226\153\170", "\226\153\171", "\226\153\172" } -- music notes

---@class LanguageSubtitleMask
---@field toks string[]

---Replace tags and positioning overrides with `{n}`. A literal `{3}` of the
---source is protected too, so every `{n}` in the masked text is a placeholder.
---@param text string
---@return string masked
---@return LanguageSubtitleMask mask
local function mask_text(text)
  local mask = { toks = {} }
  local function put(tok)
    mask.toks[#mask.toks + 1] = tok
    return "{" .. #mask.toks .. "}"
  end
  -- The source's own `{3}` first: the placeholders made below are not touched again.
  local masked = text:gsub("{%d+}", put)
  masked = masked:gsub("<[^<>]*>", put)
  masked = masked:gsub("{\\[^{}]*}", put)
  return masked, mask
end

---Put the protected text back. Fails unless every placeholder is present once.
---@param text string
---@param mask LanguageSubtitleMask
---@return string|nil
local function unmask_text(text, mask)
  local seen = {}
  local ok = true
  local out = text:gsub("{(%d+)}", function(n)
    local k = tonumber(n)
    if not k or not mask.toks[k] or seen[k] then
      ok = false
      return nil
    end
    seen[k] = true
    return mask.toks[k]
  end)
  if not ok or #mask.toks ~= vim.tbl_count(seen) then
    return nil
  end
  return out
end

---True when a masked cue has words to translate (not only tags, notes, symbols).
---@param masked string
---@return boolean
local function has_text(masked)
  local s = masked:gsub("{%d+}", "")
  for _, note in ipairs(NOTES) do
    s = s:gsub(note, "")
  end
  return s:find(ENGINE_LETTERS) ~= nil
end

---Translate the cues of `lines` that fall in `range`, through `provider`.
---
---`lines` is the whole document (cue boundaries need the context); `range`
---(1-based, inclusive, default: everything) selects the part that is returned.
---`cb(ok, result, info)` runs once: on success `result` is the lines of the
---range with only cue text replaced, same line count.
---@param provider LanguageTranslateProvider
---@param lines string[]
---@param kind "srt"|"vtt"
---@param target string
---@param cfg table
---@param cb fun(ok: boolean, result: string[]|string, info?: LanguageSubtitleInfo)
---@param range? { s: integer, e: integer }
---@return table|nil job
function M.translate(provider, lines, kind, target, cfg, cb, range)
  local s = range and range.s or 1
  local e = range and range.e or #lines

  ---@type { s: integer, e: integer, masks: LanguageSubtitleMask[], first: integer }[]
  local cues = {}
  ---@type string[]
  local flat = {}
  local total = 0
  for _, r in ipairs(M.cue_ranges(lines, kind)) do
    local cs, ce = math.max(r.s, s), math.min(r.e, e)
    if cs <= ce then
      total = total + 1
      local masks, texts, any = {}, {}, false
      for l = cs, ce do
        local masked, mask = mask_text(lines[l])
        masks[#masks + 1] = mask
        texts[#texts + 1] = masked
        any = any or has_text(masked)
      end
      if any then
        if #flat > 0 then
          flat[#flat + 1] = ""
        end
        cues[#cues + 1] = { s = cs, e = ce, masks = masks, first = #flat + 1 }
        vim.list_extend(flat, texts)
      end
    end
  end

  ---@type string[]
  local base = {}
  for l = s, e do
    base[#base + 1] = lines[l]
  end
  ---@type LanguageSubtitleInfo
  local info = { total = total, sent = #cues, kept = 0 }

  if #cues == 0 then
    vim.schedule(function()
      cb(true, base, info)
    end)
    return nil
  end

  return provider.translate(flat, target, nil, cfg, function(ok, result)
    if not ok then
      cb(false, result)
      return
    end
    local shaped = type(result) == "table" and #result == #flat
    for i = 1, shaped and #flat or 0 do
      shaped = shaped and type(result[i]) == "string"
    end
    if not shaped then
      cb(false, "the engine changed the line structure of the subtitle text; nothing was written")
      return
    end
    -- The blank lines between cues must have survived: they are the proof that
    -- the answer lines up with the cues.
    for ci = 2, #cues do
      if not result[cues[ci].first - 1]:match("^%s*$") then
        cb(false, "the engine changed the line structure of the subtitle text; nothing was written")
        return
      end
    end
    for _, cue in ipairs(cues) do
      local out, good = {}, true
      for k = 1, #cue.masks do
        local back = unmask_text(result[cue.first + k - 1], cue.masks[k])
        if not back then
          good = false
          break
        end
        out[k] = back
      end
      if good then
        for k = 1, #out do
          base[cue.s - s + k] = out[k]
        end
      else
        info.kept = info.kept + 1
      end
    end
    cb(true, base, info)
  end)
end

return M
