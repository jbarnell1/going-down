// Rebuilds the roosting birds' five sounds (godot/assets/sfx/dangers/roost/*.ogg) from nothing: every sample is
// arithmetic on a seeded generator, so the same files come out every time. No recording, no service.
//   node assets_src/sfx/dangers/roost.mjs [--out=<folder>]
// ffmpeg (on PATH, or FFMPEG) only encodes the finished samples to mono Ogg Vorbis (quality 5).
//
//   roost_idle    6 s loop: feathers shuffling high in a tree and a low throaty chuckle every few seconds.
//   roost_stir    4 s loop: the same birds restless: dense shuffling, beak clacks, short sharp calls.
//   roost_flush   3 s once: the whole roost going up: a clap of wings, many wingbeat trains climbing away, alarm calls.
//   roost_circle  8 s loop: a few birds circling somewhere overhead, far off: wingbeats and a call now and then.
//   roost_settle  1.5 s once: a few birds dropping back in: soft flutters and two low chuckles.
// Loops are written round a ring (anything that runs past the end comes back in at the start), so they join cleanly.
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, statSync, mkdtempSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..', '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).slice(k.length + 3);
const out = resolve(arg('out', join(root, 'godot', 'assets', 'sfx', 'dangers', 'roost')));
const ffmpeg = process.env.FFMPEG || 'ffmpeg';
const RATE = 44100;
const TAU = Math.PI * 2;

// mulberry32, the game's own generator (sim/rng.gd), seeded per sound.
function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  next.range = (lo, hi) => lo + (hi - lo) * next();
  return next;
}

// RBJ biquads, run in place over a Float32Array.
function biquad(kind, f, q) {
  const w = (TAU * f) / RATE;
  const cs = Math.cos(w);
  const al = Math.sin(w) / (2 * q);
  let b0, b1, b2;
  if (kind === 'band') { b0 = al; b1 = 0; b2 = -al; }
  else if (kind === 'low') { b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2; }
  else { b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2; }
  const a0 = 1 + al;
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: (-2 * cs) / a0, a2: (1 - al) / a0, x1: 0, x2: 0, y1: 0, y2: 0 };
}
function run(fl, x) {
  const y = fl.b0 * x + fl.b1 * fl.x1 + fl.b2 * fl.x2 - fl.a1 * fl.y1 - fl.a2 * fl.y2;
  fl.x2 = fl.x1; fl.x1 = x; fl.y2 = fl.y1; fl.y1 = y;
  return y;
}
function filter(buf, kind, f, q = 0.707) {
  const fl = biquad(kind, f, q);
  for (let i = 0; i < buf.length; i++) buf[i] = run(fl, buf[i]);
  return buf;
}

// Adds `src` into `dst` at sample `at`, wrapping round the end when `ring` (loops).
function mix(dst, src, at, gain, ring) {
  for (let i = 0; i < src.length; i++) {
    let j = at + i;
    if (j >= dst.length) { if (!ring) break; j %= dst.length; }
    if (j < 0) continue;
    dst[j] += src[i] * gain;
  }
}
const len = (s) => Math.max(1, Math.round(s * RATE));

// Feathers and twigs: a burst of tiny noise grains (2 to 6 ms), band-passed high. `dens` grains per second.
function rustle(r, secs, dens, lo = 2000, hi = 4200) {
  const b = new Float32Array(len(secs));
  const n = Math.max(2, Math.round(secs * dens));
  for (let g = 0; g < n; g++) {
    const at = Math.floor(r() * b.length);
    const gl = len(r.range(0.002, 0.006));
    const amp = r.range(0.3, 1.0);
    for (let i = 0; i < gl && at + i < b.length; i++) b[at + i] += (r() * 2 - 1) * amp * Math.exp((-i / gl) * 3);
  }
  // A soft swell over the burst, then the band.
  for (let i = 0; i < b.length; i++) b[i] *= Math.sin((Math.PI * i) / b.length) ** 0.7;
  filter(b, 'band', r.range(lo, hi), 1.4);
  return filter(b, 'band', r.range(lo, hi), 1.0);
}

