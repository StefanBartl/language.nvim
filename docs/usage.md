# Usage

```vim
:Spellcheck                 " check the current buffer (toggle session on/off)
:Spellcheck en cwd          " all text files under cwd (recursive, CLI preferred, otherwise native tree walking)
:Spellcheck de path=~/notes " file or folder
:Spellcheck clear           " end session, remove diagnostics
:Spellcheck refresh         " rescan

:'<,'>Translate DE           " popup with the translation, buffer untouched
:Translate FR --output=vsplit " translation in a new vertical split
:'<,'>TranslateReplace DE    " selection to German, REPLACES the text (classic behavior)
:TranslateReplace EN --nocode " replaces, skips fenced/inline code
:Translate!                  " interactive window (live translation while typing)
:'<,'>Translate! DE          " window pre-filled with the selection, target DE
:Translate DE cwd            " select files in cwd (Tab) & translate → name.DE.ext
:TranslateReplace DE cwd     " select files & overwrite in place (with confirmation)
```

Default keymap: `<leader>ss` toggles the spell session in the current buffer
(configurable). During a session: `<leader>z=` fix & advance, `<leader>z1`
accept the first suggestion & advance, `]s` next issue.
