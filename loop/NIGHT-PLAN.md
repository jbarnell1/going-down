# Night plan, 17 November 2026

The owner's goal: "a playable version significantly farther along than we currently are and maybe even with a floor past the annex." The floor is the Playroom, a children's play area with a new resident, the Minder (`docs/floors/playarea.md`). The owner's priority: "Just do the whole thing, even if not ready by morning." So nothing is cut. This plan is one queue that runs through the night and on into the day; the order makes every promoted build as playable as it can be. The run it is building towards: Clinic, Clinic, the Annex with the Temp, the Playroom, back up to the prison, through the day.

About 9 hours tonight. Three Opus lanes. Each lane owns its files, so worktrees never collide. Every piece is checked by a different Sonnet agent, who re-runs the proof and applies the deliberate break. Windowed game runs go one at a time: lanes A and B are checked headless (Blender renders are headless too), so only lane C queues for the window.

## Before the lanes start

- Merge what is in flight first: the rules agent's T6f and T5q (it is in `sim/run.gd`, which lane A owns next), then the sounds (TA, with the player-breath fix; it is in `client/sfx.gd`, which lane C owns).
- The Opus cap is 3 in all. The rules agent and the goldens agent count until they finish. Start B1 and C1 now (new files only). Start A1 when the rules agent reports; it can write `sim/places.gd` first and must rebase before touching `run.gd`.
- Every builder's brief needs its "What the North Star says" heading (A11, A2, B11, B6 and the fairness promises for the count pieces). The blind judges in B3 get `North Star: not applicable`.

## Who owns what

| Lane | Owns |
|---|---|
| **A, the run** | `sim/run.gd`, `sim/places.gd`, `net/*`, `server/*`, `tests/prop_run.gd`, the goldens |
| **B, new rules and the figure** | `sim/playroom.gd`, `sim/seek.gd`, `sim/entity.gd`, `sim/bot.gd`, their tests and tools; the Minder's Blender files, renders and exported model; `docs/ART-*` notes |
| **C, the screen** | `client/*`, `assets/*` except the Minder's model, `tools/play_*.mjs` and the walk tools |

Nobody but lane A edits `run.gd` or `net/`. Nobody but lane C edits `client/`. A piece that needs a line in another lane's file hands it over as a note, and that lane applies it in its next piece.

## Builds to promote, in order

1. **About hour 2:** ride down Clinic, Clinic, and the doors open on the Annex.
2. **About hour 4:** the Temp is in the Annex; the Playroom is floor 4 and walkable with the placeholder Minder wandering; BANK rides up to the prison and bed starts day 2.
3. **About hour 7:** the count works on the Playroom, with health and the last count.
4. **Hour 9 and on:** the party table, the Blender Minder, and the rest of the queue.

Promote after each with the combined check (quick tests, `play_web`, `play_desktop`, `play_net`), rebuild the zip, and redeploy the server whenever a message changed. Keep the Progress page current as each agent starts and finishes.

---

## Lane A: the run

### A1. T16e, the place deck
- **A player notices:** the third floor down is the yellow office, not another Clinic.
- **Owns:** new `sim/places.gd`, `tests/prop_places.gd`; the `generate_clinic` callers at `sim/run.gd:535`, `net/host_rules.gd:62`, `net/session.gd:61`.
- **Done:** `Places.place_at(seed, depth)` gives prison at 0, Clinic at 1 and 2, Annex at 3, Playroom at 4 (the Clinic stands in until `playroom.gd` lands), a seeded draw from 5 with no place twice running. `Places.generate(seed, depth)` is the one way the host and the client make a plan. `Places.resident(place)` names the resident (Orderly, Temp, Minder) and whether it is a Stillness one. A run takes a deck; the default deck is Clinic only; the game passes the full deck. The Annex's car zone fits the 4 m car.
- **Checker proves:** the quick set is green with no golden re-recorded; a headless run rides to depth 3 and the host's and a client's plan hashes agree and say `annex`; 200 seeds give the fixed order for depths 0 to 4.
- **Break:** make the full deck the default: the stored run results must go red. Second: let the client call `generate_clinic` directly: the hash check must go red at depth 3.
- **Depends on:** T6f/T5q merged before the `run.gd` edit.

