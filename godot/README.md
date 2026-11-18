# Going Down on Godot

This folder is the game, in Godot 4.7: the rules, ported from `src/sim/*.ts` to typed GDScript and
proved to behave exactly like the TypeScript rules; the client that draws and plays them (copied in
from `spikes/godot-client`); the network (`net/`) and the home server (`server/`). It plays with no
TypeScript and no Node at run time. The Windows build is the main way to play; the browser build is
the backup. Alone or with friends the game runs the same way: the client talks to a host through the
network client. Alone, that host is a room inside the game (`net/local_room.gd`); with friends it is
the server.

```
godot/
  project.godot       Compatibility renderer (runs in a browser); untyped declarations are compile errors;
                      the client's main scene, display, rendering and audio settings
  export_presets.cfg  "Web", "Windows" (tests/, tools/ and export/ are left out of the builds) and
                      "Linux Server" (headless, feature "server": project.godot starts server/server.tscn)
  sim/                the rules, one file per src/sim module (rng, floor, clinic, walls, landing, move,
                      follow, sight, stamina, tape, entity, instrument, run, bot) plus jsmath.gd
  client/             main.gd (the game), play_link.gd (THE boundary: the only client script that talks
                      to the room), start_screen.gd (title, join form, lobby), others_view.gd (the other
                      players), plan_dump.gd, and the drawing scripts and shaders (level.gd, lift.gd,
                      sfx.gd, hud.gd, ...); rules_bridge.gd is no longer used by the game (ref_bridge only)
  net/                the network (port of src/net, see net/README.md): protocol, NetHost, NetClient,
                      transports, the room client, the local room (playing alone), the server's door;
                      host_rules.gd (src/game/runHost.ts HostRules) and pose.gd (lerpPose, samePose,
                      cameraSees), shared by the bridge, the local room and the server
  server/             the dedicated server (one room; server.tscn), its Dockerfile and README.md
  assets/, data/      models, textures, recorded lines, pixel font (synced; all from public/assets)
  main.tscn, default_bus_layout.tres   the main scene and the Voice, Entity, Scare, Effects, Ambience and UI buses (synced; see assets/sfx/MIX.md)
  tests/              run_tests.gd (the runner), ref_*.gd (sameness), prop_*.gd (design rules),
                      reference/*.json (written by the TypeScript rules), helpers
  tools/              godot.mjs (npm scripts); dump_reference.ts, property_counts.ts, bridge_script.ts and
                      rules_host.ts (write tests/reference); sync_client.mjs; the synced browser and
                      desktop checks (playthrough.mjs, play_web.mjs, play_desktop.mjs, sound_web.mjs,
                      measure_web.mjs, serve.mjs; careful.mjs: waiting for the car in a hide, as a
                      careful player does now that a catch alone is the wipe); the network checks (net_local.mjs, play_net.mjs); the
                      mix (mix_check.gd + mix_check.mjs, sfx_levels.gd)
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
npm run godot:export -- server           # the Linux headless server: export/server/GoingDownServer.x86_64
node godot/tools/net_local.mjs 4451      # the network end to end on this PC (server + 3 players + probes, ~2 min)
node godot/tools/play_net.mjs --port=4460  # two game windows and a browser on one server (see Playing together)
node godot/tools/godot.mjs import        # only the import pass (assets, the client's class names)
node godot/tools/sync_client.mjs         # copy the client in again from spikes/godot-client
node godot/tools/night_logs.mjs --ssh USER@HOST  # game night: fetch the server's log over ssh, save it, summarise it
node godot/tools/hotfix.mjs "the fix"    # game night: tests, export, playthroughs, promote, package, server; prints the deploy
node godot/tools/hotfix.mjs --dry-run "the fix"  # the same steps and deploy commands, nothing run
```

