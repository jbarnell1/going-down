# The Annex generator

`sim/annex.gd` builds the Annex, the second place: an endless yellow office where rooms repeat and
corridors loop back on themselves. It produces the same `Floor.FloorPlan` as the Clinic (2 m cells,
two levels, rooms, doors, stairs, a landing, an entity start, sightlines), with `plan.place = &"annex"`.
It is not wired into the run yet: the place deck is a later task, and nothing calls it but its tests
and its tool.

```gdscript
const Annex = preload("res://sim/annex.gd")
var plan := Annex.generate_annex("seed-0", 1)   # Floor.FloorPlan, place &"annex"
Annex.annex_size(depth)                          # Vector2i: the Clinic's size (36 at depth 1, up to 44)
Annex.render_ascii(plan, level)                  # a text map (Floor.render_ascii knows only the Clinic's room kinds)
```

## What it builds

Canonical orientation first, then one of the grid's eight symmetries (seeded), as the Clinic does.

- **Lattice.** One-cell corridors every 7 cells, 6 by 6 blocks between them: 4 blocks a side below
  42 cells (a 29-cell lattice), 5 from 42 (36 cells). It sits against the north margin, seeded across.
  The south line is the spine.
- **Stairs.** Two, three from depth 4, one block each, at least two blocks apart (no two in
  neighbouring blocks, diagonals included). The stair is 4 cells long and climbs from the block's
  front edge; its foot is on the front corridor (level 0), and a two-cell corridor stub on level 1
  joins its head to the back corridor. The stair never uses the block's middle two columns.
- **Atrium.** One block, two from depth 4: an open room with a door on every corridor side on level 0,
  an opening with a balcony of corridor round it on level 1.
- **Lobby.** 5 by 3 off the spine with a door at each end; the landing is the middle cell of the
  outer row. Reserved and kept void on both levels: the cell above the landing (the shaft), and a car
  zone of **3 cells along the outer wall, centred on the landing, by 2 cells beyond it** (6 by 4 m).
  Today's car is one 2 m cell beyond the elevator wall (`run.gd` `CAR_WIDTH`, `CAR_DEPTH`); the planned
  4 m car fits the zone centred on the doors. Nothing is ever built south of the spine but the lobby.