### A2. T18j, the day in the run
- **A player notices:** vote BANK and the lift rides up to the prison; walk to your bunk, lie down, and you wake on day 2 going down again.
- **Owns:** `sim/run.gd`, `net/host_rules.gd`, `net/protocol.gd`, `net/host.gd`, `net/client.gd`, `net/local_room.gd`, `server/room.gd`, `tests/prop_run.gd`.
- **Done:** prison.md P7, behind a setting off in tests and on in the game. BANK banks the tapes (the float floored before `Day.end_day`) and loads the prison plan (depth 0, no resident). Hold F at a bunk to lie down; the bed count is `sim/day.gd`'s and cannot be stopped. Then a new day at depth 1 with seed `<seed>:day<n>`. The snapshot carries the day number, the day's result facts and who is in bed. After a wipe everyone wakes on a bunk.
- **Checker proves:** headless, three bots over the lossy test link play two days and agree on the day number, the banked total and the plan hash at every stop; no tape is banked twice; `ref_run`, `ref_net`, `ref_bridge` unchanged.
- **Break:** start day 2 with day 1's seed. Second: bank a tape left on the floor.
- **Depends on:** A1.

### A3. T15d, the count in the run and on the network
- **A player notices:** on floor 4 somebody sprints, the xylophone plays, the lights die, and the ball pit actually saves you.
- **Owns:** `sim/run.gd`, `net/host_rules.gd`, `net/protocol.gd`, `net/host.gd`, `net/client.gd`.
- **Done:** on the Playroom, `run.gd` steps `sim/seek.gd` instead of the Orderly's rules: provocations, the count, hide in and out as an input, the four ways of being found, the catch, health, recording gated as playarea.md section 11, the last count in place of the call wait. The snapshot adds each player's hide id, peek flag, health and sight total, and the crew's noise level. One `count` event carries host time, length, index, who and why. Applies lane B's note that gives the Annex the Temp's settings.
- **Checker proves:** three bots on a lossy link at 0, 100 and 300 ms: all clients agree on every count's start, length, cause and found list; a bot that only walks and creeps for five minutes starts no count and loses no health before the first count; one sprint tick starts one; a call ends in open doors only after a last count.
- **Break:** stamp the count event with the receiver's clock: clients' count times must disagree. Second: let a taken player's position count as a target.
- **Depends on:** A1, B1, B2.

### A4. T15h, the party table (rules)
- **A player notices:** found players sit at the party table in hats, can blow a horn, and can be fetched.
- **Owns:** `sim/run.gd`, `net/*`; a note to lane B for the seat spots in `playroom.gd` if they are not already there.
- **Done:** playarea.md section 9: seated state, the horn as an input that makes a sound but is never a noise that starts a count, fetching by holding F three seconds outside a count, 50 health on return.
- **Checker proves:** the horn never starts a count, inside or outside one; a fetch during a count is refused; fetched players are standing with 50 health on every client.
- **Break:** let the horn start a count (the owner made it harmless).
- **Depends on:** A3.

### A5. T8a, down first, then out
- **A player notices:** being caught, or running out of health, drops you where you stood; a friend holding F for three seconds puts you back up.
- **Owns:** `sim/run.gd`, `net/*`. A note to lane C for the crawl camera.
- **Done:** B6 as written: ten seconds down, heal by holding F three seconds beside, then out.
- **Checker proves:** over 200 bot runs a healed player is always standing, an unhealed one always out at ten seconds, and the Orderly targets nobody else meanwhile. **Break:** let the heal finish from 5 m.
- **Depends on:** A3.

### A6 onwards, in order
- **T16h** marks and sticky notes in the run and on the network (annex.md T4). Break: send marks only to their owner.
- **T18l** the night on the server: buying, undo, the stamped save (prison.md P8). Break: accept a purchase after bed.
- **T8b** the wipe scene and the cameras (F3).

