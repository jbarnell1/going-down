# The Godot tests and their goldens

The tests check the rules in `godot/sim/` and the network in `godot/net/` two ways:

- **Sameness tests** (`ref_*.gd`, `test_jsmath.gd`) replay scripted scenarios and compare everything
  they produce, tick by tick and message by message, with the **goldens**: the results recorded
  earlier from this same GDScript code, in `tests/golden/*.json`. Every comparison is exact: every
  number (pay included), string, flag and event. A difference means the behaviour changed.
- **Design-rule tests** (`prop_*.gd`) run many seeded games and assert the rules of the design (the
  Orderly never moves while watched, looking saves you, the car is safe, the network never shows it
  moving, ...). They also count what happened, and those counts must equal the golden counts for
  the same seeds (`tests/golden/properties.json`), so a change that keeps the rules but changes how
  often things happen is noticed too.

Some design-rule files check only their rules and keep no counts: `prop_prison`, `prop_notes`,
`prop_marks`, `prop_upgrades`, `prop_report`, `prop_day`, `prop_save` and `prop_face_net` (pure rules
over seeded inputs, compared with oracles written in the test). `prop_annex` keeps one golden, every
Annex floor's plan hash (`tests/golden/annex.json`, 800 floors; the quick set compares its 40). Each of
these files also has a standalone runner (`tests/run_<name>.gd`) that runs it alone. `prop_downs` (down
first, then out: 200 seeded bot runs against an oracle, the Playroom's down from health, and three clients
on lossy links) keeps no counts either; run it alone with `npm run godot:test -- prop_downs`.
`prop_down_view` checks what the screen says for the host's downs block (client/down_view.gd: the timer,
the help prompt and its bar, the out screen) against the test's own reading of B6; the same on screen,
with two real game windows over the network, is `node godot/tools/play_down.mjs`.

The scenario inputs that are data rather than code (the bridge's requests, the network scripts, the
maths samples, the literal table) are in `tests/inputs/` and never change when goldens are recorded.

The test run needs Godot only: no Node, no TypeScript, no `src/`.

```sh
npm run godot:test -- --quick            # the quick set (every commit; the pre-commit hook runs it)
npm run godot:test                       # the default run: the full check
npm run godot:test -- ref_run prop_net   # only these files
npm run godot:test -- --full             # property tests at their full sizes (slow; needs the full goldens)
npm run godot:golden                     # RECORD the goldens (never part of a test run)
npm run godot:golden -- ref_run prop_blackout   # record only these test files
npm run godot:golden -- --full           # record only the full-size property counts (slow)
```

Without npm, `"$GODOT" --headless --path godot --script res://tests/run_tests.gd -- [args]` (always
under a timeout).

## Sizes

| run | ref_* / test_jsmath | prop_* | golden key in properties.json |
| --- | --- | --- | --- |
| `--quick` | the first seeds only, a few long scenes skipped | small runs | `quick`, `clinicQuick` |
| default | everything | default runs | `sub`, `clinic` |
| `--full` | everything | the full sizes | `full` |

`npm run godot:golden` records the ref_* files at the default size (the quick set reads a subset
of the same records) and the prop_* counts at the quick and default sizes. The full-size counts are
recorded only by `npm run godot:golden -- --full`, on purpose, because it takes hours; its summary
says which sizes it wrote.

## Changing a rule

1. Change the rule in `godot/sim/` (or `godot/net/`).
2. Run the tests: `npm run godot:test`. The tests whose behaviour changed fail, and each failure says
   what differs from the golden: the scene, the first tick whose state differs (and whether only in
   the pay), the first different event, the first different message, or which counts changed.
3. Read why. A design-rule failure (a `prop_*` assertion that is not "the counts") means the change
   breaks the design: fix the change, not the test. A sameness failure is expected where the rule
   change should have an effect; check that it fails only where you expected.
4. Record the goldens for the affected test files: `npm run godot:golden -- ref_run prop_run`
   (or `npm run godot:golden` for all of them).
5. Read the summary it prints: for every golden file, which scenarios changed and how (the first
   differing tick, event or message in each, which counts changed and by how much) and which did not.
   Anything changed that you did not expect is a bug.
6. Run the tests again (they pass now), and commit the goldens together with the rule change, so the
   commit shows what the change did. If the change affects the full-size counts, also run
   `npm run godot:golden -- --full` (slow) and commit that, or say in the commit that the full-size
   goldens are stale.

Recording refuses to write anything if a test raises an engine or script error. A design-rule
failure while recording is printed (`FAIL (rule)`) and the goldens are still written, but the
command exits with an error.

## Scenes added after the switch

The goldens may hold scenarios the TypeScript reference never had; they are recorded and compared
like the rest:

- `ref_entity` scene `edge-of-view`: the player keeps the hunting Orderly near the edge of the view
  cone, so a wider or narrower cone changes when it may move (the other scenes stare dead on or turn
  fully away). Doubling the cone's width in `sight.gd` turns it red in the quick and default runs.
- `ref_net.four_bank_opening` (every run): the first 12 s of the four-player `four-bank` scene,
  compared with the beginning of that scene's golden record. It is how the quick set sees changes
  to what the host does with the clients' reports of what they see.
- `prop_net.host_*` (every run): the host driven by hand-made inputs (ported from
  `tests/net/host.test.ts`): put-backs, the bound, the Orderly held while a client says it sees it,
  catches that wait for the victim's screen, a seen report cancelling a wind-up, policing bodies.

## Where the goldens came from

The first goldens were recorded from the GDScript port when it had just been proved the same as the
TypeScript game (`src/sim`, `src/net`). `node godot/tools/check_goldens_against_typescript.mjs` shows
that they agree with the TypeScript reference (`npm run godot:reference`, the historical dumpers in
`godot/tools/`): every value is identical except values derived from the instrument's pay, which
differ by less than 1e-9 because JavaScript's `**` uses the platform's `pow` (see `godot/README.md`).
That check only makes sense while no rule has changed since; after the first deliberate rule change
it is expected to fail and is retired with `src/`.

## Files

```
run_tests.gd        the runner (--quick, --full, --golden, file names)
t.gd                what a test gets: check, eq, expect (record or compare a golden), notes
golden.gd           reading and writing tests/golden/ and tests/inputs/ (floats as "~" + 16 hex digits)
trace.gd            a scene tick by tick: state digests, events, full states every N ticks
snap.gd             rule objects to plain data, digests, exact comparison
golden/             the expected results (written only by npm run godot:golden); annex.json holds the
                    Annex plan hashes (prop_annex)
inputs/             the scenario inputs (never rewritten)
```
