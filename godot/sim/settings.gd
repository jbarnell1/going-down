# Live settings: the host tunes the game while it runs (docs/floors/live-settings.md, piece LS1). Pure data
# and a checker: the same file is in the server and in every client. No rendering, no network, no files.
#
# Three things, three jobs:
#   - the registry (this file): every setting's id, group, section, name, what it changes, unit, the game's
#     value ("today"), least, most, step, and when a change takes hold (holds). The panel's order is the
#     order of ROWS below, group by group;
#   - the tuning (sim/run.gd RunState.tuning, a Values or null): what is in force in this run. The rules read
#     it with f() and i(), passing the constant they use today as the fallback, so a run given no tuning (or
#     an empty one, or one that does not name the id) computes with the very same constant by the very same
#     path. Replaced, never edited: Run.with_tuning(s, given) returns the copy;
#   - the desk (net/tuning_desk.gd, LS2): what the host has asked for. It checks every change with check()
#     and decides when each asked-for value goes into force.
#
# What LS2 (the desk, the file, the wire) and LS3 (the panel, the notice) call:
#   Settings.list(wired_only = false) -> Array[Setting]   every row in the panel's order (the panel passes
#                                                         true: a row nothing reads yet is left out)
#   Settings.row(id) -> Setting                           one row, or null for an unknown id
#   Settings.has(id) -> bool
#   Settings.today(id) -> float                           the game's value (what RESET puts back)
#   Settings.check(id, value, asked = {}) -> StringName   the only door: &"" when accepted, else the tuneNo
#                                                         reason: &"id" (unknown), &"range" (not a finite
#                                                         number, or under least / over most once snapped
#                                                         to the step), &"pair" (breaks a pair rule against
#                                                         `asked`, the other asked-for values {id: number})
#   Settings.snap(id, value) -> float                     the value on the setting's step (what is stored)
#   Settings.pair_broken(given) -> String                   "" or the panel's words for the first pair rule
#                                                         `given` ({id: number}, others at today's) breaks
#   Settings.differs(id, value) -> bool                   whether a value is not the game's (what the file
#                                                         and the "set" list keep)
#   Settings.text(id, value) -> String                    "3.60 M/S": the value at the step's decimals and
#                                                         the unit, as the panel and the notice print it
#   Settings.groups() / Settings.sections()               [{id, title}] and [{id, group, title}] in order
#   Settings.HOLDS_SHOWN                                  {holds: "NOW" | "NEXT TIME" | "NEXT FLOOR" | "TOMORROW"}
#   Settings.make(given) -> Values                          a tuning from {id: number} (as given: check first)
#   Settings.f(tuning, id, fallback) / Settings.i(...)    the rules' read (float / whole number)
#   Run.with_tuning(s, given) -> RunState                   (sim/run.gd) the run with this tuning in force
#
# When a change takes hold (the row's `holds`; the desk's business, the rules never ask):
#   &"now"    the next tick reads it;
#   &"next"   the number is stamped when its clock starts: a clock already running keeps its length
#             (the down timer is stamped in Downed.until, the lift's floors and seconds in the call's plan);
#   &"floor"  goes into force as the car leaves a floor (the desk holds it until carLeft);
#   &"day"    goes into force at lights out.
#
# Nothing in the fairness contract is here, and never will be: who counts as looking (Entity.GRACE, the seen
# outlines, sim/sight.gd), how many watchers hold a Stillness resident, the put-back and catch-confirm numbers
# in net/session.gd, and any number a floor plan or a hide list is made from (every player builds the floor
# from the seed: "identical for every player"). A setting never adds or removes a random draw.
#
# The rule for every new number from now on: it goes in ROWS in the piece that adds its reader, with `wired`
# true only once the rules read it and tests/prop_settings.gd has its proof.
extends RefCounted

## The four kinds of "when a change takes hold", as the panel shows them.
const HOLDS_SHOWN := {&"now": "NOW", &"next": "NEXT TIME", &"floor": "NEXT FLOOR", &"day": "TOMORROW"}

## The panel's groups, in order: [id, title].
const GROUPS: Array = [
	[&"residents", "RESIDENTS"],
	[&"lift", "THE LIFT AND THE DARK"],
	[&"players", "PLAYERS"],
	[&"earning", "EARNING"],
	[&"hiding", "HIDING"],
	# The owner, 17 Nov: player speeds come last.
	[&"speeds", "PLAYER SPEEDS"],
]

## The sections inside the groups, in order: [id, group, title].
const SECTIONS: Array = [
	[&"every", &"residents", "EVERY RESIDENT"],
	[&"orderly", &"residents", "THE ORDERLY (THE CLINIC)"],
	[&"temp", &"residents", "THE TEMP (THE ANNEX)"],
	[&"minder", &"residents", "THE MINDER (THE PLAYROOM)"],
	[&"groundskeeper", &"residents", "THE GROUNDSKEEPER (THE ARBORETUM)"],
	[&"tenant", &"residents", "THE TENANT (EVERY FLOOR)"],
	[&"lift", &"lift", "THE LIFT AND THE DARK"],
	[&"stamina", &"players", "STAMINA"],
	[&"down", &"players", "DOWN AND HEALING"],
	[&"health", &"players", "HEALTH (THE PLAYROOM)"],
	[&"carry", &"players", "CARRYING"],
	[&"shop", &"players", "THE SHOP AND THE CABINET"],
	[&"earning", &"earning", "EARNING"],
	[&"hiding", &"hiding", "HIDING"],
	[&"moving", &"speeds", "MOVING"],
]

