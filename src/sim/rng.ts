// Seeded random numbers. Everything about a building comes from one seed, so every player
// who has the seed builds the same floors. No Math.random anywhere in src/sim.

/** Turns any string into a 32-bit seed. */
export function hashSeed(text: string): number {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

export interface Rng {
  /** A float in [0, 1). */
  next(): number;
  /** An integer in [min, max], both included. */
  int(min: number, max: number): number;
  /** True with the given probability. */
  chance(p: number): boolean;
  /** One item from a non-empty list. */
  pick<T>(items: readonly T[]): T;
  /** A new, independent generator derived from this seed and a label. Drawing from it does not disturb this one. */
  fork(label: string): Rng;
}

export function makeRng(seed: number | string): Rng {
  const base = typeof seed === 'string' ? hashSeed(seed) : seed >>> 0;
  let a = base;
  const next = (): number => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    chance: (p) => next() < p,
    pick: (items) => {
      if (items.length === 0) throw new Error('pick from an empty list');
      return items[Math.floor(next() * items.length)] as (typeof items)[number];
    },
    fork: (label) => makeRng(hashSeed(`${base}:${label}`)),
  };
}
