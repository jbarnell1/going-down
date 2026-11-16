import { expect, test } from '@playwright/test';

// Phones without float render targets take an 8-bit path through the tape look. The test PC never
// takes it by itself, so ?hdr=0 forces it. A black or flat screen here would mean a black screen
// on someone's phone.
test.use({ viewport: { width: 844, height: 390 }, hasTouch: true });

test('the tape look still draws a readable picture on the 8-bit fallback path', async ({ page }) => {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));

  await page.goto('/?seed=alpha&hdr=0&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.waitForFunction(() => (window as any).__gd.frames > 20);
  await page.evaluate(() => (window as any).__gd.start());

  // Read what actually reached the screen: several distinct brightness levels across the frame.
  const shot = await page.screenshot({ path: 'test-results/shots/47-tape-8bit-phone.png' });
  expect(shot.byteLength).toBeGreaterThan(20_000); // a flat black or white frame compresses to almost nothing

  const fx = await page.evaluate(() => (window as any).__gd.fx() as number);
  expect(fx).toBe(1);
  const ms = await page.evaluate(() => (window as any).__gd.frameMs() as number);
  console.log(`frameMs 8-bit phone path=${ms.toFixed(2)}`);
  if (!process.env.CI) expect(ms).toBeLessThan(25); // CI draws in software and cannot meet a frame budget
  expect(errors).toEqual([]);
});