## Whole numbers (read with i()): marked W in ROWS.
const W := true
const F := false

## The registry, in the panel's order. Each row:
##   [id, section, name shown, what it changes, unit, today (the game's value), least, most, step, holds,
##    the piece that wires it, whole number]
## "Today" is the game's value, the rooms' switches on (net/host_rules.gd: paced, the long dark, the car waits),
## not always the bare constant: tests/prop_settings.gd names the constant each one must equal.
const ROWS: Array = [
	# Residents: every resident.
	[&"resident.wind_up", &"every", "REACH TAKES", "from its reach starting to the catch: the window to turn and look", "s", 0.6, 0.3, 2.0, 0.1, &"next", &"LS4", F],
	[&"resident.rest", &"every", "RESTS AFTER A CATCH", "how long it stays quiet after catching someone", "s", 10.0, 3.0, 30.0, 1.0, &"next", &"LS4", F],
	[&"resident.wake_near", &"every", "WAKES WITHIN", "it starts hunting when a player comes this near", "m", 12.0, 6.0, 25.0, 1.0, &"now", &"LS4", F],
	[&"resident.wake_after", &"every", "WAKES ANYWAY AFTER", "it starts hunting this long after the doors open, whatever the crew does", "s", 60.0, 15.0, 180.0, 5.0, &"now", &"LS4", F],
	[&"reloc.rest", &"every", "MOVES AGAIN AFTER", "least time between two relocations", "s", 20.0, 5.0, 90.0, 5.0, &"now", &"LS4", F],
	[&"reloc.near_min", &"every", "ARRIVES NO NEARER THAN", "a relocation lands at least this far from the player it goes to", "m", 12.0, 6.0, 20.0, 1.0, &"now", &"LS4", F],
	[&"reloc.near_max", &"every", "ARRIVES NO FURTHER THAN", "and at most this far", "m", 20.0, 10.0, 35.0, 1.0, &"now", &"LS4", F],
	# The Orderly (the Clinic).
	[&"orderly.speed", &"orderly", "HUNT SPEED", "how fast it comes while nobody holds it", "m/s", 3.8, 2.4, 4.8, 0.05, &"now", &"LS1", F],
	[&"orderly.dark_speed", &"orderly", "SPEED IN THE BLACKOUT", "the same, while the lights are out before the car", "m/s", 3.8, 2.4, 4.8, 0.05, &"now", &"LS1", F],
	[&"orderly.catch_dance", &"orderly", "BELLY DANCE AFTER A CATCH", "dance after bending over a downed crewmate", "on/off", 0.0, 0.0, 1.0, 1.0, &"now", &"T20i", W],
	# The Temp (the Annex). Lonely (T19c, sim/lonely.gd) is on in the game's rooms: its chase speed is temp.speed
	# (temp.dark_speed in the blackout, temp.alone_speed with a crew of one), today's its CHASE_SPEED and
	# SOLO_CHASE_SPEED. Without Lonely (tests only) the Temp's Stillness hunt reads the same two ids.
	[&"temp.speed", &"temp", "HUNT SPEED", "how fast it chases a player who is alone", "m/s", 3.9, 2.4, 4.8, 0.05, &"now", &"LS1", F],
	[&"temp.dark_speed", &"temp", "SPEED IN THE BLACKOUT", "the same, while the lights are out before the car", "m/s", 3.9, 2.4, 4.8, 0.05, &"now", &"LS1", F],
	[&"temp.alone_speed", &"temp", "HUNT SPEED, PLAYING ALONE", "its chase in a run of one player (slower than a walk)", "m/s", 2.6, 1.5, 4.5, 0.1, &"now", &"LS1", F],
	# The Minder (the Playroom).
	[&"minder.stroll", &"minder", "STROLL SPEED", "tidying, outside a count", "m/s", 1.2, 0.6, 2.0, 0.1, &"now", &"LS4", F],
	[&"minder.search_speed", &"minder", "SEARCH SPEED", "going from hide to hide in a count", "m/s", 3.0, 1.5, 4.5, 0.1, &"now", &"LS1", F],
	[&"minder.run_speed", &"minder", "RUN SPEED", "running down someone it has found", "m/s", 7.0, 4.0, 9.0, 0.25, &"now", &"LS1", F],
	# The tuned Playroom (T15m, sim/seek.gd) is on in the game's rooms: the first count gives 30 s to hide, each
	# later one 5 s more (to the fourth), the last count 30; every search lasts 30 s; the anger bar cools from
	# full in 50 s. Without it (tests only) a count's hide is HIDE_TIME.
	# The Minder's hunt (PT1, sim/seek.gd) is on with it in the game's rooms, so the two anger rows' game values
	# are its own: Seek.HUNT_ANGER_SPRINT (1 s of sprinting) and Seek.HUNT_ANGER_NOISE (55 in 100 a noise).
	# Without the hunt (tests only) an unset row is still today's old 2 s and 34.
	[&"minder.hide_time", &"minder", "TIME TO HIDE", "the free seconds at the start of the first count", "s", 30.0, 3.0, 60.0, 1.0, &"next", &"LS4", F],
	[&"minder.hide_more", &"minder", "EACH COUNT HIDES LONGER BY", "seconds more to hide at each later count, to the fourth", "s", 5.0, 0.0, 15.0, 1.0, &"next", &"LS4", F],
	[&"minder.last_hide", &"minder", "TIME TO HIDE, THE LAST COUNT", "the free seconds at the start of the count the lift call starts", "s", 30.0, 3.0, 60.0, 1.0, &"next", &"LS4", F],
	[&"minder.search", &"minder", "IT SEARCHES FOR", "how long a count's search lasts after the time to hide", "s", 30.0, 10.0, 90.0, 5.0, &"next", &"LS4", F],
	[&"minder.last_count", &"minder", "THE LAST COUNT LASTS", "the count the lift call starts", "s", 40.0, 20.0, 90.0, 5.0, &"next", &"LS4", F],
	[&"minder.calm", &"minder", "CALM AFTER A COUNT", "nothing can start a new count for this long", "s", 15.0, 5.0, 60.0, 5.0, &"next", &"LS4", F],
	[&"minder.sight", &"minder", "SEES AS FAR AS", "its sight in a count", "m", 12.0, 6.0, 20.0, 1.0, &"now", &"LS4", F],
	[&"minder.found_after", &"minder", "FOUND AFTER", "how long in its sight before you are found", "s", 1.0, 0.3, 3.0, 0.1, &"now", &"LS4", F],
	[&"minder.anger_sprint", &"minder", "SPRINTING FILLS ITS ANGER IN", "seconds of sprinting that fill an empty anger bar", "s", 1.0, 0.5, 10.0, 0.5, &"now", &"LS4", F],
	[&"minder.anger_noise", &"minder", "ONE NOISE ADDS TO ITS ANGER", "a ball pit, a flap, a dropped tape or an emote", "in 100", 55.0, 5.0, 100.0, 1.0, &"now", &"LS4", W],
	[&"minder.anger_cool", &"minder", "ITS ANGER COOLS FROM FULL IN", "seconds of quiet that empty a full anger bar. Does nothing with the party table on (the game's rooms): there the bar never cools by itself", "s", 50.0, 10.0, 300.0, 5.0, &"now", &"LS4", F],
	# The Groundskeeper (the Arboretum; sim/hearing.gd, sim/noise.gd, sim/run.gd KEEPER_HEALS). AR1 wires its
	# speeds, reach, timings and heals, along with the radii of the garden sounds.
	[&"groundskeeper.speed", &"groundskeeper", "COMING SPEED", "how fast it comes to a noise", "m/s", 6.0, 4.2, 9.0, 0.1, &"now", &"AR1", F],
	[&"groundskeeper.dark_speed", &"groundskeeper", "SPEED IN THE BLACKOUT", "the same, while the lights are out before the car", "m/s", 6.5, 4.2, 9.0, 0.1, &"now", &"AR1", F],
	[&"groundskeeper.reach", &"groundskeeper", "REACH", "it takes whoever is this near when a lean ends or a noise is made", "m", 2.0, 1.0, 3.0, 0.1, &"now", &"AR1", F],
	[&"groundskeeper.lean_range", &"groundskeeper", "LEANS TO ANYONE WITHIN", "of the place the noise was, when it gets there", "m", 4.0, 2.5, 8.0, 0.5, &"now", &"AR1", F],
	[&"groundskeeper.lean", &"groundskeeper", "THE LEAN LASTS", "how long it leans to a face before it takes them or not", "s", 2.5, 1.0, 6.0, 0.5, &"next", &"AR1", F],
	[&"groundskeeper.heals", &"groundskeeper", "HEALS A PLAYER, A FLOOR", "times one player can be healed back up on its floor", "heals", 2.0, 0.0, 5.0, 1.0, &"now", &"AR1", W],
	[&"groundskeeper.tilt", &"groundskeeper", "HEARING REACTION", "from hearing a noise to setting off", "s", 0.8, 0.3, 2.0, 0.1, &"next", &"AR", F],
	[&"groundskeeper.beat", &"groundskeeper", "THE BEAT AFTER A LEAN", "it holds the pose this long when it takes nobody", "s", 0.5, 0.0, 2.0, 0.1, &"next", &"AR", F],
	[&"groundskeeper.sweep", &"groundskeeper", "THE SWEEP LASTS", "the shears through an empty place", "s", 2.0, 0.5, 5.0, 0.5, &"next", &"AR", F],
	[&"groundskeeper.turn", &"groundskeeper", "LISTENING TURN", "how fast its head turns while it listens", "deg/s", 30.0, 10.0, 90.0, 5.0, &"now", &"AR", F],
	[&"noise.creep_loud", &"groundskeeper", "HEARS A CREEP ON LITTER WITHIN", "a creep on litter or gravel (on moss it is silent)", "m", 2.5, 1.0, 5.0, 0.5, &"now", &"AR", F],
	[&"noise.walk_moss", &"groundskeeper", "HEARS A WALK ON MOSS WITHIN", "a walk on moss or worn path", "m", 3.0, 1.0, 6.0, 0.5, &"now", &"AR", F],
	[&"noise.walk_litter", &"groundskeeper", "HEARS A WALK ON LITTER WITHIN", "a walk on leaf litter", "m", 8.0, 4.0, 14.0, 0.5, &"now", &"AR", F],
	[&"noise.walk_gravel", &"groundskeeper", "HEARS A WALK ON GRAVEL WITHIN", "a walk on gravel", "m", 10.0, 4.0, 16.0, 0.5, &"now", &"AR", F],
	[&"noise.twig", &"groundskeeper", "HEARS A TWIG CRACK WITHIN", "walking or sprinting onto a twig fall, once a crossing", "m", 12.0, 6.0, 20.0, 1.0, &"now", &"AR", F],
	[&"noise.sprint", &"groundskeeper", "HEARS A SPRINT WITHIN", "a sprint, on anything", "m", 14.0, 8.0, 24.0, 1.0, &"now", &"AR", F],
	[&"noise.crawl", &"groundskeeper", "HEARS A CRAWL WITHIN", "a downed player crawling", "m", 2.0, 0.0, 5.0, 0.5, &"now", &"AR", F],
	[&"noise.hide", &"groundskeeper", "HEARS A HIDE WITHIN", "getting into or out of a hide, opening something", "m", 4.0, 2.0, 8.0, 0.5, &"now", &"AR", F],
	[&"noise.drop", &"groundskeeper", "HEARS A DROP OR A HEAL WITHIN", "a tape hitting the floor, a player getting back up", "m", 6.0, 3.0, 12.0, 0.5, &"now", &"AR", F],
	[&"noise.cone", &"groundskeeper", "HEARS A PINECONE WITHIN", "where a thrown cone lands", "m", 12.0, 6.0, 20.0, 1.0, &"now", &"AR5", F],
	[&"noise.search_open", &"groundskeeper", "HEARS A CAREFUL SEARCH WITHIN", "the storage opening at the end of a careful search", "m", 4.0, 2.0, 6.0, 1.0, &"now", &"AR", F],
	[&"noise.search_rush", &"groundskeeper", "HEARS A RUSHED SEARCH WITHIN", "rummaging in storage at the start of a rushed search", "m", 8.0, 6.0, 12.0, 1.0, &"now", &"AR", F],
	[&"noise.emote", &"groundskeeper", "HEARS A WHISTLE WITHIN", "a sound emote: a whistle, a clap, a shout", "m", 18.0, 10.0, 30.0, 1.0, &"now", &"AR", F],
	# The Tenant clock (TT1, net/host_rules.gd tenant_timer): on in the game's rooms, the clock on every floor below the
	# prison, stamped as the doors open on arrival (a change waits for the next floor). Today's is HostRules.TENANT_MINUTES.
	[&"tenant.minutes", &"tenant", "ARRIVES AFTER", "minutes on a floor before the Tenant arrives", "min", 10.0, 2.0, 30.0, 1.0, &"next", &"TT1", W],
	# The lift and the dark. "Time for the elevator to return" is the first three rows.
	[&"lift.floors_min", &"lift", "CAR STARTS, FEWEST FLOORS AWAY", "the shortest the indicator can start from", "floors", 6.0, 2.0, 19.0, 1.0, &"next", &"LS1", W],
	[&"lift.floors_max", &"lift", "CAR STARTS, MOST FLOORS AWAY", "the longest", "floors", 12.0, 3.0, 20.0, 1.0, &"next", &"LS1", W],
	[&"lift.floor_time", &"lift", "SECONDS A FLOOR", "how long each floor on the indicator takes", "s", 4.0, 1.0, 8.0, 0.5, &"next", &"LS1", F],
	[&"lift.false_stop", &"lift", "FALSE STOP, CHANCE", "the car stops one floor above first", "in 100", 25.0, 0.0, 100.0, 5.0, &"next", &"LS4", W],
	[&"lift.board", &"lift", "BOARDING LASTS", "doors open to the bell", "s", 30.0, 10.0, 90.0, 5.0, &"next", &"LS4", F],
	[&"lift.hold", &"lift", "DOORS CAN BE HELD FOR", "the most a crew can hold the doors at one stop", "s", 15.0, 0.0, 60.0, 5.0, &"next", &"LS4", F],
	[&"lift.ride", &"lift", "THE RIDE DOWN TAKES", "doors shut, between floors", "s", 6.0, 3.0, 15.0, 1.0, &"next", &"LS4", F],
	[&"dark.min", &"lift", "BLACKOUT, SHORTEST", "the dark before the car arrives, from floor 2 down", "s", 20.0, 5.0, 40.0, 1.0, &"next", &"LS4", F],
	[&"dark.max", &"lift", "BLACKOUT, LONGEST", "the dark before the car arrives, from floor 2 down", "s", 24.0, 5.0, 40.0, 1.0, &"next", &"LS4", F],
	[&"dark.first_min", &"lift", "FIRST FLOOR'S BLACKOUT, SHORTEST", "the same on the first floor of a day", "s", 14.0, 5.0, 40.0, 1.0, &"next", &"LS4", F],
	[&"dark.first_max", &"lift", "FIRST FLOOR'S BLACKOUT, LONGEST", "the same on the first floor of a day", "s", 16.0, 5.0, 40.0, 1.0, &"next", &"LS4", F],
	[&"dark.warning", &"lift", "BLACKOUT WARNING", "the long flicker before it", "s", 3.0, 1.0, 6.0, 0.5, &"next", &"LS4", F],
	# Players: stamina.
	[&"stamina.tank", &"stamina", "A FULL TANK SPRINTS FOR", "seconds of sprinting in a full tank", "s", 7.0, 3.0, 15.0, 0.5, &"now", &"LS5", F],
	[&"stamina.refill_walk", &"stamina", "REFILL, WALKING", "empty to full", "s", 8.0, 3.0, 20.0, 0.5, &"now", &"LS5", F],
	[&"stamina.refill_rest", &"stamina", "REFILL, STANDING OR CREEPING", "empty to full", "s", 5.0, 2.0, 15.0, 0.5, &"now", &"LS5", F],
	[&"stamina.winded", &"stamina", "WINDED UNTIL THE TANK IS", "after running dry, no sprint until this full", "in 100", 35.0, 10.0, 80.0, 5.0, &"now", &"LS5", W],
	# Players: down and healing.
	[&"down.time", &"down", "DOWN FOR, BEFORE YOU ARE OUT", "the owner's \"time down until you expire\"", "s", 10.0, 5.0, 60.0, 1.0, &"next", &"LS1", F],
	[&"heal.time", &"down", "A HEAL TAKES", "how long F is held", "s", 3.0, 1.0, 10.0, 0.5, &"next", &"LS5", F],
	[&"heal.reach", &"down", "HEAL FROM WITHIN", "healer's feet to the downed player", "m", 1.5, 1.0, 3.0, 0.1, &"floor", &"LS6", F],
	[&"down.crawl", &"down", "CRAWL SPEED", "a downed player", "m/s", 0.6, 0.0, 2.0, 0.1, &"floor", &"LS6", F],
	[&"heal.quiet", &"down", "RESIDENT STANDS OFF AFTER A HEAL", "how long a resident that lost its downed player to a heal stays quiet", "s", 5.0, 0.0, 15.0, 1.0, &"next", &"LS5", F],
	# Players: health (the Playroom). With the Minder's hunt (PT1, the game's rooms) walking and sprinting cost only
	# while it searches; without it (tests only) from the end of the first count, outside counts.
	[&"health.walk", &"health", "WALKING COSTS", "health a second of walking, only while it hunts", "a second", 3.0, 0.0, 10.0, 0.5, &"now", &"LS5", F],
	[&"health.sprint", &"health", "SPRINTING COSTS", "health a second of sprinting, only while it hunts", "a second", 8.0, 0.0, 20.0, 1.0, &"now", &"LS5", F],
	[&"health.rest", &"health", "STANDING GIVES BACK", "health a second of standing", "a second", 1.0, 0.0, 5.0, 0.25, &"now", &"LS5", F],
	[&"heal.health", &"health", "A HEAL GIVES BACK", "the health a heal puts back", "health", 50.0, 10.0, 100.0, 5.0, &"next", &"LS5", F],
	# Players: carrying (the four-slot inventory, S1; sim/inventory.gd). Four slots is fixed. The stack goes into force
	# at lights out, when every bag is empty, so a slot never holds more than the number in force.
	[&"inv.stack", &"carry", "ONE SLOT HOLDS", "how many of the same item stack in one slot", "items", 1.0, 1.0, 5.0, 1.0, &"day", &"S1", W],
	[&"inv.hand_reach", &"carry", "HAND OVER WITHIN", "giver's feet to the crewmate's", "m", 1.5, 0.5, 3.0, 0.1, &"floor", &"S1", F],
	[&"flare.throw", &"carry", "FLARE THROW", "distance to the burst along the player's aim", "m", 4.0, 2.0, 8.0, 0.5, &"now", &"B3", F],
	[&"flare.reach", &"carry", "FLARE STUN RANGE", "within this distance of the burst with a clear path", "m", 6.0, 2.0, 10.0, 0.5, &"now", &"B3", F],
	[&"flare.stun", &"carry", "FLARE STUN LASTS", "how long it stops the resident", "s", 1.5, 0.5, 3.0, 0.25, &"now", &"B3", F],
	[&"flare.blind", &"carry", "FLARE BLIND LASTS", "how long the struck crewmate is blinded", "s", 1.0, 0.5, 2.0, 0.25, &"now", &"B3", F],
	[&"flare.noise", &"carry", "FLARE NOISE REACH", "the radius of its loud burst", "m", 24.0, 12.0, 30.0, 1.0, &"now", &"B3", F],
	[&"lamp.seconds", &"carry", "LAMP CHARGE", "seconds of light in a fresh battery", "s", 60.0, 15.0, 180.0, 5.0, &"now", &"B4", F],
	[&"lamp.range", &"carry", "LAMP BEAM REACH", "range of the portable beam", "m", 12.0, 5.0, 22.0, 1.0, &"now", &"B4", F],
	# Players: the shop and the cabinet (S2, T28 and T29; sim/shop.gd). Prices are credits from the buyer's own share; the
	# game's are the design's shares of a made day's pay (Shop.SHARE). The cabinet's size goes into force at lights out.
	[&"cabinet.slots", &"shop", "CABINET HOLDS", "slots in each cell's cabinet", "slots", 6.0, 4.0, 8.0, 1.0, &"day", &"S2", W],
	[&"shop.price.marker", &"shop", "A MARKER COSTS", "credits at the shop window", "credits", 60.0, 0.0, 600.0, 5.0, &"now", &"S2", W],
	[&"shop.price.glow", &"shop", "A GLOW STICK COSTS", "credits at the shop window", "credits", 90.0, 0.0, 600.0, 5.0, &"now", &"S2", W],
	[&"shop.price.flash", &"shop", "A FLASHBULB COSTS", "credits at the shop window", "credits", 120.0, 0.0, 600.0, 5.0, &"now", &"S2", W],
	[&"shop.price.speed", &"shop", "SPEED JUICE COSTS", "credits at the shop window", "credits", 150.0, 0.0, 600.0, 5.0, &"now", &"S2", W],
	[&"shop.price.toy", &"shop", "A WIND-UP TOY COSTS", "credits at the shop window", "credits", 150.0, 0.0, 600.0, 5.0, &"now", &"S2", W],
	[&"shop.price.salts", &"shop", "SMELLING SALTS COST", "credits at the shop window", "credits", 180.0, 0.0, 600.0, 5.0, &"now", &"S2", W],
	[&"shop.glow", &"shop", "A GLOW STICK LASTS", "seconds a dropped glow stick stays lit", "s", 180.0, 30.0, 600.0, 10.0, &"next", &"S2", F],
	# Earning.
	[&"quota.each", &"earning", "FLOOR QUOTA, EACH PLAYER", "floor 1's quota for one player", "credits", 400.0, 100.0, 1000.0, 25.0, &"floor", &"LS5", W],
	[&"quota.step", &"earning", "QUOTA GROWS, A FLOOR", "times this for every floor deeper", "times", 1.45, 1.0, 2.0, 0.05, &"floor", &"LS5", F],
	[&"pay.step", &"earning", "PAY GROWS, A FLOOR", "a reading is worth this much more a floor", "times", 1.35, 1.0, 2.0, 0.05, &"floor", &"LS5", F],
	[&"record.reach", &"earning", "RECORDING REACH", "how near the resident the needle writes", "m", 9.0, 4.0, 16.0, 0.5, &"now", &"LS5", F],
	[&"record.rate", &"earning", "PAY RATE UP CLOSE", "credits a second at the nearest", "a second", 140.0, 40.0, 400.0, 10.0, &"now", &"LS5", F],
	[&"day.first", &"earning", "DAY 1 OWES", "in floor-1 quotas", "quotas", 1.5, 0.5, 4.0, 0.5, &"day", &"LS5", F],
	[&"day.lights_out", &"earning", "LIGHTS OUT AFTER", "once more than half the crew is in bed", "s", 20.0, 5.0, 60.0, 5.0, &"next", &"LS5", F],
	[&"marks.pad", &"earning", "ARROWS ON THE PAD", "the Annex's marks, a floor", "arrows", 3.0, 0.0, 9.0, 1.0, &"floor", &"LS5", W],
	[&"badge.chance", &"earning", "BADGE CHANCE ON FLOOR 1", "an old crew badge hidden in distant searchable furniture", "%", 75.0, 0.0, 100.0, 1.0, &"floor", &"T30", W],
	[&"badge.depth_chance", &"earning", "BADGE CHANCE, EACH FLOOR DEEPER", "percentage points added per floor, up to certainty", "%", 8.0, 0.0, 25.0, 1.0, &"floor", &"T30", W],
	# Hiding.
	[&"hide.in_slow", &"hiding", "GETTING IN, QUIETLY", "seconds to get into a hide quietly", "s", 1.5, 0.5, 4.0, 0.1, &"next", &"LS6", F],
	[&"hide.in_fast", &"hiding", "GETTING IN, FAST AND LOUD", "seconds to get into a hide fast", "s", 0.5, 0.2, 2.0, 0.1, &"next", &"LS6", F],
	[&"hide.reach", &"hiding", "HIDE FROM WITHIN", "how near a hide F works", "m", 1.2, 0.8, 2.5, 0.1, &"floor", &"LS6", F],
	# Player speeds, last (the owner: "player speeds come last").
	[&"player.walk", &"moving", "WALK", "a player's walking speed", "m/s", 3.0, 2.0, 4.0, 0.1, &"floor", &"LS6", F],
	[&"player.sprint", &"moving", "SPRINT", "a player's sprinting speed", "m/s", 5.0, 3.5, 7.0, 0.1, &"floor", &"LS6", F],
	[&"player.creep", &"moving", "CREEP", "a player's creeping speed", "m/s", 1.2, 0.6, 2.0, 0.1, &"floor", &"LS6", F],
	[&"player.raised", &"moving", "WALK WITH THE INSTRUMENT UP", "the cap while recording", "m/s", 2.2, 1.0, 4.0, 0.1, &"floor", &"LS6", F],
]

