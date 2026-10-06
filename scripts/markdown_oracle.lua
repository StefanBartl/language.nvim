-- scripts/markdown_oracle.lua -- translate real Markdown files with a fake engine and
-- write the source and the result side by side, for `markdown_oracle.mjs` to compare
-- with the previewer's renderer (comrak): same block structure, same literal blocks,
-- same link / image / code targets. A segmenter bug that makes code text, or a wrap
-- that turns text into a list, a table or a fence, shows up as a differing pair.
--
--   nvim -n -i NONE --headless -u TESTS/minimal_init.lua \
--     -l scripts/markdown_oracle.lua <out_dir> <file> [<file> ...]
--   node scripts/markdown_oracle.mjs <out_dir>
--
-- `<file>` may also be `@list.txt`, one path per line. The fake engine reverses every
-- word of four letters or more ("scr") or keeps the first 60 % of the words ("shr").
-- Needs the sibling checkout `mdview.nvim` (its WASM renderer) for the .mjs half.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.fn.chdir(root)
dofile(root .. "/TESTS/minimal_init.lua")
local helpers = dofile(root .. "/TESTS/markdown_helpers.lua")
require("language.translate.markdown").cache._reset()

local out = arg[1]
if not out or #arg < 2 then
  io.stderr:write("usage: markdown_oracle.lua <out_dir> <file|@list> ...\n")
  vim.cmd("cquit 2")
end
vim.fn.mkdir(out, "p")

local files = {}
for i = 2, #arg do
  if arg[i]:sub(1, 1) == "@" then
    vim.list_extend(files, vim.fn.readfile(arg[i]:sub(2)))
  else
    files[#files + 1] = arg[i]
  end
end

local engines = {
  scr = function(t)
    return (t:gsub("%a%a%a+", function(w)
      return w:reverse()
    end))
  end,
  shr = function(t)
    local words = {}
    for w in t:gmatch("%S+") do
      words[#words + 1] = w
    end
    return table.concat(words, " ", 1, math.max(1, math.ceil(#words * 0.6)))
  end,
}

local runs, failed = 0, 0
for i, file in ipairs(files) do
  local ok, lines = pcall(vim.fn.readfile, file, "b")
  if ok then
    for mode, fn in pairs(engines) do
      local r = helpers.run(lines, { provider = helpers.fake(fn, { sync = true }) })
      runs = runs + 1
      if r.ok and #r.res == #lines then
        vim.fn.writefile(lines, ("%s/s%d_%s_a.md"):format(out, i, mode), "b")
        vim.fn.writefile(r.res, ("%s/s%d_%s_b.md"):format(out, i, mode), "b")
      else
        failed = failed + 1
        print("FAILED", file, tostring(r.res))
      end
    end
  end
end
print(("markdown_oracle: %d files, %d runs, %d failed"):format(#files, runs, failed))
vim.cmd("qa!")
