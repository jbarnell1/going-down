// Copies the Godot client from spikes/godot-client into this project, so godot/ plays the game with
// the GDScript rules. Repeatable: run it again whenever the spike's client changes; it prints what
// changed and touches nothing that did not.
//
//   node godot/tools/sync_client.mjs            copy, prune files the spike no longer has, print changes
//   node godot/tools/sync_client.mjs --check    only report what would change (exit 1 if anything would)
//
// What goes where (the spike is not in git; everything here is):
//   game/scripts/*               -> godot/client/      res://scripts/ rewritten to res://client/
//   game/assets/**               -> godot/assets/      (with their .import files; the same res:// paths)
//   game/data/pixel_font.json    -> godot/data/
//   game/main.tscn, game/default_bus_layout.tres -> godot/   (res://scripts/ rewritten)
//   tools/playthrough.mjs, play_web.mjs, play_desktop.mjs, sound_web.mjs, serve.mjs, measure_web.mjs
//                                -> godot/tools/       (paths and default ports rewritten, see TOOL_REWRITES)
// Never written: godot/client/rules_bridge.gd (the GDScript bridge; the spike's own talks to
// TypeScript), host_rules.gd and pose.gd (its parts), and anything outside those folders. The
// project settings and export presets are kept in godot/project.godot and godot/export_presets.cfg
// by hand (see README.md): this script only warns when the spike's settings change.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const godot = resolve(here, '..');
const root = resolve(godot, '..');
const spike = join(root, 'spikes', 'godot-client');
const game = join(spike, 'game');
const check = process.argv.includes('--check');

/** Files in godot/client/ that belong to this project, not to the spike. */
const PROTECTED = new Set(['rules_bridge.gd', 'rules_bridge.gd.uid', 'host_rules.gd', 'host_rules.gd.uid', 'pose.gd', 'pose.gd.uid']);
/** Spike files that are not copied at all. */
const SKIP_SCRIPTS = new Set(['rules_bridge.gd', 'rules_bridge.gd.uid']);
/** Text files get their res:// paths rewritten; everything else is copied byte for byte. */
const TEXT = /\.(gd|gdshader|tscn|tres|json|import|cfg|uid|mjs|md|txt)$/;

/** Tool scripts: [from, to] text rewrites; each must apply (or the script says so). */
const TOOL_REWRITES = {
  'playthrough.mjs': [],
  'serve.mjs': [
    ["?? '../export/web'", "?? 'godot/export/web'"],
    ['?? 4431', '?? 4440'],
  ],
  'play_web.mjs': [
    ["'../../../node_modules/playwright'", "'../../node_modules/playwright'"],
    ['?? 4431', '?? 4440'],
    ["resolve(here, '../shots')", "resolve(here, '../export/shots')"],
  ],
  'sound_web.mjs': [
    ["'../../../node_modules/playwright'", "'../../node_modules/playwright'"],
    ['?? 4431', '?? 4440'],
  ],
  'play_desktop.mjs': [
    ["arg('port', 4461)", "arg('port', 4441)"],
    ["resolve(here, '../shots/desktop')", "resolve(here, '../export/shots/desktop')"],
  ],
  'measure_web.mjs': [
    ["'../../../node_modules/playwright'", "'../../node_modules/playwright'"],
    ['?? 4431', '?? 4440'],
    ["resolve(here, '../shots/web-metrics.json')", "resolve(here, '../export/shots/web-metrics.json')"],
  ],
};
const TOOL_HEADER = '// Copied from spikes/godot-client/tools by godot/tools/sync_client.mjs (paths adjusted). Edit it there, then re-sync.\n';

const changes = [];
const warnings = [];

function walk(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
}
const md5 = (b) => createHash('md5').update(b).digest('hex');
const rel = (p) => relative(root, p).split(sep).join('/');

/** Paths a public repository must never carry (absolute machine paths, user folders). */
function machinePaths(text) {
  return /\b[A-Za-z]:[\\/]|\/Users\/|\/home\/[a-z]/.test(text);
}

