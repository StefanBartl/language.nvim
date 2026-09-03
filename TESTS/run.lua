-- TESTS/run.lua — headless test runner for language.nvim.
--
-- Run from the repo root:
--   nvim --headless -u NONE -c "set rtp+=." -l TESTS/run.lua
--
-- lib.nvim has to be reachable: several language modules
-- require it at module load. The runner puts a sibling checkout on the
-- runtimepath, or whatever $LIB_NVIM_PATH points at.

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

do
  local candidates = {}
  if vim.env.LIB_NVIM_PATH and vim.env.LIB_NVIM_PATH ~= "" then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_PATH
  end
  candidates[#candidates + 1] = dir .. "../../lib.nvim"
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"

  for _, path in ipairs(candidates) do
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. "/lua/lib") == 1 then
      vim.opt.rtp:append(norm)
      package.path = table.concat({
        norm .. "/lua/?.lua",
        norm .. "/lua/?/init.lua",
        package.path,
      }, ";")
      break
    end
  end
end

if not pcall(require, "lib.lua.tables") then
  print("FAIL  cannot locate lib.nvim (a runtime dependency of language.nvim).")
  print("      Set $LIB_NVIM_PATH, or check it out next to this repo.")
  os.exit(1)
end

local H = dofile(dir .. "harness.lua")

-- Ordered so a failure points at the smallest layer first.
local specs = {
  "split_spec.lua",
  "scope_spec.lua",
  "ignore_spec.lua",
  "config_spec.lua",
  "hover_spec.lua",
}

local failed = 0
for _, name in ipairs(specs) do
  local run = dofile(dir .. name)
  local ok, err = pcall(run, H)
  if ok then
    print(("ok    %s"):format(name))
  else
    failed = failed + 1
    print(("FAIL  %s\n      %s"):format(name, tostring(err)))
  end
end

if failed > 0 then
  print(("\n%d spec(s) failed"):format(failed))
  os.exit(1)
end

print("\nLANGUAGE_TESTS_OK")
