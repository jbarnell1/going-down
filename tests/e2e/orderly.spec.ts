import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

const SHOTS = 'test-results/shots';

async function settle(page: Page, frames = 4): Promise<void> {
  const start = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((n) => (window as any).__gd.frames >= n, start + frames);
}

test('the Orderly stands in the alpha clinic: far, mid, near and beside a door', async ({ page }) => {
  test.setTimeout(120_000);
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));

  await page.goto('/?seed=alpha&depth=1&preview=orderly&anim=idle');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.entity?.loaded() === true, undefined, { timeout: 30_000 });
  mkdirSync(SHOTS, { recursive: true });

  // The model loaded with its named animations.
  const anims: string[] = await page.evaluate(() => (window as any).__gd.entity.animations());
  expect(anims.sort()).toEqual(['duck', 'idle', 'reach', 'still', 'walk']);

  // An animation is playing: a bone moves between two moments of the walk.
  await page.evaluate(() => (window as any).__gd.entity.play('walk'));
  await settle(page, 2);
  const a = await page.evaluate(() => (window as any).__gd.entity.bone('foot.L'));
  await page.waitForTimeout(400);
  await settle(page, 2);
  const b = await page.evaluate(() => (window as any).__gd.entity.bone('foot.L'));
  expect(a).not.toBeNull();
  const moved = Math.hypot(b[0] - a[0], b[1] - a[1], b[2] - a[2]);
  expect(moved).toBeGreaterThan(0.02);
  expect(await page.evaluate(() => (window as any).__gd.entity.current())).toBe('walk');
  await page.evaluate(() => (window as any).__gd.entity.play('idle'));

  // Where to stand, from the plan the game is running.
  const setup = await page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const S = plan.cellSize;
    const at = (level: number, x: number, y: number): string =>
      x < 0 || y < 0 || x >= plan.width || y >= plan.height ? 'void' : plan.cells[level][y * plan.width + x];
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    // The Orderly at the x2 end, facing back along the corridor; the player k cells toward x1.
    const ord = { x: s.x2, y: s.y2, yaw: yawToward(ux, uy) };
    const view = (metres: number) => {
      const k = Math.min(s.length - 1, Math.max(1, Math.round(metres / S)));
      return { cell: { x: s.x2 + ux * k, y: s.y2 + uy * k }, yaw: yawToward(-ux, -uy), metres: k * S };
    };
    // A door with a corridor on one side and corridor running along the wall on that side.
    let door: any = null;
    for (const d of plan.doors) {
      if (d.level !== 0) continue;
      const sides: [number, number, number, number][] = [[d.ax, d.ay, d.bx, d.by], [d.bx, d.by, d.ax, d.ay]];
      for (const [cx, cy, ox, oy] of sides) {
        if (at(0, cx, cy) !== 'corridor') continue;
        const nx = ox - cx;
        const ny = oy - cy;
        const along: [number, number][] = [[ny, nx], [-ny, -nx]];
        for (const [px, py] of along) {
          if ([1, 2, 3].every((k) => at(0, cx + px * k, cy + py * k) === 'corridor')) door = door ?? { cx, cy, nx, ny, px, py };
        }
      }
    }
    if (door) {
      // Beside the frame: 0.55 m toward the door wall and 0.85 m along it from the opening.
      const fx = (door.cx + 0.5) * S + door.nx * 0.55 + door.px * 0.85;
      const fz = (door.cy + 0.5) * S + door.ny * 0.55 + door.py * 0.85;
      const pc = { x: door.cx + door.px * 3, y: door.cy + door.py * 3 };
      const pxw = (pc.x + 0.5) * S;
      const pzw = (pc.y + 0.5) * S;
      door.fig = { x: fx, z: fz, yaw: yawToward(pxw - fx, pzw - fz) };
      door.player = { cell: pc, yaw: yawToward(fx - pxw - door.nx * 0.5, fz - pzw - door.ny * 0.5) };
    }
    return { line: s, ord, far: view(40), mid: view(15), near: view(4), door };
  });

  await page.evaluate(({ x, y, yaw }) => (window as any).__gd.entity.placeCell(0, x, y, yaw), setup.ord);
  for (const [name, v] of [['20-orderly-far', setup.far], ['21-orderly-mid', setup.mid], ['22-orderly-near', setup.near]] as const) {
    await page.evaluate(({ c, yaw }) => {
      (window as any).__gd.teleport(0, c.x, c.y, yaw);
      (window as any).__gd.look(yaw, 0);
    }, { c: v.cell, yaw: v.yaw });
    await settle(page, 6);
    await page.screenshot({ path: `${SHOTS}/${name}.png` });
    console.log(`${name}: ${v.metres} m`);
  }

  expect(setup.door).not.toBeNull();
  await page.evaluate(({ fig, player }) => {
    const gd = (window as any).__gd;
    gd.entity.placeAt(fig.x, 0, fig.z, fig.yaw);
    gd.teleport(0, player.cell.x, player.cell.y, player.yaw);
    gd.look(player.yaw, 6);
  }, setup.door);
  await settle(page, 6);
  await page.screenshot({ path: `${SHOTS}/23-orderly-door.png` });

  await settle(page, 120);
  const ms = await page.evaluate(() => (window as any).__gd.frameMs() as number);
  console.log(`frameMs=${ms.toFixed(2)} corridor=${setup.line.length} cells far=${setup.far.metres} m`);
  expect(errors).toEqual([]);
});
