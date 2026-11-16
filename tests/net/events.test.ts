// Test 5: events arrive exactly once and in order on every client, under heavy loss, reordering and
// duplication, and a client that misses many snapshots in a row still ends with the host's list.
// Test 9: the same seeds give identical message streams.

import { describe, expect, it } from 'vitest';
import { LOSSY, Session, type NetConfig } from './harness';
import { agreement } from './rule';

const HARSH: NetConfig = { delayMin: 0.02, delayMax: 0.25, jitter: 0.06, loss: 0.2, reorder: 0.3, reorderDelay: 0.15, duplicate: 0.2 };

describe('events: exactly once, in order', () => {
  it('under 20% loss, 30% reordering and 20% duplication, and through a 3 s blackout of one client', () => {
    const out: { label: string; disagreements: string[]; eventsChecked: number }[] = [];
    let blackedOut = 0;
    for (let i = 0; i < 16; i++) {
      const s = new Session({ seed: `events-${i}`, remotes: 2, net: HARSH, setup: i % 2 ? 'run' : 'hunt' });
      s.run(10);
      // p1 hears nothing from the host for 3 s (60 snapshots in a row).
      s.net.setLink('host', 'p1', { loss: 1 });
      s.run(10.6); // what was already in flight lands
      const before = s.machines.find((m) => m.id === 'p1')?.client.events.length ?? 0;
      s.run(13);
      const during = s.machines.find((m) => m.id === 'p1')?.client.events.length ?? 0;
      expect(during).toBe(before);
      blackedOut += s.host.log.filter((l) => l.tick > 200 && l.tick <= 260).length;
      s.net.setLink('host', 'p1', { loss: HARSH.loss });
      s.run(60);
      const r = { label: `events-${i}`, disagreements: [] as string[], eventsChecked: 0 };
      agreement(s, r);
      // Exactly once: never more events than the host has, never a duplicate in a row of ids.
      for (const m of s.machines) expect(m.client.events.length).toBeLessThanOrEqual(s.host.log.length);
      out.push(r);
    }
    const checked = out.reduce((a, r) => a + r.eventsChecked, 0);
    console.log(`events: ${out.length} harsh sessions, ${checked} client events checked against the host's log; ${blackedOut} events were produced during blackouts`);
    expect(out.flatMap((r) => r.disagreements)).toEqual([]);
    expect(checked).toBeGreaterThan(1500);
    expect(blackedOut).toBeGreaterThan(0);
  }, 120_000);
});

describe('determinism', () => {
  it('9. the same seeds give identical message streams', () => {
    const stream = (seed: string): { hash: number; sent: number } => {
      const s = new Session({ seed, remotes: 3, net: LOSSY });
      s.run(30);
      let sent = 0;
      for (const st of s.net.stats.values()) sent += st.sent;
      return { hash: s.net.streamHash, sent };
    };
    for (const seed of ['det-a', 'det-b']) {
      const a = stream(seed);
      const b = stream(seed);
      expect(a.sent).toBeGreaterThan(4000);
      expect(b).toEqual(a);
    }
    expect(stream('det-a').hash).not.toBe(stream('det-b').hash);
  }, 120_000);
});
