// The mix check: runs tools/mix_check.gd headless (a busy minute of the real game, every bus recorded),
// measures each bus with ffmpeg's ebur128 (short-term loudness every 100 ms, Master's true peak) and
// judges it against the voice's own loudness V (the Voice bus, integrated, as it was heard):
//   - no bus but Scare goes above V short-term (nothing but a scare is louder than the voice); a scare
//     (the roar, the shrieks) no more than V + 4 LU (they are made to reach about V + 3);
//   - Master's true peak stays at or under -1 dBTP;
//   - while the Orderly has been moving unseen within hearing for 3 s, Entity is no more than 12 LU under V;
//   - while the voice has been speaking for 3 s, Ambience is at least 14 LU under V (the beds duck);
//   - the busy minute really happened (the voice spoke, the Orderly came on unseen, a blink, the blackout).
// Usage: node godot/tools/mix_check.mjs [--keep=<dir>] [--reuse=<dir>]   (GODOT = the engine)
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const arg = (k) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? '').split('=').slice(1).join('=');
const reuse = arg('reuse');
const dir = reuse || arg('keep') || mkdtempSync(join(tmpdir(), 'mixcheck-'));
if (!reuse) {
  const godot = process.env.GODOT;
  if (!godot) { console.error('set GODOT to the engine'); process.exit(2); }
  const r = spawnSync(godot, ['--headless', '--path', project, '-s', 'res://tools/mix_check.gd', '--', dir, 'auto=1'], { encoding: 'utf8', timeout: 240000, killSignal: 'SIGKILL' });
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  const errs = out.split(/\r?\n/).filter((l) => /SCRIPT ERROR|Parse Error/.test(l));
  if (r.status !== 0 || errs.length) { console.log(out.slice(-3000)); console.log('FAIL the busy minute did not run'); process.exit(1); }
  console.log(out.split(/\r?\n/).find((l) => l.startsWith('mix_check:')) ?? '');
}
const meta = JSON.parse(readFileSync(join(dir, 'timeline.json'), 'utf8'));
const BUSES = ['Master', 'Voice', 'Entity', 'Scare', 'Effects', 'Ambience', 'UI'];
const meter = {};
for (const b of BUSES) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-f', 'f32le', '-ar', String(meta.rate), '-ac', '2', '-i', join(dir, `${b}.f32`), '-af', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 256 << 20 });
  const txt = r.stderr;
  const rows = [];
  const num = (v) => (/inf/.test(v) ? (v.startsWith('-') ? -200 : 200) : Number.isNaN(parseFloat(v)) ? -200 : parseFloat(v));
  for (const m of txt.matchAll(/t:\s*([\d.]+)\s+TARGET:.*?M:\s*(-?[\d.inf]+)\s+S:\s*(-?[\d.inf]+).*?TPK:\s*(-?[\d.inf]+)\s+(-?[\d.inf]+)/g)) {
    rows[Math.round(+m[1] * 10)] = { t: +m[1], M: num(m[2]), S: Math.max(-120, num(m[3])), tp: Math.max(num(m[4]), num(m[5])) };
  }
  for (let i = 0; i < rows.length; i++) if (!rows[i]) rows[i] = { t: i / 10, M: -120, S: -120, tp: -200 };
  const summ = txt.slice(txt.lastIndexOf('Summary:'));
  const I = parseFloat(/I:\s+(-?[\d.]+)/.exec(summ)?.[1] ?? '-70');
  const peak = parseFloat(/Peak:\s+(-?[\d.inf]+)/.exec(summ)?.[1] ?? '-inf');
  meter[b] = { rows, I, peak, sMax: Math.max(-120, ...rows.map((r) => r.S)) };
}
const V = meter.Voice.I;
const at = (b, t) => meter[b].rows[Math.min(meter[b].rows.length - 1, Math.max(0, Math.round(t * 10)))]?.S ?? -120;
const tl = meta.timeline;
const results = [];
const check = (name, ok, detail) => { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} ${name} (${detail})`); };
const fmt = (x) => (x <= -100 ? 'silent' : `${x.toFixed(1)}`);

console.log(`voice V = ${V.toFixed(1)} LUFS (Voice bus, integrated, as heard); ${meta.seconds.toFixed(1)} s recorded`);
for (const b of BUSES) console.log(`  ${b.padEnd(9)} integrated ${fmt(meter[b].I)}  short-term max ${fmt(meter[b].sMax)} (${(meter[b].sMax - V).toFixed(1)} LU vs V)  true peak ${meter[b].peak}`);
for (const b of ['Entity', 'Effects', 'Ambience', 'UI']) check(`${b} never louder than the voice`, meter[b].sMax <= V, `short-term max ${fmt(meter[b].sMax)}, ${(meter[b].sMax - V).toFixed(1)} LU vs V`);
check('a scare no more than 4 LU over the voice', meter.Scare.sMax <= V + 4, `short-term max ${fmt(meter.Scare.sMax)}, ${(meter.Scare.sMax - V).toFixed(1)} LU vs V`);
check('Master true peak at or under -1 dBTP', meter.Master.peak <= -1.0, `${meter.Master.peak} dBTP`);
// Windows where a condition has held for the last 3 s (the short-term window is full of it).
const held3 = (pred) => {
  const out = [];
  let since = null;
  for (const r of tl) {
    if (pred(r)) { if (since === null) since = r.t; if (r.t - since >= 3.0) out.push(r); } else since = null;
  }
  return out;
};
const coming = held3((r) => r.o && r.o.moving && !r.o.held && !r.o.seeing && r.o.g > 0);
const entityLow = coming.map((r) => ({ t: r.t, S: at('Entity', r.t), d: r.o.d })).sort((a, b) => a.S - b.S);
check('the Orderly coming on unseen was heard throughout (Entity within 12 LU of the voice)', coming.length > 0 && entityLow[0].S >= V - 12,
  coming.length ? `${coming.length} moments, quietest ${fmt(entityLow[0].S)} at ${entityLow[0].d.toFixed(1)} m (${(entityLow[0].S - V).toFixed(1)} LU vs V)` : 'it never came on unseen for 3 s');
const speaking = held3((r) => r.voice);
const ambLoud = speaking.map((r) => ({ t: r.t, S: at('Ambience', r.t) })).sort((a, b) => b.S - a.S);
check('the beds duck under the voice (Ambience at least 14 LU under V while it speaks)', speaking.length > 0 && ambLoud[0].S <= V - 14,
  speaking.length ? `${speaking.length} moments, loudest ${fmt(ambLoud[0].S)} (${(ambLoud[0].S - V).toFixed(1)} LU vs V)` : 'the voice never spoke for 3 s');
const blinks = tl.filter((r) => r.dark && !r.blackout).length;
const blackout = tl.filter((r) => r.blackout).length;
check('the busy minute: a blink and the blackout happened', blinks > 0 && blackout > 0, `${blinks} dark-blink samples, ${blackout} blackout samples`);
const played = {};
for (const r of tl) for (const n of r.played) played[n] = (played[n] ?? 0) + 1;
console.log(`one-shots played: ${JSON.stringify(played)}`);
if (!reuse && !arg('keep')) rmSync(dir, { recursive: true, force: true });
const ok = results.every(Boolean);
console.log(ok ? 'PASS the mix holds together' : 'FAIL the mix');
process.exit(ok ? 0 : 1);
