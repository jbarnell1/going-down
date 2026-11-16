import { mkdirSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// A whole run for one player, in the real game with the tape look on: out of the car, earn, call
// the elevator, live through a blink, ride DOWN, earn again (paid more for depth), call, ride BANK,
// the summary, a new run. Waits for the car are skipped with runCtl.skip, which still steps the run
// tick by tick through stepRun. The run's rules are proven in tests/sim/run.test.ts.
test.skip(!!process.env.CI, 'needs a real graphics card and real time');

const SHOTS = 'test-results/shots';

type Run = {
  phase: string; depth: number; t: number; car: string; doorsOpen: boolean; doors: number;
  indicator: { floorsAway: number; label: string; falseStop: boolean }; eta: number | null; blink: boolean; blinkSoon: boolean;
  vote: string | null; aboard: boolean; status: string; bellLeft: number; held: boolean; calls: number; banked: number;
  summary: { depth: number; readings: number; total: number; shares: Record<string, number>; wiped: boolean } | null;
  lifetime: number; multiplier: number; planKey: string; ended: string | null; endShown: boolean; endText: string[]; runs: number;
  callPrompt: boolean; holdPrompt: boolean; lightLevel: number;
  car3: { doorX: number; doorZ: number; inX: number; inZ: number; level: number };
};
type Ord = { x: number; z: number; distance: number; seen: boolean; phase: string; frozen: boolean };

const run = (page: Page) => page.evaluate(() => (window as any).__gd.run() as Run);
const orderly = (page: Page) => page.evaluate(() => (window as any).__gd.orderly() as Ord);
const inst = (page: Page) => page.evaluate(() => (window as any).__gd.instrument() as { total: number; value: number; needle: string; tapes: number });
const deg = (rad: number): number => (rad * 180) / Math.PI;
/** Yaw (degrees) that faces into the car, and out of it. */
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

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: `${SHOTS}/${name}.png` });
}

async function boot(page: Page, url: string): Promise<void> {
  await page.goto(url);
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  // Hold the run's clock until the Orderly has loaded, so the start is seen from its first second.
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(0));
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  mkdirSync(SHOTS, { recursive: true });
}

/** Skips logic time until an event of this type (tick by tick through stepRun); fails if it never comes. */
async function skipUntil(page: Page, type: string, max = 120): Promise<void> {
  const hit = await page.evaluate(([t, m]) => (window as any).__gd.runCtl.skipUntil(t, m) as boolean, [type, max] as const);
  expect(hit, `event ${type} within ${max} s`).toBe(true);
  await settle(page, 2);
}

async function walkCar(page: Page, u: number, v: number): Promise<void> {
  await page.evaluate(([a, b]) => (window as any).__gd.runCtl.walkCar(a, b), [u, v] as const);
  await settle(page, 2);
}

/** Stands the Orderly a few cells straight out from the player (away from the car), awake, where they can see it. */
async function orderlyInView(page: Page): Promise<number> {
  const r = await run(page);
  for (const k of [4, 3, 2, 5]) {
    // A cell it could never stand in (a wall, the void past the corridor) is refused by the hook.
    const placed = await page.evaluate(([k, ix, iz, yaw]) => {
      const g = (window as any).__gd;
      const p = g.player();
      g.look(yaw, 0);
      if (!g.entityCtl.placeCell(p.level, p.cx - Math.round(ix) * k, p.cy - Math.round(iz) * k, yaw + 180)) return false;
      g.entityCtl.wake();
      return true;
    }, [k, r.car3.inX, r.car3.inZ, yawOut(r)] as const);
    if (!placed) continue;
    // Judge it where it now stands: wait until the page draws it there, not where it was.
    await page.waitForFunction(() => { const o = (window as any).__gd.orderly(); return o.drawn !== null && Math.hypot(o.drawn.x - o.x, o.drawn.z - o.z) < 0.6; }, undefined, { timeout: 3000 });
    await settle(page, 3);
    const o = await orderly(page);
    if (o.seen) return o.distance;
  }
  throw new Error('no cell in view of the landing');
}

