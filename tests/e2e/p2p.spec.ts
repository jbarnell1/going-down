import { expect, test, type Page } from '@playwright/test';

// Real peer to peer: two players in two separate browser contexts (nothing shared between them but
// the internet) find each other through Trystero's public signalling, connect directly, and play one
// run. Needs the internet and the public relays, so it is skipped on CI and given time and a retry.
test.skip(!!process.env.CI, 'needs the internet and public signalling');
test.describe.configure({ retries: 1 });

const CONNECT_MS = 90_000;

function watch(page: Page): string[] {
  const errors: string[] = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));
  return errors;
}

test('two browsers on two contexts connect over Trystero and play the same run', async ({ browser }) => {
  test.setTimeout(240_000);
  const ca = await browser.newContext({ viewport: { width: 640, height: 360 } });
  const cb = await browser.newContext({ viewport: { width: 640, height: 360 } });
  const a = await ca.newPage();
  const b = await cb.newPage();
  const ea = watch(a);
  const eb = watch(b);
  try {
    await a.goto('/?seed=alpha');
    await a.waitForFunction(() => (window as any).__gd?.ready === true);
    await a.evaluate(() => (window as any).__gd.lobby.setName('HOST 1111'));
    const room = await a.evaluate(() => (window as any).__gd.lobby.startCrew() as Promise<string>);
    expect(room).toMatch(/^[A-Z0-9]{5}$/);
    const t0 = Date.now();
    await b.goto(`/?room=${room}`);
    await b.waitForFunction(() => (window as any).__gd?.ready === true);
    await b.evaluate(() => (window as any).__gd.lobby.setName('GUEST 2222'));
    await b.evaluate(() => (window as any).__gd.lobby.join());
    // Connecting: say plainly if the public signalling never introduced the two.
    const met = await a
      .waitForFunction(() => (window as any).__gd.net().peers.some((p: any) => p.name === 'GUEST 2222'), undefined, { timeout: CONNECT_MS })
      .then(() => true, () => false);
    const waited = ((Date.now() - t0) / 1000).toFixed(1);
    if (!met) {
      const na = await a.evaluate(() => (window as any).__gd.net());
      const nb = await b.evaluate(() => (window as any).__gd.net());
      throw new Error(`public signalling did not connect the two browsers within ${CONNECT_MS / 1000} s (host lobby "${na.lobby}", guest lobby "${nb.lobby}", errors ${na.error || '-'} / ${nb.error || '-'}): peer to peer is UNPROVEN on this machine`);
    }
    console.log(`p2p: connected after ${waited} s`);
    expect(await a.evaluate(() => (window as any).__gd.lobby.goDown())).toBe(true);
    await b.waitForFunction(() => (window as any).__gd.net().inRun === true && (window as any).__gd.run().phase !== 'none', undefined, { timeout: 30_000 });
    for (const p of [a, b]) await p.evaluate(() => (window as any).__gd.start());
    // The same floor.
    await b.waitForFunction(() => (window as any).__gd.run().depth === 1, undefined, { timeout: 10_000 });
    const ka = await a.evaluate(() => (window as any).__gd.run().planKey);
    const kb = await b.evaluate(() => (window as any).__gd.run().planKey);
    expect(kb).toBe(ka);
    // Each sees the other.
    await a.waitForFunction(() => (window as any).__gd.crew().length === 1, undefined, { timeout: 15_000 });
    await b.waitForFunction(() => (window as any).__gd.crew().length === 1, undefined, { timeout: 15_000 });
    // The Orderly, put to rest where it stands, is drawn in the same place by both.
    await a.evaluate(() => (window as any).__gd.entityCtl.rest(600));
    await a.waitForTimeout(1500);
    const oa = await a.evaluate(() => (window as any).__gd.orderly());
    const ob = await b.evaluate(() => (window as any).__gd.orderly());
    expect(Math.hypot(oa.x - ob.x, oa.z - ob.z)).toBeLessThan(0.02);
    const net = await b.evaluate(() => (window as any).__gd.net());
    console.log(`p2p: guest round trip ${net.rttMs?.toFixed(0)} ms, snapshot age ${net.snapshotAgeMs?.toFixed(0)} ms, orderly at ${oa.x.toFixed(2)}, ${oa.z.toFixed(2)} on both`);
    expect(ea).toEqual([]);
    expect(eb).toEqual([]);
  } finally {
    await ca.close();
    await cb.close();
  }
});
