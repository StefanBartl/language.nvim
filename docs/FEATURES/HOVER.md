# The word under the cursor, translated

An integration rather than a domain: [hover.nvim](https://github.com/StefanBartl/hover.nvim)
brings the float, the dismissal and the paging between several answers;
language.nvim brings the answer. Optional in both directions — without
hover.nvim installed, nothing here registers and nothing is missing.

```
:Hover show          over a word → its translation, in a float
:Translate DE cword  the same word, into a language you name, in the popup
```

## Why there are two of them, and they are not the same feature

`:Translate` has always taken a **scope** — a buffer, a visible range, a
selection, a directory. A single word is none of those, so the smallest useful
translation was the one shape this plugin could not do. Two things were
missing, and they are separable:

| | Who names the language | Where the answer lands | Costs a keypress |
| --- | --- | --- | --- |
| `:Translate DE cword` | you, per call | the existing popup | a typed command |
| `:Hover show` | `translate.default_target`, else `EN` | a hover.nvim float | whatever you already bound to `:Hover show` |

The `cword` scope is the part that had to exist either way — the hover uses the
same word-finding. What the hover adds on top is that the answer arrives
**where you are already looking**, alongside whatever else answers for that
position (documentation.nvim, insights.nvim); `<M-n>` steps between them.

## It is `on_request`, and that is not decoration

hover.nvim distinguishes contributions asked on the **automatic trigger** —
which fires after every keystroke followed by quiet — from those asked only
when someone types `:Hover show`. This one is the second kind, and it has to
be.

Every answer here is a request from your machine to a translation endpoint,
carrying the word your cursor is on. On the automatic trigger that would turn
reading a document into a stream of disclosures about what you are reading, one
word at a time. It is the same class of thing hover.nvim's own `links.fetch` is
off by default for, and it gets the same answer: only when asked, in as many
words.

`:checkhealth language` reports the flag rather than assuming it — an older
hover.nvim that does not know `on_request` would ignore it and ask on every
quiet moment, which is the one failure here nobody would notice from outside.

## It blocks the editor, and that is measured rather than hoped

`hover.registry.position_at` is synchronous: a contribution returns its content
or it does not answer. There is no placeholder to hand back and fill in later,
so the translation is waited for. Measured against the keyless Google endpoint
on 2026-09-03, one word, two runs each:

| Word | Run 1 | Run 2 |
| --- | --- | --- |
| hover | 929 ms | 452 ms |
| threshold | 514 ms | 663 ms |
| ambiguous | 448 ms | 465 ms |
| deliberately | 590 ms | 452 ms |
| measurement | 676 ms | 582 ms |

448–929 ms — the same order as sandbox.nvim's container lookups (286–754 ms),
and bearable only because nobody arrives here by accident. The wait is capped
at **2 s**, deliberately not `translate.timeout_ms` (8 s): that budget belongs
to `:Translate`, which runs in the background and can be superseded by the next
run, while this one holds the editor and cannot redraw.

## What that measurement actually found

**Every one of those requests came back HTTP 429** — Google's "your computer or
network may be sending automated queries" page — with and without a browser
user agent, while `api.datamuse.com` answered 200 from the same machine in the
same minute. So the numbers above are the cost of the round trip, not proof
that an answer arrives.

The keyless `translate_a/single` endpoint is one nobody promised. It is what
translate-shell and a dozen CLI tools use, it costs no key, and it can decline
at any time for any network. Two consequences are built in rather than left to
be discovered:

- **The failure is named.** `vim.json.decode` on an HTML page reports "invalid
  translation response" — true, and indistinguishable from a parse bug. The
  float says *the endpoint answered with a page, not a translation (rate limit
  or block)* instead, because those are different problems with different
  fixes.
- **The engine is replaceable.** `translate.engine = "deepl"` with a key, or
  `"shell"`, or a `custom` command — the hover asks whatever the provider chain
  resolves to, not Google specifically.

## The target language

`translate.default_target` when you set it, and **`EN`** otherwise.

The fallback lives in the hover rather than in `DEFAULTS` because `nil` already
means something there: *ask*, which is what the operator and visual maps do
when no target is fixed. A hover has nowhere to ask from — it is handed a
cursor position and must return content — so it needs an answer rather than a
question. English is the one a reader of an unfamiliar language most often
wants; setting `default_target` moves the hover and the maps together.

## Switching it off

```lua
require("language").setup({ hover = false })
```

Registers nothing at all, rather than registering something that declines.
`:checkhealth language` tells the four look-alike states apart: the switch is
off, hover.nvim is not installed, it is installed but too old to honour
`on_request`, or everything is wired and the endpoint is the problem.

## What no spec covers

`TESTS/hover_spec.lua` drives the word-finding, the target resolution, both
refusal paths and the registration shape — with the provider and hover.nvim
both stubbed, so it never touches the network. What it cannot be asked is
whether the endpoint answers, and on 2026-09-03 it did not.
