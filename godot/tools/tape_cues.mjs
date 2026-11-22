// Where the orientation tape cuts its pictures inside each beat's recording (docs/floors/story.md
// section 2, "Timing"). One recording per beat; the beat's shots share it. A shot's start is first
// estimated by its share of the beat's characters (as the design says), then moved to the nearest pause
// in the recording, so the picture changes between sentences and never in the middle of a word.
//
// Each voice reads at its own pace, so each has its own cues. beats.<b>.audio / cues / duration are the first
// voice's (Bella's; client/orientation_tape.gd falls back to them). Every other voice in the voice manifest whose
// folder has the beat's line gets beats.<b>.voices.<voice> = { audio, cues, duration }.
//
//   node godot/tools/tape_cues.mjs            measure and write the cues into godot/data/tapes.json
//   node godot/tools/tape_cues.mjs --check    measure and compare only; exits 1 if the file is out of date
//
// Needs ffmpeg and ffprobe on the PATH. Run it after any re-take of a tape line (assets_src/voice).
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GODOT = path.resolve(HERE, '..');
const DATA = path.join(GODOT, 'data', 'tapes.json');
const check = process.argv.includes('--check');

/** A pause is at least this long and this quiet. */
const PAUSE_S = 0.12;
const PAUSE_DB = -35;
/** The cut sits in the pause, but never more than this far before the next words start. */
const CUT_BEFORE_WORDS = 0.22;
/** A pause further than this from the estimate is not the sentence break. */
const SNAP_WINDOW = 1.0;
/** The longest a shot may run, and the lead before a beat's recording (client/orientation_tape.gd LEAD). */
const MAX_SHOT = 5.0;
const LEAD = 0.25;

function ff(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 16 << 20 });
  if (r.error) throw new Error(`${cmd}: ${r.error.message}`);
  return `${r.stdout ?? ''}${r.stderr ?? ''}`;
}

function measure(file) {
  const duration = Number(ff('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file]).trim());
  const out = ff('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-af', `silencedetect=noise=${PAUSE_DB}dB:d=${PAUSE_S}`, '-f', 'null', '-']);
  const pauses = [];
  let start = null;
  for (const line of out.split(/\r?\n/)) {
    const s = line.match(/silence_start: ([\d.]+)/);
    const e = line.match(/silence_end: ([\d.]+)/);
    if (s) start = Number(s[1]);
    if (e && start !== null) {
      pauses.push([start, Number(e[1])]);
      start = null;
    }
  }
  if (start !== null) pauses.push([start, duration]);
  return { duration, pauses };
}

const round = (x) => Math.round(x * 1000) / 1000;
const data = JSON.parse(readFileSync(DATA, 'utf8'));
const tape = data.orientation;
let stale = false;
const manifestFile = path.join(GODOT, 'assets', 'voice', 'manifest.json');
const voiceIds = existsSync(manifestFile) ? (JSON.parse(readFileSync(manifestFile, 'utf8')).voices ?? []).map((v) => v.id) : [];
const resFile = (res) => path.join(GODOT, res.replace('res://', ''));

/** The cue times of one beat's recording `audio` (res:// path). */
function cuesOf(b, shots, audio, who) {
  const file = resFile(audio);
  const { duration, pauses } = measure(file);
  // Speech runs from the end of any leading silence to the start of any trailing one.
  const t0 = pauses.length && pauses[0][0] < 0.02 ? pauses[0][1] : 0;
  const last = pauses.at(-1);
  const t1 = last && last[1] >= duration - 0.02 ? last[0] : duration;
  const inner = pauses.filter((p) => p[0] > t0 && p[1] < t1);
  const text = shots.map((s) => s.subtitle).join(' ');
  const cues = [0];
  let at = 0;
  let used = -1;
  for (let i = 1; i < shots.length; i++) {
    at += shots[i - 1].subtitle.length + 1;
    const est = t0 + (at / text.length) * (t1 - t0);
    let best = -1;
    for (let k = used + 1; k < inner.length; k++) {
      const mid = (inner[k][0] + inner[k][1]) / 2;
      if (Math.abs(mid - est) <= SNAP_WINDOW && (best < 0 || Math.abs(mid - est) < Math.abs((inner[best][0] + inner[best][1]) / 2 - est))) best = k;
    }
    let cut = est;
    if (best >= 0) {
      const [s, e] = inner[best];
      cut = Math.max((s + e) / 2, e - CUT_BEFORE_WORDS);
      // A shot is at most MAX_SHOT long (story.md: "clamped to 2 to 5 s"): when the usual place in the pause
      // would make the shot before it longer, cut earlier, but never before the pause starts.
      const most = cues.at(-1) + MAX_SHOT - (i === 1 ? LEAD : 0);
      if (cut > most) cut = Math.max(s, most);
      used = best;
    } else {
      console.warn(`  ${b} ${who}: no pause near shot ${shots[i].n} (estimate ${est.toFixed(2)} s); cutting on the estimate`);
    }
    cues.push(round(cut));
  }
  const lens = cues.map((c, i) => (i + 1 < cues.length ? cues[i + 1] : duration) - c);
  console.log(`beat ${b} ${who}: ${duration.toFixed(2)} s, target ${shots.reduce((n, s) => n + s.target, 0)} s; shots ${shots.map((s, i) => `${s.n}=${lens[i].toFixed(2)}`).join(' ')}`);
  return { cues, duration: round(duration) };
}

for (const [b, beat] of Object.entries(tape.beats)) {
  const shots = tape.shots.filter((s) => s.beat === b);
  // The first voice: its own fields, in place (Bella's, unchanged by the other voices).
  const first = beat.audio.match(/assets\/voice\/([^/]+)\//)?.[1] ?? '';
  const got = cuesOf(b, shots, beat.audio, first);
  if (JSON.stringify(beat.cues) !== JSON.stringify(got.cues) || beat.duration !== got.duration) stale = true;
  beat.cues = got.cues;
  beat.duration = got.duration;
  // Every other voice with this beat's line.
  const voices = {};
  for (const v of voiceIds) {
    if (v === first) continue;
    const audio = `res://assets/voice/${v}/${beat.line}.mp3`;
    if (!existsSync(resFile(audio))) continue;
    voices[v] = { audio, ...cuesOf(b, shots, audio, v) };
  }
  if (JSON.stringify(beat.voices ?? {}) !== JSON.stringify(voices)) stale = true;
  if (Object.keys(voices).length) beat.voices = voices;
  else delete beat.voices;
}
if (check) {
  if (stale) {
    console.error('godot/data/tapes.json cues are out of date: run node godot/tools/tape_cues.mjs');
    process.exit(1);
  }
  console.log('cues up to date');
} else {
  writeFileSync(DATA, JSON.stringify(data, null, 2) + '\n');
  console.log(`wrote ${path.relative(path.resolve(GODOT, '..'), DATA)}`);
}
