// Tapes: where a player's readings sit until the crew banks them. Pure data and small helpers;
// the crew logic that drops and picks tapes up lives in instrument.ts.

/** A trait an entity has. Each trait's safety rule says when it can be recorded. */
export type Trait = 'stillness';

/** One closed reading: a continuous stretch of recording one trait of one entity. */
export interface Reading {
  /** Unique within a run. */
  id: string;
  /** Who held the instrument. */
  playerId: string;
  entityId: string;
  trait: Trait;
  /** Pay, already multiplied by the repeat factor that applied while it was recorded. */
  value: number;
  /** Seconds of actual recording in it (gaps not counted). */
  duration: number;
  /** Highest per-second rate reached (after the repeat factor). */
  peakRate: number;
  /** Simulation time it was closed. */
  closedAt: number;
}

export interface Tape {
  id: string;
  /** Whose instrument recorded onto it (it may be carried by someone else). */
  ownerId: string;
  readings: readonly Reading[];
  /** Sum of the readings' values. */
  total: number;
}

export function emptyTape(id: string, ownerId: string): Tape {
  return { id, ownerId, readings: [], total: 0 };
}

/** A copy of the tape with one more reading on it. */
export function addReading(tape: Tape, reading: Reading): Tape {
  return { ...tape, readings: [...tape.readings, reading], total: tape.total + reading.value };
}

/** What a tape, or a set of tapes, is worth. */
export function tapeValue(tapes: Tape | readonly Tape[]): number {
  const list: readonly Tape[] = 'readings' in tapes ? [tapes] : tapes;
  let sum = 0;
  for (const t of list) for (const r of t.readings) sum += r.value;
  return sum;
}
