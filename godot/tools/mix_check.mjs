// The mix check: runs tools/mix_check.gd headless (a busy minute of the real game on the Clinic, every bus
// recorded), measures each bus with ffmpeg's ebur128 (short-term loudness every 100 ms, Master's true peak)
// and judges it against the voice's own loudness V (the Voice bus, integrated, as it was heard):
//   - no bus but Scare goes above V short-term (nothing but a scare is louder than the voice); a scare
//     (the roar, the shrieks) no more than V + 4 LU (they are made to reach about V + 3);
//   - Master's true peak stays at or under -1 dBTP;
//   - while the Orderly has been moving unseen within hearing for 3 s, Entity is no more than 12 LU under V;
//   - while the voice has been speaking for 3 s, Ambience is at least 14 LU under V (the beds duck);
//   - the busy minute really happened (the voice spoke, the Orderly came on unseen, a blink, the blackout);
//   - every bus was recorded from the same frame (in every run), or the times above do not line up.
// Then the Annex, the Playroom and the prison with the lift's panel (tools/mix_check_floors.gd: each one's loudest moments through the real
// sound code, headless, no walls), each judged against the voice heard in that same run (V = the Voice
// bus, integrated over the four lines):
//   - Entity, Effects, Ambience and UI never above V short-term; the Scare bus at most V + 4 and at least V
//     (the catch's roar, the found-you sting: louder than the voice, not by much);
//   - Ambience at least 8 LU under V throughout (the beds are V - 14, a room tone V - 10 at 3 m);
//   - the Playroom's count bell (on the Voice bus) never above V; Master's true peak at or under -1 dBTP;
//   - the scripted sounds really played (the floor's own one-shots are in the log).
// Usage: node godot/tools/mix_check.mjs [--keep=<dir>] [--reuse=<dir>] [--only=clinic|floors|far]
//        [--break=office|sting|far]   (GODOT = the engine)
//   --break=office  the Annex's office tone 12 dB up: must FAIL;  --break=sting  the found-you sting 8 dB up: must FAIL
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const arg = (k) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? '').split('=').slice(1).join('=');
const reuse = arg('reuse');
const only = arg('only');
const brk = arg('break');
const dir = reuse || arg('keep') || mkdtempSync(join(tmpdir(), 'mixcheck-'));
const godot = process.env.GODOT;
if (!reuse && !godot) { console.error('set GODOT to the engine'); process.exit(2); }
const BUSES = ['Master', 'Voice', 'Entity', 'Scare', 'Effects', 'Ambience', 'UI'];
const results = [];
const check = (name, ok, detail) => { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} ${name} (${detail})`); };
const fmt = (x) => (x <= -100 ? 'silent' : `${x.toFixed(1)}`);
const num = (v) => (/inf/.test(v) ? (v.startsWith('-') ? -200 : 200) : Number.isNaN(parseFloat(v)) ? -200 : parseFloat(v));

function runGodot(script, args) {
  const r = spawnSync(godot, ['--headless', '--path', project, '-s', script, '--', ...args], { encoding: 'utf8', timeout: 240000, killSignal: 'SIGKILL' });
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  const errs = out.split(/\r?\n/).filter((l) => /SCRIPT ERROR|Parse Error/.test(l));
  if (r.status !== 0 || errs.length) { console.log(out.slice(-3000)); return null; }
  return out;
}

// Every bus of a recording in `d`: short-term rows (100 ms), integrated, true peak.
// Every bus must be recorded from the same frame, or one runs early against the others and the timeline
// (the Ambience once lost 2 s at the start and the beds seemed to come back up before the voice ended).
function measure(d, rate, label) {
  const secs = BUSES.map((b) => statSync(join(d, `${b}.f32`)).size / (8 * rate));
  const spread = Math.max(...secs) - Math.min(...secs);
  check(`${label}: every bus recorded in step`, spread <= 0.1, `${secs.map((s, i) => `${BUSES[i]} ${s.toFixed(2)}`).join(', ')} s`);
  const meter = {};
  for (const b of BUSES) {
    const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-f', 'f32le', '-ar', String(rate), '-ac', '2', '-i', join(d, `${b}.f32`), '-af', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 256 << 20 });
    const txt = r.stderr;
    const rows = [];
    for (const m of txt.matchAll(/t:\s*([\d.]+)\s+TARGET:.*?M:\s*(-?[\d.inf]+|nan)\s+S:\s*(-?[\d.inf]+|nan).*?TPK:\s*(-?[\d.inf]+)\s+(-?[\d.inf]+)/g)) {
      rows[Math.round(+m[1] * 10)] = { t: +m[1], M: num(m[2]), S: Math.max(-120, num(m[3])), tp: Math.max(num(m[4]), num(m[5])) };
    }
    for (let i = 0; i < rows.length; i++) if (!rows[i]) rows[i] = { t: i / 10, M: -120, S: -120, tp: -200 };
    const summ = txt.slice(txt.lastIndexOf('Summary:'));
    const I = parseFloat(/I:\s+(-?[\d.]+)/.exec(summ)?.[1] ?? '-70');
    const peak = parseFloat(/Peak:\s+(-?[\d.inf]+)/.exec(summ)?.[1] ?? '-inf');
    meter[b] = { rows, I, peak, sMax: Math.max(-120, ...rows.map((x) => x.S)) };
  }
  return meter;
}
// Integrated loudness of one bus between two times.
function integrated(d, rate, bus, from, to) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-f', 'f32le', '-ar', String(rate), '-ac', '2', '-ss', String(from), '-to', String(to), '-i', join(d, `${bus}.f32`), '-af', 'ebur128', '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 256 << 20 });
  const summ = r.stderr.slice(r.stderr.lastIndexOf('Summary:'));
  return parseFloat(/I:\s+(-?[\d.]+)/.exec(summ)?.[1] ?? '-70');
}

// ---- The busy minute on the Clinic.
function clinic() {
  const cdir = join(dir, 'clinic');
  if (!reuse) {
    mkdirSync(cdir, { recursive: true });
    // quota=0 (with auto=1): no floor quota, so the busy minute's call brings the car without a reading.
    const out = runGodot('res://tools/mix_check.gd', [cdir, 'auto=1', 'quota=0']);
    if (out === null) { check('the busy minute ran', false, 'it did not'); return; }
    console.log(out.split(/\r?\n/).find((l) => l.startsWith('mix_check:')) ?? '');
  }
  const meta = JSON.parse(readFileSync(join(cdir, 'timeline.json'), 'utf8'));
  const meter = measure(cdir, meta.rate, 'Clinic');
  const V = meter.Voice.I;
  const at = (b, t) => meter[b].rows[Math.min(meter[b].rows.length - 1, Math.max(0, Math.round(t * 10)))]?.S ?? -120;
  const tl = meta.timeline;
  console.log(`== The Clinic, the busy minute: voice V = ${V.toFixed(1)} LUFS (Voice bus, integrated, as heard); ${meta.seconds.toFixed(1)} s recorded`);
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
}

// ---- The Annex and the Playroom.
const WANT = {
  annex: ['phone', 'copier', 'blink_warn', 'blackout_warn', 'roar', 'staple_soft', 'chime'],
  playroom: ['xylo', 'xylo_note', 'count_bell', 'squeak', 'pit_jump', 'hide_in', 'net_flap', 'huff', 'found', 'down'],
  prison: ['refused', 'quota_met', 'lift_up', 'bunk', 'lights_out'],
};
function oneFloor(name) {
  const fdir = join(dir, name);
  if (!reuse) {
    mkdirSync(fdir, { recursive: true });
    const out = runGodot('res://tools/mix_check_floors.gd', [fdir, name, ...(brk ? [`break=${brk}`] : [])]);
    if (out === null) { check(`the ${name} run ran`, false, 'it did not'); return; }
    console.log(out.split(/\r?\n/).find((l) => l.startsWith('mix_check_floors:')) ?? '');
  }
  const meta = JSON.parse(readFileSync(join(fdir, 'timeline.json'), 'utf8'));
  const meter = measure(fdir, meta.rate, name[0].toUpperCase() + name.slice(1));
  const mk = (w) => meta.marks.find((m) => m.what === w)?.t;
  const V = integrated(fdir, meta.rate, 'Voice', mk('voice'), mk('voice_end'));
  const Name = name[0].toUpperCase() + name.slice(1);
  console.log(`== The ${Name}${meta.break ? ` (break: ${meta.break})` : ''}: voice V = ${V.toFixed(1)} LUFS (Voice bus over the four lines); ${meta.seconds.toFixed(1)} s recorded`);
  // Where each bus was loudest, by the scripted moment it fell in.
  const moment = (t) => { let w = ''; for (const m of meta.marks) if (m.t <= t) w = m.what; return w; };
  const loudest = (b, from = 0, to = 1e9) => {
    let best = { S: -120, t: 0 };
    for (const r of meter[b].rows) if (r.t >= from && r.t <= to && r.S > best.S) best = r;
    return best;
  };
  for (const b of BUSES) {
    const l = loudest(b);
    console.log(`  ${b.padEnd(9)} short-term max ${fmt(l.S)} (${(l.S - V).toFixed(1)} LU vs V) at ${l.t.toFixed(1)} s (${moment(l.t)})  true peak ${meter[b].peak}`);
  }
  for (const b of ['Entity', 'Effects', 'Ambience', 'UI']) {
    const l = loudest(b);
    check(`${Name}: ${b} never louder than the voice`, l.S <= V, `short-term max ${fmt(l.S)}, ${(l.S - V).toFixed(1)} LU vs V, at ${moment(l.t)}`);
  }
  const sc = loudest('Scare');
  if (name === 'prison') check('Prison: no scare at home (the Scare bus silent)', sc.S <= -100, `short-term max ${fmt(sc.S)}`);
  else check(`${Name}: the scare louder than the voice, at most 4 LU over it`, sc.S <= V + 4 && sc.S >= V, `short-term max ${fmt(sc.S)}, ${(sc.S - V).toFixed(1)} LU vs V, at ${moment(sc.t)}`);
  const amb = loudest('Ambience');
  check(`${Name}: the beds and room tones sit under the voice (Ambience at least 8 LU under V)`, amb.S <= V - 8, `short-term max ${fmt(amb.S)}, ${(amb.S - V).toFixed(1)} LU vs V, at ${moment(amb.t)}`);
  if (name === 'playroom') {
    const bell = loudest('Voice', mk('bell'), mk('bell_end'));
    check('Playroom: the count bell (Voice bus) never above the voice', bell.S <= V, `short-term max ${fmt(bell.S)}, ${(bell.S - V).toFixed(1)} LU vs V`);
  }
  check(`${Name}: Master true peak at or under -1 dBTP`, meter.Master.peak <= -1.0, `${meter.Master.peak} dBTP`);
  const missing = WANT[name].filter((n) => !meta.played.includes(n));
  check(`${Name}: the scripted sounds played`, missing.length === 0, missing.length ? `missing ${missing.join(', ')}` : `${meta.played.length} one-shots`);
}

// ---- Far off (the owner on build 0833: distant shrieks, roars and the raspy breathing were too quiet).
// A roar at 55 m and at 25 m behind you must be heard (Scare short-term at least V-20 and V-11, never
// over V+4); the Orderly's slow breathing, coming from 40 m unseen, must be heard (Entity momentary over
// V-35) from 20 m or further out, and grow as it nears.
function far() {
  const fdir = join(dir, 'far');
  if (!reuse) {
    mkdirSync(fdir, { recursive: true });
    const out = runGodot('res://tools/mix_check_floors.gd', [fdir, 'far', ...(brk ? [`break=${brk}`] : [])]);
    if (out === null) { check('the far run ran', false, 'it did not'); return; }
  }
  const meta = JSON.parse(readFileSync(join(fdir, 'timeline.json'), 'utf8'));
  const meter = measure(fdir, meta.rate, 'Far');
  const mk = (w) => meta.marks.find((m) => m.what === w)?.t;
  const V = integrated(fdir, meta.rate, 'Voice', mk('voice'), mk('voice_end'));
  const max = (b, k, from, to) => Math.max(-120, ...meter[b].rows.filter((r) => r.t >= from && r.t <= to).map((r) => r[k]));
  const r55 = max('Scare', 'S', mk('roar55'), mk('roar25'));
  const r25 = max('Scare', 'S', mk('roar25'), mk('breath'));
  console.log(`== Far off${meta.break ? ` (break: ${meta.break})` : ''}: voice V = ${V.toFixed(1)} LUFS`);
  check('Far: a roar 25 m behind you is heard (Scare at least V-11, at most V+4)', r25 >= V - 11 && r25 <= V + 4, `short-term max ${fmt(r25)}, ${(r25 - V).toFixed(1)} LU vs V`);
  check('Far: a roar 55 m off, the lift from a far corner, is heard (Scare at least V-20)', r55 >= V - 20 && r55 <= V + 4, `short-term max ${fmt(r55)}, ${(r55 - V).toFixed(1)} LU vs V`);
  const mAt = (t) => meter.Entity.rows[Math.min(meter.Entity.rows.length - 1, Math.max(0, Math.round(t * 10)))]?.M ?? -120;
  let onset = 0;
  for (const [t, d] of meta.track) if (mAt(t) > V - 35) { onset = d; break; }
  // The loudest moment while it comes from dm + 3 m to dm m (1.5 s at 2 m/s): the slow breath has a
  // 0.6 s hush between breaths every 2.7 s, so one 100 ms reading at the very metre could land in a hush
  // and read 15 dB low (what made "louder at 5 m than at 20 m" come and go).
  const at = (dm) => Math.max(-120, ...meta.track.filter(([, d]) => d >= dm && d <= dm + 3).map(([t]) => mAt(t)));
  console.log(`  the breathing, loudest momentary vs V coming in to: ${[30, 25, 20, 15, 10, 5, 2].map((dm) => `${dm} m ${(at(dm) - V).toFixed(1)}`).join(', ')}`);
  check('Far: the Orderly\'s breathing is heard only within immediate proximity (Entity momentary over V-35)', onset >= 4 && onset <= 8.5, onset ? `first heard at ${onset.toFixed(1)} m` : 'never heard');
  check('Far: the breathing builds as it nears (louder at 5 m than at 20 m), never over the voice', at(5) > at(20) && max('Entity', 'S', mk('breath'), mk('end')) <= V, `20 m ${(at(20) - V).toFixed(1)}, 5 m ${(at(5) - V).toFixed(1)} LU vs V`);
  // In the game the trolley sounds while it comes on unseen, and the breath steps back under it close in
  // (Sfx.breath_db): it must still never drop as it nears, with the trolley or without.
  const curve = meta.curve ?? [];
  const drops = (k) => curve.slice(1).filter((row, i) => row[k] < curve[i][k] - 0.01).map((row) => row[0]);
  const show = (k) => [20, 10, 5, 2].map((dm) => `${dm} m ${(curve.find((r) => r[0] === dm)?.[k] ?? NaN).toFixed(1)}`).join(', ');
  console.log(`  the breath's curve in dB, alone: ${show(1)}; under the trolley: ${show(2)}; the rattle under the trolley: ${show(3)}`);
  check('Far: the breathing never drops as it nears, alone or under the trolley, nor the rattle (Sfx.breath_db, every half metre from 40 m)', curve.length > 0 && [1, 2, 3].every((k) => drops(k).length === 0),
    curve.length ? ([1, 2, 3].some((k) => drops(k).length) ? `drops at ${[1, 2, 3].flatMap((k) => drops(k)).join(', ')} m` : `${curve.length} points`) : 'no curve logged');
}

if (only !== 'floors' && only !== 'far') clinic();
if (only !== 'clinic' && only !== 'far') { oneFloor('annex'); oneFloor('playroom'); oneFloor('prison'); }
if (only !== 'clinic') far();
if (!reuse && !arg('keep')) rmSync(dir, { recursive: true, force: true });
const ok = results.every(Boolean);
console.log(ok ? 'PASS the mix holds together' : 'FAIL the mix');
process.exit(ok ? 0 : 1);