/**
 * The earning routine from earn.spec.ts on the current floor: back turned in the longest corridor,
 * the Orderly 9.5 m behind and awake, the instrument up, turn round at 2.5 m. Returns the closed
 * reading (its value after the depth's pay) and the largest raw value the open reading showed.
 */
async function earn(page: Page): Promise<{ value: number; maxRaw: number }> {
  const before = await page.evaluate(() => (window as any).__gd.crewEvents().filter((e: any) => e.type === 'readingClosed').length as number);
  const c = await page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    return { ux, uy, cell: { x: s.x2 + ux * 6, y: s.y2 + uy * 6 }, face: yawToward(-ux, -uy), away: yawToward(ux, uy) };
  });
  await page.evaluate((c) => {
    const g = (window as any).__gd;
    g.teleport(0, c.cell.x, c.cell.y, c.away);
    g.look(c.away, 0);
    g.raise(true);
    const p = g.player();
    g.entityCtl.placeAt(p.x - c.ux * 9.5, p.z - c.uy * 9.5, 0, c.away);
    g.entityCtl.wake();
  }, c);
  await page.waitForFunction(() => (window as any).__gd.instrument().needle === 'recording', undefined, { timeout: 5000 });
  const out = await page.evaluate(({ face, before }) => new Promise<{ value: number; maxRaw: number }>((resolve, reject) => {
    const g = (window as any).__gd;
    let maxRaw = 0;
    let turned = false;
    const t0 = performance.now();
    const loop = (): void => {
      const i = g.instrument();
      maxRaw = Math.max(maxRaw, i.value);
      if (!turned && g.orderly().distance <= 2.5) {
        g.look(face, 0);
        turned = true;
      }
      const closed = g.crewEvents().filter((e: any) => e.type === 'readingClosed');
      if (closed.length > before) {
        resolve({ value: closed[closed.length - 1].value, maxRaw });
        return;
      }
      if (performance.now() - t0 > 30_000) {
        reject(new Error('no reading closed'));
        return;
      }
      requestAnimationFrame(loop);
    };
    loop();
  }), { face: c.face, before });
  await page.evaluate(() => (window as any).__gd.raise(null));
  return out;
}

/** Back to the landing on foot (the Orderly put to rest first), facing the doors. */
async function toLanding(page: Page): Promise<void> {
  await page.evaluate(() => (window as any).__gd.entityCtl.rest(600));
  await page.evaluate(() => { const g = (window as any).__gd; const l = g.plan.landing; return g.walkTo(l.level, l.x, l.y); });
  const r = await run(page);
  await page.evaluate((y) => (window as any).__gd.look(y, 4), yawIn(r));
  await settle(page, 3);
}

