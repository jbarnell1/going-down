// ffmpeg helpers shared by generate.mjs and check.mjs: loudness, true peak, sample peak and duration
// of an audio file, and two-pass loudness normalisation to an mp3.
import { execFileSync, spawnSync } from 'node:child_process';

export const TARGET_LUFS = -16;
export const TARGET_TP = -1.5;

function ffmpeg(args) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-nostats', ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.error) throw new Error(`ffmpeg could not run: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`ffmpeg failed (${r.status}): ${(r.stderr ?? '').split('\n').slice(-4).join(' ')}`);
  return r.stderr ?? '';
}

/** Integrated loudness (LUFS), true peak (dBTP), sample peak (dBFS) and duration (s). */
export function measure(file) {
  const ebu = ffmpeg(['-i', file, '-af', 'ebur128=peak=true+sample', '-f', 'null', '-']);
  const summary = ebu.slice(ebu.lastIndexOf('Summary:'));
  const num = (re) => {
    const m = summary.match(re);
    return m ? Number(m[1]) : NaN;
  };
  const lufs = num(/I:\s+(-?[\d.]+|-inf) LUFS/);
  const truePeak = num(/True peak:\s+Peak:\s+(-?[\d.]+|-inf) dBFS/);
  const samplePeak = num(/Sample peak:\s+Peak:\s+(-?[\d.]+|-inf) dBFS/);
  const out = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', file], { encoding: 'utf8' });
  return { lufs, truePeak, samplePeak, duration: Number(out.trim()) };
}

/** Two-pass loudnorm to TARGET_LUFS, then a plain gain trim if the result is still off by more than 0.3 LU. */
export function normalise(src, dst) {
  const lnBase = `loudnorm=I=${TARGET_LUFS}:TP=${TARGET_TP}:LRA=11`;
  const p1 = ffmpeg(['-i', src, '-af', `${lnBase}:print_format=json`, '-f', 'null', '-']);
  const json = JSON.parse(p1.slice(p1.lastIndexOf('{'), p1.lastIndexOf('}') + 1));
  const ln = `${lnBase}:measured_I=${json.input_i}:measured_TP=${json.input_tp}:measured_LRA=${json.input_lra}:measured_thresh=${json.input_thresh}:offset=${json.target_offset}:linear=true`;
  const enc = ['-ar', '44100', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '128k', '-y', dst];
  ffmpeg(['-i', src, '-af', ln, ...enc]);
  let m = measure(dst);
  // Done when the loudness is on target and the encoded true peak is within the check's -1 dBTP.
  const done = (x) => Math.abs(x.lufs - TARGET_LUFS) <= 0.3 && x.truePeak <= -1;
  if (done(m)) return m;
  // loudnorm on short speech can land short of the target (its linear mode will not push past the
  // peak limit, and it measures differently from ebur128). Fall back to a plain gain from the source
  // with a limiter, corrected against the measured result. A sharp attack can still overshoot the
  // limiter once encoded (hint_play_no_run_1 measured -0.6 dBTP): then the limit comes down 1 dB a pass.
  const s = measure(src);
  let gain = TARGET_LUFS - s.lufs;
  let tp = TARGET_TP;
  for (let i = 0; i < 6; i++) {
    const limit = 10 ** (tp / 20);
    ffmpeg(['-i', src, '-af', `volume=${gain.toFixed(2)}dB,alimiter=limit=${limit.toFixed(4)}:attack=1:release=50:level=false`, ...enc]);
    m = measure(dst);
    if (done(m)) break;
    if (m.truePeak > -1) tp -= 1;
    else gain += TARGET_LUFS - m.lufs;
  }
  return m;
}
