---@module 'language.config'
---@brief Merges user options (from setup()) over the plugin's defaults.
---@description
--- See config/DEFAULTS.lua for the default values and config/@types for their
--- types. Use `get()` to read the active configuration; never mutate the
--- returned table.

require("language.config.@types")

local M = {}

---@type LanguageConfig
local defaults = require("language.config.DEFAULTS")

---@type LanguageConfig
local current = vim.deepcopy(defaults)

---Merge user options over the defaults.
---@param opts LanguageConfig|table|nil
---@return nil
function M.setup(opts)
  current = vim.tbl_deep_extend("force", defaults, opts or {})
end

---Return the active configuration.
---@return LanguageConfig
function M.get()
  return current
end

return M
