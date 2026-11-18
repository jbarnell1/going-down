// Waiting for the car the way a careful person plays it, for the scripted runs (tools/playthrough.mjs,
// tools/sound_web.mjs). Since the owner's 17 Nov changes the game's rooms run the long dark (T20c: a longer
// blackout), paced residents (T20h: they hunt at 3.8 m/s) and down-then-out (T8a/T8c): playing alone a
// catch is down, then out, then (nobody left standing) the wipe. Standing at the lift with your back to
// the Orderly, or running down a corridor through a 15 s blackout, now ends the day; a careful player
// gets into a hide (T19b, sim/hiding.gd) while the Orderly cannot see them get in, and stays there until
// the lights come back with the car. Hidden with no reason (seen getting in, a fast noisy entry, an
// instrument ticking inside) it never hunts or looks for you (sim/run.gd "Hiding off the Playroom").
// "Seen getting in" is the Orderly's own view (Seek.SIGHT_RANGE 12 m, within 60 degrees of its face, a
// clear line), whether or not it is frozen, so the hide must be well away from it. In the light, watching
// it keeps it frozen, so the walk there and the 1.5 s of getting in are done looking at it.
// Nothing here is a test switch: every step is a command a person's keys make (walk, F, look).
//
// ctx: { cmd(text) -> reply, state() -> parsed state, wait(ms), until(pred, ms, every) -> state }

/** How far from the Orderly a hide's front must be to get in unseen (m): its sight range (12 m) with
 * room for it to close in while we walk there and get in, if it is not held. */
export const CLEAR_OF_IT = 17;

/** The hides on this floor (the client's `hides` list: metres). */
export async function hidesOf(ctx) {
  return JSON.parse(await ctx.cmd('hides'));
}

const keyed = (hides, s) => hides.filter((h) => h.level === s.me.level && h.kind !== 'desk');
const fromMe = (h, s) => Math.hypot(h.front[0] - s.me.x, h.front[1] - s.me.z);
const fromIt = (h, s) => {
  const o = s.orderly;
  if (!o) return 1e9;
  return Math.hypot(h.front[0] - o.x, h.front[1] - o.z, (h.level - o.level) * 3.2);
};

/** A hide (with a key press, not a desk, on our level) at most `reach` metres from us whose front is at
 * least CLEAR_OF_IT from the Orderly and further from it than we are: the nearest such, or null. */
export function safeHide(hides, s, reach = 18) {
  return keyed(hides, s).filter((h) => fromMe(h, s) <= reach && fromIt(h, s) >= CLEAR_OF_IT && fromIt(h, s) > fromMe(h, s) + 4)
    .sort((a, b) => fromMe(a, s) - fromMe(b, s))[0] ?? null;
}

/** The last resort (no safe hide in reach): the one with the most room between it and the Orderly. */
export function chooseHide(hides, s) {
  return safeHide(hides, s, 1e9) ?? keyed(hides, s).sort((a, b) => (fromIt(b, s) - fromMe(b, s)) - (fromIt(a, s) - fromMe(a, s)))[0] ?? null;
}

/** Looks at the Orderly when it is on our level and near enough to matter (in the light it freezes). */
export async function watchIt(ctx, s) {
  const o = s.orderly;
  if (o && o.level === s.me.level && o.distance < 30) await ctx.cmd(`face ${o.x} ${o.z} ${(o.pose?.y ?? 0) + 1.6}`);
}

/** Walks to the hide's front along the rules' path, looking at the Orderly on the way; the last steps by
 * hand; then, looking at it again, presses F once (the slow, quiet way) and waits until the host has us
 * inside. Returns the last state. */
export async function getIn(ctx, hide, pace = 5) {
  const { cmd, wait, until } = ctx;
  await cmd('raise 0'); // an instrument ticking inside is a reason to look in
  await cmd(`walkto ${hide.level} ${Math.floor(hide.front[0] / 2)} ${Math.floor(hide.front[1] / 2)} ${pace}`);
  await wait(100);
  let s = await ctx.state();
  for (const end = Date.now() + 20000; s.auto === 'walking' && Date.now() < end;) {
    await watchIt(ctx, s);
    await wait(50);
    s = await ctx.state();
  }
  for (const end = Date.now() + 6000; s.nearHide !== hide.id && Date.now() < end;) {
    await cmd(`face ${hide.front[0]} ${hide.front[1]}`);
    await cmd('move 1 0 0 0');
    await wait(50);
    s = await ctx.state();
  }
  await cmd('stopmove');
  await watchIt(ctx, s);
  await cmd('hide');
  for (const end = Date.now() + 5000; s.mySeek?.phase !== 'inside' && !(s.me?.status && s.me.status !== 'ok') && Date.now() < end;) {
    await watchIt(ctx, s);
    await wait(50);
    s = await ctx.state();
  }
  return s;
}

/** Right after the call: watching the Orderly while the lights are on, waits (up to `ms`) for a hide in
 * reach that is clear of it (safeHide), and gets in; with none by then, the best one left (chooseHide).
 * Returns { s, hide, note }. */
export async function hideForTheWait(ctx, ms = 12000) {
  const hides = await hidesOf(ctx);
  let s = await ctx.state();
  for (const end = Date.now() + ms; Date.now() < end && s.phase === 'coming';) {
    if (!s.dark && !s.warn) {
      await watchIt(ctx, s);
      const h = safeHide(hides, s, 30);
      if (h) {
        const note = `the Orderly ${s.orderly.distance.toFixed(1)} m away (${s.orderly.seeing ? 'watched' : 'not in view'})`;
        return { s: await getIn(ctx, h), hide: h, note };
      }
    }
    await ctx.wait(60);
    s = await ctx.state();
  }
  const h = chooseHide(hides, s);
  return { s: h ? await getIn(ctx, h) : s, hide: h, note: `no hide clear of it, the Orderly ${s.orderly?.distance?.toFixed(1)} m away` };
}

/** F again inside: out of the hide (the slow way), on their feet at its front. Returns the last state. */
export async function getOut(ctx) {
  const { cmd, until } = ctx;
  await cmd('hide');
  return until((t) => !t.mySeek || t.mySeek.phase === 'out', 5000, 50);
}
