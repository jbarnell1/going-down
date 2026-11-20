// The recovered tape (godot/assets/station/tape/crew23.ogv: 960 x 540 Theora, 24 fps, 51.5 s) is 6.9 MB, and video
// does not compress, so the browser build carries a lighter copy instead: crew23_web.ogv, 480 x 270, mono sound,
// the same length and frames (about 1.6 MB). export_presets.cfg leaves each copy out of the other build;
// client/reactor_screening.gd plays whichever is there. Needs ffmpeg on the PATH.
//
//   node assets_src/station/tape_web.mjs
//
// The full tape itself was rendered on 18 Nov in Blender from the players' own crewmate figure and rig (the four
// seats' faces from assets_src/station/draw_faces.py), with the announcer voice lines recorded in
// assets_src/voice/ledger.json (crew23_*) and silence between them; no sound effects.
import { execFileSync } from 'node:child_process';
import { statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const dir = path.join(ROOT, 'godot', 'assets', 'station', 'tape');
const full = path.join(dir, 'crew23.ogv');
const web = path.join(dir, 'crew23_web.ogv');
execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', full, '-vf', 'scale=480:270:flags=area',
  '-c:v', 'libtheora', '-q:v', '5', '-c:a', 'libvorbis', '-q:a', '2', '-ac', '1', web], { stdio: 'inherit' });
console.log(`${path.relative(ROOT, web)}: ${(statSync(web).size / 1048576).toFixed(2)} MB (full copy ${(statSync(full).size / 1048576).toFixed(2)} MB)`);