Game night's logs (server/README.md "The night's log"): every game keeps its own log in
`user://telemetry/` (the session, the last one, the last crashed one, F9 reports with a picture) and sends
a heartbeat, its error lines and F9 reports to the server, which prints them as JSON lines with its own
(joins, leaves, runs, catches, tick cost). F9 in the game sends a report ("Report sent, thank you").
`npm run godot:export` writes the build id (the commit) into the builds; the server refuses a game of
another build with "Your game is out of date".

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

The game opens on the start screen: PLAY ALONE (in the middle of the screen) starts a run in a room
inside the game; JOIN FRIENDS opens the form. Either first opens "draw your face" (`face/`): the editor
starts on this computer's last face, so a returning player presses Enter (or DONE) to keep it; CANCEL
keeps the last saved face (or none: the mask then shows the plain default face). The face is kept for
the session and sent in the join, only to the other players in the same run. JOIN FRIENDS then opens the form (the server's address, your name, the passphrase
for the night), then the lobby, which lists everyone in the room. Anyone can press START, and everyone
in the lobby goes down together; LEAVE goes back. Errors are said in plain words on the form (wrong
passphrase, room full, server not answering, an address that does not look right); BACK clears them.
The address and the name are remembered in `user://join.cfg` (not under automation); the passphrase
is kept in memory only, never written or printed. A bare address gets `ws://` on a home network
(localhost, 127.x, 10.x, 192.168.x, 172.16-31.x, a name with no dot) and `wss://` otherwise, e.g.
`wss://your-server.example`. After a run everyone is back in the lobby.

Controls: WASD or arrows walk, Shift sprints, Ctrl (or C) creeps, mouse looks (click to capture the
mouse, Esc frees it and shows the controls), E brings the instrument out and puts it away (the right
mouse button raises it while held), F calls the lift, holds the doors from inside the car and picks up
a dropped tape, R held opens the emote wheel (aim with the mouse, let go to send; a tap closes it), T
toggles the tape look. In a browser use C to creep: Ctrl+W closes the tab.

### Playing together

```sh
GD_JOIN_SECRET='the passphrase for tonight' godot/export/windows/GoingDown.exe --headless -- server port=4450
```

The Windows exe given `-- server ...` runs the dedicated server instead of the game (the arguments of
`server/server.tscn`, see `server/README.md`; the passphrase only in the environment). Each player
opens the game, presses JOIN FRIENDS and types the address, a name and the passphrase.

Other players are drawn as crewmates by `client/others_view.gd`: interpolated by the network client,
with their gait, the instrument raised, lying down while the host says they are caught, and skin,
headwear and chest number from their place in the room; their footsteps are heard. The clip plays at
the measured ground speed over the stride measured from the clip's planted toe, the body turns to
where it moves (backwards it walks backwards) with the chest and mask twisted back to the look, and
the creep is a shortened sneak (`client/crew_view.gd`; `tools/crew_check.gd` measures the foot slip).
A name tag over each, crisp over the tape with a dark outline, shows only up close (`main.gd`
TAG_RANGE, 2 m: further off you cannot tell who is who without asking or walking up) and is hidden by
walls, by the car's shut doors, in the dark and while the emote wheel is open. Emotes (WAVE, LOOK BEHIND, PRAY, DANCE SPIN, DANCE SNAKE, BUTTON: clockwise from
the top of the wheel, 60 degrees each) go to the host, which passes them on to everyone else (at most
one every 0.4 s per player); they play on your figure on their screens. Every crewmate's mask screen
shows the face that player drew (the host passes faces on once, `net/README.md` Faces), and the
monitor on the back wall inside the lift shows the whole crew's faces side by side, yours included.

