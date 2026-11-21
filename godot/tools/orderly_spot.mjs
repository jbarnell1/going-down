// Where the scripted runs stand to watch the Orderly (tools/playthrough.mjs, tools/sound_web.mjs).
// Since the Orderly fix (OR2, sim/orderly_fix.gd, the owner's 20 Nov playtest: "spawning in the clean part of the
// hospital, not the dirty part") the Orderly starts at a seeded cell deep in the dirty part, not at the plan's
// entityStart, and that cell is not always on a listed sightline. So: where it really is (the rules' body, from the
// state), and the cells to try watching it from, best first. The rules decide whether it is seen from there.

/** The cell the Orderly stands on now, from a state reply (2 m cells). */
export const orderlyCell = (s, S = 2) => ({ level: s.orderly.level, x: Math.floor(s.orderly.x / S), y: Math.floor(s.orderly.z / S) });

/**
 * Cells on `es`'s level to watch it from: first the cell down the longest listed sightline through it, at most
 * `far` metres off (the old way); then every walkable cell `near` to `far` metres off with an open straight line
 * of cells to it, those in its row or column first, the farthest first.
 */
export function watchSpots(plan, es, { near = 4, far = 10, S = 2 } = {}) {
  const W = plan.width;
  const H = plan.height;
  const out = [];
  const along = plan.sightlines
    .filter((sl) => sl.level === es.level && ((sl.x1 === sl.x2 && sl.x1 === es.x && es.y >= Math.min(sl.y1, sl.y2) && es.y <= Math.max(sl.y1, sl.y2)) || (sl.y1 === sl.y2 && sl.y1 === es.y && es.x >= Math.min(sl.x1, sl.x2) && es.x <= Math.max(sl.x1, sl.x2))))
    .sort((a, b) => b.length - a.length)[0];
  if (along) {
    const cellsOn = [];
    for (let x = Math.min(along.x1, along.x2); x <= Math.max(along.x1, along.x2); x++)
      for (let y = Math.min(along.y1, along.y2); y <= Math.max(along.y1, along.y2); y++) cellsOn.push({ x, y, d: Math.hypot(x - es.x, y - es.y) * S, how: 'sightline' });
    const best = cellsOn.filter((c) => c.d <= far).sort((a, b) => b.d - a.d)[0];
    if (best) out.push(best);
  }
  const walkable = (x, y) => x >= 0 && y >= 0 && x < W && y < H && ['corridor', 'room', 'landing', 'atriumOpen'].includes(plan.cells[es.level][y * W + x]) && plan.liftDist[es.level * W * H + y * W + x] >= 0;
  const more = [];
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const d = Math.hypot(x - es.x, y - es.y) * S;
    if (d < near || d > far || !walkable(x, y)) continue;
    const n = Math.ceil(d / S) * 2;
    let clear = true;
    for (let i = 1; i < n && clear; i++) clear = walkable(Math.floor(es.x + 0.5 + ((x - es.x) * i) / n), Math.floor(es.y + 0.5 + ((y - es.y) * i) / n));
    if (clear) more.push({ x, y, d, how: 'open line', inLine: x === es.x || y === es.y });
  }
  more.sort((a, b) => (b.inLine - a.inLine) || (b.d - a.d));
  for (const c of more) if (!out.some((p) => p.x === c.x && p.y === c.y)) out.push(c);
  return out;
}
