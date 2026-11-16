// Checks the published announcer lines (docs/VOICE.md, "Checks the loop can run"). Exits non-zero on
// any failure. It cannot tell whether a read is funny or frightening: that needs ears.
//
//   node assets_src/voice/check.mjs
//
// For every shipped voice (voices.ship) and every line in lines.json: public/assets/voice/<voice>/<id>.mp3
// exists and the line is in the manifest; its
// duration is 0.4 to 1.6 times the estimate (words at 2.5 a second, plus the pauses its tags and
// ellipses ask for; far outside that usually means a tag was read aloud or a sound effect produced);
// no clipping (sample peak under -0.1 dBFS, true peak at most -1 dBTP); loudness within 1 LU of
// -16 LUFS. And the ledger is under the cap.
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { measure, TARGET_LUFS } from './ff.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const PUBLIC = path.join(ROOT, 'public', 'assets', 'voice');
const cfg = JSON.parse(readFileSync(path.join(HERE, 'lines.json'), 'utf8'));
const manifestFile = path.join(PUBLIC, 'manifest.json');
const manifest = existsSync(manifestFile) ? JSON.parse(readFileSync(manifestFile, 'utf8')) : { lines: [] };
const ledgerFile = path.join(HERE, 'ledger.json');
const ledger = existsSync(ledgerFile) ? JSON.parse(readFileSync(ledgerFile, 'utf8')) : { total: 0, entries: [] };
const CAP = 50_000;

const WORDS_PER_SECOND = 2.5;
const PAUSE = { '[short pause]': 0.5, '[pause]': 1.6, '[long pause]': 2.5 };

/** Expected seconds for a line: its spoken words, plus its pauses. */
export function estimate(line) {
  const words = line.plain.split(/\s+/).filter((w) => /[a-z0-9]/i.test(w)).length;
  let s = words / WORDS_PER_SECOND;
  for (const [tag, sec] of Object.entries(PAUSE)) s += (line.text.split(tag).length - 1) * sec;
  s += (line.text.match(/\.\.\./g) ?? []).length * 0.4;
  // A colon mid-sentence is read as a beat (measured 0.32 to 0.53 s in called_3, both voices).
  s += (line.plain.match(/:\s/g) ?? []).length * 0.35;
  return s;
}

const fails = [];
const ids = new Set();
const slug = (name) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const ship = (cfg.voices.ship ?? []).map(slug);
if (ship.length === 0) fails.push('lines.json ships no voices (voices.ship)');
if (JSON.stringify((manifest.voices ?? []).map((v) => v.id)) !== JSON.stringify(ship)) fails.push(`manifest.json voices ${JSON.stringify((manifest.voices ?? []).map((v) => v.id))} do not match voices.ship (run --publish)`);
if (!ship.includes(manifest.default)) fails.push(`manifest.json default voice ${manifest.default} is not shipped`);
for (const line of cfg.lines) {
  if (ids.has(line.id)) fails.push(`${line.id}: duplicate id`);
  ids.add(line.id);
  if (!cfg.moments[line.moment]) fails.push(`${line.id}: unknown moment ${line.moment}`);
  if (!manifest.lines.some((l) => l.id === line.id && l.plain === line.plain)) fails.push(`${line.id}: missing or stale in manifest.json (run --publish)`);
}
for (const voice of ship) for (const line of cfg.lines) {
  const name = `${voice}/${line.id}`;
  const file = path.join(PUBLIC, voice, `${line.id}.mp3`);
  if (!existsSync(file)) {
    fails.push(`${name}: no file public/assets/voice/${name}.mp3`);
    continue;
  }
  const m = measure(file);
  const est = estimate(line);
  const k = m.duration / est;
  const bad = [];
  if (!(k >= 0.4 && k <= 1.6)) bad.push(`duration ${m.duration.toFixed(2)} s is ${k.toFixed(2)}x the estimate`);
  if (!(m.samplePeak < -0.1)) bad.push(`sample peak ${m.samplePeak} dBFS (clipping)`);
  if (!(m.truePeak <= -1)) bad.push(`true peak ${m.truePeak} dBTP`);
  if (!(Math.abs(m.lufs - TARGET_LUFS) <= 1)) bad.push(`loudness ${m.lufs} LUFS`);
  const row = `${name.padEnd(16)} ${m.duration.toFixed(2).padStart(5)} s (est ${est.toFixed(2)}, x${k.toFixed(2)})  ${m.lufs.toFixed(1)} LUFS  TP ${m.truePeak.toFixed(1)}  SP ${m.samplePeak.toFixed(1)}`;
  console.log(`${bad.length ? 'FAIL' : 'ok  '} ${row}`);
  for (const b of bad) fails.push(`${name}: ${b}`);
}
for (const l of manifest.lines) if (!ids.has(l.id)) fails.push(`manifest.json has ${l.id}, which lines.json does not`);
const sum = ledger.entries.reduce((n, e) => n + e.characters, 0);
if (sum !== ledger.total) fails.push(`ledger total ${ledger.total} does not match its entries (${sum})`);
if (ledger.total > CAP) fails.push(`ledger ${ledger.total} is over the cap ${CAP}`);
console.log(`ledger: ${ledger.total} of ${CAP} characters`);

if (fails.length) {
  console.error(`\n${fails.length} problem(s):\n  ${fails.join('\n  ')}`);
  process.exit(1);
}
console.log(`voice check: ${cfg.lines.length} lines x ${ship.length} voices (${ship.join(', ')}) ok`);
