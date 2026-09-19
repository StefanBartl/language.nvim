-- TESTS/spell_providers_cli_spec.lua — the external-CLI spell providers'
-- pure parts: output parsing (cspell/codespell, both explicitly "public for
-- testing" in their own source), path resolution (providers/util.lua), the
-- custom provider's cmd/parse contract, and the LSP grammar harvester's
-- diagnostic-matching logic.
--
-- What is NOT here: actually running typos/cspell/codespell/node. Those are
-- optional external tools this suite must not depend on being installed —
-- same reasoning TESTS/README.md already gives for the persistent cspell
-- sidecar and for `ignore.add_persistent`'s original exclusion. `typos.lua`'s
-- own JSON-lines parser is a local function (not exposed), unlike its two
-- siblings, so it is exercised only indirectly via `available()`'s false path.

return function(H)
  local putil = require("language.spell.providers.util")

  -- providers/util.lua ---------------------------------------------------------
  H.ok(putil.is_absolute("/a/b"), "a leading slash is absolute")
  H.ok(putil.is_absolute("C:/a/b"), "a drive letter is absolute")
  H.falsy(putil.is_absolute("a/b"), "a relative path is not")

  H.eq(putil.resolve_path("/already/abs.md", "/base"), "/already/abs.md", "an absolute path wins")
  H.contains(
    putil.resolve_path("rel.md", "/base"),
    "base",
    "a relative path is resolved against base"
  )
  H.eq(
    putil.resolve_path("x.md", nil),
    vim.fn.fnamemodify("x.md", ":p"),
    "no base: just fnamemodify(':p')"
  )

  H.eq(putil.bufnr_for("/no/such/buffer/x.md"), nil, "no loaded buffer for that path: nil")

  -- cspell.parse -----------------------------------------------------------
  local cspell = require("language.spell.providers.cspell")
  local issues = cspell.parse(
    "src/a.md:3:5 - Unknown word (recieve)\n"
      .. "not a matching line, ignored\n"
      .. "src/b.md:10:1 - Unknown word (fooo)",
    "/base"
  )
  H.eq(#issues, 2, "two lines matched the cspell lint format")
  H.eq(issues[1].word, "recieve", "the flagged word")
  H.eq(issues[1].lnum, 3, "its line")
  H.eq(issues[1].col, 5, "its column")
  H.eq(issues[1].end_col, 5 + #"recieve", "end_col is col + #word")
  H.eq(issues[1].source, "cspell", "tagged with its source")
  H.contains(issues[1].path, "a.md", "and resolved against base")

  H.eq(#cspell.parse("", "/base"), 0, "empty output: no issues")
  H.eq(#cspell.parse("garbage\nmore garbage", "/base"), 0, "unmatched lines: no issues")

  -- codespell.parse ----------------------------------------------------------
  local codespell = require("language.spell.providers.codespell")
  local cs_issues = codespell.parse(
    "docs/readme.md:12: teh ==> the\n" .. "docs/readme.md:20: recieve ==> receive, receive",
    "/base"
  )
  H.eq(#cs_issues, 2, "two codespell lines matched")
  H.eq(cs_issues[1].word, "teh", "the flagged word")
  H.eq(cs_issues[1].lnum, 12, "its line")
  H.eq(cs_issues[1].col, 1, "codespell reports no column: defaults to 1")
  H.eq(cs_issues[1].suggestions[1], "the", "a single correction is still parsed into suggestions")
  -- second line has two identical corrections separated by a comma+space
  H.ok(cs_issues[2].suggestions and #cs_issues[2].suggestions == 2, "multiple corrections parsed")
  H.eq(cs_issues[2].suggestions[1], "receive", "trimmed of surrounding whitespace")

  H.eq(#codespell.parse("", "/base"), 0, "empty output: no issues")

  -- typos.available()/scan_async(): the unavailable path never touches the
  -- network/filesystem and always resolves via cb({}) -----------------------
  local typos = require("language.spell.providers.typos")
  H.eq(typos.supports.cwd, true, "typos declares cwd support")
  H.eq(typos.supports.buffer, false, "and no buffer support")
  if not typos.available() then
    local done, delivered = false, nil
    typos.scan_async({ kind = "cwd" }, {}, function(res)
      done, delivered = true, res
    end)
    H.ok(done, "unavailable: scan_async still calls back synchronously")
    H.eq(#delivered, 0, "with an empty result, not an error")
  end

  -- spell providers/custom.lua: the escape-hatch CLI contract ---------------
  local custom = require("language.spell.providers.custom")
  H.falsy(custom.available({}), "no providers.custom configured: unavailable")
  H.falsy(
    custom.available({ providers = { custom = { cmd = function() end } } }),
    "cmd without parse: still unavailable"
  )
  H.ok(
    custom.available({ providers = { custom = { cmd = function() end, parse = function() end } } }),
    "both cmd and parse: available"
  )

  local done_u, delivered_u = false, nil
  custom.scan_async({ kind = "cwd" }, {}, function(res)
    done_u, delivered_u = true, res
  end)
  H.ok(done_u, "no config at all: still calls back")
  H.eq(#delivered_u, 0, "with nothing")

  -- A cmd that raises, or returns something that isn't an argv list, degrades
  -- to an empty result rather than propagating the error to the caller.
  local done_bad, delivered_bad = false, nil
  custom.scan_async({ kind = "cwd" }, {
    providers = {
      custom = {
        cmd = function()
          error("boom")
        end,
        parse = function()
          return {}
        end,
      },
    },
  }, function(res)
    done_bad, delivered_bad = true, res
  end)
  H.ok(done_bad, "a cmd() that errors still calls back")
  H.eq(#delivered_bad, 0, "with an empty result")

  -- A parse() that raises, or returns the wrong shape, also degrades to an
  -- empty result rather than propagating the error (ERR-11: notified, not
  -- silently indistinguishable from "clean"). `language.util.job` is stubbed
  -- so this never spawns a real process -- same reasoning the file header
  -- gives for not depending on external tools being installed.
  package.loaded["language.util.job"] = {
    run = function(_, opts)
      opts.on_done(true, "", "")
      return nil
    end,
  }
  package.loaded["language.spell.providers.custom"] = nil
  local custom_stubbed = require("language.spell.providers.custom")

  local done_parse_bad, delivered_parse_bad = false, nil
  custom_stubbed.scan_async({ kind = "cwd" }, {
    providers = {
      custom = {
        cmd = function()
          return { "whatever" }
        end,
        parse = function()
          error("parse boom")
        end,
      },
    },
  }, function(res)
    done_parse_bad, delivered_parse_bad = true, res
  end)
  H.ok(done_parse_bad, "a parse() that errors still calls back")
  H.eq(#delivered_parse_bad, 0, "with an empty result")

  -- Entries missing word/path are dropped, but well-formed ones alongside
  -- them still come through.
  local done_partial, delivered_partial = false, nil
  custom_stubbed.scan_async({ kind = "cwd" }, {
    providers = {
      custom = {
        cmd = function()
          return { "whatever" }
        end,
        parse = function()
          return {
            { word = "teh", path = "/f.txt", lnum = 1 },
            { word = "no path here" },
          }
        end,
      },
    },
  }, function(res)
    done_partial, delivered_partial = true, res
  end)
  H.ok(done_partial, "a partially-malformed parse() result still calls back")
  H.eq(#delivered_partial, 1, "the malformed entry is dropped, the well-formed one kept")
  H.eq(delivered_partial[1].word, "teh", "the surviving entry")

  package.loaded["language.util.job"] = nil
  package.loaded["language.spell.providers.custom"] = nil

  -- LSP grammar harvester ------------------------------------------------------
  local lsp = require("language.spell.providers.lsp")
  H.eq(lsp.supports.grammar, true, "declares grammar support")
  H.eq(lsp.supports.cwd, false, "and no cwd support (buffer diagnostics only)")
  H.eq(#lsp.suggest({}), 0, "grammar issues carry no native suggestions")

  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "This is bad grammar." })
  local ns = vim.api.nvim_create_namespace("language_test_harper")
  vim.diagnostic.set(ns, buf, {
    {
      lnum = 0,
      col = 0,
      end_lnum = 0,
      end_col = 4,
      message = "consider rewording",
      source = "harper_ls",
      severity = vim.diagnostic.severity.WARN,
    },
  })

  local grammar_issues = lsp.scan_scope(
    { kind = "buffer", bufnr = buf },
    { providers = { lsp = { enable = true } } }
  )
  H.eq(#grammar_issues, 1, "the harper_ls diagnostic is harvested")
  H.eq(grammar_issues[1].source, "harper", "matched by its source string")
  H.eq(grammar_issues[1].kind, "grammar", "kind defaults to grammar for a non-spell source")
  H.contains(grammar_issues[1].word, "This", "range_text reads the covered text off the line")

  H.eq(
    #lsp.scan_scope({ kind = "buffer", bufnr = buf }, { providers = { lsp = { enable = false } } }),
    0,
    "lsp.enable = false: nothing harvested"
  )

  -- A source string that names neither a configured server nor one of the
  -- hardcoded fallback names (harper/ltex/languagetool) is never harvested,
  -- regardless of `providers.lsp.servers` — note that the fallback match
  -- below is itself hardcoded and does *not* consult `servers` (see the
  -- adjacent quirk noted in TESTS/README.md's coverage section).
  vim.diagnostic.reset(ns, buf)
  vim.diagnostic.set(ns, buf, {
    {
      lnum = 0,
      col = 0,
      end_lnum = 0,
      end_col = 4,
      message = "unused variable",
      source = "eslint",
      severity = vim.diagnostic.severity.WARN,
    },
  })
  H.eq(
    #lsp.scan_scope(
      { kind = "buffer", bufnr = buf },
      { providers = { lsp = { enable = true, servers = { "eslint" } } } }
    ),
    0,
    "a source outside the hardcoded harper/ltex/languagetool fallback is never harvested, even if named in `servers`"
  )

  -- A "spell" source is tagged kind = spell instead of grammar.
  vim.diagnostic.reset(ns, buf)
  vim.diagnostic.set(ns, buf, {
    {
      lnum = 0,
      col = 0,
      end_lnum = 0,
      end_col = 4,
      message = "spelling",
      source = "harper_ls spelling",
      severity = vim.diagnostic.severity.WARN,
    },
  })
  local spell_kind = lsp.scan_scope(
    { kind = "buffer", bufnr = buf },
    { providers = { lsp = { enable = true } } }
  )
  H.eq(spell_kind[1].kind, "spell", "a source string containing 'spell' is tagged kind = spell")

  vim.diagnostic.reset(ns, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end
