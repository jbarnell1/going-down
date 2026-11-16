// Debug minimap (?debug=1): a top-down picture of the player's current level drawn from the floor
// plan on a small 2D canvas. Each level is drawn once and cached; every update only blits it and
// draws the player arrow on top.

import { cellAt, hasDoor, isWalkable, roomIdAt, stairCells, type FloorPlan, type Level } from '../sim/floor';

const COLOURS: Record<string, string> = {
  corridor: '#c9d2ce',
  room: '#9aa6a1',
  landing: '#6fd18a',
  stair: '#e2b84b',
  atriumOpen: '#2d3a36',
};

export class Minimap {
  readonly canvas: HTMLCanvasElement;
  private readonly cache = new Map<Level, HTMLCanvasElement>();
  private readonly px: number;

  constructor(private readonly plan: FloorPlan, maxSize = 168) {
    this.px = Math.max(2, Math.floor(maxSize / Math.max(plan.width, plan.height)));
    this.canvas = document.createElement('canvas');
    this.canvas.id = 'minimap';
    this.canvas.width = plan.width * this.px;
    this.canvas.height = plan.height * this.px;
  }

  /**
   * Draws level `level` with the player at (x, z) metres facing `yaw` (radians, 0 = north/-z), and
   * the live entity if given: a square, filled white while the player can see it, red while unseen.
   * Dropped tapes are small yellow bars with a black edge.
   */
  update(
    level: Level,
    x: number,
    z: number,
    yaw: number,
    entity?: { level: Level; x: number; z: number; seen: boolean } | null,
    tapes: readonly { level: Level; x: number; z: number }[] = [],
  ): void {
    const g = this.canvas.getContext('2d');
    if (!g) return;
    g.clearRect(0, 0, this.canvas.width, this.canvas.height);
    g.drawImage(this.levelImage(level), 0, 0);
    const k = this.px / this.plan.cellSize;
    for (const t of tapes) {
      const tr = Math.max(2, this.px * 0.6);
      g.globalAlpha = t.level === level ? 1 : 0.4;
      g.fillStyle = '#ffd23a';
      g.strokeStyle = '#000';
      g.fillRect(t.x * k - tr, t.z * k - tr * 0.6, tr * 2, tr * 1.2);
      g.strokeRect(t.x * k - tr, t.z * k - tr * 0.6, tr * 2, tr * 1.2);
      g.globalAlpha = 1;
    }
    const cx = x * k;
    const cy = z * k;
    const fx = -Math.sin(yaw);
    const fy = -Math.cos(yaw);
    const r = Math.max(4, this.px * 1.4);
    g.fillStyle = '#ff3b6b';
    g.strokeStyle = '#000';
    g.lineWidth = 1;
    g.beginPath();
    g.moveTo(cx + fx * r, cy + fy * r);
    g.lineTo(cx - fx * r * 0.6 + fy * r * 0.6, cy - fy * r * 0.6 - fx * r * 0.6);
    g.lineTo(cx - fx * r * 0.25, cy - fy * r * 0.25);
    g.lineTo(cx - fx * r * 0.6 - fy * r * 0.6, cy - fy * r * 0.6 + fx * r * 0.6);
    g.closePath();
    g.fill();
    g.stroke();
    if (entity) {
      const ex = entity.x * k;
      const ey = entity.z * k;
      const er = Math.max(3, this.px);
      g.globalAlpha = entity.level === level ? 1 : 0.4;
      g.fillStyle = entity.seen ? '#ffffff' : '#ff2a1a';
      g.fillRect(ex - er, ey - er, er * 2, er * 2);
      g.strokeRect(ex - er, ey - er, er * 2, er * 2);
      g.globalAlpha = 1;
    }
  }

  private levelImage(level: Level): HTMLCanvasElement {
    const hit = this.cache.get(level);
    if (hit) return hit;
    const { plan, px } = this;
    const c = document.createElement('canvas');
    c.width = this.canvas.width;
    c.height = this.canvas.height;
    const g = c.getContext('2d');
    if (!g) return c;
    g.fillStyle = 'rgba(0, 0, 0, 0.35)';
    g.fillRect(0, 0, c.width, c.height);

    for (let y = 0; y < plan.height; y++) {
      for (let x = 0; x < plan.width; x++) {
        const kind = cellAt(plan, level, x, y);
        const colour = COLOURS[kind];
        if (!colour) continue;
        g.fillStyle = colour;
        g.fillRect(x * px, y * px, px, px);
      }
    }
    // Stairs on the upper level show where they arrive from below, faintly.
    if (level === 1) {
      g.fillStyle = 'rgba(226, 184, 75, 0.45)';
      for (const s of plan.stairs) for (const c2 of stairCells(s)) g.fillRect(c2.x * px, c2.y * px, px, px);
    }
    // Walls: a dark line between walkable neighbours in different spaces with no door between them.
    // Doors: a bright mark across the opening.
    const wall = (x: number, y: number, dx: number, dy: number, door: boolean): void => {
      g.fillStyle = door ? '#ffffff' : '#1d2422';
      if (dx === 1) g.fillRect((x + 1) * px - (door ? 1 : 0.5), y * px + (door ? px * 0.2 : 0), door ? 2 : 1, door ? px * 0.6 : px);
      else g.fillRect(x * px + (door ? px * 0.2 : 0), (y + 1) * px - (door ? 1 : 0.5), door ? px * 0.6 : px, door ? 2 : 1);
    };
    for (let y = 0; y < plan.height; y++) {
      for (let x = 0; x < plan.width; x++) {
        if (!isWalkable(plan, level, x, y) && cellAt(plan, level, x, y) !== 'stair') continue;
        for (const [dx, dy] of [[1, 0], [0, 1]] as const) {
          const nx = x + dx;
          const ny = y + dy;
          if (!isWalkable(plan, level, nx, ny)) continue;
          const door = hasDoor(plan, level, x, y, nx, ny);
          if (door) wall(x, y, dx, dy, true);
          else if (roomIdAt(plan, level, x, y) !== roomIdAt(plan, level, nx, ny)) wall(x, y, dx, dy, false);
        }
      }
    }
    // Where the entity starts.
    const e = plan.entityStart;
    if (e.level === level) {
      g.fillStyle = '#d0201c';
      g.beginPath();
      g.arc((e.x + 0.5) * px, (e.y + 0.5) * px, Math.max(2.5, px * 0.8), 0, Math.PI * 2);
      g.fill();
    }
    // The elevator landing gets an outline so it reads at a glance.
    const l = plan.landing;
    if (l.level === level) {
      g.strokeStyle = '#6fd18a';
      g.lineWidth = 1;
      g.strokeRect(l.x * px - 1.5, l.y * px - 1.5, px + 3, px + 3);
    }
    this.cache.set(level, c);
    return c;
  }
}
