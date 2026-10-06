-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "language",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  dialect = "h",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  -- ui.nvim is deliberately absent: the suite must pass without it (see TESTS/README.md).
  deps = { "lib.nvim" },
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "none",
  -- Guards (see testing.nvim's docs/GUARDS.md). Measured on this suite: fs, scheduled_error, prompt,
  -- deprecation and process_net are clean with the allowlist below; state is not.
  guards = {
    fs = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "error",
    -- Under isolated = "none" the specs leave what setup() and the code under test create: the
    -- :Spellcheck / :Translate / :TranslateReplace commands, the language_nvim BufDelete autocmd,
    -- the <leader>Z.. keymaps, the 'operatorfunc' / 'spell' options and a few scratch buffers.
    -- Real leaks between spec files: reported (warn) instead of failing the run until the specs clean up.
    -- isolated = "file" is not an option yet: spell_init_spec needs a downloaded spell file for "de" in
    -- the developer's real stdpath('data'); a hermetic child gets the "Download? [y/N]" prompt and fails.
    state = "warn",
  },
  guard_allow = {
    -- The specs create and remove fixture directories TESTS/.fixture-* inside the repository
    -- (collect, ignore, job, native, spell, translate, cspell server); relative to the project root.
    fs = { "TESTS" },
    -- Specs start headless nvim children (job stdin / sleep, version probe) to exercise the job
    -- wrapper; the nonexistent executable is the deliberate negative probe of the spawn-failure path.
    -- translate_markdown_curl_spec runs a real curl against a loopback server inside the spec's own
    -- editor (no external network): the placeholder must survive the argv path of a real process.
    spawn = { "nvim", "curl", "zzqqxx-nonexistent-executable-language-nvim" },
  },
}