// A glottal call: a saw that falls in pitch, through two throat resonances, with a little breath.
// f0: start pitch (Hz), fall: fraction it falls by, secs, rough: pitch wobble, formants [f, q, gain].
function call(r, f0, fall, secs, rough, formants, breath = 0.15, attack = 0.006) {
  const n = len(secs);
  const src = new Float32Array(n);
  let ph = 0;
  const wob = r.range(25, 40);
  const wph = r() * TAU;
  for (let i = 0; i < n; i++) {
    const t = i / n;
    const f = f0 * (1 - fall * t) * (1 + rough * Math.sin(TAU * wob * (i / RATE) + wph) + rough * 0.6 * (r() * 2 - 1));
    ph += f / RATE;
    ph -= Math.floor(ph);
    const saw = 2 * ph - 1;
    const env = Math.min(1, i / len(attack)) * Math.min(1, (n - i) / len(Math.min(0.06, secs * 0.4)));
    src[i] = (saw * (1 - breath) + (r() * 2 - 1) * breath) * env;
  }
  const outb = new Float32Array(n);
  for (const [f, q, g] of formants) {
    const b = Float32Array.from(src);
    filter(b, 'band', f, q);
    for (let i = 0; i < n; i++) outb[i] += b[i] * g;
  }
  return outb;
}

// A chuckle: three to six short throaty pulses, falling, the last ones softer ("kuk-kuk-kuk").
function chuckle(r, low = false) {
  const pulses = 3 + Math.floor(r() * 4);
  const gap = r.range(0.07, 0.11);
  const b = new Float32Array(len(pulses * gap + 0.12));
  const f0 = r.range(180, 260) * (low ? 0.85 : 1);
  for (let k = 0; k < pulses; k++) {
    const p = call(r, f0 * (1 - 0.04 * k), 0.25, r.range(0.045, 0.07), 0.04, [[700, 3.0, 1.0], [1350, 4.0, 0.45]], 0.12, 0.004);
    mix(b, p, len(k * gap + r.range(-0.006, 0.006)), 1 - 0.13 * k, false);
  }
  return b;
}

// An alarm call: a harsh rasping "kraa", fast wobble, noisy, falling a little.
function alarm(r) {
  const secs = r.range(0.18, 0.32);
  const c = call(r, r.range(360, 480), 0.18, secs, 0.09, [[1000, 2.2, 1.0], [2200, 3.0, 0.6], [650, 2.0, 0.4]], 0.32, 0.012);
  // Rasp: chop it at 60 to 90 Hz.
  const chop = r.range(60, 90);
  for (let i = 0; i < c.length; i++) c[i] *= 0.65 + 0.35 * Math.sign(Math.sin(TAU * chop * (i / RATE)));
  return c;
}

// A beak clack: two hard little clicks 30 to 50 ms apart.
function clack(r) {
  const b = new Float32Array(len(0.07));
  for (const at of [0, r.range(0.03, 0.05)]) {
    const f = r.range(2600, 3500);
    const s = len(at);
    for (let i = 0; i < len(0.008) && s + i < b.length; i++) {
      const t = i / RATE;
      b[s + i] += (Math.sin(TAU * f * t) * 0.8 + (r() * 2 - 1) * 0.5) * Math.exp(-t * 700);
    }
  }
  return b;
}

// One bird's wingbeats: `secs` of beats at `rate` Hz; each beat a low air thump and a whoosh. The whoosh's band
// rises (from `f1` to `f2`) and the train fades out, as the bird climbs away. `startAmp` to `endAmp`.
function wings(r, secs, rate, f1, f2, startAmp = 1, endAmp = 0) {
  const n = len(secs);
  const noise = new Float32Array(n);
  const thump = new Float32Array(n);
  const ph = r() * TAU;
  const jitter = r.range(0.02, 0.06);
  for (let i = 0; i < n; i++) {
    const t = i / RATE;
    const rr = rate * (1 + jitter * Math.sin(TAU * 1.3 * t));
    const beat = Math.max(0, Math.sin(TAU * rr * t + ph));
    const env = beat ** 3;
    noise[i] = (r() * 2 - 1) * env;
    thump[i] = Math.sin(TAU * r.range(95, 130) * t) * beat ** 8;
  }
  // The whoosh in short pieces so its band can rise.
  const piece = len(0.05);
  const outb = new Float32Array(n);
  for (let s = 0, k = 0; s < n; s += piece, k++) {
    const frac = s / n;
    const fl = biquad('band', f1 + (f2 - f1) * frac, 0.9);
    // Warm the filter on the previous samples so the pieces join.
    for (let i = Math.max(0, s - piece); i < s; i++) run(fl, noise[i]);
    for (let i = s; i < Math.min(n, s + piece); i++) outb[i] = run(fl, noise[i]);
  }
  for (let i = 0; i < n; i++) {
    const frac = i / n;
    const amp = startAmp + (endAmp - startAmp) * frac;
    outb[i] = (outb[i] * 1.6 + thump[i] * 0.35 * (1 - frac)) * amp * Math.min(1, i / len(0.01));
  }
  return outb;
}

