# Thesaurus

## Synonym replacement

`require("language").synonyms()` replaces the word under the cursor with a
synonym looked up from the free, keyless Datamuse API (async), or from a
`custom` source/language if configured. Opt-in keymap.

- **Module:** `thesaurus/init.lua` (`replace_under_cursor`)
- **Keymaps:** `opts.thesaurus.keymap` (off by default) — [keymaps](../BINDINGS.md#keymaps)
- **Config:** `opts.thesaurus.keymap`, `opts.thesaurus.custom`

### Taking the Nth synonym directly (2026-08-24)

`3{keymap}` replaces the word with the third synonym without opening the
menu, the way `3z=` takes the third spelling suggestion. The list already
exists at that point — the menu was only ever the way to choose from it.
Closes the count-support audit's entry.

`vim.v.count` is read raw rather than `count1`: 0 must stay distinguishable
from 1, since no count opens the menu while `1` takes the first synonym
outright.

Out of range is **reported, not clamped**. Clamping would substitute a
different word than the one you counted — an edit you did not ask for — and
`z=` errors in the same situation.