## The pieces whose rows the rules read today (`wired`). LS4, LS5 and LS6 add theirs as they wire them.
const WIRED_PIECES: Array[StringName] = [&"LS1", &"AR5"]
## Rows of later pieces the rules already read (wired one group at a time, each with its proof).
const WIRED_IDS: Array[StringName] = [
	&"groundskeeper.tilt", &"groundskeeper.beat", &"groundskeeper.sweep", &"groundskeeper.turn",
	&"noise.creep_loud", &"noise.walk_moss", &"noise.walk_litter", &"noise.walk_gravel", &"noise.twig",
	&"noise.sprint", &"noise.crawl", &"noise.hide", &"noise.drop", &"noise.emote",
	&"noise.search_open", &"noise.search_rush",
	&"orderly.catch_dance",
	# LS4: the lift and the dark.
	&"lift.false_stop", &"lift.board", &"lift.hold", &"lift.ride",
	&"dark.min", &"dark.max", &"dark.first_min", &"dark.first_max", &"dark.warning",
	# LS4: the Minder (the tuned Playroom).
	&"minder.stroll", &"minder.hide_time", &"minder.hide_more", &"minder.last_hide", &"minder.search",
	&"minder.anger_sprint", &"minder.anger_noise", &"minder.anger_cool",
	# LS5: the tank, and the heal.
	&"stamina.tank", &"heal.time", &"heal.quiet", &"heal.health",
	# LS5: health on the Playroom (sim/seek.gd step 7 and PT1's health).
	&"health.walk", &"health.sprint", &"health.rest",
	# AR1: the Groundskeeper (the Arboretum).
	&"groundskeeper.speed", &"groundskeeper.dark_speed", &"groundskeeper.reach", &"groundskeeper.lean_range",
	&"groundskeeper.lean", &"groundskeeper.heals",
	# S1: carrying.
	&"inv.stack", &"inv.hand_reach",
	# S2: the shop and the cabinet.
	&"cabinet.slots", &"shop.price.marker", &"shop.price.glow", &"shop.price.flash", &"shop.price.speed", &"shop.price.toy",
	&"shop.price.salts", &"shop.glow",
	&"badge.chance", &"badge.depth_chance",
	# TT1: the Tenant clock.
	&"tenant.minutes",
]

