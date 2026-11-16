import { describe, expect, it } from 'vitest';
import { hashSeed, makeRng } from '../../src/sim/rng';

describe('seeded rng', () => {
  it('gives the same sequence for the same seed', () => {
    const a = makeRng('building-7');
    const b = makeRng('building-7');
    const seqA = Array.from({ length: 50 }, () => a.next());
    const seqB = Array.from({ length: 50 }, () => b.next());
    expect(seqA).toEqual(seqB);
  });

  it('gives different sequences for different seeds', () => {
    const a = makeRng('building-7');
    const b = makeRng('building-8');
    expect(a.next()).not.toEqual(b.next());
  });

  it('stays inside [0, 1) and spreads evenly enough', () => {
    const r = makeRng(12345);
    let sum = 0;
    for (let i = 0; i < 20000; i++) {
      const v = r.next();
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThan(1);
      sum += v;
    }
    expect(sum / 20000).toBeGreaterThan(0.48);
    expect(sum / 20000).toBeLessThan(0.52);
  });

  it('int covers both ends of its range', () => {
    const r = makeRng('ints');
    const seen = new Set<number>();
    for (let i = 0; i < 500; i++) seen.add(r.int(2, 5));
    expect([...seen].sort()).toEqual([2, 3, 4, 5]);
  });

  it('a fork is repeatable and does not disturb its parent', () => {
    const a = makeRng('parent');
    const b = makeRng('parent');
    const forkValue = a.fork('floor-3').next();
    expect(b.fork('floor-3').next()).toEqual(forkValue);
    expect(a.next()).toEqual(b.next());
    expect(makeRng('parent').fork('floor-4').next()).not.toEqual(forkValue);
  });

  it('hashes strings to stable unsigned 32-bit values', () => {
    expect(hashSeed('going down')).toEqual(hashSeed('going down'));
    expect(hashSeed('a')).not.toEqual(hashSeed('b'));
    expect(hashSeed('anything')).toBeGreaterThanOrEqual(0);
  });

  it('refuses to pick from an empty list', () => {
    expect(() => makeRng(1).pick([])).toThrow();
  });
});
