// The blackout: the blinks of a wait grow, and the last dark stretch is a long blackout that ends as
// the car's doors open. 1. The schedule, over many seeds and depths. 2. Fairness, by simulation: a
// crew that stands at the lift through it should usually lose someone; a crew that runs when warned,
// keeps moving, avoids dead ends and comes back should usually all survive and make the car.

import { describe, expect, it } from 'vitest';
import {
  BLACKOUT_FIRST_MAX,
  BLACKOUT_FIRST_MIN,
  BLACKOUT_MAX,
  BLACKOUT_MIN,
  BLACKOUT_WARNING,
  BLINK_FIRST_AFTER,
  BLINK_LADDER,
  BLINK_WARNING,
  callPlan,
  FLOOR_TIME,
} from '../../src/sim/run';
import { tableLine, waitTable, type WaitTable } from './waits';

describe('the dark schedule of a wait', () => {
  it('blinks grow, gaps fit, and the last dark is the blackout, ending exactly as the car arrives', () => {
    const problems: string[] = [];
    const steps: Record<number, number> = {};
    let falseStops = 0;
    let stopsInBlackout = 0;
    for (const depth of [1, 2, 3, 6]) {
      for (let i = 0; i < 500; i++) {
        const p = callPlan(`sched-${i}`, i % 3, null, depth);
        const tag = `depth ${depth} seed ${i}`;
        const d = p.darks;
        const last = d[d.length - 1];
        if (!last || !last.blackout) {
          problems.push(`${tag}: no blackout`);
          continue;
        }
        steps[d.length - 1] = (steps[d.length - 1] ?? 0) + 1;
        const [lo, hi] = depth === 1 ? [BLACKOUT_FIRST_MIN, BLACKOUT_FIRST_MAX] : [BLACKOUT_MIN, BLACKOUT_MAX];
        if (last.len < lo - 1e-9 || last.len > hi + 1e-9) problems.push(`${tag}: blackout ${last.len.toFixed(2)} s`);
        if (Math.abs(last.at + last.len - p.wait) > 1e-9) problems.push(`${tag}: blackout ends at ${(last.at + last.len).toFixed(3)}, car at ${p.wait.toFixed(3)}`);
        if (last.warn !== BLACKOUT_WARNING) problems.push(`${tag}: blackout warning ${last.warn}`);
        if (d.slice(0, -1).some((x) => x.blackout || x.warn !== BLINK_WARNING)) problems.push(`${tag}: a blink unlike a blink`);
        // Each longer than the last, from the ladder in order.
        d.slice(0, -1).forEach((x, k) => {
          if (x.len !== BLINK_LADDER[k]) problems.push(`${tag}: blink ${k} is ${x.len} s`);
        });
        for (let k = 1; k < d.length; k++) if ((d[k]?.len ?? 0) <= (d[k - 1]?.len ?? 0)) problems.push(`${tag}: dark ${k} not longer`);
        // In order, never overlapping (warning included), the first after BLINK_FIRST_AFTER.
        if (d[0] && d[0].at - d[0].warn < BLINK_FIRST_AFTER - 1e-9) problems.push(`${tag}: first warning at ${(d[0].at - d[0].warn).toFixed(2)} s`);
        for (let k = 1; k < d.length; k++) {
          const a = d[k - 1];
          const b = d[k];
          if (a && b && b.at - b.warn < a.at + a.len + 2.9) problems.push(`${tag}: dark ${k} warned ${(b.at - b.warn - a.at - a.len).toFixed(2)} s after the last`);
        }
        // A false stop (one floor above, FLOOR_TIME before the arrival) falls inside the blackout.
        if (p.falseStop) {
          falseStops++;
          if (p.wait - FLOOR_TIME - p.extra >= last.at - 1e-9) stopsInBlackout++;
        }
      }
    }
    console.log(`dark schedules: blinks before the blackout ${JSON.stringify(steps)}; false stops ${falseStops}, inside the blackout ${stopsInBlackout}`);
    expect(problems.slice(0, 10)).toEqual([]);
    // Short waits get fewer blinks, long ones more; the blackout is always there.
    expect(Object.keys(steps).length).toBeGreaterThanOrEqual(4);
    expect(stopsInBlackout).toBeGreaterThan(falseStops * 0.9);
  });

  it('is the same for every player: the same seed and call give the same schedule', () => {
    for (let i = 0; i < 50; i++) expect(callPlan(`same-${i}`, 2, 7, 3)).toEqual(callPlan(`same-${i}`, 2, 7, 3));
    expect(callPlan('x', 0, null, 1).darks).not.toEqual(callPlan('x', 1, null, 1).darks);
  });
});

describe('the blackout is fair: 300 seeded waits at depths 1, 2 and 3, crews of 1 to 4', () => {
  const WAITS = 300;
  const tables: WaitTable[] = [];
  for (const depth of [1, 2, 3]) for (const style of ['stay', 'flee'] as const) tables.push(waitTable(style, depth, WAITS).table);
  console.log(tables.map(tableLine).join('\n'));
  const of = (style: 'stay' | 'flee', depth: number): WaitTable => tables.find((t) => t.style === style && t.depth === depth) as WaitTable;

  it('a crew that stands at the lift through it loses someone in at least 70% of waits', () => {
    for (const depth of [1, 2, 3]) expect(of('stay', depth).lost / WAITS, `depth ${depth}`).toBeGreaterThanOrEqual(0.7);
  });

  it('a crew that runs when warned and comes back loses someone in at most 30%, and boards at least 80% of the time', () => {
    for (const depth of [1, 2, 3]) {
      const t = of('flee', depth);
      expect(t.lost / WAITS, `depth ${depth} lost`).toBeLessThanOrEqual(0.3);
      expect(t.boarded / WAITS, `depth ${depth} boarded`).toBeGreaterThanOrEqual(0.8);
    }
  });

  it('is a chase, not a walk: the fleeing crew gets well away from the car, and it comes close in some waits', () => {
    for (const depth of [1, 2, 3]) {
      const t = of('flee', depth);
      expect(t.medianFarthest, `depth ${depth}`).toBeGreaterThan(20);
      expect(t.chased / WAITS, `depth ${depth}`).toBeGreaterThan(0.1);
    }
  });
});
