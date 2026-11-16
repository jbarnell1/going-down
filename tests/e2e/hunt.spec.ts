import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// Timing against a real graphics card and a real audio device. CI draws in software at a few frames
// a second, where "within two seconds" means something else. The rule itself is proven in tests/sim.
test.skip(!!process.env.CI, 'needs a real graphics card and audio device');

// The staring contest, in the real game: the Orderly moves only while nobody is looking at it.
// Taken with the tape look on (the default), because that is what players see.

const SHOTS = 'test-results/shots';

type Orderly = {
  x: number; z: number; cx: number; cy: number; phase: string; frozen: boolean; seen: boolean; logicSeen: boolean;
  anim: string; distance: number; loaded: boolean; moving: boolean; drawn: { x: number; z: number; yaw: number; anim: string; frozen: boolean } | null;
};
type TraceRow = { f: number; vis: boolean; dx: number; dz: number; lx: number; lz: number; t: number; anim: string; clip: number };

const gd = (page: Page) => page.evaluate(() => (window as any).__gd.orderly() as Orderly);
const squeak = (page: Page) => page.evaluate(() => (window as any).__gd.audio.state() as { running: boolean; gain: number; nodeGain: number; muffled: boolean; notes: number });
const eventTypes = (page: Page) => page.evaluate(() => ((window as any).__gd.events() as { type: string; playerId?: string }[]));

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

async function boot(page: Page, url: string): Promise<void> {
  await page.goto(url);
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  mkdirSync(SHOTS, { recursive: true });
}

/** The longest level-0 corridor sightline: Orderly at the x2 end, the player `cells` toward x1, facing it. */
async function corridorSetup(page: Page, cells: number) {
  return page.evaluate((k) => {
    const plan = (window as any).__gd.plan;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    return {
      ord: { x: s.x2, y: s.y2, yaw: yawToward(ux, uy) },
      player: { x: s.x2 + ux * k, y: s.y2 + uy * k },
      face: yawToward(-ux, -uy),
      length: s.length,
    };
  }, cells);
}

