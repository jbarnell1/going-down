import { expect, test } from '@playwright/test';

// A hard limit on frame time, so a slow change fails a test instead of being noticed by luck.
// Only meaningful on a real graphics card: CI machines draw in software and are skipped.
const BUDGET_MS = 20; // the display refreshes every 16.7 ms; 20 leaves room for timer jitter

test.skip(!!process.env.CI, 'frame time needs a real graphics card');

async function settledFrameMs(page: import('@playwright/test').Page): Promise<number> {
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  const from = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((f) => (window as any).__gd.frames > f + 150, from, { timeout: 30_000 });
  return page.evaluate(() => (window as any).__gd.frameMs() as number);
}

test('an empty corridor with the tape look stays inside the frame budget', async ({ page }) => {
  await page.goto('/?seed=alpha&entity=0');
  const ms = await settledFrameMs(page);
  console.log(`budget corridor=${ms.toFixed(2)} ms`);
  expect(ms).toBeLessThan(BUDGET_MS);
});

test('the Orderly on screen with its shadow stays inside the frame budget', async ({ page }) => {
  await page.goto('/?seed=alpha&preview=orderly&anim=walk');
  await page.waitForFunction(() => (window as any).__gd?.entity?.loaded() === true, undefined, { timeout: 30_000 });
  const ms = await settledFrameMs(page);
  console.log(`budget orderly=${ms.toFixed(2)} ms`);
  expect(ms).toBeLessThan(BUDGET_MS);
});

test('the live Orderly hunting, glanced at and away, with the instrument up, stays inside the frame budget', async ({ page }) => {
  await page.goto('/?seed=alpha');
  await page.waitForFunction(() => (window as any).__gd?.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  // 40 m down the longest corridor, awake; the player looks at it and away every half second, so
  // it is drawn frozen with its shadow, then walks (path planning, animation, squeak) unseen. The
  // instrument is raised the whole time: its own pass, the needle, the ticking and the crew logic.
  await page.evaluate(() => {
    const g = (window as any).__gd;
    g.raise(true);
    const s = g.plan.sightlines.filter((l: any) => l.level === 0).sort((p: any, q: any) => q.length - p.length)[0];
    const yaw = (Math.atan2(-(s.x2 - s.x1), -(s.y2 - s.y1)) * 180) / Math.PI;
    g.teleport(0, s.x1, s.y1, yaw);
    g.entityCtl.placeCell(0, s.x2, s.y2);
    g.entityCtl.wake();
    let k = 0;
    setInterval(() => g.look(yaw + (k++ % 2 ? 180 : 0), 0), 500);
  });
  const ms = await settledFrameMs(page);
  const o = await page.evaluate(() => (window as any).__gd.orderly());
  const i = await page.evaluate(() => (window as any).__gd.instrument());
  console.log(`budget orderly hunting + instrument=${ms.toFixed(2)} ms (phase ${o.phase}, ${o.distance.toFixed(1)} m, needle ${i.needle})`);
  expect(o.phase).toBe('hunting');
  expect(i.raised).toBe(true);
  expect(ms).toBeLessThan(BUDGET_MS);
});

test('the heavy tape level on a large window stays inside the frame budget', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.goto('/?seed=alpha&fx=2&depth=4');
  const ms = await settledFrameMs(page);
  console.log(`budget heavy 1080p depth4=${ms.toFixed(2)} ms`);
  expect(ms).toBeLessThan(BUDGET_MS);
});

test('the elevator wait (called, indicator counting, a blink, its sounds) stays inside the frame budget', async ({ page }) => {
  await page.goto('/?seed=alpha');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  // Out of the car onto the landing, the car gone; the Orderly awake in view across the lobby; call.
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 5000 });
  await page.evaluate(() => (window as any).__gd.runCtl.walkCar(-1, 0));
  await page.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 5000 });
  await page.evaluate(() => {
    const g = (window as any).__gd;
    const r = g.run();
    const p = g.player();
    const yaw = (Math.atan2(r.car3.inX, r.car3.inZ) * 180) / Math.PI;
    g.look(yaw, 0);
    g.entityCtl.placeCell(p.level, p.cx - r.car3.inX * 4, p.cy - r.car3.inZ * 4, yaw + 180);
    g.entityCtl.wake();
    g.runCtl.call();
    // To just before a blink, so the window below holds the warning, the dark and the lights coming back.
    g.runCtl.skipUntil('blinkSoon', 20);
  });
  const from = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((f) => (window as any).__gd.frames > f + 150, from, { timeout: 30_000 });
  const ms = await page.evaluate(() => (window as any).__gd.frameMs() as number);
  const r = await page.evaluate(() => (window as any).__gd.run());
  const a = await page.evaluate(() => (window as any).__gd.audio.state());
  console.log(`budget elevator wait=${ms.toFixed(2)} ms (car ${r.car}, indicator ${r.indicator.label}, blink warnings ${a.blinkWarnings}, darks ${a.blinkOuts}, machine ${a.machine.toFixed(2)})`);
  expect(r.car).toBe('coming');
  expect(a.blinkOuts).toBeGreaterThanOrEqual(1);
  expect(ms).toBeLessThan(BUDGET_MS);
});
