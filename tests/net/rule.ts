// The property sessions behind tests 1 to 4: run a networked session and check, frame by frame on
// every client, what that client's screen showed, with the independent oracle (oracle.ts).

import { WIND_UP_TIME } from '../../src/sim/entity';
import { TICK } from '../../src/net/session';
import { planFor } from '../../src/net/session';
import { q2, samePose, type Pose } from '../../src/net/protocol';
import { oracleSees } from './oracle';
import { FRAME, Session, type NetConfig } from './harness';

export interface SessionResult {
  label: string;
  /** Visible frame pairs the oracle checked (visible in this frame and the one before, same floor). */
  pairs: number;
  /** Pairs where the pose changed: the rule broken on a screen. */
  violations: string[];
  visibleFrames: number;
  frames: number;
  putBacks: number;
  putBackDistances: number[];
  maxPutBack: number;
  boundViolations: number;
  maxViolationGap: number;
  reports: number;
  travelled: number;
  seenOnHost: boolean;
  catches: number;
  /** Catches where the victim's screen showed the Orderly during the wind-up, by window. */
  catchViolations: { strict: string[]; natural: string[]; displayed: string[] };
  catchHoldTicks: number;
  catchesForced: number;
  blinks: number;
  /** Frames inside a host blind window that were lit. */
  blinkViolations: string[];
  blinkFramesChecked: number;
  /** Extra seconds of darkness per (client, blink) beyond the host's blind window. */
  extraDark: number[];
  maxReleaseJump: number;
  releases: number;
  bigReleases: number;
  /** Test 6: drawn other players against where the host had them at the drawn time. */
  posChecks: number;
  maxPosErr: number;
  posOver: string[];
  /** Tests 5 and 6 at the end: disagreements with the host. */
  disagreements: string[];
  eventsChecked: number;
  clamped: number;
  /** Taken latches on the clients (see client.ts), those let go without a catch, and catches whose victim latched first. */
  latches: number;
  falseLatches: number;
  latchedCatches: number;
  /** Frames that were not taken between a victim's latch and its catch being drawn. */
  latchGaps: string[];
}

interface Track {
  g: number[];
  rt: number[];
  dark: boolean[];
  showed: boolean[];
  taken: boolean[];
  prevVis: boolean;
  prevPose: Pose | null;
  prevDepth: number;
}

/** Drawn players must be within this of the host's record at the drawn time (metres). */
export const POS_BOUND = 0.5;

/** Where the host had a player at host time `t` (between ticks, blended); null across a teleport. */
function hostBodyAt(s: Session, id: string, t: number): { x: number; y: number; z: number } | null {
  const k = Math.floor(t / TICK + 1e-6);
  const a = s.host.stateAt(k)?.players.find((p) => p.id === id)?.body;
  const b = s.host.stateAt(k + 1)?.players.find((p) => p.id === id)?.body;
  if (!a || !b) return null;
  // Placed by the run (rides, push-outs): the drawn figure blends across, so is not compared there.
  for (let j = k - 3; j <= k + 3; j++) {
    const p = s.host.stateAt(j)?.players.find((q) => q.id === id)?.body;
    const q = s.host.stateAt(j + 1)?.players.find((r) => r.id === id)?.body;
    if (p && q && (Math.hypot(p.x - q.x, p.z - q.z) > 1 || p.level !== q.level)) return null;
  }
  const f = Math.max(0, Math.min(1, t / TICK - k));
  return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, z: a.z + (b.z - a.z) * f };
}

