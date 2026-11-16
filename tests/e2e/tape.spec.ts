import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

const SHOTS = 'test-results/shots';
type GD = any;

async function settle(page: Page, frames = 4): Promise<void> {
  const start = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((n) => (window as any).__gd.frames >= n, start + frames);
}

function watchErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  return errors;
}

/** Longest level-0 corridor: one end cell and the yaw facing the other end. */
async function corridor(page: Page) {
  return page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((a: any, b: any) => b.length - a.length)[0];
    return { x: s.x1, y: s.y1, x2: s.x2, y2: s.y2, length: s.length, yaw: yawToward(s.x2 - s.x1, s.y2 - s.y1), cell: plan.cellSize };
  });
}

/** Median frame time after a fresh window of frames at the current settings. */
async function frameMs(page: Page): Promise<number> {
  await settle(page, 130);
  return page.evaluate(() => (window as any).__gd.frameMs() as number);
}

test('the tape look: on, off, heavy, a glitch, and frame times', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watchErrors(page);
  await page.goto('/?seed=alpha&depth=1&fx=1');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  mkdirSync(SHOTS, { recursive: true });

  expect(await page.evaluate(() => (window as any).__gd.fx())).toBe(1);
  const c = await corridor(page);
  await page.evaluate((v) => {
    const gd = (window as any).__gd as GD;
    gd.teleport(0, v.x, v.y, v.yaw);
    gd.look(v.yaw, 0);
  }, c);
  await settle(page, 8);
  await page.screenshot({ path: `${SHOTS}/40-tape-corridor.png` });
  const on = await page.evaluate(() => (window as any).__gd.probePixels(8) as number[][]);
  const ms1 = await frameMs(page);

  expect(await page.evaluate(() => (window as any).__gd.setFx(0))).toBe(0);
  expect(await page.evaluate(() => (window as any).__gd.fx())).toBe(0);
  await settle(page, 4);
  await page.screenshot({ path: `${SHOTS}/41-tape-off.png` });
  const off = await page.evaluate(() => (window as any).__gd.probePixels(8) as number[][]);
  const off2 = await page.evaluate(() => (window as any).__gd.probePixels(8) as number[][]);
  const ms0 = await frameMs(page);

  await page.evaluate(() => (window as any).__gd.setFx(2));
  expect(await page.evaluate(() => (window as any).__gd.fx())).toBe(2);
  await settle(page, 4);
  await page.screenshot({ path: `${SHOTS}/42-tape-heavy.png` });
  const ms2 = await frameMs(page);

  // The tape changes the picture measurably; the clean render is steady frame to frame.
  const diff = (a: number[][], b: number[][]) =>
    a.reduce((t, p, i) => t + Math.abs(p[0]! - b[i]![0]!) + Math.abs(p[1]! - b[i]![1]!) + Math.abs(p[2]! - b[i]![2]!), 0) / (a.length * 3);
  const dOn = diff(on, off);
  const dOff = diff(off, off2);
  console.log(`probe diff fx1 vs fx0=${dOn.toFixed(2)} fx0 vs fx0=${dOff.toFixed(2)}`);
  expect(dOn).toBeGreaterThan(4);
  expect(dOff).toBeLessThan(0.5);

  // A burst of interference, caught mid-way.
  await page.evaluate(() => (window as any).__gd.setFx(1));
  await settle(page, 4);
  await page.evaluate(() => (window as any).__gd.glitch(1500, 1));
  await page.waitForTimeout(350);
  await page.screenshot({ path: `${SHOTS}/46-glitch.png` });

  console.log(`frameMs fx0=${ms0.toFixed(2)} fx1=${ms1.toFixed(2)} fx2=${ms2.toFixed(2)}`);
  expect(ms1).toBeLessThan(20);
  expect(errors).toEqual([]);
});

