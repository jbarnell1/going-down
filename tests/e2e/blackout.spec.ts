import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';
import { generateClinic } from '../../src/sim/clinic';
import { distancesFrom, isWalkable, posFromIndex } from '../../src/sim/floor';

// The blackout in the real game: the blinks of a wait grow, the last dark stretch is the blackout
// (a long warning, then the dark with the emergency lighting on, the Orderly hunting, heard and never
// drawn), and the lights come back as the car's doors open. Real time through the blackout itself.
test.skip(!!process.env.CI, 'needs a real graphics card and real time');

const SHOTS = 'test-results/shots';

type Dark = { at: number; len: number; warn: number; blackout: boolean };
type Run = {
  phase: string; t: number; car: string; doors: number; eta: number | null; blink: boolean; blinkSoon: boolean; dark: boolean;
  darkNow: (Dark & { announced: boolean; on: boolean }) | null; darks: Dark[] | null; emergency: number; lightLevel: number;
  car3: { doorX: number; doorZ: number; inX: number; inZ: number; level: number };
};
type Sample = { dark: boolean; shown: boolean; seen: boolean; em: number; light: number; gain: number; x: number; z: number; t: number };

const run = (page: Page) => page.evaluate(() => (window as any).__gd.run() as Run);
const deg = (rad: number): number => (rad * 180) / Math.PI;
const yawIn = (r: Run): number => deg(Math.atan2(-r.car3.inX, -r.car3.inZ));
const yawOut = (r: Run): number => deg(Math.atan2(r.car3.inX, r.car3.inZ));

function watchErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  return errors;
}

async function settle(page: Page, frames = 4): Promise<void> {
  const start = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((n) => (window as any).__gd.frames >= n, start + frames);
}

/** A cell 18 to 22 cells' walk from the landing yet within 30 m of it in a straight line: it can hunt from there, heard, and not reach the landing in a few seconds. */
function huntCell(seed: string, depth: number): { level: 0 | 1; x: number; y: number } {
  const plan = generateClinic(seed, depth);
  const dist = distancesFrom(plan, plan.landing);
  const lx = plan.landing.x;
  const ly = plan.landing.y;
  let best: { level: 0 | 1; x: number; y: number } | null = null;
  for (let i = 0; i < dist.length; i++) {
    const d = dist[i] ?? -1;
    if (d < 18 || d > 22) continue;
    const p = posFromIndex(plan, i);
    if (p.level !== plan.landing.level || !isWalkable(plan, p.level, p.x, p.y)) continue;
    if (Math.hypot(p.x - lx, p.y - ly) * plan.cellSize > 30) continue;
    best = p;
    break;
  }
  if (!best) throw new Error('no hunting cell');
  return best;
}

