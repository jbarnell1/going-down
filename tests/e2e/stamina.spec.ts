import { expect, test, type Page } from '@playwright/test';

// Sprint, creep and breath, with real keys in real time: Shift runs clearly faster than a walk, the
// tank runs dry after about five seconds of running and the pace falls back to a walk with the
// player winded (breathing hard, the edge of the view darkened), and the host's copy of the tank
// agrees. Real frame timing decides the distances, so CI (software drawing, a few frames a second)
// skips this file, as it does the other real-time specs.

test.skip(!!process.env.CI, 'measures distances over real time; CI draws too slowly');

type Gd = { x: number; z: number; gait: string; speed: number };
type Breath = { level: number; winded: boolean; gait: string; exertion: number; vignette: number; breath: { rate: number; level: number; breaths: number; winded: boolean }; host: { level: number; winded: boolean } | null };

const player = (p: Page) => p.evaluate(() => (window as any).__gd.player() as Gd);
const stamina = (p: Page) => p.evaluate(() => (window as any).__gd.stamina() as Breath);
const dist = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

/** The longest straight corridor on the ground floor: its x2 end cell, the step along it, and the yaw down it. */
async function corridor(page: Page) {
  return page.evaluate(() => {
    const plan = (window as any).__gd.plan;
    const s = plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const ux = Math.sign(s.x1 - s.x2);
    const uy = Math.sign(s.y1 - s.y2);
    // Facing from the x2 end toward x1 (three.js yaw, degrees).
    const along = (Math.atan2(-ux, -uy) * 180) / Math.PI;
    return { x2: s.x2 as number, y2: s.y2 as number, ux, uy, along, length: s.length as number };
  });
}

