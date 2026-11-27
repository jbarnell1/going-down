# The game's own rules around the run, applied by the host. Port of src/game/runHost.ts (HostRules,
# startSpot, startBody, parkedOrderly). Work-arounds for gaps in the run's logic, kept visible here:
#  - create_run always starts at depth 1. A depth above 1 swaps in floor N's plan, car and Orderly.
#  - The run's deck (sim/places.gd): Clinic only unless one is given; the game (server/room.gd,
#    net/local_room.gd) gives Places.FULL. prepare() puts it on the run and makes floor N with it.
#  - run.gd wipes the run when its last active player is caught. The design says a catch is a wipe
#    only when the car is gone and nobody can call it; while the car is here or coming, a catch is
#    the "YOU WENT DOWN" placeholder and the player must still be able to finish the run. So when a
#    catch would wipe and the car was not 'away', the tick is re-run without the caught players to
#    recover the run's own phase, call and blink; the Orderly and crew are kept from the real tick
#    (the dropped tape, the dormant Orderly), and the players are put back on their feet ('ok').
#  - entity off: the run always has an Orderly. The host parks it, dormant for ever, where it starts.
#    On the Playroom the Minder's rules are off too (sim/run.gd seek_off): no count ever starts.
#  - The soft catch above is the Orderly's. A Playroom's found, taken and down players are not "caught"
#    events (sim/run.gd), so there a crew all found or down is a wipe, as playarea.md 12 says.
#  - A test may press the call button "from the landing" wherever the player stands (force_call).
#  - The day loop (sim/run.gd, docs/floors/prison.md P7): off unless asked (`days`); the game's rooms
#    (server/room.gd, net/local_room.gd) ask for it, so BANK rides up to the prison and bed starts the
#    next day. prepare() turns it on before the first tick. With the resident off, every new day's
#    resident is parked too.
#  - The floor quota (sim/run.gd quota, North Star C9): off unless asked (`quota`); the game's rooms ask
#    for it, so the call button does nothing until the crew has recorded enough on the floor. prepare()
#    turns it on before the first tick, after any depth above 1, so it is that floor's quota. With the
#    resident off nothing can ever be recorded, so the quota would lock the lift for good: it stays off.
#    Test-only: `quota=N` with `auto=1` caps every floor's quota at N (quota_cap_by_arg), so a scripted
#    playthrough (tools/play_quota.mjs) meets it with a reading or two.
#  - The Annex's marks and notes (sim/run.gd annex) are the run's own: the soft catch keeps them from the
#    real tick (the catch's note), and a forced call passes the mark and peel keys on like the rest.
#  - Down first, then out (sim/run.gd downs, North Star B6): off unless asked (`downs`); the game's rooms ask
#    for it, so a catch puts the player down where they stood for ten seconds, a crewmate holding F beside
#    them for three puts them back up, and otherwise they are out until the car next rides down. prepare()
#    turns it on before the first tick. With it on the run's own down replaces the soft catch above (a catch
#    is never a wipe on its own tick, so the soft catch never fires): a crew all out is a wipe, wherever the
#    car is, because nobody is left to board it.
#  - Two-watcher Stillness (sim/run.gd two_watchers, T19a): off unless asked (`watchers`); the game's server
#    room asks for it, so from three up players it takes two watchers to hold a Stillness resident. prepare()
#    turns it on before the first tick.
#  - Relocation (sim/run.gd relocation, sim/relocate.gd, T19e): off unless asked (`relocation`); the game's rooms
#    ask for it (the server's always, playing alone with the game's deck), so a resident may leave where nobody
#    can see it and arrive where nobody can, near a player. prepare() turns it on before the first tick.
#  - The owner's 17 Nov changes (sim/run.gd long_dark, paced, car_waits): off unless asked (`long_dark`,
#    `paced`, `car_waits`); the game's rooms ask for all three, so the blackout is longer, the tank is bigger
#    and the residents hunt faster to match, and the car waits for whoever is aboard, boards for 30 s and
#    leaves anyone out for the day. prepare() turns them on before the first tick.
#  - Lonely (sim/run.gd lonely, sim/lonely.gd, T19c): off unless asked (`lonely`); the game's rooms ask for it
#    (the server's always, playing alone with the game's deck), so the Annex's Temp carries its own mechanic
#    instead of Stillness. prepare() turns it on before the first tick.
#  - The Playroom tuned from the owner's first play (sim/run.gd playroom_tuned, sim/seek.gd T15m): off unless
#    asked (`playroom_tuned`); the game's rooms ask for it, so there are 30-45 s to hide, an anger bar, and the
#    Minder grabs anyone within 1 m outside a count. prepare() turns it on before the first tick.
#  - The Minder's hunt from the owner's playtest of 19 Nov (sim/run.gd minder_hunt, sim/seek.gd PT1): off unless
#    asked (`minder_hunt`, the last parameter); the game's rooms ask for it with the tuned Playroom, so the Minder
#    never acts on an instrument, angers sooner, and health drains only while it searches.
#  - The party table from the owner's words of 19 Nov (sim/run.gd party_table, sim/seek.gd "Party table", T15h):
#    off unless asked (`party_table_`, the last parameter, after another branch's `late_floors_`); the game's
#    rooms ask for it with the tuned Playroom, so a crewmate holding F at the table for 3 s frees everyone seated
#    (half the anger bar), the bar never cools by itself, and anyone still seated when the car leaves is left out.
#  - A second Orderly (sim/run.gd second_orderly, T9b): off unless asked (`second_orderly`, the last parameter,
#    after late_floors, party_table and tenant_timer, which are only stored here); the game's rooms ask for it, so a
#    Clinic at depth 2 or deeper has two Orderlies. prepare() turns it on last, and only with the resident on.
#  - The day quota's lock (sim/run.gd day_lock, FD2): off unless asked (`day_lock`, the last parameter); the
#    game's rooms ask for it together with the floor quota, so BANK is refused until the crew has earned the
#    day quota. prepare() turns it on before the first tick, and only when the run has days and the floor
#    quota (with nothing to record, or the test switch quota=0, it stays off and a short BANK is a missed
#    day as before). The soft catch keeps the day's earned from the real tick, like the floor's.
#  - Solid furniture (sim/run.gd furniture, sim/furniture.gd, FD7): off unless asked (`furniture`); the game's rooms
#    ask for it (the server's always, playing alone with the game's deck), so players slide along the Clinic's and
#    the Annex's chairs, beds, cabinets and desks instead of walking through them. prepare() turns it on before the
#    first tick.
#  - Findables (sim/run.gd findables, sim/findables.gd, FD9): off unless asked (`findables`, the last parameter); the
#    game's rooms ask for it (the server's always, playing alone with the game's deck), so the Clinic's and the
#    Annex's drawers, gurneys, lockers, copiers and boxes can be searched (F held) for credits, notes and cartons.
#    prepare() turns it on before the first tick. The soft catch keeps what was opened and found on the real tick.
#  - The four-slot inventory (sim/run.gd inventory, sim/inventory.gd, S1): off unless asked (`inventory`, the last
#    parameter); the game's rooms ask for it. prepare() turns it on before the first tick. The soft catch keeps the
#    bags and the pickups of the real tick (what the caught player carried fell where they were caught).
#  - The shop and the cabinet (sim/run.gd shop, sim/shop.gd, S2): off unless asked (`shop`, the last parameter); the
#    game's rooms ask for it, and it needs the inventory. prepare() turns it on before the first tick. The soft catch
#    keeps the cabinets, the lit things and the wallets of the real tick.
#  - The late floors (FL1, `late_floors`, the last parameter): off unless asked; the game's rooms ask for it with
#    the full deck. The host (net/host.gd enable_late_floors) then starts the Hanging Ward's overlay on arriving at
#    WARD_DEPTH and the Reactor's on arriving at REACTOR_DEPTH, each seeded from the day's floor seed. prepare() and
#    step() do nothing different: the overlays are the host's, exactly as their review starts are.
#  - The Tenant clock (TT1, the owner on 19 Nov: "a Timer that says Tenant arrives in: xx:xx, with a ten minute
#    timer per level"): off unless asked (`tenant_timer`, the last parameter); the game's rooms ask for it. On every
#    floor below the prison (not the prison, not a ride, not Practice) the clock starts the tick the doors open on
#    arrival, `tenant.minutes` (live setting, stamped then) long, in host time, and stops when the car rides on.
#    At zero, once a floor, the step adds "tenantArrived" {depth, quotaMet}: the clients slam a door and the
#    announcer says the time is up. Nothing else happens at zero (no catch, no phase change, the quota as it was);
#    _tenant_arrived is the one place a consequence goes later. The clock lives here, not in the run's state, so
#    with the flag off the run is exactly what it was; net/host.gd sends it as the world's "tenant" block.
#    `late_floors` and `party_table` are other pieces' flags, kept in plain fields and not read here.
#  - Cycles (FL2, `cycles`, the last parameter; docs/floors/difficulty.md section 1): off unless asked, and only with
#    the late floors; the game's rooms ask for it with them. The deck then carries Places.CYCLES, so floors repeat in
#    sevens (sim/places.gd), the Ward's lift rides down to the Reactor, the Reactor's return settles the day, and
#    each morning starts at the cycle the campaign has reached (sim/run.gd "Cycles"). A run made to start past
#    floor 7 (the floor picker's floor 8) counts the cycles before it as done.
#  - The late floors as places (RN1, `ward_place` then `reactor_place`, the last two parameters): off unless asked,
#    and only with the late floors. `ward_place` is another worker's flag, stored only. With `reactor_place` the deck
#    carries Places.REACTOR: floor 7 (and 14, 21 with cycles) is the generated station (sim/station.gd), its rules
#    stepped by the run itself (sim/run.gd "The Reactor", sim/station_floor.gd), and net/host.gd starts no overlay there.
#  - The pressures (DF1, `pressures`, the last parameter after `reactor_place`; docs/floors/difficulty.md section 2): off
#    unless asked, and only with cycles; the game's rooms ask for it with them (`pressures=0` switches it off). From
#    floor 8 the quotas grow, heals are counted, a Stillness resident needs a third watcher, the near light shrinks
#    and the Tenant comes sooner (sim/run.gd "Pressures"). Cycle 1 is unchanged.
#  - The Ward's call and web (WC1, `ward_call` then `ward_web`, the last two parameters after `pressures`): off unless
#    asked, and only with the late floors; the game's rooms ask for both (`ward_call=0`, `ward_web=0` switch them off).
#    Stored here; net/host.gd reads them as the Ward starts (sim/ward/state.gd `called` and `web`).
#  - The Ward's layout from the seed (WG1, `ward_layout`, after `ward_web`): off unless asked, and
#    only with the late floors. On, net/host.gd builds the Hanging Ward with sim/ward/layout.gd generate_v2 (the
#    houses' places, heights, facing and walkways from the floor seed) and its block carries the options, so every
#    screen builds the same; off, the Ward is today's for every seed.
#  - The Orderly fix (OR2, `orderly_fix`, after `ward_layout`; sim/run.gd "The Orderly fix"): off
#    unless asked; the game's rooms ask for it. The Orderly keeps walking as it reaches, a second Orderly chases
#    another player its own way round, and on the Clinic the Orderlies start in the dirty part, apart, by the seed.
#  - The owner's playtest of 20 Nov, the last three flags, after `orderly_fix` (each off unless asked; the game's rooms ask for all
#    three): `minder_calm` (MA1, sim/seek.gd "MA1": the Minder's anger never cools, hiding and opening things add to it,
#    and between counts it walks to a player it sees), `down_ring` (DR1, only with `downs`: a downed player has 30 s,
#    the live setting down.ring, before they are out) and `pn_fixes` (PN2: G with an empty hand puts down a carried
#    tape; PN3: the Annex's hides work under Lonely). prepare() turns them on before the first tick.
#  - The last one standing and the wipe (LS1, North Star B7; `last_stand`, after `pn_fixes`;
#    sim/last_stand.gd): off unless asked; the game's rooms ask for it. When one player of a crew of two or more is the only
#    one still up on a floor, the run marks the spotlight, and what that player records from the next tick on pays the
#    live setting last_stand.bonus more; a wipe keeps who and what made the last catch for every screen's scene and the
#    prison's standee. prepare() turns it on before the first tick. The soft catch keeps the re-run tick's own (no wipe).
#  - The elevator deal (ED1, `deal`, the parameter after `last_stand`; agreed tail ..., pn_fixes_, last_stand_,
#    deal_, split_): off unless asked; the game's rooms ask for it (`deal=0` switches it off). On each ride down to the
#    2nd to 5th floor of a cycle the host deals one card from the seed; the crew takes or passes it (sim/deal.gd,
#    sim/run.gd "The elevator deal"). prepare() turns it on before the first tick.
#  - Split reality (SR1, sim/split.gd, North Star E1 to E5; `split_`, after `deal`): off unless asked; the game's
#    rooms ask for it (`split=0` switches it off). prepare() gives the run its exposure state; step() steps it after
#    everything else, on the tick's own new state, so nothing the run decides (residents, catches, the instrument,
#    tapes, the quota) can see it. net/host.gd sends each player only their own exposure and false sights.
#  - PY1, `economy_fix`, the last parameter, after `split` (off unless asked; the game's rooms ask for it): pay and
#    quota by the floor's place in its cycle times the cycle's multiplier, credits kept at game over, the Reactor's
#    call panel says why it is refused, a player still hung in the Ward's web when its car leaves is left out for the
#    day, and Soft Shoes against the Rigger and the Reactor's four (sim/run.gd "PY1").
#  - VC1, `voice`, the last parameter, after `economy_fix` (off unless asked; the game's rooms ask for it, `voice=0`
#    switches it off): each player's microphone level (0 to 15, an input element; no audio is ever sent) becomes a noise
#    where they were, in three bands (noise.voice_whisper, voice_talk, voice_shout), heard by the Groundskeeper, the
#    Minder, the Rigger and the Reactor's four, each by its own live setting (0: deaf). sim/run.gd "VC1".
#  - RL1, `ward_lift_clear`, the parameter after `voice` (off unless asked, and only with `ward_layout`; the game's
#    rooms ask for it wherever they ask for the layout, `ward_lift_clear=0` switches it off). The owner, 21 Nov: "I'm ok
#    with making the lift never the lowest house". The Rigger lives below the lowest house; with this the generated
#    Ward never makes that the lift's own (sim/ward/layout.gd LIFT_CLEAR). Seeds where another house is already lower
#    are the same Ward. net/host.gd puts it in the layout's options, so the block carries it and every screen builds
#    the same Ward. The agreed tail: ..., voice_, ward_lift_clear_, ward_homes_ (WH1).
#  - WH1, `ward_homes`, the last parameter, after `ward_lift_clear` (off unless asked, and only with `ward_layout`; the game's rooms
#    ask for it only when started with `ward_homes=1`): the Hanging Ward's houses are built from six house types
#    (data/ward_homes.json, sim/ward/homes.gd) with rooms, furniture, inner doors and hiding places, and the Rigger's
#    arm bends round their walls and furniture by itself (sim/ward/house.gd, sim/ward/arm.gd). Run.with_ward_homes marks
#    the run; net/host.gd puts it in the Ward's layout options so every screen builds the same.
#  - ST1, `ward_stairs`, the last parameter, after `ward_homes` (off unless asked, and only with `ward_layout`; the game's
#    rooms ask for it wherever they ask for the layout, `ward_stairs=0` switches it off): a stair on the Hanging Ward has
#    a body. A walker cannot stand where a stair's underside is less than a standing player's eye height above their
#    feet unless they stand on it (sim/ward/house.gd stair_depth, sim/ward/state.gd walk_clear). net/host.gd puts it in
#    the layout's options ("stairs": 1), so the block carries it and every screen walks by the same rule.
#  - DG0, `dangers`, the last parameter, after `ward_stairs`: the enabled danger kinds (sim/dangers.gd), empty by
#    default, and then nothing changes anywhere. The game's rooms pass data/dangers.json's "enabled" (shipped empty)
#    or the start argument dangers=<kind,kind|all|0> (dangers_by_arg). prepare() gives the run its DangerFloor; step()
#    steps the base after the run's tick, before split reality; on the Hanging Ward net/host.gd calls step_dangers.
# Typed and immutable like godot/sim: a step never edits the state it was given.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Instr = preload("res://sim/instrument.gd")
const Settings = preload("res://sim/settings.gd")
const Split = preload("res://sim/split.gd")
const Dangers = preload("res://sim/dangers.gd")

