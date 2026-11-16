import { expect, test, type Page } from '@playwright/test';

// The elevator's voice in the real game: on a scripted run the announcer speaks at boarding, on the
// call, on the car's arrival, before the bell and on banking; the subtitle shown is the line playing;
// no line overlaps another; the slip is said at most once a run (and only from floor 2), followed after
// its pause by the cheerful resume line; an unknown line is shrugged off. Whether any of it sounds
// right is for ears: docs/VOICE.md.
test.skip(!!process.env.CI, 'needs a real graphics card and real time');

type Hist = { id: string; moment: string; voice: string; file: string; start: number; end: number | null; depth: number; mode: 'car' | 'landing' };
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

  // The car comes after the wait's blackout: the blackout's line as the lights go, and the lights
  // line (in place of the arrival line) as they come back with the doors; aboard on BANK; the bell's
  // line and the banking line.
  await page.evaluate(() => (window as any).__gd.runCtl.skipUntil('carArrived', 90));
  await spoke(page, 'lights');
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
  for (const m of ['board', 'called', 'lights', 'bell', 'banked']) expect(s.history.some((h) => h.moment === m), m).toBe(true);
  expect(s.history.some((h) => h.moment === 'arrived')).toBe(false);
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
  await page1.close();
});

test('the settings panel: voice, a sample, subtitles, tape look, volume; by keyboard; the run keeps going; remembered', async ({ page }) => {
  test.setTimeout(120_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&entity=0');
  const set = () => page.evaluate(() => (window as any).__gd.settings.get() as { voice: string; subtitles: boolean; tape: number; volume: number });
  const isOpen = () => page.evaluate(() => (window as any).__gd.settings.isOpen() as boolean);
  const click = async (key: string, dir: string) => {
    await page.click(`#settings button[data-setting="${key}"][data-dir="${dir}"]`);
    await settle(page, 2);
  };

  // The default voice is Bella, and the first line came from her folder.
  expect((await set()).voice).toBe('bella');
  const board = await spoke(page, 'board', 10_000);
  expect(board.voice).toBe('bella');
  expect(board.file).toContain('assets/voice/bella/');
  // On a computer there is no gear button.
  expect(await page.evaluate(() => (window as any).__gd.settings.gearShown())).toBe(false);

  // Esc opens it; the run's clock keeps going underneath.
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.bringToFront();
  await page.keyboard.press('Escape');
  await settle(page, 2);
  expect(await isOpen()).toBe(true);
  const t0 = await page.evaluate(() => (window as any).__gd.run().t as number);
  await page.waitForTimeout(1200);
  const t1 = await page.evaluate(() => (window as any).__gd.run().t as number);
  expect(t1 - t0).toBeGreaterThan(0.8);
  await page.screenshot({ path: 'test-results/shots/90-settings.png' });

  // Voice: Brian. The next line (the sample) loads from his folder and plays.
  await click('voice', 'next');
  expect((await set()).voice).toBe('brian');
  expect(await page.getAttribute('#settings [data-setting="voice"][data-value]', 'data-value')).toBe('brian');
  const brianFile = page.waitForRequest((r) => r.url().includes('/assets/voice/brian/'));
  const before = (await ann(page)).history.length;
  await click('sample', 'run');
  await brianFile;
  await page.waitForFunction((n) => (window as any).__gd.announcer.state().history.length > n, before, { timeout: 8000 });
  const sample = (await ann(page)).history.at(-1)!;
  expect(sample.voice).toBe('brian');
  expect(sample.file).toContain('assets/voice/brian/');
  expect((await ann(page)).playing).toBe(sample.id);

  // Subtitles off and on again.
  await click('subtitles', 'next');
  expect((await set()).subtitles).toBe(false);
  expect(await page.evaluate(() => document.getElementById('subs'))).toBeNull();
  await click('subtitles', 'next');
  expect((await set()).subtitles).toBe(true);
  expect((await ann(page)).subsOn).toBe(true);

  // Tape look: heavy, off, normal (the existing fx levels).
  await click('tape', 'next');
  expect(await page.evaluate(() => (window as any).__gd.fx())).toBe(2);
  await click('tape', 'next');
  expect(await page.evaluate(() => (window as any).__gd.fx())).toBe(0);
  await click('tape', 'next');
  expect(await page.evaluate(() => (window as any).__gd.fx())).toBe(1);

  // Volume down a step: the master gain follows.
  await click('volume', 'prev');
  expect((await set()).volume).toBeCloseTo(0.9, 6);
  expect(await page.evaluate(() => (window as any).__gd.audio.state().volume)).toBeCloseTo(0.9, 6);

  // Esc closes it.
  await page.keyboard.press('Escape');
  await settle(page, 2);
  expect(await isOpen()).toBe(false);

  // Remembered over a reload.
  await page.reload();
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  expect((await set()).voice).toBe('brian');
  expect((await set()).volume).toBeCloseTo(0.9, 6);
  expect(await page.evaluate(() => (window as any).__gd.announcer.state().voice)).toBe('brian');
  // ?voice= overrides, and is remembered too.
  await page.goto('/?seed=alpha&entity=0&voice=bella');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  expect((await set()).voice).toBe('bella');
  await page.goto('/?seed=alpha&entity=0');
  await page.waitForFunction(() => (window as any).__gd?.ready === true);
  expect((await set()).voice).toBe('bella');
  expect(errors).toEqual([]);
});

test('the settings panel on a phone: the gear opens and closes it, and a tap back in the game closes it', async ({ browser }) => {
  test.setTimeout(60_000);
  const context = await browser.newContext({ hasTouch: true, isMobile: true, viewport: { width: 844, height: 390 } });
  const page = await context.newPage();
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&entity=0');
  const isOpen = () => page.evaluate(() => (window as any).__gd.settings.isOpen() as boolean);
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => (window as any).__gd.settings.gearShown() === true, undefined, { timeout: 5000 });
  await page.tap('#settings-gear');
  await settle(page, 3);
  expect(await isOpen()).toBe(true);
  await page.screenshot({ path: 'test-results/shots/91-settings-phone.png' });
  const t0 = await page.evaluate(() => (window as any).__gd.run().t as number);
  await page.tap('#settings-gear');
  await settle(page, 2);
  expect(await isOpen()).toBe(false);
  await page.tap('#settings-gear');
  await settle(page, 2);
  expect(await isOpen()).toBe(true);
  await page.waitForTimeout(300);
  await page.touchscreen.tap(600, 250);
  await settle(page, 2);
  expect(await isOpen()).toBe(false);
  expect(await page.evaluate(() => (window as any).__gd.run().t as number)).toBeGreaterThan(t0);
  expect(errors).toEqual([]);
  await context.close();
});

