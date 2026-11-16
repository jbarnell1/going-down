// Game textures from Google's Gemini image model, inside a strict budget.
//
//   node assets_src/textures/generate.mjs --list-models          list image-capable models (costs nothing)
//   node assets_src/textures/generate.mjs <id> [<id> ...]        generate (or reuse from cache) and post-process
//   node assets_src/textures/generate.mjs --post <id>            redo only the post-processing from the raw file
//   node assets_src/textures/generate.mjs --status               budget and ledger summary
//
// The API key is read at run time from the file named by the environment variable GD_GEMINI_KEY_FILE.
// It is sent only in the x-goog-api-key header and is never printed, logged or written anywhere.
// Every paid request is written to ledger.json; a request that would pass the task budget is refused.
// Results are cached by a hash of (full prompt + model + size): the same picture is never paid for twice.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const RAW = path.join(HERE, "raw");
const CHECK = path.join(HERE, "check");
const OUT = path.join(ROOT, "public", "assets", "textures");
const LEDGER = path.join(HERE, "ledger.json");
const API = "https://generativelanguage.googleapis.com/v1beta";

const cfg = JSON.parse(readFileSync(path.join(HERE, "requests.json"), "utf8"));
const MODEL = cfg.model;
// Prepended to every prompt so all textures belong to one world.
const STYLE = cfg.style;

function loadLedger() {
  if (existsSync(LEDGER)) return JSON.parse(readFileSync(LEDGER, "utf8"));
  return { budget_usd: cfg.budget.task_usd, max_images: cfg.budget.max_images, model: MODEL,
    price_note: cfg.budget.price_note, spent_usd: 0, images: 0, entries: [] };
}
function saveLedger(l) {
  l.spent_usd = Math.round(l.entries.reduce((s, e) => s + (e.cost_usd || 0), 0) * 10000) / 10000;
  l.images = l.entries.filter((e) => e.kind === "image").length;
  writeFileSync(LEDGER, JSON.stringify(l, null, 1) + "\n");
}

function readKey() {
  const f = process.env.GD_GEMINI_KEY_FILE;
  if (!f) throw new Error("GD_GEMINI_KEY_FILE is not set; stopping.");
  if (!existsSync(f)) throw new Error("the key file named by GD_GEMINI_KEY_FILE does not exist; stopping.");
  const k = readFileSync(f, "utf8").trim();
  if (!k) throw new Error("the key file is empty; stopping.");
  return k;
}

async function apiError(res) {
  let msg = "";
  try {
    const j = await res.json();
    msg = j?.error?.message || JSON.stringify(j).slice(0, 400);
  } catch { msg = "(no JSON body)"; }
  return `HTTP ${res.status}: ${msg}`;
}

async function listModels() {
  const key = readKey();
  const out = [];
  let token = "";
  do {
    const res = await fetch(`${API}/models?pageSize=200${token ? "&pageToken=" + encodeURIComponent(token) : ""}`,
      { headers: { "x-goog-api-key": key } });
    if (!res.ok) throw new Error("model list failed: " + (await apiError(res)));
    const j = await res.json();
    out.push(...(j.models || []));
    token = j.nextPageToken || "";
  } while (token);
  const img = out.filter((m) => /image/i.test(m.name) || /image/i.test(m.description || ""));
  for (const m of img)
    console.log(`${m.name}\t${m.displayName}\t${(m.supportedGenerationMethods || []).join(",")}\t${(m.description || "").slice(0, 140)}`);
  console.log(`(${out.length} models listed, ${img.length} mention images)`);
  const l = loadLedger();
  l.entries.push({ kind: "model_list", time: new Date().toISOString(), cost_usd: 0,
    image_models: img.map((m) => m.name) });
  saveLedger(l);
}

function fullPrompt(r) {
  let p = STYLE + "\n\nSubject: " + r.prompt;
  if (r.tile) p += "\n" + cfg.tile_clause;
  if (r.alpha_key) p += "\n" + cfg.alpha_clause.replace("{KEY}", r.alpha_key_name || r.alpha_key);
  if (r.alpha_from_white) p += "\n" + cfg.alpha_white_clause;
  if (r.palette) p +="\nPalette: " + r.palette;
  return p;
}

