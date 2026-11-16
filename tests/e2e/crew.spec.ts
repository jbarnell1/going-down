import { mkdirSync } from 'node:fs';
import { expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test';

// A crew of four in one browser: four tabs of one context, on one room over a BroadcastChannel
// (?net=local), seed alpha. One tab hosts (it pressed START A CREW), three join. Real time, four
// WebGL pages at once: this runs on the development PC only.
test.skip(!!process.env.CI, 'needs a real graphics card, real time and four tabs');

const SHOTS = 'test-results/shots';
const NAMES = ['ALPHA 1001', 'BRAVO 2002', 'CHARLIE 3003', 'DELTA 4004'];

type Crew = { context: BrowserContext; pages: Page[]; errors: string[][]; ids: string[]; room: string };
type Drawn = { id: string; name: string; x: number; y: number; z: number; raised: boolean };
type Ord = { x: number; z: number; distance: number; seen: boolean; phase: string; drawn: { x: number; z: number; anim: string; frozen: boolean } | null };
type Row = { f: number; vis: boolean; dx: number; dz: number };

const gd = <T>(page: Page, fn: string, arg?: unknown): Promise<T> =>
  page.evaluate(([f, a]) => {
    const g = (window as any).__gd;
    const parts = (f as string).split('.');
    let o = g;
    for (let i = 0; i < parts.length - 1; i++) o = o[parts[i] as string];
    return o[parts[parts.length - 1] as string](a);
  }, [fn, arg] as const) as Promise<T>;

function watch(page: Page): string[] {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  return errors;
}

async function settle(page: Page, frames = 4): Promise<void> {
  const start = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((n) => (window as any).__gd.frames >= n, start + frames);
}

/** Four tabs: the first starts a crew, the others open its link and join; the host goes down. */
async function gather(browser: Browser, n = 4): Promise<Crew> {
  mkdirSync(SHOTS, { recursive: true });
  const context = await browser.newContext({ viewport: { width: 960, height: 540 } });
  const room = `Q${Math.floor(Math.random() * 1e6).toString(36).toUpperCase()}`;
  const pages: Page[] = [];
  const errors: string[][] = [];
  for (let i = 0; i < n; i++) {
    const page = await context.newPage();
    errors.push(watch(page));
    await page.goto(i === 0 ? '/?net=local&seed=alpha' : `/?net=local&seed=alpha&room=${room}`);
    await page.waitForFunction(() => (window as any).__gd?.ready === true);
    await gd(page, 'lobby.setName', NAMES[i]);
    if (i === 0) await gd(page, 'lobby.startCrew', room);
    else await gd(page, 'lobby.join');
    pages.push(page);
  }
  const host = pages[0] as Page;
  await host.waitForFunction((k) => (window as any).__gd.net().peers.filter((p: any) => p.name).length === k, n - 1, { timeout: 20_000 });
  expect(await gd(host, 'lobby.goDown')).toBe(true);
  for (const p of pages) {
    await p.waitForFunction(() => { const g = (window as any).__gd; return g.net().inRun === true && g.run().phase !== 'none'; }, undefined, { timeout: 20_000 });
    await gd(p, 'start');
  }
  const ids: string[] = [];
  for (const p of pages) ids.push((await gd<{ me: string }>(p, 'net')).me);
  return { context, pages, errors, ids, room };
}

const yawToward = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;

async function corridor(page: Page) {
  return page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    const yawT = (dx: number, dz: number): number => (Math.atan2(-dx, -dz) * 180) / Math.PI;
    return { x2: s.x2, y2: s.y2, ux, uy, face: yawT(-ux, -uy), away: yawT(ux, uy), length: s.length as number };
  });
}
type Corridor = Awaited<ReturnType<typeof corridor>>;