test('the blackout: blinks that grow, a long warning, the emergency lights, the Orderly never drawn in the dark, the lights back with the doors open', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watchErrors(page);
  mkdirSync(SHOTS, { recursive: true });
  await page.goto('/?seed=alpha');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(0));
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 5000 });
  await page.evaluate(() => (window as any).__gd.runCtl.walkCar(-1.6, 0));
  await page.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 20_000 });
  const r0 = await run(page);

  // The call: the wait's dark stretches, laid out at once. Each longer than the last; the last the blackout, ending as the car arrives.
  expect(await page.evaluate(() => (window as any).__gd.runCtl.call())).toBe(true);
  await page.waitForFunction(() => (window as any).__gd.run().darks !== null, undefined, { timeout: 3000 });
  const called = await run(page);
  const darks = called.darks!;
  expect(darks.length).toBeGreaterThanOrEqual(2);
  for (let k = 1; k < darks.length; k++) expect(darks[k]!.len).toBeGreaterThan(darks[k - 1]!.len);
  expect(darks.map((d) => d.blackout)).toEqual(darks.map((_, k) => k === darks.length - 1));
  const black = darks.at(-1)!;
  expect(black.len).toBeGreaterThanOrEqual(9);
  expect(black.warn).toBeCloseTo(3, 6);
  expect(black.at + black.len).toBeCloseTo(called.t + called.eta!, 1);
  console.log(`darks: ${darks.map((d) => `${d.len.toFixed(1)} s at ${d.at.toFixed(1)}`).join(', ')}; car at ${(called.t + called.eta!).toFixed(1)}`);

  // The Orderly stands in view out from the landing, asleep, looked at.
  await page.evaluate(([yaw, ix, iz]) => {
    const g = (window as any).__gd;
    const p = g.player();
    g.look(yaw, 2);
    for (const k of [4, 3, 5]) if (g.entityCtl.placeCell(p.level, p.cx - Math.round(ix) * k, p.cy - Math.round(iz) * k, yaw + 180)) break;
    g.entityCtl.rest(600);
  }, [yawOut(r0), r0.car3.inX, r0.car3.inZ] as const);

  // Every frame from here: dark, the figure drawn, the emergency lights, the light level, the trolley's level.
  await page.evaluate(() => {
    const w = window as any;
    w.__bo = [];
    const loop = (): void => {
      const g = w.__gd;
      const r = g.run();
      const o = g.orderly();
      w.__bo.push({ dark: r.dark, shown: o.shown, seen: o.seen, em: r.emergency, light: r.lightLevel, gain: g.audio.state().gain, x: o.x, z: o.z, t: r.t });
      requestAnimationFrame(loop);
    };
    loop();
  });

  // To the blackout's warning (the blinks before it skipped tick by tick).
  for (let i = 0; i < 8 && !(await run(page)).darkNow?.blackout; i++) {
    expect(await page.evaluate(() => (window as any).__gd.runCtl.skipUntil('blinkSoon', 60))).toBe(true);
  }
  await settle(page, 2);
  const w0 = await run(page);
  expect(w0.darkNow?.blackout).toBe(true);
  expect(w0.blinkSoon).toBe(true);
  expect(w0.dark).toBe(false);
  await page.waitForTimeout(1200);
  const w1 = await run(page);
  expect(w1.blinkSoon).toBe(true);
  expect(w1.lightLevel).toBeLessThan(0.6);
  expect((await page.evaluate(() => (window as any).__gd.orderly())).shown).toBe(true);
  await page.screenshot({ path: `${SHOTS}/120-blackout-warning.png` });

  // The dark: after a moment the emergency lights hold. Amber-red, and enough to see by.
  await page.waitForFunction(() => (window as any).__gd.run().dark === true, undefined, { timeout: 4000 });
  await page.waitForFunction(() => (window as any).__gd.run().emergency === 1, undefined, { timeout: 4000 });
  await settle(page, 3);
  const px = await page.evaluate(() => (window as any).__gd.probePixels(8) as number[][]);
  await page.screenshot({ path: `${SHOTS}/121-blackout-emergency-lights.png` });
  const sum = px.reduce((s, p) => [s[0]! + p[0]!, s[1]! + p[1]!, s[2]! + p[2]!], [0, 0, 0]);
  const mean = sum.map((v) => v / px.length);
  console.log(`emergency light picture: mean rgb ${mean.map((v) => v.toFixed(1)).join(', ')}`);
  expect(mean[0]).toBeGreaterThan(mean[2]! * 1.25);
  expect(mean[0]).toBeGreaterThan(mean[1]! * 1.1);
  expect(mean[0]).toBeGreaterThan(12);
  expect((await page.evaluate(() => (window as any).__gd.orderly())).shown).toBe(false);

  // It hunts in the dark: woken some way off, it comes, heard (and never drawn).
  const cell = huntCell('alpha', 1);
  await page.evaluate((c) => {
    const g = (window as any).__gd;
    g.entityCtl.placeCell(c.level, c.x, c.y);
    g.entityCtl.wake();
  }, cell);
  const woke = (await page.evaluate(() => (window as any).__gd.orderly())) as { x: number; z: number };

  // The lights come back with the car: the doors open.
  await page.waitForFunction(() => { const r = (window as any).__gd.run(); return !r.dark && r.car !== 'coming'; }, undefined, { timeout: 15_000 });
  await page.evaluate((y) => (window as any).__gd.look(y, 4), yawIn(r0));
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 4000 });
  await settle(page, 4);
  const back = await run(page);
  expect(back.phase).toBe('boarding');
  expect(back.lightLevel).toBe(1);
  expect(back.emergency).toBe(0);
  await page.screenshot({ path: `${SHOTS}/122-lights-back-car-open.png` });

  const samples = (await page.evaluate(() => (window as any).__bo)) as Sample[];
  const dark = samples.filter((s) => s.dark);
  const lit = samples.filter((s) => !s.dark);
  // Never drawn on a dark frame; drawn (and seen) on lit ones, so the check is not empty.
  expect(dark.length).toBeGreaterThan(100);
  expect(dark.filter((s) => s.shown)).toEqual([]);
  expect(lit.some((s) => s.shown && s.seen)).toBe(true);
  // The emergency lights only in the dark, and fully on for most of it.
  expect(lit.filter((s) => s.em > 0)).toEqual([]);
  expect(dark.filter((s) => s.em === 1).length).toBeGreaterThan(dark.length * 0.6);
  // It moved in the dark after waking, and was heard doing it.
  const moved = dark.filter((s) => Math.hypot(s.x - woke.x, s.z - woke.z) > 3);
  expect(moved.length).toBeGreaterThan(0);
  expect(dark.some((s) => s.gain > 0)).toBe(true);
  // The lights line, in place of the arrival line.
  await page.waitForFunction(() => (window as any).__gd.announcer.state().history.some((h: any) => h.moment === 'lights') || (window as any).__gd.announcer.state().queue.some((id: string) => id.startsWith('lights')), undefined, { timeout: 8000 });
  const said = await page.evaluate(() => (window as any).__gd.announcer.state().history.map((h: any) => h.moment) as string[]);
  expect(said).not.toContain('arrived');
  expect(said).toContain('blackout');
  console.log(`blackout frames: ${dark.length} dark (${dark.filter((s) => s.em === 1).length} with the emergency lights full), ${lit.length} lit; the Orderly drawn on ${dark.filter((s) => s.shown).length} dark frames; heard on ${dark.filter((s) => s.gain > 0).length}; announcer said ${said.join(' ')}`);
  expect(errors).toEqual([]);
});