## The least wait of a call is its start delay plus the floors: sim/run.gd CALL_START_DELAY_MIN (this file
## does not load run.gd, which loads it; tests/prop_settings.gd checks they are equal).
const LIFT_DELAY_MIN := 1.0
## The pair rule's shortest wait (seconds): the blackout and one blink always fit.
const LIFT_SHORTEST_WAIT := 15.0
## ARRIVES NO NEARER stays at least this far under ARRIVES NO FURTHER (metres).
const RELOC_GAP := 2.0
## The Groundskeeper always comes at least this many times a sprint ("sprinting away never works"), and leans
## to at least this far beyond its reach (metres).
const KEEPER_OVER_SPRINT := 1.2
const KEEPER_LEAN_GAP := 0.5

const EPS := 1e-9

## One row of the registry. Shared and read-only.
class Setting extends RefCounted:
	var id: StringName
	var group: StringName
	var section: StringName
	## The name shown (at most 32 characters, unique in its section).
	var name: String
	## What it changes, in a few words.
	var changes: String
	var unit: String
	## The game's value.
	var today: float
	## The least and the most it may be set to, and what one press of an arrow moves.
	var lo: float
	var hi: float
	var step: float
	## When a change takes hold: &"now", &"next", &"floor" or &"day" (HOLDS_SHOWN).
	var holds: StringName
	## The piece that wires it (&"LS1" ... &"LS6").
	var piece: StringName
	## The rules read it (and tests/prop_settings.gd proves it). The panel shows only these.
	var wired: bool
	## A whole number (read with i()).
	var whole: bool