---

## Lane B: new rules, and the figure

### B1. T15a, the Playroom generator
- **A player notices:** floor 4 is a soft-play centre: a ball pit hall, a netted frame of crawl dens, a party room, a toddler corner.
- **Owns:** new `sim/playroom.gd`, `sim/PLAYROOM.md`, `tests/prop_playroom.gd`, `tests/playroom_hashes.json`, `tools/playroom_tool.gd`.
- **Done:** playarea.md section 6: `generate_playroom`, `hides`, `squeakers`, `zones`, the party-table seats, with text maps of five floors showing all of them. Reuses `annex.gd` and `clinic.gd` by preload without editing them.
- **Checker proves:** the eight properties over 800 floors (40 quick); hashes equal on a second run; reads two maps.
- **Break:** remove an outer-ring segment (property 2); lay squeakers across a whole way in (property 6); swap a seeded draw for `randi()` (property 3).
- **Depends on:** nothing. Start at once.

### B2. T15b, the count, the Minder and health, as pure rules
- **A player notices:** nothing yet; this is what makes the seeker fair and a threat.
- **Owns:** new `sim/seek.gd`, `tests/prop_seek.gd`. Does not edit `entity.gd` or `run.gd`; it calls `Follow` and `Sight`.
- **Done:** playarea.md sections 2 to 5, 7 and 8: every provocation in the table (the light one driven by a test light), the 15 s, the count clock, hides in and out slow and fast, the four ways of being found, the search order, the 1 of n draw, the catch, the wander, health, the last count.
- **Checker proves:** the nine properties of section 5; reads the test's own geometry to see it is written apart from the rule.
- **Break:** let it take a player by touch outside a count (property 1); count sight during the 6 s (property 6); always look in hide 0 (property 4, default sizes); drain health during a count (property 9).
- **Depends on:** B1.

### B3. T15g, the Minder, modelled, rigged and animated in Blender
- **A player notices:** the placeholder becomes a tall padded attendant with a bobbing balloon for a head.
- **Owns:** the Minder's Blender scripts and files, its renders, its exported model under `assets/`, the art notes. It hands lane C one note: the model's path and animation names.
- **Done:** by the character process in `loop/LOOP.md`. (1) Study two Blender tutorials that fit it (a soft cloth-suited figure; a secondary-motion bone chain for the balloon and ribbon) from captions and sampled frames, and write what was learned into the art notes; delete the downloads. (2) Build: body, tabard panels, mittens, balloon with the face on one side only; rig; animations: wander, straighten, turn to the wall and cover the face, search walk, look in, run, the catch bend, the disappointed slump. (3) Two blind-judge rounds on renders, fixing between them. No other game's character is referenced or shown to the judges.
- **Checker proves:** the model loads in a headless Godot import; every named animation exists and loops or ends as listed; the face is on exactly one side (render from behind shows none); triangle and bone counts within the Orderly's; both judge rounds are on file with their scores.
- **Break:** export without the cover-face animation: the animation check must go red.
- **Depends on:** nothing but B2 being out of the way. Long: expect three hours or more. If lane B reaches it before hour 4, it runs beside lane A and C with no shared files.

### B4. T16f, the Temp's body
- **A player notices:** the thing in the Annex is shorter, clicks a stapler, and stops clicking the moment you look.
- **Owns:** `sim/entity.gd`, new `tests/prop_temp.gd`.
- **Done:** annex.md T5: the Orderly's numbers become a settings object, Orderly by default; the Temp is a second one (1.8 m, its own seen size, a click every 1.2 m and every 4 s waiting unseen). Stillness. Hands lane A one line for `Places.resident`.
- **Checker proves:** `ref_entity` and the goldens unchanged; the Temp never moves or clicks in a seen tick; a waiting unseen Temp clicks.
- **Break:** let the idle click ignore "seen".
- **Depends on:** nothing. It is short: do it before B3 if A1 has landed, so build 2 has the Temp.

