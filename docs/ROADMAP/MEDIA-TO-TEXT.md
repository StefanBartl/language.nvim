# Media to text — a concept

> **Status: concept, nothing implemented.** This document decides *where* each
> piece belongs before any of it is built, because the wrong home here is
> expensive to undo: it would put an ffmpeg pipeline inside a plugin whose every
> entry point currently takes a `bufnr`.

The request behind it: transcribe videos, extract text from images, translate
and summarise the result, and get a dashboard listing every media file under a
directory with an action picker on top. Plus the honest question — does any of
this belong in `language.nvim`?

## Table of contents

- [1. What already exists](#1-what-already-exists)
- [2. The actual gap](#2-the-actual-gap)
- [3. Where does it belong?](#3-where-does-it-belong)
- [4. The new plugin: `media.nvim`](#4-the-new-plugin-medianvim)
- [5. What `language.nvim` actually gets](#5-what-languagenvim-actually-gets)
- [6. The dashboard](#6-the-dashboard)
- [7. Phases](#7-phases)
- [8. Risks and known traps](#8-risks-and-known-traps)
- [9. Open decisions](#9-open-decisions)

---

## 1. What already exists

Two thirds of "extract text from media" is already shipped and in daily use.
Anything built now has to delegate to it rather than duplicate it.

| Capability | Where | Entry point |
|---|---|---|
| Image → text (OCR, tesseract) | `images.nvim` | `require("images.ocr").run(path, opts, cb)`, `:Image ocr` |
| OCR result → buffer lines | `images.nvim` | `require("images.ocr").to_lines(text)` |
| PDF → text (7 backends, incl. tesseract OCR fallback) | `pdfport.nvim` | `require("pdfport").extract(path, opts)`, `:PdfPort text` |
| PDF page → PNG | `pdfport.nvim` | `render_page()` |
| Backend registry + fallback chain + cross-session cache | `pdfport.nvim` | `core/registry.lua`, `core/resolver.lua`, `util/cache.lua` |
| Media file discovery under `cfile`/`cwd`/`path` | `images.nvim` | `require("images.browse").roots(scope, arg)`, `.walk(root, exclude, exts)` |
| Text → translation (Google/DeepL/shell/custom) | `language.nvim` | `require("language.translate").run(lang, opts)` |
| Spell/grammar over any buffer | `language.nvim` | `:Spellcheck` |
| Multi-select picker, progress, confirm, context menu, deps popup | `lib.nvim` | `ui.kit.picker`, `progress`, `contextmenu`, `deps` |
| A working consumer of OCR sidecars | nvim config | `bindings/usrcmds/case/ocr.lua` → `shot.png.ocr.md` |

Two conventions already proved themselves in that last row and should be kept:

- **Sidecar next to the source, as Markdown**: `shot.png` → `shot.png.ocr.md`.
  The suffix is appended to the *full* name, not swapped for the extension, so
  `a.png` and `a.jpg` do not collide and a grep hit explains itself. Every
  `*.md`-walking tool (`:Case grep`) picked it up with zero changes.
- **Staleness by mtime, not by existence.** A sidecar older than its source is
  regenerated — otherwise a redacted screenshot keeps the text that was blacked
  out.

## 2. The actual gap

**Audio and video → text.** Nothing in the ecosystem touches it. No ffmpeg, no
whisper, no timestamped data model, nowhere. That is the one genuinely new
capability in the request; everything else is aggregation.

Two secondary gaps fall out of it:

- **No timestamp-aware text model.** OCR and PDF extraction produce a flat
  string. A transcript without segment times cannot produce SRT/VTT and cannot
  jump back into the video. This has to exist from the first commit, not be
  retrofitted.
- **No kind-agnostic verb.** There is `:Image ocr` and `:PdfPort text` and
  (soon) transcription, but nothing that says "get the text out of *this file*,
  whatever it is".

## 3. Where does it belong?

### Not in `language.nvim`

`language.nvim`'s domain is *language inside text that is already in a buffer*.
Every public entry point proves it: `run_region(target, {bufnr, sr, sc, er, ec})`,
`run(lang, {scope})`, `spellcheck(lang, scope)`. The shared `language.scope`
module exists precisely to stop each domain re-deriving a buffer and a range.

Media extraction brings none of that and all of this instead: external binaries
(ffmpeg, whisper), multi-gigabyte model downloads, jobs measured in minutes
rather than a network round trip, intermediate WAV files, a cross-session cache
keyed by content mtime, and a segment/timestamp data model. Not one line of it
would be shared with spell or translate.

There is also a precedent, written down deliberately when OCR was built —
`images.nvim/lua/images/ocr.lua` opens with a section titled *"Why this is not
an interface to `language.nvim`"*. Its conclusion: put the recognised text in a
buffer, which is what you want anyway in order to read and correct it, and
`:Translate` on a Visual selection already *is* the crossing, through keys that
already exist. That reasoning holds identically for a transcript.

**So: yes, a too-far stretch — for the extraction half.** Not for the
consumption half, which is section 5 and is real work.

### Not in `pdfport.nvim` either

Tempting, because the architecture is exactly right (registry, resolver,
fallback chain, cache, batch, integrations) and it already carries a tesseract
backend. But its name, its types (`PdfPort.Backend`, `PdfPort.ExtractOpts`), its
command grammar and its producer half are all PDF. An `mp4` in there is a lie
in every identifier. **Copy the shape, not the repository.**

### A new plugin: `media.nvim`

One domain: *files that contain text but are not text*. Two halves.

1. **Transcription** — its own core, because there is nowhere else for it.
2. **The hub** — discovery, dashboard, and one kind-agnostic verb that delegates
   image → `images.ocr`, PDF → `pdfport.extract`, audio/video → its own core.

The hub is why the plugin is called `media` rather than `transcribe`: a
dashboard listing images, PDFs and videos side by side has to be allowed to know
all three, and none of the three should be forced to depend on the other two.
`media.nvim` is the one place that may `pcall` its way to all of them. Every
dependency stays soft — a missing `images.nvim` removes OCR rows from the
dashboard, it does not break it.

**Alternative considered:** the hub inside `open.nvim`, whose `:Open viewer`
already does "collect targets in a buffer/dir/project, then hand you a picker".
Structurally close. Rejected because `open.nvim`'s verb is *open* — route one
target to the right application — while the hub's verb is *extract*, and the
action list is about tools that must be installed rather than about
destinations.

## 4. The new plugin: `media.nvim`

Modelled directly on `pdfport.nvim`, which is the proven shape in this ecosystem.

```
lua/media/
  init.lua                 -- public façade (the only thing other plugins call)
  @types/init.lua
  config/{init,DEFAULTS,@types}.lua
  core/
    registry.lua           -- engine registry: id / available() / transcribe()
    resolver.lua           -- configured engine, then fallback chain
    dispatcher.lua         -- probe -> normalize -> transcribe -> deliver, cancellable
    probe.lua              -- ffprobe: duration, stream kinds, "has an audio track at all"
    normalize.lua          -- ffmpeg: any A/V -> 16 kHz mono WAV (whisper.cpp requires it)
    segments.lua           -- the timestamped model + txt/srt/vtt/md serialisers
    cache.lua              -- key: path + engine + model + lang + task + mtime
  engines/
    whisper_cpp.lua        -- local, GGML models, best Windows story
    faster_whisper.lua     -- local, CTranslate2, fastest per watt
    openai_whisper.lua     -- local, reference Python CLI, slowest
    openai_api.lua         -- remote, API key, 25 MB request cap -> chunking
    custom.lua             -- cmd/parse escape hatch (mirrors language.translate.custom)
  output/
    init.lua               -- buffer | sidecar | srt | vtt | clipboard | notify
    sidecar.lua            -- <file>.transcript.md, the case/ocr.lua convention
  hub/
    kinds.lua              -- classify a path: image | pdf | audio | video | other
    scan.lua               -- discovery under cfile | cwd | path=<dir>
    actions.lua            -- which actions this kind supports, given what is installed
    dashboard.lua          -- the picker/panel itself
  integrations/
    menu.lua               -- nvzone/menu items via lib.nvim.contextmenu
    picker.lua             -- snacks/telescope, if present
  bindings/{usrcmds,keymaps,autocmds}.lua
  health.lua               -- per engine, plus ffmpeg, plus "is the model file there"
docs/install.json          -- ffmpeg, whisper-cli, whisper-ctranslate2, model hints
```

### The data model

This is the part that must be right on day one.

```lua
---@class Media.Segment
---@field s number        # start, seconds
---@field e number        # end, seconds
---@field text string

---@class Media.Transcript
---@field engine string
---@field model string|nil
---@field lang string|nil     # detected, or forced by the caller
---@field duration number|nil
---@field segments Media.Segment[]
---@field text string         # segments joined; the flat view for OCR-shaped consumers
```

Segments are mandatory, not optional. Without them there is no SRT, no VTT and
no "jump to that point in the video" later. Every candidate engine can produce
them: whisper.cpp writes JSON (`-oj`), the faster-whisper CLI takes
`--output_format json`, the OpenAI API takes `response_format=verbose_json`.
An engine that cannot is allowed to return one segment spanning the whole file
— but the *shape* stays uniform.

### The engine interface

Deliberately the same three fields `pdfport.core.registry` asserts on:

```lua
---@class Media.Engine
---@field id string
---@field name string
---@field capabilities Media.EngineCapabilities   # { local_: boolean, remote: boolean, segments: boolean, translate_to_en: boolean, diarization: boolean }
---@field available fun(): boolean
---@field transcribe fun(wav_path: string, opts: Media.InternalOpts, cb: fun(t: Media.Transcript|nil, err: string|nil)): Media.Job
```

Asynchronous and cancellable throughout, with `lib.nvim.progress` reporting.
Non-negotiable: an hour of audio is minutes of work, and a modal editor that
blocks for minutes is broken.

### Command grammar

Via `lib.nvim.bindings.usercmd.composer`, exactly as `:PdfPort` does — one verb,
subcommands underneath:

```
:Media                                        -- dashboard, scope cwd
:Media dashboard [cfile|cwd|path=<dir>]
:Media text [path]                            -- kind-agnostic; delegates by kind
:Media transcribe [path] [--engine=] [--lang=] [--task=transcribe|translate]
                         [--out=buffer|sidecar|srt|vtt|clipboard]
:Media engines                                -- registered engines + live availability
:Media cancel
```

`:Media text` is the point of the whole plugin: one key, any media file, text in
a buffer. Image → `images.ocr.run`. PDF → `pdfport.extract`. Audio/video → its
own dispatcher. Anything else → a notify saying so.

### Configuration sketch

```lua
require("media").setup({
  engine = "whisper_cpp",                       -- like translate.engine
  fallback = { "faster_whisper", "openai_api" },-- like translate.fallback
  lang = nil,                                   -- nil = let the engine detect
  task = "transcribe",                          -- "transcribe" | "translate" (to English only)
  output = "buffer",                            -- default delivery
  cache = true,                                 -- cross-session, mtime-invalidated
  timeout_ms = 0,                               -- 0 = none; transcription is not a round trip
  ffmpeg = { bin = nil },                       -- nil = PATH
  whisper_cpp = { bin = nil, model = nil },     -- model = absolute path to a .bin
  faster_whisper = { bin = nil, model = "medium", compute_type = "auto" },
  openai_api = { api_key = nil, model = "whisper-1" },  -- or env
  hub = {
    exclude = { ".git", "node_modules", ".venv", "dist", "build", "target" },
    max_entries = 20000,
    kinds = { image = true, pdf = true, audio = true, video = true },
  },
  deps_popup = true,                            -- lib.nvim.deps, like every sibling plugin
})
```

## 5. What `language.nvim` actually gets

The extraction does not belong here. The *consumption* does, and it is not
cosmetic — one of these three is the difference between "subtitle translation
works" and "subtitle translation is broken".

### 5.1 A subtitle-aware filter (the real one)

`language.translate.filter.translatable_ranges()` already answers exactly this
class of question for code: *which lines of this text are prose?* Fenced blocks
and inline backticks are excluded so `--nocode` does not translate them.

An SRT/VTT file poses the identical question with a different answer. Given:

```
2
00:00:04,120 --> 00:00:07,300
Und dann ist der Prozess abgestürzt.
```

only the third line may be sent to DeepL. Translate the timestamp line and the
file stops being a subtitle file. Translate the sequence number and it is
garbage. This is *precisely* `language.nvim`'s domain — deciding which parts of
a text are language — and it is where the media work touches this plugin
legitimately.

Shape: a sibling to the existing filter, auto-selected by filetype/extension
rather than by a flag, since unlike `--nocode` there is no sensible "translate
the timestamps too" mode.

```lua
---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@return { s: integer, e: integer }[]
function M.subtitle_ranges(bufnr, start_line, end_line) end
```

### 5.2 `srt` / `vtt` in `translate.files.extensions`

A one-line default change, but it is what makes `:Translate DE path=<dir>` pick
up subtitle files at all. Depends on 5.1 — without the filter this would
actively produce broken files, so the two ship together or not at all.

### 5.3 Optional: a source-agnostic entry point

Every current entry point is buffer-bound. A transcript that is not in a buffer
yet has to be given one first. A small addition would let another plugin hand
text straight over:

```lua
---@param lines string[]
---@param target string
---@param opts table|nil   -- { output?, on_done? }
function M.translate_lines(lines, target, opts) end
```

**Explicitly optional.** The existing route — scratch buffer, then `:Translate`
on a selection — already works, is the documented recommendation in
`images/ocr.lua`, and leaves the user able to correct the text before spending a
network call on it. Build 5.3 only if the buffer hop turns out to be friction in
practice.

### What `language.nvim` does *not* get

No ffmpeg. No whisper. No summarisation — that needs an LLM backend, and this
plugin has none; `pdfport.nvim` already carries the ollama/claude pattern for
exactly that, and section 7's phase 4 reuses it in `media.nvim`.

### The clean seam, in one sentence

Whisper's own `--task translate` produces **English only**. Every other target
language — DE, FR, ZH, JA — has to go through `language.nvim`. So the division
of labour is not an arbitrary preference: transcription hands over a text in its
original language, and translating it is the other plugin's job by construction.

## 6. The dashboard

`:Media dashboard [cfile|cwd|path=<dir>]` — the scope vocabulary is deliberately
the one both `images.browse.roots()` and `language.scope` already use, so the
same three words mean the same three things across every plugin here.

**Discovery** reuses the shape of `images.browse.walk(root, exclude, exts)` —
iterative `fs_scandir` with an exclusion set and an entry cap, no recursion into
`node_modules`. Extensions come from `hub.kinds`.

**A row** carries what the decision needs and nothing else:

```
  video   talks/standup.mp4          14:32     — transcript: missing
  video   talks/retro.mp4            41:07     ✓ transcript (3 days old)
  image   assets/error.png           1920×1080  ✓ ocr
  pdf     docs/spec.pdf              24 pages   — text: missing
  audio   notes/2026-08-11.m4a       06:44     — transcript: stale
```

Status is computed the way `case/ocr.is_stale` does it: compare the sidecar's
mtime against the source's. "Stale" is a distinct state from "missing", because
it is the one that silently produces wrong answers.

**Actions** are offered per kind *and* per availability. A row whose tool is not
installed still shows its action, greyed, with the reason and the fix
(`:Lib deps install media.nvim`) rather than silently hiding the feature — the
same principle `images.ocr` applies when it reports which tesseract languages
are actually present.

| Kind | Actions |
|---|---|
| image | OCR → buffer / sidecar · show · info |
| pdf | extract text · open (pdfport modes) · page → PNG |
| audio | transcribe · transcribe + translate · SRT/VTT |
| video | transcribe · transcribe + translate · SRT/VTT · extract audio |
| any | translate the extracted text (`language.nvim`) · spellcheck it · summarise (phase 4) |

**Multi-select** with `<Tab>`, then the action runs over the batch sequentially
with one progress handle — the flow `language.translate.files` already
established for multi-file translation, and the reason the UI kit's multi-select
picker exists.

**UI**: `lib.nvim.ui.kit.picker` (multi-select + preview) by default, with
`snacks.picker` used when installed — the same soft-detection `images.browse`
does. Plus `integrations/menu.lua` contributing entries to the RightMouse menu
via `lib.nvim.contextmenu`, so a media file under the cursor in a Neo-tree gets
the same actions without the dashboard.

## 7. Phases

Each phase is independently useful; none is a prerequisite for the value of the
one before it.

**Phase 0 — transcription that works.** `media.nvim` skeleton, config, one
engine (`whisper_cpp` or `faster_whisper`), ffprobe + ffmpeg normalisation,
`:Media transcribe`, buffer and sidecar output, cache, `:checkhealth media`,
`docs/install.json`. Done when a `.mp4` becomes a `.mp4.transcript.md`.

**Phase 1 — the model pays off.** Segment serialisers (SRT/VTT), remaining
engines behind the fallback chain, `:Media text` with kind dispatch to
`images.ocr` and `pdfport.extract`.

**Phase 2 — the dashboard.** `hub/`, scope handling, status column, multi-select
batch, context-menu integration.

**Phase 3 — `language.nvim`.** `subtitle_ranges` filter (5.1) plus `srt`/`vtt`
in `translate.files.extensions` (5.2). The only phase that touches this
repository. Optionally 5.3.

**Phase 4 — the long tail.** Summarisation via ollama/claude (copy
`pdfport/backends/{ollama,claude}.lua`), jump-from-transcript-to-timestamp,
`:Case transcribe` as a sibling of `:Case ocr`, speaker diarization if an engine
offers it.

## 8. Risks and known traps

- **Runtime.** Transcription is minutes, not seconds. Cache, progress and cancel
  are phase-0 requirements, not polish. `timeout_ms` defaults to *no* timeout;
  the translate layer's 8 s default would be actively wrong here.
- **Model downloads.** Whisper models run to gigabytes. Never fetch one
  automatically — health reports the missing file, and installation is an
  explicit, confirmed action.
- **Windows argv.** `whisper-ctranslate2` is a Python console entry point, i.e.
  a `.exe` shim or a `.cmd` depending on the install, and libuv cannot spawn the
  latter directly. This ecosystem has already solved it twice —
  `language/util/job/init.lua`'s `resolve_argv` and `lib.nvim.system` — so reuse
  it rather than rediscovering it.
- **ffmpeg is not optional for whisper.cpp.** It only accepts 16 kHz mono WAV.
  `normalize.lua` is a hard dependency of that engine, not a convenience.
- **The OpenAI API caps a request at 25 MB**, which an hour of audio exceeds.
  Either chunk on silence boundaries or declare the remote engine as
  short-clips-only; do not let it fail at minute 40.
- **Sidecars and redaction.** The mtime rule from `case/ocr.lua` exists because
  `:Image redact` rewrites a file in place. A transcript sidecar has the same
  hazard the moment anything edits the source media.
- **Do not feed transcripts into TF-IDF corpora.** `case/similar.lua` deliberately
  excludes OCR sidecars: recognition errors are by construction the rarest terms
  in a corpus, so TF-IDF weights every mistake at maximum. Machine transcripts
  carry exactly the same defect.

## 9. Open decisions

1. **Plugin name.** `media.nvim` (covers hub + transcription) versus
   `transcribe.nvim` (narrower, but then the dashboard has no home).
   Recommendation: `media.nvim`.
2. **Default engine.** `whisper_cpp` (best Windows story, no Python) versus
   `faster_whisper` (fastest, but a Python toolchain). Recommendation:
   `whisper_cpp` as default with `faster_whisper` first in the fallback chain.
3. **Sidecar format.** `.transcript.md` only, or `.md` + a sibling `.srt`?
   Recommendation: `.transcript.md` by default, `.srt`/`.vtt` on request —
   Markdown is what greps and what `:Translate` already handles.
4. **Does the hub also list Office files** (`.docx`, `.pptx`), which `open.nvim`
   already routes and `pdfport` can convert? Out of scope for phase 2; revisit
   once `:Media text` exists.
5. **Phase 3 timing.** The subtitle filter is small and self-contained enough to
   land in `language.nvim` before `media.nvim` produces its first SRT — it makes
   hand-written and downloaded subtitle files translatable on its own.