## Where a player stands alone in the car at the start: the middle, so the doorway is straight ahead.
const START_U := Run.CAR_DEPTH / 2.0
## The late floors (FL1): the depth whose arrival starts the Hanging Ward, and the Reactor's. The one place these
## numbers live (net/host.gd, net/local_room.gd and the tests read them here).
const WARD_DEPTH := 6
const REACTOR_DEPTH := 7

## Catches turned from a wipe into the placeholder (see the header). (TypeScript: softCatches)
var soft_catches := 0
## Players put back on their feet since the glue last asked.
var revived: Array[String] = []
var _forced_id := ""
var _forced_body: Move.Body = null
var _entity_on: bool
var _depth: int
## The places the run's floors are drawn from.
var deck: Array[StringName]
## The day loop (off unless asked).
var days: bool
## The floor quota (off unless asked; never with the resident off).
var quota: bool
## Test-only: every floor's quota is at most this (0: no cap). See quota_cap_by_arg.
var _quota_cap := 0
## Down first, then out (off unless asked).
var downs: bool
## Two-watcher Stillness (off unless asked).
var watchers: bool
## Relocation (off unless asked).
var relocation: bool
## The owner's 17 Nov changes (off unless asked): the long dark, paced, the car waits.
var long_dark: bool
var paced: bool
var car_waits: bool
## Lonely, the Temp's own mechanic (off unless asked).
var lonely: bool
## The Playroom tuned from the owner's first play (off unless asked; sim/run.gd playroom_tuned, T15m).
var playroom_tuned: bool
## The day quota's lock (off unless asked; only with days and the floor quota both on).
var day_lock: bool
## Solid furniture (off unless asked; sim/run.gd furniture, FD7).
var furniture: bool
## Findables (off unless asked; sim/run.gd findables, FD9).
var findables: bool
## The four-slot inventory (off unless asked; sim/run.gd inventory, S1).
var inventory: bool
## Restored wall furniture (T20j), with solid furniture.
var furniture_layout: bool
## Residents route around the floor's shared solid footprints (off unless asked).
var resident_navigation: bool
## The shop and the cabinet (off unless asked; sim/run.gd shop, S2).
var shop: bool
var garden_cones: bool
var garden_search: bool
var deep_pockets: bool
var second_wind: bool
var soft_shoes: bool
var flare: bool
var lamp: bool
var badge_search: bool
var quick_fingers: bool
var doorway_shadow: bool
var long_burn: bool
var field_dressing: bool
var steady_gaze: bool
var throwing_arm: bool
var nerve_passive: bool
var annex_drag: bool
## The Minder's hunt from the owner's playtest of 19 Nov (off unless asked; sim/run.gd minder_hunt, PT1).
var minder_hunt: bool
## Another branch's flag (stored only here so the parameter order is agreed; this branch does nothing with it).
var late_floors: bool
## The party table from the owner's words of 19 Nov (off unless asked; sim/run.gd party_table, T15h).
var party_table: bool
## A second Orderly on deeper Clinic floors (off unless asked; sim/run.gd second_orderly, T9b).
var second_orderly: bool
## Cycles (FL2, see the header). On only together with the late floors.
var cycles: bool
## WN1: the Hanging Ward as a normal level. On, the main scene draws and plays floor 6 itself (client/main.gd,
## client/ward/floor.gd) and never swaps to client/ward/review.tscn; the host marks the Ward's snapshot block
## `native`. The rules of the Ward do not change. On only together with the late floors. Off: FL1's swap.
var ward_place: bool
## The Reactor as a place (RN1, the last parameter; sim/station.gd, sim/station_floor.gd): off unless asked, and only
## with the late floors; the game's rooms ask for it with them. The deck then carries Places.REACTOR, so floor 7 (14,
## 21 with cycles) is the generated station with its rules in the run, and the host starts no Reactor overlay there.
var reactor_place: bool
## The pressures of floor 8 and deeper (DF1, the last parameter; sim/run.gd "Pressures"): off unless asked, and only
## with cycles. The game's rooms ask for it with the late floors unless started with `pressures=0`.
var pressures: bool
## WC1: the Hanging Ward's lift called from a far house (the last parameter but one; sim/ward/state.gd `called`, net/host.gd
## _step_ward_review): no clock; the car comes, boards and goes up or down by every floor's rules (sim/run.gd _step_lift),
## called from the station; the call is a noise the Rigger hears. The live setting ward.lift_clock brings the clock back.
## Off unless asked, and only with the late floors and the Ward as a normal level (ward_place); the game's rooms ask for it (`ward_call=0`).
var ward_call: bool
## WC1: the web (the last parameter; sim/ward/state.gd `web`): a caught player is hung at a hang point and a crewmate's
## loud cut frees them. Off unless asked, and only with the late floors; the game's rooms ask for it (`ward_web=0`).
var ward_web: bool
## RR1: the Rigger as a solid creature (the last parameter; sim/ward/roam.gd): he crawls the Ward's surfaces on his own
## graph, reaches in by any window or door, and chases a player who is too loud out of doors. Off unless asked, and
## only with the late floors. The game's rooms ask for it unless started with `rigger_roam=0` (rigger_roam_by_arg).
var rigger_roam: bool
## WG1: the Ward's layout from the seed (see the header; the parameter after ward_web_). Read by net/host.gd ward_layout().
var ward_layout: bool
## The Orderly fix (OR2, the parameter after ward_layout_; sim/run.gd with_orderly_fix): off unless asked. The game's rooms ask for
## it: the Orderly keeps coming as it swipes, a second chases another player its own way, and both start in the
## Clinic's dirty part.
var orderly_fix: bool
## The owner's playtest of 20 Nov (see the header; the last three parameters, after orderly_fix_): MA1, DR1 (only with downs), PN2 and PN3.
var minder_calm: bool
var down_ring: bool
var pn_fixes: bool
## LS1, the last one standing and the wipe (North Star B7; the parameter after pn_fixes_; sim/last_stand.gd).
var last_stand: bool
## ED1: the elevator deal (see the header; after last_stand_).
var deal: bool
## Split reality (SR1; see the header). Off unless asked.
var split: bool
## PY1 (the last parameter, after `split_`): see the header.
var economy_fix: bool
## VC1, the microphone (the last parameter, after economy_fix_; see the header).
var voice: bool
## RL1, the lift's house never the lowest (after voice_; see the header). Only with ward_layout.
var ward_lift_clear: bool
## WH1, the Ward's real homes (the last parameter, after ward_lift_clear_; see the header).
var ward_homes: bool
## ST1, a stair's body on the Ward (the last parameter, after ward_homes_; see the header). Only with ward_layout.
var ward_stairs: bool
## DG0, the enabled danger kinds (the last parameter, after ward_stairs_; see the header). Empty: off.
var dangers: Array[StringName] = []
var nightly_reels: bool
var orientation := false
var orientation_prelude := false
## Other pieces' flags (stored only; this file does not read them).
## The Tenant clock (TT1; see the header). Off unless asked.
var tenant_timer: bool
## The game's length of the clock (minutes), the live setting `tenant.minutes` when the host has changed it.
const TENANT_MINUTES := 10
## This floor's clock: host time the Tenant arrives (-1: no clock on this floor), its length in seconds, the
## floor it runs on (depth and day), and whether the moment has come.
var tenant_at := -1.0
var tenant_len := 0.0
var tenant_depth := -1
var tenant_day := -1
var tenant_fired := false
## Tests: how many times the moment came (one a floor).
var tenant_arrivals := 0

