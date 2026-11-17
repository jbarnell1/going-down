// HISTORICAL CHECK: shows that the goldens Godot recorded (godot/tests/golden/) still agree with the
// reference the frozen TypeScript rules write (godot/tools/dump_reference.ts and property_counts.ts).
// It is meaningful only while no rule has changed since the switch to goldens; after a deliberate rule
// change the goldens are expected to differ from TypeScript, and this check is retired with src/.
//
//   node godot/tools/check_goldens_against_typescript.mjs              # runs `npm run godot:reference` first (about 4 min)
//   node godot/tools/check_goldens_against_typescript.mjs --ref=DIR    # uses TypeScript output already in DIR
//
// What "agree" means (the comparison the Godot tests made against TypeScript before the goldens):
//   - every value is identical, with one exception: values derived from the instrument's pay
//     (rateAt's `k ** 3`, whose JavaScript result depends on the platform's pow: see godot/README.md)
//     may differ by at most 1e-9 (relative to the value, absolute below 1). Only fields named in PAY
//     get that allowance; the per-tick `full` digests (which include the pay) may differ only on ticks
//     whose `exact` digest (pay masked) is identical, and message texts only where the message's
//     masked digest is identical;
//   - the scenario inputs in godot/tests/inputs/ are exactly what TypeScript wrote;
//   - scenes that exist only in the goldens (added after the switch) are listed, not compared;
//   - parts of the TypeScript reference that the goldens do not hold are listed (for example the
//     full-size property counts before `npm run godot:golden -- --full` has been run).
// Exit code 0 only if everything compared agrees.
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const goldenDir = join(root, 'godot', 'tests', 'golden');
const inputDir = join(root, 'godot', 'tests', 'inputs');
const refArg = process.argv.find((a) => a.startsWith('--ref='));
const refDir = refArg ? resolve(refArg.slice('--ref='.length)) : join(root, 'godot', 'export', 'typescript-reference');

if (!refArg) {
  console.log(`Writing the TypeScript reference to ${refDir.slice(root.length + 1)} (npm run godot:reference) ...`);
  const r = spawnSync(process.execPath, [join(here, 'godot.mjs'), 'reference', `--out=${refDir}`], { stdio: 'inherit', cwd: root });
  if (r.status !== 0) {
    console.error('npm run godot:reference failed');
    process.exit(1);
  }
}

/** Fields derived from the instrument's pay (dump_reference.ts TAINT, and the property counts made from pay). */
const PAY = new Set([
  'value', 'rate', 'recorded', 'tickHz', 'loudness', 'tickPhase', 'ticks', 'total', 'peakRate', 'lostValue', 'carriedValue', 'shares',
  'carried', 'lost', 'medianValue', 'maxValue', 'rates',
  // The pow samples themselves (tests/test_jsmath.gd): fdlibm's pow against the platform's, within 1 ulp.
  'powInt',
]);
const TOL = 1e-9;
/** pow samples: the old test's bound (1 ulp, relative). */
const TOL_POW = 4.5e-16;

const read = (dir, name) => JSON.parse(readFileSync(join(dir, name), 'utf8'));
const isHex = (v) => typeof v === 'string' && /^~[0-9a-f]{16}$/.test(v);
const num = (v) => (isHex(v) ? Buffer.from(v.slice(1), 'hex').readDoubleBE(0) : v);
const isNum = (v) => typeof num(v) === 'number';
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const report = { compared: 0, payWithin: 0, payKeys: new Set(), digestTicks: 0, textsPayOnly: 0, failures: [], godotOnly: [], typescriptOnly: [] };
const fail = (path, msg) => report.failures.push(`${path}: ${msg}`);

/** Chunks of 8 hex digits that differ. */
function chunkDiffs(a, b) {
  const out = [];
  for (let i = 0; i < Math.max(a.length, b.length); i += 8) if (a.slice(i, i + 8) !== b.slice(i, i + 8)) out.push(i / 8);
  return out;
}

/** Compares golden `g` with TypeScript `r`; `key` is the nearest object key (for the pay allowance). */
function compare(g, r, path, key = '', payCtx = false) {
  const pay = payCtx || PAY.has(key);
  if (g === undefined) {
    report.typescriptOnly.push(path);
    return;
  }
  if (r === undefined) {
    report.godotOnly.push(path);
    return;
  }
  if (same(g, r)) {
    report.compared++;
    return;
  }
  if (isNum(g) && isNum(r)) {
    const a = num(g);
    const b = num(r);
    const ok = key === 'powInt' ? Math.abs(a - b) <= TOL_POW * Math.abs(b) : Math.abs(a - b) <= TOL * Math.max(1, Math.abs(b));
    if (pay && ok) {
      report.compared++;
      report.payWithin++;
      report.payKeys.add(key);
    } else {
      fail(path, `${a} (golden) vs ${b} (TypeScript)${pay ? '' : ', not a pay field'}`);
    }
    return;
  }
  if (Array.isArray(g) && Array.isArray(r)) {
    if (g.length !== r.length) fail(path, `${g.length} items (golden) vs ${r.length} (TypeScript)`);
    for (let i = 0; i < Math.min(g.length, r.length); i++) compare(g[i], r[i], `${path}[${i}]`, key, pay);
    return;
  }
  if (g && r && typeof g === 'object' && typeof r === 'object') {
    if (isTrace(g) && isTrace(r)) return compareTrace(g, r, path);
    if (g.msgs && r.msgs && g.frames && r.frames) return compareNet(g, r, path);
    for (const k of new Set([...Object.keys(g), ...Object.keys(r)])) compare(g[k], r[k], `${path}.${k}`, k, pay || (k === 'shares'));
    return;
  }
  fail(path, `${JSON.stringify(g)?.slice(0, 120)} (golden) vs ${JSON.stringify(r)?.slice(0, 120)} (TypeScript)`);
}

