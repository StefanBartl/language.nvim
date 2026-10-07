# TESTS/

Headless spec suite. Every spec drives a module directly — no picker, no
window, no external spell CLI, no network.

```
bash scripts/test.sh                  # every spec
bash scripts/test.sh --file config    # only spec files whose name contains "config"
bash scripts/test.sh --json ir.json   # also write the machine-readable result
```

The specs are run by [testing.nvim](https://github.com/StefanBartl/testing.nvim)
(configured in `.testing.lua`; dialect `h`, i.e. on this directory's own
`harness.lua`). Every `*_spec.lua` under `TESTS/` is discovered — there is no
list to maintain. Exit 0 is a pass; a failed spec, or a missing testing.nvim /
lib.nvim, exits 1 (and the script prints `LANGUAGE_TESTS_OK` on a green run).
CI runs exactly this command.

## testing.nvim and lib.nvim

Several modules require lib.nvim at module load, so the suite cannot run
without it. `scripts/test.sh` resolves testing.nvim and lib.nvim, each in
this order (a missing one is a loud error naming all four places):

1. `$TESTING_NVIM_DIR` / `$LIB_NVIM_DIR`
2. `.deps/<name>`
3. a sibling checkout, `../<name>`
4. the lazy.nvim-managed copy under `stdpath("data")/lazy/<name>`

A sibling wins over the plugin-manager copy on purpose: that one is often older
than the working checkout, and testing against a stale lib.nvim gives
misleading failures.

## The specs

| | |
| --- | --- |
| `split_spec.lua` | breaking an identifier into words a dictionary can be asked about — camelCase, acronyms, separators, and the offsets that turn a hit back into a highlight |
| `scope_spec.lua` | turning the words after a command into the region it acts on, and handing the caller's own arguments back |
| `ignore_spec.lua` | the session ignore set and the filter that applies it, plus the persistent list (redirected to a fixture file via `spell.dictionary.ignore_file`, never the developer's real one) |
| `actions_spec.lua` | `replace_all_in_buffer`'s whole-word boundary (not a substring match) and its empty-input/no-match paths, `add_to_dict`'s validation and its real `:spellgood` effect on `vim.spell.check` |
| `cache_spec.lua` | the per-buffer changedtick-keyed scan cache: hit, `changedtick`-invalidation on edit, explicit `invalidate`, and a deleted buffer never being a hit |
| `regions_spec.lua` | turning a scope into concrete byte/line ranges to scan |
| `native_spec.lua` | the native `:spellgood`/`z=`-backed provider |
| `collect_spec.lua` | gathering issues across providers/scopes and de-duplicating them |
| `spell_ui_spec.lua` | `ui/highlights.lua` and `ui/list.lua` (the two spell UI modules that do not require `ui.kit`) — diagnostic namespace, the per-buffer `max` cap |
| `live_spec.lua` | debounced live re-scanning on buffer change |
| `wordlists_spec.lua` | the built-in programming dictionary and extra-wordlist merging; `session_words`: a batch costs two `:spellgood!` commands instead of one per word, known words are not re-added (the counter drains the scheduled flush first, so these zero-command checks can really fail), invalid entries are dropped (also blank-only, U+FEFF and trailing-slash entries at either end of a batch, which would break the first/last-word handshake), the per-word fallback (list file not found, or a wrong file found) still lands every word, and with no temp dir at all the lookup returns nil and never touches the working directory |
| `job_spec.lua` | `util/job`: argv/opts plumbing, `on_done`, a spawn failure reported through `on_done`, `cancel()` before completion suppressing it, and the Windows `cmd.exe /c` guard (a `.cmd`/`.bat` launcher is refused when an argument holds a quote, `%`, `^`, `&`, `\|`, `<`, `>` or a line break; the platform is injected, so it runs everywhere) |
| `spell_providers_cli_spec.lua` | the CLI/LSP spell providers (`codespell`, `cspell`, `custom`, `lsp`, `typos`) and their shared `util.lua`, all with the underlying process/LSP client stubbed |
| `spell_providers_cspell_server_spec.lua` | the persistent Node/cspell-lib sidecar (`cspell_server.lua`): `available()`, `resolve()`'s nested/hoisted candidate paths and its failure case, `ensure_started()`'s reentrancy and `jobstart` failure, `on_stdout`'s line buffering (including a line split across two chunks), the ready/error/id-reply dispatch, request/reply round-tripping with issue tagging, `cancel()`, `on_exit()` dropping pending requests, and the `VimLeavePre` kill handler — with `language.util.job` and `vim.fn.jobstart`/`chansend`/`jobstop` stubbed, never a real node or cspell-lib |
| `translate_filter_indent_spec.lua` | the line filter that skips fenced code/front-matter, and re-indenting translated output to match the source |
| `translate_output_spec.lua` | applying translated output back to a buffer, register, or via notify |
| `translate_history_spec.lua` | recording/labelling/picking/clearing translation history, including label clipping for long input |
| `translate_chunk_spec.lua` | `translate/chunk.lua`, the wrapper around every engine: block boundaries (blank lines preferred, `max_lines`), `limits_for` (`max_chars` lowers, an engine's own option may raise), blank block edges surviving an engine that trims them (gtx / `trans` / a parse that splits the output on newlines and so gains a trailing empty line), a blank-only block never being sent, an over-long line cut at sentence/word boundaries (ASCII and CJK, never inside a UTF-8 character) and re-joined into one line, pinned rule by rule with exact pieces (each sentence and clause mark, the half-budget rule, boundaries that fall exactly on the budget, trailing white space trimmed from a piece, blank over-long lines left alone), packing of the pieces into requests (the byte budget, `max_lines` — more than 50 pieces of one line never share a DeepL request), a single token over the budget still failing with a message that says why, `translate.max_blocks`, the wrapper's contracts (empty input, surplus lines in an answer, a double callback, `cancel()` in every state, unusable config values), and the registry's google path with a stubbed job (a 3 600 character line, a 600 character Japanese line and a 40 000 byte line all translate) |
| `translate_providers_spec.lua` | the translate engines — registry resolution/fallback, and each provider's (`google`, `deepl`, `shell`, `custom`) request-building and response-parsing (google: the text is the stdin of a POST, not part of argv/URL; deepl: the stdin config is quoted by `lib.nvim.net.curl.config_quote`; shell/custom: the platform-dependent budget and `translate.custom.max_bytes`), with `util/job` stubbed so nothing hits curl or a real network |
| `translate_markdown_segment_spec.lua` | `translate/markdown/segment.lua`: what is never translated (front matter, fences, HTML blocks, definitions, indented code, math, table delimiter rows) and what is a unit (headings, paragraphs, items, quotes, every table cell), prefixes kept apart from content, hard breaks ending a unit, the container rules (a fence, a table or a list ends with its quote / item / first-column block; four columns beyond the container are code, so no fence or table opens and no closing fence closes there; text of an outer item; a `>` inside a fence; tab-indented fences; linear time on one long line, also a `<` with a long name and no `>`, a tag on a line of its own is an HTML block; setext, first-cell, math, front-matter, tab, CRLF and `[label]:` edge cases) and the round trip (rendering unchanged reproduces the source byte for byte, also over a fuzz of random fragment mixtures) |
| `translate_markdown_mask_spec.lua` | `translate/markdown/mask.lua`: what is masked (inline code, both halves of a link, autolinks, bare URLs, entities, footnote refs, keep words), that a placeholder is ASCII `{n}`, restoration byte for byte, the `check` gate (a lost, repeated or unknown placeholder, a link whose halves swapped) the bounded look-ahead (unclosed brackets, destinations and backtick runs stay linear; a unit that used up the budget is `degraded`), many addresses or unclosed comment openers in one unit without a quadratic scan, and the end of an address (a run of punctuation behind it, many `https://` in one run or in a link text), a tag with a long name and many `[^` without a quadratic match, an address at the end of a link text masked, the sentence punctuation trimmed as before |
| `translate_markdown_reflow_spec.lua` | `translate/markdown/reflow.lua`: exactly n lines, widths steering the split, the golden "no break before a block-start token" test (the dash that became a list item), fewer words than lines, a 3 000-case property test, the delimiter-row guard and a comparison with the plain full-range break search |
| `translate_markdown_anchors_spec.lua` | `translate/markdown/anchors.lua`: the slug of the mdview client (Unicode letters/numbers/white space, combining marks, final sigma, invalid bytes), the heading text as the previewer reads it, the old-to-new map with `-1` numbering and the rewriting of link and definition targets |
| `translate_markdown_cache_spec.lua` | `translate/markdown/cache.lua`: the key, the bounded memory cache, the disk file (persistence, size cap, merge with another instance, damaged and malformed files) in a fixture directory |
| `translate_markdown_spec.lua` | `translate_markdown` against a fake engine: golden documents (`TESTS/fixtures/markdown/`) with the same line count, byte-identical fences, restored placeholders and unchanged block types, the dash rule for every block-start token, anchors, validation/retry/fallback and "a failure is never cached", batching and concurrency, progress events, `cache_only`, cancellation, stale tokens, `cb` exactly once, a 250-case fuzz of the whole pipeline, the review-round regressions (setext heading, first cell, cell pipes, anchors of unchanged units, linear time on a 6 000-line paragraph, CRLF) and the independent-review ones (an answer that adds a link, image, tag, `www.` or e-mail address is refused, a degraded unit is not sent, an answer with a long run of white space is validated in linear time) and the second review round (an e-mail address in the forms the previewer links but a plain `%w@` test misses, `_@x.example`, `+@x.example`, `.@x.example`, `a@x_y.example`, is refused; the visible address of a link cannot be swapped for another one; a unit of 12 500 `https://`, a run of `)` behind an address and a `<` with a long name are masked, wrapped and checked in linear time; the hard-break address check looks at the last word only) |
| `translate_ai_provider_spec.lua` | the `ai` engine (`translate/providers/ai.lua`) against a fake `ai` module: request shape and bulk profile, strict parse (fence, count, types, placeholders, line breaks), one retry, policy and bulk-limit errors, cancel, chunking by the bulk budget, registry behaviour (no silent fallback), the cache identity as ai.nvim resolves it, no `bulk.reset` of an old run (it would refund the session cap), an ai.nvim without `ai.bulk` |
| `translate_markdown_curl_spec.lua` | the placeholder over the REAL curl path: the full pipeline (registry, chunk wrapper, `custom` engine, `util/job`, a curl process) against a loopback HTTP server in the spec's own editor; skipped without curl |
| `translate_init_spec.lua` | `translate.run`'s scope handling and buffer replace |
| `translate_motion_spec.lua` | the operator/motion entry point into translate |
| `translate_files_spec.lua` | `translate.files.process`/`run` against a fake provider — suffix/replace/buffers output modes, error handling, and the early-return guards, all without reaching `ui.kit`'s file picker |
| `thesaurus_spec.lua` | looking up and applying a synonym under the cursor, off the `ui.kit` picker branch |
| `bindings_usrcmds_spec.lua` | `:Spellcheck`/`:Translate`/`:TranslateReplace` argument parsing and dispatch, with `language.spell`/`language.translate`/`language.translate.window` stubbed |
| `usrcmds_help_spec.lua` | every flag of `:Translate`/`:TranslateReplace` (and `:Spellcheck`) has a line in lib.nvim's option float: `composer.help.undocumented(<verb>)` is empty |
| `bindings_keymaps_autocmds_spec.lua` | keymap registration for spell/translate/thesaurus, and the autocmd wiring (including the live-scan debounce arm/disarm and the write guard) |
| `language_init_spec.lua` | `language.setup()` end to end — command registration gating, idempotency, the lazy `M.health` facade, and the programming_dict/extra_wordlists gate |
| `spell_init_spec.lua` | the top-level `language.spell` facade — starting/closing a session, `:Spellcheck`'s scope dispatch, panel stubbed (see "Deliberately left untested") |
| `config_spec.lua` | the merge, and that `DEFAULTS` survives it unmutated |
| `hover_spec.lua` | the word under the cursor as a hover.nvim float — the word finder, the target language, decline-vs-fail, the rate-limit failure path, and `on_request` registration (translate provider and hover.nvim both stubbed) |
| `health_spec.lua` | `:checkhealth language` (`M.check()`) branch by branch: version/native-provider detection, every optional-tool present/absent pair (including the cspell-without-node middle case), the attached-grammar-client list, deepl-key resolution, the effective-config echo, and `check_hover()`'s four states — with every collaborator (tools, LSP clients, hover.nvim, which-key, `lib.nvim.deps.health`) stubbed or monkeypatched; also pins a real crash (see "Known bugs" below) |

Adding one: write `TESTS/<name>_spec.lua` returning `function(H) ... end`, then
run `scripts/test.sh` (it is discovered by its `_spec.lua` suffix). `H` is the harness — `eq`, `ok`, `falsy`, `contains`,
`excludes`, `read` and `fixture`.

## Coverage

Every `lua/language/**/*.lua` file with real logic or branching that can be
required without `ui.kit` now has a dedicated real-assertion spec: both spell
cores (split/scope/regions/collect/cache/ignore/actions), the native,
CLI/LSP, and persistent-sidecar spell providers, live scanning, the
wordlists, `util/job`, every translate provider plus the registry's fallback
chain, translate's filter/indent/output/history/files/motion pieces, the
thesaurus, all three bindings modules, `language/init.lua`'s `setup()`, and
`health.lua`'s `M.check()` branch by branch (not just the lazy facade that
resolves it). `ignore.add_persistent`, previously excluded for writing into
the developer's real `stdpath("state")` ignore file, is covered too —
redirected to a fixture path via the existing `spell.dictionary.ignore_file`
config option, which needed no source change. `cspell_server.lua`, previously
excluded outright as needing a real Node/cspell install, is covered the same
way the other CLI providers are: every real external call it makes goes
through `language.util.job` or a plain `vim.fn.*` global, both stubbable, so
its own logic (candidate resolution, line buffering, request/reply matching)
is exercised without ever spawning node or cspell-lib for real.

### Known bugs pinned by these specs (not fixed here)

Some specs assert the *current*, buggy behavior on purpose rather than
silently patching it — grep any spec file for `BUG:` for the full reasoning
inline. As of this audit:

- **`spell_init_spec.lua`** — `spell.clear()` does not actually restore a
  buffer's previous `'spelllang'` when the quickfix view (not the panel) is
  in use; it restores the wrong window's option.
- **`health_spec.lua`** — `check_lib()` correctly detects and warns about a
  `lib.nvim` checkout missing `bindings.usercmd.composer`, but `M.check()`'s
  own tail calls straight into that same module a few lines later with no
  guard at all — so instead of degrading past the warning already given, an
  old `lib.nvim` crashes `:checkhealth language` outright, and everything
  after the "lib.nvim (required dependency)" section (translate/config/
  which-key/hover/deps) never renders.

### Deliberately left untested

- **`spell/ui/panel.lua`, `spell/ui/item_menu.lua`** — both `require("ui.kit")`
  at module load. This repo's CI (`.github/workflows/ci.yml`) checks out only
  `lib.nvim` as a sibling, not `ui.nvim`/`ui.kit` — so a spec that so much as
  `require`s either module would pass locally (where a `ui.nvim` checkout
  happens to be on disk) and fail in CI. `spell_init_spec.lua` stubs
  `language.spell.ui.panel` in `package.loaded` purely so `M.clear()`'s call
  into it does not error; the panel's own rendering logic is not exercised.
- **`translate/window.lua`** — the interactive `:Translate` (bang) window.
  `require("ui.kit")` is lazy (inside its functions, not at module top), so it
  does not fail CI's module-load, but exercising its actual picker/prompt flow
  needs `ui.kit` regardless. `bindings_usrcmds_spec.lua` only stubs it as a
  collaborator to assert that the bang form reaches it instead of
  `translate.run`.
- **`config/DEFAULTS.lua`** — a plain data table (`return { ... }`); its merge
  behavior is what `config_spec.lua` actually tests.
- **`@types` modules** (`language/@types`, `config/@types`,
  `spell/@types`, `translate/@types`) — `---@meta`-style annotation files, no
  runtime behavior.

Translation itself (`curl`/network), the shell-based spell providers, and the
persistent cspell sidecar's actual process stay stubbed at the `util/job` /
`vim.fn.*` boundary throughout — none of this suite spawns a real process,
a real Node runtime, or touches the network.