func _init(entity_on: bool, depth: int, deck_: Array = [], days_: bool = false, quota_: bool = false, downs_: bool = false,
		watchers_: bool = false, relocation_: bool = false, long_dark_: bool = false, paced_: bool = false, car_waits_: bool = false,
		lonely_: bool = false, playroom_tuned_: bool = false, day_lock_: bool = false, furniture_: bool = false, findables_: bool = false,
		inventory_: bool = false, furniture_layout_: bool = false, resident_navigation_: bool = false,
		shop_: bool = false, nightly_reels_: bool = false, garden_cones_: bool = false, garden_search_: bool = false,
		deep_pockets_: bool = false, second_wind_: bool = false, soft_shoes_: bool = false, flare_: bool = false, lamp_: bool = false, badge_search_: bool = false, quick_fingers_: bool = false, long_burn_: bool = false, field_dressing_: bool = false, doorway_shadow_: bool = false, steady_gaze_: bool = false, throwing_arm_: bool = false,
		nerve_passive_: bool = false, annex_drag_: bool = false, minder_hunt_: bool = false, late_floors_: bool = false,
		party_table_: bool = false, tenant_timer_: bool = false, second_orderly_: bool = false, cycles_: bool = false,
		ward_place_: bool = false, reactor_place_: bool = false, pressures_: bool = false, ward_call_: bool = false,
		ward_web_: bool = false, rigger_roam_: bool = false, ward_layout_: bool = false, orderly_fix_: bool = false,
		minder_calm_: bool = false, down_ring_: bool = false, pn_fixes_: bool = false, last_stand_: bool = false,
		deal_: bool = false, split_: bool = false, economy_fix_: bool = false, voice_: bool = false,
		ward_lift_clear_: bool = false, ward_homes_: bool = false, ward_stairs_: bool = false, dangers_: Variant = []) -> void:
	# DG0: a caller that fills every parameter with false (tests that build the list by name) means none.
	dangers = Dangers.resolve(dangers_) if dangers_ is Array else ([] as Array[StringName])
	voice = voice_
	ward_lift_clear = ward_lift_clear_ and ward_layout_ and late_floors_
	# WH1: only with the Ward laid out from the seed (the homes need its cells).
	ward_homes = ward_homes_ and ward_layout_ and late_floors_
	# ST1: only with the Ward laid out from the seed (its options carry the rule to every screen).
	ward_stairs = ward_stairs_ and ward_layout_ and late_floors_
	last_stand = last_stand_
	deal = deal_
	split = split_
	orderly_fix = orderly_fix_
	economy_fix = economy_fix_
	minder_calm = minder_calm_
	down_ring = down_ring_ and downs_
	pn_fixes = pn_fixes_
	ward_place = ward_place_ and late_floors_
	ward_layout = ward_layout_ and late_floors_
	rigger_roam = rigger_roam_ and late_floors_
	# Both need the Ward drawn by the main game (ward_place): the old swapped-in Ward has neither the station nor the web.
	ward_call = ward_call_ and ward_place
	ward_web = ward_web_ and ward_place
	pressures = pressures_ and cycles_ and late_floors_
	tenant_timer = tenant_timer_
	reactor_place = reactor_place_ and late_floors_
	minder_hunt = minder_hunt_
	late_floors = late_floors_
	party_table = party_table_
	second_orderly = second_orderly_
	cycles = cycles_ and late_floors_
	garden_cones = garden_cones_
	garden_search = garden_search_
	deep_pockets = deep_pockets_
	second_wind = second_wind_
	soft_shoes = soft_shoes_
	flare = flare_
	lamp = lamp_
	badge_search = badge_search_
	quick_fingers = quick_fingers_
	long_burn = long_burn_
	field_dressing = field_dressing_
	doorway_shadow = doorway_shadow_
	steady_gaze = steady_gaze_
	throwing_arm = throwing_arm_
	nerve_passive = nerve_passive_
	annex_drag = annex_drag_
	nightly_reels = nightly_reels_
	shop = shop_
	inventory = inventory_
	findables = findables_
	furniture_layout = furniture_layout_
	resident_navigation = resident_navigation_
	playroom_tuned = playroom_tuned_
	furniture = furniture_
	relocation = relocation_
	lonely = lonely_
	day_lock = day_lock_
	_entity_on = entity_on
	_depth = depth
	deck = Places.with_cycles(Run.deck_of(deck_)) if cycles else Run.deck_of(deck_)
	if reactor_place:
		deck = Places.with_reactor(deck)
	days = days_
	quota = quota_
	_quota_cap = quota_cap_by_arg() if quota_ else 0
	downs = downs_
	watchers = watchers_
	long_dark = long_dark_
	paced = paced_
	car_waits = car_waits_

