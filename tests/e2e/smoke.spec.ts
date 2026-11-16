import { mkdirSync } from 'node:fs';
import { expect, test } from '@playwright/test';

const SHOTS = 'test-results/shots';

test('the game boots, draws frames and logs no errors', async ({ page }) => {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));

  await page.goto('/?seed=smoke');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.waitForFunction(() => (window as any).__gd.frames > 10);

  const info = await page.evaluate(() => {
    const g = (window as any).__gd;
    return { build: g.build as string, seed: g.seed as string, gpu: g.gpu as string };
  });
  console.log(`build=${info.build} seed=${info.seed} gpu=${info.gpu}`);
  expect(info.seed).toBe('smoke');

  mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: `${SHOTS}/00-boot.png` });

  // The canvas must contain more than one colour, or nothing was really drawn.
  // Read straight from the GPU right after a draw; copying a WebGL canvas later gives a blank image.
  const colours = await page.evaluate(() => (window as any).__gd.probeColours() as number);
  expect(colours).toBeGreaterThan(8);
  expect(errors).toEqual([]);
});
