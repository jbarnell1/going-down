# Going Down on Godot

This folder is the game, in Godot 4.7: the rules, ported from `src/sim/*.ts` to typed GDScript and
proved to behave exactly like the TypeScript rules; the client that draws and plays them (copied in
from `spikes/godot-client`); and the bridge between the two, in GDScript. It plays with no TypeScript
and no Node at run time. The Windows build is the main way to play; the browser build is the backup.

```
godot/
  project.godot       Compatibility renderer (runs in a browser); untyped declarations are compile errors;
                      the client's main scene, display, rendering and audio settings
  export_presets.cfg  "Web" and "Windows" (tests/, tools/ and export/ are left out of the builds)
  sim/                the rules, one file per src/sim module (rng, floor, clinic, walls, landing, move,
                      follow, sight, stamina, tape, entity, instrument, run, bot) plus jsmath.gd
  client/             rules_bridge.gd (THE boundary: the only client script that calls sim/), host_rules.gd
                      (src/game/runHost.ts HostRules), pose.gd (src/net lerpPose, samePose, cameraSees),
                      and the client's scripts and shaders (main.gd, level.gd, lift.gd, sfx.gd, ...: synced)
  assets/, data/      models, textures, recorded lines, pixel font (synced; all from public/assets)
  main.tscn, default_bus_layout.tres   the main scene and the Sfx, Squeak and Voice buses (synced)
  tests/              run_tests.gd (the runner), ref_*.gd (sameness), prop_*.gd (design rules),
                      reference/*.json (written by the TypeScript rules), helpers
  tools/              godot.mjs (npm scripts); dump_reference.ts, property_counts.ts, bridge_script.ts and
                      rules_host.ts (write tests/reference); sync_client.mjs; the synced browser and
                      desktop checks (playthrough.mjs, play_web.mjs, play_desktop.mjs, sound_web.mjs,
                      measure_web.mjs, serve.mjs)
  export/             the builds and the playthroughs' pictures (ignored by git)
```

## Commands

Set `GODOT` to the engine (on Windows the console build, so output reaches the terminal). Without it
the npm scripts use `tools/godot/Godot_v4.7.2-stable_win64_console.exe` under the repository root.

```sh
npm run godot:test                       # everything, default sizes; exit code 0 only if all pass
npm run godot:test -- --quick            # the quick set, for every commit: about a minute, every test file
npm run godot:test -- ref_rng prop_clinic  # only these test files
npm run godot:test -- --full             # property tests at the Vitest sizes (slow: see Timing)
npm run godot:reference                  # regenerate tests/reference/ from src/ (needs Node; installs tsx here)
npm run godot:export                     # import, export export/web and export/windows/GoingDown.exe, precompress
node godot/tools/godot.mjs import        # only the import pass (assets, the client's class names)
node godot/tools/sync_client.mjs         # copy the client in again from spikes/godot-client
```

The runner itself, without npm:

```sh
"$GODOT" --headless --path godot --script res://tests/run_tests.gd [-- files... | --full | --quick]
```

Always run Godot headless commands under a timeout (the npm scripts do): a script that fails to
parse can leave a headless Godot process waiting forever. The runner prints one line per test and a
summary line `N passed, M failed in S s`. Any engine or script error raised while a test runs (a bad
call, a `push_error` from the rules) fails that test: GDScript has no exceptions, so the runner
counts errors through Godot's `Logger` API.

