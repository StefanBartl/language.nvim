# language.nvim

Sprachwerkzeuge für Neovim in **einem** Plugin: **Rechtschreibung & Grammatik**
prüfen und direkt abarbeiten sowie **Text übersetzen** — mit einheitlichem
Scope-Modell (Buffer / Sichtbereich / cwd / Pfad / Auswahl) und durchgehend
asynchron.

Gebaut auf [lib.nvim](https://github.com/StefanBartl/lib.nvim) als bewusst
geteilte Abhängigkeit. Für Übersetzung wird **kein** externes Neovim-Plugin
benötigt — nur `curl` (Google-Engine, keyless, funktioniert ohne Konfiguration).

> Status: **Beta** — Kern (Spell-Session + Google-Übersetzung) funktioniert;
> Multi-Provider-Panel, weitere Engines und Grammatik-LSP folgen (siehe Roadmap).

---

## Features

- **`:Spellcheck`** — Rechtschreib-/Grammatik-Session über nativen `vim.spell`,
  Ausgabe als Diagnostics + [Trouble](https://github.com/folke/trouble.nvim)
  oder Quickfix-Fallback. `z=`-Fix mit automatischem Weitersprung, Session-State
  pro Buffer, spelllang-Wiederherstellung.
- **`:Translate`** — Range/Auswahl übersetzen; Default ersetzt den Text in place
  (`--output=replace`), alternativ `float`/`notify`/`clipboard`/`insert`.
  `--nocode` überspringt Fenced- und Inline-Code.
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
    engine = "google",          -- keyless Default
    default_output = "replace",
    timeout_ms = 8000,
    deepl = { api_key = nil },   -- oder $DEEPL_API_KEY (deepl-Engine folgt)
  },
})
```

## Health

```vim
:checkhealth language
```

## Lizenz

MIT
