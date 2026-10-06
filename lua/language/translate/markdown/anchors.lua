---@module 'language.translate.markdown.anchors'
---@brief Keeps in-page links (`#slug`) working after the headings were translated.
---@description
--- A link target `#entwurf` points at a heading by its slug. Translate the
--- heading and the slug changes while the (masked, never translated) target
--- does not: spike 2026-10-06, 16 of 18 table-of-contents links broke. The map
--- built here takes the slug of the i-th original heading to the slug of the
--- i-th translated heading and rewrites the targets; a target that matches no
--- heading stays as it is.
---
--- `slug` is the one the mdview client resolves an anchor with
--- (`slugify` in `linkHover.ts`: lower case, anything but letters, digits,
--- white space and hyphens removed, white space to hyphens). The first heading
--- with a slug wins, as it does in the client.

local M = {}

---@internal
---@param s string
---@return string
local function lower(s)
  if not s:find("[\128-\255]") then
    return s:lower()
  end
  local ok, res = pcall(vim.fn.tolower, s)
  return ok and type(res) == "string" and res or s:lower()
end

---Slug of a heading text (plain text, no Markdown).
---@param text string
---@return string
function M.slug(text)
  text = lower(text)
  local keep
  if not text:find("[\128-\255]") then
    keep = text:gsub("[^%w%s-]", "")
  else
    local parts, n = {}, 0
    for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
      local b = ch:byte()
      local ok
      if b < 128 then
        ok = ch:match("[%w%s-]") ~= nil
      else
        -- charclass: 2 = letter/digit/underscore, 3 = emoji; the CJK classes are above 0x2e80.
        local cc = vim.fn.charclass(ch)
        ok = cc == 2 or cc >= 0x3040 or cc == 0x2e80
      end
      if ok then
        n = n + 1
        parts[n] = ch
      end
    end
    keep = table.concat(parts)
  end
  keep = keep:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "-"):gsub("%-+", "-")
  return keep
end

---Plain text of a Markdown heading: link/image syntax, code ticks, HTML tags
---and emphasis markers are dropped.
---@param md string
---@return string
function M.plain(md)
  local s = md
  s = s:gsub("!?%[([^%]]*)%]%b()", "%1")
  s = s:gsub("!?%[([^%]]*)%]%[[^%]]*%]", "%1")
  s = s:gsub("<[^<>]*>", "")
  s = s:gsub("`", "")
  s = s:gsub("%*", "")
  return s
end

---Map the slug of each original heading to the slug of its translation.
---@param old string[]  -- original heading texts (Markdown)
---@param new string[]  -- translated heading texts, same order
---@return table<string, string> map, integer changed
function M.build_map(old, new)
  local map, changed = {}, 0
  for i = 1, #old do
    local a = M.slug(M.plain(old[i]))
    local b = new[i] and M.slug(M.plain(new[i])) or ""
    if a ~= "" and b ~= "" and map[a] == nil then
      map[a] = b
      if a ~= b then
        changed = changed + 1
      end
    end
  end
  return map, changed
end

---@internal
---@param s string
---@return string
local function pct_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---Rewrite the destination of a masked link half (`](#slug "title")`).
---@param text string
---@param map table<string, string>
---@return string text, boolean changed
function M.rewrite_dest(text, map)
  local head, slug, tail = text:match("^(%]%(<?)#([^%s>)\"']*)(.*)$")
  if not head then
    return text, false
  end
  local new = map[M.slug(pct_decode(slug))]
  if not new or new == slug then
    return text, false
  end
  return head .. "#" .. new .. tail, true
end

---Rewrite the target of a reference definition line (`[x]: #slug`).
---@param line string
---@param map table<string, string>
---@return string line, boolean changed
function M.rewrite_refdef(line, map)
  local head, slug, tail = line:match("^(%s*%[[^%]]+%]:%s*<?)#([^%s>]*)(.*)$")
  if not head then
    return line, false
  end
  local new = map[M.slug(pct_decode(slug))]
  if not new or new == slug then
    return line, false
  end
  return head .. "#" .. new .. tail, true
end

return M