export function runRuleSession(i: number, net: NetConfig, seconds: number): SessionResult {
  const seed = `net-${i}`;
  const remotes = 1 + (i % 3);
  const res: SessionResult = {
    label: `${seed} remotes${remotes}`,
    pairs: 0,
    violations: [],
    visibleFrames: 0,
    frames: 0,
    putBacks: 0,
    putBackDistances: [],
    maxPutBack: 0,
    boundViolations: 0,
    maxViolationGap: 0,
    reports: 0,
    travelled: 0,
    seenOnHost: false,
    catches: 0,
    catchViolations: { strict: [], natural: [], displayed: [] },
    catchHoldTicks: 0,
    catchesForced: 0,
    blinks: 0,
    blinkViolations: [],
    blinkFramesChecked: 0,
    extraDark: [],
    maxReleaseJump: 0,
    releases: 0,
    bigReleases: 0,
    posChecks: 0,
    maxPosErr: 0,
    posOver: [],
    disagreements: [],
    eventsChecked: 0,
    clamped: 0,
    latches: 0,
    falseLatches: 0,
    latchedCatches: 0,
    latchGaps: [],
  };
  const tracks = new Map<string, Track>();
  let lastBody: { x: number; z: number } | null = null;
  let lastDepth = 1;
  const s = new Session({
    seed,
    remotes,
    net,
    onTick: (ss) => {
      const st = ss.host.state;
      const b = st.orderly.body;
      if (lastBody && st.depth === lastDepth) res.travelled += Math.hypot(b.x - lastBody.x, b.z - lastBody.z);
      lastBody = { x: b.x, z: b.z };
      lastDepth = st.depth;
      if (st.orderly.seen) res.seenOnHost = true;
    },
    onFrame: (m, rec) => {
      let t = tracks.get(m.id);
      if (!t) {
        t = { g: [], rt: [], dark: [], showed: [], taken: [], prevVis: false, prevPose: null, prevDepth: -1 };
        tracks.set(m.id, t);
      }
      res.frames++;
      const pose = rec.pose;
      const vis = !rec.dark && pose !== null && oracleSees(planFor(seed, rec.depth), rec.cam, pose);
      if (vis) res.visibleFrames++;
      if (vis && t.prevVis && pose && t.prevPose && rec.depth === t.prevDepth) {
        res.pairs++;
        if (!samePose(pose, t.prevPose)) {
          res.violations.push(
            `${res.label} ${m.id} t=${rec.g.toFixed(3)} drawn moved ${Math.hypot(pose.x - t.prevPose.x, pose.z - t.prevPose.z).toFixed(3)} m (clock ${t.prevPose.animTime}->${pose.animTime}) while visible`,
          );
        }
      }
      // 6. Other players, drawn where the host had them at the (delayed) time being drawn.
      for (const dp of rec.frame.players) {
        const truth = hostBodyAt(s, dp.id, rec.rt);
        if (!truth) continue;
        res.posChecks++;
        const err = Math.hypot(dp.body.x - truth.x, dp.body.z - truth.z, dp.body.y - truth.y);
        res.maxPosErr = Math.max(res.maxPosErr, err);
        if (err > POS_BOUND) res.posOver.push(`${res.label} ${m.id} draws ${dp.id} ${err.toFixed(2)} m off at t=${rec.g.toFixed(2)}`);
      }
      t.prevVis = vis;
      t.prevPose = pose;
      t.prevDepth = rec.depth;
      t.g.push(rec.g);
      t.rt.push(rec.rt);
      t.dark.push(rec.dark);
      t.showed.push(vis || rec.seeing);
      t.taken.push(rec.frame.taken);
    },
  });
  s.run(seconds);
  agreement(s, res);

  const h = s.host;
  res.putBacks = h.stats.putBacks;
  res.putBackDistances = h.stats.putBackDistances;
  res.maxPutBack = h.stats.maxPutBack;
  res.boundViolations = h.stats.boundViolations;
  res.maxViolationGap = h.stats.maxViolationGap;
  res.reports = h.stats.reports;
  res.catchHoldTicks = h.stats.catchHoldTicks;
  res.catchesForced = h.stats.catchesForced;
  res.clamped = h.stats.clampedInputs;
  for (const m of s.machines) {
    res.maxReleaseJump = Math.max(res.maxReleaseJump, m.client.stats.maxReleaseJump);
    res.releases += m.client.stats.releases;
    res.bigReleases += m.client.stats.bigReleases;
    res.latches += m.client.stats.latches;
    res.falseLatches += m.client.stats.falseLatches;
  }

  // 3. Looking saves you.
  const windUps = new Map<string, number>();
  for (const { e } of h.log) {
    if (e.type === 'windUp') windUps.set(e.playerId, e.t);
    if (e.type !== 'caught') continue;
    res.catches++;
    const w = windUps.get(e.playerId);
    const t = tracks.get(e.playerId);
    if (w === undefined || !t) continue;
    const c = e.t;
    // From the victim's latch on, every frame drawing a moment before the catch is a taken (blind) frame.
    let latched = false;
    for (let k = 0; k < t.g.length; k++) {
      const rt = t.rt[k] as number;
      if (rt < w || rt >= c) continue;
      if (t.taken[k]) latched = true;
      else if (latched) res.latchGaps.push(`${res.label} ${e.playerId} caught t=${c.toFixed(2)}: frame at t=${(t.g[k] as number).toFixed(3)} drawing t=${rt.toFixed(3)} not blind after the latch`);
    }
    if (latched) res.latchedCatches++;
    for (let k = 0; k < t.g.length; k++) {
      if (!t.showed[k]) continue;
      const g = t.g[k] as number;
      const rt = t.rt[k] as number;
      const tag = `${res.label} ${e.playerId} caught t=${c.toFixed(2)} windUp t=${w.toFixed(2)}`;
      if (g >= w && g <= c) res.catchViolations.strict.push(`${tag} screen showed it at t=${g.toFixed(3)}`);
      if (g >= w && g <= w + WIND_UP_TIME) res.catchViolations.natural.push(`${tag} screen showed it at t=${g.toFixed(3)}`);
      if (rt >= w && rt < c) res.catchViolations.displayed.push(`${tag} screen showed it drawing t=${rt.toFixed(3)}`);
    }
  }

  // 4. Blinks: every frame inside a host blind window is dark on every client.
  let start: number | null = null;
  for (const { e } of h.log) {
    if (e.type === 'blinkStart') start = e.t;
    if (e.type !== 'blinkEnd' || start === null) continue;
    res.blinks++;
    const lo = start - TICK;
    const hi = e.t - TICK;
    for (const [id, t] of tracks) {
      let dark = 0;
      for (let k = 0; k < t.g.length; k++) {
        const g = t.g[k] as number;
        if (g > lo && g <= hi) {
          res.blinkFramesChecked++;
          if (!t.dark[k]) res.blinkViolations.push(`${res.label} ${id} lit at t=${g.toFixed(3)} in blink ${start.toFixed(2)}-${e.t.toFixed(2)}`);
        }
        if (g >= start - 3 && g <= e.t + 3 && t.dark[k]) dark++;
      }
      res.extraDark.push(dark * FRAME - (hi - lo));
    }
    start = null;
  }
  return res;
}

