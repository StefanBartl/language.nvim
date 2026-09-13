# Features

Language tools for Neovim in one plugin, built on `lib.nvim`: spelling and
grammar checking you can act on directly, and translation — sharing one
scope model (buffer / visible range / cwd / path / selection) and running
fully asynchronously throughout.

Language work in an editor usually means leaving it: a browser tab for the
translation, a separate linter run for the spelling, a thesaurus site for the
word that is almost right. Each of those is a context switch out of the text
you were writing. This plugin keeps all three in the buffer, over one shared
scope vocabulary — `buffer`, `visible`, `cwd`, `path=<p>`, `selection`,
`cword` — so the same word means the same thing to every command.

| Area | Does |
| --- | --- |
| **Spell** | A per-buffer review session with diagnostics you jump between and fix in place, native or through external providers (`cspell`, `codespell`, `typos`), code-aware, with a persistent cspell sidecar when `node` is there |
| **Grammar** | The same session fed from an LSP, so grammar findings land in the same list as spelling ones |
| **Translate** | `:Translate` into a popup that leaves the buffer alone, `:TranslateReplace` when you mean to mutate — eight output destinations, an engine fallback chain, and an interactive window with live translation while typing |
| **Thesaurus** | The word under the cursor swapped for a synonym, keyless via Datamuse; `3{lhs}` takes the third directly, the way `3z=` takes the third spelling suggestion |

Everything runs asynchronously and cancellably: a scan over a directory tree
does not block the editor, and starting a new one ends the old.

One page per theme, and each of them says what the feature is for rather than
only that it exists.

- **[SPELL.md](SPELL.md)** — spelling and grammar you can act on without
  leaving the buffer: the per-buffer review session and its diagnostics, the
  jump-and-fix keys, grammar over LSP, external providers and the persistent
  cspell sidecar, the recursive directory scan, code-aware detection, and what
  the live scan costs.
- **[TRANSLATE.md](TRANSLATE.md)** — `:Translate` and `:TranslateReplace`: the
  engine fallback chain, the eight output destinations and why the popup is
  the default, a custom provider, the indent-preserving round trip, and
  column-precise selections.
- **[THESAURUS.md](THESAURUS.md)** — the word under the cursor swapped for a
  synonym from the keyless Datamuse API or a source of your own, and how to
  take the *n*-th suggestion directly. Opt-in keymap.
- **[CORE.md](CORE.md)** — what spell and translate share: the one scope
  vocabulary every command parses the same way, the cancellable async job
  layer, the `lib.nvim.deps` install popup, and how the bindings are composed.
- **[HOVER.md](HOVER.md)** — the word under the cursor, translated into a
  hover.nvim float: why it is asked only on request, what it costs to block
  for, and the HTTP 429 that measurement found waiting behind the keyless
  endpoint.
