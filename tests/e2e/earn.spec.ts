import { mkdirSync } from 'node:fs';
import { expect, test, type Browser, type Page } from '@playwright/test';

// Timing against a real graphics card and real time: CI draws in software at a few frames a second.
// The earning rule itself is proven in tests/sim/instrument.test.ts.
test.skip(!!process.env.CI, 'needs a real graphics card and real time');

// The earning loop in the real game, with the tape look on (the default). The instrument records
// only while the Orderly is MOVING within about 9 m, which means only while nobody looks at it: you
// raise it, turn your back, listen to the ticking climb, and choose when to turn round.

const SHOTS = 'test-results/shots';

type Inst = {
  raised: boolean; needle: string; value: number; recording: number; total: number; own: number; tickHz: number; loudness: number;
  tapes: number; carrying: number; distance: number | null; drawnRaise: number; needleAngle: number; slip: { text: string; shown: boolean }; osd: string;
};
type CrewEv = { type: string; value?: number; reading?: { value: number; duration: number; peakRate: number }; at?: { x: number; z: number }; text?: string };
type Sample = { t: number; d: number; needle: string; value: number; hz: number; angle: number; audioHz: number; cadence: number };

const inst = (page: Page) => page.evaluate(() => (window as any).__gd.instrument() as Inst);
const orderly = (page: Page) => page.evaluate(() => (window as any).__gd.orderly() as { x: number; z: number; distance: number; frozen: boolean; seen: boolean; phase: string; moving: boolean });
const crewEvents = (page: Page) => page.evaluate(() => (window as any).__gd.crewEvents() as CrewEv[]);

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

