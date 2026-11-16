import { expect, test } from '@playwright/test';

// Reference pictures. If the scenery changes by more than a sliver, these fail, and a person
// decides whether the change was meant (then refresh them with `npm run e2e:update`) or a bug.
// Taken with the tape look off, because its grain is different on every frame.
// Pictures differ between graphics drivers, so this runs on the development PC and not in CI.
test.skip(!!process.env.CI, 'reference pictures are specific to this graphics card');

// Tight on purpose. With the tape look off and the camera fixed, the same card draws the same
// picture every time, so even a faint tint over a wall fails. (Looser settings, threshold 0.2
// and then 0.03, let a deliberate 4% pink tint on the corridor walls through.)
const OPTS = { maxDiffPixelRatio: 0.002, threshold: 0.01 };

async function ready(page: import('@playwright/test').Page): Promise<void> {
  await page.goto('/?seed=alpha&fx=0&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  // The corner text carries the build number, which changes with every commit.
  await page.addStyleTag({ content: '#hud, #debug { display: none !important; }' });
}

async function settle(page: import('@playwright/test').Page): Promise<void> {
  const from = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((f) => (window as any).__gd.frames > f + 3, from);
}

test('the view on stepping out of the elevator', async ({ page }) => {
  await ready(page);
  // The run starts inside the car; this is the view one step out, in the middle of the landing.
  await page.evaluate(() => {
    const g = (window as any).__gd;
    g.teleport(g.plan.landing.level, g.plan.landing.x, g.plan.landing.y);
  });
  await settle(page);
  await expect(page).toHaveScreenshot('landing.png', OPTS);
});

test('the view down the longest corridor', async ({ page }) => {
  await ready(page);
  await page.evaluate(() => {
    const g = (window as any).__gd;
    const s = g.plan.sightlines.filter((l: any) => l.level === 0).sort((a: any, b: any) => b.length - a.length)[0];
    const yaw = (Math.atan2(-(s.x2 - s.x1), -(s.y2 - s.y1)) * 180) / Math.PI;
    g.teleport(0, s.x1, s.y1, yaw);
  });
  await settle(page);
  await expect(page).toHaveScreenshot('corridor.png', OPTS);
});

test('the atrium from its floor, looking up', async ({ page }) => {
  await ready(page);
  await page.evaluate(() => {
    const g = (window as any).__gd;
    const a = g.plan.rooms.find((r: any) => r.kind === 'atrium');
    g.teleport(0, a.x, a.y, -135);
    g.look(-135, 25);
  });
  await settle(page);
  await expect(page).toHaveScreenshot('atrium.png', OPTS);
});
