# The Playroom generator

`sim/playroom.gd` builds the Playroom, floor 4: an empty indoor soft-play centre where the crew hides
from the Minder (design: `docs/floors/playarea.md`, section 6). It produces the same `Floor.FloorPlan`
as the Clinic and the Annex (2 m cells, two levels, rooms, doors, stairs, a landing, an entity start,
sightlines), with `plan.place = &"playroom"`. Hides, squeaker tiles, zones and the party-table seats are
pure functions of the plan and the seed, so the host and every client compute the same lists with no
new field on the plan or the wire. Nothing calls it yet but its tests and its tool: the place deck
(T16e) and the count (T15b) come next.

```gdscript
const Playroom = preload("res://sim/playroom.gd")
var plan := Playroom.generate_playroom("seed-0", 4)   # Floor.FloorPlan, place &"playroom"
var hides := Playroom.hides(plan, plan.seed)          # Array[Playroom.Hide], zone by zone
var squeak := Playroom.squeakers(plan, plan.seed)     # PackedInt32Array of Floor.pos_index, ascending
var zones := Playroom.zones(plan)                     # Array[Playroom.Zone]: id, block, rooms, ways in, sign number
var seats := Playroom.seats(plan)                     # Array[Playroom.Seat]: 8 seats at the far-end party table
Playroom.party_room(plan)                             # the Minder's start room, where taken players sit
Playroom.entity_facing(plan)                          # which way the Minder faces at its start (the wall)
Playroom.sign_text(zone)                              # "HIDING PLACES HERE: 3. IT LOOKS IN 1."
Playroom.floor_hashes(plan)                           # [plan, hides, squeakers, zones, seats] hashes
Playroom.render_ascii(plan, level)                    # a text map with hides, squeakers and seats
```

`hides` and `squeakers` take the seed as the design says; `""` means `plan.seed`. `zones(plan)` takes
no seed, so its sign numbers come from `hides(plan, plan.seed)`.

## What it builds

Canonical orientation first, then one of the grid's eight symmetries (seeded), as the Clinic does.

- **Walkway.** The Annex's lattice (`annex.gd` `_make_lattice`): one-cell padded walkways every 7
  cells, 6 by 6 blocks between them, 4 blocks a side below 42 cells (depths 1 to 3), 5 from 42 (depth 4,
  the Playroom's own floor). On each level 15% of the segments are taken out in a seeded order (6 of 40,
  9 of 60), never one on the **outer ring**, never a protected one (each stair's foot segment on level
  0 and head segment on level 1, the four balcony segments round each ball pit on level 1), never one
  that leaves a block with walkway on fewer than two sides, and never one that leaves a junction or a
  segment whose loss would split the walkway. So there is always a loop round the whole floor, no
  dead-end walkway, and blocking any one walkway cell leaves the rest of that level's walkway joined.
- **Lift lobby** (the shoe room). 5 by 3 off the south line, a door at each end; the landing is the
  middle cell of the outer row; the shaft cell above it and the car zone (3 along the outer wall by 2
  beyond it) stay void on both levels. No hides, no squeakers.
- **Stairs.** Two blocks hold the soft steps, at least two blocks apart (diagonals included): the
  Annex's 4-cell stair climbing from the block's front edge, a two-cell stub on level 1 joining its head
  to the back walkway. Beside it on both levels, across the block from the stair's column, a 4 by 6
  **nook** (kind `nook`) with a way in on every side that has walkway, holding a crawl den and a toy
  chest.
- **Blocks on level 0.** One party room on the row farthest from the lift, then one each of ball pit,
  frame, toddler corner and cloakroom on seeded blocks, then every other block dealt from a deck of the
  five, reshuffled whenever it runs out. A ball pit never goes beside another ball pit or a stair block
  (a ball pit dealt there waits in the deck for a later block). Each template is stamped in the Annex's local frame and turned
  to face the first of south, north, east, west (canonical) that has walkway:
  - **ball pit** (`ballpit`): one 6 by 6 room, a way in on every side with walkway. On level 1 above
    it, an opening with netted balconies round it (the Annex's atrium).
  - **frame** (`den`): four 3 by 3 crawl dens linked in a ring by low doors; the front two open on the
    front walkway, the back two on the back walkway, and each den on the side walkway beside it.
  - **party room** (`party`): 6 by 4, two front doors, two 3 by 2 stores (`store`) behind it, each
    with a back door onto the back walkway when there is one.
  - **toddler corner** (`toddler`): one open 6 by 6 room, a way in on every side with walkway.
  - **cloakroom** (`cloak`): 4 by 6, a front door and a back door (when the back has walkway), a 2 by 6
    store with its own door onto the east walkway (when there is one). The west wall has no door: the
    six coat cubbies stand along it.
- **Level 1**, the frame's upper deck. Over every block that is not a stair or a ball pit, a netted
  **deck** (one 6 by 6 room, kind `deck`, a way in on every side with walkway), in a seeded order while
  the 80-room budget lasts; then, in the same order and while it still lasts, the deck over a frame
  becomes the frame's **upper storey** (four 3 by 3 `den`s, as below).
- **Entity start.** The party room farthest from the landing by walking (steps to its nearest cell; the
  lowest room id on a tie), at one of the two middle cells of the row against its back wall (the wall
  its stores are behind; seeded), facing that wall. The far row's party room makes it 33 or more steps.
- **Room kinds:** `lobby`, `ballpit`, `den`, `party`, `store`, `toddler`, `cloak`, `nook`, `deck`.

**Seed.** `Rng.make_rng("playroom:<seed>:<depth>")`, a named fork per stage: `shape` (lattice position,
lobby), `stairs` (stair blocks, facing, column), `blocks` (templates, the level-1 order), `prune0`,
`prune1`, `orient`, `entity`, and for the lists `hides` (one sub-fork per zone, `zone:<id>`) and
`squeak`. Whole numbers only (the floats are inside `Rng`), no engine randomness, no sorts.

## Zones

A zone is one block on one level (the party room and its stores are one block). **Zone ids are block
ids: `level * n * n + row * n + column`**, row-major in the plan as generated (after the symmetry), so
level 1's blocks are zones of their own. Only blocks with rooms are zones (a ball-pit opening and a
bare stair block are not). Each `Zone` has its block, its rooms, its ways in (indices into `plan.doors`
of the doors from a walkway into it) and its sign's number, its hide count. Every zone has 1 to 5 hides.

