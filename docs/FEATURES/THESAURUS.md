# Thesaurus

## Synonym replacement

`require("language").synonyms()` replaces the word under the cursor with a
synonym looked up from the free, keyless Datamuse API (async), or from a
`custom` source/language if configured. Opt-in keymap.

- **Module:** `thesaurus/init.lua`
- **Keymaps:** `opts.thesaurus.keymap` (off by default) — [keymaps](../BINDINGS.md#keymaps)
- **Config:** `opts.thesaurus.keymap`, `opts.thesaurus.custom`
