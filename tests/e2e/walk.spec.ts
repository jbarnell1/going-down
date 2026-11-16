import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

const SHOTS = 'test-results/shots';

type Cell = { level: number; x: number; y: number };

/** Waits until the game has drawn a few more frames, so a screenshot shows the latest camera. */
async function settle(page: Page, frames = 4): Promise<void> {
  const start = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((n) => (window as any).__gd.frames >= n, start + frames);
}

async function walkTo(page: Page, c: Cell): Promise<void> {
  await page.evaluate(({ level, x, y }) => (window as any).__gd.walkTo(level, x, y), c);
  const p = await page.evaluate(() => (window as any).__gd.player());
  expect({ level: p.level, x: p.cx, y: p.cy }).toEqual({ level: c.level, x: c.x, y: c.y });
}

async function look(page: Page, yaw: number, pitch: number): Promise<void> {
  await page.evaluate(([y, p]) => (window as any).__gd.look(y, p), [yaw, pitch] as const);
  await settle(page);
}

test('one player walks the alpha clinic from the landing to the balcony', async ({ page }) => {
  test.setTimeout(180_000);
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));

  await page.goto('/?seed=alpha&depth=1&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await settle(page, 10);
  mkdirSync(SHOTS, { recursive: true });

  // Where to go, worked out from the plan the game is actually running.
  const route = await page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const at = (level: number, x: number, y: number): string =>
      x < 0 || y < 0 || x >= plan.width || y >= plan.height ? 'void' : plan.cells[level][y * plan.width + x];
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;

    // Longest level-0 sightline: stand at one end, face the other.
    const lines = plan.sightlines.filter((s: any) => s.level === 0).sort((a: any, b: any) => b.length - a.length);
    const s = lines[0];
    const corridor = { cell: { level: 0, x: s.x1, y: s.y1 }, yaw: yawToward(s.x2 - s.x1, s.y2 - s.y1), length: s.length };

    // Atrium: near one corner, looking up towards the far corner so two balcony sides and the
    // full two-storey height are in view.
    const a = plan.rooms.find((r: any) => r.kind === 'atrium');
    const long = a.h >= a.w;
    const below = { cell: { level: 0, x: a.x + 1, y: a.y + a.h - 2 }, yaw: yawToward(a.w - 3, -(a.h - 3)) };

    // Balcony: the upper corridor cell beside the opening closest to the middle of a long side.
    let best: any = null;
    const mx = a.x + (a.w - 1) / 2;
    const my = a.y + (a.h - 1) / 2;
    for (let y = 0; y < plan.height; y++) {
      for (let x = 0; x < plan.width; x++) {
        if (at(1, x, y) !== 'corridor') continue;
        for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
          if (at(1, x + dx, y + dy) !== 'atriumOpen') continue;
          // Prefer looking across the short axis (towards the far long side) and the middle of the run.
          const across = long ? dx !== 0 : dy !== 0;
          const score = (across ? 0 : 100) + Math.abs(long ? y - my : x - mx);
          // Turned 30 degrees off square, so the shot runs along the opening as well as down into it.
          if (!best || score < best.score) best = { score, cell: { level: 1, x, y }, yaw: yawToward(dx, dy) + 30, dx, dy };
        }
      }
    }
    // The first stair: the cell at its foot (level 0) and the cell off its top (level 1).
    const st = plan.stairs[0];
    const v = { n: [0, -1], e: [1, 0], s: [0, 1], w: [-1, 0] }[st.dir as 'n' | 'e' | 's' | 'w'] as [number, number];
    const stair = {
      bottom: { level: 0, x: st.x - v[0], y: st.y - v[1] },
      top: { level: 1, x: st.x + v[0] * st.length, y: st.y + v[1] * st.length },
      upYaw: yawToward(v[0], v[1]),
    };
    return { corridor, below, balcony: best, stair, landing: plan.landing };
  });

  // 1. The landing, as the player first sees it.
  const start = await page.evaluate(() => (window as any).__gd.player());
  expect({ level: start.level, x: start.cx, y: start.cy }).toEqual({ level: 0, x: route.landing.x, y: route.landing.y });
  await page.screenshot({ path: `${SHOTS}/10-landing.png` });
  // Review view: two cells into the lobby, turned round to face the elevator and its floor marking.
  const fwd = [Math.round(-Math.sin((start.yaw * Math.PI) / 180)), Math.round(-Math.cos((start.yaw * Math.PI) / 180))] as const;
  await walkTo(page, { level: 0, x: route.landing.x + 2 * fwd[0], y: route.landing.y + 2 * fwd[1] });
  await look(page, start.yaw + 180, -8);
  await page.screenshot({ path: `${SHOTS}/16-elevator.png` });

  // 2. Down the longest corridor.
  await walkTo(page, route.corridor.cell);
  await look(page, route.corridor.yaw, 0);
  await page.screenshot({ path: `${SHOTS}/11-corridor.png` });

  // 3. In the atrium on level 0, looking up at the balcony.
  await walkTo(page, route.below.cell);
  await look(page, route.below.yaw, 22);
  await page.screenshot({ path: `${SHOTS}/12-atrium-below.png` });

  // 4. Up the stair on foot to the balcony, looking down into the atrium.
  const before = await page.evaluate(() => (window as any).__gd.player().level);
  expect(before).toBe(0);
  await walkTo(page, route.balcony.cell);
  const after = await page.evaluate(() => (window as any).__gd.player());
  expect(after.level).toBe(1);
  expect(after.y).toBeCloseTo(3.2, 5);
  await look(page, route.balcony.yaw, -30);
  await page.screenshot({ path: `${SHOTS}/13-balcony.png` });

  // Extra views for review: down the stairwell from the top, then up it from the foot (walked down).
  await walkTo(page, route.stair.top);
  await look(page, route.stair.upYaw + 180, -30);
  await page.screenshot({ path: `${SHOTS}/14-stair-top.png` });
  await walkTo(page, route.stair.bottom);
  expect(await page.evaluate(() => (window as any).__gd.player().y)).toBe(0);
  await look(page, route.stair.upYaw, 12);
  await page.screenshot({ path: `${SHOTS}/15-stair-bottom.png` });

  // Let the frame-time window fill with ordinary frames before reading it.
  await settle(page, 120);
  const perf = await page.evaluate(() => ({ ms: (window as any).__gd.frameMs() as number, gpu: (window as any).__gd.gpu as string }));
  console.log(`frameMs=${perf.ms.toFixed(2)} gpu=${perf.gpu} corridor=${route.corridor.length} cells`);
  expect(errors).toEqual([]);
});