### B5. T11a, a whole run with bots, headless
- **A player notices:** nothing; it is the proof that the build plays end to end.
- **Owns:** `sim/bot.gd`, new `tests/prop_whole_run.gd`.
- **Done:** bots that read, call, board, vote DOWN three times, hide when a count starts, creep afterwards, vote BANK, walk to bed. One test rides Clinic, Clinic, Annex, Playroom, banks, sleeps and wakes on day 2 over the in-memory network.
- **Checker proves:** 10 seeds complete (2 quick); every stop's place is the deck's; at least one count ran on every Playroom.
- **Break:** make the bots ignore the count: at least one must be found by sight.
- **Depends on:** A2, A3.

### B6 onwards
- **T16i** the Temp's stapled-note catch and drag (annex.md T6), after A5.
- **T15j** riding the tube slides down a level (one-way links in `playroom.gd` and `move`).

---

## Lane C: the screen

### C1. T16g, the Temp's figure and its stapler
- **A player notices:** an office worker with a sheet of paper for a face, and the face on the paper is a crewmate's drawing.
- **Owns:** new `client/temp_view.gd`, a demo scene, the one place `client/main.gd` picks the resident's view (by `plan.place`; this switch also serves the Minder), `client/sfx.gd` for the click after the TA merge.
- **Done:** a solid figure made in code tonight: shirt, tie, lanyard, a paper face showing a seeded crewmate's drawn face; idle and walk; the stapler click at its position. Driven by the resident state already in every snapshot.
- **Checker proves:** the demo's pictures show the right player's drawing on the paper (hashed against the face sent); the pose never changes on a frame the camera sees it; frame time within the Clinic's.
- **Break:** advance the walk while seen.
- **Depends on:** nothing. Start at once. Its real-run check waits for A1.

### C2. T15c, the Playroom's look, and the placeholder Minder
- **A player notices:** padded primary colours under white strip lights, a ball pit, netting, PLAY NICELY on the wall, and a sign that says HIDING PLACES HERE: 3. IT LOOKS IN 1.
- **Owns:** new `client/playroom_view.gd`, `client/minder_view.gd`, shaders, `playroom_demo`, `tools/playroom_walk.mjs`, one switch in `client/level.gd`.
- **Done:** playarea.md section 10's look from the real generator; every hide's furniture exactly at `Playroom.hides`; squeaker tiles with their printed note; zone signs; the lights that stay on in count dark; real lights under the limit (about 124, as the Annex). The placeholder Minder: capsule body, sphere head, face on one side, glowing, with the music box; **the client's pose hold is off for it** (it is not a Stillness resident).
- **Checker proves:** a desktop walk with pictures; every sign's number equals the zone's hide count from the rules; furniture within 5 cm of its hide; every squeaker tile drawn is in the rules' list and the reverse; frame time within the Clinic's.
- **Break:** draw the sign number from a local guess. Second: skip drawing one squeaker tile.
- **Depends on:** B1.

### C3. T18k, bed and the board on screen
- **A player notices:** the prison shows what the crew banked, and HOLD F TO SLEEP at your bunk works.
- **Owns:** `client/prison_view.gd`, `client/hud.gd`, `client/main.gd`, `client/lift.gd`.
- **Done:** the lift arrives in the prison in a real run; the day board shows the day's result facts; the bunk prompt, lying down, the bed count, lights out, waking. The windows show CLOSED TONIGHT until T18l.
- **Checker proves:** `play_net` extended: two clients bank, both read the same total, both sleep, both are on day 2 at depth 1.
- **Break:** show the board from the client's own sum.
- **Depends on:** A2.

