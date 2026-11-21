// Compares two test logs (npm run godot:test, one engine or sharded): the same tests, each with the same
// result? Prints every difference and exits 1 if there is one, else prints "same N tests" and exits 0.
//   node godot/tools/test_compare.mjs serial.log sharded.log
// A line is a result when it starts (after an engine's "[s1] " prefix) with "PASS  " or "FAIL  ".
import { readFileSync } from 'node:fs';

export function results(text) {
  const out = new Map();
  const dup = [];
  for (const raw of text.split(/\r?\n/)) {
    const l = raw.replace(/^\[[^\]]+\] /, '');
    const m = /^(PASS|FAIL)  (\S+)/.exec(l);
    if (!m) continue;
    if (out.has(m[2])) dup.push(m[2]);
    out.set(m[2], m[1]);
  }
  const totals = text.split(/\r?\n/).filter((l) => /^\d+ passed, \d+ failed in [\d.]+ s\s*$/.test(l)).pop() ?? '(no totals line)';
  return { out, dup, totals };
}

const [a, b] = process.argv.slice(2);
if (!a || !b) {
  console.error('usage: node godot/tools/test_compare.mjs A.log B.log');
  process.exit(2);
}
const A = results(readFileSync(a, 'utf8'));
const B = results(readFileSync(b, 'utf8'));
const diffs = [];
for (const [n, r] of A.out) if (!B.out.has(n)) diffs.push(`only in ${a}: ${r}  ${n}`);
for (const [n, r] of B.out) if (!A.out.has(n)) diffs.push(`only in ${b}: ${r}  ${n}`);
for (const [n, r] of A.out) if (B.out.has(n) && B.out.get(n) !== r) diffs.push(`${n}: ${r} in ${a}, ${B.out.get(n)} in ${b}`);
for (const n of A.dup) diffs.push(`reported twice in ${a}: ${n}`);
for (const n of B.dup) diffs.push(`reported twice in ${b}: ${n}`);
console.log(`${a}: ${A.out.size} tests; last line: ${A.totals}`);
console.log(`${b}: ${B.out.size} tests; last line: ${B.totals}`);
for (const d of diffs) console.log(`  ${d}`);
console.log(diffs.length === 0 ? `same ${A.out.size} tests, each with the same result` : `${diffs.length} difference(s)`);
process.exit(diffs.length === 0 ? 0 : 1);
