// language.nvim — persistent cspell sidecar.
//
// Keeps cspell-lib loaded so buffer spell-checks are ~instant (no per-scan Node
// cold start). Speaks newline-delimited JSON over stdin/stdout:
//
//   in : {"id":N,"text":"…","path":"file.md","suggestions":false}
//   out: {"id":N,"issues":[{"lnum":1,"col":6,"end_col":14,"word":"…","suggestions":[]}]}
//   ready line on startup: {"ready":true}
//   errors: {"id":N,"error":"…"} or {"error":"init failed: …"}
//
// argv[2] = absolute path to cspell-lib's ESM entry (dist/index.js). The process
// must be spawned with cwd inside the cspell install so bundled dictionaries
// resolve. Env CSPELL_LANG sets the language (default "en").

"use strict";

const readline = require("readline");
const { pathToFileURL } = require("url");

const LIB_ENTRY = process.argv[2];

const EXT_LANG = {
  md: "markdown", markdown: "markdown", mdx: "markdown",
  txt: "plaintext", text: "plaintext",
  rst: "restructuredtext", adoc: "asciidoc", asciidoc: "asciidoc", tex: "latex",
  lua: "lua", js: "javascript", jsx: "javascript", ts: "typescript", tsx: "typescriptreact",
  py: "python", go: "go", rs: "rust", c: "c", h: "c", cpp: "cpp",
  java: "java", rb: "ruby", sh: "shellscript", html: "html", css: "css",
  json: "json", yaml: "yaml", yml: "yaml", toml: "toml",
};

function langId(path) {
  const m = /\.([^.\\/]+)$/.exec(path || "");
  return (m && EXT_LANG[m[1].toLowerCase()]) || "plaintext";
}

// cspell issue offset is a JS string (UTF-16) offset; convert to 1-based line
// and 1-based *byte* column (what Neovim uses).
function posFromOffset(text, offset) {
  let row = 0;
  let lineStart = 0;
  for (let i = 0; i < offset && i < text.length; i++) {
    if (text.charCodeAt(i) === 10) {
      row += 1;
      lineStart = i + 1;
    }
  }
  const colBytes = Buffer.byteLength(text.slice(lineStart, offset), "utf8");
  return [row + 1, colBytes + 1];
}

let lib = null;
let baseSettings = null;

async function init() {
  lib = await import(pathToFileURL(LIB_ENTRY).href);
  const def = await lib.getDefaultSettings(true);
  baseSettings = lib.mergeSettings(def, { language: process.env.CSPELL_LANG || "en" });
}

async function handle(req) {
  const uri = req.path ? pathToFileURL(req.path).href : "file:///buffer.txt";
  const res = await lib.spellCheckDocument(
    { uri, text: req.text || "", languageId: langId(req.path) },
    { generateSuggestions: !!req.suggestions },
    baseSettings
  );
  const issues = [];
  for (const it of res.issues || []) {
    const [lnum, col] = posFromOffset(req.text || "", it.offset);
    issues.push({
      lnum,
      col,
      end_col: col + Buffer.byteLength(it.text, "utf8"),
      word: it.text,
      suggestions: (it.suggestions || []).map((s) => (typeof s === "string" ? s : s.word)),
    });
  }
  return { id: req.id, issues };
}

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

init()
  .then(() => {
    send({ ready: true });
    const rl = readline.createInterface({ input: process.stdin });
    rl.on("line", (line) => {
      if (!line.trim()) return;
      let req;
      try {
        req = JSON.parse(line);
      } catch (_e) {
        return;
      }
      handle(req)
        .then(send)
        .catch((e) => send({ id: req.id, error: String((e && e.message) || e) }));
    });
    // Do not force-exit on close: let pending checks drain; Node exits on its
    // own once stdin is closed and the event loop empties.
  })
  .catch((e) => {
    send({ error: "init failed: " + String((e && e.message) || e) });
    process.exit(1);
  });
