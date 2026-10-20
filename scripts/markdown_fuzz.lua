-- scripts/markdown_fuzz.lua -- random Markdown documents for the oracle: fragments mixed under random containers
-- (quote depth, list indent, tabs), so that fences in lists in quotes, empty items and open fences turn up.
--
--   nvim -n -i NONE --headless -u NONE -l scripts/markdown_fuzz.lua <out_dir> [count] [seed] [wide]
--
-- Writes `<out_dir>/f<N>.md` and `<out_dir>/list.txt` (one path per line) for
-- `markdown_oracle.lua <pairs_dir> @<out_dir>/list.txt`.

local out = arg[1]
local count = tonumber(arg[2]) or 1000
local seed = tonumber(arg[3]) or 20261019
if not out then
  io.stderr:write("usage: markdown_fuzz.lua <out_dir> [count] [seed]\n")
  vim.cmd("cquit 2")
end
vim.fn.mkdir(out, "p")
math.randomseed(seed)

local fragments = {
  "# Title",
  "Text with `code` and [a link](#title).",
  "",
  "",
  "- item",
  "* item",
  "+ item",
  "-",
  "1. one",
  "2) two",
  "10. ten",
  "> quote",
  ">",
  "```",
  "```lua",
  "~~~",
  "````",
  "| a | b |",
  "|---|---|",
  "<div>",
  "</div>",
  "<!-- c -->",
  "---",
  "***",
  "===",
  "[ref]: /x",
  "$$",
  "line with break  ",
  "backslash\\",
  "word word word",
  "- [ ] todo",
  "    indented",
  "text *emph* **strong**",
  "Setext",
  "-----",
}
local prefixes = {
  "",
  "",
  "",
  "> ",
  "> > ",
  "  ",
  "   ",
  "    ",
  "\t",
  "- ",
  "  - ",
  "1. ",
  "   ",
  "> - ",
  "- > ",
  "> 1. ",
}
-- `wide`: the fragments the default set leaves out (footnotes, open HTML blocks, math in lists, table variants,
-- definitions with titles, raw HTML, odd markers), under more containers
if arg[4] == "wide" then
  vim.list_extend(fragments, {
    "[^1]: note",
    "[^1]: note",
    "    footnote continuation",
    "Fussnote[^1] hier",
    "<pre>",
    "</pre>",
    "<details>",
    "</details>",
    "<span>x</span>",
    "<script>",
    "</script>",
    "<?php",
    "?>",
    "<!--",
    "-->",
    "$$ x = 1",
    "x $$",
    "$$x$$",
    "| a |",
    "|-|",
    "a | b",
    "--|--",
    ":-:|-:",
    "| a | b | c |",
    "[ref]:",
    "  /url",
    '  "title"',
    "[ref2]: /y 'title'",
    "~~strike~~",
    "10) ten",
    "0. zero",
    "1.     code",
    "-     code",
    "*",
    "+",
    "* * *",
    "- - -",
    "1.",
    "= = =",
    "word\\",
    "[x]: <a b>",
  })
  vim.list_extend(
    prefixes,
    { "   1. ", "- - ", "> > - ", "> ", "    > ", "\t- ", "  > ", "1. > ", "- [ ] " }
  )
end

local list = {}
for n = 1, count do
  local lines = {}
  for _ = 1, math.random(3, 24) do
    local frag = fragments[math.random(#fragments)]
    local prefix = prefixes[math.random(#prefixes)]
    -- keep the same container for a few lines, like a real nested block
    local run = math.random(1, 3)
    for _ = 1, run do
      lines[#lines + 1] = prefix .. frag
      if math.random() < 0.6 then
        frag = fragments[math.random(#fragments)]
      end
    end
  end
  local path = ("%s/f%d.md"):format(out, n)
  vim.fn.writefile(lines, path)
  list[#list + 1] = path
end
vim.fn.writefile(list, out .. "/list.txt")
print(("markdown_fuzz: %d documents in %s (seed %d)"):format(count, out, seed))
vim.cmd("qa!")
