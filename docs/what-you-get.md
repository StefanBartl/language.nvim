# What you get with the defaults

| Command / key | Does |
| --- | --- |
| `:Spellcheck [lang] [scope]` | Start or toggle the review session over buffer, `visible`, `cwd` or `path=<p>` |
| `:Spellcheck clear` / `refresh` | End the session and drop the diagnostics, or rescan |
| `:Translate <lang> [scope]` | Translate into a popup; the buffer is not touched |
| `:Translate <lang> --output=<m>` | `popup`, `replace`, `buffer`, `vsplit`, `split`, `tab`, `insert`, `clipboard` or `notify` |
| `:Translate!` | Interactive window, translating live as you type; a range pre-fills it |
| `:TranslateReplace <lang> [scope]` | The mutating counterpart — always replaces, no `--output=` |
| `--nocode` | Skips fenced and inline code spans in replace-style output |
| `<leader>ss` | Toggle the spell session in the current buffer |
| `]s` · `<leader>z=` · `<leader>z1` | Next issue · fix and advance · take the first suggestion |

Every other key — the translate operator, the visual-mode map, one key per
target language, the thesaurus swap — is off by default and named in
[BINDINGS.md](BINDINGS.md). The full command surface, with all flags
and scopes, is [usage.md](usage.md).
