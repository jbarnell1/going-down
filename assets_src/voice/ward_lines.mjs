// The Hanging Ward's lift lines, in every voice the game ships (Bella and Brian), mastered for the game the same
// way --publish masters every other line (ff.mjs normalise: -16 LUFS, true peak -1.5 dBTP, mono mp3), from take 1
// of each line in assets_src/voice/takes/<voice>/ (the takes are on the owner's PC, not in git; ledger.json records
// each one). Writes godot/assets/ward/voice/<voice>/<id>.mp3, which client/announcer.gd ward_line plays in the
// player's chosen voice (voice_path). The Ward's call station, web and left-behind lines (lines.json group ward2) are
// published by generate.mjs into godot/assets/voice/<voice>/; they are copied beside the lift lines unchanged.
// Sends nothing anywhere.
//
//   node assets_src/voice/ward_lines.mjs
//
// The texts, as generated (eleven_v4, stability 0.35, similarity 0.75; Bella and Brian alike):
//   ward_lift_departed     "Your lift returns in ten minutes. Do enjoy the neighbourhood."
//   ward_lift_last_minute  "One minute until collection. Perhaps finish the viewing another day."
//   ward_lift_returned     "Your lift is here. Step aboard, please."
//   ward_lift_final_call   "Ten seconds to departure. Mind the doors."
//   ward_lift_closed       "Doors closed."
import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalise } from './ff.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
export const WARD_LINES = ['ward_lift_departed', 'ward_lift_last_minute', 'ward_lift_returned', 'ward_lift_final_call', 'ward_lift_closed'];
/** The Ward's other spoken lines, already published per voice in godot/assets/voice/<voice>/. */
export const WARD_PUBLISHED = ['ward_station', 'ward_called', 'ward_hung', 'ward_cut', 'ward_left_behind'];
export const WARD_VOICES = ['bella', 'brian'];
let missing = 0;
for (const voice of WARD_VOICES) {
  const out = path.join(ROOT, 'godot', 'assets', 'ward', 'voice', voice);
  mkdirSync(out, { recursive: true });
  for (const id of WARD_LINES) {
    const src = path.join(HERE, 'takes', voice, id, 'take-1.mp3');
    if (!existsSync(src)) {
      console.error(`${voice} ${id}: no take at ${path.relative(ROOT, src)}`);
      missing++;
      continue;
    }
    const m = normalise(src, path.join(out, `${id}.mp3`));
    console.log(`${voice} ${id}: ${m.duration.toFixed(2)} s  ${m.lufs.toFixed(1)} LUFS  peak ${m.truePeak.toFixed(1)} dBTP`);
  }
  for (const id of WARD_PUBLISHED) {
    const src = path.join(ROOT, 'godot', 'assets', 'voice', voice, `${id}.mp3`);
    if (!existsSync(src)) {
      console.error(`${voice} ${id}: not published at ${path.relative(ROOT, src)}`);
      missing++;
      continue;
    }
    copyFileSync(src, path.join(out, `${id}.mp3`));
    console.log(`${voice} ${id}: copied from godot/assets/voice/${voice}`);
  }
}
process.exit(missing ? 1 : 0);
