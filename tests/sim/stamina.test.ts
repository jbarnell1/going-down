import { describe, expect, it } from 'vitest';
import {
  CREEP_SPEED, freshStamina, gaitFor, RECOVER_RESTING, RECOVER_WALKING, speedFor, SPRINT_SECONDS, SPRINT_SPEED,
  stepStamina, sustainedFleeSpeed, WALK_SPEED, WINDED_UNTIL, type Stamina,
} from '../../src/sim/stamina';
import { HUNT_SPEED } from '../../src/sim/entity';

const DT = 1 / 20;
const run = (st: Stamina, seconds: number, gait: 'creep' | 'walk' | 'sprint', speed: number): Stamina => {
  for (let t = 0; t < seconds - 1e-9; t += DT) st = stepStamina(st, gait, speed, DT);
  return st;
};
const wish = (o: Partial<{ sprint: boolean; creep: boolean; moving: boolean; cap: number }>) =>
  ({ sprint: false, creep: false, moving: true, cap: Infinity, ...o });

describe('stamina', () => {
  it('a full tank sprints for SPRINT_SECONDS, then you are winded', () => {
    let st = freshStamina();
    st = run(st, SPRINT_SECONDS - 0.2, 'sprint', SPRINT_SPEED);
    expect(st.winded).toBe(false);
    expect(gaitFor(st, wish({ sprint: true }))).toBe('sprint');
    st = run(st, 0.4, 'sprint', SPRINT_SPEED);
    expect(st.level).toBe(0);
    expect(st.winded).toBe(true);
    expect(gaitFor(st, wish({ sprint: true }))).toBe('walk');
  });

  it('winded players cannot sprint again until the tank passes the mark', () => {
    let st: Stamina = { level: 0, winded: true };
    st = run(st, RECOVER_WALKING * WINDED_UNTIL - 0.3, 'walk', WALK_SPEED);
    expect(gaitFor(st, wish({ sprint: true }))).toBe('walk');
    st = run(st, 0.6, 'walk', WALK_SPEED);
    expect(st.winded).toBe(false);
    expect(gaitFor(st, wish({ sprint: true }))).toBe('sprint');
  });

  it('standing still or creeping recovers faster than walking', () => {
    const walking = run({ level: 0, winded: true }, 3, 'walk', WALK_SPEED).level;
    const standing = run({ level: 0, winded: true }, 3, 'walk', 0).level;
    const creeping = run({ level: 0, winded: true }, 3, 'creep', CREEP_SPEED).level;
    expect(standing).toBeGreaterThan(walking);
    expect(creeping).toBeCloseTo(standing, 6);
    expect(run({ level: 0, winded: true }, RECOVER_RESTING + 0.1, 'walk', 0).level).toBe(1);
  });

  it('sprinting into a wall costs nothing', () => {
    const st = run(freshStamina(), 3, 'sprint', 0);
    expect(st.level).toBe(1);
  });

  it('creep wins over sprint, and a capped player (the raised instrument) cannot sprint', () => {
    const st = freshStamina();
    expect(gaitFor(st, wish({ sprint: true, creep: true }))).toBe('creep');
    expect(gaitFor(st, wish({ sprint: true, cap: 2.2 }))).toBe('walk');
    expect(speedFor('walk', 2.2)).toBe(2.2);
    expect(gaitFor(st, wish({ sprint: true, moving: false }))).toBe('walk');
    expect(speedFor('sprint')).toBe(SPRINT_SPEED);
    expect(speedFor('creep')).toBe(CREEP_SPEED);
  });

  it('never leaves the range 0 to 1', () => {
    let st = freshStamina();
    for (let i = 0; i < 4000; i++) {
      st = stepStamina(st, i % 7 < 4 ? 'sprint' : i % 3 ? 'walk' : 'creep', i % 5 ? 5 : 0, DT);
      expect(st.level).toBeGreaterThanOrEqual(0);
      expect(st.level).toBeLessThanOrEqual(1);
    }
  });

  // The design in numbers. These three assertions are the owner's request: the Orderly is faster than
  // a walk, and a player mixing running and walking stays ahead of it, but not by much.
  it('the Orderly is faster than a walk and slower than a sprint', () => {
    expect(HUNT_SPEED).toBeGreaterThan(WALK_SPEED);
    expect(HUNT_SPEED).toBeLessThan(SPRINT_SPEED);
  });

  it('a tired player cycling run and walk only just outpaces it', () => {
    const flee = sustainedFleeSpeed();
    console.log(`sustained flee ${flee.toFixed(3)} m/s against the Orderly's ${HUNT_SPEED} m/s (lead ${(flee - HUNT_SPEED).toFixed(3)} m/s)`);
    expect(flee).toBeGreaterThan(HUNT_SPEED);
    expect(flee - HUNT_SPEED).toBeLessThan(0.3);
  });

  it('simulated: a fleeing player with good timing gains a little over a minute, a walker is caught up', () => {
    // Player and Orderly on a straight line, the Orderly never seen (the worst case), 60 seconds.
    let st = freshStamina();
    let fled = 0;
    for (let t = 0; t < 60; t += DT) {
      const gait = gaitFor(st, wish({ sprint: true }));
      const v = speedFor(gait);
      fled += v * DT;
      st = stepStamina(st, gait, v, DT);
    }
    const hunted = HUNT_SPEED * 60;
    console.log(`60 s: fled ${fled.toFixed(1)} m, the Orderly ${hunted.toFixed(1)} m, a walker ${(WALK_SPEED * 60).toFixed(1)} m (gain ${(fled - hunted).toFixed(1)} m)`);
    expect(fled).toBeGreaterThan(hunted);          // you can stay in front...
    expect(fled - hunted).toBeLessThan(25);        // ...but not by much over a whole minute
    expect(WALK_SPEED * 60).toBeLessThan(hunted);  // and walking alone loses
  });
});
