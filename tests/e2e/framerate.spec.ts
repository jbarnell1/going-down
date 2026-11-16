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

test('the live Orderly hunting, glanced at and away, stays inside the frame budget', async ({ page }) => {
  await page.goto('/?seed=alpha');
  await page.waitForFunction(() => (window as any).__gd?.orderly()?.loaded === true, undefined, { timeout: 30_000 });
  // 40 m down the longest corridor, awake; the player looks at it and away every half second, so
  // it is drawn frozen with its shadow, then walks (path planning, animation, squeak) unseen.
  await page.evaluate(() => {
    const g = (window as any).__gd;
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
  console.log(`budget orderly hunting=${ms.toFixed(2)} ms (phase ${o.phase}, ${o.distance.toFixed(1)} m)`);
  expect(o.phase).toBe('hunting');
  expect(ms).toBeLessThan(BUDGET_MS);
});

test('the heavy tape level on a large window stays inside the frame budget', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await page.goto('/?seed=alpha&fx=2&depth=4');
  const ms = await settledFrameMs(page);
  console.log(`budget heavy 1080p depth4=${ms.toFixed(2)} ms`);
  expect(ms).toBeLessThan(BUDGET_MS);
});