## Named opt-in for a host's standalone practice room.
func enable_orientation() -> void:
	orientation = true
	deck = Places.ORIENTATION_ONLY

## Explicit candidate route before a normal paid campaign begins.
func enable_orientation_prelude() -> void:
	orientation_prelude = _depth == 1 and days and _entity_on

## Where player `i` of `n` stands in the car at the start (car-local u, v).
static func start_spot(i: int, n: int) -> PackedFloat64Array:
	if n <= 1:
		return PackedFloat64Array([START_U, 0.0])
	var spots: Array[PackedFloat64Array] = [
		PackedFloat64Array([1.3, -1.0]), PackedFloat64Array([1.3, 1.0]),
		PackedFloat64Array([2.7, -1.0]), PackedFloat64Array([2.7, 1.0]),
	]
	return spots[i % spots.size()]

static func start_body(car: Run.CarGeometry, i: int, n: int) -> Move.Body:
	var uv := start_spot(i, n)
	return Run.car_body(car, uv[0], uv[1])

## A dormant Orderly that never wakes, standing where the floor's Orderly would start (the floor's own
## resident, in its own body).
static func parked_orderly(state: Run.RunState) -> Entity.OrderlyState:
	var o := Places.create_resident(state.plan)
	o.mode = &"dormant"
	o.dormant_left = INF
	return o

