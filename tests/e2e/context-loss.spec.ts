import { expect, test } from '@playwright/test';

// A phone's browser can throw the graphics context away mid-game; the owner saw exactly that: a
// blank white canvas with the overlays still on top. These tests take the context away on purpose.

async function boot(page: import('@playwright/test').Page, query: string): Promise<void> {
  await page.goto(query);
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.frames > 30);
}

const lose = (page: import('@playwright/test').Page, restoreAfterMs: number | null) =>
  page.evaluate((ms) => {
    const gl = (document.getElementById('view') as HTMLCanvasElement).getContext('webgl2') as WebGL2RenderingContext;
    const ext = gl.getExtension('WEBGL_lose_context');
    if (!ext) throw new Error('this browser cannot simulate a lost context');
    ext.loseContext();
    if (ms !== null) setTimeout(() => ext.restoreContext(), ms);
  }, restoreAfterMs);

test('the picture comes back after the graphics context is lost once', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  await boot(page, '/?seed=alpha');
  await lose(page, 400);
  await expect(page.getByText('PICTURE LOST')).toBeVisible();
  // It carries on drawing real frames afterwards, and the notice goes away.
  const from = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((f) => (window as any).__gd.frames > f + 60, from, { timeout: 15_000 });
  await expect(page.getByText('PICTURE LOST')).toBeHidden();
  const colours = await page.evaluate(() => (window as any).__gd.probeColours() as number);
  expect(colours).toBeGreaterThan(8);
  await page.screenshot({ path: 'test-results/shots/95-after-context-loss.png' });
  expect(errors).toEqual([]);
});

test('losing it twice switches to a lighter picture and reloads once', async ({ page }) => {
  await boot(page, '/?seed=alpha');
  await lose(page, 300);
  const from = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((f) => (window as any).__gd.frames > f + 30, from, { timeout: 15_000 });
  await lose(page, null);
  await page.waitForURL(/[?&]safe=1/, { timeout: 15_000 });
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.frames > 30);
  expect(await page.evaluate(() => (window as any).__gd.probeColours() as number)).toBeGreaterThan(8);
  await page.screenshot({ path: 'test-results/shots/96-safe-mode.png' });
});

test('the lightest level still draws a floor you can walk', async ({ page }) => {
  await boot(page, '/?seed=alpha&safe=2');
  expect(await page.evaluate(() => (window as any).__gd.fx() as number)).toBe(0);
  expect(await page.evaluate(() => (window as any).__gd.probeColours() as number)).toBeGreaterThan(8);
});