## What is in force in a run: {id: value}, only as given (the desk keeps it to what differs from the game's).
## Replaced, never edited.
class Values extends RefCounted:
	var values: Dictionary = {}

	func has(id: StringName) -> bool:
		return values.has(id)

	func size() -> int:
		return values.size()

static var _rows: Array[Setting] = []
static var _by_id: Dictionary = {}

static func _load() -> void:
	if not _rows.is_empty():
		return
	for r: Array in ROWS:
		var s := Setting.new()
		s.id = r[0]
		s.section = r[1]
		s.group = _group_of(r[1])
		s.name = r[2]
		s.changes = r[3]
		s.unit = r[4]
		s.today = r[5]
		s.lo = r[6]
		s.hi = r[7]
		s.step = r[8]
		s.holds = r[9]
		s.piece = r[10]
		s.whole = r[11]
		s.wired = WIRED_PIECES.has(s.piece) or WIRED_IDS.has(s.id)
		_rows.append(s)
		_by_id[s.id] = s

static func _group_of(section: StringName) -> StringName:
	for sec: Array in SECTIONS:
		if sec[0] == section:
			return sec[1]
	return &""

# ---------------------------------------------------------------------------------------------
# The rules' read.

## The value of `id` in force in this run, or `fallback` (the constant the caller uses today) when there is
## no tuning or it does not name `id`. An untuned run returns `fallback` itself: same number, same path.
static func f(tuning: Values, id: StringName, fallback: float) -> float:
	if tuning == null:
		return fallback
	var v: Variant = tuning.values.get(id)
	return fallback if v == null else float(v)