/** Puts every page's player on a corridor cell (k cells from the x2 end), facing as given; waits until the host has them there. */
async function stand(c: Crew, cor: Corridor, spots: { k: number; yaw: number; pitch?: number }[]): Promise<void> {
  await Promise.all(c.pages.map((p, i) => {
    const s = spots[i] as { k: number; yaw: number; pitch?: number };
    return p.evaluate(([x, y, yaw, pitch]) => { const g = (window as any).__gd; g.teleport(0, x, y, yaw); g.look(yaw, pitch); }, [cor.x2 + cor.ux * s.k, cor.y2 + cor.uy * s.k, s.yaw, s.pitch ?? 0] as const);
  }));
  // The host takes a remote player's jump only once it is no faster than a run allows: wait for it.
  await waitHostHas(c);
  for (const p of c.pages) await settle(p, 3);
}

/** Waits until the host has every player where that player's own page has them. */
async function waitHostHas(c: Crew): Promise<void> {
  const host = c.pages[0] as Page;
  await expect.poll(async () => {
    const truth = await Promise.all(c.pages.map((p) => gd<{ x: number; z: number }>(p, 'player')));
    const seen = await gd<{ id: string; x: number; z: number; status: string }[]>(host, 'players');
    return Math.max(...c.ids.map((id, i) => {
      const q = seen.find((s) => s.id === id);
      if (q && q.status !== 'ok') return 0;
      const t = truth[i] as { x: number; z: number };
      return q ? Math.hypot(q.x - t.x, q.z - t.z) : 99;
    }));
  }, { timeout: 20_000, intervals: [200] }).toBeLessThan(0.3);
}

/** Out of the car onto the landing, spread across it. */
async function stepOut(c: Crew): Promise<void> {
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 10_000 });
  const vs = [0, -1.3, 0, 1.3];
  const us = [-1.2, -1.7, -2.3, -1.7];
  await Promise.all(c.pages.map((p, i) => p.evaluate(([u, v]) => (window as any).__gd.runCtl.walkCar(u, v), [us[i], vs[i]] as const)));
}

async function close(c: Crew): Promise<void> {
  for (const [i, p] of c.pages.entries()) {
    if (p.isClosed()) continue;
    const ms = await gd<number>(p, 'frameMs');
    console.log(`page ${i} (${NAMES[i]}): frameMs=${ms.toFixed(2)}`);
  }
  for (const e of c.errors) expect(e).toEqual([]);
  await c.context.close();
}