test('a whole run: out, earn, call, a blink, ride down, earn more, ride to the bank, a new run', async ({ page }) => {
  test.setTimeout(240_000);
  const errors = watchErrors(page);
  const t0 = Date.now();
  await boot(page, '/?seed=alpha');

  // 1. Inside the car, the doors opening onto floor 1.
  const r0 = await run(page);
  expect(r0.depth).toBe(1);
  expect(r0.phase).toBe('arriving');
  expect(r0.aboard).toBe(true);
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => { const d = (window as any).__gd.run().doors; return d > 0.25 && d < 0.75; }, undefined, { timeout: 5000 });
  await shot(page, '70-in-the-car');
  const audio0 = await page.evaluate(() => (window as any).__gd.audio.state());
  expect(audio0.doorSounds).toBe(1);

  // 2. Step out; the doors shut behind you and the car leaves, the indicator climbing away.
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99);
  await walkCar(page, -1, 0);
  // Then back across the landing, turned to face the doors.
  await walkCar(page, -5, 0);
  await page.evaluate((y) => (window as any).__gd.look(y, 9), yawIn(r0));
  await page.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 5000 });
  await page.waitForTimeout(2900);
  const r1 = await run(page);
  expect(r1.doorsOpen).toBe(false);
  expect(['G', '1', '2', '3']).toContain(r1.indicator.label);
  await shot(page, '71-car-leaves');

  // 3. Earn a reading.
  const first = await earn(page);
  expect(first.value).toBeGreaterThan(0);
  expect(first.value).toBeCloseTo(first.maxRaw, 6);
  await page.waitForTimeout(1200);
  await shot(page, '72-earned');

  // 4. Back at the landing, call. The indicator counts the car down.
  await toLanding(page);
  expect((await run(page)).callPrompt).toBe(true);
  await page.keyboard.press('KeyE');
  await page.waitForFunction(() => (window as any).__gd.run().car === 'coming', undefined, { timeout: 2000 });
  const called = await run(page);
  const a1 = await page.evaluate(() => (window as any).__gd.audio.state());
  expect(a1.chimes).toBe(1);
  // The car starts moving 1 to 3 s after the call, then takes 4 s a floor.
  await page.evaluate(() => (window as any).__gd.runCtl.skip(7.2));
  await settle(page, 3);
  const counting = await run(page);
  expect(counting.indicator.floorsAway).toBeLessThan(called.indicator.floorsAway);
  expect(counting.indicator.label).not.toBe(called.indicator.label);
  console.log(`called: ${called.indicator.floorsAway} floors away (${called.indicator.label}), eta ${called.eta?.toFixed(1)} s; after 7.2 s ${counting.indicator.label}`);
  // From across the landing.
  await walkCar(page, -5, 0);
  await page.evaluate((y) => (window as any).__gd.look(y, 9), yawIn(r0));
  await settle(page, 4);
  await shot(page, '73-called');

  // 5. A blink. The Orderly stands in view; while the lights are on and you watch it, it does not move.
  await walkCar(page, -2.2, 0);
  const d0 = await orderlyInView(page);
  const p0 = await orderly(page);
  await skipUntil(page, 'blinkSoon', 20);
  const p1 = await orderly(page);
  expect([p1.x, p1.z]).toEqual([p0.x, p0.z]);
  // Slow the clock so the 0.6 s warning and the 1 s dark can be photographed.
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(0.25));
  expect((await run(page)).blinkSoon).toBe(true);
  await shot(page, '74-blink-warning');
  const warnLight = (await run(page)).lightLevel;
  await page.waitForFunction(() => (window as any).__gd.run().blink === true, undefined, { timeout: 5000 });
  await settle(page, 3);
  await shot(page, '75-blink-dark');
  const darkLight = (await run(page)).lightLevel;
  await page.waitForFunction(() => { const r = (window as any).__gd.run(); return !r.blink && !r.blinkSoon; }, undefined, { timeout: 8000 });
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  const p2 = await orderly(page);
  expect(Math.hypot(p2.x - p1.x, p2.z - p1.z)).toBeGreaterThan(0.3);
  console.log(`blink: orderly ${d0.toFixed(1)} m -> ${p2.distance.toFixed(1)} m; light warning ${warnLight} dark ${darkLight}`);
  expect(warnLight).toBeLessThan(1);
  expect(darkLight).toBeLessThan(0.1);

  // 6. The car arrives. Board, stand on DOWN, the bell, the ride, floor two.
  await page.evaluate(() => (window as any).__gd.entityCtl.rest(600));
  await skipUntil(page, 'carArrived', 80);
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 4000 });
  await page.evaluate((y) => (window as any).__gd.look(y, 4), yawIn(r0));
  await settle(page, 3);
  await shot(page, '76-doors-open');
  await walkCar(page, 0.8, 0.5);
  await page.waitForFunction(() => (window as any).__gd.run().vote === 'down', undefined, { timeout: 4000 });
  await page.evaluate((y) => (window as any).__gd.look(y, -52), yawIn(r0));
  await settle(page, 6);
  await shot(page, '77-vote-down');
  const plan1 = (await run(page)).planKey;
  await skipUntil(page, 'bell', 30);
  expect((await run(page)).phase).toBe('riding');
  await skipUntil(page, 'rodeDown', 10);
  const down = await run(page);
  expect(down.depth).toBe(2);
  expect(down.planKey).not.toBe(plan1);
  expect(down.multiplier).toBeCloseTo(1.35, 6);
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 5000 });
  await walkCar(page, 1.3, 0);
  await page.evaluate((y) => (window as any).__gd.look(y, 0), yawOut(down));
  await settle(page, 4);
  await shot(page, '78-floor-two');

  // 7. Earn again: the reading is paid for depth.
  await walkCar(page, -1, 0);
  const second = await earn(page);
  expect(second.value / second.maxRaw).toBeCloseTo(1.35, 3);
  console.log(`readings: floor 1 ${first.value.toFixed(1)}, floor 2 ${second.value.toFixed(1)} (raw ${second.maxRaw.toFixed(1)} x ${(second.value / second.maxRaw).toFixed(3)})`);
  const aboard = (await inst(page)).total;
  expect(aboard).toBeCloseTo(first.value + second.value, 6);
  await toLanding(page);
  await page.keyboard.press('KeyE');
  await page.waitForFunction(() => (window as any).__gd.run().car === 'coming', undefined, { timeout: 2000 });
  await skipUntil(page, 'carArrived', 80);
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 4000 });
  await walkCar(page, 0.8, -0.5);
  await page.waitForFunction(() => (window as any).__gd.run().vote === 'bank', undefined, { timeout: 4000 });
  await page.evaluate((y) => (window as any).__gd.look(y, -52), yawIn(down));
  await settle(page, 6);
  await shot(page, '79-vote-bank');
  await skipUntil(page, 'banked', 30);
  await page.waitForFunction(() => (window as any).__gd.run().endShown === true, undefined, { timeout: 6000 });
  const end = await run(page);
  expect(end.phase).toBe('ended');
  expect(end.summary!.wiped).toBe(false);
  expect(end.summary!.total).toBeGreaterThan(0);
  expect(end.summary!.total).toBeCloseTo(aboard, 6);
  expect(end.summary!.readings).toBe(2);
  expect(end.summary!.depth).toBe(2);
  expect(end.banked).toBeCloseTo(aboard, 6);
  expect(end.lifetime).toBeCloseTo(aboard, 6);
  expect(end.endText[0]).toBe('BANKED');
  await shot(page, '80-banked');
  const a2 = await page.evaluate(() => (window as any).__gd.audio.state());
  console.log(`sounds: chimes ${a2.chimes} dings ${a2.dings} doors ${a2.doorSounds} bells ${a2.bells} warnings ${a2.warnDings} blink warnings ${a2.blinkWarnings} darks ${a2.blinkOuts}`);
  expect(a2.bells).toBe(2);

  // A new run, without reloading: the car, the depth and the totals start over; the lifetime stays.
  await page.waitForTimeout(1300);
  await page.keyboard.press('Space');
  await settle(page, 3);
  const again = await run(page);
  expect(again.runs).toBe(2);
  expect(again.endShown).toBe(false);
  expect(again.depth).toBe(1);
  expect(['arriving', 'unloading']).toContain(again.phase);
  expect(again.aboard).toBe(true);
  expect(again.banked).toBe(0);
  expect(again.calls).toBe(0);
  expect(again.planKey).toBe(plan1);
  expect((await inst(page)).total).toBe(0);
  expect(again.lifetime).toBeCloseTo(aboard, 6);
  const elapsed = (Date.now() - t0) / 1000;
  await settle(page, 60);
  const ms = await page.evaluate(() => (window as any).__gd.frameMs() as number);
  console.log(`run: banked ${end.summary!.total.toFixed(1)} over ${end.summary!.depth} floors, ${end.summary!.readings} readings; logic time ${end.t.toFixed(0)} s; test took ${elapsed.toFixed(0)} s; frameMs=${ms.toFixed(2)}`);
  expect(errors).toEqual([]);
});