async function boot(page: Page): Promise<string[]> {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('/?seed=alpha&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.run().car === 'open', undefined, { timeout: 5000 });
  return errors;
}

test('Shift runs clearly faster than a walk; the tank runs dry and you are winded, walking, out of breath', async ({ page }) => {
  const errors = await boot(page);
  const cor = await corridor(page);
  expect(cor.length).toBeGreaterThanOrEqual(8);
  const toStart = () => page.evaluate(([x, y, yaw]) => { const g = (window as any).__gd; g.teleport(0, x, y, yaw); g.look(yaw, 0); }, [cor.x2, cor.y2, cor.along] as const);

  // A full tank: silent, and the view's edge exactly as always.
  const fresh = await stamina(page);
  expect(fresh.level).toBe(1);
  expect(fresh.winded).toBe(false);
  expect(fresh.vignette).toBe(0);
  expect(fresh.breath.rate).toBe(0);

  // Two seconds of walking down the corridor...
  await toStart();
  await page.waitForTimeout(300);
  const w0 = await player(page);
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(2000);
  const wMid = await player(page);
  await page.keyboard.up('KeyW');
  const walked = dist(w0, await player(page));
  expect(wMid.gait).toBe('walk');

  // ...against two seconds of running from the same spot (a walk does not tire you).
  await toStart();
  await page.waitForTimeout(300);
  const s0 = await player(page);
  await page.keyboard.down('ShiftLeft');
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(1000);
  const sMid = await player(page);
  await page.screenshot({ path: 'test-results/shots/110-sprinting.png' });
  await page.waitForTimeout(1000);
  await page.keyboard.up('KeyW');
  const ran = dist(s0, await player(page));
  console.log(`2 s: walked ${walked.toFixed(2)} m, ran ${ran.toFixed(2)} m`);
  expect(sMid.gait).toBe('sprint');
  expect(sMid.speed).toBeCloseTo(5, 5);
  expect(ran).toBeGreaterThan(walked * 1.4);
  const after2 = await stamina(page);
  expect(after2.level).toBeLessThan(0.75);
  expect(after2.level).toBeGreaterThan(0.4);
  expect(after2.winded).toBe(false);

  // Keep running, back and forth along the corridor, until the tank is dry (about 3 s more of
  // running). Shift stays held throughout.
  let forward = false;
  let winded = false;
  for (let i = 0; i < 8 && !winded; i++) {
    const key = forward ? 'KeyW' : 'KeyS';
    await page.keyboard.down(key);
    await page.waitForTimeout(1200);
    await page.keyboard.up(key);
    forward = !forward;
    winded = (await stamina(page)).winded;
  }
  expect(winded).toBe(true);

  // Still holding Shift: the pace is a walk now, not a run.
  const key = forward ? 'KeyW' : 'KeyS';
  const now = () => page.evaluate(() => performance.now() / 1000);
  const t0 = await player(page);
  const tStart = await now();
  await page.keyboard.down(key);
  await page.waitForTimeout(250);
  const tMid = await player(page);
  await page.waitForTimeout(750);
  const tired = await stamina(page);
  await page.screenshot({ path: 'test-results/shots/111-winded-vignette.png' });
  const t1 = await player(page);
  const tEnd = await now();
  await page.keyboard.up(key);
  await page.keyboard.up('ShiftLeft');
  const pace = dist(t0, t1) / (tEnd - tStart);
  console.log(`winded: ${dist(t0, t1).toFixed(2)} m at ${pace.toFixed(2)} m/s, breath ${JSON.stringify(tired.breath)}, vignette ${tired.vignette.toFixed(3)}, host ${JSON.stringify(tired.host)}`);
  expect(tMid.gait).toBe('walk');
  expect(tMid.speed).toBeCloseTo(3, 5);
  // Walking pace (3 m/s) and nowhere near a run (5 m/s), measured on the page's own clock.
  expect(pace).toBeLessThan(3.4);
  expect(tired.winded).toBe(true);
  expect(tired.exertion).toBeGreaterThanOrEqual(0.7);
  // The edge of the view is darkened, and the breathing is fast and hard (the sound itself is not
  // heard by a test: this reads what the synthesiser was told to play).
  expect(tired.vignette).toBeGreaterThan(0.2);
  expect(tired.breath.winded).toBe(true);
  expect(tired.breath.rate).toBeGreaterThan(1.2);
  expect(tired.breath.level).toBeGreaterThan(0.1);
  // The host owns the tank: its copy says the same.
  expect(tired.host?.winded).toBe(true);
  expect(Math.abs((tired.host?.level ?? 1) - tired.level)).toBeLessThan(0.08);

  // Standing still, breath comes back: no longer winded within a few seconds, and in time full and quiet.
  await page.waitForFunction(() => (window as any).__gd.stamina().winded === false, undefined, { timeout: 5000 });
  await page.waitForFunction(() => (window as any).__gd.stamina().level === 1, undefined, { timeout: 8000 });
  const rested = await stamina(page);
  expect(rested.vignette).toBe(0);
  expect(rested.breath.rate).toBe(0);
  expect(errors).toEqual([]);
});

test('C creeps, and creeping beats Shift: holding both creeps', async ({ page }) => {
  const errors = await boot(page);
  const cor = await corridor(page);
  const toStart = () => page.evaluate(([x, y, yaw]) => { const g = (window as any).__gd; g.teleport(0, x, y, yaw); g.look(yaw, 0); }, [cor.x2, cor.y2, cor.along] as const);
  await toStart();
  await page.waitForTimeout(300);
  const c0 = await player(page);
  await page.keyboard.down('KeyC');
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(500);
  const cMid = await player(page);
  await page.keyboard.down('ShiftLeft');
  await page.waitForTimeout(500);
  const both = await player(page);
  await page.keyboard.up('ShiftLeft');
  await page.waitForTimeout(500);
  await page.keyboard.up('KeyW');
  await page.keyboard.up('KeyC');
  const crept = dist(c0, await player(page));
  expect(cMid.gait).toBe('creep');
  expect(cMid.speed).toBeCloseTo(1.2, 5);
  expect(both.gait).toBe('creep');
  expect(crept).toBeGreaterThan(0.8);
  expect(crept).toBeLessThan(2.2);
  // Creeping costs no breath.
  expect((await stamina(page)).level).toBe(1);
  // Let go of C: back to a walk on the next frames.
  await page.waitForTimeout(200);
  expect((await stamina(page)).gait).toBe('walk');
  // Plain Ctrl is not a game key here (not fullscreen with a keyboard lock), so Ctrl+W can never be needed.
  expect(await page.evaluate(() => (window as any).__gd.stamina().ctrlCreep)).toBe(false);
  expect(errors).toEqual([]);
});