function hashOf(prompt, model, size) {
  return createHash("sha256").update(JSON.stringify([prompt, model, size])).digest("hex").slice(0, 16);
}

async function generate(r) {
  const prompt = fullPrompt(r);
  const size = r.gen_size || "1K";
  const h = hashOf(prompt, MODEL, size);
  const cached = findRaw(r.id, h);
  if (cached) {
    console.log(`[cache] ${r.id}: ${path.relative(ROOT, cached)} (no request sent)`);
    return cached;
  }
  const l = loadLedger();
  const price = cfg.budget.est_usd_per_image[size];
  if (price == null) throw new Error(`no price for size ${size}`);
  if (l.spent_usd + price > l.budget_usd + 1e-9)
    throw new Error(`REFUSED: ${r.id} would bring the estimate to $${(l.spent_usd + price).toFixed(3)}, over the $${l.budget_usd} task budget`);
  if (l.images + 1 > l.max_images)
    throw new Error(`REFUSED: ${r.id} would be image ${l.images + 1}, over the ${l.max_images}-image limit`);
  const key = readKey();
  const body = {
    contents: [{ role: "user", parts: [{ text: prompt }] }],
    generationConfig: { responseModalities: ["IMAGE"], imageConfig: { aspectRatio: r.aspect || "1:1", imageSize: size } },
  };
  const t0 = Date.now();
  const res = await fetch(`${API}/models/${MODEL}:generateContent`, {
    method: "POST", headers: { "x-goog-api-key": key, "content-type": "application/json" }, body: JSON.stringify(body),
  });
  const entry = { kind: "image", id: r.id, purpose: r.purpose, model: MODEL, size, hash: h,
    time: new Date().toISOString(), cost_usd: price, ms: 0 };
  if (!res.ok) {
    const err = await apiError(res);
    // a refused request is normally not billed; record it at zero and stop
    entry.kind = "refused"; entry.cost_usd = 0; entry.error = err;
    l.entries.push(entry); saveLedger(l);
    throw new Error(`API refused ${r.id}: ${err}`);
  }
  const j = await res.json();
  entry.ms = Date.now() - t0;
  entry.usage = j.usageMetadata || null;
  const parts = j.candidates?.[0]?.content?.parts || [];
  const imgPart = parts.find((p) => p.inlineData?.data);
  if (!imgPart) {
    entry.kind = "image"; entry.note = "no image returned: " + (j.candidates?.[0]?.finishReason || "?") +
      " " + parts.map((p) => p.text || "").join(" ").slice(0, 200);
    l.entries.push(entry); saveLedger(l);
    throw new Error(`${r.id}: ${entry.note}`);
  }
  mkdirSync(RAW, { recursive: true });
  const bytes = Buffer.from(imgPart.inlineData.data, "base64");
  const mime = imgPart.inlineData.mimeType || "image/png";
  // keep the source exactly as it came (this model returns JPEG at 1K)
  const rawPath = path.join(RAW, `${r.id}__${h}.${mime === "image/jpeg" ? "jpg" : "png"}`);
  writeFileSync(rawPath, bytes);
  entry.raw = path.relative(ROOT, rawPath).replaceAll("\\", "/");
  entry.mime = mime;
  l.entries.push(entry);
  saveLedger(l);
  const after = loadLedger();
  console.log(`[paid] ${r.id}: ~$${price} (${entry.ms} ms) usage=${JSON.stringify(entry.usage)} -> ${entry.raw}`);
  console.log(`[ledger] $${after.spent_usd.toFixed(3)} of $${after.budget_usd}, ${after.images} of ${after.max_images} images`);
  return rawPath;
}

function findRaw(id, h) {
  for (const ext of ["jpg", "png"]) {
    const p = path.join(RAW, `${id}__${h}.${ext}`);
    if (existsSync(p)) return p;
  }
  return null;
}

function latestRaw(r) {
  const h = hashOf(fullPrompt(r), MODEL, r.gen_size || "1K");
  const p = findRaw(r.id, h);
  if (!p) throw new Error(`${r.id}: no raw file for the current prompt (${h})`);
  return p;
}

