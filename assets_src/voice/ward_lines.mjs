// The Hanging Ward's five lift lines (Bella), mastered for the game the same way --publish masters every
// other line (ff.mjs normalise: -16 LUFS, true peak -1.5 dBTP, mono mp3), from take 1 of each line in
// assets_src/voice/takes/bella/ (the takes are on the owner's PC, not in git; ledger.json records each one).
// Writes godot/assets/ward/voice/bella/<id>.mp3, which client/ward/view.gd plays. Sends nothing anywhere.
//
//   node assets_src/voice/ward_lines.mjs
//
// The texts, as generated (eleven_v4, Bella, stability 0.35, similarity 0.75):
//   ward_lift_departed     "Your lift returns in ten minutes. Do enjoy the neighbourhood."
//   ward_lift_last_minute  "One minute until collection. Perhaps finish the viewing another day."
//   ward_lift_returned     "Your lift is here. Step aboard, please."
//   ward_lift_final_call   "Ten seconds to departure. Mind the doors."
//   ward_lift_closed       "Doors closed."
import { existsSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalise } from './ff.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
export const WARD_LINES = ['ward_lift_departed', 'ward_lift_last_minute', 'ward_lift_returned', 'ward_lift_final_call', 'ward_lift_closed'];
const out = path.join(ROOT, 'godot', 'assets', 'ward', 'voice', 'bella');
mkdirSync(out, { recursive: true });
let missing = 0;
for (const id of WARD_LINES) {
  const src = path.join(HERE, 'takes', 'bella', id, 'take-1.mp3');
  if (!existsSync(src)) {
    console.error(`${id}: no take at ${path.relative(ROOT, src)}`);
    missing++;
    continue;
  }
  const m = normalise(src, path.join(out, `${id}.mp3`));
  console.log(`${id}: ${m.duration.toFixed(2)} s  ${m.lufs.toFixed(1)} LUFS  peak ${m.truePeak.toFixed(1)} dBTP`);
}
process.exit(missing ? 1 : 0);
