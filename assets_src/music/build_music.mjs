// Rebuilds the game's five music tracks (godot/assets/music/*.ogg) from the owner's .wav files.
//   node assets_src/music/build_music.mjs [--inbox=<folder with the .wav files>] [--out=<folder>]
// The inbox defaults to assets_src/inbox/music/ (git-ignored: the owner's files stay on his PC).
// Each file is only decoded and re-encoded by ffmpeg (on PATH, or FFMPEG): nothing in it is run.
//
// Per track: leading and trailing silence trimmed (under -45 dB); for the four that loop, the last LOOP_XFADE
// seconds are cross-faded into the first ones so the end runs straight back into the start without a click;
// loudness made the same with ffmpeg's two-pass loudnorm (linear, integrated LUFS from TRACKS, true peak under
// -2 dBTP); stereo 44.1 kHz Ogg Vorbis at quality 4. The drone sits lower than the others (it is a bed).
// The game sets the loop flag in code (client/music.gd); the files carry no loop points of their own.
// Prints each file's measured loudness, true peak, length and size, and the total.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..', '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).slice(k.length + 3);
const inbox = resolve(arg('inbox', join(root, 'assets_src', 'inbox', 'music')));
const out = resolve(arg('out', join(root, 'godot', 'assets', 'music')));
const ffmpeg = process.env.FFMPEG || 'ffmpeg';

// [source file, output name, integrated LUFS, loops]
const TRACKS = [
  ['Abandoned Jingle.wav', 'abandoned_jingle', -20, true],   // 1: the start screen
  ['elevator muzak.wav', 'elevator_muzak', -20, true],       // 2: riding the lift
  ['wistful regret.wav', 'wistful_regret', -20, true],       // 3: the prison between runs
  ['sub-bass drone.wav', 'sub_bass_drone', -24, true],       // 4: the bed on a floor
  ['final stamp.wav', 'final_stamp', -20, false],            // 5: the end-of-run report, once
];
const TRUE_PEAK = -2.0;
const LOOP_XFADE = 3.0;
const QUALITY = 4;

function run(args) {
  const r = spawnSync(ffmpeg, ['-hide_banner', '-nostats', ...args], { encoding: 'utf8', maxBuffer: 64 << 20 });
  if (r.error) throw new Error(`ffmpeg did not start (${r.error.message}): install it or set FFMPEG`);
  if (r.status !== 0) throw new Error(`ffmpeg failed:\n${r.stderr.slice(-2000)}`);
  return r.stderr;
}

const trim = 'silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.02,'
  + 'areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.02,areverse,asetpts=N/SR/TB';

// The shaped track before loudness, as a filter graph to [s]. A loop reads the file twice ([0:a] and [1:a], the same
// trim on each): one asplit feeding both sides of acrossfade gives no samples at all in ffmpeg 7.1.
function shape(loops) {
  if (!loops) return `[0:a]${trim},afade=t=in:d=0.01,areverse,afade=t=in:d=0.05,areverse[s]`;
  return `[0:a]${trim},atrim=start=${LOOP_XFADE},asetpts=N/SR/TB[body];`
    + `[1:a]${trim},atrim=end=${LOOP_XFADE},asetpts=N/SR/TB[head];[body][head]acrossfade=d=${LOOP_XFADE}:c1=qsin:c2=qsin[s]`;
}

const inputs = (file, loops) => (loops ? ['-i', file, '-i', file] : ['-i', file]);

function measure(file, loops, graph) {
  const err = run([...inputs(file, loops), '-filter_complex', graph, '-map', '[o]', '-f', 'null', '-']);
  const j = err.slice(err.lastIndexOf('{'), err.lastIndexOf('}') + 1);
  return JSON.parse(j);
}

function loudness(file) {
  const err = run(['-i', file, '-af', 'ebur128=peak=true', '-f', 'null', '-']);
  const sum = err.slice(err.lastIndexOf('Summary:'));
  const num = (re) => Number((sum.match(re) || [])[1]);
  return { lufs: num(/I:\s+(-?[\d.]+) LUFS/), peak: num(/Peak:\s+(-?[\d.]+) dBFS/) };
}

function duration(file) {
  const r = spawnSync(ffmpeg.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1'), ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], { encoding: 'utf8' });
  return Number(String(r.stdout).trim());
}

mkdirSync(out, { recursive: true });
let total = 0;
for (const [src, name, lufs, loops] of TRACKS) {
  const file = join(inbox, src);
  if (!existsSync(file)) throw new Error(`missing ${file}`);
  const target = `I=${lufs}:TP=${TRUE_PEAK}:LRA=11`;
  const m = measure(file, loops, `${shape(loops)};[s]loudnorm=${target}:print_format=json[o]`);
  const norm = `loudnorm=${target}:linear=true:measured_I=${m.input_i}:measured_TP=${m.input_tp}`
    + `:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}:print_format=json`;
  const dest = join(out, `${name}.ogg`);
  const e2 = run(['-y', ...inputs(file, loops), '-filter_complex', `${shape(loops)};[s]${norm},aresample=44100[o]`, '-map', '[o]',
    '-ac', '2', '-ar', '44100', '-c:a', 'libvorbis', '-q:a', String(QUALITY), '-map_metadata', '-1', dest]);
  const kind = JSON.parse(e2.slice(e2.lastIndexOf('{'), e2.lastIndexOf('}') + 1)).normalization_type;
  const got = loudness(dest);
  const size = statSync(dest).size;
  total += size;
  console.log(`${name}.ogg  ${got.lufs.toFixed(1)} LUFS  true peak ${got.peak.toFixed(1)} dBTP  ${duration(dest).toFixed(1)} s  ${(size / 1048576).toFixed(2)} MB  ${loops ? 'loops' : 'once'}  (${kind})`);
}
console.log(`total ${(total / 1048576).toFixed(2)} MB in ${out}`);