| Zone kind | Hides |
|---|---|
| `ballpit` | the pit (holds 3) in the middle, two tube-slide mouths |
| `frame` | two or three crawl dens (each in a different den), a playhouse |
| `upper` | two or three crawl dens (each in a different den), a tube slide's top |
| `deck` | a crawl den beside each of its two to four ways in, a tube slide's top |
| `party` | the party table (holds 2), a toy chest in each store |
| `toddler` | two playhouses |
| `cloak` | three or four of the six coat cubbies, and a toy chest in the store or not |
| `nook` | a crawl den, a toy chest |

## Hides

A `Hide` has an id, zone, room, level, kind, capacity, an inside spot, a front spot, an eye height, a
gap direction, a gap half-angle and a gap range. Positions are **whole centimetres**: `x` is world x
and `y` is world z (cell x times 200 plus an offset). Kinds and their numbers are the design's table:
`pit` (3, 0.3 m, 180 degrees, the gap only 4 m far), `slide` (2, 0.6 m, 20), `den` (1, 0.7 m, 40),
`playhouse` (1, 1.0 m, 25), `table` (2, 0.3 m, 60), `chest` (1, 0.5 m, 30), `cubby` (1, 1.4 m, 15).

Most hides stand against a wall: the seed picks a wall slot (an edge cell of the room that is not a
door cell, and one of its walled sides); the inside spot is 0.5 m from that wall at the middle of the
cell, the gap faces away from the wall into the room, and the front spot is 0.7 m further in. The pit
and the party table stand in the middle of their room: the pit's front is 0.7 m from the centre in a
seeded direction, the table's gap faces one of its two long sides (seeded). No two hides share a cell.

## Squeaker tiles

- **Toddler corners:** a seeded third of each corner's cells (12 of 36), taking a cell only if the
  corner's quiet cells stay joined to each other.
- **Walkways far from the lift:** of the walkway segment cells at least half the farthest walking
  distance from the landing, one in six. A segment's first squeaker goes in only if the quiet walkway
  (segments without a squeaker) is still one piece with no bridge; more squeakers on that segment only
  beside one already there, so each segment's squeakers are one run and every quiet cell of it still
  reaches a junction. In practice the far half gets a few loud stretches, each with a quiet loop round.
- **Never** in the lobby, on either cell of a door (a way in is never squeaky), on a hide's inside or
  front cell, on a junction, on a stair's foot cell, or on the head, the stub or the walkway cell the
  stub joins.

## Seats

`seats(plan)`: eight seats (one per player the server admits) at the far-end party room's table, four
along each long side, 1 m either side of the table's centre line, at 0.45 m and 1.35 m either way along
it, each facing the table and so across the room. The side nearer the back wall first.

## Commands

All headless, under a timeout, from `godot/` (`$GODOT` is the console build).

```sh
"$GODOT" --headless --path . --script res://tests/run_tests.gd -- prop_playroom           # the eight properties, 800 floors
"$GODOT" --headless --path . --script res://tests/run_tests.gd -- prop_playroom --quick   # 40 floors
"$GODOT" --headless --path . --script res://tools/playroom_tool.gd -- hashes              # rewrite tests/playroom_hashes.json
"$GODOT" --headless --path . --script res://tools/playroom_tool.gd -- maps                # five text maps to export/playroom/
```

`prop_playroom` is in `run_tests.gd`'s list, so `npm run godot:test` (and `-- --quick`) runs it.
Rewrite the hashes only when the Playroom is meant to change, and commit the new file with the change.

## The properties (`tests/prop_playroom.gd`)

800 floors (seed-0..199 at depths 1 to 4), 40 in the quick set (seed-0..9 at each depth); the same at
`--full`. The oracles are written in the test from `floor.gd`'s step rule; the lattice is found from the
plan itself.

1. Every walkable cell is reachable from the landing, and can walk back to it.
2. The outer ring is whole on both levels; no walkway cell is a cut cell of its level's walkway
   (Tarjan on the cell graph, every floor; and by brute force, blocking each walkway cell and flooding
   the rest, on the first 40); exactly two stairs, and with either blocked everything else, level 1
   included, is reachable.
3. Generating twice gives the same five hashes (plan, hides, squeakers, zones, seats), all equal to
   `tests/playroom_hashes.json`; `plan.place` is `&"playroom"`.
4. Every block kind is on level 0 (ball pit, frame, party room, toddler corner, cloakroom, two stair
   blocks); each level's hides hold at least 16; every walkway cell is at most 14 steps from a hide's
   front spot.
5. Every hide's inside and front spots are in its room, 0.3 m clear of its walls, on walkable cells of
   that room; the front within 0.8 m of the inside; the gap faces into the room; capacity, eye and gap as
   the design's table; every zone has 1 to 5 hides, at least one way in, and its sign reads its count.
6. Between any two walkway cells there is a path crossing no squeaker; every walkable cell that is not
   a squeaker is reached from the landing without crossing one; no squeaker in the lobby, on a door's
   cells or on a hide's spots, and every squeaker is on the walkway or in a toddler corner.
7. The entity starts in the party room farthest from the landing, 12 or more steps away, facing a
   wall; eight seats in that room, 0.3 m clear of its walls, apart, facing the table; one lobby with two
   doors and the landing, no hides and no squeakers; the shaft cell and the car zone are void.
8. At most 80 rooms.

## Decisions where the design had to be read

- **Zones on level 1 are their own zones** (`level * n * n + row * n + column`): the seeker's sweep and
  its one draw make sense on one level at a time.
- **Level 1's rooms.** The design names dens, balconies and slide tops on level 1 but no template. Four
  dens over every block would pass 80 rooms at depth 4, so level 1 gets a one-room netted `deck` over
  every block that is not a stair or ball pit, and four `den`s over frames while the budget lasts.
- **Property 4's 14 steps needed five additions the design does not name:** the nook beside the
  steps; doors from the frame's dens onto side walkways and from the party stores and the cloakroom's
  store onto the walkway behind or beside them; a deck's crawl dens beside its ways in; and no ball pit
  beside another ball pit or a stair block. Without them a walkway beside a stair block, a party room's
  back or a pair of ball-pit openings on level 1 was up to 20 steps from a hide (408 cells on 800
  floors). With them the farthest walkway cell on 800 floors is 14 steps.
