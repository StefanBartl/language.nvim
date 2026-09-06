# Health

```vim
:checkhealth language
```

Nine sections. Each optional tool is reported `info` when absent, not
`warn` — a missing optional spell/grammar backend just means fewer engines
to choose from, never a broken install.

| Section | Checks |
|---|---|
| Neovim | `>= 0.9` required (`error` below it); `vim.spell.check` (the native spell provider) |
| `lib.nvim` (required dependency) | The plugin itself, plus `lib.nvim.bindings.usercmd.composer` (the `:Spellcheck`/`:Translate`/`:TranslateReplace` command layer) |
| Spell providers (optional external tools) | `typos`, `cspell`, `codespell` — each independently `info` if missing; separately, `node` for the persistent `cspell` sidecar (`spell.providers.buffer = "cspell_server"`) |
| Grammar providers (optional LSP) | Whether `harper_ls` or `ltex` is attached to the current buffer |
| Translate engines | `curl` (needed by the default `google` and the `deepl` engine — `error` if missing), a configured DeepL API key, and `trans` (translate-shell, the optional `shell` engine) |
| Configuration | Dumps `spell.default_scope`, `spell.live` / `live_scope`, `spell.filetypes`, `translate.engine`; separately checks `'spelllang'` is actually set (`warn` if empty — nothing here sets it for you) |
| which-key (optional) | Whether group labels get registered; keymap `desc` fields work either way |
| Declared tools (`lib.nvim.deps`) | Cross-check against [install.json](install.json) |
| hover.nvim integration (optional) | Whether anything is registered, and — only when it should be — whether hover.nvim actually reports the contribution as `on_request` |

The hover section is the one worth reading carefully: `hover = false` and
"hover.nvim not installed" are both `info`, not `warn` — two different
reasons nothing is registered, neither a problem. A `warn` there only
fires when hover.nvim **is** installed and `hover.nvim`'s own registry
disagrees with what this plugin thinks it registered.

Thesaurus lookups (`opts.thesaurus.keymap`, see
[FEATURES/THESAURUS.md](FEATURES/THESAURUS.md)) go through Datamuse, a web
API with no local binary, so there is no thesaurus-specific health check
to run.
