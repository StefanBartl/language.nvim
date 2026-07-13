---@module 'language.spell.providers.lsp'
---@brief Harvests grammar/spell diagnostics from language-server clients.
---@description
--- Grammar checkers like harper_ls and ltex publish their findings as normal
--- `vim.diagnostic` entries. This provider collects those (for the configured
--- servers) and maps them into the shared issue model so they appear in the
--- panel/list next to native spelling issues. Fixes for grammar issues are LSP
--- code actions; this phase surfaces and navigates them (jump), full
--- code-action application is a follow-up.

require("language.spell.@types")

local api = vim.api

local M = {}

M.name = "harper"
M.supports = { buffer = true, cwd = false, grammar = true }

---@return boolean
function M.available()
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  return type(get) == "function"
end

---Does diagnostic `d` come from one of the configured grammar servers?
---@param d table
---@param servers table<string, true>
---@return boolean
local function from_grammar_server(d, servers)
  -- LSP diagnostics carry a namespace named like "vim.lsp.<client>.<bufnr>".
  local ns = d.namespace
  if ns then
    local ok, info = pcall(vim.diagnostic.get_namespace, ns)
    if ok and info and type(info.name) == "string" then
      for server in pairs(servers) do
        if info.name:find(server, 1, true) then
          return true
        end
      end
    end
  end
  -- Fallback: match the human-readable source string.
  if type(d.source) == "string" then
    local s = d.source:lower()
    if s:find("harper") or s:find("ltex") or s:find("languagetool") then
      return true
    end
  end
  return false
end

---Text covered by a diagnostic range on its line (best-effort display word).
---@param bufnr integer
---@param d table
---@return string
local function range_text(bufnr, d)
  local line = api.nvim_buf_get_lines(bufnr, d.lnum, d.lnum + 1, false)[1] or ""
  local ec = (d.end_lnum == d.lnum) and d.end_col or #line
  local ok, sub = pcall(string.sub, line, d.col + 1, ec)
  if ok and sub and sub ~= "" then
    return sub
  end
  return d.message or "?"
end

---@param source string
---@return LanguageSpellKind
local function kind_of(source)
  local s = (source or ""):lower()
  if s:find("spell") then
    return "spell"
  end
  return "grammar"
end

---Scan a single-buffer scope by harvesting grammar diagnostics.
---@param scope LanguageScope
---@param cfg LanguageSpellCfg
---@return LanguageSpellIssue[]
function M.scan_scope(scope, cfg)
  local bufnr = scope.bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local lsp_cfg = (cfg.providers and cfg.providers.lsp) or {}
  if lsp_cfg.enable == false then
    return {}
  end
  ---@type table<string, true>
  local servers = {}
  for _, name in ipairs(lsp_cfg.servers or { "harper_ls", "ltex" }) do
    servers[name] = true
  end

  local path = api.nvim_buf_get_name(bufnr)
  local lo, hi
  if (scope.kind == "visible" or scope.kind == "selection") and scope.range then
    lo, hi = scope.range.s - 1, scope.range.e - 1
  end

  ---@type LanguageSpellIssue[]
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if from_grammar_server(d, servers) then
      if not lo or (d.lnum >= lo and d.lnum <= hi) then
        out[#out + 1] = {
          bufnr = bufnr,
          path = path,
          lnum = d.lnum + 1,
          col = d.col + 1,
          end_col = (d.end_lnum == d.lnum and d.end_col or d.col) + 1,
          word = range_text(bufnr, d),
          kind = kind_of(d.source),
          source = (type(d.source) == "string" and d.source:lower():find("ltex")) and "ltex"
            or "harper",
          message = d.message,
          rule = (type(d.code) == "string" or type(d.code) == "number") and tostring(d.code) or nil,
        }
      end
    end
  end
  return out
end

---Grammar issues have no native suggestions; return none.
---@param _issue LanguageSpellIssue
---@return string[]
function M.suggest(_issue)
  return {}
end

return M
