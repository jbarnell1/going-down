// A quick approximation of the game's VHS tape look, so renders are judged the way players see them:
// brought down to the game's 480 px width, desaturated toward green-grey, slightly blurred, grained.
// Usage: node assets_src/blender/orderly/tape_look.mjs [renders dir]   (writes tape_<name>.png beside each)
import { readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const dir = process.argv[2] || path.resolve(HERE, "..", "..", "renders", "orderly");
const names = readdirSync(dir).filter((f) => f.endsWith(".png") && !f.startsWith("tape_") && !f.startsWith("pose_"));
for (const f of names) {
  const src = path.join(dir, f);
  const w = Number(execFileSync("magick", ["identify", "-format", "%w", src], { encoding: "utf8" }));
  const game = Math.min(w, 480);
  execFileSync("magick", [src, "-filter", "Box", "-resize", `${game}x`,
    "-modulate", "100,45", "-fill", "#6c8072", "-colorize", "16%",
    "-blur", "0x0.6", "-attenuate", "0.45", "+noise", "Gaussian",
    "-level", "4%,97%", "-filter", "Point", "-resize", `${(w / game) * 100}%`, "-strip",
    path.join(dir, "tape_" + f)]);
  console.log("tape_" + f);
}