function normalise(b, peakDb) {
  let peak = 0;
  for (const v of b) peak = Math.max(peak, Math.abs(v));
  const k = peak > 0 ? 10 ** (peakDb / 20) / peak : 1;
  for (let i = 0; i < b.length; i++) b[i] *= k;
  return b;
}

function fadeEnds(b, inS, outS) {
  const a = len(inS);
  const z = len(outS);
  for (let i = 0; i < a && i < b.length; i++) b[i] *= i / a;
  for (let i = 0; i < z && i < b.length; i++) b[b.length - 1 - i] *= i / z;
  return b;
}

// ---- the five sounds ----

function idle() {
  const r = rng(4101);
  const L = 16;
  const b = new Float32Array(len(L));
  // Feathers: shuffles of 60 to 200 ms, here and there.
  for (let k = 0; k < 26; k++) mix(b, rustle(r, r.range(0.06, 0.2), r.range(250, 500)), len(r.range(0, L)), r.range(0.25, 0.5), true);
  // A longer settle of feathers now and then.
  for (let k = 0; k < 5; k++) mix(b, rustle(r, r.range(0.35, 0.6), 160, 1800, 3200), len(k * 3.2 + r.range(0.3, 2.0)), 0.3, true);
  // Chuckles at uneven gaps (2 to 5 s) round the ring, low and higher birds.
  let at = r.range(0.2, 0.8);
  while (at < L - 1.0) {
    const low = r() < 0.4;
    mix(b, chuckle(r, low), len(at), low ? 0.8 : 1.0, true);
    at += r.range(2.0, 5.0);
  }
  // Soft single croaks.
  for (let k = 0; k < 2; k++) {
    mix(b, call(r, r.range(160, 190), 0.3, 0.16, 0.05, [[650, 2.5, 1], [1250, 3.5, 0.4]], 0.2, 0.02), len(r.range(1, L - 1)), 0.55, true);
  }
  return normalise(b, -3);
}

function stir() {
  const r = rng(4202);
  const b = new Float32Array(len(4));
  for (let k = 0; k < 26; k++) mix(b, rustle(r, r.range(0.05, 0.16), r.range(400, 800)), len(r.range(0, 4)), r.range(0.3, 0.6), true);
  for (let k = 0; k < 6; k++) mix(b, clack(r), len(r.range(0, 4)), r.range(0.35, 0.6), true);
  // Short, sharper calls: restless, not yet alarmed.
  for (let k = 0; k < 4; k++) {
    const c = call(r, r.range(260, 340), 0.22, r.range(0.07, 0.12), 0.06, [[850, 2.6, 1], [1700, 3.5, 0.5]], 0.18, 0.006);
    mix(b, c, len(k + r.range(0.1, 0.8)), r.range(0.55, 0.8), true);
  }
  mix(b, chuckle(r), len(r.range(1.6, 2.2)), 0.7, true);
  return normalise(b, -2);
}

function flush() {
  const r = rng(4303);
  const b = new Float32Array(len(3.2));
  // The clap: branches and leaves thrashing as they all push off at once.
  mix(b, rustle(r, 0.45, 2600, 1500, 3800), 0, 0.9, false);
  mix(b, rustle(r, 0.3, 1800, 900, 1800), len(0.02), 0.6, false);
  // Wingbeat trains, most in the first half second, each climbing away.
  for (let k = 0; k < 26; k++) {
    const start = Math.min(1.2, -Math.log(1 - r() * 0.95) * 0.22);
    const secs = r.range(0.9, 2.4);
    const w = wings(r, secs, r.range(7.5, 11.5), r.range(350, 550), r.range(900, 1500), r.range(0.6, 1.0), 0);
    mix(b, w, len(start), (k < 8 ? 0.55 : 0.4) * r.range(0.7, 1.0), false);
  }
  // Alarm calls, packed at the start and thinning out.
  for (let k = 0; k < 9; k++) {
    const start = Math.min(2.2, -Math.log(1 - r() * 0.95) * 0.45);
    mix(b, alarm(r), len(start), r.range(0.45, 0.8) * (1 - start / 3), false);
  }
  // Everything loud in the first half second, then thinner.
  for (let i = 0; i < b.length; i++) {
    const t = i / RATE;
    b[i] *= t < 0.5 ? 1 : Math.max(0.15, 1 - (t - 0.5) * 0.35);
  }
  // Feathers and air, not hiss: the top rolled off.
  filter(b, 'low', 6500, 0.7);
  filter(b, 'low', 6500, 0.7);
  return fadeEnds(normalise(b, -1), 0.002, 0.35);
}

