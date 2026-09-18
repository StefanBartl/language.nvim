-- TESTS/health_spec.lua — language.health: `M.check()` (the `:checkhealth
-- language` entry point) driven directly, branch by branch.
--
-- Round 8 (see git history) left this file annotated in TESTS/README.md as
-- "not tested branch-by-branch, since each branch is a declarative
-- vim.health.* call with no computed value to assert on" -- true of maybe
-- half its sections, but check_hover()'s four-state detection, check_grammar
-- ()'s attached-client list, and check_translate()'s deepl-key resolution
-- are all real computed values, and M.check()'s own tail turns out to have a
-- real bug (see the BUG block at the end). This closes that gap.
--
-- health.lua binds vim.health.ok/warn/error/info/start into its own
-- module-level locals ONCE, at require time -- so `capture()` (which
-- reassigns fresh closures to vim.health.*) only takes effect for a spec
-- that reloads the module afterwards. `reload_health()` does exactly that;
-- every block below calls `capture()` then `reload_health()`, in that order,
-- never the other way around.
--
-- Every optional collaborator (curl/typos/cspell/codespell/node/trans,
-- attached LSP clients, hover.nvim, which-key, lib.nvim.deps.health) is
-- monkeypatched or stubbed so each branch is reachable deterministically, on
-- any machine -- not just one that happens to have a given tool on PATH.

