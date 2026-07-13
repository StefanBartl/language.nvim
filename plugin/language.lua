-- language.nvim — plugin entry point.
-- The plugin is lazy: setup() must be called by the user. This file only sets
-- a load guard so :checkhealth language works without an explicit setup().
if vim.g.loaded_language then
  return
end
vim.g.loaded_language = true
