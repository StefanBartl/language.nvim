# Translate

Translating text with a choice of engines and output destinations, none of
which require an external Neovim plugin — only `curl` for the default
keyless engine.

## `:Translate` / `:TranslateReplace`

`:Translate` translates a range/selection and, by default, shows the
result in a read-only, focusable `ui.kit` popup — the buffer
stays untouched. `--output=` selects an alternative destination:
`replace`/`buffer`/`vsplit`/`split`/`tab`/`insert`/`clipboard`/`notify`.
`:TranslateReplace` is the direct, mutating counterpart — always
`replace`, no `--output=` flag — restoring the classic "select, translate,
replace" workflow under its own name. `--nocode` skips fenced and inline
code spans (relevant to replace-style output only).

- **Tab:** true
- **Module:** `translate/init.lua`, `translate/output/init.lua`
- **Usercmds:** `:Translate <lang> [--nocode|--output=<m>|--files=<m>] [cword|selection|buffer|cwd|path=<p>]`, `:TranslateReplace <lang> [--nocode] [selection|buffer|cwd|path=<p>]` — [user commands](../BINDINGS.md#user-commands)
- **One word:** the `cword` scope, and — with hover.nvim installed — `:Hover show` over a word. See [HOVER.md](HOVER.md).
- **Config:** `opts.translate.default_output` (default `"popup"`), `opts.translate.engine` (default `"google"`)

An unrecognized `--flag` is now a reported error (composer's declared-flags
gate runs before the handler), not silently ignored as it was
pre-composer.

## Engines with fallback chain

Google (keyless `gtx` endpoint, default, zero configuration), DeepL
(`deepl.api_key` or `$DEEPL_API_KEY`), `translate-shell`, or a custom CLI —
`opts.translate.fallback` is an ordered list tried if the selected engine
is unavailable.

- **Module:** `translate/providers/{google,deepl,shell,custom,registry}.lua`
- **Config:** `opts.translate.engine`, `opts.translate.fallback` (default `{"google"}`), `opts.translate.deepl.api_key`

### Large inputs: chunking

Windows rejects a command line above roughly 32 700 characters
(`ENAMETOOLONG`), and the engines have limits of their own, so no provider
ever receives an arbitrarily large payload. `providers/registry.lua` wraps
every engine with `translate/chunk.lua`, which cuts the input into blocks on
line boundaries (preferring blank lines), translates them one after the
other through the unchanged provider and joins the results; the line count
is preserved, which the indent restoration relies on. This applies to the
command, the operators, the window, the hover and multi-file translation.

The budget is counted in **cost units**, which are bytes of the text plus one
per line for the separator -- except DeepL, which counts 8 extra per line for
the JSON quoting of each text. This is the unit of `translate.max_chars`.

| Engine | Block budget (cost units) | Payload |
| --- | --- | --- |
| google | 15 000 | POST body on stdin (`--data-urlencode q@-`): neither in the URL nor in argv |
| shell | 6000 on Windows, 20 000 elsewhere | argv (one element) |
| custom | same as shell; `translate.custom.max_bytes` replaces it | whatever `cmd` builds |
| deepl | 50 lines, 60 000 | key **and** JSON body on stdin (`curl -K -`), never argv |

- **Blank lines at the edge of a block are layout, not content.** The engines
  trim them (gtx drops leading and trailing newlines, `trans` output is
  right-trimmed, a custom `vim.split(out, "\n")` adds a trailing empty
  string), so they are not sent and are put back around the result; a block
  that is blank throughout is not sent at all. Without this every cut at a
  paragraph break would lose a line and merge two paragraphs.
- **A single line over the budget is cut, not refused.** It is split at
  sentence ends (`. ! ? ;` before white space, and the CJK `。！？；`), else at
  white space, never inside a UTF-8 character; the pieces are translated in
  blocks of their own and re-joined with a single space, so the input line
  stays one output line. Only a line that has no such boundary inside the
  budget (one giant token, e.g. minified JSON or base64) fails the call, with
  a message naming the line.
- `opts.translate.max_chars` (cost units, `0` = engine default) can only lower
  the budget; `opts.translate.custom.max_bytes` is the one way to raise the
  `custom` budget, for a `cmd` that does not put the text into argv.
- `opts.translate.max_blocks` (default `50`, `0` = no limit) refuses an input
  that would need more requests than that, before the first one is sent, with
  a message naming the option. A large buffer or file is otherwise fired off
  request by request (the keyless gtx endpoint rate-limits), and everything
  sent before a late failure has already left the machine.
- `opts.translate.timeout_ms` applies to **each request**, not to the whole
  call: a chunked input can take up to `blocks * timeout_ms`.
- A failing block fails the whole call (one callback, with the block and
  line range in the message); `cancel` stops the running block and the rest.
- `util/job.run` reports a spawn failure through `on_done(false, ...)`
  instead of throwing, and `translate.files.process` turns a failure into a
  failed file while the remaining files carry on.
- **Windows launchers that are not `.exe`** (an npm-style or `.cmd`/`.bat`
  shim for `trans` or a custom engine) are started through `cmd.exe /c`, and
  its parser would interpret a `"`, `%`, `^`, `&`, `|`, `<`, `>` or line break
  inside the translated text. `util/job.run` refuses such a command with a
  message instead of running it; use an `.exe` for the engine (or one of the
  curl-based engines) to translate arbitrary text.

## Markdown API: `translate_markdown`

```lua
local handle = require("language").translate_markdown(lines, opts, function(ok, result, info)
  -- ok == true:  result is string[], exactly #lines long; info is the report
  -- ok == false: result is a message ("cancelled", "stale", "no available translate engine ...")
end)
handle.cancel() -- optional; the callback then runs once with (false, "cancelled")
```

Translates a whole Markdown document and gives back **exactly as many lines as
it got** (`#result == #lines`, a hard invariant: when an internal check ever
disagrees, the original comes back). It is the engine behind a translated
preview: the buffer stays German, the previewer shows English, and every
line-based mapping of the previewer (scroll sync, cursor marker,
click-to-navigate) stays valid because no line moves.

Not a command: there is no `:Translate` flag for it. It is for Lua callers
(mdview.nvim is the first).

### Options

| Option | Meaning |
| --- | --- |
| `target` | **Required.** Target language, e.g. `"EN"`. |
| `source` | Source language; `nil` lets the engine detect it. |
| `engine` | Overrides `translate.engine` for this call (no fallback chain). |
| `model` | Part of the cache key, for engines where a model matters (the AI engine to come). |
| `token` | `{ generation, current = fn }` (or `{ cancelled = true }`): the run is abandoned, `cb(false, "stale")`, once `current() ~= generation`. |
| `max_chars` | Bytes of masked text per request (default `translate.markdown.max_chars`, 3000). |
| `max_units` | Units per request (default 40; DeepL accepts 50 texts). |
| `concurrency` | Requests in flight (default `translate.markdown.concurrency`, 3). |
| `keep` | Words that are never translated (proper names), added to `translate.markdown.keep`. |
| `cache` | `false` bypasses the cache (read and write). |
| `cache_only` | Never asks the engine: a cached unit is translated, every other stays original, `info.pending` counts them. The building block for stale-while-revalidate: show this at once, then run again without it. |
| `on_unit` | `fun(ev)`: called once per finished block with `{ first, last, lines, status, done, total }`. `lines` replaces source lines `first..last` (same count). Progressive filling: patch the view as events arrive, finish with the `result` of `cb`. `status` is `"translated"`, `"cached"` or `"partial"`. A reference definition is no block, so its rewritten anchor target only appears in the final result. |

Every callback runs on the main loop and never before `translate_markdown` has
returned. `cb` runs **exactly once**, also after `cancel()`, a stale token or an
internal error.

`info` is the report: `units`, `translated`, `cached`, `failed` (stayed
original after validation and retry), `skipped` (nothing to translate),
`pending` (`cache_only`), `reflow_failed`, `requests`, `retries`,
`anchors_changed`, `errors` (the first few messages) and `ms`.

### What is translated

Never translated, kept byte for byte: front matter (`---`/`+++`), fenced code
(``` and `~~~`), indented code, `$$` math blocks, HTML blocks and comments,
reference definitions, thematic breaks, setext underlines, table delimiter
rows, blank lines. Translated, each as a unit of its own: headings,
paragraphs, list items, block quotes, footnote definitions and **every table
cell** (the pipes stay). A hard line break (two trailing spaces or a
backslash) ends a unit, since the reflow would move it.

Inside a unit, inline code, link and image targets, autolinks, bare URLs,
inline HTML, entities, footnote references, `{#id}` attribute lists and the
`keep` words are **masked**: replaced by a placeholder, translated around, put
back afterwards. The text of a link stays translatable. Collapsed and shortcut
references (`[text][]`, `[label]` with a definition) are masked whole, since
their text is their key.

The placeholder is plain ASCII, `{n}`. This is measured, not a taste: in the
spike (2026-10-06) the Unicode pair U+27E6/U+27E7 came back as `?1?` for 25 % of
the units on the Windows curl path. It reproduces on a current machine too: with
the text as one argv element, `curl` hands a loopback server `?1?` for the
Unicode pair and `{1}` for the ASCII one (and even `ü` arrives as the single
byte `%FC`, not UTF-8, which is why the argv-based `custom`/`shell` engines are
the weak spot on Windows, while `google` and `deepl` send stdin).
`TESTS/translate_markdown_curl_spec.lua` runs the whole pipeline through a real
curl and a loopback server to keep it that way.

### Never broken: validation, retry, fall back

Each answer is checked: every placeholder present exactly once (the halves of a
link in the right order; fullwidth braces and `{ 1 }` are put right first),
not empty, a plausible length compared with the source. A unit that fails is
retried once (a batch with an unattributable line count is retried unit by
unit); if it fails again, **the original unit stays**: the preview shows German
for that paragraph and is never empty or half. Three failed requests in a row
stop the run (a down engine or a 429 is not hammered); the document then comes
back as it was, with `info.failed` and `info.errors` telling why. A failed unit
is **never cached**: the spike saw 27 requests instead of 1 for a one-paragraph
change because failures had been remembered as answers.

### Reflow: the same number of lines

A unit's translation is wrapped onto exactly the line count of its source,
distributing the words in proportion to the width of the original lines. Soft
line breaks are invisible in the rendered HTML. **No break lands in front of a
word that Markdown reads as a block start**: `-`, `*`, `+`, `1.`, `#`, `>`,
`|`, a fence, a thematic break or setext underline, `<`, `$$`, `:::`, a
definition `[x]:`. The spike lost a sentence to a dash at the start of a line,
which became a list item (98 blocks turned into 102); the rule has a golden
test. The same check guards the first line of a paragraph, an item or a quote.
If no safe break exists, the unit stays original (`info.reflow_failed`).

Fewer words than lines (a short translation, or CJK without spaces): the words
take one line each and the surplus lines are padded: blank lines at the end of
a plain paragraph, a zero-width space (U+200B) line inside an item, a quote or
mid-paragraph, where a blank line would split the block or loosen the list.

### Anchors

Translating the heading `Installation` to `Setup` changes its slug, while the
masked target `(#installation)` does not: 16 of 18 table-of-contents links
broke in the spike. The i-th original heading's slug is mapped to the i-th
translated heading's slug and every `](#old)` target (and a `[x]: #old`
definition) is rewritten. The slug function is the one the mdview client
resolves anchors with (lower case; letters, digits, white space and hyphens
only; the first heading with a slug wins). A target that matches no heading
stays as it is. Blocks that contain such a link are held back from `on_unit`
until the headings are known (headings are sent first).

### Cache

Key = hash of (engine, model, target, source, masked unit text); the value is
the validated translation with the placeholders still in it, so two units that
differ only in a link target share an entry. Memory is bounded (20 000 units);
an optional disk file (`stdpath("cache")/language.nvim/translate_markdown.json`,
through `lib.nvim.cache.disk`) is read lazily, written debounced after a change
and at exit, merged with what another Neovim wrote, and cut to
`translate.markdown.cache_max_kb` (oldest first). A damaged file or an entry of
the wrong shape is ignored, and a cached value goes through the same
placeholder check as a fresh answer. `require("language").translate_markdown_clear_cache({ disk = true })`
forgets everything. **Privacy:** the disk cache holds your translated text in
plain JSON; switch it off with `translate.markdown.disk_cache = false`.

### Requests

Units are deduplicated, then packed (headings first) into requests of at most
`max_chars` bytes and `max_units` units, `concurrency` of them in flight.
The request goes through the existing provider registry and its chunk wrapper,
so every engine's own limits apply on top. DeepL's `tag_handling` is **not**
used: the `{n}` placeholders need no tags, and the provider signature stays
unchanged.

Measured on a laptop with a fake engine (no network): a 1 460-line document of
619 units took 23 ms cold, 19 ms with every unit cached and 17 ms for a
one-paragraph change (one request, one unit). Real engines add their latency:
the spike measured 8-18 s for a cold 105-unit document with four parallel
single-unit requests and 48 s serially, which is why units are batched and the
cold start is meant to be shown progressively (`on_unit`) over the original.

### Config

```lua
translate = {
  markdown = {
    concurrency = 3,     -- requests in flight
    max_chars = 3000,    -- masked bytes per request
    disk_cache = true,   -- persist the unit cache in stdpath("cache")
    cache_max_kb = 2048, -- size cap of that file
    keep = {},           -- words that are never translated, e.g. { "Neovim" }
  },
}
```

- **Modules:** `translate/markdown/{init,segment,mask,reflow,anchors,cache}.lua`
- **Specs:** `translate_markdown_*_spec.lua` (golden documents in
  `TESTS/fixtures/markdown/`, a property test of the reflow, a fuzz run of the
  whole pipeline, the real-curl placeholder spec)

Limits worth knowing: the Markdown parser is line-based and errs on the side
of skipping (code mistaken for prose is caught by the placeholder and length
checks; prose mistaken for code stays German); there is no inline parse for
emphasis, so `*`/`_` stay in the text for the engine to keep; math in single
`$...$` is not recognised.

## Custom translate provider

`translate.custom = { cmd = function(lines, target) return {"trans", "-b", ...} end, parse = function(out) return vim.split(out, "\n") end }` —
an escape hatch mirroring `spell.providers.custom`. `cmd` receives one block
of lines (see [chunking](#large-inputs-chunking)); a trailing empty entry in
what `parse` returns is dropped when the block has gained a line.

- **Module:** `translate/providers/custom.lua`
- **Config:** `opts.translate.custom` (`cmd`, `parse`, optional `max_bytes`)

## Indent-preserving round trip

Each line's leading whitespace is captured before translating the dedented
text, then re-prepended to the matching output line — closes a gap where
providers (notably Google's `gtx`) normalize away leading whitespace,
which would otherwise drop indented list items to column 0. Skipped when
the provider merges or splits lines (line counts no longer match 1:1).

- **Module:** `translate/indent.lua`

## Column-precise selection

Char-wise motions (e.g. `<lhs>iw`) and char-wise visual selections
translate the exact byte span (multibyte-safe via `getregionpos`) and
replace it in place, rather than falling back to whole-line replacement.
Line-wise and block-wise selections still use the line range.

- **Module:** `translate/init.lua` (`run_region`)

## Motion/visual translate maps

Opt-in operator (`{lhs}{motion}` translates the moved-over text object,
e.g. `gtrip`) and visual-mode map (translates the current selection).
Target is `translate.default_target` if set, otherwise a quick picker.
Both always replace in place regardless of the popup default used by
`:Translate`.

- **Module:** `translate/motion.lua`
- **Config:** `opts.translate.keymaps.operator` (default `false`), `opts.translate.keymaps.visual` (default `false`), `opts.translate.keymaps.to` (default `{}`), `opts.translate.default_target`

### Choosing the target from the keymap (2026-08-24)

With `default_target` set the operator always used it and never asked;
without one it always asked. Neither is "translate this bit into Spanish,
just now" — the flag/option audit's entry.

`translate.keymaps.to` is one key per language:

```lua
translate = { keymaps = { to = { EN = "<leader>tE", DE = "<leader>tD" } } },
```

Each key works in normal (operator) and visual mode and forces that target
for a **single** run — the force is consumed by the next `choose_target`, so
it never leaks into the following unforced one.

A count could not carry the language: on an operator the count belongs to the
motion (`3{lhs}w` is three words), which is the whole point of having an
operator. Hence a key per language, which is what the audit suggested as well.
Unset by default.

- **Module:** `translate/motion.lua` (`force_target`, `choose_target`)

## Interactive translate window

`:Translate!` opens a two-pane float — editable input, live output —
that translates as you type. `<C-l>` retargets the language, `<C-y>`
copies the result, `<C-h>` opens the history picker, `<C-r>` promotes the
current translation to the input and picks a new target (round-trip/
reverse translation). `q`/`<Esc>`/`<C-c>` closes it. Prefilled from a
range/selection when given one (`:'<,'>Translate! DE`).

- **Module:** `translate/window.lua`
- **Usercmds:** `:Translate!` — [user commands](../BINDINGS.md#user-commands)

## Query history

Records `:Translate` results and window copies in a newest-first ring,
with optional JSON persistence across restarts. Recall via the window's
`<C-h>` picker or `require("language").translate_history()`.

- **Module:** `translate/history.lua`

## Multi-file translation

`:Translate <lang> cwd` (or `path=<dir>`) gathers translatable files under
the target, multi-selects via the `ui.kit` chooser (`<Tab>`), and
translates each — writing a language-suffixed sibling file by default
(`name.DE.ext`), overwriting in place with `--files=replace` (confirmed),
or opening scratch buffers with `--files=buffers`.
`:TranslateReplace <lang> cwd` forces file-mode `replace`.

- **Module:** `translate/files.lua`
- **Config:** `opts.translate.files.output`
