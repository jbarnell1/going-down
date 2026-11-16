import { expect, test } from '@playwright/test';

// Under test automation the game never takes the browser's real pointer lock (on Windows that
// confines the real cursor of whoever owns the machine). A stand-in lock behaves the same for the
// game: clicking in locks it, the mouse turns the view, Esc lets go and opens the settings.
test('the mouse lock is a stand-in under automation, and mouse-look still turns the view', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  // Count every call of the browser's real requestPointerLock: there must be none.
  await page.addInitScript(() => {
    const w = window as any;
    w.__realLockCalls = 0;
    const real = Element.prototype.requestPointerLock;
    Element.prototype.requestPointerLock = function (this: Element, ...args: unknown[]) {
      w.__realLockCalls++;
      return (real as (...a: unknown[]) => unknown).apply(this, args);
    } as typeof real;
  });
  await page.goto('/?seed=alpha&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  const lock = () => page.evaluate(() => (window as any).__gd.pointerLock() as { standIn: boolean; locked: boolean; real: boolean });
  expect(await lock()).toEqual({ standIn: true, locked: false, real: false });
  await page.click('#start');
  await page.waitForFunction(() => (window as any).__gd.pointerLock().locked === true, undefined, { timeout: 3000 });
  expect(await lock()).toEqual({ standIn: true, locked: true, real: false });
  await expect(page.locator('#start')).toBeHidden();

  const yaw = () => page.evaluate(() => (window as any).__gd.player().yaw as number);
  const y0 = await yaw();
  await page.mouse.move(640, 360);
  await page.mouse.move(840, 360, { steps: 10 });
  await page.waitForTimeout(150);
  const y1 = await yaw();
  expect(Math.abs(y1 - y0)).toBeGreaterThan(5);

  // Esc lets go, as the real lock does, and the settings panel opens in place of the start screen.
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => (window as any).__gd.pointerLock().locked === false, undefined, { timeout: 3000 });
  expect(await page.evaluate(() => (window as any).__gd.settings.isOpen())).toBe(true);
  // Unlocked, the mouse no longer turns the view.
  const y2 = await yaw();
  await page.mouse.move(440, 360, { steps: 10 });
  await page.waitForTimeout(150);
  expect(await yaw()).toBeCloseTo(y2, 3);
  expect((await lock()).real).toBe(false);
  expect(await page.evaluate(() => (window as any).__realLockCalls)).toBe(0);
  expect(errors).toEqual([]);
});

// The browser's real lock, on purpose. Never in the default run: on Windows it confines the real
// cursor. Run it alone with GD_REALLOCK=1.
test('the real pointer lock with ?reallock=1 (only with GD_REALLOCK=1)', async ({ page }) => {
  test.skip(process.env.GD_REALLOCK !== '1', 'takes the real mouse; run deliberately with GD_REALLOCK=1');
  await page.goto('/?seed=alpha&entity=0&reallock=1');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  expect((await page.evaluate(() => (window as any).__gd.pointerLock())).standIn).toBe(false);
  await page.click('#start');
  await page.waitForFunction(() => (window as any).__gd.pointerLock().real === true, undefined, { timeout: 3000 });
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => (window as any).__gd.pointerLock().real === false, undefined, { timeout: 3000 });
});

// The walk test drives the game through auto-walk. This one presses real keys, because the
// owner tests by hand on the live link and nothing else proves the controls are wired up.
test('W walks forward, C creeps, and a wall stops you', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await page.goto('/?seed=alpha&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  // The run starts in the elevator car: wait for its doors to open onto the floor.
  await page.waitForFunction(() => (window as any).__gd.run().car === 'open', undefined, { timeout: 5000 });

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
  await page.keyboard.down('KeyC');
  await page.keyboard.down('KeyS');
  await page.waitForTimeout(700);
  await page.keyboard.up('KeyS');
  await page.keyboard.up('KeyC');
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