function circle() {
  const r = rng(4404);
  const b = new Float32Array(len(8));
  for (let k = 0; k < 5; k++) {
    const w = wings(r, r.range(1.0, 2.0), r.range(5.5, 8), r.range(300, 450), r.range(500, 700), 0.2, 0.7);
    // The other way round too: coming nearer, then going.
    const back = wings(r, r.range(0.8, 1.6), r.range(5.5, 8), r.range(500, 700), r.range(300, 450), 0.7, 0.1);
    const at = len(r.range(0, 8));
    mix(b, w, at, 0.5, true);
    mix(b, back, at + w.length, 0.5, true);
  }
  mix(b, alarm(r), len(r.range(2, 3)), 0.35, true);
  mix(b, call(r, r.range(300, 360), 0.2, 0.18, 0.07, [[900, 2.4, 1], [1900, 3, 0.4]], 0.25, 0.01), len(r.range(5.5, 6.5)), 0.4, true);
  // Far away: the top rolled off.
  filter(b, 'low', 2400, 0.7);
  return normalise(b, -4);
}

function settle() {
  const r = rng(4505);
  const b = new Float32Array(len(1.6));
  for (let k = 0; k < 4; k++) {
    const w = wings(r, r.range(0.25, 0.4), r.range(9, 12), r.range(700, 900), r.range(400, 500), 0.7, 0.05);
    mix(b, w, len(k * 0.22 + r.range(0, 0.08)), 0.55, false);
    mix(b, rustle(r, 0.12, 500), len(k * 0.22 + 0.25), 0.35, false);
  }
  mix(b, chuckle(r, true), len(0.75), 0.9, false);
  mix(b, chuckle(r, true), len(1.1), 0.6, false);
  return fadeEnds(normalise(b, -3), 0.004, 0.12);
}

function wav(samples) {
  const data = Buffer.alloc(44 + samples.length * 2);
  data.write('RIFF', 0);
  data.writeUInt32LE(36 + samples.length * 2, 4);
  data.write('WAVEfmt ', 8);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(RATE, 24);
  data.writeUInt32LE(RATE * 2, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write('data', 36);
  data.writeUInt32LE(samples.length * 2, 40);
  for (let i = 0; i < samples.length; i++) data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, samples[i])) * 32000), 44 + i * 2);
  return data;
}

// ---- loudness (assets/sfx/MIX.md: V = -16.1 LUFS, every sound played at the voice's own -5 dB) ----

// ffmpeg's ebur128 on a file: integrated I, short-term max S, momentary max M, true peak TP.
function loudness(file) {
  const r = spawnSync(ffmpeg, ['-hide_banner', '-nostats', '-loglevel', 'verbose', '-i', file, '-af', 'ebur128=peak=true:framelog=verbose', '-f', 'null', '-'], { encoding: 'utf8', maxBuffer: 64 << 20 });
  if (r.error || r.status !== 0) throw new Error(`ffmpeg ebur128 failed: ${r.error?.message ?? r.stderr.slice(-500)}`);
  let S = -99, M = -99;
  for (const m of r.stderr.matchAll(/M:\s*(-?[\d.]+|-inf)\s+S:\s*(-?[\d.]+|-inf)/g)) {
    M = Math.max(M, Number(m[1]) || -99);
    S = Math.max(S, Number(m[2]) || -99);
  }
  const tail = r.stderr.slice(r.stderr.lastIndexOf('Summary:'));
  const I = Number((tail.match(/I:\s*(-?[\d.]+) LUFS/) || [])[1]);
  const TP = Number((tail.match(/Peak:\s*(-?[\d.]+) dBFS/) || [])[1]);
  return { I, S, M, TP };
}