test('a crew of four: the same building, each other in it, and the rule across four screens', async ({ browser }) => {
  test.setTimeout(240_000);
  const c = await gather(browser);
  const [a, b, cc, d] = c.pages as [Page, Page, Page, Page];

  // 1. All four on the first floor of the same building.
  const keys = await Promise.all(c.pages.map((p) => gd<{ planKey: string; depth: number }>(p, 'run')));
  for (const k of keys) {
    expect(k.depth).toBe(1);
    expect(k.planKey).toBe(keys[0]?.planKey);
  }
  const net = await gd<{ role: string; peers: { name: string }[] }>(a, 'net');
  expect(net.role).toBe('host');
  expect(net.peers.map((p) => p.name).sort()).toEqual(NAMES.slice(1).sort());
  expect((await gd<{ role: string; host: string }>(b, 'net')).role).toBe('client');

  // 2. Each sees the other three. Out of the car, the host turned round to face the others.
  await stepOut(c);
  await a.evaluate(() => {
    const g = (window as any).__gd;
    const l = g.plan.landing;
    const p = g.player();
    const fx = Math.round(-Math.sin((p.yaw * Math.PI) / 180));
    const fz = Math.round(-Math.cos((p.yaw * Math.PI) / 180));
    return g.walkTo(l.level, l.x + 3 * fx, l.y + 3 * fz);
  });
  for (const p of c.pages) await settle(p, 20);
  // Everyone else faces the host.
  const pa = await gd<{ x: number; z: number }>(a, 'player');
  for (const p of [b, cc, d]) {
    const q = await gd<{ x: number; z: number }>(p, 'player');
    await p.evaluate((y) => (window as any).__gd.look(y, 0), yawToward(pa.x - q.x, pa.z - q.z));
  }
  const others = await Promise.all([b, cc, d].map((p) => gd<{ x: number; z: number }>(p, 'player')));
  const mx = others.reduce((s, o) => s + o.x, 0) / 3;
  const mz = others.reduce((s, o) => s + o.z, 0) / 3;
  await a.evaluate((y) => (window as any).__gd.look(y, -4), yawToward(mx - pa.x, mz - pa.z));
  await a.waitForTimeout(800);
  for (const [i, p] of c.pages.entries()) {
    const drawn = await gd<Drawn[]>(p, 'crew');
    expect(drawn.map((f) => f.name).sort(), `page ${i} draws the other three`).toEqual(NAMES.filter((_, j) => j !== i).sort());
  }
  await a.screenshot({ path: `${SHOTS}/100-crew.png` });

  // Move one player; a moment later the other three draw them within half a metre of where they are.
  const dCell = await d.evaluate(() => { const g = (window as any).__gd; const p = g.player(); return { x: p.cx, y: p.cy, level: p.level }; });
  await d.evaluate((t) => (window as any).__gd.walkTo(t.level, t.x, t.y + 1), dCell).catch(() => d.evaluate((t) => (window as any).__gd.walkTo(t.level, t.x + 1, t.y), dCell));
  await d.waitForTimeout(600);
  const truth = await gd<{ x: number; z: number }>(d, 'player');
  let worst = 0;
  for (const p of [a, b, cc]) {
    const f = (await gd<Drawn[]>(p, 'crew')).find((q) => q.id === c.ids[3]);
    expect(f).toBeTruthy();
    const e = Math.hypot((f as Drawn).x - truth.x, (f as Drawn).z - truth.z);
    worst = Math.max(worst, e);
    expect(e).toBeLessThan(0.5);
  }
  console.log(`moved player drawn within ${worst.toFixed(3)} m on the other three pages`);

  // 3. The rule across tabs. The Orderly at the end of the longest corridor; A faces it, B, C, D face away.
  const cor = await corridor(a);
  await a.evaluate(() => (window as any).__gd.entityCtl.rest(600));
  await stand(c, cor, [{ k: 10, yaw: cor.face }, { k: 11, yaw: cor.away }, { k: 12, yaw: cor.away }, { k: 13, yaw: cor.away }]);
  await a.evaluate((v) => { const g = (window as any).__gd; g.entityCtl.placeCell(0, v.x2, v.y2, v.away + 180); g.entityCtl.wake(); }, cor);
  for (const p of c.pages) await settle(p, 10);
  expect((await gd<Ord>(a, 'orderly')).seen).toBe(true);
  const drawnAll = async (): Promise<{ x: number; z: number }[]> => Promise.all(c.pages.map(async (p) => {
    const o = await gd<Ord>(p, 'orderly');
    return { x: o.drawn?.x ?? NaN, z: o.drawn?.z ?? NaN };
  }));
  const frozen0 = await drawnAll();
  let spread = 0;
  const t0 = Date.now();
  while (Date.now() - t0 < 3000) {
    const now = await drawnAll();
    for (const q of now) {
      spread = Math.max(spread, Math.hypot(q.x - (frozen0[0] as { x: number }).x, q.z - (frozen0[0] as { z: number }).z));
      expect([q.x, q.z]).toEqual([(frozen0[0] as { x: number }).x, (frozen0[0] as { z: number }).z]);
    }
    await a.waitForTimeout(100);
  }
  await a.screenshot({ path: `${SHOTS}/101-watched-by-one.png` });
  // A turns away: within 2 s it moves on every page.
  await a.evaluate((y) => (window as any).__gd.look(y, 0), cor.away);
  const tTurn = Date.now();
  const movedAt: number[] = [-1, -1, -1, -1];
  while (Date.now() - tTurn < 2000 && movedAt.some((m) => m < 0)) {
    const now = await drawnAll();
    now.forEach((q, i) => {
      if (movedAt[i] === -1 && Math.hypot(q.x - (frozen0[0] as { x: number }).x, q.z - (frozen0[0] as { z: number }).z) > 0.05) movedAt[i] = Date.now() - tTurn;
    });
    await a.waitForTimeout(25);
  }
  console.log(`rule: frozen for 3 s on all four pages, largest disagreement ${spread.toFixed(3)} m; moving after A turned away: ${movedAt.map((m, i) => `${NAMES[i]} ${m} ms`).join(', ')}`);
  for (const m of movedAt) expect(m).toBeGreaterThanOrEqual(0);
  // B turns to face it: from B's first frame after turning, constant for a full second.
  await b.waitForTimeout(700);
  const f0 = await b.evaluate((y) => { const g = (window as any).__gd; g.look(y, 0); return g.frames as number; }, cor.face);
  await b.waitForTimeout(1100);
  const rows = (await b.evaluate(() => (window as any).__gd.entityCtl.trace() as Row[])).filter((r) => r.f > f0);
  expect(rows.length).toBeGreaterThan(20);
  const r0 = rows[0] as Row;
  for (const r of rows) {
    expect(r.vis).toBe(true);
    expect([r.dx, r.dz]).toEqual([r0.dx, r0.dz]);
  }
  // Settled: all four pages agree on where it is (the host put it back where B froze it).
  await a.waitForTimeout(300);
  const settled = await drawnAll();
  let agree = 0;
  for (const q of settled) agree = Math.max(agree, Math.hypot(q.x - r0.dx, q.z - r0.dz));
  console.log(`B froze it at ${r0.dx.toFixed(2)}, ${r0.dz.toFixed(2)} for ${rows.length} frames; pages agree within ${agree.toFixed(3)} m`);
  expect(agree).toBeLessThan(0.02);
  await a.evaluate(() => (window as any).__gd.entityCtl.rest(600));
  await close(c);
});

