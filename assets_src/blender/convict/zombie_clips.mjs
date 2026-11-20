// The four on the Reactor's floor crawl and run with two Mixamo clips the owner downloaded ("Zombie Crawl",
// "Zombie Running"), retargeted onto the players' own crew rig by build_zombie_clips.py. Mixamo's terms allow its
// animations in a game but not the raw files by themselves (CREDITS.md, assets_src/inbox/README.md), so, exactly as
// with godot/assets/entities/crewmate.glb, only a game model with the clips baked in is published:
// godot/assets/station/crew_zombie.glb is the crewmate figure (its mesh, skin and skeleton from crewmate.glb, no
// textures: the game dresses the figure from crewmate.glb itself) carrying only "zombie_crawl" and "zombie_run".
// client/station_crew_view.gd reads the two clips from it; without the file the four use the rig's own crawl and run.
//
//   node assets_src/blender/convict/zombie_clips.mjs [retargeted.glb]
//
// The retargeted clips come from build_zombie_clips.py's export (default assets_src/inbox/crew-zombie-actions.glb,
// not in git). Every channel's node must match a crewmate node by name with the same rest pose (checked).
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const BASE = path.join(ROOT, 'godot', 'assets', 'entities', 'crewmate.glb');
const BAKED = process.argv[2] ?? path.join(ROOT, 'assets_src', 'inbox', 'crew-zombie-actions.glb');
const OUT = path.join(ROOT, 'godot', 'assets', 'station', 'crew_zombie.glb');
export const CLIPS = ['zombie_crawl', 'zombie_run'];

function readGlb(file) {
  const glb = readFileSync(file);
  assert.equal(glb.readUInt32LE(0), 0x46546c67, `${file} is not a glb`);
  const jsonSize = glb.readUInt32LE(12);
  const json = JSON.parse(glb.toString('utf8', 20, 20 + jsonSize));
  const length = glb.readUInt32LE(20 + jsonSize);
  assert.equal(json.buffers.length, 1);
  return { json, bin: glb.subarray(28 + jsonSize, 28 + jsonSize + length) };
}