// A look-ahead peak limiter (2 ms ahead, 80 ms release) holding sample peaks under `ceilDb`, then a fixed gain.
function limit(b, ceilDb) {
  const ceil = 10 ** (ceilDb / 20);
  const ahead = len(0.002);
  const rel = Math.exp(-1 / (0.08 * RATE));
  const need = new Float32Array(b.length);
  for (let i = 0; i < b.length; i++) need[i] = Math.min(1, ceil / Math.max(Math.abs(b[i]), 1e-9));
  // Each sample's gain is the least needed within the look-ahead, eased back up afterwards.
  const out = new Float32Array(b.length);
  let g = 1;
  for (let i = 0; i < b.length; i++) {
    let want = 1;
    for (let j = i; j < Math.min(b.length, i + ahead); j++) want = Math.min(want, need[j]);
    g = want < g ? want : want - (want - g) * rel;
    out[i] = b[i] * Math.min(g, need[i]);
  }
  return out;
}

// [file, metric, target LUFS, what it is]. Targets against V: idle a room tone made louder for this floor (V-8), stir
// an effect (V-6), the flush by short-term loudness at V-4.5 (an effect, well under the voice and inside the effect
// band the game's test measures; the Scare bus is the residents' own, so the birds stay off it; for anyone under the
// tree it never plays louder than its file), the circling an effect played 14 dB under in the game, settle V-8.
const TARGETS = {
  roost_idle: ['I', -24.1], roost_stir: ['I', -22.1], roost_flush: ['S', -20.6], roost_circle: ['I', -22.1], roost_settle: ['I', -24.1],
};
const TP_MAX = -1.5;

const SOUNDS = { roost_idle: idle, roost_stir: stir, roost_flush: flush, roost_circle: circle, roost_settle: settle };
mkdirSync(out, { recursive: true });
const tmp = mkdtempSync(join(tmpdir(), 'roost-'));
let total = 0;
const encode = (w, o) => {
  const r = spawnSync(ffmpeg, ['-hide_banner', '-nostats', '-loglevel', 'error', '-y', '-i', w, '-ac', '1', '-c:a', 'libvorbis', '-q:a', '5', '-map_metadata', '-1', '-fflags', '+bitexact', '-flags:a', '+bitexact', o], { encoding: 'utf8' });
  if (r.error || r.status !== 0) throw new Error(`ffmpeg failed for ${o}: ${r.error?.message ?? r.stderr}`);
};
for (const [name, make] of Object.entries(SOUNDS)) {
  let s = make();
  const [metric, target] = TARGETS[name];
  const w = join(tmp, `${name}.wav`);
  const o = join(out, `${name}.ogg`);
  let lim = 0;
  // Gain to the target, limiting the peaks first when the gain would push them past the ceiling; three rounds.
  for (let round = 0; round < 3; round++) {
    writeFileSync(w, wav(s));
    encode(w, o);
    const m = loudness(o);
    const gain = target - m[metric];
    const peakAfter = m.TP + gain;
    if (Math.abs(gain) < 0.15 && m.TP <= TP_MAX) break;
    if (peakAfter > TP_MAX - 0.3) {
      const before = s.reduce((a, v) => Math.max(a, Math.abs(v)), 0);
      s = limit(s, 20 * Math.log10(before) - (peakAfter - (TP_MAX - 0.5)));
      lim += peakAfter - (TP_MAX - 0.5);
    }
    const k = 10 ** (gain / 20);
    s = s.map((v) => v * k);
  }
  writeFileSync(w, wav(s));
  encode(w, o);
  const m = loudness(o);
  const size = statSync(o).size;
  total += size;
  console.log(`${name}.ogg  ${(s.length / RATE).toFixed(2)} s  ${(size / 1024).toFixed(1)} KB  I ${m.I.toFixed(1)}  S ${m.S.toFixed(1)}  M ${m.M.toFixed(1)}  TP ${m.TP.toFixed(1)}  (${metric} target ${target}, ${(m[metric] + 16.1 >= 0 ? '+' : '')}${(m[metric] + 16.1).toFixed(1)} to V; limited ${lim.toFixed(1)} dB)`);
}
rmSync(tmp, { recursive: true, force: true });
console.log(`total ${(total / 1024).toFixed(1)} KB in ${out}`);