const isTrace = (v) => v && typeof v === 'object' && typeof v.full === 'string' && typeof v.exact === 'string' && 'events' in v;

/** A tick-by-tick trace: `exact` identical; `full` may differ only where `exact` does not. */
function compareTrace(g, r, path) {
  compare(g.name, r.name, `${path}.name`, 'name');
  compare(g.ticks, r.ticks, `${path}.ticks`, 'nticks');
  if (g.exact !== r.exact) fail(`${path}.exact`, `pay-masked state digests differ from tick ${chunkDiffs(g.exact, r.exact)[0]}`);
  else report.compared++;
  if (g.full !== r.full) {
    const d = chunkDiffs(g.full, r.full);
    report.digestTicks += d.length;
  }
  compare(g.snaps, r.snaps, `${path}.snaps`);
  compare(g.events, r.events, `${path}.events`);
  compare(g.extra, r.extra, `${path}.extra`, 'extra', path.includes('bridge'));
}

/** A network scene: every message's masked digest, route and frames identical; texts may differ in pay only. */
function compareNet(g, r, path) {
  const gm = g.msgs;
  const rm = r.msgs;
  compare(gm.n, rm.n, `${path}.msgs.n`, 'n');
  for (const k of ['mask', 'route']) {
    if (gm[k] !== rm[k]) fail(`${path}.msgs.${k}`, `differs from message ${chunkDiffs(gm[k], rm[k])[0]}`);
    else report.compared++;
  }
  // A text (and so its length and its full digest) may differ only in the pay fields: its masked digest is identical (checked above).
  const textDiff = chunkDiffs(gm.text, rm.text);
  report.textsPayOnly += textDiff.length;
  const fullDiff = new Set(chunkDiffs(gm.full, rm.full));
  for (const i of fullDiff) if (!textDiff.includes(i)) fail(`${path}.msgs.full`, `message ${i}: decoded message differs but its text does not`);
  for (let i = 0; i < Math.max(gm.lens.length, rm.lens.length); i++) {
    if (gm.lens[i] !== rm.lens[i] && !textDiff.includes(i)) fail(`${path}.msgs.lens[${i}]`, `${gm.lens[i]} vs ${rm.lens[i]}`);
  }
  for (const k of new Set([...Object.keys(gm.samples), ...Object.keys(rm.samples)])) {
    const a = gm.samples[k];
    const b = rm.samples[k];
    if (a === b) {
      report.compared++;
      continue;
    }
    if (a === undefined || b === undefined) {
      fail(`${path}.msgs.samples.${k}`, 'missing on one side');
      continue;
    }
    // Same message, pay numbers within the tolerance (the sample is a decoded message: compare its numbers).
    compare(JSON.parse(a), JSON.parse(b), `${path}.msgs.samples.${k}`, '', true);
  }
  compare(g.frames, r.frames, `${path}.frames`);
  compare(g.host, r.host, `${path}.host`);
  compare(g.hostStats, r.hostStats, `${path}.hostStats`);
  compare(g.clientStats, r.clientStats, `${path}.clientStats`);
  compare(g.logLength, r.logLength, `${path}.logLength`);
}

/** Lists matched by name: golden-only names are listed, not compared. */
function compareNamedLists(g, r, path) {
  const rByName = new Map(r.map((x) => [x.name, x]));
  for (const x of g) {
    if (!rByName.has(x.name)) {
      report.godotOnly.push(`${path} ${x.name}`);
      continue;
    }
    compare(x, rByName.get(x.name), `${path} ${x.name}`);
    rByName.delete(x.name);
  }
  for (const name of rByName.keys()) report.typescriptOnly.push(`${path} ${name}`);
}

/** The parts of a TypeScript scene that are inputs (tests/inputs/), not results. */
const withoutKeys = (o, keys) => Object.fromEntries(Object.entries(o).filter(([k]) => !keys.includes(k)));
const BRIDGE_INPUTS = ['frameKeys', 'requests'];
const NET_INPUTS = ['seed', 'setup', 'entity', 'roster', 'until', 'quick', 'near', 'machines', 'inputs'];

