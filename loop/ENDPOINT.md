# End point: the Clinic slice

Edit this file to change where the loop stops. The loop ends when every gate below is ticked in PROGRESS.md with evidence.

## What exists at the end

One crew of up to four in separate browser tabs rides the elevator down into a bright, two-level Clinic floor built from a seed. The Orderly, a full 3D figure made in Blender, is somewhere on it and can be heard before it is seen. The crew gets close, takes a reading under the recording rule, carries the tape back, calls the elevator, waits out the loud arrival, and banks or rides down to a deeper Clinic floor. Anyone caught goes down and watches through cameras. If everyone is down the run is wiped. It all sits under the tape-playback look.

## Gates

G1. **Builds clean.** From a fresh clone: `npm ci`, `npm run check` and `npm run build` all succeed.
G2. **Floors are sound.** For 200 seeds the Clinic generator gives a floor where every room is reachable from the elevator landing, there are at least two side branches, and two levels are joined by at least one stair. The same seed gives the same floor every time.
G3. **Rules hold.** In 500 simulated runs with wandering bot players, a Stillness entity never changes position on a tick when any player has it in view, and the instrument never gains a reading outside the recording rule.
G4. **The Orderly is a real figure.** A rigged `.glb` from a re-runnable Blender script, with at least idle, walk and reach animations, loads in the game, animates and casts a shadow. Fable has looked at the renders and an in-game screenshot. A fresh Opus critic, told nothing about it, has described what it sees and what looks wrong, and the worst problems are fixed.
G5. **Heard before seen.** A test shows the Orderly's sound is audible to a player before it first enters their view on a scripted approach.
G6. **One player can finish a run.** A Playwright script plays from elevator to reading to tape to elevator call to bank, with a screenshot at each beat and no console errors.
G7. **Four players share one world.** Four tabs in same-PC mode see each other move, see the Orderly in the same place, and agree on the floor. Two tabs also connect over the real peer-to-peer path on this PC.
G8. **Going down works.** A caught player goes down and gets the camera view within 5 seconds. All players down gives the wipe screen. A new run starts without reloading.
G9. **Three runs in a row.** The four-tab script completes three runs back to back without a reload or a console error.
G10. **The look.** Low internal resolution and the tape filter are on. Median frame time is under 16.7 ms on this PC with four players, measured in a GPU-backed test browser. If that cannot be measured, the gate is marked unverified, not passed. A fresh Opus critic, shown one in-game screenshot and told nothing, has said what it sees and what looks cheap, and the worst of it is fixed.
G11. **A shadow as a trigger.** In a quiet moment the pacing rule can fire one shadow-across-a-doorway event. It is never an entity, and a screenshot shows it.
G13. **The elevator speaks.** At least ten announcer lines, written and generated as `docs/VOICE.md` says, play at the right moments (boarding, arriving, calling the elevator, banking, someone going down, the wipe). Each has three takes and passes the file checks in that guide. `assets_src/voice/audition.html` lets the user pick the voice and takes by ear. The character ledger is under the cap.
G14. **Playable alone, and always live.** `?bots=3` on the live link gives one human a full crew of bots that walk, take readings, get caught and vote, and a whole run can be finished that way. `?debug=1` gives the test panel. The hub's `/play/` holds the newest green build, CI is green on `main`, and the gitleaks workflow has never failed.
G12. **Final validation.** A fresh Opus reviewer audits the code and the gates against this file and the fairness contract. Fable checks each finding and fixes the real ones. `loop/FINAL-REPORT.md` says what is verified, what is not, and how to play.

## Only if every gate is green with time left

S1. Voice that fades with distance, tested with Chromium's fake microphone.
S2. A second trait for the Orderly (Hearing, driven by microphone loudness) that re-rolls per run.
S3. The Tenant on the stairs.
S4. A second place: the Annex.

## Not in this end point

Friends connecting from other networks (needs a relay and a second network), skill tree, elevator deal cards, false sights, the incident report, the building's AI mind, paid assets. These come in later loops.