/** Tests 5 and 6 at the end of a session: every client agrees with the host. */
export function agreement(s: Session, res: { label: string; disagreements: string[]; eventsChecked: number }): void {
  const h = s.host;
  const hostEvents = h.log.map((l) => JSON.stringify(l.e));
  for (const m of s.machines) {
    if (m.gone) continue;
    const c = m.client;
    const w = c.latest;
    if (!w) {
      res.disagreements.push(`${res.label} ${m.id} has no state`);
      continue;
    }
    if (w.tick < h.tick - 20) res.disagreements.push(`${res.label} ${m.id} is ${h.tick - w.tick} ticks behind`);
    const hs = h.stateAt(w.tick);
    if (!hs) continue;
    const tapes = (members: readonly { id: string; tape: { id: string; readings: number; total: number }; carrying: readonly { id: string; readings: number; total: number }[] }[]): string =>
      members.map((mm) => `${mm.id}:${[mm.tape, ...mm.carrying].map((tp) => `${tp.id}/${tp.readings}/${q2(tp.total)}`).join(',')}`).join(' ');
    const mine = {
      phase: w.phase,
      depth: w.depth,
      tapes: tapes(w.crew),
      floor: w.floor.map((f) => `${f.id}/${f.readings}/${q2(f.total)}`).join(','),
      banked: w.summary ? `${w.summary.wiped ? 'wiped' : 'banked'} ${q2(w.summary.total)} ${Object.entries(w.summary.shares).map(([k, v]) => `${k}=${q2(v)}`).join(',')}` : null,
    };
    const host = {
      phase: hs.phase,
      depth: hs.depth,
      tapes: tapes(hs.crew.members.map((mm) => ({ id: mm.id, tape: { id: mm.tape.id, readings: mm.tape.readings.length, total: mm.tape.total }, carrying: mm.carrying.map((tp) => ({ id: tp.id, readings: tp.readings.length, total: tp.total })) }))),
      floor: hs.crew.floor.map((f) => `${f.tape.id}/${f.tape.readings.length}/${q2(f.tape.total)}`).join(','),
      banked: hs.summary ? `${hs.summary.wiped ? 'wiped' : 'banked'} ${q2(hs.summary.total)} ${Object.entries(hs.summary.shares).map(([k, v]) => `${k}=${q2(v)}`).join(',')}` : null,
    };
    if (JSON.stringify(mine) !== JSON.stringify(host)) res.disagreements.push(`${res.label} ${m.id} at tick ${w.tick}: ${JSON.stringify(mine)} vs host ${JSON.stringify(host)}`);
    // 5. Events: exactly the host's, in its order, with nothing missing up to a second before the end.
    const got = c.events.map((e) => JSON.stringify(e));
    res.eventsChecked += got.length;
    for (let k = 0; k < got.length; k++) {
      if (got[k] !== hostEvents[k]) {
        res.disagreements.push(`${res.label} ${m.id} event ${k + 1}: ${got[k]} vs host ${hostEvents[k]}`);
        break;
      }
    }
    const due = h.log.filter((l) => l.tick <= w.tick - 20).length;
    if (got.length < due) res.disagreements.push(`${res.label} ${m.id} has ${got.length} events, host had ${due} a second before its newest state`);
  }
}