The tests need no import step: on a fresh clone (no `.godot/`) they run as they are, because they
only load `sim/`, `tests/` and the bridge's three scripts, which refer to each other with `preload`.
The game itself needs the import pass (models, textures, sounds, and the client's `class_name`s):
`npm run godot:export` runs it first, and `node godot/tools/godot.mjs import` runs it alone. The import
writes a `.uid` file beside each script that has none yet; commit them.

The quick set (`--quick`) runs every test file on the first seeds only: 40 floors instead of 800 for
the floor hashes and the clinic properties, 2 of the 30 bot crews, 4 of the 24 whole waits, all three
bridge runs, and smaller property runs whose counts are compared exactly with TypeScript's for the
same seeds (`properties.json` key `quick`, written by `property_counts.ts`). It skips the statistical
"not vacuous" and fairness shares, which need the default sizes. The default run is unchanged and
remains the full check.

When a rule changes in `src/sim`, change the GDScript the same way, run `npm run godot:reference`,
then `npm run godot:test`. The reference files are small enough to commit (about 7 MB; the bridge's is 2 MB).

## Playing it

```sh
npm run godot:export                                    # both builds (about 2 minutes, most of it compressing the wasm)
node godot/tools/serve.mjs godot/export/web 4440 &      # then open http://127.0.0.1:4440/ ; stop the server afterwards
godot/export/windows/GoingDown.exe                      # the main build: nothing else needed beside it
```

`npm run godot:export -- web` or `-- windows` builds one. Controls, URL parameters and desktop
arguments (`seed=`, `quality=`, `entity=0`, `auto=1`, `testport=`, `--bench=`) are the client's,
unchanged: see `spikes/godot-client/README.md`. After the web export `godot:export` runs
`node hub/precompress.mjs godot/export/web` (the hub serves the compressed copies only when they are
newer than the files).

Checks (start `powershell -NoProfile -ExecutionPolicy Bypass -File .local/guard-mouse.ps1 -Minutes 9 &`
beside any of them; the game never captures the mouse under `auto=1` or `navigator.webdriver`):

```sh
node godot/tools/play_web.mjs 4440         # browser playthrough, 29 checks, pictures in godot/export/shots/
node godot/tools/sound_web.mjs 4440        # browser sound after a real click: must PASS; with --query=&mute=1 must FAIL
node godot/tools/play_desktop.mjs          # Windows build in a 960x540 window, 33 checks incl. bus peaks
node godot/tools/measure_web.mjs 4440      # sizes, cold first frame, frame times
```

## The client, and re-syncing it

The client was first built in `spikes/godot-client/` (not in git) and copied here by
`node godot/tools/sync_client.mjs`. **From 16 November 2026 this folder is the only place the game is
edited**: change `client/`, `assets/` and `tools/` here, and do not run the sync again (it would
overwrite those changes with the old copy). The script is kept only as a record of how the copy was made. It copies `game/scripts/`
to `client/` (rewriting `res://scripts/` to `res://client/`), `game/assets/` to `assets/` (with the
`.import` files), `game/data/pixel_font.json`, `main.tscn`, `default_bus_layout.tres`, and the browser
and desktop checks from `tools/` (paths and default ports adjusted); it removes files the spike no
longer has and prints every file it added, updated or removed (`--check` only reports). It never
writes `client/rules_bridge.gd`, `client/host_rules.gd` or `client/pose.gd`. Project settings and
export presets are merged by hand; the script warns when the spike's `project.godot` or
`export_presets.cfg` change. After a sync: `npm run godot:export`, then the checks above.

Sound: the buses are declared in `default_bus_layout.tres` (`audio/buses/default_bus_layout`). Never
add buses at run time with `AudioServer.add_bus`: in the browser's Sample playback mode that
silences everything.

## The bridge

`client/rules_bridge.gd` keeps the public calls and reply shapes of the spike's bridge (`open`,
`start`, `step`, `teleport`, `walk_to`, `nudge`, `stop_walk`, `debug_info`, and `plan`, `state`,
`last_ms`, `mode` = `"gdscript"`), so the client scripts are used unchanged. It is a port of the
interim TypeScript host (`tools/rules_host.ts`, kept as the reference) and of the glue that host used
from outside `src/sim`: `HostRules` (src/game/runHost.ts: the start spot, the depth override, the
parked Orderly, the soft catch) in `host_rules.gd`; `lerpPose`, `samePose` (src/net/protocol.ts) and
`cameraSees` (src/net/session.ts) in `pose.gd`; the pose hold of src/net/client.ts `frame()` in the
bridge. Each frame it moves the body, runs the 20 Hz ticks that are due, decides which Orderly pose
this frame's camera may be shown, and returns one snapshot Dictionary with the TypeScript (camelCase)
names. Values are native (ints, floats, Strings), not JSON-parsed.

`tests/ref_bridge.gd` proves it is the same. `tools/bridge_script.ts` plays three runs through the
reference host (7833 requests): stepping out (walk, sprint, creep, strafe), both levels and the stair,
recording near the Orderly while watching it and while looking away (the slip), a reading closing,
the call, blinks, a soft catch in the blackout, the dropped tape picked up, boarding, holding the
doors, the vote and banking; a second run with the Orderly parked that rides down to floor 2 and uses
the test hooks there; a third started at depth 2. `dump_reference.ts bridge` records every request
and reply (`tests/reference/bridge.json`); the test replays the requests through the GDScript bridge
and compares every reply's canonical digest with the pay fields masked (everything else exact), every
event, every plan field by field, the full reply every 20 requests, and every reply's pay values
within 1e-9. The script makes its choices from the TypeScript replies; only the requests are
replayed, so the script itself is never ported.

## How the sameness is proved

`tools/dump_reference.ts` imports the real `src/sim` modules and records: RNG sequences and forks
(50 seeds); 40 complete floor plans field by field and the plan hash of the 800 floors the property
tests use; every wall edge, every collision segment, seeded random walks, stair jitter, path
following and moving through the car door on five floors; 6000 sight queries asked seven ways;
the Orderly tick by tick in 14 scripted scenes; stamina traces, the rate curve and three instrument
scenes with the pay the game shows; 200 call plans with their blinks and blackouts; a whole scripted
run to the bank; vote, hold, left-behind, wipe and repeated-call scenes; 24 whole waits with wait
bots; and 30 bot crews for 90 s each; and (job `bridge`) every reply of the reference host on the three scripted runs of `bridge_script.ts` (see The bridge). Long traces carry a digest (MD5 of a canonical JSON text,
floats as their bits) of the complete state after every tick, the complete state every so often,
and every event. The `tests/ref_*.gd` files run the same scenarios in GDScript and compare.

`tools/property_counts.ts` copies the property-test loops and oracles from `tests/sim` and writes
their counts for the full Vitest sizes (which match what Vitest prints) and for the shorter default
runs here. The `tests/prop_*.gd` files port the same loops with their own oracles and must produce
the same counts, besides asserting the design rules themselves.

## Rules for writing rules here (what makes the GDScript match JavaScript)

- **Use `sim/jsmath.gd` for maths.** `sin_js cos_js tan_js atan_js atan2_js exp_js` are V8's
  fdlibm routines ported line for line; Godot's built-ins differ from V8's in the last bit for a few
  percent of inputs. `hypot2`/`hypot3` are V8's `Math.hypot` (it scales and compensates, so it is not
  `sqrt(x*x + y*y)`). `imul`, `to_int32`, `to_uint32` do JavaScript's 32-bit integer operators.
  `+ - * /`, `sqrt`, `floor`, `ceil`, `fmod`, `minf`, `maxf`, `absf` are exact and may be used as is.