const files = ['math.json', 'rng.json', 'floors.json', 'move.json', 'sight.json', 'entity.json', 'instrument.json', 'run.json', 'bots.json', 'bridge.json', 'net.json', 'properties.json'];
for (const name of files) {
  if (!existsSync(join(goldenDir, name))) {
    fail(name, 'no golden file (run npm run godot:golden)');
    continue;
  }
  if (!existsSync(join(refDir, name))) {
    fail(name, `no TypeScript file in ${refDir}`);
    continue;
  }
  const g = read(goldenDir, name);
  const r = read(refDir, name);
  if (name === 'entity.json' || name === 'bots.json') compareNamedLists(g, r, name);
  else if (name === 'run.json') {
    for (const k of new Set([...Object.keys(g), ...Object.keys(r)])) {
      if (k === 'scenes') compareNamedLists(g[k], r[k], `${name} scenes`);
      else compare(g[k], r[k], `${name}.${k}`, k);
    }
  } else if (name === 'bridge.json') {
    compareNamedLists(g.scenes, r.scenes.map((s) => withoutKeys(s, BRIDGE_INPUTS)), `${name} scenes`);
  } else if (name === 'net.json') {
    compareNamedLists(g.scenes, r.scenes.map((s) => withoutKeys(s, NET_INPUTS)), `${name} scenes`);
  } else if (name === 'properties.json') {
    for (const k of new Set([...Object.keys(g), ...Object.keys(r)])) {
      if (!(k in g)) report.typescriptOnly.push(`${name}.${k} (not recorded in the goldens${k === 'full' ? ': npm run godot:golden -- --full' : ''})`);
      else compare(g[k], r[k], `${name}.${k}`, k);
    }
  } else compare(g, r, name);
}

// The inputs: exactly what TypeScript wrote.
{
  const im = read(inputDir, 'math.json');
  const rm = read(refDir, 'math.json');
  for (const k of ['sin', 'cos', 'tan', 'atan', 'exp', 'fixed']) compare(im[k], rm[k].map((row) => row[0]), `inputs/math.json.${k}`, 'input');
  compare(im.atan2, rm.atan2.map((row) => row.slice(0, 2)), 'inputs/math.json.atan2', 'input');
  compare(im.hypot2, rm.hypot2.map((row) => row.slice(0, 2)), 'inputs/math.json.hypot2', 'input');
  compare(im.hypot3, rm.hypot3.map((row) => row.slice(0, 3)), 'inputs/math.json.hypot3', 'input');
  compare(im.powInt, rm.powInt.map((row) => row.slice(0, 2)), 'inputs/math.json.powInt', 'input');
  compare(read(inputDir, 'literals.json'), read(refDir, 'literals.json'), 'inputs/literals.json', 'input');
  const ib = read(inputDir, 'bridge.json');
  const rb = read(refDir, 'bridge.json');
  compare(ib.scenes, rb.scenes.map((s) => ({ name: s.name, ...Object.fromEntries(BRIDGE_INPUTS.map((k) => [k, s[k]])) })), 'inputs/bridge.json', 'input');
  const inet = read(inputDir, 'net.json');
  const rnet = read(refDir, 'net.json');
  compare(inet.scenes, rnet.scenes.map((s) => ({ name: s.name, ...Object.fromEntries(NET_INPUTS.map((k) => [k, s[k]])) })), 'inputs/net.json', 'input');
  const texts = rnet.scenes.flatMap((s) => Object.keys(s.msgs.samples).sort((a, b) => a - b).map((k) => s.msgs.samples[k]));
  compare(read(inputDir, 'js_texts.json'), texts, 'inputs/js_texts.json', 'input');
}

console.log('');
console.log(`Goldens (godot/tests/golden/) against TypeScript (${refDir.slice(root.length + 1) || refDir}):`);
console.log(`  parts compared (an identical subtree counts once): ${report.compared}`);
console.log(`  pay-derived values that differ but within ${TOL}: ${report.payWithin} (fields: ${[...report.payKeys].sort().join(', ') || 'none'})`);
console.log(`  per-tick full digests that differ while the pay-masked digest is identical: ${report.digestTicks}`);
console.log(`  network message texts that differ only in pay fields (masked digest identical): ${report.textsPayOnly}`);
console.log(`  only in the goldens (added after the switch, not compared): ${report.godotOnly.length ? report.godotOnly.join('; ') : 'none'}`);
console.log(`  only in the TypeScript reference (not in the goldens): ${report.typescriptOnly.length ? report.typescriptOnly.join('; ') : 'none'}`);
if (report.failures.length === 0) {
  console.log('AGREE: everything compared exactly is identical; pay-derived values are within 1e-9.');
  process.exit(0);
}
console.log(`DISAGREE: ${report.failures.length} difference(s):`);
for (const f of report.failures.slice(0, 60)) console.log(`  - ${f}`);
if (report.failures.length > 60) console.log(`  ... ${report.failures.length - 60} more`);
process.exit(1);
