// Rebuilds the failing ceiling strip's sounds (godot/assets/sfx/dangers/failing_lights/*.wav) from nothing:
// every sample is arithmetic here (sines, a seeded noise, one-pole filters), written straight to 16-bit WAV.
// Nothing is downloaded, no tool or service is used.
//   node assets_src/sfx/dangers/failing_lights.mjs [--out=<folder>]
//
// The strip is an old magnetic-ballast fitting going bad. Its sounds, in the order a cycle plays them:
//   buzz.wav    the loop while it is lit: the ballast's 120 Hz hum with a loose rattle and a few crackles (4 s,
//               seamless: every partial is a whole number of cycles in 4 s, the noise is cross-faded round).
//   wind.wav    the warning: the hum goes rough, sags and stutters faster and faster (2 s; the screen starts it
//               part way in so that it always ends as the strip goes out, whatever the warning's length).
//   out.wav     the strip dropping out: the starter's tink and a dull thump as the tube dies, the hum ringing off.
//   dark.wav    the loop while it is out: only the starter trying, a tick and a faint fizz now and then (2 s).
//   strike.wav  the strip catching again: two ticks 0.35 s apart (each with the screen's flash), the tube striking
//               with a plink 0.35 s later, the hum swelling back.
// Loudness: each file is scaled so the base's simple loudness (client/dangers/kind_view.gd measure(): the RMS of
// the samples above -50 dBFS) sits in the middle of its category's band (kind_view.gd BANDS, from MIX.md against the
// voice): the hum a room tone (Ambience bus, V-10), the warning, drop and catch effects (V-6), the dark's ticks an
// ambience bed (V-14); sample peaks never over -1.5 dBFS. The game plays each at Sfx.BASE_DB (kind_view.gd).
// Prints each file's loudness, peak and size.
import { mkdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..', '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).slice(k.length + 3);
const out = resolve(arg('out', join(root, 'godot', 'assets', 'sfx', 'dangers', 'failing_lights')));
const SR = 22050;
const TAU = Math.PI * 2;

// A small seeded generator (mulberry32), so every rebuild makes the same samples.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function noise(n, seed) {
  const r = rng(seed);
  const a = new Float64Array(n);
  for (let i = 0; i < n; i++) a[i] = r() * 2 - 1;
  return a;
}

// One-pole low-pass (cutoff in Hz) and high-pass made from it.
function lowpass(x, hz) {
  const k = 1 - Math.exp((-TAU * hz) / SR);
  const y = new Float64Array(x.length);
  let s = 0;
  for (let i = 0; i < x.length; i++) {
    s += k * (x[i] - s);
    y[i] = s;
  }
  return y;
}
function highpass(x, hz) {
  const l = lowpass(x, hz);
  return x.map((v, i) => v - l[i]);
}
function band(x, lo, hi) {
  return lowpass(highpass(x, lo), hi);
}

// The ballast's hum at a moment, given its phase (cycles of the fundamental) and how rough it is (0 clean, 1 bad).
function hum(phase, rough) {
  const p = TAU * phase;
  return 0.34 * Math.sin(p) + 0.26 * Math.sin(2 * p + 0.4) + 0.13 * Math.sin(3 * p + 1.1)
    + 0.08 * Math.sin(4 * p + 2.0) + (0.04 + 0.06 * rough) * Math.sin(5 * p + 0.3)
    + 0.05 * rough * Math.sin(7 * p + 1.7);
}

// The lamination rattle: noise gated into a sharp pulse twice a cycle of the hum.
function rattleGate(phase, sharp) {
  return Math.pow(Math.abs(Math.sin(TAU * phase)), sharp);
}

// A click: a few milliseconds of bright noise with a short ring.
function addClick(buf, at, amp, ringHz, seed) {
  const n = Math.floor(0.06 * SR);
  const nz = highpass(noise(n, seed), 1800);
  const i0 = Math.floor(at * SR);
  for (let i = 0; i < n && i0 + i < buf.length; i++) {
    const t = i / SR;
    buf[i0 + i] += amp * (0.8 * nz[i] * Math.exp(-t / 0.0025) + 0.5 * Math.sin(TAU * ringHz * t) * Math.exp(-t / 0.009));
  }
}