- **Never use `Vector2`, `Vector3` or `Rect2` for rule values**: they are 32-bit floats. (`Vector2i`
  and `Rect2i` are fine for small integers.)
- **Float literals**: GDScript's parser reads some decimal literals as the wrong double (measured: 886
  of 3011 shortest-form literals, 269 of 6011 literals of up to 15 digits). Short tuning constants
  like `0.35` are read correctly, and `tests/test_jsmath.gd` checks every float literal in `sim/`
  against JavaScript's reading (the list is regenerated by `npm run godot:reference`). Long constants
  are built from their bits (see `jsmath.gd`'s `_static_init`). Godot's JSON parser has the same
  problem, so the reference files carry floats as `"~"` + 16 hex digits.
- **`pow` cannot be matched.** JavaScript's `**` and `Math.pow` call the platform's C library pow
  (on this machine it is neither fdlibm nor correctly rounded), so `k ** 3` in `rateAt` gives
  last-bit differences that no GDScript code can reproduce, and differs between operating systems
  even in TypeScript. The port uses fdlibm's pow (`jsmath.pow_js`). Only pay values are affected
  (the instrument's reading values, rate, ticking, tape totals); the tests mask those fields in the
  per-tick digest and compare them within 1e-9 instead. The fix belongs in TypeScript: write
  `k * k * k` (and repeated multiplication for `DEPTH_PAY_STEP ** n`), then make `rate_at` and
  `depth_multiplier` here do the same, and the masking can go.
- **Integer division**: `a / b` with two ints truncates in GDScript; JavaScript always divides as
  floats. Write `floorf(k / 2.0)` or `k / 2` only where the TypeScript has `Math.floor` of
  non-negative integers.
- **No `class_name`.** Scripts refer to each other with `const X = preload("res://sim/x.gd")` and
  inner classes (`Floor.Pos`, `Entity.OrderlyState`). A new `class_name` stays invisible to headless
  `--script` runs until an `--import` pass, so a fresh clone would fail to compile.
- Sorting: GDScript's `sort_custom` is not stable; JavaScript's sort is. Only sort where ties
  cannot happen, or write a stable sort.

## The data, for the next agent (drawing, then the home server)

- Names: TypeScript field and function names in snake_case (`entityStart` -> `entity_start`,
  `stepEntity` -> `step_entity`, `int` -> `int_in`, `trait` -> `trait_name`); the comments say so
  where they differ. String enums are `StringName`s with the TypeScript spellings (`&"corridor"`,
  `&"windUp"`, `&"boarding"`).
- State objects are small classes with typed fields (`Floor.FloorPlan`, `Move.Body`,
  `Entity.OrderlyState`, `Instr.CrewState`, `Run.RunState`, `Bot.Bot`, ...). They are treated as
  immutable, as in TypeScript: a step makes a shallow `copy()` and replaces fields, never edits a
  state or `Body` it was given, so old states can be kept (for interpolation, replays, rollback).
- `TypeScript null` is `null` in `Variant`-typed fields (`last_seen_at`, `target_id`, `call`,
  `blink.ends_at`); a missing path is an empty array; `RunState.last_floors` is `-1`;
  `Landing.elevator_wall` returns `&""`. `PlayerInput.raised` and `pick_up` are `null` for
  "not given" (TypeScript `undefined`).
- Events are `Dictionary`s with exactly the TypeScript keys (`{"type": "caught", "t": ..., "playerId": ...}`),
  carrying `Move.Body`, `TapeLib.Reading` and `Run.RunSummary` objects where TypeScript carries those
  objects; `tests/snap.gd` turns them into plain data. A network layer can send the same shapes.
- A floor plan caches its lookup tables on itself (`_index`, `_adjacency`, `_edges`, ...): build it
  once with `Clinic.generate_clinic(seed, depth)` and share it; `FloorPlan.copy()` starts fresh caches.
- Cells: `plan.cells[level][y * width + x]`; cell (x, y) covers world x in [2x, 2x+2), z in [2y, 2y+2);
  level 1's floor is at y = 3.2. Walls come from `Walls.west_edge` / `north_edge` (what stops you
  is what is drawn). Sight is `Sight.can_see` and `has_line_of_sight`. The car is `Run.car_geometry`.
- `jsmath.gd` keeps one shared scratch buffer, so the rules are not safe to run on two threads at once.

## Timing

Measured on the development PC (2026-11-16): the default suite runs 34 tests in about 395 to 450 s
(`npx vitest run tests/sim`: about 51 s, 61 s wall); the quick set (`--quick`) in about 68 s. The slowest parts are the 30 bot crews
(160 s, most of it hashing every tick's state), the 800 floor hashes (55 s) and the blackout
tables (90 s). `--full` runs the property tests at the Vitest sizes (500 Orderly runs, 1800 waits,
...) and takes about an hour. GDScript runs these rules roughly 15 to 30 times slower than
TypeScript under V8; generating one floor takes about 35 ms.

The default property runs use the first seeds of the Vitest sequences (24 Orderly and instrument
runs, 24 staring calls, 16 car-safety runs, 16 hearing seeds, 20 waits per blackout table cell);
their counts are compared exactly with TypeScript's for the same seeds.

The bridge, natively (ref_bridge): about 0.45 ms a frame on average, at most about 3 ms on an
ordinary frame; the frame on which a ride ends costs about 60 ms (generating the next floor, about
35 ms, and its plan dump), while the doors are shut. In the browser build the client's `stats`
hook reported 0.48 to 0.59 ms a frame on average (the Windows build: 0.28 to 0.38 ms).