A caught crewmate is out until the car next rides down (the run's rule). The soft catch of
`net/host_rules.gd` applies only when a catch would wipe the run, which is why playing alone you are
put back on your feet. The last stretch of every wait is the blackout, when the Orderly hunts unseen,
so with friends whoever is nearest it is usually taken there. The state comes from the host
(`status` "caught" in the snapshot): the downed-and-healed rules will change what the host says, and
the client already draws whatever it says.

Desktop arguments (after `--`) and URL parameters, besides the ones below: `join=<address>` and
`name=<text>` fill the form in; `pass=<text>` (with both) joins at once through the form's own Join.
**`pass=` is for local tests only**: it shows in the process list, the address bar and the browser
history. Never put a real passphrase there.

`npm run godot:export -- web` or `-- windows` builds one. URL parameters and desktop
arguments (`seed=`, `quality=`, `entity=0`, `auto=1`, `testport=`, `--bench=`) are the client's,
unchanged: see `spikes/godot-client/README.md`. After the web export `godot:export` runs
`node hub/precompress.mjs godot/export/web` (the hub serves the compressed copies only when they are
newer than the files).

Checks (start `powershell -NoProfile -ExecutionPolicy Bypass -File .local/guard-mouse.ps1 -Minutes 9 &`
beside any of them; the game never captures the mouse under `auto=1` or `navigator.webdriver`):

```sh
node godot/tools/play_web.mjs 4440         # browser playthrough, 29 checks, pictures in godot/export/shots/
node godot/tools/sound_web.mjs 4440        # browser sound after a real click, then each recording against the rules
                                           # (trolley only while it moves unseen, hum gone in the dark): must PASS;
                                           # with --query=&mute=1 must FAIL
node godot/tools/mix_check.mjs             # headless busy minute, every bus measured against the voice (GODOT set)
node godot/tools/play_desktop.mjs          # Windows build in a 960x540 window, 33 checks incl. bus peaks
node godot/tools/measure_web.mjs 4440      # sizes, cold first frame, frame times and the cost of playing alone
node godot/tools/play_net.mjs --port=4460  # multiplayer: 27 checks, pictures in godot/export/shots/net/
```

The playthroughs start with the start screen's PLAY ALONE and the face step (play_web clicks PLAY
ALONE and presses Enter; play_desktop sends `ui alone` then `draw done`, the editor's Enter;
measure_web sends `alone`, which does both). Under automation the face is saved to
`user://face/test_last_face.txt`, never over the player's own. Because the screen is drawn a little behind the host and the client keeps a
blink dark one tick past its end, "the lights come back as the car arrives" allows 0.3 s of host time
(measured: 0.15 s).