// How visible the wrap-around seam is: mean difference across the wrap edge (last column -> first,
// last row -> first) divided by the mean difference between two neighbouring interior columns/rows.
// Around 1 means no visible seam; 2 or more is a seam you can see.
function mae(img, g1, g2) {
  const r = spawnSync("magick", ["compare", "-metric", "MAE", "(", img, "-crop", g1, "+repage", ")",
    "(", img, "-crop", g2, "+repage", ")", "null:"], { encoding: "utf8" });
  const m = /\(([\d.e+-]+)\)/.exec(r.stderr || "");
  return m ? parseFloat(m[1]) : NaN;
}
function seamScore(img) {
  const [w, h] = execFileSync("magick", ["identify", "-format", "%w %h", img], { encoding: "utf8" }).split(" ").map(Number);
  const cx = mae(img, `1x${h}+${w - 1}+0`, `1x${h}+0+0`) / mae(img, `1x${h}+${w >> 1}+0`, `1x${h}+${(w >> 1) + 1}+0`);
  const cy = mae(img, `${w}x1+0+${h - 1}`, `${w}x1+0+0`) / mae(img, `${w}x1+0+${h >> 1}`, `${w}x1+0+${(h >> 1) + 1}`);
  return `x ${cx.toFixed(2)}, y ${cy.toFixed(2)} (1 = invisible)`;
}

function magick(args) {
  execFileSync("magick", args, { stdio: ["ignore", "inherit", "inherit"] });
}