function buzz() {
  const len = 4.0;
  const n = Math.round(len * SR);
  const x = new Float64Array(n);
  // Rattle noise made longer than the loop and cross-faded round its end, so the loop has no seam.
  const fade = Math.floor(0.25 * SR);
  const raw = band(noise(n + fade, 11), 400, 5200);
  const nz = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    nz[i] = raw[i];
    if (i < fade) {
      const w = i / fade;
      nz[i] = raw[i] * w + raw[n + i] * (1 - w);
    }
  }
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const ph = 120 * t;
    const wob = 1 + 0.08 * Math.sin(TAU * 0.5 * t) + 0.04 * Math.sin(TAU * 1.25 * t + 1);
    x[i] = wob * (0.8 * hum(ph, 0.25) + 0.22 * nz[i] * rattleGate(ph, 10));
  }
  // A few crackles of the bad contact (inside the loop, away from its seam).
  for (const [at, a] of [[0.92, 0.35], [2.31, 0.22], [2.36, 0.3], [3.41, 0.25]]) addClick(x, at, a, 2700, Math.floor(at * 100));
  return x;
}

function wind() {
  const len = 2.0;
  const n = Math.round(len * SR);
  const x = new Float64Array(n);
  const nz = band(noise(n, 23), 300, 6000);
  let ph = 0;
  let wph = 0;
  let chop = 0;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const u = t / len;
    const f = 120 * (1 - 0.42 * u * u);
    ph += f / SR;
    // A thin whine falling under the hum, as the choke strains.
    wph += (3100 - 1900 * u) / SR;
    // The stutter: the hum chopped faster and deeper as it goes.
    const rate = 5 + 19 * u * u;
    chop += rate / SR;
    const gate = 1 - (0.15 + 0.75 * u) * (((chop % 1) < 0.35 + 0.25 * (1 - u)) ? 0 : 1);
    const swell = 0.85 + 0.35 * Math.sin(Math.PI * Math.min(1, u * 1.3));
    const rough = 0.25 + 0.75 * u;
    x[i] = gate * swell * (0.8 * hum(ph, rough) + (0.2 + 0.35 * u) * nz[i] * rattleGate(ph, 8 - 5 * u))
      + 0.035 * u * Math.sin(TAU * wph);
  }
  for (const [at, a] of [[0.55, 0.2], [1.12, 0.25], [1.5, 0.3], [1.71, 0.35], [1.86, 0.4]]) addClick(x, at, a, 2500, Math.floor(at * 100) + 3);
  // Short fade at the very end: the drop's own sound takes over.
  const f = Math.floor(0.03 * SR);
  for (let i = 0; i < f; i++) x[n - 1 - i] *= i / f;
  return x;
}

function drop() {
  const len = 0.8;
  const n = Math.round(len * SR);
  const x = new Float64Array(n);
  const nz = lowpass(noise(n, 31), 900);
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    // The starter's tink, the tube's dull thump, and the hum ringing off.
    const tink = 0.14 * (Math.sin(TAU * 3150 * t) + 0.6 * Math.sin(TAU * 4720 * t) + 0.35 * Math.sin(TAU * 6230 * t)) * Math.exp(-t / 0.02);
    const thump = 0.55 * Math.sin(TAU * (58 - 18 * t) * t) * Math.exp(-t / 0.09) + 0.5 * nz[i] * Math.exp(-t / 0.035);
    const ring = 0.35 * hum(70 * t, 0.6) * Math.exp(-t / 0.16);
    x[i] = tink + thump + ring;
  }
  addClick(x, 0.0, 0.18, 3000, 77);
  return x;
}

function dark() {
  const len = 2.0;
  const n = Math.round(len * SR);
  const x = new Float64Array(n);
  const fz = band(noise(n, 41), 900, 3200);
  for (const at of [0.35, 1.05, 1.62]) {
    addClick(x, at, 0.32, 2350, Math.floor(at * 100) + 9);
    // The starter's glow: a faint fizz just after the tick.
    const i0 = Math.floor((at + 0.012) * SR);
    for (let i = 0; i < 0.09 * SR && i0 + i < n; i++) {
      const t = i / SR;
      x[i0 + i] += 0.07 * fz[i0 + i] * Math.sin(Math.PI * t / 0.09);
    }
  }
  return x;
}

