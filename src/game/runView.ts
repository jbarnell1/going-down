// What a page shows of the run, in one shape whether this page hosts it or not. On the host's page
// it is read from the run itself (exact numbers: the tests compare readings to six places); on
// every other page from the newest snapshot the host sent, plus what the events have said (the
// call's length, a false stop). Everything that moves on screen (the Orderly, the other players)
// does not come from here but from NetClient.frame().

import type { NetClient } from '../net/client';
import type { NetHost } from '../net/host';
import type { BlinkSnap, FloorTapeSnap, MemberSnap, OrderlySnap, SnapPlayer, WorldSnap } from '../net/protocol';
import type { RunEvent, RunPhase, RunSummary } from '../sim/run';

export interface CallView {
  floorsAway: number;
  /** Floors the car had to come when called. */
  floors: number;
  falseStop: boolean;
  /** Seconds until it arrives (host only; null when not known). */
  eta: number | null;
}

export interface RunView {
  phase: RunPhase;
  depth: number;
  /** Run time, seconds. */
  t: number;
  bellLeft: number;
  holdLeft: number;
  held: boolean;
  calls: number;
  call: CallView | null;
  blink: BlinkSnap | null;
  summary: RunSummary | null;
  players: SnapPlayer[];
  crew: MemberSnap[];
  floor: FloorTapeSnap[];
  orderly: OrderlySnap & { moving: boolean };
}

export function doorsOpenView(v: RunView): boolean {
  return v.phase === 'unloading' || v.phase === 'boarding';
}

/** Every player is blind (a blink is on), by the run's clock. */
export function blinkingView(v: RunView): boolean {
  return v.blink !== null && v.blink.endsAt !== null;
}

/** The lights warn of a blink (announced, not yet dark). */
export function blinkWarningView(v: RunView): boolean {
  return v.blink !== null && v.blink.announced && v.blink.endsAt === null;
}

/** The run as the host has it. */
export function hostView(host: NetHost): RunView {
  const s = host.state;
  const w = host.world();
  const c = s.call;
  return {
    ...pick(w),
    t: s.t,
    calls: s.calls,
    call: c ? { floorsAway: c.floorsAway, floors: c.plan.floors, falseStop: c.stopUntil !== null, eta: s.phase === 'coming' ? Math.max(0, c.at + c.plan.wait - s.t) : null } : null,
    orderly: { ...w.orderly, moving: s.orderly.moving },
  };
}

/** What a client knows of the call from the events (the snapshot only says how far away it is). */
export class CallTracker {
  floors = 0;
  calls = 0;
  private stopUntil = -1;

  reset(): void {
    this.floors = 0;
    this.calls = 0;
    this.stopUntil = -1;
  }

  onEvent(e: RunEvent): void {
    if (e.type === 'called') {
      this.calls++;
      this.floors = e.floorsAway;
    } else if (e.type === 'falseStop') this.stopUntil = e.t + e.extra;
    else if (e.type === 'carArrived' || e.type === 'rodeDown') this.stopUntil = -1;
  }

  falseStop(t: number): boolean {
    return t < this.stopUntil;
  }
}

/** The run as a client last heard it. Null before the first state arrives. */
export function clientView(client: NetClient, calls: CallTracker): RunView | null {
  const w = client.latest;
  if (!w) return null;
  return {
    ...pick(w),
    t: w.ht,
    calls: calls.calls,
    call: w.floorsAway === null ? null : { floorsAway: w.floorsAway, floors: Math.max(calls.floors, w.floorsAway), falseStop: calls.falseStop(w.ht), eta: null },
    orderly: { ...w.orderly, moving: w.orderly.speed > 0 && !w.orderly.frozen },
  };
}

function pick(w: WorldSnap): Omit<RunView, 't' | 'calls' | 'call' | 'orderly'> {
  return {
    phase: w.phase,
    depth: w.depth,
    bellLeft: w.bellLeft,
    holdLeft: w.holdLeft,
    held: w.held,
    blink: w.blink,
    summary: w.summary,
    players: w.players,
    crew: w.crew,
    floor: w.floor,
  };
}