test('the Orderly through the tape at 4 m and 15 m', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watchErrors(page);
  await page.goto('/?seed=alpha&depth=1&preview=orderly&anim=idle&fx=1');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.entity?.loaded() === true, undefined, { timeout: 30_000 });
  mkdirSync(SHOTS, { recursive: true });

  const views = await page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const S = plan.cellSize;
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    const view = (metres: number) => {
      const k = Math.min(s.length - 1, Math.max(1, Math.round(metres / S)));
      return { cell: { x: s.x2 + ux * k, y: s.y2 + uy * k }, yaw: yawToward(-ux, -uy), metres: k * S };
    };
    return { ord: { x: s.x2, y: s.y2, yaw: yawToward(ux, uy) }, near: view(4), mid: view(15) };
  });
  await page.evaluate(({ x, y, yaw }) => (window as any).__gd.entity.placeCell(0, x, y, yaw), views.ord);
  for (const [name, v] of [['43-tape-orderly', views.near], ['44-tape-orderly-mid', views.mid]] as const) {
    await page.evaluate(({ c, yaw }) => {
      (window as any).__gd.teleport(0, c.x, c.y, yaw);
      (window as any).__gd.look(yaw, 0);
    }, { c: v.cell, yaw: v.yaw });
    await settle(page, 6);
    await page.screenshot({ path: `${SHOTS}/${name}.png` });
    console.log(`${name}: ${v.metres} m`);
  }
  expect(errors).toEqual([]);
});

test('the debug minimap appears only with ?debug=1 and follows the level', async ({ page }) => {
  const errors = watchErrors(page);
  await page.goto('/?seed=alpha&depth=1');
  await page.waitForFunction(() => (window as any).__gd?.frames > 5);
  expect(await page.locator('#minimap').count()).toBe(0);

  await page.goto('/?seed=alpha&depth=1&debug=1');
  await page.waitForFunction(() => (window as any).__gd?.frames > 20);
  await page.evaluate(() => (window as any).__gd.start());
  const c = await corridor(page);
  await page.evaluate((v) => {
    const gd = (window as any).__gd as GD;
    gd.teleport(0, v.x, v.y, v.yaw);
    gd.look(v.yaw, 0);
  }, c);
  await settle(page, 12);
  await expect(page.locator('#minimap')).toBeVisible();
  const text = await page.locator('#debug').innerText();
  expect(text).toMatch(/tape fx1/);
  expect(text).toMatch(/median \d+\.\d ms/);
  mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: `${SHOTS}/45-debug-minimap.png` });

  // The map redraws for the upper level when the player is there.
  const upper = await page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    for (let y = 0; y < plan.height; y++) for (let x = 0; x < plan.width; x++) if (plan.cells[1][y * plan.width + x] === 'corridor') return { x, y };
    return null;
  });
  expect(upper).not.toBeNull();
  const before = await page.evaluate(() => (document.getElementById('minimap') as HTMLCanvasElement).toDataURL());
  await page.evaluate((u) => (window as any).__gd.teleport(1, u!.x, u!.y), upper);
  await settle(page, 12);
  expect(await page.locator('#debug').innerText()).toMatch(/cell L1/);
  const after = await page.evaluate(() => (document.getElementById('minimap') as HTMLCanvasElement).toDataURL());
  expect(after).not.toBe(before);
  expect(errors).toEqual([]);
});

test('reduced motion keeps the tape but stills it; resizing and rotating keep the picture whole', async ({ page }) => {
  const errors = watchErrors(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/?seed=alpha&depth=1&debug=1');
  await page.waitForFunction(() => (window as any).__gd?.frames > 20);
  expect(await page.locator('#debug').innerText()).toMatch(/tape fx1 \(reduced motion\)/);

  // Phone portrait, then landscape, then back: the screen buffer follows the window.
  for (const [w, h] of [[390, 844], [844, 390], [1280, 720]] as const) {
    await page.setViewportSize({ width: w, height: h });
    await settle(page, 6);
    const buf = await page.evaluate(() => {
      const c = document.getElementById('view') as HTMLCanvasElement;
      return { w: c.width, h: c.height };
    });
    expect(buf.h).toBe(h);
    expect(Math.abs(buf.w - w)).toBeLessThanOrEqual(1);
    expect(await page.evaluate(() => (window as any).__gd.probeColours() as number)).toBeGreaterThan(8);
    if (w === 844) console.log(`frameMs phone 844x390 fx1=${(await frameMs(page)).toFixed(2)}`);
  }
  expect(errors).toEqual([]);
});
