# TESTS/

Headless spec suite. Every spec drives a module directly — no picker, no
window, no external spell CLI, no network.

```
nvim --headless -u NONE -c "set rtp+=." -l TESTS/run.lua
```

Exit 0 is a pass; the runner prints one line per spec and exits non-zero on the
first failure. CI runs exactly this command.

## lib.nvim

Several modules require lib.nvim at module load, so the suite cannot run
without it. `run.lua` resolves it in this order:

1. `$LIB_NVIM_PATH`
2. a sibling checkout, `../lib.nvim`
3. the lazy.nvim-managed copy under `stdpath("data")/lazy/lib.nvim`

A sibling wins over the plugin-manager copy on purpose: that one is often older
than the working checkout, and testing against a stale lib.nvim gives
misleading failures.

## The specs

| | |
| --- | --- |
| `split_spec.lua` | breaking an identifier into words a dictionary can be asked about — camelCase, acronyms, separators, and the offsets that turn a hit back into a highlight |
| `scope_spec.lua` | turning the words after a command into the region it acts on, and handing the caller's own arguments back |
| `ignore_spec.lua` | the session ignore set and the filter that applies it |
| `config_spec.lua` | the merge, and that `DEFAULTS` survives it unmutated |

Adding one: write `TESTS/<name>_spec.lua` returning `function(H) ... end`, then
list it in `run.lua`. `H` is the harness — `eq`, `ok`, `falsy`, `contains`,
`excludes`, `read` and `fixture`.

## What is deliberately not here

`ignore.add_persistent` writes into `stdpath("data")`, and the spell providers
shell out to `codespell`/`cspell` or talk to a language server; translation
needs `curl` and a network. None of that belongs in a suite that runs on every
push — it would either accumulate state in the developer's real ignore file or
fail for reasons that have nothing to do with the change under test.
