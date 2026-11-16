# Progress

## Status (read this first)

- **Hub:** live on the owner's tailnet (address in `.local/MACHINE.md`). The home page, Play and Questions all answered 200 when requested from a second tailnet device, and the owner's home dashboard links to it. To check reachability, always test from another device, never from this PC.
- **Started:** 2026-11-16T03:38Z (2026-11-15 21:38 Central). The 30-hour limit is 2026-11-17T09:38Z.
- **Iterations so far:** 3
- **Now working on:** T2a, walking through a generated Clinic floor (an Opus agent is building it; Fable verifies when it reports)
- **What you can play:** nothing yet. The hub's Play link shows a placeholder corridor with some crates, which only proves the pipeline from seed to pixels.
- **How to run it:** `npm ci`, then `npm run dev`. Checks: `npm run check` and `npm run e2e`.
- **Last fully green build:** tag `good-1`
- **Unverified:** CI's first full run (pushed, result not yet seen).
- **Answers applied up to:** none yet (no answers file existed at iteration 1)
- **Last CI result seen:** `ci` and gitleaks both passed on 1cdff32. (`ci` had failed once on 3189f41: the browser test could not find the preview server on Linux; fixed by binding it to 127.0.0.1.)

## Tasks

Status is one of `todo`, `doing`, `done`, `blocked`. A task is `done` only with evidence on the line below it.

- [x] T0 `done` Project setup. Evidence: `npm run check` exit 0 (typecheck clean, 7 rule tests passed, build 523 kB); `npm run e2e` 1 passed, reporting `gpu=ANGLE (NVIDIA GeForce RTX 4070 SUPER, Direct3D11)`, so the test browser does use the graphics card and G10 can be measured here; screenshot `test-results/shots/00-boot.png` opened and looked at (low-resolution corridor with crates, hard pixels, no errors). Hooks live in `scripts/hooks` (secret scan, then `npm run check`). Vite is pinned to 6 and Vitest to 3 because this PC's Node 20.12 cannot run Vite 8. Original task text:
  Project setup: git init, Vite + TypeScript + three.js + Vitest + Playwright, the folder shape in LOOP.md, `npm run check` and `npm run e2e` both run, one screenshot of an empty scene opened and looked at. A git pre-commit hook that runs `npm run check`, so a broken build cannot be committed. Find out whether the test browser can use the graphics card. Also in T0: install the pre-commit hook so it runs `node hub/scan-secrets.mjs` first; write `.github/workflows/ci.yml` (see LOOP.md); add `npm run deploy:live` (build, copy `dist/` to `.live/`, write `.live/version.json` with commit, time and a one-line note) and deploy the first build so the hub's Play link works.
- [x] T1 `done` `src/sim`: seeded RNG and the Clinic floor generator. Evidence: Fable re-ran `npm run check`: 29 tests passed, build ok, exit 0. The floor tests run over 200 seeds at each of depths 1 to 4 (800 floors) and cover every G2 point plus loops, sight lines and the entity start. `src/sim` has no Math.random, Date, DOM or three.js. Fable read the printed map `test-results/floors/alpha-d1.txt`: a 2-wide corridor ring with a cross hall, a lobby with the elevator, an atrium open to the upper gallery, wards, exam rooms and one stair; it reads as a building. Built by one Opus agent (about 19 minutes, about 206k tokens).
- [ ] T1b `todo` (after the slice's gates, before a second place) More than one skeleton for the Clinic. Every floor is currently the same ring, cross hall, atrium and stair band with sizes, mirroring and room mix varied. That passes G2 but will feel samey by the third floor.
- [ ] T2a `doing` First-person walking through a generated Clinic floor: continuous movement and collision as pure, tested logic in `src/sim`; the floor plan turned into meshes (floors, walls with door gaps, ceilings, stair, balcony rail); bright Clinic materials and light; pointer-lock controls; test hooks and URL flags; a Playwright walk from the elevator up the stair to the balcony with screenshots.
- [ ] T2b `todo` The tape-playback look as a post-process on a low-resolution target, the `?debug=1` overlay with a minimap, and frame-time statistics exposed for tests.
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

G1 [ ]  G2 [x] (T1 evidence)  G3 [ ]  G4 [ ]  G5 [ ]  G6 [ ]  G7 [ ]  G8 [ ]  G9 [ ]  G10 [ ]  G11 [ ]  G12 [ ]  G13 [ ]  G14 [ ]

## Decisions taken on defaults

(The loop adds a line here every time it would otherwise have had to ask you something.)

- Tool versions: pinned Vite 6 and Vitest 3 to suit the Node already on this PC, not upgrading Node, because installing a new Node is outside the project folder.
- Repository licence: none yet (question `license` on the hub).
- North Star document: kept out of the public repository (question `publish-design-doc`).

## Blocked

(nothing)

## Log

- 2026-11-15 22:20 iteration 3: T1 accepted after Fable's own run of the checks and a read of the printed map. G2 ticked. Noted the agent's own caveat as T1b: one skeleton for every floor. T2 split in two so the walk can be seen before the tape look goes on top. T2a handed to one Opus agent.

- 2026-11-15 22:00 iteration 2: CI's first run had failed, so that came first: fixed and pushed (1cdff32). T1 handed to one Opus agent with a written interface for the floor plan. At the owner's request a tile for the hub was added to their home dashboard; it points at the tailnet port the hub will have once the owner moves it.

- 2026-11-15 21:45 iteration 1: T0 done by Fable inline. One wrong test fixed, not weakened: the first colour check copied the WebGL canvas after the frame had been presented, which always reads blank; it now reads pixels from the GPU straight after a draw. Keep-awake is on while the session stays active.

- 2026-11-15: public repository created and first commit pushed. Hub built and smoke-tested (pages load, answers save, path-escape attempts return 404), started on localhost, and registered to start at logon. Adding it to Tailscale serve failed: it needs an administrator, so that step is left to the owner. Secret scan runs before every commit and gitleaks runs on every push.

- 2026-11-15: Orderly first pass by one Opus agent (about 14 minutes, 73 tool calls, about 170k tokens). Fable read the `.glb` directly: 1 mesh, 2,546 triangles, 24 joints, 1 texture, animations idle 3.5 s, walk 1.0 s, reach 1.5 s, still. Fable looked at four renders: a real rigged figure, pipeline proven, not yet scary. Blender 5.3 API notes for the next script: engine id is `BLENDER_EEVEE`; `Action.fcurves` is gone, use `action.layers[].strips[].channelbags[].fcurves`; export with `export_animation_mode='ACTIONS'`; constant interpolation exports as glTF STEP; imports add a stray "Icosphere" object.

- 2026-11-15: loop files written. `docs/north-star.html` is a copy of the published North Star (draft 4.1). The winget install of Blender stopped at an administrator prompt, so the portable Blender 5.3.0 from blender.org goes in `tools/blender/` instead (checksum verified, not in git).