## The first state of a run (create_run's, adjusted).
func prepare(s0: Run.RunState) -> Run.RunState:
	if orientation:
		var practice := Run.with_flare(s0) if flare else s0
		return Run.with_orientation(Run.with_lamp(practice) if lamp else practice)
	var s := s0
	if s.deck != deck:
		s = s.copy()
		s.deck = deck
	if days and not s.days:
		s = Run.with_days(s)
	if _depth > 1:
		var plan := Places.generate(s.seed, _depth, deck, garden_search and (findables or s.findables))
		s = s.copy()
		s.depth = _depth
		s.plan = plan
		s.car = Run.car_geometry(plan)
		s.orderly = Places.create_resident(plan)
		s.entity_id = Places.entity_id(plan.place, _depth)
	var n := s.players.size()
	var bodies := {}
	for i in n:
		bodies[s.players[i].id] = start_body(s.car, i, n)
	s = s.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		if bodies.has(p.id):
			np.body = bodies[p.id]
		players.append(np)
	s.players = players
	if _depth > 1:
		var c := s.crew.copy()
		var members: Array[Instr.CrewMember] = []
		for m in s.crew.members:
			var nm := m.copy()
			nm.body = bodies[m.id] if bodies.has(m.id) else null
			members.append(nm)
		c.members = members
		s = s.copy()
		s.crew = c
	if not _entity_on:
		s = s.copy()
		s.orderly = parked_orderly(s)
		# The Playroom's Minder too: no count, no search (sim/run.gd seek_off).
		s.seek_off = true
	# DF1: before the quota, so a run made to start below floor 7 has its first floor's quota with the pressure.
	if pressures and not s.pressures:
		s = Run.with_pressures(s)
	# PY1: before the quota too, so the first floor's quota is the new rule's.
	if economy_fix and not s.economy_fix:
		s = Run.with_economy_fix(s)
	# VC1: a player's microphone level becomes a noise where they were (sim/run.gd "VC1").
	if voice and not s.voice:
		s = Run.with_voice(s)
	# WH1: the Ward's homes (net/host.gd reads this flag as the Ward starts).
	if ward_homes and not s.ward_homes:
		s = Run.with_ward_homes(s)
	# DG0: the dangers (sim/dangers.gd); nothing at all with none enabled.
	if not dangers.is_empty() and s.dangers == null:
		s = Dangers.with_dangers(s, dangers)
	if quota and _entity_on and not s.quota:
		s = Run.with_quota(s)
	if downs and not s.downs:
		s = Run.with_downs(s)
	if watchers and not s.two_watchers:
		s = Run.with_two_watchers(s)
	if relocation and not s.relocation:
		s = Run.with_relocation(s)
	if long_dark and not s.long_dark:
		s = Run.with_long_dark(s)
	if paced and not s.paced:
		s = Run.with_paced(s)
	if car_waits and not s.car_waits:
		s = Run.with_car_waits(s)
	if lonely and not s.lonely:
		s = Run.with_lonely(s)
	if playroom_tuned and not s.playroom_tuned:
		s = Run.with_playroom_tuned(s)
	if minder_hunt and not s.minder_hunt:
		s = Run.with_minder_hunt(s)
	if party_table and not s.party_table:
		s = Run.with_party_table(s)
	if minder_calm and not s.minder_calm:
		s = Run.with_minder_calm(s)
	if down_ring and s.downs and not s.down_ring:
		s = Run.with_down_ring(s)
	if pn_fixes and not s.pn_fixes:
		s = Run.with_pn_fixes(s)
	if last_stand and not s.last_stand:
		s = Run.with_last_stand(s)
	if deal and s.deal == null:
		s = Run.with_deal(s)
	# SR1: exposure starts at nothing for everyone.
	if split and s.split == null:
		s = Split.with_split(s)
	# The day lock needs something to earn: only with days and the floor quota on (so never with the
	# resident off, and never with the test switch quota=0).
	if day_lock and s.days and s.quota and not s.day_lock:
		s = Run.with_day_lock(s)
	if furniture and not s.furniture:
		s = Run.with_furniture(s)
	if furniture_layout and s.furniture and not s.furniture_layout:
		s = Run.with_furniture_layout(s)
	if findables and not s.findables:
		s = Run.with_findables(s)
	if inventory and not s.inventory:
		s = Run.with_inventory(s)
	if resident_navigation and not s.resident_navigation:
		s = Run.with_resident_navigation(s)
	if shop and s.inventory and not s.shop:
		s = Run.with_shop(s)
	if deep_pockets and s.shop and s.days and not s.deep_pockets:
		s = Run.with_deep_pockets(s)
	if second_wind and s.deep_pockets and not s.second_wind:
		s = Run.with_second_wind(s)
	if soft_shoes and s.deep_pockets and not s.soft_shoes:
		s = Run.with_soft_shoes(s)
	if garden_cones and deck.has(Places.ARBORETUM) and s.inventory and not s.garden_cones:
		s = Run.with_garden_cones(s)
	if garden_search and deck.has(Places.ARBORETUM) and s.findables and not s.garden_search:
		s = Run.with_garden_search(s)
	if doorway_shadow:
		s = s.copy()
		s.doorway_shadow = true
	if badge_search:
		s = Run.with_badge_search(s)
	if long_burn:
		s = Run.with_long_burn(s)
	if steady_gaze:
		s = Run.with_steady_gaze(s)
	if throwing_arm:
		s = Run.with_throwing_arm(s)
	if annex_drag and not s.annex_drag:
		s = Run.with_annex_drag(s)
	if nerve_passive and not s.nerve_passive:
		s = s.copy()
		s.nerve_passive = true
	if field_dressing:
		s = Run.with_field_dressing(s)
	if quick_fingers:
		s = Run.with_quick_fingers(s)
	if nightly_reels and s.days:
		s = Run.with_nightly_reels(s)
	if flare:
		s = Run.with_flare(s)
	if lamp:
		s = Run.with_lamp(s)
	# A second Orderly (T9b): last, so its start settles with every other rule already on. Never with the resident off.
	if second_orderly and _entity_on and not s.second_orderly:
		s = Run.with_second_orderly(s)
	# OR2: after the second, so both Orderlies' starts are the fix's.
	if orderly_fix and _entity_on and not s.orderly_fix:
		s = Run.with_orderly_fix(s)
	if cycles and _depth > Places.CYCLE_FLOORS:
		# A run started past the first cycle (the floor picker's floor 8): the cycles above it count as done.
		s = s.copy()
		s.cycles_done = Places.cycle_of(_depth) - 1
	s = _capped(s)
	if reactor_place and s.plan != null and s.plan.place == Places.REACTOR:
		# RN1: a run made to start on the station (the floor picker's floor 7) has its state before the first tick,
		# so the first snapshot already carries its block.
		s = s.copy()
		Run._sync_station(s)
	if not orientation_prelude:
		return s
	# VC3: the prelude is a fresh run of its own; with the voice on it has the voice too (meter and noise alike).
	var o := Run.with_orientation(s, true)
	return Run.with_voice(o) if voice else o

