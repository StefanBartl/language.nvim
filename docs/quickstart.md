# Quickstart

Open a file with prose in it and start a spell session — it stays on until you
end it, and every finding becomes a diagnostic you can jump to:

```vim
:Spellcheck
```

Inside the session, `]s` jumps to the next issue, `<leader>z=` picks a fix and
advances, `<leader>z1` takes the first suggestion outright. Then:

```vim
:Spellcheck de path=~/notes   " a file or folder instead of this buffer
:Spellcheck clear             " end the session, remove the diagnostics

:'<,'>Translate DE            " popup with the translation, buffer untouched
:'<,'>TranslateReplace DE     " same selection, but REPLACES the text
:Translate DE cword           " just the word under the cursor
:Translate!                   " interactive window, live translation while typing
```

Verify your setup any time with:

```vim
:checkhealth language
```

See [usage.md](usage.md) for the full command reference, and
[What you get with the defaults](what-you-get.md) for the rest of the
surface at a glance.