test('the staring contest: still while watched, closer every time you look away, and then it has you', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const audio0 = await squeak(page);
  expect(audio0.running).toBe(true);

  // 1. Twenty metres down a corridor, facing it. Wake it. It must not move at all for 3 s.
  const c = await corridorSetup(page, 10);
  await page.evaluate((v) => {
    const g = (window as any).__gd;
    g.teleport(0, v.player.x, v.player.y, v.face);
    g.look(v.face, 0);
    g.entityCtl.placeCell(0, v.ord.x, v.ord.y, v.ord.yaw);
    g.entityCtl.wake();
  }, c);
  await settle(page, 6);
  const start = await gd(page);
  expect(start.phase).toBe('hunting');
  expect(start.distance).toBeGreaterThan(19);
  expect(start.seen).toBe(true);
  const t0 = Date.now();
  while (Date.now() - t0 < 3000) {
    const o = await gd(page);
    const a = await squeak(page);
    expect([o.x, o.z]).toEqual([start.x, start.z]);
    expect(a.gain).toBe(0);
    await page.waitForTimeout(100);
  }
  await page.screenshot({ path: `${SHOTS}/50-orderly-watched.png` });

  // 2. Turn your back. Within 2 s the squeak starts and it is closer.
  await page.evaluate((y) => (window as any).__gd.look(y, 0), c.face + 180);
  let heard = 0;
  let closer = false;
  const t1 = Date.now();
  while (Date.now() - t1 < 2000 && !(heard > 0 && closer)) {
    const a = await squeak(page);
    const o = await gd(page);
    heard = Math.max(heard, a.gain);
    closer = o.distance < start.distance - 0.5;
    await page.waitForTimeout(50);
  }
  expect(heard).toBeGreaterThan(0);
  expect(closer).toBe(true);
  const sq = await squeak(page);
  console.log(`squeak while unseen: gain=${sq.gain.toFixed(3)} node=${sq.nodeGain.toFixed(3)} muffled=${sq.muffled} notes=${sq.notes}`);
  expect(sq.notes).toBeGreaterThan(0);
  // Let it come a good deal nearer before turning round.
  await page.waitForFunction(() => (window as any).__gd.orderly().distance < 7, undefined, { timeout: 8000 });
  const away = await gd(page);

  // 3. Face it again. From the first frame drawn after turning it stays exactly put for a full second.
  const f0 = await page.evaluate((y) => {
    const g = (window as any).__gd;
    g.look(y, 0);
    return g.frames as number;
  }, c.face);
  const tCut = Date.now();
  // The squeak's own gain node: almost nothing left 50 ms after the turn.
  await page.waitForTimeout(60);
  const cut = await squeak(page);
  console.log(`squeak ${Date.now() - tCut} ms after turning: target=${cut.gain} node=${cut.nodeGain.toFixed(4)}`);
  expect(cut.gain).toBe(0);
  expect(cut.nodeGain).toBeLessThan(0.05);
  await page.waitForTimeout(1000);
  const rows = (await page.evaluate(() => (window as any).__gd.entityCtl.trace() as TraceRow[])).filter((r) => r.f > f0);
  expect(rows.length).toBeGreaterThan(30);
  const first = rows[0]!;
  for (const r of rows) {
    expect(r.vis).toBe(true);
    expect([r.dx, r.dz]).toEqual([first.dx, first.dz]);
    expect([r.dx, r.dz]).toEqual([r.lx, r.lz]);
    expect([r.anim, r.clip]).toEqual([first.anim, first.clip]);
  }
  const near = await gd(page);
  expect(near.distance).toBeLessThan(start.distance - 5);
  expect(near.drawn).not.toBeNull();
  expect([near.drawn!.x, near.drawn!.z]).toEqual([near.x, near.z]);
  expect((await squeak(page)).gain).toBe(0);
  console.log(`turned back: ${start.distance.toFixed(1)} m -> ${near.distance.toFixed(1)} m (was ${away.distance.toFixed(1)} m when turning), pose ${first.anim} t=${first.clip.toFixed(2)} frames held=${rows.length}`);
  await page.screenshot({ path: `${SHOTS}/51-orderly-closer.png` });

  // 4. Turn away and wait for it.
  await page.evaluate((y) => (window as any).__gd.look(y, 0), c.face + 180);
  await page.waitForFunction(() => (window as any).__gd.events().some((e: any) => e.type === 'caught'), undefined, { timeout: 15_000 });
  await page.waitForTimeout(250);
  const during = await page.evaluate(() => (window as any).__gd.caught());
  expect(during.noise).toBe(true);
  await page.screenshot({ path: `${SHOTS}/52-caught.png` });
  await page.waitForFunction(() => (window as any).__gd.caught().line === true, undefined, { timeout: 5000 });
  const back = await page.evaluate(() => {
    const g = (window as any).__gd;
    return { p: g.player(), landing: g.plan.landing, catches: g.catches() };
  });
  expect({ level: back.p.level, x: back.p.cx, y: back.p.cy }).toEqual({ level: back.landing.level, x: back.landing.x, y: back.landing.y });
  expect(back.catches).toBe(1);
  await expect(page.locator('#went-down')).toBeVisible();
  await expect(page.locator('#went-down')).toHaveText('YOU WENT DOWN');
  await settle(page, 4);
  await page.screenshot({ path: `${SHOTS}/53-went-down.png` });
  expect((await gd(page)).phase).toBe('dormant');

  await settle(page, 60);
  const ms = await page.evaluate(() => (window as any).__gd.frameMs() as number);
  console.log(`hunt frameMs=${ms.toFixed(2)}`);
  expect(errors).toEqual([]);
});

