import { expect, test, type Page } from '@playwright/test';

// The elevator's voice in the real game: on a scripted run the announcer speaks at boarding, on the
// call, on the car's arrival, before the bell and on banking; the subtitle shown is the line playing;
// no line overlaps another; the slip is said at most once a run (and only from floor 2), followed after
// its pause by the cheerful resume line; an unknown line is shrugged off. Whether any of it sounds
// right is for ears: docs/VOICE.md.
test.skip(!!process.env.CI, 'needs a real graphics card and real time');

type Hist = { id: string; moment: string; start: number; end: number | null; depth: number; mode: 'car' | 'landing' };
type Ann = { ready: boolean; playing: string | null; queue: string[]; played: string[]; slipPlayed: boolean; history: Hist[]; missing: string[]; subtitle: string; subsOn: boolean };

const ann = (page: Page) => page.evaluate(() => (window as any).__gd.announcer.state() as Ann);

function watchErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  return errors;
}

async function boot(page: Page, url: string): Promise<Record<string, string>> {
  await page.goto(url);
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(0));
  await page.evaluate(() => (window as any).__gd.start());
  await page.waitForFunction(() => (window as any).__gd.announcer.state().ready === true, undefined, { timeout: 10_000 });
  const manifest = await page.evaluate(async () => (await fetch('assets/voice/manifest.json')).json());
  // Sample what plays and what the subtitle says on every frame, for the whole test.
  await page.evaluate(() => {
    const g = window as any;
    g.__subs = [];
    const loop = (): void => {
      const s = g.__gd.announcer.state();
      if (s.playing) g.__subs.push([s.playing, s.subtitle]);
      requestAnimationFrame(loop);
    };
    loop();
  });
  return Object.fromEntries((manifest.lines as { id: string; plain: string }[]).map((l) => [l.id, l.plain]));
}

/** Waits until a line of this moment has started (and returns it). */
async function spoke(page: Page, moment: string, timeout = 25_000): Promise<Hist> {
  await page.waitForFunction((m) => (window as any).__gd.announcer.state().history.some((h: Hist) => h.moment === m), moment, { timeout });
  return (await ann(page)).history.find((h) => h.moment === moment)!;
}

async function settle(page: Page, frames = 3): Promise<void> {
  const start = await page.evaluate(() => (window as any).__gd.frames as number);
  await page.waitForFunction((n) => (window as any).__gd.frames >= n, start + frames);
}

function noOverlap(history: Hist[]): void {
  const h = [...history].sort((a, b) => a.start - b.start);
  for (let i = 1; i < h.length; i++) {
    const prev = h[i - 1]!;
    expect(prev.end, `${prev.id} ended before ${h[i]!.id}`).not.toBeNull();
    expect(h[i]!.start, `${h[i]!.id} starts after ${prev.id} ends`).toBeGreaterThanOrEqual(prev.end! - 5);
  }
}