test('a crew of four: a reading on every screen, a taken crewmate, and their tape picked up', async ({ browser }) => {
  test.setTimeout(240_000);
  const c = await gather(browser);
  const [a, b, cc, d] = c.pages as [Page, Page, Page, Page];
  await stepOut(c);
  const cor = await corridor(a);
  await a.evaluate(() => (window as any).__gd.entityCtl.rest(600));
  // B in the corridor with its back to the far end, instrument up; the others look at the floor.
  await stand(c, cor, [{ k: 16, yaw: cor.away, pitch: -85 }, { k: 6, yaw: cor.away }, { k: 17, yaw: cor.away, pitch: -85 }, { k: 18, yaw: cor.away, pitch: -85 }]);
  await b.evaluate(() => (window as any).__gd.raise(true));
  const bp = await gd<{ x: number; z: number }>(b, 'player');
  await a.evaluate(([x, z, yaw]) => { const g = (window as any).__gd; g.entityCtl.placeAt(x, z, 0, yaw); g.entityCtl.wake(); }, [bp.x - cor.ux * 9.5, bp.z - cor.uy * 9.5, cor.away] as const);
  await b.waitForFunction(() => (window as any).__gd.instrument().needle === 'recording', undefined, { timeout: 8000 });
  // B turns round at 2.5 m (in the page, so the test's own round trip is not in the timing).
  await b.evaluate((face) => new Promise<void>((resolve) => {
    const g = (window as any).__gd;
    const loop = (): void => { if (g.orderly().distance <= 2.5) { g.look(face, 0); resolve(); } else requestAnimationFrame(loop); };
    loop();
  }), cor.face);
  await b.waitForFunction(() => (window as any).__gd.crewEvents().some((e: any) => e.type === 'readingClosed'), undefined, { timeout: 6000 });
  await b.evaluate(() => (window as any).__gd.raise(null));
  const earned = (await gd<{ total: number }>(b, 'instrument')).total;
  expect(earned).toBeGreaterThan(0);
  for (const [i, p] of c.pages.entries()) {
    await p.waitForFunction(([n, v]) => (window as any).__gd.crewList().rows.some((r: any) => r.name === n && Math.floor(r.total) === Math.floor(v as number)), [NAMES[1], earned] as const, { timeout: 4000 });
    expect((await p.evaluate(() => (window as any).__gd.crewList().shown)), `crew list on page ${i}`).toBe(true);
  }
  console.log(`B earned ${earned.toFixed(1)}; every crew list shows it`);

  // B turns away again and is taken (the others still look at the floor; the car is gone, but three are left).
  // B's page records every frame from here: whether the Orderly is on screen, the taken latch, the noise.
  await b.evaluate(() => {
    const g = (window as any).__gd;
    const w = window as any;
    w.__takenLog = [];
    const tick = (): void => {
      const o = g.orderly();
      w.__takenLog.push({ t: performance.now(), seen: o?.seen === true, taken: g.run().taken === true, noise: g.caught().noise === true });
      if (w.__takenLog.length < 4000) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  const where = await b.evaluate((y) => { const g = (window as any).__gd; g.look(y, 0); return g.player(); }, cor.away);
  await b.waitForFunction(() => (window as any).__gd.events().some((e: any) => e.type === 'caught'), undefined, { timeout: 20_000 });
  await b.waitForFunction(() => (window as any).__gd.caught().noise === true, undefined, { timeout: 4000 });
  // A remote victim's screen commits first: a hard cut to black (the taken latch), then the noise, and
  // no frame in the second before that commit showed it the Orderly.
  const log = await b.evaluate(() => (window as any).__takenLog as { t: number; seen: boolean; taken: boolean; noise: boolean }[]);
  const commit = log.findIndex((f) => f.taken || f.noise);
  expect(commit).toBeGreaterThan(0);
  expect(log[commit]?.taken).toBe(true);
  const commitT = log[commit]?.t ?? 0;
  expect(log.filter((f, k) => k < commit && f.t >= commitT - 1000 && f.seen)).toEqual([]);
  // Black until the noise takes over: no visible frame between.
  const noiseAt = log.findIndex((f) => f.noise);
  expect(log.slice(commit, noiseAt).every((f) => f.taken && !f.seen)).toBe(true);
  console.log(`B taken: black for ${(((log[noiseAt]?.t ?? commitT) - commitT) / 1000).toFixed(2)} s before the noise; no sighting in the second before`);
  for (const p of c.pages) {
    await p.waitForFunction((owner) => (window as any).__gd.tapes().some((t: any) => t.owner === owner), c.ids[1], { timeout: 4000 });
    const t = (await gd<{ owner: string; x: number; z: number; value: number }[]>(p, 'tapes')).find((q) => q.owner === c.ids[1]);
    expect(Math.hypot((t?.x ?? 0) - where.x, (t?.z ?? 0) - where.z)).toBeLessThan(0.3);
    expect(t?.value ?? 0).toBeGreaterThanOrEqual(earned - 0.01);
    await p.waitForFunction((n) => (window as any).__gd.crewList().rows.some((r: any) => r.name === n && r.mark === 'TAKEN'), NAMES[1], { timeout: 4000 });
  }
  // D walks to it and picks it up; it is gone from every floor and on D's tally.
  await a.evaluate(() => (window as any).__gd.entityCtl.rest(600));
  const tape = (await gd<{ cx: number; cy: number; level: number }[]>(d, 'tapes'))[0] as { cx: number; cy: number; level: number };
  await d.evaluate((t) => (window as any).__gd.walkTo(t.level, t.cx, t.cy), tape);
  await d.waitForFunction(() => (window as any).__gd.pickupShown() === true, undefined, { timeout: 4000 });
  // The test's walk is faster than a player can run: let the host catch up with D first.
  await waitHostHas(c);
  await d.evaluate(() => (window as any).__gd.pickUp());
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.tapes().length === 0, undefined, { timeout: 4000 });
  await d.waitForFunction((v) => Math.abs((window as any).__gd.instrument().total - (v as number)) < 0.02, earned, { timeout: 4000 });
  for (const p of c.pages) await p.waitForFunction(([n, v]) => (window as any).__gd.crewList().rows.some((r: any) => r.name === n && Math.floor(r.total) === Math.floor(v as number)), [NAMES[3], earned] as const, { timeout: 4000 });
  console.log(`B taken: the tape (${earned.toFixed(1)}) lay on every floor; D picked it up`);
  await close(c);
});

test('a crew of four: a whole run, the blinks on every screen, the vote, two floors and the bank', async ({ browser }) => {
  test.setTimeout(360_000);
  const c = await gather(browser);
  const [a, b, cc, d] = c.pages as [Page, Page, Page, Page];
  await stepOut(c);
  await a.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 20_000 });
  await a.evaluate(() => (window as any).__gd.entityCtl.rest(6000));
  const floor1 = (await gd<{ planKey: string }>(a, 'run')).planKey;
  // Every page records when its screen is dark.
  for (const p of c.pages) {
    await p.evaluate(() => {
      const w = window as any;
      w.__dark = [];
      let was = false;
      const loop = (): void => {
        const dark = w.__gd.run().dark as boolean;
        if (dark !== was) w.__dark.push([performance.now(), dark]);
        was = dark;
        requestAnimationFrame(loop);
      };
      loop();
    });
  }
  expect(await a.evaluate(() => (window as any).__gd.runCtl.call({ force: true }))).toBe(true);
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().car === 'coming', undefined, { timeout: 4000 });
  // Two blinks in real time.
  await a.waitForFunction(() => (window as any).__gd.runEvents().filter((e: any) => e.type === 'blinkEnd').length >= 2, undefined, { timeout: 40_000 });
  await a.waitForTimeout(600);
  const blinks = await a.evaluate(() => (window as any).__gd.runEvents().filter((e: any) => e.type === 'blinkStart').length as number);
  for (const [i, p] of c.pages.entries()) {
    const outs = await p.evaluate(() => ((window as any).__dark as [number, boolean][]).filter((x) => x[1]).length);
    expect(outs, `page ${i} went dark for each blink`).toBe(blinks);
  }
  console.log(`blinks: ${blinks}, every page dark for each`);
  // On to the blackout (skipped on the host): every screen goes dark and the emergency lights come up.
  for (let i = 0; i < 8 && !(await a.evaluate(() => (window as any).__gd.run().darkNow?.blackout === true)); i++) {
    expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('blinkSoon', 60))).toBe(true);
  }
  expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('blinkStart', 10))).toBe(true);
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().emergency === 1, undefined, { timeout: 8000 });
  await settle(b, 3);
  await b.screenshot({ path: `${SHOTS}/123-blackout-crew.png` });
  // The rest of the wait, skipped on the host (the others follow its clock).
  expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('carArrived', 90))).toBe(true);
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 8000 });
  // Board: three on DOWN, one on BANK.
  const spots: [number, number][] = [[1.65, -0.65], [0.4, 0.6], [1.0, 0.65], [1.6, 0.62]];
  await Promise.all(c.pages.map((p, i) => p.evaluate(([u, v]) => (window as any).__gd.runCtl.walkCar(u, v), spots[i] as [number, number])));
  for (const p of c.pages) await p.waitForFunction(() => { const v = (window as any).__gd.run().votes; return v.bank === 1 && v.down === 3; }, undefined, { timeout: 8000 });
  // From the back corner of BANK, looking across the car at the three on DOWN.
  const r = await gd<{ car3: { inX: number; inZ: number; rightX: number; rightZ: number } }>(a, 'run');
  const du = 0.9 - 1.65;
  const dv = 0.55 + 0.65;
  await a.evaluate((y) => (window as any).__gd.look(y, -28), yawToward(r.car3.inX * du + r.car3.rightX * dv, r.car3.inZ * du + r.car3.rightZ * dv));
  await settle(a, 8);
  await a.screenshot({ path: `${SHOTS}/102-voting.png` });
  expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('bell', 30))).toBe(true);
  expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('rodeDown', 10))).toBe(true);
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().depth === 2 && (window as any).__gd.plan !== undefined, undefined, { timeout: 8000 });
  const keys2 = await Promise.all(c.pages.map(async (p) => { await settle(p, 4); return (await gd<{ planKey: string; depth: number }>(p, 'run')); }));
  for (const k of keys2) {
    expect(k.depth).toBe(2);
    expect(k.planKey).toBe(keys2[0]?.planKey);
    expect(k.planKey).not.toBe(floor1);
  }
  // Floor two: out, a reading for the bank, call, and all on BANK.
  await stepOut(c);
  await a.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 20_000 });
  const cor = await corridor(a);
  await stand(c, cor, [{ k: 16, yaw: cor.away, pitch: -85 }, { k: 6, yaw: cor.away }, { k: 17, yaw: cor.away, pitch: -85 }, { k: 18, yaw: cor.away, pitch: -85 }]);
  await b.evaluate(() => (window as any).__gd.raise(true));
  const bp = await gd<{ x: number; z: number }>(b, 'player');
  await a.evaluate(([x, z, yaw]) => { const g = (window as any).__gd; g.entityCtl.placeAt(x, z, 0, yaw); g.entityCtl.wake(); }, [bp.x - cor.ux * 9.5, bp.z - cor.uy * 9.5, cor.away] as const);
  await b.waitForFunction(() => (window as any).__gd.instrument().needle === 'recording', undefined, { timeout: 8000 });
  await b.evaluate((face) => new Promise<void>((resolve) => {
    const g = (window as any).__gd;
    const loop = (): void => { if (g.orderly().distance <= 2.5) { g.look(face, 0); resolve(); } else requestAnimationFrame(loop); };
    loop();
  }), cor.face);
  await b.waitForFunction(() => (window as any).__gd.crewEvents().some((e: any) => e.type === 'readingClosed'), undefined, { timeout: 6000 });
  await b.evaluate(() => (window as any).__gd.raise(null));
  await a.evaluate(() => (window as any).__gd.entityCtl.rest(6000));
  // Everyone back to the landing.
  await Promise.all(c.pages.map((p) => p.evaluate(() => { const g = (window as any).__gd; const l = g.plan.landing; return g.walkTo(l.level, l.x, l.y); })));
  // The test walk is ten times a walk: the host takes remote bodies at the pace their gait allows, so wait for it.
  await waitHostHas(c);
  expect(await a.evaluate(() => (window as any).__gd.runCtl.call({ force: true }))).toBe(true);
  expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('carArrived', 90))).toBe(true);
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 8000 });
  const bank: [number, number][] = [[0.8, -0.45], [1.5, -0.45], [1.15, -0.25], [1.2, -0.6]];
  await Promise.all(c.pages.map((p, i) => p.evaluate(([u, v]) => (window as any).__gd.runCtl.walkCar(u, v), bank[i] as [number, number])));
  for (const p of c.pages) await p.waitForFunction(() => (window as any).__gd.run().votes.bank === 4, undefined, { timeout: 8000 });
  expect(await a.evaluate(() => (window as any).__gd.runCtl.skipUntil('banked', 30))).toBe(true);
  const ends: string[][] = [];
  for (const p of c.pages) {
    await p.waitForFunction(() => (window as any).__gd.run().endShown === true, undefined, { timeout: 10_000 });
    ends.push((await gd<{ endText: string[] }>(p, 'run')).endText);
  }
  const line = (t: string[], k: string): string => t.find((l) => l.startsWith(k)) ?? '';
  for (const t of ends) {
    expect(line(t, 'TOTAL')).toBe(line(ends[0] as string[], 'TOTAL'));
    expect(line(t, 'YOUR SHARE')).toBe(line(ends[0] as string[], 'YOUR SHARE'));
    for (const n of NAMES) expect(t.some((l) => l.startsWith(n.slice(0, 10)))).toBe(true);
  }
  expect(line(ends[0] as string[], 'TOTAL')).not.toBe('TOTAL 0000');
  console.log(`banked: ${line(ends[0] as string[], 'TOTAL')}, ${line(ends[0] as string[], 'YOUR SHARE')} on every page`);
  await cc.screenshot({ path: `${SHOTS}/103-banked-crew.png` });
  await close(c);
});

