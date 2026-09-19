-- TESTS/collect_spec.lua — language.spell.core.collect: runs the configured
-- providers for a scope and post-processes (ignore filter, dedupe).
--
-- LSP and the external CLI providers are left out of the config used here
-- (never enabled), so every scan below exercises the native provider (+ the
-- native disk-tree fallback for `gather` over cwd/path) — no external tool, no
-- network, no real LSP client required.

return function(H)
  local collect = require("language.spell.core.collect")
  local cache = require("language.spell.core.cache")
  local ignore = require("language.spell.core.ignore")

  local BAD = "zzqqxxcollecttest"
  local IGNORED = "zzqqxxcollectignored"

  ---@return LanguageSpellCfg
  local function cfg(extra)
    return vim.tbl_deep_extend("force", {
      providers = { buffer = {}, cwd = {} }, -- no lsp/cspell_server/CLI providers enabled
      word_split = { enable = false },
      regions = { treesitter_spell = false },
      skip_readonly = true,
      ui = { dedupe = true },
    }, extra or {})
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { BAD .. " " .. BAD })

  -- scan(): single-buffer scope, deduped by default -------------------------
  local issues = collect.scan({ kind = "buffer", bufnr = buf }, cfg())
  H.eq(#issues, 1, "two identical issues on one line are deduped to one")
  H.eq(issues[1].occurrences, 2, "and the occurrence count says how many")

  local undeduped = collect.scan({ kind = "buffer", bufnr = buf }, cfg({ ui = { dedupe = false } }))
  H.eq(#undeduped, 2, "with dedupe off, both occurrences are kept")

  -- The ignore filter is applied even when the caller never touches
  -- `language.spell.core.ignore` directly — using a word dedicated to this
  -- one assertion so it does not affect the reportability of BAD below.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { IGNORED })
  ignore.add_session(IGNORED)
  H.eq(#collect.scan({ kind = "buffer", bufnr = buf }, cfg()), 0, "an ignored word is filtered out")

  -- scan() caches whole-buffer native results (kind == "buffer" only) -------
  -- cache.get() needs the same cfg used at scan time (PERF-46: the config
  -- knobs that affect the scan are part of the cache key).
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean text" })
  cache.invalidate(buf)
  local scan_cfg = cfg()
  collect.scan({ kind = "buffer", bufnr = buf }, scan_cfg)
  H.ok(cache.get(buf, scan_cfg) ~= nil, "a whole-buffer scan populates the native cache")

  vim.api.nvim_buf_delete(buf, { force = true })

  -- gather(): single-buffer scope delivers via callback ----------------------
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "another " .. BAD .. " here" })

  local done, delivered = false, nil
  collect.gather({ kind = "buffer", bufnr = buf2 }, cfg(), function(res)
    done, delivered = true, res
  end)
  H.ok(done, "gather() over a single buffer delivers synchronously (no async provider enabled)")
  H.eq(#delivered, 1, "and reports the flagged word")
  H.eq(delivered[1].word, BAD, "correctly")

  vim.api.nvim_buf_delete(buf2, { force = true })

  -- gather(): cwd/path with no CLI provider configured falls back to the real
  -- native disk-tree scan (async).
  local dir, cleanup = H.fixture("collect-gather")
  vim.fn.writefile({ BAD }, dir .. "/note.md")

  local tree_done, tree_issues = false, nil
  collect.gather({ kind = "path", path = dir }, cfg(), function(res)
    tree_done, tree_issues = true, res
  end)
  vim.wait(2000, function()
    return tree_done
  end)
  H.ok(tree_done, "the native tree fallback completes")
  H.eq(#tree_issues, 1, "and finds the flagged word on disk")
  H.eq(tree_issues[1].word, BAD, "correctly")

  cleanup()
end