## The same for a whole number.
static func i(tuning: Values, id: StringName, fallback: int) -> int:
	if tuning == null:
		return fallback
	var v: Variant = tuning.values.get(id)
	return fallback if v == null else roundi(float(v))

## A tuning from {id: number}, as given (check every value first). An empty set is an empty tuning (which
## reads exactly like none).
static func make(given: Dictionary) -> Values:
	var v := Values.new()
	for id: Variant in given:
		v.values[StringName(id)] = float(given[id])
	return v

# ---------------------------------------------------------------------------------------------
# The registry.

## Every row in the panel's order; `wired_only`: only those the rules read.
static func list(wired_only: bool = false) -> Array[Setting]:
	_load()
	if not wired_only:
		return _rows.duplicate()
	var out: Array[Setting] = []
	for s in _rows:
		if s.wired:
			out.append(s)
	return out

## One row, or null for an id the registry does not know.
static func row(id: StringName) -> Setting:
	_load()
	return _by_id.get(id)

static func has(id: StringName) -> bool:
	return row(id) != null

## The game's value of `id` (0 for an unknown id).
static func today(id: StringName) -> float:
	var s := row(id)
	return s.today if s != null else 0.0

## The groups in order: [{id, title}].
static func groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for g: Array in GROUPS:
		out.append({"id": g[0], "title": g[1]})
	return out