function strike() {
  const len = 1.5;
  const n = Math.round(len * SR);
  const x = new Float64Array(n);
  const nz = band(noise(n, 53), 400, 5200);
  // Two ticks 0.35 s apart (the screen flashes with each), then the strike 0.35 s after the second.
  for (const [at, a] of [[0.0, 0.4], [0.35, 0.45]]) addClick(x, at, a, 2350, Math.floor(at * 100) + 5);
  const on = 0.7;
  for (let i = Math.floor(on * SR); i < n; i++) {
    const t = i / SR - on;
    const plink = 0.3 * (Math.sin(TAU * 880 * t) + 0.5 * Math.sin(TAU * 2210 * t)) * Math.exp(-t / 0.045);
    const thump = 0.4 * Math.sin(TAU * 62 * t) * Math.exp(-t / 0.07);
    // The hum swells back to the loop's own level (the loop takes over at the end).
    const ph = 120 * (i / SR);
    const rise = Math.min(1, t / 0.12) * (1 + 0.35 * Math.exp(-t / 0.25));
    const tail = i > n - 0.15 * SR ? (n - i) / (0.15 * SR) : 1;
    x[i] += plink + thump + tail * rise * (0.8 * hum(ph, 0.45) + 0.25 * nz[i] * rattleGate(ph, 10));
  }
  return x;
}

// The base's simple loudness of samples (kind_view.gd measure()): the RMS in dBFS of the samples above -50 dBFS.
function loudness(s) {
  const floor = Math.pow(10, -50 / 20);
  let sum = 0, n = 0;
  for (const v of s) if (Math.abs(v) >= floor) { sum += v * v; n++; }
  return n ? 10 * Math.log10(sum / n) : -Infinity;
}

function peakDb(s) {
  let p = 1e-12;
  for (const v of s) p = Math.max(p, Math.abs(v));
  return 20 * Math.log10(p);
}

// Scaled so its loudness is `target` dBFS, unless that would put a sample over PEAK dBFS (then the peak decides).
const PEAK = -1.5;
function level(samples, target) {
  // Normalise first so the -50 dBFS floor of the loudness measure is judged on the final scale (two passes).
  let s = samples;
  for (let pass = 0; pass < 3; pass++) {
    const g = Math.min(Math.pow(10, (target - loudness(s)) / 20), Math.pow(10, (PEAK - peakDb(s)) / 20));
    s = s.map((v) => v * g);
  }
  return s;
}

function wav(samples) {
  const b = Buffer.alloc(44 + samples.length * 2);
  b.write('RIFF', 0);
  b.writeUInt32LE(36 + samples.length * 2, 4);
  b.write('WAVEfmt ', 8);
  b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20);
  b.writeUInt16LE(1, 22);
  b.writeUInt32LE(SR, 24);
  b.writeUInt32LE(SR * 2, 28);
  b.writeUInt16LE(2, 32);
  b.writeUInt16LE(16, 34);
  b.write('data', 36);
  b.writeUInt32LE(samples.length * 2, 40);
  for (let i = 0; i < samples.length; i++) b.writeInt16LE(Math.round(Math.max(-1, Math.min(1, samples[i])) * 32767), 44 + i * 2);
  return b;
}

// [name, maker, category, target loudness dBFS: the middle of kind_view.gd BANDS[category]]
const SOUNDS = [
  ['buzz', buzz, 'room', -26.1],
  ['wind', wind, 'effect', -22.1],
  ['out', drop, 'effect', -22.1],
  ['dark', dark, 'ambience', -30.1],
  ['strike', strike, 'effect', -22.1],
];

mkdirSync(out, { recursive: true });
for (const [name, make, cat, target] of SOUNDS) {
  const s = level(Array.from(make()), target);
  const dst = join(out, `${name}.wav`);
  writeFileSync(dst, wav(s));
  console.log(`${name}.wav  ${statSync(dst).size} bytes  ${cat}: loudness ${loudness(s).toFixed(1)} dBFS (target ${target}), peak ${peakDb(s).toFixed(1)} dBFS`);
}