`play_net.mjs` starts the server from the Windows exe on 127.0.0.1 (the test passphrase
`test-passphrase` in its environment; ports 4460-4479 only: the server, three test channels just above
it and the web page) and two 640x360 game windows that join through the form (the `join=`, `name=`,
`pass=` arguments; the face step comes first). From both clients' own state it asserts: the face step
comes first and Enter keeps the face; a wrong passphrase gives the plain-words error, and Back returns
to the title; each player draws a different face (the editor's buttons and mouse drags); the lobby
lists both names; a browser client joins the same server
(skip with `--web=0`); Start starts the run for both; the lift's monitor shows both faces on both screens; each sees the
other where the other really stands, drawn, its name tag only up close, dressed differently, wearing the
face the other drew on the mask (the mask's picture hashed against the face the other sent), each
face received exactly once; nobody sees their own figure; the wheel
(WAVE aimed at the top, a tap sends nothing, DANCE SPIN straight down) and each emote seen by the
other; the call; the watched Orderly never moving on the watcher's screen while the other looks away
(not vacuous); a crewmate caught in the blackout is caught on both screens (their own plays the
catch, the other draws them lying where they were taken); everyone on their feet boards on BANK and
the host counts exactly those votes; the bank and the end screen for both; both back in the lobby.
It prints the bytes per second each client used (about 7.2 KB in and 2.0 KB out with two players).
With the server's seed `alpha` the blackout takes Bob every time; the checks hold whoever is taken.

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

## The bridge (no longer used by the game)

The game now plays through `client/play_link.gd` and the network client, alone too. The bridge is
kept, unchanged, because `tests/ref_bridge.gd` proves the GDScript rules against the reference host
through it. `client/rules_bridge.gd` keeps the public calls and reply shapes of the spike's bridge (`open`,
`start`, `step`, `teleport`, `walk_to`, `nudge`, `stop_walk`, `debug_info`, and `plan`, `state`,
`last_ms`, `mode` = `"gdscript"`), so the client scripts are used unchanged. It is a port of the
interim TypeScript host (`tools/rules_host.ts`, kept as the reference) and of the glue that host used
from outside `src/sim`: `HostRules` (src/game/runHost.ts: the start spot, the depth override, the
parked Orderly, the soft catch) in `host_rules.gd`; `lerpPose`, `samePose` (src/net/protocol.ts) and
`cameraSees` (src/net/session.ts) in `pose.gd`; the pose hold of src/net/client.ts `frame()` in the
bridge. Each frame it moves the body, runs the 20 Hz ticks that are due, decides which Orderly pose
this frame's camera may be shown, and returns one snapshot Dictionary with the TypeScript (camelCase)
names. Values are native (ints, floats, Strings), not JSON-parsed.

`tests/ref_bridge.gd` proves it is the same. (`host_rules.gd` and `pose.gd` now live in `net/`: the
server runs them too.) `tools/bridge_script.ts` plays three runs through the
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

## The network and the server

`net/` is the port of `src/net` (protocol, NetHost, NetClient, the in-memory test network) and
`server/` the dedicated home server that runs the host for one room; see `net/README.md` (the client
API for joining the real game to the network) and `server/README.md` (the passphrase, the limits,
Docker). Proved the same as the TypeScript by:

- `tests/ref_net.gd`: seven scripted sessions (`tools/net_script.ts`, `dump_reference.ts net`) run
  through the real `NetHost`/`NetClient` over the seeded in-memory network (two to four players;
  the Orderly watched and not at 0, 100 and 300 ms; jitter; a lossy link; a catch with the taken
  latch; blinks and the blackout; boarding, the vote, banking; riding down; joining mid-wait;
  leaving) and replayed here with the same LocalFrames: every message (length; the decoded message
  with time, sender and receiver, pay masked), every client frame, every host tick and every counter
  must match. Floats on the wire are written and read exactly as JavaScript does (`net/jsjson.gd`).
- `tests/prop_net.gd`: the fairness tests of `tests/net/rule.test.ts` with their oracle, on bot
  sessions over a lossy network (8 lossy and 2 zero-delay sessions of 60 s by default, 2 + 1 of 20 s
  in the quick set, 200 + 40 with `--full`), every count equal to TypeScript's (`properties.json`
  key `net`, written by `property_counts.ts`; `property_counts.ts --net-only` refreshes just those).

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

With the network tests (2026-11-16): ref_net adds about 55 s (6 s in the quick set) and prop_net
about 100 s (9 s quick).

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

Playing alone through the local room (16 Nov, the `stats` hook's `rules_ms_avg`: the whole of
`play_link.step`, host ticks included; standing in the clean corridor nearest the lift, as
measure_web does): the Windows build 0.82 ms a frame at 60 fps (host 0.32), 0.58 ms at 144 fps,
0.52 ms uncapped (274 fps), worst frame about 2.7 ms; the browser build 1.16 to 1.25 ms a frame at
60 fps (host 0.44 to 0.48), 0.73 to 0.77 ms uncapped (160 fps), worst frame about 6 ms. About twice
the bridge: every snapshot and input is written and read as exact JavaScript JSON (`net/jsjson.gd`)
even in memory, and the client runs the sight test for the hold every frame. The whole browser
playthrough averaged 1.34 ms (floor generation on the ride included). With a server the client's
cost on Windows was about 0.4 ms a frame.
