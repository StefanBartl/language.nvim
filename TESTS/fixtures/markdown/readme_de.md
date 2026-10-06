---
title: Beispiel-Dokument
lang: de
---

# Einleitung

Dieses Dokument prueft die Uebersetzung. Siehe [Installation](#installation) und
die [Verwendung](#verwendung), ausserdem [Gibt es nicht](#nicht-vorhanden) sowie
die Seite <https://example.org/docs> und `inline code` im Text.

## Inhalt

- [Einleitung](#einleitung)
- [Installation](#installation)
  - Zuerst das Paket holen und danach alles pruefen
  - Dann den Server starten, siehe [Doku][doku]
- [Verwendung](#verwendung)

## Installation

Ein hart umbrochener Absatz, der ueber mehrere Zeilen geht und in der
Uebersetzung auf genau dieselbe Zeilenzahl gebracht werden muss, damit der
Vorschau-Sync stimmt. Ein Gedankenstrich - mitten im Satz - darf nie am
Zeilenanfang landen.

1. Erster Schritt mit `npm install` ausfuehren
2. Zweiter Schritt: die Konfiguration anpassen
   und danach neu starten
3. Dritter Schritt

```lua
-- Kommentar bleibt deutsch
local x = require("foo").bar({ name = "Beispiel" })
print("Hallo Welt {1} {2}")
```

> Ein Zitat ueber zwei Zeilen
> mit **fettem** Text und einem Link zu [Beispiel](https://example.org/a_(b)).

| Name | Beschreibung | Wert |
|------|:------------:|-----:|
| Alpha | Der erste Eintrag | `1` |
| Beta | Der zweite Eintrag mit \| Pipe | 2 |

<details>
<summary>Mehr anzeigen</summary>

Dieser Absatz steht nach einem HTML-Block und wird uebersetzt.

</details>

<!-- ein Kommentar
ueber zwei Zeilen -->

## Verwendung

Zeile mit hartem Umbruch am Ende  
und die Folgezeile danach. Eine Fussnote[^1] und ein Bild ![Alt Text](bild.png "Titel").

Setext Ueberschrift
===================

Noch ein Absatz mit https://example.org/lang und dem Namen Neovim darin.

    eingerueckter Code bleibt unberuehrt

---

[^1]: Die Fussnote erklaert etwas ausfuehrlicher.

[doku]: https://example.org/doku "Doku Titel"
[zurueck]: #einleitung
