import { expect, test } from '@playwright/test';

// Phone controls: the left thumb is a walk stick, the right thumb drags to look. The events are
// dispatched as real PointerEvents with pointerType "touch", which is what a phone sends.
test.use({ viewport: { width: 844, height: 390 }, hasTouch: true });

test('a phone can start, walk with the left thumb, creep, and look with the right', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('/?seed=alpha&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);

  const touch = (type: string, id: number, x: number, y: number) =>
    page.evaluate(([t, i, cx, cy]) => {
      document.body.dispatchEvent(new PointerEvent(t as string, {
        pointerId: i as number, pointerType: 'touch', clientX: cx as number, clientY: cy as number, bubbles: true, isPrimary: true,
      }));
    }, [type, id, x, y]);
  const state = () => page.evaluate(() => { const p = (window as any).__gd.player(); return { x: p.x as number, z: p.z as number, yaw: p.yaw as number }; });
  const dist = (a: { x: number; z: number }, b: { x: number; z: number }) => Math.hypot(a.x - b.x, a.z - b.z);

  // The first tap only dismisses the overlay; it must not start a stick.
  await expect(page.locator('#start')).toBeVisible();
  await touch('pointerdown', 1, 400, 200);
  await touch('pointerup', 1, 400, 200);
  await expect(page.locator('#start')).toBeHidden();

  // Left thumb pushed fully up: walk forward.
  const s0 = await state();
  await touch('pointerdown', 2, 150, 300);
  await touch('pointermove', 2, 150, 230);
  await page.waitForTimeout(700);
  await touch('pointerup', 2, 150, 230);
  const s1 = await state();
  const walked = dist(s0, s1);
  expect(walked).toBeGreaterThan(1.0);

  // Lifting the thumb stops you.
  await page.waitForTimeout(300);
  expect(dist(s1, await state())).toBeLessThan(0.05);

  // Pushed gently down: back up slowly.
  await touch('pointerdown', 3, 150, 300);
  await touch('pointermove', 3, 150, 318);
  await page.waitForTimeout(700);
  await touch('pointerup', 3, 150, 318);
  const s2 = await state();
  const crept = dist(s1, s2);
  expect(crept).toBeGreaterThan(0.1);
  expect(crept).toBeLessThan(walked * 0.6);

  // Right thumb dragged sideways: the view turns and you do not move.
  await touch('pointerdown', 4, 650, 200);
  await touch('pointermove', 4, 730, 200);
  await page.waitForTimeout(150);
  await touch('pointerup', 4, 730, 200);
  const s3 = await state();
  expect(Math.abs(s3.yaw - s2.yaw)).toBeGreaterThan(15);
  expect(dist(s2, s3)).toBeLessThan(0.05);

  // Both thumbs at once: walk while turning.
  await touch('pointerdown', 5, 150, 300);
  await touch('pointermove', 5, 150, 230);
  await touch('pointerdown', 6, 650, 200);
  await touch('pointermove', 6, 700, 200);
  await page.waitForTimeout(400);
  await touch('pointerup', 5, 150, 230);
  await touch('pointerup', 6, 700, 200);
  const s4 = await state();
  expect(dist(s3, s4)).toBeGreaterThan(0.4);
  expect(Math.abs(s4.yaw - s3.yaw)).toBeGreaterThan(8);

  await page.screenshot({ path: 'test-results/shots/30-phone.png' });
  expect(errors).toEqual([]);
});
