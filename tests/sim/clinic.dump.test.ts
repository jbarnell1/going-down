// Writes ASCII maps of a few fixed floors to test-results/floors/ so layouts can be judged by eye.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { generateClinic } from '../../src/sim/clinic';
import { ASCII_LEGEND, hashPlan, renderAscii, sideBranches, type Door, type FloorPlan } from '../../src/sim/floor';

function roomAtFor(plan: FloorPlan) {
  return (d: Door, end: 'a' | 'b'): number => {
    const x = end === 'a' ? d.ax : d.bx;
    const y = end === 'a' ? d.ay : d.by;
    const r = plan.rooms.find((rr) => rr.level === d.level && x >= rr.x && x < rr.x + rr.w && y >= rr.y && y < rr.y + rr.h);
    return r ? r.id : -1;
  };
}

describe('clinic floor dumps', () => {
  it('writes maps for alpha, bravo and charlie', () => {
    const dir = join(process.cwd(), 'test-results', 'floors');
    mkdirSync(dir, { recursive: true });
    for (const seed of ['alpha', 'bravo', 'charlie']) {
      for (const depth of [1, 2, 4]) {
        const plan = generateClinic(seed, depth);
        const groups = sideBranches(plan.rooms, plan.doors, roomAtFor(plan));
        const lengths = plan.sightlines.map((s) => s.length).sort((a, b) => b - a);
        const header =
          `clinic seed=${seed} depth=${depth} size=${plan.width}x${plan.height} rooms=${plan.rooms.length} ` +
          `(L0 ${plan.rooms.filter((r) => r.level === 0).length}, L1 ${plan.rooms.filter((r) => r.level === 1).length}) ` +
          `stairs=${plan.stairs.length} sideBranches=${groups.length} (sizes ${groups.map((g) => g.length).join(',')}) ` +
          `sightlines=[${lengths.join(',')}] entity=L${plan.entityStart.level}(${plan.entityStart.x},${plan.entityStart.y}) ` +
          `hash=${hashPlan(plan)}`;
        const text = [
          header,
          `legend: ${ASCII_LEGEND}`,
          '',
          'level 0 (lower)',
          renderAscii(plan, 0),
          '',
          'level 1 (upper)',
          renderAscii(plan, 1),
          '',
        ].join('\n');
        writeFileSync(join(dir, `${seed}-d${depth}.txt`), text);
        expect(text.length).toBeGreaterThan(plan.width * plan.height * 2);
      }
    }
  });
});