test('even loudness: far from the lift a taken line is as loud as in the car, an ordinary line at least half; lines cycle', async ({ page }) => {
  test.setTimeout(90_000);
  const errors = watchErrors(page);
  await boot(page, '/?seed=alpha&entity=0');
  // In the car: the boarding line, at the in-car level.
  const board = await spoke(page, 'board', 10_000);
  const closeLevel = (await ann(page) as any).closeLevel as number;
  expect(board.mode).toBe('car');
  expect((board as any).level).toBeCloseTo(closeLevel, 6);
  await page.waitForFunction(() => (window as any).__gd.announcer.state().playing === null, undefined, { timeout: 15_000 });

  // Far from the lift: out of the car, then to the far end of the floor.
  await page.evaluate(() => (window as any).__gd.runCtl.setTimeScale(1));
  await page.waitForFunction(() => (window as any).__gd.run().doors > 0.99, undefined, { timeout: 8000 });
  await page.evaluate(() => (window as any).__gd.runCtl.walkCar(-1.5, 0));
  await page.waitForFunction(() => !(window as any).__gd.player().inCar, undefined, { timeout: 8000 });
  await page.evaluate(() => {
    // The corridor cell furthest from the doors, on the doors' storey.
    const g = (window as any).__gd;
    const plan = g.plan;
    const r = g.run().car3;
    let best = { x: 0, y: 0, d: -1 };
    for (let y = 0; y < plan.height; y++) for (let x = 0; x < plan.width; x++) {
      if (plan.cells[r.level][y * plan.width + x] !== 'corridor') continue;
      const d = Math.hypot((x + 0.5) * plan.cellSize - r.doorX, (y + 0.5) * plan.cellSize - r.doorZ);
      if (d > best.d) best = { x, y, d };
    }
    g.teleport(r.level, best.x, best.y);
  });
  await settle(page, 3);
  const far = await page.evaluate(() => { const g = (window as any).__gd; const p = g.player(); const r = g.run(); return Math.hypot(p.x - r.car3.doorX, p.z - r.car3.doorZ); });
  expect(far).toBeGreaterThan(20);
  const levelOf = async (id: string): Promise<{ gain: number; lowpass: number; mode: string }> => {
    expect(await page.evaluate((x) => (window as any).__gd.announcer.say(x), id)).toBe(true);
    await page.waitForFunction((x) => (window as any).__gd.announcer.state().playing === x, id, { timeout: 10_000 });
    await settle(page, 6);
    const st = await ann(page) as any;
    const out = { ...st.level, mode: st.mode };
    await page.waitForFunction(() => (window as any).__gd.announcer.state().playing === null, undefined, { timeout: 15_000 });
    return out;
  };
  const taken = await levelOf('taken_1');
  const called = await levelOf('called_1');
  console.log(`voice levels: in the car ${closeLevel}; ${far.toFixed(1)} m from the lift: taken ${taken.gain.toFixed(3)} (${taken.mode}), called ${called.gain.toFixed(3)} at low-pass ${called.lowpass.toFixed(0)} Hz`);
  expect(taken.mode).toBe('landing');
  expect(taken.gain).toBeCloseTo(closeLevel, 6);
  expect(called.mode).toBe('landing');
  expect(called.gain).toBeGreaterThanOrEqual(closeLevel / 2);
  expect(called.lowpass).toBeGreaterThanOrEqual(1400);

  // Each moment goes through all its lines before any comes round again, never the same twice running.
  const dealt = await page.evaluate(() => Array.from({ length: 15 }, () => (window as any).__gd.announcer.deal('arrived') as string));
  const n = new Set(dealt).size;
  expect(n).toBe(5);
  for (let i = 0; i + n <= dealt.length; i += n) expect(new Set(dealt.slice(i, i + n)).size).toBe(n);
  for (let i = 1; i < dealt.length; i++) expect(dealt[i]).not.toBe(dealt[i - 1]);
  expect(errors).toEqual([]);
});