async function boot(page: Page, url: string): Promise<void> {
  await page.goto(url);
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  if (!url.includes('entity=0')) await page.waitForFunction(() => (window as any).__gd.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  mkdirSync(SHOTS, { recursive: true });
}

/**
 * The longest level-0 corridor: the player `cells` in from its x2 end. `face` looks toward the x2
 * end, `away` toward x1 (the open corridor ahead when your back is turned).
 */
async function corridor(page: Page, cells: number) {
  return page.evaluate((k) => {
    const plan = (window as any).__gd.plan;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    return { ux, uy, cell: { x: s.x2 + ux * k, y: s.y2 + uy * k }, face: yawToward(-ux, -uy), away: yawToward(ux, uy), length: s.length, size: plan.cellSize };
  }, cells);
}

type Corridor = Awaited<ReturnType<typeof corridor>>;

/** Player in the corridor with their back to the x2 end; the Orderly `behind` metres behind them, awake. */
async function backTurned(page: Page, c: Corridor, behind: number, raised: boolean): Promise<void> {
  await page.evaluate(({ c, behind, raised }) => {
    const g = (window as any).__gd;
    g.teleport(0, c.cell.x, c.cell.y, c.away);
    g.look(c.away, 0);
    g.raise(raised);
    const p = g.player();
    g.entityCtl.placeAt(p.x - c.ux * behind, p.z - c.uy * behind, 0, c.away);
    g.entityCtl.wake();
  }, { c, behind, raised });
}

/**
 * Runs inside the page, one check per animation frame: records the instrument, and the moment the
 * Orderly is within `turnAt` metres, turns to face it. Resolves with the samples and the distance
 * at the turn. Doing the turn in the page keeps the test's own round trip out of the timing.
 */
function turnWhenWithin(page: Page, c: Corridor, turnAt: number) {
  return page.evaluate(({ face, turnAt }) => new Promise<{ samples: Sample[]; turnedAt: number }>((resolve, reject) => {
    const g = (window as any).__gd;
    const samples: Sample[] = [];
    const t0 = performance.now();
    const loop = (): void => {
      const o = g.orderly();
      const i = g.instrument();
      const a = g.audio.state();
      samples.push({ t: (performance.now() - t0) / 1000, d: o.distance, needle: i.needle, value: i.value, hz: i.tickHz, angle: i.needleAngle, audioHz: a.tickHz, cadence: a.cadenceHz });
      if (o.distance <= turnAt) {
        g.look(face, 0);
        resolve({ samples, turnedAt: o.distance });
        return;
      }
      if (performance.now() - t0 > 20_000 || g.events().some((e: any) => e.type === 'caught')) {
        reject(new Error(`never got within ${turnAt} m (last ${o.distance.toFixed(2)} m)`));
        return;
      }
      requestAnimationFrame(loop);
    };
    loop();
  }), { face: c.face, turnAt });
}

/** The full routine on a fresh page: back turned at ~9.5 m, raised, turn at `turnAt`. */
async function routine(page: Page, turnAt: number, shots = false) {
  const c = await corridor(page, 6);
  await backTurned(page, c, 9.5, true);
  await page.waitForFunction(() => (window as any).__gd.instrument().needle === 'recording', undefined, { timeout: 5000 });
  const turning = turnWhenWithin(page, c, turnAt);
  if (shots) {
    // The slip prints on the first recording tick; once it is fully up, photograph it.
    await page.waitForFunction(() => (window as any).__gd.instrument().slip.shown === true, undefined, { timeout: 3000 });
    await page.waitForTimeout(1250);
    await page.screenshot({ path: `${SHOTS}/63-slip.png` });
    await page.waitForFunction(() => (window as any).__gd.orderly().distance < 4.2, undefined, { timeout: 8000 });
    const mid = await inst(page);
    expect(mid.needle).toBe('recording');
    await page.screenshot({ path: `${SHOTS}/61-recording.png` });
  }
  const { samples, turnedAt } = await turning;
  await page.waitForTimeout(350);
  const frozen = await orderly(page);
  const after = await inst(page);
  if (shots) await page.screenshot({ path: `${SHOTS}/62-turned.png` });
  await page.waitForFunction(() => (window as any).__gd.crewEvents().some((e: any) => e.type === 'readingClosed'), undefined, { timeout: 4000 });
  const closed = (await crewEvents(page)).find((e) => e.type === 'readingClosed')!;
  const rec = samples.filter((s) => s.needle === 'recording');
  return { c, samples, rec, turnedAt, frozen, after, closed, end: await inst(page) };
}

test('staring earns nothing: facing it at 6 m with the instrument up, the needle only twitches', async ({ page }) => {
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const c = await corridor(page, 6);
  await page.evaluate((c) => {
    const g = (window as any).__gd;
    g.teleport(0, c.cell.x, c.cell.y, c.face);
    g.look(c.face, 4);
    g.raise(true);
    const p = g.player();
    g.entityCtl.placeAt(p.x - c.ux * 6, p.z - c.uy * 6, 0, c.away);
    g.entityCtl.wake();
  }, c);
  await settle(page, 6);
  const t0 = Date.now();
  const angles: number[] = [];
  while (Date.now() - t0 < 4000) {
    const i = await inst(page);
    const o = await orderly(page);
    expect(o.seen).toBe(true);
    expect(i.raised).toBe(true);
    expect(i.needle).toBe('dormant');
    expect(i.value).toBe(0);
    expect(i.tickHz).toBe(1);
    angles.push(i.needleAngle);
    await page.waitForTimeout(100);
  }
  expect((await crewEvents(page)).length).toBe(0);
  // The needle twitches without words: it does not sit still on its peg.
  const spread = Math.max(...angles) - Math.min(...angles);
  console.log(`dormant: needle angle spread ${spread.toFixed(1)} deg over 4 s, tick ${(await inst(page)).tickHz} Hz`);
  expect(spread).toBeGreaterThan(2);
  await page.screenshot({ path: `${SHOTS}/60-instrument-dormant.png` });
  expect(errors).toEqual([]);
});

test('the routine pays: back turned it records and the ticking races; turn round at 2.5 m and it freezes', async ({ page }) => {
  test.setTimeout(90_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const audio0 = await page.evaluate(() => (window as any).__gd.audio.state());
  expect(audio0.running).toBe(true);
  const r = await routine(page, 2.5, true);

  // While recording: value and tick rate climb.
  expect(r.rec.length).toBeGreaterThan(20);
  const first = r.rec[0]!;
  const last = r.rec[r.rec.length - 1]!;
  expect(last.value).toBeGreaterThan(first.value + 20);
  expect(last.hz).toBeGreaterThan(first.hz + 3);
  expect(last.angle).toBeGreaterThan(first.angle + 20);
  // Turned: it is close, frozen, and recording has stopped.
  expect(r.turnedAt).toBeLessThanOrEqual(2.5);
  expect(r.frozen.frozen).toBe(true);
  expect(r.frozen.distance).toBeGreaterThan(2.0);
  expect(r.after.needle).not.toBe('recording');
  // The reading closed onto the tape.
  expect(r.closed.value).toBeGreaterThan(0);
  expect(r.end.total).toBeCloseTo(r.closed.value!, 6);
  expect(r.end.tapes).toBe(1);
  // The camcorder display shows one tape and its worth (after the jump's blink).
  await page.waitForFunction(() => /^#x1 \d{4}$/.test((window as any).__gd.instrument().osd), undefined, { timeout: 3000 });
  expect((await inst(page)).osd).toBe(`#x1 ${String(Math.floor(r.end.total)).padStart(4, '0')}`);
  // The slip: printed once, with exactly the logic's words.
  const slips = (await crewEvents(page)).filter((e) => e.type === 'slip');
  expect(slips.length).toBe(1);
  expect(slips[0]!.text).toBe('recorded while: subject moving');
  expect(r.end.slip.text).toBe('recorded while: subject moving');

  // The sound follows the logic: the ticking plays at the logic's rate, and the trolley's cadence
  // drops from a run's rattle far off to the creep's slow creak close in.
  for (const s of r.rec) expect(s.audioHz).toBeCloseTo(s.hz, 6);
  const far = r.rec.filter((s) => s.d > 6.5);
  const near = r.rec.filter((s) => s.d < 4);
  expect(Math.max(...far.map((s) => s.cadence))).toBeGreaterThan(2);
  expect(Math.max(...near.map((s) => s.cadence))).toBeLessThan(1.2);
  console.log(`squeak cadence: far ${Math.max(...far.map((s) => s.cadence)).toFixed(2)} Hz, near ${Math.max(...near.map((s) => s.cadence)).toFixed(2)} Hz`);
  const a = await page.evaluate(() => (window as any).__gd.audio.state());
  expect(a.ticks).toBeGreaterThan(10);
  expect(a.thunks).toBe(1);
  expect(a.rasps).toBe(2);
  const secs = r.closed.reading!.duration;
  console.log(
    `turn at 2.5 m: value ${r.closed.value!.toFixed(1)} after ${secs.toFixed(2)} s recording (turned at ${r.turnedAt.toFixed(2)} m, froze at ${r.frozen.distance.toFixed(2)} m); ` +
      `tick ${first.hz.toFixed(1)} -> ${last.hz.toFixed(1)} Hz; needle ${first.angle.toFixed(0)} -> ${last.angle.toFixed(0)} deg; audio ticks ${a.ticks} thunks ${a.thunks} rasps ${a.rasps}`,
  );
  const curve = r.rec.filter((_, i) => i % 10 === 0).map((s) => `${s.t.toFixed(1)}s ${s.d.toFixed(1)}m ${s.value.toFixed(0)} ${s.hz.toFixed(1)}Hz`);
  console.log(`recording curve: ${curve.join(' | ')}`);
  await settle(page, 60);
  console.log(`earn frameMs=${(await page.evaluate(() => (window as any).__gd.frameMs() as number)).toFixed(2)}`);
  expect(errors).toEqual([]);
});

async function freshRoutine(browser: Browser, turnAt: number) {
  const page = await browser.newPage();
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const r = await routine(page, turnAt);
  expect(errors).toEqual([]);
  await page.close();
  return r;
}

test('greed pays more: turning at 1.3 m is worth clearly more than at 2.5 m', async ({ browser }) => {
  test.setTimeout(90_000);
  const safe = await freshRoutine(browser, 2.5);
  const greedy = await freshRoutine(browser, 1.3);
  const ratio = greedy.closed.value! / safe.closed.value!;
  console.log(
    `greed: 2.5 m -> ${safe.closed.value!.toFixed(1)} (${safe.closed.reading!.duration.toFixed(2)} s), ` +
      `1.3 m -> ${greedy.closed.value!.toFixed(1)} (${greedy.closed.reading!.duration.toFixed(2)} s, turned at ${greedy.turnedAt.toFixed(2)} m), ratio ${ratio.toFixed(2)}; ` +
      `tick max ${Math.max(...greedy.rec.map((s) => s.hz)).toFixed(1)} Hz`,
  );
  expect(greedy.frozen.frozen).toBe(true);
  expect(ratio).toBeGreaterThanOrEqual(1.4);
});

test('being taken drops the tape where you fell; walk back and pick it up', async ({ page }) => {
  test.setTimeout(90_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1&debug=1');
  const hideDebug = (on: boolean) => page.evaluate((h) => { (document.getElementById('debug') as HTMLElement).style.visibility = h ? 'hidden' : ''; }, on);
  const r = await routine(page, 2.5);
  const earned = r.end.total;
  expect(earned).toBeGreaterThan(0);

  // Back turned again, and never turn round. The elevator is called first: a catch with the car gone
  // ends the run (a wipe), while one with the car coming is the placeholder and play goes on.
  const where = await page.evaluate((c) => {
    const g = (window as any).__gd;
    g.runCtl.call({ force: true });
    g.look(c.away, 0);
    return g.player();
  }, r.c);
  await page.waitForFunction(() => (window as any).__gd.events().some((e: any) => e.type === 'caught'), undefined, { timeout: 15_000 });
  await settle(page, 2);
  const dropped = await page.evaluate(() => (window as any).__gd.tapes());
  expect(dropped.length).toBe(1);
  expect(Math.hypot(dropped[0].x - where.x, dropped[0].z - where.z)).toBeLessThan(0.05);
  expect(dropped[0].value).toBeGreaterThanOrEqual(earned);
  expect((await inst(page)).total).toBe(0);
  expect((await crewEvents(page)).some((e) => e.type === 'tapeDropped')).toBe(true);
  // Back at the landing.
  await page.waitForFunction(() => (window as any).__gd.caught().line === true, undefined, { timeout: 5000 });
  const back = await page.evaluate(() => { const g = (window as any).__gd; return { p: g.player(), l: g.plan.landing }; });
  expect({ x: back.p.cx, y: back.p.cy, level: back.p.level }).toEqual({ x: back.l.x, y: back.l.y, level: back.l.level });
  const i0 = await inst(page);
  expect(i0.total).toBe(0);
  expect(i0.osd).toBe('');
  // The debug minimap lists it.
  await settle(page, 12);
  expect(await page.locator('#debug').innerText()).toMatch(/on floor 1/);
  await page.locator('#debug').screenshot({ path: `${SHOTS}/67-minimap-tape.png` });

  // The Orderly out of the way; walk back to the cell before the tape and look at it.
  await page.evaluate(() => {
    const g = (window as any).__gd;
    g.raise(null);
    g.entityCtl.placeCell(g.plan.landing.level, g.plan.entityStart.x, g.plan.entityStart.y);
    g.entityCtl.setTimeScale(0);
  });
  const t = dropped[0];
  // One cell short of it, on the side you walk in from, looking toward it.
  const before = { x: t.cx + r.c.ux, y: t.cy + r.c.uy };
  await page.evaluate(({ b }) => (window as any).__gd.walkTo(0, b.x, b.y), { b: before });
  await page.evaluate(({ c }) => (window as any).__gd.look(c.face, -24), { c: r.c });
  await page.waitForFunction(() => (window as any).__gd.caught().line === false, undefined, { timeout: 6000 });
  await settle(page, 8);
  expect(await page.evaluate(() => (window as any).__gd.pickupShown())).toBe(false);
  await hideDebug(true);
  await page.screenshot({ path: `${SHOTS}/64-tape-on-floor.png` });
  await hideDebug(false);

  // Onto it: the prompt shows, and E picks it up.
  await page.evaluate(({ t }) => (window as any).__gd.walkTo(0, t.cx, t.cy), { t });
  await settle(page, 4);
  expect(await page.evaluate(() => (window as any).__gd.pickupShown())).toBe(true);
  await page.keyboard.press('KeyE');
  await settle(page, 4);
  const got = await inst(page);
  expect(got.total).toBeCloseTo(dropped[0].value, 6);
  expect(got.carrying).toBe(1);
  expect(got.tapes).toBe(1);
  expect(await page.evaluate(() => (window as any).__gd.tapes().length)).toBe(0);
  expect(await page.evaluate(() => (window as any).__gd.pickupShown())).toBe(false);
  await page.evaluate(({ c }) => (window as any).__gd.look(c.away, 0), { c: r.c });
  // The camcorder display shows the tape you now carry (after the jump's blink).
  await page.waitForFunction(() => /^#x1 \d{4}$/.test((window as any).__gd.instrument().osd), undefined, { timeout: 3000 });
  await expect(page.locator('#osd .osd-tape')).toBeVisible();
  await hideDebug(true);
  await page.screenshot({ path: `${SHOTS}/65-picked-up.png` });
  console.log(`taken: earned ${earned.toFixed(1)}, dropped tape worth ${dropped[0].value.toFixed(1)}, picked up -> total ${got.total.toFixed(1)}`);
  expect(errors).toEqual([]);
});

test('lowered, nothing records, even with it moving right behind you', async ({ page }) => {
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&depth=1');
  const c = await corridor(page, 6);
  await backTurned(page, c, 9.5, false);
  await page.waitForFunction(() => (window as any).__gd.orderly().moving === true, undefined, { timeout: 5000 });
  const t0 = Date.now();
  let closest = 99;
  while (Date.now() - t0 < 2500) {
    const i = await inst(page);
    const o = await orderly(page);
    closest = Math.min(closest, o.distance);
    expect(i.raised).toBe(false);
    expect(i.needle).toBe('off');
    expect(i.value).toBe(0);
    expect(i.tickHz).toBe(0);
    if (o.distance < 3) break;
    await page.waitForTimeout(80);
  }
  await page.evaluate((y) => (window as any).__gd.look(y, 0), c.face);
  await page.waitForTimeout(2000);
  expect(closest).toBeLessThan(7);
  expect((await crewEvents(page)).length).toBe(0);
  expect((await inst(page)).total).toBe(0);
  expect(errors).toEqual([]);
});

test('raised, real key input cannot walk faster than the cap', async ({ page }) => {
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&entity=0');
  await page.evaluate(() => {
    const g = (window as any).__gd;
    const s = g.plan.sightlines.filter((l: any) => l.level === 0).sort((a: any, b: any) => b.length - a.length)[0];
    const yaw = (Math.atan2(-(s.x2 - s.x1), -(s.y2 - s.y1)) * 180) / Math.PI;
    g.teleport(0, s.x1, s.y1, yaw);
  });
  const sample = () => page.evaluate(() => { const p = (window as any).__gd.player(); return { x: p.x as number, z: p.z as number, t: performance.now() / 1000 }; });
  const speedOver = async (ms: number) => {
    await page.waitForTimeout(250);
    const a = await sample();
    await page.waitForTimeout(ms);
    const b = await sample();
    return Math.hypot(b.x - a.x, b.z - a.z) / (b.t - a.t);
  };
  await page.keyboard.down('KeyW');
  const free = await speedOver(500);
  await page.keyboard.up('KeyW');
  await page.keyboard.down('KeyF');
  await settle(page, 2);
  expect((await inst(page)).raised).toBe(true);
  await page.keyboard.down('KeyW');
  const capped = await speedOver(500);
  await page.keyboard.up('KeyW');
  await page.keyboard.up('KeyF');
  await settle(page, 2);
  expect((await inst(page)).raised).toBe(false);
  // The right mouse button raises it too.
  await page.mouse.move(640, 360);
  await page.mouse.down({ button: 'right' });
  await settle(page, 2);
  expect((await inst(page)).raised).toBe(true);
  await page.mouse.up({ button: 'right' });
  await settle(page, 2);
  expect((await inst(page)).raised).toBe(false);
  console.log(`walk speed: free ${free.toFixed(2)} m/s, raised ${capped.toFixed(2)} m/s`);
  expect(free).toBeGreaterThan(2.7);
  expect(capped).toBeLessThan(2.3);
  expect(capped).toBeGreaterThan(1.9);
  expect(errors).toEqual([]);
});

test.describe('phone', () => {
  test.use({ viewport: { width: 844, height: 390 }, hasTouch: true });

  test('the hold-button raises the instrument while the same thumb still looks; the latch keeps it up', async ({ page }) => {
    const errors = watchErrors(page);
    await page.goto('/?seed=alpha&depth=1');
    await page.waitForFunction(() => (window as any).__gd?.ready === true);
    await page.waitForFunction(() => (window as any).__gd.orderly()?.loaded === true, undefined, { timeout: 30_000 });
    mkdirSync(SHOTS, { recursive: true });
    // Real PointerEvents with pointerType "touch", sent to whatever is under the finger.
    const touch = (type: string, id: number, x: number, y: number) =>
      page.evaluate(([t, i, cx, cy]) => {
        const el = document.elementFromPoint(cx as number, cy as number) ?? document.body;
        el.dispatchEvent(new PointerEvent(t as string, { pointerId: i as number, pointerType: 'touch', clientX: cx as number, clientY: cy as number, bubbles: true, isPrimary: true }));
      }, [type, id, x, y]);
    const yaw = () => page.evaluate(() => (window as any).__gd.player().yaw as number);

    await touch('pointerdown', 1, 400, 200);
    await touch('pointerup', 1, 400, 200);
    await expect(page.locator('#start')).toBeHidden();
    await expect(page.locator('#raise-btn')).toBeVisible();
    await expect(page.locator('#latch-btn')).toBeVisible();
    const box = (await page.locator('#raise-btn').boundingBox())!;
    const bx = box.x + box.width / 2;
    const by = box.y + box.height / 2;
    // Under the right thumb: right-hand side, lower half.
    expect(bx).toBeGreaterThan(844 * 0.7);
    expect(by).toBeGreaterThan(390 * 0.5);

    // Look somewhere interesting: down the longest corridor, the Orderly at its far end.
    await page.evaluate(() => {
      const g = (window as any).__gd;
      const s = g.plan.sightlines.filter((l: any) => l.level === 0).sort((a: any, b: any) => b.length - a.length)[0];
      const y = (Math.atan2(-(s.x2 - s.x1), -(s.y2 - s.y1)) * 180) / Math.PI;
      g.teleport(0, s.x1 + Math.sign(s.x2 - s.x1) * 4, s.y1 + Math.sign(s.y2 - s.y1) * 4, y - 20);
      g.entityCtl.placeCell(0, s.x2, s.y2);
    });
    const y0 = await yaw();
    await touch('pointerdown', 2, bx, by);
    await settle(page, 3);
    expect((await inst(page)).raised).toBe(true);
    // Same finger drags left: the view turns, and the instrument stays up.
    await touch('pointermove', 2, bx - 40, by);
    await settle(page, 3);
    await touch('pointermove', 2, bx - 30, by - 4);
    await settle(page, 12);
    const y1 = await yaw();
    expect(Math.abs(y1 - y0)).toBeGreaterThan(10);
    expect((await inst(page)).raised).toBe(true);
    await page.screenshot({ path: `${SHOTS}/66-phone-instrument.png` });
    await touch('pointerup', 2, bx - 30, by - 4);
    await settle(page, 3);
    expect((await inst(page)).raised).toBe(false);

    // The latch: tap it and the instrument stays up with no finger on it; tap again to lower.
    const lb = (await page.locator('#latch-btn').boundingBox())!;
    await touch('pointerdown', 3, lb.x + lb.width / 2, lb.y + lb.height / 2);
    await touch('pointerup', 3, lb.x + lb.width / 2, lb.y + lb.height / 2);
    await settle(page, 3);
    expect((await inst(page)).raised).toBe(true);
    // A look-drag elsewhere still works while latched.
    const y2 = await yaw();
    await touch('pointerdown', 4, 650, 150);
    await touch('pointermove', 4, 700, 150);
    await settle(page, 3);
    await touch('pointerup', 4, 700, 150);
    expect(Math.abs((await yaw()) - y2)).toBeGreaterThan(8);
    expect((await inst(page)).raised).toBe(true);
    await touch('pointerdown', 5, lb.x + lb.width / 2, lb.y + lb.height / 2);
    await touch('pointerup', 5, lb.x + lb.width / 2, lb.y + lb.height / 2);
    await settle(page, 3);
    expect((await inst(page)).raised).toBe(false);
    expect(errors).toEqual([]);
  });
});