## The sections in order: [{id, group, title}].
static func sections() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s: Array in SECTIONS:
		out.append({"id": s[0], "group": s[1], "title": s[2]})
	return out

## Decimals of a setting's step (0, 1 or 2): how its values are printed and stored.
static func decimals(id: StringName) -> int:
	var s := row(id)
	if s == null:
		return 2
	for d in 3:
		var scaled := s.step * pow(10.0, d)
		if absf(scaled - roundf(scaled)) < 1e-6:
			return d
	return 2

## `value` on the setting's step from its least, written exactly as the decimal it is (3.6, never
## 3.5999999999999996). An unknown id returns `value`.
static func snap(id: StringName, value: float) -> float:
	var s := row(id)
	if s == null:
		return value
	var n := roundf((value - s.lo) / s.step)
	var scale := pow(10.0, decimals(id))
	return roundf((s.lo + n * s.step) * scale) / scale

## Whether `value` is not the game's value of `id`.
static func differs(id: StringName, value: float) -> bool:
	return absf(value - today(id)) > EPS

## The value as the panel and the notice print it: "3.60 M/S", "6 FLOORS", "25 IN 100".
static func text(id: StringName, value: float) -> String:
	var s := row(id)
	if s != null and s.unit == "on/off":
		return "OFF" if value == 0.0 else "ON"
	var d := decimals(id)
	var num := ("%." + str(d) + "f") % value
	return num if s == null or s.unit.is_empty() else "%s %s" % [num, s.unit.to_upper()]