test('looking saves you: watched within reach it never catches, and a glance cancels its reach', async ({ page }) => {
  test.setTimeout(60_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const c = await corridorSetup(page, 6);
  // The player in a corridor cell, the Orderly 1.3 m in front of them (inside REACH_RANGE 1.6 m).
  const where = await page.evaluate((v) => {
    const g = (window as any).__gd;
    g.teleport(0, v.player.x, v.player.y, v.face);
    g.look(v.face, 14);
    const p = g.player();
    const yaw = (v.face * Math.PI) / 180;
    const ox = p.x - Math.sin(yaw) * 1.3;
    const oz = p.z - Math.cos(yaw) * 1.3;
    g.entityCtl.placeAt(ox, oz, 0, v.face + 180);
    g.entityCtl.wake();
    return { ox, oz };
  }, c);
  await settle(page, 6);
  const o0 = await gd(page);
  expect(o0.distance).toBeLessThan(1.6);
  expect(o0.seen).toBe(true);
  // Frozen within reach: it shows its reach pose.
  expect(o0.drawn?.anim).toBe('reach');
  await page.waitForTimeout(5000);
  const o1 = await gd(page);
  expect([o1.x, o1.z]).toEqual([where.ox, where.oz]);
  expect((await eventTypes(page)).filter((e) => e.type === 'caught')).toEqual([]);
  await page.screenshot({ path: `${SHOTS}/54-orderly-within-reach.png` });

  // Turn away until it starts to reach, then look: the reach is cancelled and nobody is caught.
  // Logic time runs at a third of real time here, so the test's own round trip cannot decide it.
  await page.evaluate(() => (window as any).__gd.entityCtl.setTimeScale(1 / 3));
  await page.evaluate((y) => (window as any).__gd.look(y, 0), c.face + 180);
  await page.waitForFunction(() => (window as any).__gd.events().some((e: any) => e.type === 'windUp'), undefined, { timeout: 10_000 });
  await page.evaluate((y) => (window as any).__gd.look(y, 14), c.face);
  await page.waitForTimeout(3000);
  const ev = await eventTypes(page);
  expect(ev.some((e) => e.type === 'windUpCancelled')).toBe(true);
  expect(ev.filter((e) => e.type === 'caught')).toEqual([]);
  console.log(`events: ${ev.map((e) => e.type).join(' ')}`);
  // How far the drawn mesh reaches from its feet axis per clip, against the logic's 0.35 m body.
  const ext = await page.evaluate(() => (window as any).__gd.entityCtl.extents() as Record<string, number>);
  console.log(`mesh extents (m from axis): ${Object.entries(ext).map(([k, v]) => `${k}=${v.toFixed(2)}`).join(' ')}`);
  expect(errors).toEqual([]);
});

test('a glance that falls between two logic ticks still freezes it', async ({ page }) => {
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const c = await corridorSetup(page, 8);
  await page.evaluate((v) => {
    const g = (window as any).__gd;
    g.teleport(0, v.player.x, v.player.y, v.face + 180);
    g.look(v.face + 180, 0);
    g.entityCtl.placeCell(0, v.ord.x, v.ord.y, v.ord.yaw);
    g.entityCtl.wake();
  }, c);
  await page.waitForFunction(() => (window as any).__gd.orderly().moving === true, undefined, { timeout: 5000 });
  // One logic tick per real second from here.
  await page.evaluate(() => (window as any).__gd.entityCtl.setTimeScale(0.05));
  const n = await page.evaluate(() => (window as any).__gd.entityCtl.ticks() as number);
  await page.waitForFunction((k) => (window as any).__gd.entityCtl.ticks() > k, n);
  const n1 = await page.evaluate(() => (window as any).__gd.entityCtl.ticks() as number);
  expect((await gd(page)).frozen).toBe(false);
  const frozeBefore = (await eventTypes(page)).filter((e) => e.type === 'froze').length;
  // Look for three frames, then away again, all well before the next tick.
  await page.evaluate((y) => (window as any).__gd.look(y, 0), c.face);
  await settle(page, 3);
  const glance = await gd(page);
  await page.evaluate((y) => (window as any).__gd.look(y, 0), c.face + 180);
  expect(glance.seen).toBe(true);
  expect(await page.evaluate(() => (window as any).__gd.entityCtl.ticks())).toBe(n1);
  await page.waitForFunction((k) => (window as any).__gd.entityCtl.ticks() > k, n1);
  const after = await gd(page);
  expect(after.seen).toBe(false); // the current view is turned away...
  expect(after.frozen).toBe(true); // ...but the tick counted the glance
  expect([after.x, after.z]).toEqual([glance.x, glance.z]);
  expect((await eventTypes(page)).filter((e) => e.type === 'froze').length).toBe(frozeBefore + 1);
  expect(errors).toEqual([]);
});

test('?debug=1 shows the Orderly on the minimap with its phase, sight, distance and squeak', async ({ page }) => {
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1&debug=1');
  const c = await corridorSetup(page, 8);
  await page.evaluate((v) => {
    const g = (window as any).__gd;
    g.teleport(0, v.player.x, v.player.y, v.face + 180);
    g.entityCtl.placeCell(0, v.ord.x, v.ord.y, v.ord.yaw);
    g.entityCtl.wake();
  }, c);
  await page.waitForFunction(() => (window as any).__gd.audio.state().gain > 0, undefined, { timeout: 5000 });
  await settle(page, 12);
  const text = await page.locator('#debug').innerText();
  expect(text).toMatch(/orderly hunting\s+unseen\s+\d+\.\d m/);
  expect(text).toMatch(/squeak 0\.\d\d/);
  await page.screenshot({ path: `${SHOTS}/55-orderly-debug.png` });
  expect(errors).toEqual([]);
});
