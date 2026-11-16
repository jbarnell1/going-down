// Tests 1 to 6 over many networked sessions: 1 host machine (its own player on a perfect loopback)
// and 1 to 3 remote players, bots driving every player, over links with one-way delays drawn per
// link from 0 to 250 ms, jitter up to 60 ms, 5% loss, some reordering and duplication. Every client
// renders at 60 frames a second in its own local time and every frame is checked by the independent
// oracle (oracle.ts) against where THAT client draws the Orderly.

import { describe, expect, it } from 'vitest';
import { LOSSY, ZERO } from './harness';
import { POS_BOUND, runRuleSession, type SessionResult } from './rule';

const SESSIONS = 200;
const SECONDS = 60;
const ZERO_SESSIONS = 40;

const sum = (rs: SessionResult[], f: (r: SessionResult) => number): number => rs.reduce((a, r) => a + f(r), 0);
const all = <T>(rs: SessionResult[], f: (r: SessionResult) => T[]): T[] => rs.flatMap(f);

describe('the rule under delay: 200 sessions of 60 s, every frame of every client checked by the oracle', () => {
  const t0 = performance.now();
  const lossy: SessionResult[] = [];
  for (let i = 0; i < SESSIONS; i++) lossy.push(runRuleSession(i, LOSSY, SECONDS));
  const zero: SessionResult[] = [];
  for (let i = 0; i < ZERO_SESSIONS; i++) zero.push(runRuleSession(i, ZERO, SECONDS));
  const secs = (performance.now() - t0) / 1000;

  const big = (rs: SessionResult[]): number => all(rs, (r) => r.putBackDistances).filter((d) => d > 0.6).length;
  const mean = (xs: number[]): number => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
  const extra = all(lossy, (r) => r.extraDark);
  const moved = lossy.filter((r) => r.travelled > 5).length;
  const seen = lossy.filter((r) => r.seenOnHost || r.reports > 0).length;
  const caught = lossy.filter((r) => r.catches > 0).length;
  console.log(
    [
      `net rule sessions: ${SESSIONS} lossy + ${ZERO_SESSIONS} zero-delay, ${SECONDS} s each, in ${secs.toFixed(1)} s`,
      `  1. frames checked ${sum(lossy, (r) => r.frames)}, visible ${sum(lossy, (r) => r.visibleFrames)}, visible frame pairs checked ${sum(lossy, (r) => r.pairs)}, violations ${sum(lossy, (r) => r.violations.length)}`,
      `     host put-backs ${sum(lossy, (r) => r.putBacks)} (of ${sum(lossy, (r) => r.reports)} seen reports), largest ${Math.max(...lossy.map((r) => r.maxPutBack)).toFixed(2)} m, mean ${mean(all(lossy, (r) => r.putBackDistances)).toFixed(2)} m, over 0.6 m: ${big(lossy)}`,
      `     bound violations (gap > 4 m, not moved) ${sum(lossy, (r) => r.boundViolations)}, largest gap ${Math.max(...lossy.map((r) => r.maxViolationGap)).toFixed(2)} m`,
      `     releases ${sum(lossy, (r) => r.releases)}, jumps over 0.25 m (out of view) ${sum(lossy, (r) => r.bigReleases)}, largest ${Math.max(...lossy.map((r) => r.maxReleaseJump)).toFixed(2)} m`,
      `  2. zero delay: put-backs ${sum(zero, (r) => r.putBacks)} (mean ${mean(all(zero, (r) => r.putBackDistances)).toFixed(2)} m, over 0.6 m: ${big(zero)}), lossy: ${sum(lossy, (r) => r.putBacks)} (over 0.6 m: ${big(lossy)})`,
      `     sessions where it moved > 5 m ${moved}/${SESSIONS}, was seen ${seen}/${SESSIONS}, caught someone ${caught}/${SESSIONS} (catches ${sum(lossy, (r) => r.catches)})`,
      `  3. catches ${sum(lossy, (r) => r.catches)}: victim's screen showed it during the wind-up (wall clock, natural 0.6 s) ${sum(lossy, (r) => r.catchViolations.natural.length)}, ` +
        `(wall clock, until the catch) ${sum(lossy, (r) => r.catchViolations.strict.length)}, (frames drawing the wind-up) ${sum(lossy, (r) => r.catchViolations.displayed.length)}; ` +
        `catch-hold ticks ${sum(lossy, (r) => r.catchHoldTicks)}, forced ${sum(lossy, (r) => r.catchesForced)}`,
      `  4. blinks ${sum(lossy, (r) => r.blinks)}, blind frames checked ${sum(lossy, (r) => r.blinkFramesChecked)}, lit ${sum(lossy, (r) => r.blinkViolations.length)}, ` +
        `extra darkness per blink per client ${mean(extra).toFixed(2)} s (max ${Math.max(...extra).toFixed(2)} s) on a 1.0 s blink`,
      `  6. drawn players checked ${sum(lossy, (r) => r.posChecks)}, largest error ${Math.max(...lossy.map((r) => r.maxPosErr)).toFixed(3)} m; 5. events checked ${sum(lossy, (r) => r.eventsChecked)}, disagreements ${sum(lossy, (r) => r.disagreements.length)}`,
    ].join('\n'),
  );

  it('1. on every client, a visible Orderly is drawn at exactly the same pose and clock as on the frame before', () => {
    expect(all(lossy, (r) => r.violations).slice(0, 10)).toEqual([]);
    expect(sum(lossy, (r) => r.pairs)).toBeGreaterThan(30000);
    expect(sum(lossy, (r) => r.boundViolations)).toBe(0);
  });

  it('1. the host honours what was seen: letting go of a held pose rarely needs a jump (and never in view)', () => {
    // A held pose is let go only when neither it nor the host's pose is in view; because the host
    // puts the Orderly back where the client holds it, the two are almost always the same pose. The
    // exceptions are two players holding different poses (the host keeps the earlier one).
    const releases = sum(lossy, (r) => r.releases);
    expect(releases).toBeGreaterThan(1000);
    expect(sum(lossy, (r) => r.bigReleases) / releases).toBeLessThan(0.08);
  });

  it('2. not vacuous: it moves, is seen, and catches; put-backs are rare and small without delay, common with it', () => {
    expect(moved / SESSIONS).toBeGreaterThan(0.8);
    expect(seen / SESSIONS).toBeGreaterThan(0.8);
    expect(caught).toBeGreaterThan(20);
    // With zero network delay the only lag is the 100 ms interpolation delay: put-backs stay small.
    expect(big(zero)).toBeLessThanOrEqual(2);
    expect(mean(all(zero, (r) => r.putBackDistances))).toBeLessThan(0.4);
    expect(sum(lossy, (r) => r.putBacks)).toBeGreaterThan(5 * Math.max(1, sum(zero, (r) => r.putBacks)) * (ZERO_SESSIONS / SESSIONS));
    expect(big(lossy)).toBeGreaterThan(50);
  });

  it('3. looking saves you: no catch of a player whose own screen showed the Orderly during the wind-up', () => {
    expect(all(lossy, (r) => r.catchViolations.natural)).toEqual([]);
    expect(all(lossy, (r) => r.catchViolations.displayed)).toEqual([]);
    expect(sum(lossy, (r) => r.catches)).toBeGreaterThan(20);
  });

  it('4. blinks: every frame on which the host treats players as blind is dark on every client', () => {
    expect(all(lossy, (r) => r.blinkViolations).slice(0, 10)).toEqual([]);
    expect(sum(lossy, (r) => r.blinks)).toBeGreaterThan(300);
    expect(mean(extra)).toBeLessThan(1.0);
  });

  it('5 and 6. events exactly once and in order, and at the end every client agrees with the host', () => {
    expect(all(lossy, (r) => r.disagreements).slice(0, 10)).toEqual([]);
    expect(sum(lossy, (r) => r.eventsChecked)).toBeGreaterThan(10000);
  });

  it('6. other players are drawn within a small bound of where the host had them at the drawn time', () => {
    expect(all(lossy, (r) => r.posOver).slice(0, 10)).toEqual([]);
    expect(sum(lossy, (r) => r.posChecks)).toBeGreaterThan(100000);
    expect(Math.max(...lossy.map((r) => r.maxPosErr))).toBeLessThanOrEqual(POS_BOUND);
  });
});