## SR1: split reality unless `split=0` (an argument after `--`, or the web page's ?split=0).
static func split_on_by_arg() -> bool:
	return not _arg_off("split")

static func doorway_shadow_on_by_arg() -> bool:
	return not OS.get_cmdline_user_args().has("doorway_shadow=0")

## RN1: the Reactor as a place. IP1: always. `reactor_place=0` (an argument after `--`, or the web page's
## ?reactor_place=0) once swapped in the old compiled room, which is no longer in the game; asked for, it is
## refused with a log line and the Reactor stays the place the main game draws (never a blank screen).
static func reactor_place_by_arg() -> bool:
	var asked := false
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == "reactor_place=0":
			asked = true
	if not asked and OS.has_feature("web"):
		asked = str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('reactor_place') ?? ''", true)) == "0"
	if asked:
		print("reactor_place=0 ignored: the old Reactor room is not in this build; the Reactor is drawn by the main game")
	return true

## DF1: the pressures unless `pressures=0` (an argument after `--`, or the web page's ?pressures=0).
static func pressures_by_arg() -> bool:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == "pressures=0":
			return false
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('pressures') ?? ''", true)) != "0"
	return true

## RR1: the solid, crawling Rigger unless `rigger_roam=0` (an argument after `--`, or the web page's ?rigger_roam=0)
## brings back the Rigger who climbs straight up to a house. On by default since the bot crews record and get home with
## it as often as without it, on fixed and generated layouts (tests/prop_rigger_quota.gd).
static func rigger_roam_by_arg() -> bool:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == "rigger_roam=0":
			return false
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('rigger_roam') ?? ''", true)) != "0"
	return true

static func garden_admission_by_arg() -> bool:
	return not OS.get_cmdline_user_args().has("garden_admission=0")

## WC1: the Ward's call and web unless `ward_call=0` / `ward_web=0` (an argument after `--`, or the web page's query).
static func ward_call_by_arg() -> bool:
	return not _arg_off("ward_call")

static func ward_web_by_arg() -> bool:
	return not _arg_off("ward_web")

## ED1: the elevator deal is on in the game's rooms unless started with `deal=0`.
static func deal_by_arg() -> bool:
	return not _arg_off("deal")

## PY1: on unless the game was started with `economy_fix=0` (or `?economy_fix=0` on the web page).
static func economy_fix_by_arg() -> bool:
	return not _arg_off("economy_fix")

## VC1: the microphone counts in the game's rooms unless started with `voice=0` (or `?voice=0` on the web page).
static func voice_by_arg() -> bool:
	return not _arg_off("voice")

