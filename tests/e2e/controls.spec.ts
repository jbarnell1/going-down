import { expect, test } from '@playwright/test';

// The walk test drives the game through auto-walk. This one presses real keys, because the
// owner tests by hand on the live link and nothing else proves the controls are wired up.
test('W walks forward, Shift creeps, and a wall stops you', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('/?seed=alpha');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());

  const pos = () => page.evaluate(() => { const p = (window as any).__gd.player(); return { x: p.x as number, z: p.z as number }; });
  const dist = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

  const p0 = await pos();
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(700);
  await page.keyboard.up('KeyW');
  const p1 = await pos();
  const walked = dist(p0, p1);
  expect(walked).toBeGreaterThan(1.0); // about 3 m/s for 0.7 s, less start-up

  // Releasing the key stops you.
  await page.waitForTimeout(200);
  const p2 = await pos();
  await page.waitForTimeout(300);
  expect(dist(p2, await pos())).toBeLessThan(0.05);

  // Creeping covers clearly less ground in the same time.
  await page.keyboard.down('ShiftLeft');
  await page.keyboard.down('KeyS');
  await page.waitForTimeout(700);
  await page.keyboard.up('KeyS');
  await page.keyboard.up('ShiftLeft');
  const crept = dist(p2, await pos());
  expect(crept).toBeGreaterThan(0.3);
  expect(crept).toBeLessThan(walked * 0.75);

  // Holding forward for a long time must end against something, still inside walkable space.
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(6000);
  const p3 = await pos();
  await page.waitForTimeout(500);
  const p4 = await pos();
  await page.keyboard.up('KeyW');
  expect(dist(p3, p4)).toBeLessThan(0.6); // stopped by a wall, or sliding slowly along one
  const cell = await page.evaluate(() => {
    const g = (window as any).__gd; const p = g.player();
    return g.plan.cells[p.level][p.cy * g.plan.width + p.cx] as string;
  });
  expect(cell).not.toBe('void');
  expect(cell).not.toBe('atriumOpen');
  expect(errors).toEqual([]);
});