- **Six cubbies, three or four hides.** Six hides would break "between 1 and 5 hides" in one zone, so
  the seed says which three or four of the six are deep enough to hide in (the others are drawn as
  shallow shelves later), and the store's toy chest is optional.
- **A way in** is a door from the walkway into a zone. "Never all the cells of a way in" is read as
  never either cell of a door, and the quiet-path rules above keep every quiet cell reachable.
- **Walkway squeakers.** Taken literally, one cell in six on a one-cell walkway is about one squeaker
  per far segment, which would leave no quiet loop. The quiet-loop rule caps it; the rest of the one in
  six goes on as runs beside the first squeaker of a segment.
- **Exactly two stairs** at every depth (the Annex has three from depth 4); the design says two.
- **The cut-junction rule** is added to the Annex's bridge rule: blocking a junction cell is blocking
  a walkway cell too, and the bridge rule alone does not keep the rest joined.
- **"Block any one walkway cell"** is checked on the lattice's cells. The two-cell stair stubs on
  level 1 are dead ends by construction (the Annex's stair block) and are not walkway.
- **14 steps** are counted by walking from the walkway cell to the cell of a hide's front spot.
- **The entity's facing** is not a plan field; `entity_facing(plan)` gives it. "Furthest by walking" is
  steps to the room's nearest cell.
- **Seats:** eight, one per player the server admits (`net/ws_server.gd` `MAX_PLAYERS`).
- **The party room on the far row** is placed first so the far-end party room is always 12 or more
  steps from the landing (33 or more on 800 floors).
- **Linux.** The hashes were checked on Windows only; run the test on the Linux server build to
  confirm the same list there.

## The deliberate breaks (all undone)

Each was applied, `run_tests.gd -- prop_playroom --quick` run, then undone and the suite run green.

- **Remove an outer-ring segment** (property 2): after `var present0 := _prune(...)`, add
  `present0[lat.h(1, 0)] = 0`. Property 2 goes red: `seed-0 d1 L0: the outer ring is missing 6 cells`,
  `seed-3 d1 L0: blocking walkway cell 1,1 cuts the walkway (14 such cells)` and, by brute force,
  `seed-3 d1 L0: blocking walkway cell 1,1 cuts off 215 walkway cells`. Property 3 (hashes) too.
- **Lay squeakers across a whole way in** (property 6): after a toddler corner's squeakers, put one on
  the room-side cell of every door into it. Property 6 goes red: `seed-0 d1: 7 squeakers where none
  may be` and `seed-0 d1: 41 quiet cells cannot be reached from the landing without crossing a
  squeaker` (the corner's inside is cut off). The walkway-to-walkway half of the property stays green
  under this break, as it should: the walkway itself is still quiet. Property 3 (squeaker hashes) too.
- **Swap a seeded draw for `randi()`** (property 3): the lobby's `shape.int_in(...)` becomes
  `lat.x0 + 2 + randi() % (L - 8)`. Only property 3 goes red: `seed-0 d1: plan generated twice, hashes
  87fd22b55ca2df95 and 314d19d89aa77201`, `lists whose two generations differ: got 82, want 0`.

## Timing

Measured on the development PC on 16 November 2026: the full test (800 floors) 456 s, of which
property 3 (every floor generated a second time, with all five lists) is 221 s and property 1 is 134 s;
the quick set (40 floors) about 24 s; the whole quick suite with it 102 s. One floor takes about 40 to
60 ms to generate; rewriting the hash file about 2 minutes. Two runs of `-- hashes` wrote byte-identical
files. No warnings: checked with Godot's language server on the project's warning settings (integer
division is meant throughout and is silenced with `@warning_ignore_start("integer_division")`).

## Five floors

Written by `tools/playroom_tool.gd -- maps`. Row 0 is north (smallest z); column 0 is west.

```
Playroom seed-0 depth 1  (36x36, 57 rooms, 140 doors, 2 stairs, 96 hides holding 65 + 57, 46 squeakers, 29 zones, hash 314d19d89aa77201, 40.1 ms)
# void  . walkway  ^>v< soft steps (point uphill)  o ball-pit opening  E landing  X Minder start  + door (on the room side)  B ball pit  D den  P party  S store  T toddler  C cloak  K deck  N nook  L lobby  (neighbouring rooms of the same kind alternate upper/lower case)
hides: * pit  = tube slide  % crawl den  & playhouse  $ party table  [ toy chest  | coat cubby   ! squeaker tile   : party-table seat

Level 0
####################################
###.............................####
###.NNN+%[.[+Ss+s!S+Ss+s#&!T+T&.####
###.+NNNNN.S+S[+s!S+[s+[#TTT!!T.####
###.NNNNN+.PPPPPP!PPPPPP#T!T!!+.####
###.NNNNNN!PPPPPP.PPPPPP#!!TTTT.####
###.######.PPP$PP.PPP$PP#!!T!TT.####
###.##<<<<.P+PP+P.P+PP+P#TT+TT!.####
###..........!..............!...####
###.D+%D+D.=BB+BB.SSC+C|.P+PP+P.####
###.+D+DD+.BBBBBB.SSCCC|.PP::PP.####
###.D+DD+%.BBBBB+.S+CCCC.PP:$PP.####
###.dddDDD.+BB*BB.+SCCCC.PPPXPP.####
###.+d+DD+.BBBBB=.SSCCCC.s+[S+[.####
###.&ddDDD.BB+BBB.SSCCC|.sssSSS.####
###.######........######.######.####
###.SSSSSS.!&!+!!.NNNN##.D%Dddd.####
###.S[S+SS.TT!TTT.NNN%##.+DD+d+.####
###.CCCCCC.T!TTT+.+NNN#^.DDD&d%.####
###.CCCCC+.+!!T!T.NNNN#^.D+DD+D.####
###.+CCCCC.TTTT!T.NNNN#^.+DD+D+.####
###.|C|||C.T!+T!&.N+N[#^.D+DD+%.####
###.######....................!.####
###.BBBBBB.D+D%+d.|+CCSS#BB=+BB.####
###.BBBBB=.+DD+d+.|CCCSS#BBBBBB.####
###.BBBBB+.DDDddd.|CCC[S#BBBBB+.####
###.+BB*BB.D+%D+%.|CCC+S#BBB*B=.####
###.BBBBBB.+DD+D+.CCCCSS#BBBBBB.####
###.B=+BBB.D+&D+D.CC+CSS#BB+BBB.####
###.............................####
#######+LLL+########################
#######LLLLL########################
#######LLELL########################
####################################
####################################
####################################

Zones on level 0 (id, kind, the sign's number; north up)
 0 nook    2 |  1 party   3 |  2 party   3 |  3 toddler 2
 4 frame   3 |  5 ballpit 3 |  6 cloak   3 |  7 party   3
 8 cloak   5 |  9 toddler 2 | 10 nook    2 | 11 frame   4
12 ballpit 3 | 13 frame   4 | 14 cloak   5 | 15 ballpit 3

Level 1
####################################
###.............................####
###.NNN+N%.KK%+KK!KKK+%K#=KK+%K.####
###.+NNNNN.KKKKKK!KKKKKK#KKKKK%.####
###.NNNNN+.%KKKK+.KKKKKK#KKKKK+.####
###.NNNNN[.+KKKK%.+KKKKK#KKKKKK.####
###.######!KKKKKK.%KKKKK#KKKKKK.####
###...<<<<!=%+KKK.K%+KK=#KKKKKK.####
###...!!.................######.####
###.D+DD+D.oooooo.K=K+%K.=KKKKK.####
###.+D+DD+.oooooo.KKKKKK.KKKKK%.####
###.D+%D+D.oooooo.%KKKK+.%KKKK+.####
###.dddDDD.oooooo.+KKKK%.+KKKKK.####
###.+d+DD+.oooooo!KKKKKK.KKKKKK.####
###.=ddD%D.oooooo!KK+%KK.K%+KKK.####
###.######........!!............####
###.KKKKKK#KKK+%=.%N+N#..D+Dd+d!####
###.KKKKKK#KKKKK%.NNNN#..+DD+d+.####
###.KKKKKK#KKKKK+.+NNN#^!=D%%dd.####
###.+KKKKK#KKKKKK.NNNN#^!D+DD+D.####
###.%KKKK=#KKKKKK.NNNN#^.+DD+D+.####
###.KK+%KK#KKKKKK.[+NN#^.D+D%+D.####
###........######...............####
###.oooooo.DDDddd#KK%+KK!oooooo.####
###.oooooo.+DD+dd#KKKKKK!oooooo.####
###.oooooo.%DDddd#KKKKK+.oooooo.####
###.oooooo.D+D%+D#=KKKK%.oooooo.####
###.oooooo.+DD+DD#KKKKKK.oooooo.####
###.oooooo.%+DD+=#KK+%KK.oooooo.####
###.............................####
####################################
####################################
####################################
####################################
####################################
####################################

Zones on level 1 (id, kind, the sign's number; north up)
16 nook    2 | 17 deck    5 | 18 deck    4 | 19 deck    3
20 upper   3 | 21 -       - | 22 deck    5 | 23 deck    4
24 deck    3 | 25 deck    3 | 26 nook    2 | 27 upper   4
28 -       - | 29 upper   4 | 30 deck    4 | 31 -       -

Minder start: level 0 cell 28,12 in party room 19, facing s
Seats (cm, facing): 5465,2300 n; 5555,2300 n; 5645,2300 n; 5735,2300 n; 5465,2100 s; 5555,2100 s; 5645,2100 s; 5735,2100 s;
```

```
Playroom seed-1 depth 2  (38x38, 58 rooms, 148 doors, 2 stairs, 103 hides holding 60 + 66, 55 squeakers, 30 zones, hash 20ab1aacc04b2b2d, 41.4 ms)
# void  . walkway  ^>v< soft steps (point uphill)  o ball-pit opening  E landing  X Minder start  + door (on the room side)  B ball pit  D den  P party  S store  T toddler  C cloak  K deck  N nook  L lobby  (neighbouring rooms of the same kind alternate upper/lower case)
hides: * pit  = tube slide  % crawl den  & playhouse  $ party table  [ toy chest  | coat cubby   ! squeaker tile   : party-table seat

Level 0
######################################
######################################
########...............!!!...........#
########.>>>>###CC||||.=BB+BB.D+&d+d.#
########.#######CCCCCC.BBBBBB.+D+dd+.#
########.NNNN%N#CCCCC+.BBBBB+.D+Dd+d.#
########.NNNNNN#CCCCCC.+BB*BB.DD%DDD.#
########.+NNNNN#[SS+SS.BBBBB=.+D+DD+.#
########.N[N+NN#SS+SSS.BBBBBB.D+DD+%.#
########...............######...!!...#
########.PPPP[s.SSS+SS.TTT&T!.##<<<<.#
########.+PPP++.[S+SSS.!T!T!T.######.#
########.PPPPss.CCCCCC.T!TTT+.NNNNNN.#
########.PP$PS[.+CCCCC.+!!T!T.NNNNN+.#
########.+PPP++.CCCCC+.&TT!!T.+NNNNN.#
########.PPPPSS.||||CC.!!+TTT.N[N+%N.#
########.######.######...............#
########.=BBBBB.!TTTT!.D+Dd+d.PPPPss.#
########.=BBBBB.!T!TT&.+D+dd+.+PPP++.#
########.BBBBB+.T!TTT+.D+Dd+d.PPPP[s.#
########.+BB*BB.+TTT!T.&DDDDD.PP$PSS.#
########.BBBBBB.T!T!!!.+D+DD+.+PPP++.#
########.BB+BBB.!!+TT&.D+%%+D.PPPP[S.#
########......................######.#
#####LL+.TTT+T&#%+&D+%.[SS+SS.PPPP[s.#
#####LLL.!!T!!&#DDD+D+.SS+SSS.+PPP++.#
#####ELL.!!!TTT#DDDDDD.CCCCCC.P::Pss.#
#####LLL.+TTT!T#d+dD+D.+CCCCC.P:$X[S.#
#####LL+.!!TTT!#ddd+D+.CCCCC+.+PPP++.#
########.TT+TT!#d+dD+D.|C|C||.PPPPSS.#
########.............................#
######################################
######################################
######################################
######################################
######################################
######################################
######################################

Zones on level 0 (id, kind, the sign's number; north up)
 0 nook    2 |  1 cloak   5 |  2 ballpit 3 |  3 frame   3
 4 party   3 |  5 cloak   5 |  6 toddler 2 |  7 nook    2
 8 ballpit 3 |  9 toddler 2 | 10 frame   3 | 11 party   3
12 toddler 2 | 13 frame   3 | 14 cloak   5 | 15 party   3

Level 1
######################################
######################################
########...............!!!!..........#
########.>>>>...K=K+%K.oooooo.D+%d+d.#
########.######.KKKKK%.oooooo.+D+dd+.#
########.N[NNNN.KKKKK+.oooooo.D+Dd+d.#
########.NNNNN+.+KKKKK.oooooo.%DD%DD.#
########.+NNNNN.%KKKKK.oooooo.+D+DD+.#
########.NN%+NN.KKKKKK.oooooo.=DDDDD.#
########........######.....!!.######.#
########.KK%+KK.K=KKKK.KK%+KK...<<<<.#
########.KKKKKK.KKKKKK.=KKKKK.######.#
########.%KKKK+.KKKKK+.KKKKK+.%NNNNN.#
########.+KKKK%.+KKKK%.+KKKK%.NNNNN+.#
########!KKKKKK.%KKKKK.%KKKKK.+NNNNN.#
########!=K+%KK.KK+%KK.K%+KKK.N[N+NN.#
########............!!........!!!....#
########.oooooo.KK%+=K#D+DD+D!=K%+KK.#
########.oooooo.KKKKKK#DDD+D+.KKKKK%.#
########.oooooo.KKKKKK#DDD%D=.KKKKK+.#
########.oooooo.+KKKKK#%+dD+D.+KKKKK.#
########.oooooo.%KKKKK#ddd+D+.%KKKKK.#
########.oooooo.KKKKKK#d+dD+%.K%+KKK.#
########........######...............#
########.KK%+KK#DDD%DD.KK%+KK#KKK+%K.#
########.KKKKKK#DDD+D+.KKKKKK#KKKKK=.#
########.KKKKKK#%DDDDD.%KKKKK#KKKKK+.#
########.+KKKK=#d+dD+=.+KKKKK#KKKKK%.#
########.%KKKKK#ddd+D+.KKKKK=#KKKKKK.#
########.K%+KKK#d+dD+%.KK+%KK#K%+KKK.#
########.............................#
######################################
######################################
######################################
######################################
######################################
######################################
######################################

Zones on level 1 (id, kind, the sign's number; north up)
16 nook    2 | 17 deck    4 | 18 -       - | 19 upper   4
20 deck    5 | 21 deck    4 | 22 deck    5 | 23 nook    2
24 -       - | 25 deck    3 | 26 upper   4 | 27 deck    5
28 deck    4 | 29 upper   4 | 30 deck    4 | 31 deck    4

Minder start: level 0 cell 33,27 in party room 5, facing e
Seats (cm, facing): 6500,5265 w; 6500,5355 w; 6500,5445 w; 6500,5535 w; 6300,5265 e; 6300,5355 e; 6300,5445 e; 6300,5535 e;
```

```
Playroom seed-2 depth 3  (40x40, 58 rooms, 145 doors, 2 stairs, 96 hides holding 57 + 62, 54 squeakers, 30 zones, hash b2128cbaee29f7e5, 43.5 ms)
# void  . walkway  ^>v< soft steps (point uphill)  o ball-pit opening  E landing  X Minder start  + door (on the room side)  B ball pit  D den  P party  S store  T toddler  C cloak  K deck  N nook  L lobby  (neighbouring rooms of the same kind alternate upper/lower case)
hides: * pit  = tube slide  % crawl den  & playhouse  $ party table  [ toy chest  | coat cubby   ! squeaker tile   : party-table seat

Level 0
########################################
########################################
########################################
########################################
########################################
########################################
########################################
########################################
##########..................!!!........#
##########.||C|CC#SS+S[S.BB+BB=.D+DD+D.#
##########.CCCCCC#SSS+SS.BBBBBB.+D+DD+.#
##########.+CCCCC#CCCCCC.+BBBBB.DD&DDD.#
##########.CCCCCC#CCCCC+.BBB*B+.D+Dd+d.#
##########.SS+SSS#CCCCCC.BBBBBB.+D+dd+.#
##########.SSS+S[#C|C|C|.=BB+BB.D%Ddd%.#
##########......................######.#
##########.PPPPSS.BB+B=B.T!+&!T!!!!TT!.#
##########.+PPP++.BBBBBB.TTTTTT!TT!T!T.#
##########.PPPPS[.+BBBBB.+!TT!!.+T!TTT.#
##########.PP$P[s.BBB*B+.&!TTT+.&!!!T+.#
##########.+PPP++.BBBBBB.TT!!!T.TTTTTT.#
##########.PPPPss.BBBBB=.!TT+!!.&TT+!!.#
##########........######.........!!....#
##########.!!+TT!.PPPPSS#SS+SSS.######.#
##########.!T!TTT.+PPP+S#SSS+SS.##<<<<.#
##########.+T!TT!.PPPPS[#CCCCCC.NNN[NN.#
#######LL+.TT!T!+.PP$Pss#CCCCC+.+NNNNN.#
#######LLL.TTTTT&.+PPP+s#CCCCCC.%NNNN+.#
#######ELL.T!!+&!.PPPPs[#||||CC.NNNNNN.#
#######LLL......................######.#
#######LL+.##[%+N.D+&D+D#d+dD+&.PPPPSS.#
##########.##NNNN.+D+DDD#ddd+D+.+PPP++.#
##########.#^NNNN.DD%%DD#%+dD+D.P::X[S.#
##########.#^NNN+.D+Dd+d#DDDDD%.P:$Pss.#
##########.#^NNNN.+D+ddd#DDD+D+.+PPP++.#
##########.#^N+NN.D+Dd+d#D+DD+D.PPPP[s.#
##########.............................#
########################################
########################################
########################################

Zones on level 0 (id, kind, the sign's number; north up)
 0 cloak   4 |  1 cloak   4 |  2 ballpit 3 |  3 frame   3
 4 party   3 |  5 ballpit 3 |  6 toddler 2 |  7 toddler 2
 8 toddler 2 |  9 party   3 | 10 cloak   4 | 11 nook    2
12 nook    2 | 13 frame   3 | 14 frame   3 | 15 party   3

Level 1
########################################
########################################
########################################
########################################
########################################
########################################
########################################
########################################
##########.............................#
##########.K%+KKK#K%+=KK.oooooo.D+D%+D.#
##########.KKKKKK#KKKKKK.oooooo.+D+DD+.#
##########.+KKKKK#KKKKK%.oooooo!DDDDDD.#
##########.%KKKK=#KKKKK+.oooooo!D+D=+d.#
##########.KKKKKK#KKKKKK.oooooo.+D+dd+.#
##########.KKK+%K#KK%+KK.oooooo.D+D%+d.#
##########............!!.............!.#
##########!KK+%KK.oooooo!KK+%KK.K%+KKK.#
##########!%KKKKK.oooooo!%KKKKK.%KKKKK.#
##########.+KKKK%.oooooo.+KKKKK.+KKKKK.#
##########.KKKKK+.oooooo.KKKKK+.KKKKK+.#
##########.KKKKKK.oooooo.KKKKK%.KKKKK%.#
##########.KKK+%=.oooooo.K=KKKK.=KKKKK.#
##########...............######.######.#
##########.=%+KKK#KK+%K=.K=KKKK.######.#
##########.%KKKKK#KKKKKK.KKKKKK...<<<<.#
##########.+KKKKK#KKKKKK.+KKKKK.NNNNNN.#
##########.KKKKKK#KKKKK+.%KKKK+.+NNNNN.#
##########.KKKKKK#KKKKK%.KKKKK%.NNNNN+.#
##########.KKK+%K#KKKKKK.KKKKKK.[N+N%N.#
##########........######.######.!!.....#
##########.#.NN+N.DDDDDD.DDDDDD.KK+%KK.#
##########.#.%NNN.+D+DD+.+D+DD+.%KKKKK.#
##########.#^NNNN.%DDDDD.DDD%DD.+KKKK%.#
##########.#^NNN+.D+D=+d.D+D=+d.KKKKK+.#
##########.#^NNNN.+D+dd+.+D+dd+.KKKKKK.#
##########.#^N+N[.D+D%+d.D+%%+d.KK%+=K.#
##########.............................#
########################################
########################################
########################################

Zones on level 1 (id, kind, the sign's number; north up)
16 deck    4 | 17 deck    4 | 18 -       - | 19 upper   3
20 deck    5 | 21 -       - | 22 deck    4 | 23 deck    4
24 deck    4 | 25 deck    3 | 26 deck    3 | 27 nook    2
28 nook    2 | 29 upper   3 | 30 upper   4 | 31 deck    5

Minder start: level 0 cell 35,32 in party room 10, facing e
Seats (cm, facing): 6900,6465 w; 6900,6555 w; 6900,6645 w; 6900,6735 w; 6700,6465 e; 6700,6555 e; 6700,6645 e; 6700,6735 e;
```

```
Playroom seed-3 depth 4  (42x42, 80 rooms, 206 doors, 2 stairs, 151 hides holding 99 + 94, 93 squeakers, 45 zones, hash 3c43e4a44b425863, 58.5 ms)
# void  . walkway  ^>v< soft steps (point uphill)  o ball-pit opening  E landing  X Minder start  + door (on the room side)  B ball pit  D den  P party  S store  T toddler  C cloak  K deck  N nook  L lobby  (neighbouring rooms of the same kind alternate upper/lower case)
hides: * pit  = tube slide  % crawl den  & playhouse  $ party table  [ toy chest  | coat cubby   ! squeaker tile   : party-table seat

Level 0
##########################################
##########################################
#########################LLELL############
#########################LLLLL############
#########################+LLL+############
####....................................##
####.NN+NNN.D+DD+D#B=+BBB#%+D&+D.|C+CSS.##
####.[NNNN+.+DD+DD#BBBBBB#DDD+D+.CCCCSS.##
####.+NNNNN.D+D%+D#BBBBBB#D+DD+%.CCCC+S.##
####.%NNNNN.&D%ddd#BBB*BB#DDD%dd.|CCCS+.##
####.##<<<<.+DD+dd#BBBBBB#DDD+d+.|CCCSS.##
####.######.D+Dd+d#BBB+B=#D+Dd+d.C+CCSS.##
####.######.............................##
####.[ss[SS.=B+B=B#D+DD+D.|C+CSS.&T+!TT.##
####.s+sS+S.BBBBBB#DDD+D+.|CCCSS.TT!!!T.##
####.PPPPPP.+BBBBB#D+D%+D.|CCC+S.+T!TTT.##
####.PPPPPP.BBB*BB#DDDddd.CCCCS+.!TTTT+.##
####.PPP$PP.BBBBBB#DDD+d+.|CCCSS.TT!T!&.##
####.P+PP+P.BBB+BB#DDD%d&.C+CCSS.!T!+!!.##
####.!.............######...............##
####.|C+CSS.D+DD+D.BBBBBB#P+PP+P.CC+CSS.##
####.CCCCSS.+DD+D+.=BBBBB#PPPPPP.|CCCSS.##
####.|CCC+S.D+%D+D.+BBBBB#PPP$PP.|CCC+S.##
####.CCCCS+.%D&ddd.BBB*BB#PPPPPP.|CCCS+.##
####.|CCCSS.+DD+d+.=BBBBB#S+Ss+s.CCCCSS.##
####.C+CC[S.D+D%+d.BBB+BB#S+[[+s.|+CCSS.##
####....!!!.............................##
####.!T+!T!.&!+TTT.P+PP+P#BB+BBB.TT+&T!.##
####.T!T!T!.T!!TTT!PPPPPP#BBBBBB.TT!TTT.##
####.+!TTTT.+!!T!&!PPP$PP#BBBBBB.+!TTTT.##
####.TT!T!+.TT!!T+.PPPPPP#BBB*B+.!!T!!+.##
####.TTT!T&!!TTTTT.S+[s+[#BBBBBB.TTTT!!.##
####.&!TTT!!!T!+T!.S+Ss+s#=B=+BB.!!!+&T.##
####.######..........................!!.##
####.SSCCC|.BB+BBB.D+DD+D.P+PP+P##vN+NN.##
####.SSCCC|.BBBBBB.+DD+D+.PP::PP##vNNNN.##
####.+SCCCC.+BBBBB!D+DD+%!PP:$PP##vNNN+.##
####.S+CCCC.BBB*B+.DDDddd!PPPXPP##vNNNN.##
####.SSCCC|.BBBBBB.+DD+d+.S+Ss+s###NNNN.##
####.SSC+C|.BBB+==.D+&%+d.S+[[+s###%N+[.##
####....................................##
##########################################

Zones on level 0 (id, kind, the sign's number; north up)
 0 nook    2 |  1 frame   3 |  2 ballpit 3 |  3 frame   4 |  4 cloak   3
 5 party   3 |  6 ballpit 3 |  7 frame   3 |  8 cloak   4 |  9 toddler 2
10 cloak   4 | 11 frame   4 | 12 ballpit 3 | 13 party   3 | 14 cloak   4
15 toddler 2 | 16 toddler 2 | 17 party   3 | 18 ballpit 3 | 19 toddler 2
20 cloak   4 | 21 ballpit 3 | 22 frame   3 | 23 party   3 | 24 nook    2

Level 1
##########################################
##########################################
##########################################
##########################################
##########################################
####...............!!...................##
####.[N+NNN#KK+%KK.oooooo.D+DD+=.KK+%KK.##
####.NNNNN%#KKKKKK.oooooo.+DD+D+.%KKKKK.##
####.+NNNNN#KKKKK%.oooooo.D+D%+D.+KKKKK.##
####.NNNNNN#KKKKK+.oooooo.DD%ddd.KKKKK+.##
####...<<<<#KKKKKK.oooooo.+DD+d+.KKKKK%.##
####.#######=K%+KK.oooooo.D+Dd+d.KK=KKK.##
####.######........!!..........!.######.##
####.K=KKKK.oooooo.KK+%KK.KK+%K=.KKKK=K.##
####.KKKKKK.oooooo.=KKKKK.KKKKKK.%KKKKK.##
####.+KKKK%.oooooo.+KKKKK.+KKKKK.+KKKKK.##
####.%KKKK+.oooooo!%KKKK+.%KKKK+.KKKKK+.##
####.KKKKKK.oooooo!KKKKK%.KKKKK%.KKKKK%.##
####.KK%+KK.oooooo!KKK+%K.KKKKKK.KK%+KK.##
####.!!...................######.!!.....##
####.KK+%KK.K%+KKK.oooooo.KKK=KK.K%+KKK.##
####.%KKKKK.%KKKK=.oooooo.KKKKKK.%KKKK=.##
####.+KKKK=.+KKKK%.oooooo.+KKKK%.+KKKK%.##
####.KKKKK+.KKKKK+.oooooo!%KKKK+.KKKKK+.##
####.KKKKK%.KKKKKK!oooooo!KKKKKK.KKKKKK.##
####.KK%+KK.KK%+KK!oooooo!KK%+KK.KKKKKK.##
####.....!!...............!!!....######.##
####.=%+KKK#KK+%KK#K%+KK=.oooooo.KKKKKK.##
####.%KKKKK#KKKKKK#KKKKKK.oooooo.KKKKKK.##
####.+KKKKK#KKKKKK#KKKKKK.oooooo.%KKKK+.##
####.KKKKKK#KKKKK=#KKKKK+.oooooo.+KKKK%.##
####.KKKKKK#KKKKKK#KKKKK%.oooooo.KKKKK=.##
####.KK%+KK#KKK+%K#KKKKKK.oooooo.KKKKKK.##
####.....!!........######........######.##
####.KK+%KK.oooooo.d=dDD%.K%+KKK!#vNNNN.##
####.%KKKKK.oooooo.+d+DD+.KKKKKK!#vNNNN.##
####.+KKKKK.oooooo.dddDDD.+KKKKK!#vNNN+.##
####.KKKKK+.oooooo.D+DD+D.%KKKK+.#v%NNN.##
####.KKKKK%.oooooo.+D+DD+.KKKKK%.#.NNNN.##
####.KK%+K=.oooooo.%+DD+D!K=K+%K.#.NN+[.##
####........!!!!........................##
##########################################

Zones on level 1 (id, kind, the sign's number; north up)
25 nook    2 | 26 deck    4 | 27 -       - | 28 upper   3 | 29 deck    4
30 deck    4 | 31 -       - | 32 deck    5 | 33 deck    4 | 34 deck    4
35 deck    5 | 36 deck    5 | 37 -       - | 38 deck    4 | 39 deck    4
40 deck    4 | 41 deck    3 | 42 deck    3 | 43 -       - | 44 deck    3
45 deck    5 | 46 -       - | 47 upper   3 | 48 deck    5 | 49 nook    2

Minder start: level 0 cell 29,37 in party room 12, facing s
Seats (cm, facing): 5665,7300 n; 5755,7300 n; 5845,7300 n; 5935,7300 n; 5665,7100 s; 5755,7100 s; 5845,7100 s; 5935,7100 s;
```

```
Playroom seed-4 depth 4  (42x42, 80 rooms, 204 doors, 2 stairs, 156 hides holding 95 + 101, 101 squeakers, 46 zones, hash 458032e8e8fcfd48, 65.1 ms)
# void  . walkway  ^>v< soft steps (point uphill)  o ball-pit opening  E landing  X Minder start  + door (on the room side)  B ball pit  D den  P party  S store  T toddler  C cloak  K deck  N nook  L lobby  (neighbouring rooms of the same kind alternate upper/lower case)
hides: * pit  = tube slide  % crawl den  & playhouse  $ party table  [ toy chest  | coat cubby   ! squeaker tile   : party-table seat

Level 0
##########################################
#####........!!............!.............#
#####.s+s[+S.TT+TT!.#v[+NN.d+dD+D.s+sS+[.#
#####.[+sS+S.T!!TT!.#vNNNN.+d+DD+.s+[S+S.#
#####.PPXPPP.+!!!TT.#vNNN+.dddDDD.PPPPPP.#
#####.PP::PP.TT!!T+.#vNNNN.D+D%+D.PPPPPP.#
#####.PP:$PP.TT!TTT.##NNNN.+D+DD+.PPP$PP.#
#####.P+PP+P.!&T+&!.##NN%N.D+%D+&.P+PP+P.#
#####...!!...!!.....######...............#
#####.SSCC+|.BB+BBB.ss[SSS.SSCC+|.TT+TT!.#
#####.SSCCCC.BBBBBB.s+sS+[.SSCCCC.!TT!T!.#
#####.+SCCCC.+BBBBB.PPPPPP.+SCCC|.+!T!T!.#
#####.S+CCC|.BBB*B+.PPPPPP.S+CCC|.T!T!T+.#
#####.SSCCC|.=BBBBB.PPP$PP.SSCCC|.TTT!!T.#
#####.SSC+CC.BBB+B=.P+PP+P.SSC+CC.&T!+&T.#
#####......!.............................#
#####.d+dD+&.CC+CS[.!!+!&T.d+dD+&#BB+BBB.#
#####.+d+DD+.CCCCSS.TTTTT!.+d+DDD#BBBBBB.#
#####.dddDD%.CCCC+S.+!TT!T.dddDDD#BBBBBB.#
#####.D+DD+D.|CCCS+.!T!TT+.D+D%+D#BBB*B+.#
#####.+D+DD+.|CCCSS.&T!T!!.+D+DDD#BBBBBB.#
#####.D+%D+%.|CCCSS.TTT+T!.D+%D+D#B=BB=B.#
#####........######...............######.#
#####.v#N+N%#T!TTTT.SSCC+C#BB+BBB.PPPP[s.#
#####.v#NNNN#TTT!!&.S[CCCC#BBBBBB.+PPP++.#
#####.v#NNNN#T!!!TT.+SCCCC#BBBBBB.PPPPss.#
#####.v#NNNN#TT!!T+.S+CCC|#=BB*B+.PP$PSS.#
#####.##NNNN#TTT!!!.SSCCC|#BBBBBB.+PPP++.#
#####.##[N+N#T!&+TT.SSC+C|#=BBBBB.PPPPS[.#
#####......................######.######.#
#####.d+dD+D.BB+BB=#SSCC+|.!TT!&T.sss[SS.#
#####.+d+DD+.BBBBBB#SSCCC|.T!T!!&.[+sS+S.#
#####.ddd%DD.+BBBBB#SSCCC|.+TTT!T.PPPPPP.#
#####.D+D&+D.BBB*BB#S+CCCC.T!TTT+.PPPPPP.#
#####.+D+DD+.BBBBB=#SSCCCC.T!TT!T.PPP$PP.#
#####.%+DD+%.BBB+BB#SSC+C|.!!T+!T.P+PP+P.#
#####....................................#
##################################+LLL+###
##################################LLLLL###
##################################LLELL###
##########################################
##########################################

Zones on level 0 (id, kind, the sign's number; north up)
 0 party   3 |  1 toddler 2 |  2 nook    2 |  3 frame   3 |  4 party   3
 5 cloak   3 |  6 ballpit 3 |  7 party   3 |  8 cloak   4 |  9 toddler 2
10 frame   4 | 11 cloak   4 | 12 toddler 2 | 13 frame   3 | 14 ballpit 3
15 nook    2 | 16 toddler 2 | 17 cloak   4 | 18 ballpit 3 | 19 party   3
20 frame   4 | 21 ballpit 3 | 22 cloak   4 | 23 toddler 2 | 24 party   3

Level 1
##########################################
#####....................................#
#####.KK+%KK#=%+KKK##vN+NN#d+dD+D.K%+KKK.#
#####.=KKKKK#KKKKKK##v[NNN#dd+DD+.%KKKKK.#
#####.+KKKKK#KKKKKK##vNNNN#ddd%DD.+KKKK%.#
#####.%KKKKK#KKKKKK##vNNNN#D+DD+%.KKKKK+.#
#####.KKKKKK#KKKKKK##.NNNN#DD+DD+.KKKKKK.#
#####.KKK+%K#KK%+KK##.NN+%#%+D=+D!KK%+K=.#
#####........!!!..................!!.....#
#####.=K+%KK.oooooo.K%+KK=#=%+KKK.=%+KKK.#
#####.%KKKKK.oooooo.%KKKKK#KKKKKK.KKKKKK.#
#####.+KKKKK.oooooo.+KKKKK#KKKKK%.+KKKK%.#
#####.KKKKK+.oooooo.KKKKKK#KKKKK+.%KKKK+.#
#####!KKKKK%.oooooo.KKKKKK#KKKKKK.KKKKKK.#
#####!KKK+%K.oooooo.KK%+KK#KKKKKK.KKK+%K.#
#####...........!!!........######........#
#####.KK+%KK#K%+KKK.KK+%K=.=KKKKK!oooooo.#
#####.%KKKK=#KKKKKK.%KKKKK.KKKKKK!oooooo.#
#####.+KKKKK#KKKKKK.+KKKK%.+KKKKK!oooooo!#
#####.KKKKKK#KKKKK+.KKKKK+.%KKKK+.oooooo!#
#####.KKKKKK#KKKKK%.KKKKKK.KKKKK%.oooooo!#
#####.KKK+%K#KKK=KK.KKK+%K.KK%+KK.oooooo.#
#####........######.!!.....!!............#
#####.v#[+NN.KKKKKK.K%+KKK.oooooo.K%+KK=.#
#####.v#NNNN.%KKKKK.%KKKK=.oooooo.KKKKKK.#
#####!v#%NN+.+KKKKK.+KKKKK.oooooo.+KKKKK.#
#####!v#NNNN.KKKKK+.KKKKK+.oooooo.%KKKK+.#
#####!.#NNNN.KKKKK%.KKKKK%.oooooo.KKKKK%.#
#####!.#NN+N.=KK+%K.KK%+KK.oooooo.KKKKKK.#
#####............!!...............######.#
#####.d+dD+%.oooooo!K%+KK=#K%+KKK!KKKKKK.#
#####.+d+DD+.oooooo!%KKKKK#KKKKKK!%KKKKK.#
#####.dd=DDD!oooooo.+KKKKK#KKKKKK.+KKKK%.#
#####.D+%D+%!oooooo.KKKKKK#KKKKK+.KKKKK+.#
#####.+D+DD+.oooooo.KKKKKK#=KKKK%.KKKKK=.#
#####.D+DD+D.oooooo.KKK+%K#KKK+%K.KK%+KK.#
#####....................................#
##########################################
##########################################
##########################################
##########################################
##########################################

Zones on level 1 (id, kind, the sign's number; north up)
25 deck    4 | 26 deck    3 | 27 nook    2 | 28 upper   4 | 29 deck    5
30 deck    5 | 31 -       - | 32 deck    4 | 33 deck    3 | 34 deck    5
35 deck    4 | 36 deck    3 | 37 deck    5 | 38 deck    4 | 39 -       -
40 nook    2 | 41 deck    4 | 42 deck    5 | 43 -       - | 44 deck    4
45 upper   4 | 46 -       - | 47 deck    4 | 48 deck    4 | 49 deck    4

Minder start: level 0 cell 8,4 in party room 13, facing n
Seats (cm, facing): 1665,1100 s; 1755,1100 s; 1845,1100 s; 1935,1100 s; 1665,1300 n; 1755,1300 n; 1845,1300 n; 1935,1300 n;
```