test('a crew of four: one leaves mid-run and the rest carry on; the host leaves and the session ends', async ({ browser }) => {
  test.setTimeout(120_000);
  const c = await gather(browser);
  const [a, b, cc, d] = c.pages as [Page, Page, Page, Page];
  await stepOut(c);
  await cc.close();
  for (const p of [a, b, d]) await p.waitForFunction((n) => (window as any).__gd.crewList().rows.some((r: any) => r.name === n && r.mark === 'GONE'), NAMES[2], { timeout: 10_000 });
  // The others carry on: the run's clock still runs on every page.
  const t0 = await Promise.all([a, b, d].map((p) => gd<{ t: number }>(p, 'run')));
  await a.waitForTimeout(1000);
  const t1 = await Promise.all([a, b, d].map((p) => gd<{ t: number }>(p, 'run')));
  t1.forEach((t, i) => expect(t.t).toBeGreaterThan((t0[i] as { t: number }).t + 0.5));
  // The host goes: the others are told the session is over.
  const hostMs = await gd<number>(a, 'frameMs');
  console.log(`page 0 (${NAMES[0]}) before closing: frameMs=${hostMs.toFixed(2)}`);
  await a.close();
  for (const p of [b, d]) {
    await p.waitForFunction(() => (window as any).__gd.net().ended === 'hostLeft', undefined, { timeout: 10_000 });
    await expect(p.locator('#lobby')).toBeVisible();
  }
  await b.screenshot({ path: `${SHOTS}/104-host-left.png` });
  c.pages = [b, d];
  c.errors = [c.errors[1] as string[], c.errors[3] as string[]];
  await close(c);
});

