// scripts/markdown_reduce.mjs -- shrink a Markdown file that the oracle flags to the few lines that matter.
//
//   node scripts/markdown_reduce.mjs <file.md> [work_dir]
//
// Repeats: write every "file without line N" as a candidate, run `markdown_oracle.lua` on all of them in one
// go, and keep a candidate the oracle still flags (`markdown_oracle.mjs`). When no single line can go, the file
// is minimal; it is printed together with the source line numbers that survived. Needs `nvim` on PATH and the
// sibling checkout `mdview.nvim` (as the oracle does).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const file = process.argv[2];
if (!file) {
  console.error('usage: node markdown_reduce.mjs <file.md> [work_dir]');
  process.exit(2);
}
const here = import.meta.dirname;
const root = path.resolve(here, '..');
const work = path.resolve(process.argv[3] ?? fs.mkdtempSync(path.join(os.tmpdir(), 'mdreduce-')));

/** Does the oracle flag any of these candidates? Returns the indexes that differ. */
function flagged(candidates) {
  const dir = path.join(work, 'cand');
  const pairs = path.join(work, 'pairs');
  fs.rmSync(dir, { recursive: true, force: true });
  fs.rmSync(pairs, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const names = candidates.map((c, i) => {
    const p = path.join(dir, `c${i}.md`);
    fs.writeFileSync(p, c.join('\n') + '\n');
    return p;
  });
  const list = path.join(dir, 'list.txt');
  fs.writeFileSync(list, names.join('\n') + '\n');
  const lua = spawnSync(
    'nvim',
    ['-n', '-i', 'NONE', '--headless', '-u', 'TESTS/minimal_init.lua', '-l', 'scripts/markdown_oracle.lua', pairs, '@' + list],
    { cwd: root, encoding: 'utf8' },
  );
  if (lua.status !== 0) {
    console.error(lua.stdout, lua.stderr);
    process.exit(2);
  }
  const node = spawnSync(process.execPath, ['scripts/markdown_oracle.mjs', pairs], { cwd: root, encoding: 'utf8' });
  const hit = new Set();
  for (const m of node.stdout.matchAll(/^DIFF s(\d+)_/gm)) {
    hit.add(Number(m[1]) - 1); // markdown_oracle.lua numbers its files from 1
  }
  return hit;
}

let lines = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n').replace(/\n$/, '').split('\n');
let origin = lines.map((_, i) => i + 1);
if (flagged([lines]).size === 0) {
  console.log('the oracle does not flag this file');
  process.exit(0);
}
for (;;) {
  const candidates = lines.map((_, i) => lines.filter((__, j) => j !== i));
  const hit = flagged(candidates);
  if (hit.size === 0) {
    break;
  }
  const drop = Math.min(...hit);
  lines = candidates[drop];
  origin = origin.filter((_, j) => j !== drop);
}
console.log(`reduced to ${lines.length} line(s) (source lines ${origin.join(', ')}):`);
console.log(lines.map((l) => JSON.stringify(l)).join('\n'));
console.log('---');
console.log(lines.join('\n'));