# ---------------------------------------------------------------------------------------------
# The checker: the only door (the desk, the file loader and the protocol's decoder all go through it).

## &"" when `value` may be asked for `id`, else why not: &"id" (unknown), &"range" (not a finite number, or
## under least or over most once snapped to the step), &"pair" (with `asked`, the other values asked for,
## {id: number}, it breaks a pair rule). A refused value is never clamped.
static func check(id: StringName, value: Variant, asked: Dictionary = {}) -> StringName:
	var s := row(id)
	if s == null:
		return &"id"
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return &"range"
	var x := float(value)
	if is_nan(x) or is_inf(x):
		return &"range"
	var v := snap(id, x)
	if v < s.lo - EPS or v > s.hi + EPS:
		return &"range"
	var given := asked.duplicate()
	given[id] = v
	if not pair_broken(given).is_empty():
		return &"pair"
	return &""

## "" when `given` ({id: number}; ids it leaves out at today's) keeps every pair rule, else the panel's words
## for the first one it breaks.
static func pair_broken(given: Dictionary) -> String:
	var at := func(id: StringName) -> float:
		var v: Variant = given.get(id, given.get(String(id)))
		return float(v) if v != null else today(id)
	var fewest: float = at.call(&"lift.floors_min")
	var most: float = at.call(&"lift.floors_max")
	if fewest > most - 1.0 + EPS:
		return "FEWEST FLOORS MUST STAY UNDER MOST FLOORS"
	if LIFT_DELAY_MIN + fewest * float(at.call(&"lift.floor_time")) < LIFT_SHORTEST_WAIT - EPS:
		return "THE SHORTEST WAIT MUST BE AT LEAST %d S" % int(LIFT_SHORTEST_WAIT)
	for p: Array in [[&"dark.min", &"dark.max"], [&"dark.first_min", &"dark.first_max"]]:
		if float(at.call(p[0])) > float(at.call(p[1])) + EPS:
			return "EVERY SHORTEST MUST STAY AT OR UNDER ITS LONGEST"
	if float(at.call(&"reloc.near_min")) > float(at.call(&"reloc.near_max")) - RELOC_GAP + EPS:
		return "NEARER MUST STAY %d M UNDER FURTHER" % int(RELOC_GAP)
	var creep: float = at.call(&"player.creep")
	var raised: float = at.call(&"player.raised")
	var walk: float = at.call(&"player.walk")
	var sprint: float = at.call(&"player.sprint")
	if not (creep < raised - EPS and raised <= walk + EPS and walk < sprint - EPS):
		return "CREEP UNDER INSTRUMENT UP, AT OR UNDER WALK, UNDER SPRINT"
	# The Groundskeeper (AR1): sprinting away never works, and the lean reaches beyond the reach.
	for id: StringName in [&"groundskeeper.speed", &"groundskeeper.dark_speed"]:
		if float(at.call(id)) < KEEPER_OVER_SPRINT * sprint - 1e-6:
			return "THE GROUNDSKEEPER MUST COME A FIFTH FASTER THAN A SPRINT"
	if float(at.call(&"groundskeeper.lean_range")) < float(at.call(&"groundskeeper.reach")) + KEEPER_LEAN_GAP - EPS:
		return "IT MUST LEAN FURTHER THAN IT REACHES"
	return ""