test('the announcer on a run: boarding, the call, the arrival, the bell, banking', async ({ page }) => {
  test.setTimeout(180_000);
  const errors = watchErrors(page);
  const plain = await boot(page, '/?seed=alpha&entity=0');

  // Boarding: in the car, close, with its subtitle.
  const board = await spoke(page, 'board', 10_000);
  expect(board.mode).toBe('car');
  await page.waitForFunction(() => (window as any).__gd.announcer.state().subtitle !== '');
  const s0 = await ann(page);
  expect(s0.subsOn).toBe(true);
  expect(s0.subtitle).toBe(plain[s0.playing!]);
  expect(await page.evaluate(() => !document.getElementById('subs')!.hidden)).toBe(true);

  // Out of the car; the car leaves; call it from the landing.
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 8000 });
  await page.evaluate(() => (window as any).__gd.runCtl.walkCar(-1.5, 0));
  await page.waitForFunction(() => (window as any).__gd.run().car === 'away', undefined, { timeout: 20_000 });
  await settle(page);
  expect(await page.evaluate(() => (window as any).__gd.runCtl.call())).toBe(true);
  const called = await spoke(page, 'called');
  expect(called.mode).toBe('landing');

  // The car comes; the arrival line; aboard on BANK; the bell's line and the banking line.
  await page.evaluate(() => (window as any).__gd.runCtl.skipUntil('carArrived', 90));
  await spoke(page, 'arrived');
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 5000 });
  await page.evaluate(() => (window as any).__gd.runCtl.walkCar(0.8, -0.5));
  await page.waitForFunction(() => (window as any).__gd.run().vote === 'bank', undefined, { timeout: 6000 });
  await page.evaluate(() => (window as any).__gd.runCtl.skipUntil('banked', 30));
  const bell = await spoke(page, 'bell', 30_000);
  const banked = await spoke(page, 'banked', 40_000);
  expect(banked.mode).toBe('car');
  expect(banked.start).toBeGreaterThan(bell.start);
  await page.waitForFunction(() => { const s = (window as any).__gd.announcer.state(); return s.playing === null && s.queue.length === 0; }, undefined, { timeout: 20_000 });

  const s = await ann(page);
  console.log(`announcer said: ${s.history.map((h) => `${h.id}(${h.mode}, ${((h.end! - h.start) / 1000).toFixed(1)} s)`).join(' ')}`);
  for (const m of ['board', 'called', 'arrived', 'bell', 'banked']) expect(s.history.some((h) => h.moment === m), m).toBe(true);
  noOverlap(s.history);
  expect(s.missing).toEqual([]);
  // Every frame that had a line playing showed that line's words.
  const samples = await page.evaluate(() => (window as any).__subs as [string, string][]);
  expect(samples.length).toBeGreaterThan(50);
  for (const [id, sub] of samples) expect(sub, id).toBe(plain[id]);
  expect(errors).toEqual([]);
});

test('the slip: only from floor 2, once a run, then the pause and the cheerful line; unknown lines are shrugged off', async ({ page }) => {
  test.setTimeout(90_000);
  const errors = watchErrors(page);
  const plain = await boot(page, '/?seed=alpha&entity=0&depth=2');
  await spoke(page, 'board', 10_000);

  // A line that does not exist: refused, noted, and the game carries on.
  expect(await page.evaluate(() => (window as any).__gd.announcer.say('no_such_line'))).toBe(false);
  expect((await ann(page)).missing).toContain('no_such_line');
  await settle(page, 10);

  const slipId = Object.keys(plain).find((id) => id.startsWith('slip'))!;
  expect(await page.evaluate((id) => (window as any).__gd.announcer.say(id), slipId)).toBe(true);
  // Asked for again in the same run: refused.
  expect(await page.evaluate((id) => (window as any).__gd.announcer.say(id), slipId)).toBe(false);
  const slip = await spoke(page, 'slip', 20_000);
  const resume = await spoke(page, 'resume', 20_000);
  const s = await ann(page);
  expect(s.played.filter((id) => id === slipId).length).toBe(1);
  expect(s.slipPlayed).toBe(true);
  const slipEnd = s.history.find((h) => h.moment === 'slip')!.end!;
  expect(resume.start - slipEnd).toBeGreaterThanOrEqual(2000);
  expect(resume.start).toBeGreaterThan(slip.start);
  await page.waitForFunction(() => (window as any).__gd.announcer.state().playing === null, undefined, { timeout: 15_000 });
  noOverlap((await ann(page)).history);

  // A new run on floor 1 (?depth=2 restarts on 2, so check floor 1 in its own page): no slip there.
  const page1 = await page.context().newPage();
  const errors1 = watchErrors(page1);
  await boot(page1, '/?seed=alpha&entity=0&subs=0');
  expect(await page1.evaluate((id) => (window as any).__gd.announcer.say(id), slipId)).toBe(false);
  const s1 = await ann(page1);
  expect(s1.subsOn).toBe(false);
  expect(await page1.evaluate(() => document.getElementById('subs'))).toBeNull();
  expect(errors).toEqual([]);
  expect(errors1).toEqual([]);
});