## RL1: the lift's house is never the lowest in the game's rooms unless started with `ward_lift_clear=0` (or
## `?ward_lift_clear=0` on the web page).
static func ward_lift_clear_by_arg() -> bool:
	return not _arg_off("ward_lift_clear")

## WH1: the Ward's homes only when the game was started with `ward_homes=1` (off by default for now).
static func ward_homes_on_by_arg() -> bool:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == "ward_homes=1":
			return true
	return false

## DG0: the enabled danger kinds for the game's rooms: the start argument `dangers=<kind,kind|all|0>` (after `--`, or the
## web page's ?dangers=) when given, else data/dangers.json "enabled" (shipped empty). Kept to kinds with a file.
static func dangers_by_arg() -> Array[StringName]:
	var asked: Variant = null
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("dangers="):
			asked = a.substr(8)
	if asked == null and OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('dangers') ?? ''", true))
		if q != "":
			asked = q
	if asked == null:
		return Dangers.data_enabled()
	return Dangers.resolve(str(asked).split(",", false))

## DG0 on the Hanging Ward (net/host.gd, after the Ward's tick): the dangers' step with the Ward's rules object.
func step_dangers(state: Run.RunState, inputs: Array[Run.PlayerInput], dt: float, events: Array[Dictionary], ward: Variant) -> void:
	if state.dangers != null:
		Dangers.step(state, inputs, dt, events, ward)

## ST1: a stair has a body in the game's rooms unless started with `ward_stairs=0` (or `?ward_stairs=0` on the web page).
static func ward_stairs_by_arg() -> bool:
	return not _arg_off("ward_stairs")

static func _arg_off(name: String) -> bool:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == name + "=0":
			return true
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') ?? ''" % name, true)) == "0"
	return false

## WN1: `ward_place=0` on the command line falls back to FL1's scene swap for the Ward (no new build needed).
static func ward_place_off_by_arg() -> bool:
	return OS.get_cmdline_user_args().has("ward_place=0")

static func flare_on_by_arg() -> bool:
	return OS.get_cmdline_user_args().has("flare=1")

static func lamp_on_by_arg() -> bool:
	return OS.get_cmdline_user_args().has("lamp=1")

static func annex_drag_on_by_arg() -> bool:
	return OS.get_cmdline_user_args().has("annex_drag=1")

static func nerve_passive_on_by_arg() -> bool:
	return OS.get_cmdline_user_args().has("nerve_passive=1")

## Test-only: `quota=N` (a whole number above 0, as a desktop or server argument after `--` or the web
## page's ?quota=N), honoured only together with `auto=1`: every floor's quota is at most N credits, so a
## scripted playthrough (tools/play_quota.mjs) can meet it with a reading or two. 0 when not asked.
static func quota_cap_by_arg() -> int:
	var cap := 0
	var auto := false
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("quota=") and a.substr(6).is_valid_int():
			cap = int(a.substr(6))
		auto = auto or a == "auto=1"
	if OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('quota') ?? ''", true))
		var au := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('auto') ?? ''", true))
		if q.is_valid_int():
			cap = int(q)
		auto = auto or au == "1"
	return cap if auto and cap > 0 else 0

## The state with this floor's quota at most the test cap (unchanged without one).
func _capped(s: Run.RunState) -> Run.RunState:
	if _quota_cap <= 0 or not s.quota or s.floor_needed <= _quota_cap:
		return s
	var c := s.copy()
	c.floor_needed = _quota_cap
	return c

## Test-only, and THE one reader of the floor a run starts on: runs start on floor N of the deck, so a check
## or a look at a deep place (the Arboretum is floor 5) need not ride down to it. 1 when not asked. Two
## spellings reach it, and both end as a room's first depth (server/room.gd `first_depth`, the depth
## net/local_room.gd gives its rules):
##  - a dedicated server (`server` true: server/server.gd): its argument `depth=N`, alone
##    (tools/exported_server_check.mjs passes depth=3);
##  - a client playing alone (`server` false: net/local_room.gd): `floor=N` (a desktop argument after `--`, or the
##    web page's ?floor=N), honoured only together with `auto=1`.
## Kept to the deck's fixed floors (sim/places.gd FIXED), whichever spelling asked.
static func start_depth_by_arg(server := false) -> int:
	var depth := 1
	var auto := server
	var key := "depth=" if server else "floor="
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with(key) and a.substr(key.length()).is_valid_int():
			depth = int(a.substr(key.length()))
		auto = auto or a == "auto=1"
	if not server and OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('floor') ?? ''", true))
		var au := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('auto') ?? ''", true))
		if q.is_valid_int():
			depth = int(q)
		auto = auto or au == "1"
	return clampi(depth, 1, Places.FIXED.size() - 1) if auto else 1

## Test-only: whether this server was started with `watchers=0` (an argument after `--`): Stillness is then
## held by one look at any crew size, as before T19a (tools/net_local.mjs; server/room.gd).
static func watchers_off_by_arg() -> bool:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == "watchers=0":
			return true
	return false

## Test-only: whether this process was started with the floor quota turned off, `quota=0` (a desktop or
## server argument after `--`, or the web page's ?quota=0). The scripted playthroughs (tools/play_*.mjs)
## pass it so their one reading is enough to call the lift; the quota itself is proved headless
## (tests/prop_quota_net.gd). `need_auto`: honoured only together with `auto=1` (the game's automation
## flag), so a player cannot turn it off by accident in a normal game.
static func quota_off_by_arg(need_auto: bool) -> bool:
	var off := false
	var auto := false
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		off = off or a == "quota=0"
		auto = auto or a == "auto=1"
	if OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('quota') ?? ''", true))
		var au := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('auto') ?? ''", true))
		off = off or q == "0"
		auto = auto or au == "1"
	return off and (auto or not need_auto)

## Tests: the next tick presses the call button for `id` from `body`.
func force_call(id: String, body: Move.Body) -> void:
	_forced_id = id
	_forced_body = body