test('staring through the blinks: it gains ground only while the lights are out', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&debug=1');
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 5000 });
  await walkCar(page, -1, 0);
  await page.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 5000 });
  const d0 = await orderlyInView(page);
  expect(await page.evaluate(() => (window as any).__gd.runCtl.call())).toBe(true);
  // Stand still and watch it, frame by frame, through three blinks (logic at 1.5x real time).
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1.5));
  const samples = await page.evaluate(() => new Promise<{ t: number; blink: boolean; x: number; z: number; d: number }[]>((resolve) => {
    const g = (window as any).__gd;
    const out: { t: number; blink: boolean; x: number; z: number; d: number }[] = [];
    const t0 = performance.now();
    const loop = (): void => {
      const r = g.run();
      const o = g.orderly();
      out.push({ t: r.t, blink: r.blink, x: o.x, z: o.z, d: o.distance });
      const ends = g.runEvents().filter((e: any) => e.type === 'blinkEnd').length;
      if (ends >= 3 || performance.now() - t0 > 40_000 || g.catches() > 0) {
        resolve(out);
        return;
      }
      requestAnimationFrame(loop);
    };
    loop();
  }));
  let gainedLit = 0;
  let gainedDark = 0;
  const perBlink: string[] = [];
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1]!;
    const b = samples[i]!;
    const moved = Math.hypot(b.x - a.x, b.z - a.z);
    if (!a.blink && !b.blink) gainedLit += moved;
    else gainedDark += a.d - b.d;
    if (a.blink && !b.blink) perBlink.push(b.d.toFixed(2));
  }
  console.log(`staring: start ${d0.toFixed(2)} m; after each blink ${perBlink.join(', ')} m; moved with lights on ${gainedLit.toFixed(3)} m, gained in the dark ${gainedDark.toFixed(2)} m; ${samples.length} frames`);
  // ?debug=1 shows the run's phase, the car, the wait and the vote.
  await settle(page, 12);
  const dbg = await page.locator('#debug').innerText();
  expect(dbg).toMatch(/run coming\s+depth 1\s+car coming\s+eta \d+\.\d s/);
  expect(dbg).toMatch(/vote -/);
  expect(perBlink.length).toBe(3);
  expect(gainedLit).toBe(0);
  expect(gainedDark).toBeGreaterThan(1);
  expect(await page.evaluate(() => (window as any).__gd.catches())).toBe(0);
  expect(errors).toEqual([]);
});

