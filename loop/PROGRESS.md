# Progress

## Status (read this first)

- **Needs the owner (once):** the hub runs on this PC's localhost but is not on the tailnet yet, because changing Tailscale serve needs an administrator. The exact command is in `.local/MACHINE.md`. Until it is run, the live link only opens on this PC itself.
- **Started:** not started. The first iteration writes the start time here.
- **Iterations so far:** 0
- **Now working on:** nothing yet
- **What you can play:** nothing yet
- **Last fully green build:** none
- **Unverified:** everything
- **Answers applied up to:** none yet
- **Last CI result seen:** none yet

## Tasks

Status is one of `todo`, `doing`, `done`, `blocked`. A task is `done` only with evidence on the line below it.

- [ ] T0 `todo` Project setup: git init, Vite + TypeScript + three.js + Vitest + Playwright, the folder shape in LOOP.md, `npm run check` and `npm run e2e` both run, one screenshot of an empty scene opened and looked at. A git pre-commit hook that runs `npm run check`, so a broken build cannot be committed. Find out whether the test browser can use the graphics card. Also in T0: install the pre-commit hook so it runs `node hub/scan-secrets.mjs` first; write `.github/workflows/ci.yml` (see LOOP.md); add `npm run deploy:live` (build, copy `dist/` to `.live/`, write `.live/version.json` with commit, time and a one-line note) and deploy the first build so the hub's Play link works.
- [ ] T1 `todo` `src/sim`: seeded RNG and the Clinic floor generator (rooms, corridors, two levels, a stair, an atrium), with the G2 tests.
- [ ] T2 `todo` First-person walking through a generated Clinic floor: bright lighting, collision, stairs, the tape-playback look, the URL test flags. Screenshot.
- [ ] T3 `doing` The Orderly in Blender (Opus). First pass exists (see log): `assets_src/blender/orderly/build_orderly.py`, `public/assets/entities/orderly.glb`, renders in `assets_src/renders/orderly/`. Still to do: a second pass that fixes the list below, then a blind Opus critic and one more round of fixes. Check the user's own notes on it first, if any are recorded here.
  - Reads as a shop mannequin from the front. Needs a body: elbows, wrists, collarbones, a ribcage under the gown, a visible spine curve.
  - Boxy shoulder-pad sleeves. Slope the shoulders and let the gown hang off one.
  - At 480x270 the head is about 12 px and the smile is a smudge. Bigger print, higher contrast, and a dark band where the eyes should be.
  - The walk has no weight. Add a small sway and a head that stays eerily level.
  - It is odd but not yet frightening in bright light. Try a larger scale against door frames, a head tilted to one side, and hands that twitch in idle.
  - Not yet loaded in three.js. The reach stretches a bone by scale; confirm it looks right in the engine.
- [ ] T4 `todo` Entity runtime: load the figure, play animations, the Stillness rule decided in favour of the player, the host tick, the trolley squeak placed in 3D. G3 and G5 tests.
- [ ] T5 `todo` The instrument, the recording rule, the printed slip, the tape you carry.
- [ ] T6 `todo` The elevator: start of run, calling it and the loud wait, bank or ride, the next floor from seed + depth, end-of-run screen. G6 script.
- [ ] T6b `todo` The elevator voice per `docs/VOICE.md`: shortlist three voices, write the first ten lines with directions, generate three takes each within the cap, build the audition page, wire the lines to their moments with the degrading-speaker effect. G13.
- [ ] T7 `todo` The network layer with both backends, host authority, simple 3D crew figures, the four-tab test. G7.
- [ ] T7b `todo` Bot crewmates (`?bots=N`) driven by the sim, and the `?debug=1` test panel, both working on the live build. A Playwright run finishes a whole run with one human-driven player and three bots. G14.
- [ ] T8 `todo` Caught, down, cameras, wipe, new run without reload. G8 and G9.
- [ ] T9 `todo` The shadow trigger and the quiet-moment pacing rule. G11.
- [ ] T10 `todo` Frame-time measurement and fixes. G10.
- [ ] T11 `todo` Final validation and report. G1 from a fresh clone, G12.
- [ ] S1 to S4 `todo` Stretch items from ENDPOINT.md, in order, only when T0 to T11 are done.

## Gates

G1 [ ]  G2 [ ]  G3 [ ]  G4 [ ]  G5 [ ]  G6 [ ]  G7 [ ]  G8 [ ]  G9 [ ]  G10 [ ]  G11 [ ]  G12 [ ]  G13 [ ]  G14 [ ]

## Decisions taken on defaults

(The loop adds a line here every time it would otherwise have had to ask you something.)

## Blocked

(nothing)

## Log

- 2026-11-15: public repository created and first commit pushed. Hub built and smoke-tested (pages load, answers save, path-escape attempts return 404), started on localhost, and registered to start at logon. Adding it to Tailscale serve failed: it needs an administrator, so that step is left to the owner. Secret scan runs before every commit and gitleaks runs on every push.

- 2026-11-15: Orderly first pass by one Opus agent (about 14 minutes, 73 tool calls, about 170k tokens). Fable read the `.glb` directly: 1 mesh, 2,546 triangles, 24 joints, 1 texture, animations idle 3.5 s, walk 1.0 s, reach 1.5 s, still. Fable looked at four renders: a real rigged figure, pipeline proven, not yet scary. Blender 5.3 API notes for the next script: engine id is `BLENDER_EEVEE`; `Action.fcurves` is gone, use `action.layers[].strips[].channelbags[].fcurves`; export with `export_animation_mode='ACTIONS'`; constant interpolation exports as glTF STEP; imports add a stray "Icosphere" object.

- 2026-11-15: loop files written. `docs/north-star.html` is a copy of the published North Star (draft 4.1). The winget install of Blender stopped at an administrator prompt, so the portable Blender 5.3.0 from blender.org goes in `tools/blender/` instead (checksum verified, not in git).