test('the lobby on a phone: start a crew, the code, the link, a name, and joining it', async ({ browser }) => {
  test.setTimeout(60_000);
  mkdirSync(SHOTS, { recursive: true });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const host = await context.newPage();
  const errors = [watch(host)];
  await host.goto('/?net=local');
  await host.waitForFunction(() => (window as any).__gd?.ready === true);
  await expect(host.locator('#start button[data-lobby="crew"]')).toBeVisible();
  await host.screenshot({ path: `${SHOTS}/105-start-phone.png` });
  await host.tap('#start button[data-lobby="crew"]');
  await expect(host.locator('#lobby')).toBeVisible();
  await host.waitForFunction(() => (window as any).__gd.net().room !== null && (window as any).__gd.lobby.status() !== 'OPENING THE ROOM...');
  const room = (await gd<{ room: string }>(host, 'net')).room;
  expect(new URL(host.url()).searchParams.get('room')).toBe(room);
  const join = await context.newPage();
  errors.push(watch(join));
  await join.goto(`/?net=local&room=${room}`);
  await join.waitForFunction(() => (window as any).__gd?.ready === true);
  await join.fill('#lobby-name', 'night shift');
  await join.tap('#lobby button[data-lobby="go"]:not([hidden])');
  await host.waitForFunction(() => (window as any).__gd.net().peers.some((p: any) => p.name === 'NIGHT SHIFT'), undefined, { timeout: 10_000 });
  await host.screenshot({ path: `${SHOTS}/106-lobby-phone-host.png` });
  await join.screenshot({ path: `${SHOTS}/107-lobby-phone-join.png` });
  // Nothing in the lobby is wider than the screen.
  for (const p of [host, join]) expect(await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1 && Math.max(...[...document.querySelectorAll('#lobby *')].map((e) => e.getBoundingClientRect().right)) <= window.innerWidth + 1)).toBe(true);
  await host.tap('#lobby button[data-lobby="go"]:not([hidden])');
  await join.waitForFunction(() => (window as any).__gd.net().inRun === true, undefined, { timeout: 10_000 });
  await expect(join.locator('#lobby')).toBeHidden();
  for (const e of errors) expect(e).toEqual([]);
  await context.close();
});