function put(dest, content) {
  const old = existsSync(dest) ? readFileSync(dest) : null;
  const buf = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
  if (old && md5(old) === md5(buf)) return false;
  changes.push(`${old ? 'updated' : 'added  '} ${rel(dest)}`);
  if (!check) {
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, buf);
  }
  return true;
}

function remove(dest) {
  changes.push(`removed ${rel(dest)}`);
  if (!check) rmSync(dest);
}

function rewriteRes(text) {
  return text.replaceAll('res://scripts/', 'res://client/');
}

function copyText(src, dest, transform = rewriteRes) {
  const text = transform(readFileSync(src, 'utf8'));
  if (machinePaths(text)) warnings.push(`${rel(src)} contains what looks like a machine path: check before committing`);
  put(dest, text);
}

function copyFile(src, dest) {
  if (TEXT.test(src)) copyText(src, dest);
  else put(dest, readFileSync(src));
}

/** Mirrors a folder: copies every file, removes files the source no longer has (except `keep`). */
function mirror(srcDir, destDir, { skip = new Set(), keep = new Set() } = {}) {
  const wanted = new Set();
  for (const src of walk(srcDir)) {
    const name = relative(srcDir, src);
    if (skip.has(name)) continue;
    const dest = join(destDir, name);
    wanted.add(dest);
    copyFile(src, dest);
  }
  for (const dest of walk(destDir)) {
    const name = relative(destDir, dest);
    if (!wanted.has(dest) && !keep.has(name)) remove(dest);
  }
}

if (!existsSync(game)) {
  console.error(`no client at ${rel(game)}`);
  process.exit(2);
}

mirror(join(game, 'scripts'), join(godot, 'client'), { skip: SKIP_SCRIPTS, keep: PROTECTED });
mirror(join(game, 'assets'), join(godot, 'assets'));
copyText(join(game, 'data', 'pixel_font.json'), join(godot, 'data', 'pixel_font.json'));
copyText(join(game, 'main.tscn'), join(godot, 'main.tscn'));
copyText(join(game, 'default_bus_layout.tres'), join(godot, 'default_bus_layout.tres'));

for (const [name, rewrites] of Object.entries(TOOL_REWRITES)) {
  const src = join(spike, 'tools', name);
  if (!existsSync(src)) {
    warnings.push(`spike tool ${name} is gone`);
    continue;
  }
  copyText(src, join(here, name), (text) => {
    let out = text;
    for (const [from, to] of rewrites) {
      if (!out.includes(from)) warnings.push(`${name}: expected text not found, not rewritten: ${from}`);
      out = out.replaceAll(from, to);
    }
    return TOOL_HEADER + out;
  });
}

// The spike's settings are merged by hand: say when they change (by hash of the files as merged).
const MERGED = { 'project.godot': 'b8e5ec8e2450f091cdb45a4a5741856b', 'export_presets.cfg': '364b70cf160a76241e4907c22db11f9d' };
for (const [name, hash] of Object.entries(MERGED)) {
  const now = md5(readFileSync(join(game, name)));
  if (now !== hash) warnings.push(`spike ${name} differs from the one merged into godot/ (hash ${now}): merge its settings by hand, then update MERGED in sync_client.mjs`);
}

// The client must not bring its own way to the rules.
for (const f of walk(join(godot, 'client'))) {
  if (f.endsWith('.gd') && /JavaScriptBridge\.eval\("GDRules|rules_node\.mjs|execute_with_pipe/.test(readFileSync(f, 'utf8')) && !check) {
    warnings.push(`${rel(f)} still talks to the TypeScript rules`);
  }
}

const stamp = new Date().toISOString();
console.log(`sync_client ${check ? '(check only) ' : ''}from ${rel(spike)} at ${stamp}`);
for (const c of changes) console.log(`  ${c}`);
console.log(changes.length === 0 ? '  nothing changed' : `  ${changes.length} file(s) ${check ? 'would change' : 'changed'}`);
for (const w of warnings) console.log(`  WARNING ${w}`);
if (!check && changes.some((c) => c.includes('godot/assets/'))) {
  console.log('  assets changed: the next `npm run godot:export` re-imports them (or run `node godot/tools/godot.mjs import`).');
}
process.exit(check && changes.length > 0 ? 1 : 0);