// Post-processing: (shave borders) -> (flatten lighting) -> (key out alpha) -> (make tileable) ->
// downscale -> ordered-dither palette -> strip metadata. Writes public/assets/textures/<id>.png and a
// 2x2 check image for tileable textures under assets_src/textures/check/.
function post(r, rawPath) {
  mkdirSync(OUT, { recursive: true });
  mkdirSync(CHECK, { recursive: true });
  const tmp = path.join(CHECK, `${r.id}__work.png`);
  const P = r.post || {};
  const W = 1024;
  const [SW, SH] = Array.isArray(r.size) ? r.size : [r.size, r.size];
  const SZ = `${SW}x${SH}!`;
  const a = [rawPath, "-alpha", "off", "-colorspace", "sRGB"];
  if (P.crop) a.push("-gravity", "center", "-crop", P.crop, "+repage");
  if (P.shave) a.push("-shave", `${P.shave}%x${P.shave}%`, "+repage");
  a.push("-resize", P.keep_aspect ? `${W}x${W}` : `${W}x${W}!`);
  if (P.flatten) {
    // remove broad lighting gradients: divide by a heavy blur, then restore the mean
    //   out = image * mean(image) / blur(image), per channel
    a.push("(", "-clone", "0", "-blur", `0x${P.flatten}`, ")", "(", "-clone", "0", "-scale", "1x1!", "-scale", `${W}x${W}!`, ")",
      "-fx", "u[0]*u[2]/max(u[1],0.02)");
  }
  if (P.level) a.push("-level", P.level);
  if (P.modulate) a.push("-modulate", P.modulate);
  a.push(tmp);
  magick(a);
  if (r.tile) console.log(`[seam] before: ${seamScore(tmp)}`);

  // Tiling: offset-and-blend. B is A rolled by half, so B's seams are in the middle and its edges wrap
  // cleanly. Keep A in the middle and B in a band along the edges (width set by tile_band, a fraction
  // of the image), cross-fading between them. tile "x" blends only left/right. tile_method "none"
  // keeps the image as it is (when the model already made it seamless; the seam score says so).
  if (r.tile && P.tile_method !== "none") {
    const band = P.tile_band || 0.12;
    const k = (1 / band).toFixed(3);
    const xOnly = r.tile === "x";
    const mask = path.join(CHECK, `_mask${xOnly ? "x" : ""}${W}_${band}.png`);
    if (!existsSync(mask))
      magick(["-size", `${W}x${W}`, "xc:", "-fx",
        xOnly ? `min(1,max(0,(0.5-abs(i/w-0.5))*${k}-0.3))`
          : `min(1,max(0,(0.5-max(abs(i/w-0.5),abs(j/h-0.5)))*${k}-0.3))`, mask]);
    magick([tmp, "(", "+clone", "-roll", xOnly ? `+${W / 2}+0` : `+${W / 2}+${W / 2}`, ")", "-swap", "0,1",
      mask, "-compose", "Over", "-composite", tmp]);
    console.log(`[seam] after blend: ${seamScore(tmp)}`);
  }

  const final = path.join(OUT, `${r.id}.png`);
  const b = [tmp];
  let alphaMask = null;
  if (r.alpha_from_white) {
    // a stain drawn on white paper: anything darker than the paper by more than `white_cut` is kept
    alphaMask = path.join(CHECK, `${r.id}__alpha.png`);
    magick([tmp, "-colorspace", "Gray", "-negate", "-blur", "0x1.5", "-threshold", `${P.white_cut || 14}%`,
      "-filter", "Box", "-resize", SZ, "-threshold", "50%", alphaMask]);
    // and the kept colour is pushed back toward full strength, since it was printed on white
    b.push("-level", P.white_level || "0%,90%");
  } else if (r.alpha_key) {
    // anything close to the key colour becomes a hole; the mask is made at full size then box-filtered
    // down and hard-thresholded, so the game can use alpha test (no half-transparent pixels)
    alphaMask = path.join(CHECK, `${r.id}__alpha.png`);
    // (non-key pixels go white first, then the key goes black, so dark paint is never mistaken for a hole)
    magick([tmp, "-fuzz", `${P.key_fuzz || 30}%`, "-fill", "white", "+opaque", r.alpha_key,
      "-fill", "black", "-opaque", r.alpha_key, "+fuzz", "-colorspace", "Gray",
      ...(P.erode ? ["-morphology", "Erode", `Disk:${P.erode}`] : []),
      "-filter", "Box", "-resize", SZ, "-threshold", "50%", alphaMask]);
  }
  // paint the cut-out colour dark before shrinking, so the edges of holes darken instead of turning pink
  if (r.alpha_key) b.push("-fuzz", `${(P.key_fuzz || 30) + 8}%`, "-fill", P.key_fill || "#3a3226", "-opaque", r.alpha_key, "+fuzz");
  if (r.tile) b.push("-virtual-pixel", "tile");
  b.push("-filter", P.filter || "Box", "-resize", SZ);
  if (P.sharpen) b.push("-unsharp", P.sharpen);
  // small palette: ordered dither to a few levels per channel, then cap the colour count without dither
  if (P.dither !== "none") b.push("-ordered-dither", P.dither || "o4x4,16,16,14");
  b.push("+dither", "-colors", String(P.colors || 32));
  if (alphaMask) b.push(alphaMask, "-alpha", "off", "-compose", "CopyOpacity", "-composite");
  b.push("-strip", "-define", "png:exclude-chunks=date,time", alphaMask ? `PNG32:${final}` : `PNG24:${final}`);
  magick(b);
  if (r.tile) {
    const chk = path.join(CHECK, `${r.id}_2x2.png`);
    // tile the final texture 2x2 and enlarge it with hard pixels, to look for seams
    magick([final, "(", "+clone", ")", "+append", "(", "+clone", ")", "-append", "-filter", "Point",
      "-resize", "200%", chk]);
    console.log(`[check] ${path.relative(ROOT, chk)}`);
  }
  if (alphaMask) {
    const chk = path.join(CHECK, `${r.id}_on_grey.png`);
    magick(["-size", `${SW}x${SH}`, "xc:#5a5a5a", final, "-compose", "Over", "-composite", "-filter", "Point",
      "-resize", "200%", chk]);
    console.log(`[check] ${path.relative(ROOT, chk)}`);
  }
  console.log(`[out] ${path.relative(ROOT, final)} ${SW}x${SH}`);
}

async function main() {
  const args = process.argv.slice(2);
  if (args[0] === "--list-models") return listModels();
  if (args[0] === "--status") {
    const l = loadLedger();
    console.log(`model ${MODEL}; spent ~$${l.spent_usd} of $${l.budget_usd}; ${l.images} of ${l.max_images} images`);
    return;
  }
  const postOnly = args[0] === "--post";
  const ids = postOnly ? args.slice(1) : args;
  for (const id of ids) {
    const r = cfg.requests.find((q) => q.id === id);
    if (!r) throw new Error(`unknown request id ${id}`);
    const raw = postOnly ? latestRaw(r) : await generate(r);
    post(r, raw);
  }
}

main().catch((e) => {
  console.error("[stop] " + e.message);
  process.exit(1);
});