test('caught with the car gone and nobody to call it: a wipe, nothing banked, and a new run', async ({ page }) => {
  test.setTimeout(60_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha');
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 5000 });
  await walkCar(page, -1, 0);
  await page.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 5000 });
  // Back turned on it, close behind, never turning round.
  await page.evaluate(() => {
    const g = (window as any).__gd;
    const r = g.run();
    const p = g.player();
    const yaw = (Math.atan2(r.car3.inX, r.car3.inZ) * 180) / Math.PI;
    g.look(yaw + 180, 0);
    g.entityCtl.placeCell(p.level, p.cx - r.car3.inX * 3, p.cy - r.car3.inZ * 3, yaw + 180);
    g.entityCtl.wake();
  });
  await page.waitForFunction(() => (window as any).__gd.run().ended === 'wiped', undefined, { timeout: 20_000 });
  await page.waitForFunction(() => (window as any).__gd.run().endShown === true, undefined, { timeout: 6000 });
  const r = await run(page);
  expect(r.summary!.wiped).toBe(true);
  expect(r.banked).toBe(0);
  expect(r.endText[0]).toBe('NOBODY CAME BACK UP');
  expect(await page.evaluate(() => (window as any).__gd.caught().line)).toBe(false);
  await shot(page, '81-wiped');
  await page.waitForTimeout(1300);
  await page.mouse.click(640, 360);
  await settle(page, 3);
  const again = await run(page);
  expect(again.endShown).toBe(false);
  expect(again.runs).toBe(2);
  expect(again.aboard).toBe(true);
  expect(again.lifetime).toBe(0);
  expect(errors).toEqual([]);
});
