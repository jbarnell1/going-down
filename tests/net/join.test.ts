// Test 8: a third player joins a run in progress, is told the seed and the state, watches, and
// becomes a player at the next elevator stop; a player leaves and becomes inactive; snapshots keep
// within the size bound. Also: the host leaving ends the session.

import { describe, expect, it } from 'vitest';
import type { RunPlayer, RunState } from '../../src/sim/run';
import { carBody, HOLD_LIMIT, inCar } from '../../src/sim/run';
import { Session } from './harness';

const NET = { delayMin: 0.05, delayMax: 0.2, jitter: 0.04, loss: 0.05, reorder: 0.05, reorderDelay: 0.1, duplicate: 0.03 };

/** Both players aboard on the DOWN side, the bell 3 s away, the Orderly asleep for good. */
function aboutToRide(s: RunState): RunState {
  return {
    ...s,
    phase: 'boarding',
    bellLeft: 3,
    holdLeft: HOLD_LIMIT,
    players: s.players.map((p, i): RunPlayer => ({ ...p, body: carBody(s.car, 0.8 + 0.5 * i, 0.5), aboard: true })),
    orderly: { ...s.orderly, mode: 'dormant', dormantLeft: 1e9 },
  };
}

describe('joining and leaving', () => {
  it('a third player joins mid-run (seed and state at once, a player from the next stop); a player leaves and goes inactive', () => {
    const s = new Session({ seed: 'join-1', remotes: 1, net: NET, prepare: aboutToRide });
    s.run(1);
    const joiner = s.addMachine('p2', true);
    s.run(2);
    const c = joiner.client;
    // Welcomed: the seed and the whole state, watching for now.
    expect(c.id).toBe('p2');
    expect(c.seed).toBe('join-1');
    expect(c.playing).toBe(false);
    expect(c.latest?.depth).toBe(1);
    expect(c.latest?.players.map((p) => p.id)).toEqual(['p0', 'p1']);
    expect(c.latest?.crew.map((m) => m.id)).toEqual(['p0', 'p1']);
    expect(s.host.state.players.map((p) => p.id)).toEqual(['p0', 'p1']);
    expect(joiner.last?.orderly).not.toBeNull(); // it draws the floor's Orderly as a spectator

    // The ride, and the next stop: in the car on floor 2, a player.
    s.run(12);
    const st = s.host.state;
    expect(st.depth).toBe(2);
    const p2 = st.players.find((p) => p.id === 'p2');
    expect(p2?.status).toBe('ok');
    expect(p2 && inCar(st.car, p2.body)).toBe(true);
    expect(st.crew.members.find((m) => m.id === 'p2')?.tape.readings).toEqual([]);
    expect(c.playing).toBe(true);
    expect(c.localDepth).toBe(2);
    expect(joiner.body && inCar(st.car, joiner.body)).toBe(true);
    expect(c.latest?.players.find((p) => p.id === 'p2')?.active).toBe(true);
    // Its events start where it joined, and are the host's from there.
    const from = c.firstEvent;
    expect(from).toBeGreaterThan(1);
    expect(c.events.map((e) => JSON.stringify(e))).toEqual(s.host.log.slice(from - 1, from - 1 + c.events.length).map((l) => JSON.stringify(l.e)));
    expect(c.events.some((e) => e.type === 'rodeDown')).toBe(true);

    // p1 leaves: inactive at once, still in the run's list, never active again.
    s.leave('p1');
    s.run(20);
    const gone = s.host.state.players.find((p) => p.id === 'p1');
    expect(gone?.status).toBe('leftBehind');
    const seenBy0 = s.machines[0]?.client.latest?.players.find((p) => p.id === 'p1');
    expect(seenBy0?.active).toBe(false);
    expect(seenBy0?.connected).toBe(false);
    expect(s.host.roster().find((p) => p.id === 'p1')?.left).toBe(true);
    // Snapshots kept within the bound throughout.
    const max = Math.max(...s.host.snapshotSizes.map((x) => x.bytes));
    console.log(`join/leave: joiner admitted at depth ${st.depth}, first event #${from}; largest snapshot ${max} B`);
    expect(max).toBeLessThanOrEqual(1500);
  }, 120_000);

  it('the host leaving ends the session for everyone (no host migration)', () => {
    const s = new Session({ seed: 'join-2', remotes: 2, net: NET });
    s.run(3);
    expect(s.machines.every((m) => !m.client.ended)).toBe(true);
    s.host.close();
    s.run(4);
    expect(s.machines.every((m) => m.client.ended)).toBe(true);
  }, 120_000);
});
