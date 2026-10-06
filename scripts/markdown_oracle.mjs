// scripts/markdown_oracle.mjs -- compare the pairs written by markdown_oracle.lua
// (`sN_<mode>_a.md` = source, `..._b.md` = translated) with the previewer's own renderer:
//
//   node scripts/markdown_oracle.mjs <pair_dir> [path/to/mdview.nvim]
//
// Per pair: the sequence of block elements with their start lines, the text of every
// <pre> block, and the multisets of link targets (anchors excluded), image sources and
// inline code. Exit code 1 when a pair differs. Differences that are not bugs: a bare
// URL directly followed by a backslash break (the autolink takes the backslash).

import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const dir = process.argv[2];
const mdview = path.resolve(process.argv[3] ?? path.join(import.meta.dirname, '..', '..', 'mdview.nvim'));
if (!dir) {
  console.error('usage: node markdown_oracle.mjs <pair_dir> [mdview.nvim dir]');
  process.exit(2);
}
const wasmDir = path.join(mdview, 'src', 'client', 'wasm-render');
const glue = await import(pathToFileURL(path.join(wasmDir, 'mdview_wasm_render.js')).href);
glue.initSync({ module: fs.readFileSync(path.join(wasmDir, 'mdview_wasm_render_bg.wasm')) });

const norm = (s) => s.replace(/\r\n/g, '\n').replace(/\r$/gm, '');
const bag = (a) => a.slice().sort().join('\u0001');

function describe(md) {
  const html = glue.render_markdown(norm(md), false);
  const tags = [...html.matchAll(/<(\w+)[^>]*?data-sourcepos="(\d+):\d+-\d+:\d+"[^>]*>/g)].map(
    (m) => `${m[1]}@${m[2]}`,
  );
  const pres = [...html.matchAll(/<pre[^>]*>([\s\S]*?)<\/pre>/g)].map((m) => m[1]);
  const hrefs = [...html.matchAll(/<a [^>]*href="([^"]*)"/g)].map((m) => m[1]).filter((h) => !h.startsWith('#'));
  const imgs = [...html.matchAll(/<img [^>]*src="([^"]*)"/g)].map((m) => m[1]);
  const code = [...html.replace(/<pre[\s\S]*?<\/pre>/g, '').matchAll(/<code>([\s\S]*?)<\/code>/g)].map((m) =>
    m[1].replace(/\s+/g, ' '),
  );
  return { tags, pres, hrefs: bag(hrefs), imgs: bag(imgs), code: bag(code) };
}

let bad = 0;
const files = fs.readdirSync(dir).filter((f) => f.endsWith('_a.md'));
for (const fa of files) {
  const a = describe(fs.readFileSync(path.join(dir, fa), 'utf8'));
  const b = describe(fs.readFileSync(path.join(dir, fa.replace('_a.md', '_b.md')), 'utf8'));
  let why = null;
  if (a.tags.join(' ') !== b.tags.join(' ')) {
    const i = a.tags.findIndex((t, k) => t !== b.tags[k]);
    why = `block ${a.tags[i] ?? '-'} -> ${b.tags[i] ?? '-'}`;
  } else if (JSON.stringify(a.pres) !== JSON.stringify(b.pres)) {
    why = 'literal block text changed';
  } else if (a.hrefs !== b.hrefs) {
    why = 'link targets changed';
  } else if (a.imgs !== b.imgs) {
    why = 'image sources changed';
  } else if (a.code !== b.code) {
    why = 'inline code changed';
  }
  if (why) {
    bad++;
    if (bad <= 30) console.log(`DIFF ${fa}: ${why}`);
  }
}
console.log(`pairs ${files.length}, differing ${bad}`);
process.exit(bad ? 1 : 0);