- **Pruning.** On each level separately, segments are taken out in a seeded order until a quarter are
  gone (10 of 40, or 15 of 60). A segment stays if taking it out would split the corridors or make any
  segment a bridge (Tarjan's bridge search), leave a block with corridor on fewer than two sides, or if
  it is protected: the whole spine on level 0, each stair's foot segment (level 0) and head segment
  (level 1), and the four segments round each atrium on level 1. Every corridor is on a loop; there
  are no corridor dead ends. The four corner junctions can never be pruned (they have two segments).
- **Templates.** Every other block is stamped from a fixed 6 by 6 arrangement turned to face its
  front, the first of south, north, east, west (canonical) that still has corridor: offices (four 3 by 3,
  the back two through the front two when the back has no corridor), cubicles (one walk-through room,
  a door on every corridor side), meeting (6 by 4, two front doors, two 3 by 2 closets behind),
  copy suite (6 by 2 copy room, one door, two 3 by 4 stores behind: the side branch), break room (4 by
  6, front door and a back door if the back has corridor, a 2 by 6 closet). Door positions are fixed in
  each template, so blocks of the same template facing the same way are identical. The seed picks
  three templates, the copy suite always one; block (c, r) gets number (c + 2r + offset) mod 3, with the
  copy suite on the number that has the most free blocks (see "Decisions"). Level 1 uses cubicles and
  meeting, (c + 2r + offset) mod 2, in a seeded order while a budget of 80 rooms for the floor lasts;
  blocks past the budget stay solid (this happens with five blocks a side, where level 0 alone can hold
  about 70 rooms).
- **Entity start.** The Clinic's rule (`clinic.gd` `_choose_entity_start`): an end of a straight
  corridor of 8 or more cells, at least 12 steps from the landing, among the farthest.
- **Room kinds:** `office`, `cubicles`, `meeting`, `copy`, `store`, `break`, `closet`, `lobby`, `atrium`.

**Seed.** `Rng.make_rng("annex:<seed>:<depth>")`, a named fork per stage: `shape` (lattice position,
lobby), `stairs` (stair and atrium blocks, stair facing and column), `prune0`, `prune1`, `templates`
(the three templates, both offsets, the level-1 order), `orient`, `entity`. Whole numbers only (the
floats are inside `Rng` and the Clinic's entity rule), no engine randomness, no sorts.

**Reused from `clinic.gd`, by preload, unchanged:** the builder (`_new_builder`, `_set_cell`,
`_carve`, `_add_room`, `_add_door`), `_shuffled`, `_symmetry_count`, `_transform`, `_choose_entity_start`,
`clinic_size`. From `floor.gd`: `side_branches`, `find_sightlines`, `distances_from` (inside the entity
rule), `hash_plan`. **Not reusable, so repeated in `annex.gd`:** the lobby and the side-branch marking
(written inline in `clinic.gd`'s `_lay_out` and `generate_clinic`, not as functions), and the text map
(`Floor.render_ascii` looks up a fixed table of the Clinic's room kinds and would fail on the new
ones). Neither `clinic.gd` nor `floor.gd` was edited (`FloorPlan.place` already existed), so the
Clinic's proof is untouched; if a reused Clinic helper changes, the stored Annex hashes go red.

## Commands

All headless, under a timeout, from the repository root (`$GODOT` is the console build).

```sh
"$GODOT" --headless --path godot --script res://tests/run_annex.gd              # the eight properties, 800 floors
"$GODOT" --headless --path godot --script res://tests/run_annex.gd -- --quick   # 40 floors
"$GODOT" --headless --path godot --script res://tools/annex_tool.gd -- maps     # five text maps to godot/export/annex/
```

`prop_annex` is in `run_tests.gd`'s list (`npm run godot:test -- prop_annex`: 40 floors in the quick set,
800 in the default run); `tests/run_annex.gd` still runs it alone the same way. The plan hashes are a
golden, `tests/golden/annex.json`: re-record them with `npm run godot:golden -- prop_annex` only when
the Annex is meant to change, read the summary it prints, and commit the new file with the change.

## The properties (`tests/prop_annex.gd`)

800 floors (seed-0..199 at depths 1 to 4), 40 in the quick set (seed-0..9 at each depth). The oracles
are written in the test from `floor.gd`'s step rule; the lattice is found from the plan itself.

1. Every walkable cell and every room is reachable from the landing (a flood fill over `can_step`).
2. Every walkable cell can walk to the landing (a flood fill over steps taken backwards), and steps
   are symmetric (checked on the first 40 floors).
3. Blocking the middle cell of any one segment leaves every other corridor cell of that level
   connected through corridor; blocking any one stair leaves everything else, level 1 included,
   reachable. Two stairs, three from depth 4.
4. Generating twice gives the same plan hash, and every hash matches the golden `tests/golden/annex.json`;
   `plan.place` is `&"annex"`.
5. Every corridor cell has at least two ways out; at least two side branches per floor, each one
   door in and at most two rooms deep; no room cell more than **9** steps from a corridor (see
   "Decisions").
6. A straight corridor of 8 or more cells exists; the entity starts at the end of one, 12 or more
   steps from the landing; one lobby, with two doors, holding the landing.
7. The most common level-0 block shape (rooms and doors relative to the block, a turned copy counting
   as the same shape) appears at least four times.
8. At most 80 rooms; the cell above the landing is void; the car zone (3 along the elevator wall by 2
   beyond it) is void on both levels.

## Decisions where the design could not be followed to the letter

- **9 steps, not 8 (property 5).** The design's own copy suite (a 6 by 2 room with one door, two 3 by 4
  stores behind it) puts the far store corner at least |5 - door| + 5 + 1 >= 9 steps from the corridor
  wherever its door goes; the break room's closet without a back corridor is the same. The test's bound
  is 9, the tightest those templates allow.
- **Repetition counts turned copies (property 7), and the copy suite takes the largest template
  number.** With exact shapes and the plain pattern, the most common block shape appeared only 2 or 3
  times on about one floor in twenty (40-floor sample): templates face whichever side still has
  corridor, and the pattern can leave a template only two or three free blocks. A turned copy of the
  same arrangement is the same room to a player. The copy suite's shape depends only on which way it
  faces, so giving it the template number with the most free blocks (at least a third of them) makes
  property 7 hold by construction. The offset and the other two templates are still seeded.
- **Hash file location.** `tests/golden/annex.json`, recorded by `npm run godot:golden` like every other
  golden (it began as `tests/annex_hashes.json`, written by a tool of its own; the design's T1 list said
  `tests/reference/annex_hashes.json`).
- **Linux.** The hashes were checked on Windows only; run the test on the Linux server build to
  confirm the same list there.

## The deliberate breaks (both undone)

- Skip the bridge check: in `_prune`, `if not _sound(lat, present, true):` becomes
  `if not _sound(lat, present, false):`. Property 3 goes red on every floor (blocking one segment cuts
  off up to 200 corridor cells); 4 (hashes) and 5 (corner corridor cells left with one way out) go red too.
- Swap a seeded draw for engine randomness: the lobby's
  `var lx := shape.int_in(lat.x0 + 2, lat.x0 + L - 3 - (LOBBY_W - 1))` becomes
  `var lx := lat.x0 + 2 + randi() % (L - 8)`. Only property 4 goes red (37 of 40 floors differ between
  two generations and from the stored list).

## Timing

Measured on the development PC on 16 November 2026, with other Godot test runs going at the same time:
the full test (800 floors) about 250 s, the quick set (40 floors) about 15 s. Generating one floor takes
about 40 to 50 ms (the 800 twice over, for property 4, is about 85 s of the 250); rewriting the hash
list takes about a minute.