return function(H)
  local config = require("language.config")

  -- vim.health.* originals, restored at the very end ------------------------
  local orig_health = {
    start = vim.health.start,
    ok = vim.health.ok,
    warn = vim.health.warn,
    error = vim.health.error,
    info = vim.health.info,
  }
  local orig_executable = vim.fn.executable
  local orig_get_clients = vim.lsp.get_clients
  local orig_spelllang = vim.o.spelllang
  local orig_deepl_env = vim.env.DEEPL_API_KEY

  ---@type string[]
  local log

  --- Replace vim.health.* with recorders into a fresh `log`. Must be
  --- followed by `reload_health()` -- see the module comment above.
  local function capture()
    log = {}
    vim.health.start = function(name)
      log[#log + 1] = "start: " .. name
    end
    vim.health.ok = function(msg)
      log[#log + 1] = "ok: " .. msg
    end
    vim.health.warn = function(msg)
      log[#log + 1] = "warn: " .. msg
    end
    vim.health.error = function(msg)
      log[#log + 1] = "error: " .. msg
    end
    vim.health.info = function(msg)
      log[#log + 1] = "info: " .. msg
    end
  end

  ---@return string
  local function text()
    return table.concat(log, "\n")
  end

  local function reload_health()
    package.loaded["language.health"] = nil
    return require("language.health")
  end

  ---@param present table<string, boolean>
  local function stub_tools(present)
    vim.fn.executable = function(bin)
      if present[bin] ~= nil then
        return present[bin] and 1 or 0
      end
      return orig_executable(bin)
    end
  end

  ---@param names string[]
  local function stub_clients(names)
    vim.lsp.get_clients = function()
      local out = {}
      for _, n in ipairs(names) do
        out[#out + 1] = { name = n }
      end
      return out
    end
  end

  -- lib.nvim.deps.health is a one-line pointer this module calls into;
  -- stubbed once, for every block below, so it never depends on
  -- docs/install.json actually being found and parsed.
  package.loaded["lib.nvim.deps.health"] = {
    report_for = function(name)
      log[#log + 1] = "deps_health.report_for: " .. name
    end,
  }

  -- A: everything present/attached/configured -- the all-green path --------
  capture()
  stub_tools({
    typos = true,
    cspell = true,
    codespell = true,
    node = true,
    curl = true,
    trans = true,
  })
  stub_clients({ "harper_ls" })
  vim.o.spelllang = "en"
  vim.env.DEEPL_API_KEY = nil
  config.setup({
    translate = { deepl = { api_key = "test-key" } },
    spell = {
      default_scope = "buffer",
      live = true,
      live_scope = "visible",
      filetypes = { "markdown" },
    },
  })

  local health = reload_health()
  local ok_a = pcall(health.check)
  H.ok(ok_a, "check() does not error when every collaborator resolves")
  H.contains(
    text(),
    "typos — fast tree-wide spell scan available",
    "typos present is a real ok, not just non-empty"
  )
  H.contains(text(), "cspell sidecar ready", "cspell + node together enable the sidecar hint")
  H.contains(
    text(),
    "grammar LSP attached: harper_ls",
    "the attached client's own name is in the message"
  )
  H.contains(text(), "curl — google (default, no key) + deepl engines ready", "curl present")
  H.contains(
    text(),
    "DeepL API key configured (deepl engine usable)",
    "a configured deepl key is reported"
  )
  H.contains(
    text(),
    "trans (translate-shell) — optional shell engine available",
    "the optional shell engine"
  )
  H.contains(text(), "spell.default_scope = buffer", "the effective config is echoed")
  H.contains(text(), "spell.live = true (live_scope = visible)", "including live-scan state")
  H.contains(text(), "spell.filetypes = markdown", "and the configured filetypes")
  H.contains(text(), "translate.engine = google", "and the translate engine")
  H.contains(text(), "'spelllang' = en", "and the current 'spelllang'")
  H.contains(text(), "hover.nvim not installed", "hover.nvim is not on this test's runtimepath")
  H.contains(text(), "which-key not found", "neither is which-key")
  H.contains(
    text(),
    "deps_health.report_for: language.nvim",
    "the deps.health pointer is reached with this plugin's own name"
  )

  -- B: the opposite of every optional-tool branch above ---------------------
  capture()
  stub_tools({
    typos = false,
    cspell = false,
    codespell = false,
    node = false,
    curl = false,
    trans = false,
  })
  stub_clients({})
  vim.o.spelllang = ""
  vim.env.DEEPL_API_KEY = nil
  config.setup({})

  health = reload_health()
  local ok_b = pcall(health.check)
  H.ok(ok_b, "check() does not error when every optional tool is absent")
  H.contains(
    text(),
    "typos not found (optional; native provider handles cwd via chunked scan)",
    "typos absent is optional, not an error"
  )
  H.contains(text(), "cspell not found (optional)", "same for cspell")
  H.contains(text(), "codespell not found (optional)", "same for codespell")
  H.excludes(text(), "cspell sidecar ready", "no sidecar hint with neither cspell nor node")
  H.excludes(
    text(),
    "persistent cspell sidecar unavailable",
    "nor its half-present variant, since cspell itself is absent"
  )
  H.contains(
    text(),
    "curl not found — google/deepl translate engines will not work",
    "curl absent is the one hard error in this section"
  )
  H.contains(text(), "no grammar LSP (harper_ls / ltex) attached", "no attached client at all")
  H.contains(
    text(),
    "no DeepL key (set translate.deepl.api_key or $DEEPL_API_KEY)",
    "no configured or env key"
  )
  H.contains(text(), "trans not found (optional shell engine)", "and the optional shell engine")
  H.contains(text(), "'spelllang' is empty", "an empty 'spelllang' is a warning, not silence")

  -- C: cspell present, node absent -- the third, distinct sidecar branch ----
  capture()
  stub_tools({
    typos = false,
    cspell = true,
    codespell = false,
    node = false,
    curl = false,
    trans = false,
  })
  stub_clients({})
  health = reload_health()
  health.check()
  H.contains(
    text(),
    "node not found — persistent cspell sidecar unavailable (one-shot cspell still works)",
    "cspell alone, without node, gets its own message rather than either all-or-nothing one"
  )

  -- D: an old Neovim and a vim.spell without .check -- self-contained, ------
  -- restored immediately rather than at the file's end, since other specs
  -- (native_spec.lua) depend on the real vim.spell throughout this run.
  do
    local orig_version = vim.version
    local orig_spell = vim.spell
    vim.version = function()
      return { major = 0, minor = 8, patch = 0 }
    end
    vim.spell = {}

    capture()
    health = reload_health()
    health.check()
    H.contains(text(), "Neovim 0.8.0", "an old version is named by number")
    H.contains(text(), "language.nvim requires 0.9+", "and called out as too old")
    H.contains(
      text(),
      "vim.spell.check missing — native spell provider unavailable",
      "and the native provider follows suit"
    )

    vim.version = orig_version
    vim.spell = orig_spell
  end

  -- E: hover = false short-circuits before hover.nvim is even probed --------
  capture()
  config.setup({ hover = false })
  health = reload_health()
  health.check()
  H.contains(text(), "hover = false -- nothing registered", "the switch itself is what is reported")

  config.setup({})

  -- F: hover.nvim installed -- the states language.hover's own presence and
  -- registration decide. `language.hover` is stubbed rather than driven for
  -- real (that is hover_spec.lua's job); only `registered()`/`target()` are
  -- read here, matching what check_hover() itself actually calls.
  do
    local contrib_honoured = false
    package.loaded["hover.registry"] = {
      contributors = function()
        if not contrib_honoured then
          return {}
        end
        return { { name = "language.nvim", on_request = 1 } }
      end,
    }

    -- installed, but nothing registered() ------------------------------------
    package.loaded["language.hover"] = {
      registered = function()
        return false
      end,
      target = function()
        return "EN"
      end,
    }
    capture()
    health = reload_health()
    health.check()
    H.contains(
      text(),
      "hover.nvim is installed, but nothing is registered",
      "state 1: installed, never registered"
    )

    -- installed, registered, but not seen as on_request ----------------------
    package.loaded["language.hover"] = {
      registered = function()
        return true
      end,
      target = function()
        return "EN"
      end,
    }
    capture()
    health = reload_health()
    health.check()
    H.contains(
      text(),
      "does not report the contribution as on_request",
      "state 2: registered, but an older hover.nvim would ask on every hover"
    )

    -- installed, registered, and correctly on_request -------------------------
    contrib_honoured = true
    capture()
    health = reload_health()
    health.check()
    H.contains(text(), "registered, on request only", "state 3: fully wired")
    H.contains(
      text(),
      "translates it to EN",
      "naming the target language health.lua read from the stub"
    )

    -- installed, but language.hover itself errors on load ---------------------
    package.loaded["language.hover"] = nil
    package.preload["language.hover"] = function()
      error("simulated: language.hover failed to load", 0)
    end
    capture()
    health = reload_health()
    health.check()
    H.contains(
      text(),
      "language.hover failed to load -- the contribution cannot be registered",
      "state 4: hover.nvim is there, this plugin's own module is broken"
    )
    package.preload["language.hover"] = nil
    package.loaded["language.hover"] = nil
    package.loaded["hover.registry"] = nil
  end

  -- G: BUG -- check_lib() already detects a missing composer and warns about
  -- it, but M.check()'s own tail requires the same module a few lines later
  -- with no guard at all, so the warning is not the end of the story: it is
  -- immediately followed by an uncaught error. A lib.nvim checkout old
  -- enough to lack `lib.nvim.bindings.usercmd.composer` -- exactly the case
  -- check_lib()'s own advice text names ("Update StefanBartl/lib.nvim") --
  -- does not just get a warning, it crashes `:checkhealth language` outright,
  -- and every section after "lib.nvim (required dependency)" that would have
  -- run this call (translate/config/which-key/hover/deps) never renders.
  -- Not fixed here: the fix (guard the three tail calls the same way
  -- check_lib() itself already guards its own probe, e.g. with pcall) is a
  -- real source change, not a test one.
  package.loaded["lib.nvim.bindings.usercmd.composer"] = nil
  package.preload["lib.nvim.bindings.usercmd.composer"] = function()
    error("simulated: this lib.nvim checkout has no composer module", 0)
  end

  capture()
  health = reload_health()
  local ok_g = pcall(health.check)
  H.falsy(
    ok_g,
    "BUG: an old lib.nvim without the composer module crashes check(), instead of degrading past the warning check_lib() already gave"
  )
  H.contains(
    text(),
    "usercmd.composer not found",
    "check_lib() did warn, correctly, before the crash"
  )

  package.preload["lib.nvim.bindings.usercmd.composer"] = nil
  package.loaded["lib.nvim.bindings.usercmd.composer"] = nil

  -- Teardown ------------------------------------------------------------------
  vim.fn.executable = orig_executable
  vim.lsp.get_clients = orig_get_clients
  vim.o.spelllang = orig_spelllang
  vim.env.DEEPL_API_KEY = orig_deepl_env
  vim.health.start = orig_health.start
  vim.health.ok = orig_health.ok
  vim.health.warn = orig_health.warn
  vim.health.error = orig_health.error
  vim.health.info = orig_health.info
  package.loaded["lib.nvim.deps.health"] = nil
  package.loaded["language.health"] = nil
  config.setup({})
end