const base = readGlb(BASE);
const baked = readGlb(BAKED);
const out = {
  asset: { version: '2.0', generator: 'assets_src/blender/convict/zombie_clips.mjs' },
  scene: base.json.scene ?? 0,
  scenes: base.json.scenes,
  nodes: base.json.nodes,
  skins: [],
  meshes: [],
  materials: (base.json.materials ?? []).map((m) => {
    const pbr = { ...(m.pbrMetallicRoughness ?? {}) };
    delete pbr.baseColorTexture;
    delete pbr.metallicRoughnessTexture;
    return { name: m.name, pbrMetallicRoughness: pbr, ...(m.alphaMode ? { alphaMode: m.alphaMode } : {}), ...(m.doubleSided ? { doubleSided: true } : {}) };
  }),
  accessors: [],
  bufferViews: [],
  buffers: [{ byteLength: 0 }],
  animations: [],
};
const chunks = [];
let bytes = 0;
const viewMemo = new Map();
function copyView(src, index) {
  const key = `${src === base ? 'b' : 'z'}${index}`;
  if (viewMemo.has(key)) return viewMemo.get(key);
  const view = src.json.bufferViews[index];
  const pad = (4 - (bytes % 4)) % 4;
  if (pad) { chunks.push(Buffer.alloc(pad)); bytes += pad; }
  const start = view.byteOffset ?? 0;
  chunks.push(src.bin.subarray(start, start + view.byteLength));
  const copy = { buffer: 0, byteOffset: bytes, byteLength: view.byteLength };
  if (view.byteStride) copy.byteStride = view.byteStride;
  if (view.target) copy.target = view.target;
  out.bufferViews.push(copy);
  bytes += view.byteLength;
  viewMemo.set(key, out.bufferViews.length - 1);
  return out.bufferViews.length - 1;
}
const accMemo = new Map();
function copyAccessor(src, index) {
  const key = `${src === base ? 'b' : 'z'}${index}`;
  if (accMemo.has(key)) return accMemo.get(key);
  const a = src.json.accessors[index];
  assert(!a.sparse, 'sparse accessors are not expected');
  out.accessors.push({ ...a, bufferView: copyView(src, a.bufferView) });
  accMemo.set(key, out.accessors.length - 1);
  return out.accessors.length - 1;
}
// The figure: every mesh and skin of crewmate.glb, its geometry copied as it is.
for (const mesh of base.json.meshes) {
  out.meshes.push({
    name: mesh.name,
    primitives: mesh.primitives.map((p) => ({
      ...p,
      attributes: Object.fromEntries(Object.entries(p.attributes).map(([k, v]) => [k, copyAccessor(base, v)])),
      ...(p.indices !== undefined ? { indices: copyAccessor(base, p.indices) } : {}),
      ...(p.targets ? { targets: p.targets.map((t) => Object.fromEntries(Object.entries(t).map(([k, v]) => [k, copyAccessor(base, v)]))) } : {}),
    })),
  });
}
for (const skin of base.json.skins ?? []) {
  out.skins.push({ ...skin, ...(skin.inverseBindMatrices !== undefined ? { inverseBindMatrices: copyAccessor(base, skin.inverseBindMatrices) } : {}) });
}
// The two clips, each channel moved onto the crewmate node of the same name (whose rest pose must agree).
function nodeFor(bakedIndex) {
  const source = baked.json.nodes[bakedIndex];
  const matches = base.json.nodes.filter((n) => n.name === source.name);
  assert.equal(matches.length, 1, `one crewmate node named ${source.name}`);
  const target = matches[0];
  for (const [prop, fallback] of [['translation', [0, 0, 0]], ['rotation', [0, 0, 0, 1]], ['scale', [1, 1, 1]]]) {
    const s = source[prop] ?? fallback;
    const d = target[prop] ?? fallback;
    const sign = prop === 'rotation' && s.reduce((sum, n, i) => sum + n * d[i], 0) < 0 ? -1 : 1;
    assert(s.every((v, i) => Math.abs(v * sign - d[i]) < 0.0001), `rest pose differs on ${source.name} ${prop}`);
  }
  return base.json.nodes.indexOf(target);
}
for (const name of CLIPS) {
  const clip = baked.json.animations.find((a) => a.name === name);
  assert(clip, `the retargeted export has ${name}`);
  // Rotations for every bone, and the hips' position (the moving clips' travel is already taken out).
  const channels = clip.channels.filter(({ target }) => target.path === 'rotation' ||
    (target.path === 'translation' && baked.json.nodes[target.node].name === 'Hips'));
  assert(channels.length >= 20, `${name} has its bone channels`);
  out.animations.push({
    name,
    channels: channels.map(({ target }, i) => ({ sampler: i, target: { ...target, node: nodeFor(target.node) } })),
    samplers: channels.map(({ sampler }) => {
      const s = clip.samplers[sampler];
      return { ...s, input: copyAccessor(baked, s.input), output: copyAccessor(baked, s.output) };
    }),
  });
}
out.buffers[0].byteLength = bytes;

function chunk(type, payload, padByte) {
  const pad = (4 - (payload.length % 4)) % 4;
  const header = Buffer.alloc(8);
  header.writeUInt32LE(payload.length + pad, 0);
  header.writeUInt32LE(type, 4);
  return Buffer.concat([header, payload, Buffer.alloc(pad, padByte)]);
}
const json = chunk(0x4e4f534a, Buffer.from(JSON.stringify(out)), 0x20);
const bin = chunk(0x004e4942, Buffer.concat(chunks), 0);
const header = Buffer.alloc(12);
header.writeUInt32LE(0x46546c67, 0);
header.writeUInt32LE(2, 4);
header.writeUInt32LE(12 + json.length + bin.length, 8);
mkdirSync(path.dirname(OUT), { recursive: true });
writeFileSync(OUT, Buffer.concat([header, json, bin]));
const check = readGlb(OUT);
assert.deepEqual(check.json.animations.map((a) => a.name), CLIPS);
assert.deepEqual(check.json.nodes, base.json.nodes);
console.log(`${path.relative(ROOT, OUT)}: the crewmate figure with ${CLIPS.join(' and ')}, ${(12 + json.length + bin.length) / 1024 | 0} KB`);