## One tick of the run, with the rules above.
func step(before: Run.RunState, raw: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
	var inputs := raw
	if _forced_body != null:
		var fid := _forced_id
		var fbody := _forced_body
		_forced_id = ""
		_forced_body = null
		inputs = []
		for i in raw:
			if i.id == fid:
				var ni := _copy_input(i)
				ni.body = Move.Body.make(fbody.x, fbody.z, fbody.level, fbody.y)
				ni.call = true
				inputs.append(ni)
			else:
				inputs.append(i)
	var r := Run.step_run(before, inputs, dt)
	var events := r.events
	var caught := {}
	var wiped := false
	for e in events:
		if e["type"] == "caught":
			caught[str(e["playerId"])] = true
		elif e["type"] == "wiped":
			wiped = true
	if not caught.is_empty() and wiped and before.phase != &"away":
		# Not a wipe by the design's rule: the car is here or coming. See the header.
		var kept: Array[Run.PlayerInput] = []
		for i in inputs:
			if not caught.has(i.id):
				kept.append(i)
		var alt := Run.step_run(before, kept, dt)
		var players: Array[Run.RunPlayer] = []
		for p in r.state.players:
			if caught.has(p.id):
				var np := p.copy()
				np.status = &"ok"
				players.append(np)
			else:
				players.append(p)
		var st := alt.state.copy()
		st.orderly = r.state.orderly
		st.orderly2 = r.state.orderly2
		st.flare_stun2_until = r.state.flare_stun2_until
		st.crew = r.state.crew
		# The floor quota goes with the crew: the victim's reading closed as they were caught counts.
		st.floor_earned = r.state.floor_earned
		st.floor_by = r.state.floor_by
		st.floor_needed = r.state.floor_needed
		st.quota_met = r.state.quota_met
		st.nerve_readings = r.state.nerve_readings
		# The day's earned likewise (FD2), and whether "dayMet" was said.
		st.day_earned = r.state.day_earned
		st.day_met = r.state.day_met
		# The Annex's marks and notes too: the catch's note was triggered by the real tick.
		st.annex = r.state.annex
		# The Reactor (RN1): the station's tick that caught them.
		st.station = r.state.station
		st.note_seq = r.state.note_seq
		# Findables (FD9): what was opened and found on the real tick (the credits ride on its crew's tapes).
		st.find = r.state.find
		st.lore_used = r.state.lore_used
		st.items = r.state.items
		# The inventory (S1): the bags and pickups of the real tick.
		st.bags = r.state.bags
		st.pickups = r.state.pickups
		st.pickups_plan = r.state.pickups_plan
		st.pickup_seq = r.state.pickup_seq
		# The shop (S2): the cabinets, what was lit, and what was bought, of the real tick.
		if st.shop:
			st.shop_state = r.state.shop_state
		if r.state.garden_cones or r.state.garden_search:
			st.garden = r.state.garden
			st.wallets = r.state.wallets
		st.players = players
		st.summary = null
		var kept_events: Array[Dictionary] = []
		for e in events:
			if e["type"] != "wiped":
				kept_events.append(e)
		events = kept_events
		r = Run.RunStep.new()
		r.state = st
		r.events = events
		soft_catches += 1
		for id: String in caught:
			revived.append(id)
	var state := r.state
	if state.doorway_shadow:
		Run.step_doorway_shadow(state, inputs, dt, events)
	if not _entity_on:
		for e in events:
			if e["type"] == "rodeDown" or e["type"] == "newDay":
				state = state.copy()
				state.orderly = parked_orderly(state)
				break
	# DG0: the dangers, on the tick's new state (sim/dangers.gd step).
	if state.dangers != null:
		state = state.copy() if state == before else state
		Dangers.step(state, inputs, dt, events)
	# SR1: last, on the tick's new state; it reads the run and writes only state.split.
	if state.split != null:
		Split.step(state, inputs, dt, events)
	var out := Run.RunStep.new()
	out.state = _capped(state)
	out.events = events
	if tenant_timer:
		_step_tenant(out.state, out.events)
	return out

## Whether floor `s` runs the Tenant clock: below the prison, never the prison itself or Practice.
static func tenant_floor(s: Run.RunState) -> bool:
	return s.depth >= 1 and not s.orientation and not Run.at_home(s)

## The Tenant clock after a tick (see the header): started as the doors open on arrival, stopped when the car
## rides on (or the run is somewhere else), and the moment once a floor at zero.
func _step_tenant(s: Run.RunState, events: Array[Dictionary]) -> void:
	for e in events:
		if e["type"] == "doorsOpened" and str(e.get("reason", "")) == "arrival" and tenant_floor(s):
			# The length is stamped now: a change to the setting mid-floor waits for the next floor.
			tenant_len = 60.0 * Run.pressure_tenant_minutes(s, Settings.i(s.tuning, &"tenant.minutes", TENANT_MINUTES))
			tenant_at = s.t + tenant_len
			tenant_depth = s.depth
			tenant_day = s.day_index
			tenant_fired = false
	if tenant_at >= 0.0 and (s.phase == &"riding" or s.phase == &"ended" or s.depth != tenant_depth or s.day_index != tenant_day or not tenant_floor(s)):
		tenant_at = -1.0
		tenant_fired = false
	if tenant_at >= 0.0 and not tenant_fired and s.t >= tenant_at - 1e-6:
		tenant_fired = true
		tenant_arrivals += 1
		events.append({"type": "tenantArrived", "t": s.t, "depth": s.depth, "quotaMet": Run.quota_reached(s)})
		_tenant_arrived(s, events)

## The one place for what the Tenant does when it arrives. Today nothing: the owner asked only for the clock, a
## door slam and the line (TT1). A consequence added here changes the state of the tick that `s` is.
func _tenant_arrived(_s: Run.RunState, _events: Array[Dictionary]) -> void:
	pass

## The world's "tenant" block for run state `s` (net/host.gd): {at (host time the Tenant arrives), len (the
## clock's seconds)}, or null when there is no clock on this floor (the flag off, the prison, Practice, a ride).
func tenant_block(s: Run.RunState) -> Variant:
	if not tenant_timer or tenant_at < 0.0 or s.depth != tenant_depth or s.day_index != tenant_day or not tenant_floor(s):
		return null
	return {"at": tenant_at, "len": tenant_len}

static func _copy_input(i: Run.PlayerInput) -> Run.PlayerInput:
	var n := Run.PlayerInput.make(i.id, i.body, i.eye, i.yaw, i.pitch, i.h_fov_deg, i.v_fov_deg)
	n.call = i.call
	n.hold_doors = i.hold_doors
	n.raised = i.raised
	n.pick_up = i.pick_up
	n.blind = i.blind
	n.blind_first = i.blind_first
	n.blind_second = i.blind_second
	n.use = i.use
	n.gait = i.gait
	n.hide_use = i.hide_use
	n.hide_fast = i.hide_fast
	n.peek = i.peek
	n.emote_sound = i.emote_sound
	n.voice = i.voice
	n.horn = i.horn
	n.light = i.light
	n.mark = i.mark
	n.peel = i.peel
	n.search = i.search
	n.search_fast = i.search_fast
	n.inv_select = i.inv_select
	n.inv_op = i.inv_op
	n.inv_arg = i.inv_arg
	return n