### C4. T15e, the count on screen
- **A player notices:** three xylophone notes, HIDE, the lights go, the tune sags; you press F at the ball pit, lean up with W, and watch a glowing balloon turn your way.
- **Owns:** new `client/hide_view.gd`, `client/main.gd`, `client/hud.gd`, `client/sfx.gd`, `client/announcer.gd`, new `tools/play_hide.mjs`.
- **Done:** F to get in and out, slow and fast; the sat-back view; the gap camera clamped to the gap; count dark; the bell; the tune at half speed; captions for every line and for "Started by"; the trill; the health bar with its rates; other players drawn inside hides; the catch (the balloon filling the screen) and the hat.
- **Checker proves:** `play_hide`: two clients; one sprints and both see the count start within one snapshot of each other with the sprinter named; both hide; the bell's bus peaks once a second; a player standing in its view is found at 1.0 s by both clients' state; the health bar equals the host's number; the last count ends with doors open.
- **Break:** start count dark from the client's clock when the event arrives, not the event's host time: the two clients' dark must disagree under 300 ms delay. Second: mute, and the bell check must fail.
- **Depends on:** A3, C2.

### C5 onwards, in order
- **T15h (screen)** the party table view, the horn, the fetch prompt, after A4.
- **T15g (screen)** swap the placeholder for the Blender Minder and wire its animations, after B3. Check: no pose name from the rules is left without an animation.
- **T15i** recorded voice lines for the count, within the ElevenLabs cap and `docs/VOICE.md`.
- **T8a (screen)** the crawl camera and heal prompt, after A5.
- **T16j** marks, notes and the pad on screen (annex.md T10), after T16h.
- **T18m** the shop and skill windows on screen and the save on the PC (prison.md P11, P12), after T18l.
- **T7e** better crewmates and name tags; the noise needle on the instrument.

---

## If time runs short

Nothing is cut. Pieces that are not checked by morning carry on in the same order. What matters is what the morning build contains, so:

1. Never hold a promotion for a later piece. Builds 1 and 2 go out as soon as their checks are green.
2. **If the count (A3, C4) is not checked by morning:** the morning build has the Playroom at floor 4 with the placeholder Minder wandering harmlessly, and the Progress page says the count lands next. The run is still whole: Clinic, Clinic, Annex, Playroom, prison, bed, day 2.
3. **If the generator (B1) is late:** the deck goes Clinic, Clinic, Annex, Clinic until it lands.
4. **What slips first when a lane is behind:** in lane A, A5 and A6 before A4; in lane B, B3's second judge round and B6 before B5; in lane C, everything in C5 before C4.
5. If the window queue backs up, check C3 before C2: the prison closes the loop, the look does not.

## Open questions

Each has a default; build with it unless the owner answers.

1. **The Minder is a tall attendant in soft-play vinyl with a balloon for a head and a face drawn on one side?** Default: yes.
2. **It is a Hearing entity, not Stillness, and never takes anyone outside a count?** Default: yes.
3. **Walking is not a noise; sprinting and the listed things (squeaker tiles, flaps, the ball pit at speed, bumping it, a dropped tape, sound emotes, the horn) are?** Default: yes.
4. **15 s after a count when nothing provokes?** Default: yes.
5. **One hide looked in per zone, 1 of n, printed on the zone's sign; certain if it saw you get in or heard you?** Default: yes.
6. **Found by sight: 1.0 s in its view in total per count, never draining; count lengths 6 s to hide, then 30 s (35, 40, 45 later), last count 40 s?** Default: yes.
7. **Health: walking drains 3 a second, sprinting 8, resting restores 1, from the end of the first count until the lift leaves, the boarding dash included; at 0 you are down?** Default: yes.
8. **Taken players sit at the party table with a horn that counts as noise outside a count, and a friend can fetch them (hold F three seconds, outside a count)?** Default: yes to both.
9. **Counts pay double on the instrument, tuned with the quota?** Default: yes.
10. **The Temp tonight is a figure made in code with the Orderly's catch; its stapled-note drag follows (T16i)?** Default: yes.
11. **The prison's windows say CLOSED TONIGHT until buying is wired (T18l, T18m)?** Default: yes.
12. **From floor 5 the deck draws Clinic, Annex or Playroom by the seed, never the same twice running?** Default: yes.
13. **The lift's voice, through a cheap speaker, speaks the Playroom's lines; the place is called the Playroom?** Default: yes.
