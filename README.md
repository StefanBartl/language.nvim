# language.nvim

Sprachwerkzeuge für Neovim in **einem** Plugin: **Rechtschreibung & Grammatik**
prüfen und direkt abarbeiten sowie **Text übersetzen** — mit einheitlichem
Scope-Modell (Buffer / Sichtbereich / cwd / Pfad / Auswahl) und durchgehend
asynchron.

Gebaut auf [lib.nvim](https://github.com/StefanBartl/lib.nvim) als bewusst
geteilte Abhängigkeit. Für Übersetzung wird **kein** externes Neovim-Plugin
benötigt — nur `curl` (Google-Engine, keyless, funktioniert ohne Konfiguration).

> Status: **Beta** — Spell-Panel, Grammatik (LSP), Mehrfach-Provider und
> mehrere Übersetzungs-Engines funktionieren. Weitere Ideen: siehe
> [ROADMAP](docs/ROADMAP/ROADMAP.md).

---

## Features

- **`:Spellcheck`** — Rechtschreib-/Grammatik-Session über nativen `vim.spell`,
  Ausgabe als Diagnostics + [Trouble](https://github.com/folke/trouble.nvim)
  oder Quickfix-Fallback. `z=`-Fix mit automatischem Weitersprung, Session-State
  pro Buffer, spelllang-Wiederherstellung.
- **Grammatik & Provider** — Grammatik-Diagnostics von `harper_ls`/`ltex`
  erscheinen im selben Panel; optionale externe Spell-CLIs (`typos`, `cspell`,
  `codespell`) für cwd/path-Scans. Native Erkennung splittet CamelCase/snake_case und prüft nur
  Treesitter-`@spell`-Regionen (Kommentare/Strings/Prosa), keine Identifier-
  Fehlalarme.
- **`:Translate`** — Range/Auswahl übersetzen; Default ersetzt den Text in place
  (`--output=replace`), alternativ `float`/`notify`/`clipboard`/`insert`.
  `--nocode` überspringt Fenced- und Inline-Code. Engines: Google (keyless),
  DeepL, translate-shell, eigenes CLI — mit Fallback-Kette.
- **Scoping** — jede Aktion kennt einen Scope: `buffer` (Default), `visible`,
  `cwd`, `path=<datei|ordner>`, `selection`.
- **Asynchron & abbrechbar** — externe Prozesse (curl u. a.) laufen non-blocking
  über eine argv-basierte Job-Schicht (kein Shell-Interpolieren von Text) mit
  Timeout; ein neuer Aufruf bricht den laufenden ab.

## Anforderungen

- Neovim ≥ 0.9 (empfohlen 0.10+ für `vim.system`)
- [lib.nvim](https://github.com/StefanBartl/lib.nvim)
- `curl` (für Übersetzung)
- optional: `folke/trouble.nvim` (schönere Liste), externe Spell-CLIs/LSP (später)

## Installation (lazy.nvim)

```lua
{
  "StefanBartl/language.nvim",
  dependencies = { "StefanBartl/lib.nvim", "folke/trouble.nvim" }, -- trouble optional
  event = "VeryLazy",
  config = function()
    require("language").setup({})
  end,
}
```

## Verwendung

```vim
:Spellcheck                 " aktuellen Buffer prüfen (Session an/aus)
:Spellcheck en cwd          " alle offenen Textbuffer unter dem cwd
:Spellcheck de path=~/notes " Datei oder Ordner
:Spellcheck clear           " Session beenden, Diagnostics entfernen
:Spellcheck refresh         " neu scannen

:'<,'>Translate DE          " Auswahl nach Deutsch, ersetzt den Text
:Translate EN --nocode      " Range übersetzen, Code auslassen
:Translate FR --output=float " Übersetzung im Float statt Ersetzen
:Translate!                 " interaktives Fenster (live übersetzen beim Tippen)
:'<,'>Translate! DE         " Fenster mit Auswahl vorbefüllt, Ziel DE
```

Standard-Keymap: `<leader>ss` schaltet die Spell-Session im aktuellen Buffer um
(konfigurierbar). Während einer Session: `<leader>z=` korrigieren & weiter,
`<leader>z1` ersten Vorschlag übernehmen & weiter, `]s` nächster Fehler.

## Konfiguration

`setup()` merged über die Defaults (siehe `lua/language/config/DEFAULTS.lua`).
Auszug:

```lua
require("language").setup({
  spell = {
    default_scope = "buffer",
    live = false,                -- true = fortlaufende Inline-Diagnostics beim Tippen
    live_scope = "visible",      -- "visible" (nur Sichtbereich) | "buffer"
    scan_debounce_ms = 400,
    ui = { view = "picker", preview = true }, -- "quickfix" erzwingt den qf-Fallback

    -- Code-Features
    word_split = { enable = true, min_length = 4 }, -- CamelCase/snake_case in Subwörter
    regions = { treesitter_spell = true, skip_urls = true, skip_emails = true },
    programming_dict = false, -- opt-in: Fachwortliste (git, kubernetes, treesitter, …)

    -- Performance/Safety-Caps
    max_highlights = 100,   -- max. Inline-Diagnostics je Buffer (Panel zeigt trotzdem alle)
    max_file_lines = 20000, -- darüber: kein Live-Scan
    skip_readonly = true,

    keymaps = { panel = "<leader>ss", next = "]s", fix = "<leader>z=", fix1 = "<leader>z1" },
  },
  translate = {
    engine = "google",           -- "google" (keyless) | "deepl" | "shell" | "custom"
    fallback = { "google" },     -- Engine-Kette, wenn die gewählte nicht verfügbar ist
    default_output = "replace",  -- replace | float | notify | clipboard | insert
    default_target = nil,        -- feste Zielsprache für Motion/Visual-Maps; nil = Auswahl
    timeout_ms = 8000,
    deepl = { api_key = nil },   -- oder $DEEPL_API_KEY
    -- Opt-in Motion/Visual-Keymaps (Default aus, um Tasten nicht zu belegen):
    --   operator: <lhs>{motion} übersetzt das Textobjekt (z. B. gtrip)
    --   visual:   <lhs> übersetzt die Auswahl
    keymaps = { operator = false, visual = false },
    -- custom = { cmd = function(lines, target) return { "trans", "-b", ... } end,
    --           parse = function(out) return vim.split(out, "\n") end },
  },
})
```

## Health

```vim
:checkhealth language
```

## Lizenz

MIT
