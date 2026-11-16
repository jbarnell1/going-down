// Print what the game depends on in a .glb: joint names, animation names and lengths, root transforms,
// materials (alpha mode, double-sided), image sizes, triangle count.
// Usage: node assets_src/blender/orderly/inspect_glb.mjs <file.glb> [--json out.json]
import { readFileSync, writeFileSync } from "node:fs";

const file = process.argv[2];
const buf = readFileSync(file);
const jsonLen = buf.readUInt32LE(12);
const gltf = JSON.parse(buf.subarray(20, 20 + jsonLen).toString("utf8"));
const binStart = 20 + jsonLen + 8;

function accessorMax(i) {
  const a = gltf.accessors[i];
  return a.max ? a.max[0] : null;
}

const skin = gltf.skins?.[0];
const joints = skin ? skin.joints.map((j) => gltf.nodes[j].name) : [];
const anims = (gltf.animations || []).map((a) => {
  let len = 0;
  for (const s of a.samplers) len = Math.max(len, accessorMax(s.input) ?? 0);
  return { name: a.name, seconds: Math.round(len * 10000) / 10000 };
});
const roots = gltf.scenes[gltf.scene || 0].nodes.map((n) => {
  const nd = gltf.nodes[n];
  return { name: nd.name, translation: nd.translation, rotation: nd.rotation, scale: nd.scale };
});
let tris = 0;
for (const m of gltf.meshes || [])
  for (const p of m.primitives) tris += p.indices != null ? gltf.accessors[p.indices].count / 3 : 0;
const mats = (gltf.materials || []).map((m) => ({
  name: m.name, alphaMode: m.alphaMode || "OPAQUE", alphaCutoff: m.alphaCutoff, doubleSided: !!m.doubleSided,
}));
const images = (gltf.images || []).map((im) => {
  const bv = gltf.bufferViews[im.bufferView];
  const off = binStart + (bv.byteOffset || 0);
  const png = buf.subarray(off, off + bv.byteLength);
  return { name: im.name, mime: im.mimeType, width: png.readUInt32BE(16), height: png.readUInt32BE(20) };
});
const samplers = gltf.samplers || [];
const out = { file, bytes: buf.length, joints, jointCount: joints.length, anims, roots, tris, mats, images, samplers,
  footL: joints.includes("foot.L") };
console.log(JSON.stringify(out, null, 1));
const j = process.argv.indexOf("--json");
if (j > 0) writeFileSync(process.argv[j + 1], JSON.stringify(out, null, 1));
