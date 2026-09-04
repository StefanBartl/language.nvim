# Features

Language tools for Neovim in one plugin, built on `lib.nvim`: spelling and
grammar checking you can act on directly, and translation — sharing one
scope model (buffer / visible range / cwd / path / selection) and running
fully asynchronously throughout.

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
