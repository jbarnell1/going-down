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
# One exception, on the lead's brief for DF1 (the owner approved the pressures, the numbers are Claude's proposals):
# pressure.watchers sets how many watchers hold a Stillness resident from floor 8, only within what the crew on its
# feet can field. The host alone counts watchers (Run.pressure_watch_need), so no screen predicts it.
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
	[&"deeper", "FLOOR 8 AND DEEPER"],
	# ED1: the elevator deal's cards (sim/deal.gd).
	[&"deal", "THE DEAL"],
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
	[&"reactor", &"residents", "THE FOUR (THE REACTOR)"],
	[&"rigger", &"residents", "THE RIGGER (THE WARD)"],
	[&"lift", &"lift", "THE LIFT AND THE DARK"],
	[&"ward", &"lift", "THE WARD"],
	[&"stamina", &"players", "STAMINA"],
	[&"down", &"players", "DOWN AND HEALING"],
	[&"health", &"players", "HEALTH (THE PLAYROOM)"],
	[&"split", &"players", "SPLIT REALITY"],
	[&"voice", &"players", "THE MICROPHONE"],
	[&"carry", &"players", "CARRYING"],
	[&"shop", &"players", "THE SHOP AND THE CABINET"],
	[&"earning", &"earning", "EARNING"],
	[&"hiding", &"hiding", "HIDING"],
	[&"pressure", &"deeper", "FLOOR 8 AND DEEPER"],
	[&"deal", &"deal", "THE DEAL"],
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
	# The second Orderly (T9b, sim/run.gd second_here): a Clinic floor this deep or deeper has two. Decided as the car
	# arrives, so a change waits for the next floor. Today's is Run.SECOND_ORDERLY_DEPTH.
	[&"orderly2.first_floor", &"orderly", "SECOND ORDERLY FROM FLOOR", "a Clinic floor this deep or deeper has a second Orderly", "", 2.0, 1.0, 20.0, 1.0, &"floor", &"T22b", W],
	[&"orderly.catch_dance", &"orderly", "BELLY DANCE AFTER A CATCH", "dance after bending over a downed crewmate", "on/off", 0.0, 0.0, 1.0, 1.0, &"now", &"T20i", W],
	# OR2, the Orderly fix (sim/run.gd with_orderly_fix, on in the game's rooms). Today's are Entity.REACH_WALK and
	# OrderlyFix.DIRTY_FROM. Off (tests only) nothing reads them.
	[&"orderly.reach_walk", &"orderly", "KEEPS COMING AS IT REACHES", "in 100 of its hunt speed, while it swipes (0: it stops to swipe and a walker gets away)", "in 100", 100.0, 0.0, 100.0, 5.0, &"now", &"OR2", W],
	[&"orderly.dirty_from", &"orderly", "STARTS IN THE DIRTY PART", "how far in the Orderlies start: in 100 of the walk from the lift to the far end", "in 100", 60.0, 30.0, 90.0, 5.0, &"floor", &"OR2", W],
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
	# MA1, the owner's playtest of 20 Nov (sim/seek.gd "MA1"): on in the game's rooms. Today's are Seek.CALM_AFTER_HUNT,
	# CALM_HIDE_ANGER, CALM_OPEN_ANGER (in 100) and CALM_STALK_SPEED.
	[&"minder.after_hunt", &"minder", "EACH HUNT LEAVES ITS ANGER AT", "where the anger bar restarts as a count ends. 0 (the game's): empty after every hunt. Raised, this much more for each count so far (never over 60)", "in 100", 0.0, 0.0, 45.0, 5.0, &"now", &"MA1", W],
	[&"minder.anger_hide", &"minder", "HIDING ANGERS IT BY", "getting into a hide adds this to its anger bar", "in 100", 10.0, 0.0, 50.0, 1.0, &"now", &"MA1", W],
	[&"minder.anger_open", &"minder", "OPENING SOMETHING ANGERS IT BY", "opening a drawer or a box adds this to its anger bar", "in 100", 10.0, 0.0, 50.0, 1.0, &"now", &"MA1", W],
	[&"minder.stalk", &"minder", "WALKS TO A PLAYER IT SEES AT", "between counts, toward a player in its view (walk 3, creep 1.2)", "m/s", 1.5, 0.5, 2.9, 0.1, &"now", &"MA1", F],
	[&"minder.voice", &"minder", "HEARS VOICES", "in 100 of a voice's reach: angers it, and a talking hider is heard in a count; 0 is deaf", "in 100", 100.0, 0.0, 200.0, 10.0, &"now", &"VC1", W],
	# The party table (T15h, sim/seek.gd "Party table"): on in the game's rooms. Today's are Seek.FETCH_TIME, FETCH_ANGER
	# and FETCH_REACH. The health the freed get back is heal.health. Read by the rules and by the client's table
	# prompt (client/hide_view.gd), so the screen prints the number in force; on the panel since T22c.
	[&"party.free_time", &"minder", "FREEING THE TABLE TAKES", "seconds of F held at the party table that free everyone seated", "s", 3.0, 1.0, 10.0, 0.5, &"next", &"T22b", F],
	[&"party.free_anger", &"minder", "FREEING THE TABLE ANGERS IT BY", "added to its anger bar when the table is freed", "in 100", 50.0, 0.0, 100.0, 5.0, &"now", &"T22b", W],
	[&"party.reach", &"minder", "FREE THE TABLE FROM WITHIN", "how near a seat F works", "m", 1.5, 0.8, 3.0, 0.1, &"floor", &"T22b", F],
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
	[&"groundskeeper.voice", &"groundskeeper", "HEARS VOICES", "in 100 of a voice's reach (THE MICROPHONE); 0 is deaf to voices", "in 100", 100.0, 0.0, 200.0, 10.0, &"now", &"VC1", W],
	# The Tenant clock (TT1, net/host_rules.gd tenant_timer): on in the game's rooms, the clock on every floor below the
	# prison, stamped as the doors open on arrival (a change waits for the next floor). Today's is HostRules.TENANT_MINUTES.
	[&"tenant.minutes", &"tenant", "ARRIVES AFTER", "minutes on a floor before the Tenant arrives", "min", 10.0, 2.0, 30.0, 1.0, &"next", &"TT1", W],
	# The Reactor (RN1, sim/station_floor.gd): on in the game's rooms with the late floors. Today's are its POWER_HOLD,
	# WAKE_AFTER, WAKE_GAP, CRAWL_TIME, CRAWL_SPEED and RUN_SPEED (the old floor's numbers). A player walks at 3 m/s and
	# sprints at 5.
	[&"reactor.power_hold", &"reactor", "LIGHTS HOLD FOR", "seconds of light after the first player passes the landing, before the power cuts", "s", 45.0, 10.0, 180.0, 5.0, &"next", &"RN1", F],
	[&"reactor.wake_after", &"reactor", "FIRST STIRS AFTER", "seconds from the cut to the first of the four moving (its sound comes then)", "s", 1.1, 0.0, 10.0, 0.1, &"now", &"RN1", F],
	[&"reactor.wake_gap", &"reactor", "EACH NEXT STIRS AFTER", "seconds between one of the four stirring and the next", "s", 0.62, 0.0, 10.0, 0.01, &"now", &"RN1", F],
	[&"reactor.crawl_time", &"reactor", "CRAWLS FOR", "seconds each crawls before it stands and pursues (a crawler catches nobody)", "s", 4.2, 0.0, 30.0, 0.1, &"now", &"RN1", F],
	[&"reactor.crawl_speed", &"reactor", "CRAWL SPEED", "how fast they crawl", "m/s", 0.43, 0.1, 2.0, 0.01, &"now", &"RN1", F],
	[&"reactor.run_speed", &"reactor", "PURSUIT SPEED", "how fast they pursue once standing (walk 3, sprint 5)", "m/s", 2.6, 1.5, 6.0, 0.1, &"now", &"RN1", F],
	# RX2 (tools/station_crews.gd measured these; sim/station_floor.gd ALONE_SCALE, PAIR_SCALE, CRAWL_KEEP, FEED, STAND_OFF).
	[&"reactor.alone_scale", &"reactor", "PURSUIT ALONE", "the pursuit speed for a crew of one, in 100 of the pursuit speed", "in 100", 100.0, 40.0, 150.0, 5.0, &"now", &"RX2", F],
	[&"reactor.pair_scale", &"reactor", "PURSUIT IN TWOS", "the pursuit speed for a crew of two, in 100 of the pursuit speed", "in 100", 100.0, 40.0, 150.0, 5.0, &"now", &"RX2", F],
	[&"reactor.crawl_keep", &"reactor", "CRAWLERS KEEP OFF", "how near a crawling body may come to anyone on their feet (0: right up to them)", "m", 3.0, 0.0, 8.0, 0.5, &"now", &"RX2", F],
	[&"reactor.feed", &"reactor", "CATCHER STAYS OVER ITS CATCH", "1: a body that puts someone down goes after nobody else while they lie there; 0: it hunts on", "", 1.0, 0.0, 1.0, 1.0, &"now", &"RX2", F],
	[&"reactor.stand_off", &"reactor", "STANDS OFF AFTER A HEAL", "seconds the catcher stays still after its catch is healed", "s", 5.0, 0.0, 15.0, 0.5, &"now", &"RX2", F],
	# RX3: the four hunt by what they see and hear (sim/station_floor.gd SENSES ... NOISE_DRAWS).
	[&"reactor.senses", &"reactor", "THEY HUNT BY SIGHT AND SOUND", "1: only whom they see or hear; 0: they always know where everyone is", "", 1.0, 0.0, 1.0, 1.0, &"now", &"RX3", F],
	[&"reactor.sight_dark", &"reactor", "SEE IN THE DARK", "how far they see a player in the emergency light", "m", 6.0, 2.0, 30.0, 0.5, &"now", &"RX3", F],
	[&"reactor.sight_lit", &"reactor", "SEE IN THE LIGHT", "how far they see a player once the power is back", "m", 16.0, 2.0, 40.0, 0.5, &"now", &"RX3", F],
	[&"reactor.sight_glow", &"reactor", "SEE A LIGHT", "how far they see a player with a lamp on, the glowing tape, or under an emergency lamp", "m", 10.0, 2.0, 40.0, 0.5, &"now", &"RX3", F],
	[&"reactor.sight_creep", &"reactor", "SEE A CREEP", "the furthest they see a creeping player", "m", 2.5, 0.0, 10.0, 0.5, &"now", &"RX3", F],
	[&"reactor.lamp_glow", &"reactor", "EMERGENCY LAMP'S POOL", "how near an emergency lamp a player stands lit", "m", 2.0, 0.0, 6.0, 0.5, &"now", &"RX3", F],
	[&"reactor.hear_walk", &"reactor", "HEAR A WALK", "how far they hear a walking player, through walls", "m", 6.0, 0.0, 20.0, 0.5, &"now", &"RX3", F],
	[&"reactor.hear_sprint", &"reactor", "HEAR A SPRINT", "how far they hear a sprinting player, through walls", "m", 10.0, 0.0, 30.0, 0.5, &"now", &"RX3", F],
	[&"reactor.hear_socket", &"reactor", "HEAR THE SOCKET", "how far they hear the fuse going into the cabinet", "m", 0.0, 0.0, 60.0, 1.0, &"now", &"RX3", F],
	[&"reactor.search_time", &"reactor", "SEARCH FOR", "seconds they search where they lost someone before drifting back to the hall", "s", 8.0, 0.0, 60.0, 1.0, &"now", &"RX3", F],
	[&"reactor.search_speed", &"reactor", "SEARCH PACE", "how fast they walk while searching", "m/s", 1.2, 0.5, 4.0, 0.1, &"now", &"RX3", F],
	[&"reactor.noise_draws", &"reactor", "ONE NOISE DRAWS", "how many of the four one noise (a whistle, a flare, a dropped fuse) pulls to it", "", 2.0, 0.0, 4.0, 1.0, &"now", &"RX3", W],
	[&"reactor.hear_wall", &"reactor", "HEAR A WALK THROUGH A WALL", "how near they hear a walk with no clear line (further, only in sight)", "m", 3.0, 0.0, 20.0, 0.5, &"now", &"RX3", F],
	[&"reactor.lunge_range", &"reactor", "LUNGE FROM", "how near the player it hunts before a body lunges", "m", 2.0, 0.0, 6.0, 0.5, &"now", &"RX3", F],
	[&"reactor.lunge_speed", &"reactor", "LUNGE SPEED", "how fast the lunge (walk 3, sprint 5)", "m/s", 4.5, 1.5, 8.0, 0.1, &"now", &"RX3", F],
	[&"reactor.wake_alone", &"reactor", "WAKE FOR ONE PLAYER", "how many of the four wake at the cut for a crew of one", "", 2.0, 1.0, 4.0, 1.0, &"next", &"RX3", W],
	[&"reactor.wake_pair", &"reactor", "WAKE FOR TWO", "how many of the four wake at the cut for a crew of two", "", 3.0, 1.0, 4.0, 1.0, &"next", &"RX3", W],
	[&"reactor.flinch", &"reactor", "FLINCH AT THE LIGHTS", "seconds every awake body holds still when the power comes back", "s", 3.5, 0.0, 15.0, 0.5, &"now", &"RX3", F],
	[&"reactor.board", &"reactor", "REACTOR'S CAR WAITS", "seconds the car stands open after the power comes back, before the bell", "s", 60.0, 10.0, 180.0, 5.0, &"now", &"RX3", F],
	[&"reactor.wake_late", &"reactor", "THE REST WAKE AFTER", "seconds after the cut that the ones a small crew did not wake stir", "s", 90.0, 0.0, 600.0, 5.0, &"now", &"RX3", F],
	[&"reactor.voice", &"reactor", "HEAR VOICES", "in 100 of a voice's reach, through walls, like a walk; 0 is deaf to voices", "in 100", 100.0, 0.0, 200.0, 10.0, &"now", &"VC1", W],
	# The Rigger (the Ward, WD1: sim/ward/state.gd and arm.gd). Today's are their constants, set by bot crews
	# (tools/ward_hunt.gd). A sprint is heard on any house floor; these say what else he hears and how he searches.
	[&"rigger.steps_reach", &"rigger", "HEARS A WALK WITHIN", "walking (not creeping) this near the house he is at; 0 is never", "m", 9.0, 0.0, 30.0, 0.5, &"now", &"WD1", F],
	[&"rigger.click_reach", &"rigger", "HEARS AN INSTRUMENT WITHIN", "an instrument recording this near his hand turns it to that room; 0 is never", "m", 2.5, 0.0, 8.0, 0.5, &"now", &"WD1", F],
	[&"rigger.open_heard", &"rigger", "HEARS SPRINTS OUT OF DOORS", "sprints upstairs, on galleries and on walkways", "on/off", 1.0, 0.0, 1.0, 1.0, &"now", &"WD1", W],
	[&"rigger.door_heard", &"rigger", "HEARS A DOOR", "a house door opened or shut", "on/off", 1.0, 0.0, 1.0, 1.0, &"now", &"WD1", W],
	[&"rigger.move_on", &"rigger", "MOVES ON TO A SECOND NOISE", "a noise at another house while he searches brings him there next", "on/off", 1.0, 0.0, 1.0, 1.0, &"now", &"WD1", W],
	[&"rigger.record_inside", &"rigger", "SEARCH RECORDS ONLY INSIDE", "his search records only from that house's ground floor; his climb from anywhere near", "on/off", 1.0, 0.0, 1.0, 1.0, &"now", &"WD1", W],
	[&"rigger.room_warn", &"rigger", "WAITS BEFORE EACH ROOM", "the hand's pause at the sill before it reaches into a room", "s", 0.9, 0.3, 4.0, 0.05, &"now", &"WD1", F],
	[&"rigger.probe", &"rigger", "FEELS EACH ROOM FOR", "how long the hand stays at the end of its reach", "s", 1.0, 0.0, 4.0, 0.1, &"now", &"WD1", F],
	[&"rigger.arm_speed", &"rigger", "HAND REACHES AT", "how fast the hand pays out into a house (walk 3, creep 1.2)", "m/s", 2.2, 0.5, 4.0, 0.05, &"now", &"WD1", F],
	[&"rigger.alone_arm_speed", &"rigger", "HAND REACHES AT, PLAYING ALONE", "the same with a crew of one", "m/s", 1.8, 0.5, 4.0, 0.05, &"now", &"WD1", F],
	[&"rigger.arm_back", &"rigger", "HAND DRAWS BACK AT", "how fast the hand comes back out", "m/s", 2.6, 0.5, 6.0, 0.1, &"now", &"WD1", F],
	# WC1 (net/host_rules.gd ward_call, ward_web): the lift's call at the far house and a cut down from the web are loud
	# (sim/ward/state.gd hear_loud): heard as a flare's burst is, this near where he is. 80 m is anywhere on the Ward.
	[&"rigger.call_heard", &"rigger", "HEARS THE LIFT CALLED WITHIN", "the call button at the far house, this near the house he is at; 0 is never", "m", 80.0, 0.0, 80.0, 1.0, &"now", &"WC1", F],
	[&"rigger.cut_heard", &"rigger", "HEARS A CUT FROM THE WEB WITHIN", "a crewmate cut down from the web, this near the house he is at; 0 is never", "m", 80.0, 0.0, 80.0, 1.0, &"now", &"WC1", F],
	# RR1: the Rigger as a solid creature crawling the Ward's surfaces (sim/ward/rigger_graph.gd; the run flag
	# rigger_roam). Read only with that flag on.
	[&"rigger.climb_speed", &"rigger", "CLIMBS HIS LINES AT", "up and down the taut lines at the houses' corners", "m/s", 6.0, 1.0, 10.0, 0.25, &"now", &"RR1", F],
	[&"rigger.crawl_speed", &"rigger", "CRAWLS AT", "over walls, roofs, decks and undersides", "m/s", 3.0, 0.5, 6.0, 0.1, &"now", &"RR1", F],
	[&"rigger.lair_speed", &"rigger", "CROSSES HIS LAIR AT", "in the dark far below the houses", "m/s", 16.0, 2.0, 30.0, 0.5, &"now", &"RR1", F],
	[&"rigger.linger", &"rigger", "STAYS AFTER A SEARCH", "seconds he waits at the house before going home; a noise then brings him straight on", "s", 8.0, 0.0, 60.0, 1.0, &"now", &"RR1", F],
	[&"rigger.opening_time", &"rigger", "SEARCHES FROM ONE OPENING FOR", "the longest his hand stays in at one window or door", "s", 20.0, 5.0, 60.0, 1.0, &"now", &"RR1", F],
	[&"rigger.feel", &"rigger", "FEELS EACH ROOM FOR, CRAWLING", "how long his hand stays at the end of its reach into a room", "s", 4.5, 0.0, 8.0, 0.1, &"now", &"RR1", F],
	[&"rigger.openings", &"rigger", "OPENINGS A VISIT", "windows and doors he may move between on one visit to a house", "openings", 2.0, 1.0, 3.0, 1.0, &"now", &"RR1", W],
	[&"rigger.loud", &"rigger", "CHASES AFTER NOISES", "noises he hears from one player out of doors within 5 s that start a chase; 0 is never", "noises", 3.0, 0.0, 10.0, 1.0, &"now", &"RR1", W],
	[&"rigger.chase_time", &"rigger", "CHASES FOR", "seconds he follows a loud player before he stops to reach", "s", 8.0, 1.0, 30.0, 0.5, &"now", &"RR1", F],
	[&"rigger.chase_gap", &"rigger", "KEEPS BACK DURING A CHASE", "the nearest his body comes to the player he chases", "m", 6.0, 3.0, 15.0, 0.5, &"now", &"RR1", F],
	[&"rigger.chase_gain", &"rigger", "GAINS ON A PLAYER AT", "how much faster than the player he goes per metre beyond that gap", "1/s", 0.8, 0.0, 3.0, 0.1, &"now", &"RR1", F],
	[&"rigger.chase_top", &"rigger", "CHASES AT MOST AT", "his top speed in a chase", "m/s", 5.5, 1.0, 10.0, 0.25, &"now", &"RR1", F],
	# VC1: who hears a player's real voice (the run flag voice; sim/run.gd "VC1"). 0 is deaf to voices. Read only with
	# the flag on. The Orderly and the Temp never hear a voice (Stillness, Lonely).
	[&"rigger.voice_reach", &"rigger", "HEARS TALKING WITHIN", "a talking voice this near the house he is at (a whisper less, a shout more); 0 is never", "m", 9.0, 0.0, 30.0, 0.5, &"now", &"VC1", F],
	[&"rigger.reach_pause", &"rigger", "REARS BEFORE HE GRABS FOR", "seconds between his rearing up and the arm going out; a player in a house by then is not taken", "s", 1.5, 0.5, 5.0, 0.1, &"now", &"RR1", F],
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
	# The Ward (PL2, net/host.gd _step_ward_review): LIFT RETURNS IN m:ss, stamped as the lift leaves the crew in the
	# Hanging Ward. Today's is sim/ward/state.gd RETURN_SECONDS (the design's ten minutes). At one minute there is no
	# separate one-minute reminder.
	[&"ward.lift_minutes", &"ward", "LIFT RETURNS AFTER", "minutes from the lift leaving the crew in the Ward to its return", "min", 10.0, 1.0, 20.0, 1.0, &"next", &"PL2", W],
	# WC1: with the call on, the clock is back only when this is on (read as the Ward starts); the web's carry and cut.
	[&"ward.lift_clock", &"ward", "LIFT ON A CLOCK, NOT CALLED", "the old ten-minute return instead of the call at the far house", "on/off", 0.0, 0.0, 1.0, 1.0, &"next", &"WC1", W],
	[&"ward.carry_time", &"ward", "A CATCH IS HUNG AFTER", "seconds from the hand's catch to the cocoon at its hang point", "s", 2.0, 0.0, 8.0, 0.5, &"now", &"WC1", F],
	[&"ward.cut_time", &"ward", "A CUT FROM THE WEB TAKES", "how long F is held under a cocoon", "s", 4.0, 1.0, 15.0, 0.5, &"now", &"WC1", F],
	# WG1: the Ward laid out from the floor seed (net/host_rules.gd ward_layout; sim/ward/layout.gd generate_v2), stamped
	# as the host builds the Ward on arrival and sent to every screen in the Ward's block. They only scale lengths: the
	# seed's draws are the same whatever they say. Today's are sim/ward/layout.gd SPREAD and RISE.
	[&"ward.spread", &"ward", "HOUSES HANG APART", "times the Ward's spacing between neighbouring houses (longer walkways)", "times", 1.1, 1.0, 1.6, 0.05, &"floor", &"WG1", F],
	[&"ward.rise", &"ward", "HOUSES HANG WITHIN", "metres above or below the lift's cottage; walkways never steeper than 1 in 5.5", "m", 1.5, 0.0, 3.0, 0.1, &"floor", &"WG1", F],
	# Players: stamina.
	[&"stamina.tank", &"stamina", "A FULL TANK SPRINTS FOR", "seconds of sprinting in a full tank", "s", 7.0, 3.0, 15.0, 0.5, &"now", &"LS5", F],
	[&"stamina.refill_walk", &"stamina", "REFILL, WALKING", "empty to full", "s", 8.0, 3.0, 20.0, 0.5, &"now", &"LS5", F],
	[&"stamina.refill_rest", &"stamina", "REFILL, STANDING OR CREEPING", "empty to full", "s", 5.0, 2.0, 15.0, 0.5, &"now", &"LS5", F],
	[&"stamina.winded", &"stamina", "WINDED UNTIL THE TANK IS", "after running dry, no sprint until this full", "in 100", 35.0, 10.0, 80.0, 5.0, &"now", &"LS5", W],
	# Players: down and healing.
	[&"down.time", &"down", "DOWN FOR, BEFORE YOU ARE OUT", "the owner's \"time down until you expire\" (without the ring: tests only)", "s", 10.0, 5.0, 60.0, 1.0, &"next", &"LS1", F],
	# DR1, the owner's playtest of 20 Nov (sim/run.gd down_time): on in the game's rooms. Today's is Run.DOWN_RING_TIME.
	[&"down.ring", &"down", "DOWN FOR, WITH THE RING", "time down until you are out, shown as the ring", "s", 30.0, 5.0, 90.0, 1.0, &"next", &"DR1", F],
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
	# Players: split reality (SR1, sim/split.gd; North Star E1, E2, E5), on in the game's rooms. Exposure is 0 to 100,
	# never shown. Today's are the Split constants.
	[&"split.read_rise", &"split", "RISES WITH THE INSTRUMENT UP", "exposure gained a second while recording", "in 100 a second", 0.35, 0.0, 3.0, 0.05, &"now", &"SR1", F],
	[&"split.alone_rise", &"split", "RISES WHILE ALONE", "exposure gained a second with no crewmate near", "in 100 a second", 0.15, 0.0, 3.0, 0.05, &"now", &"SR1", F],
	[&"split.alone_m", &"split", "ALONE WITH NOBODY WITHIN", "how near a crewmate must be for you not to be alone", "m", 8.0, 3.0, 20.0, 1.0, &"now", &"SR1", F],
	[&"split.dark_rise", &"split", "RISES IN THE DARK", "exposure gained a second in a blink or the blackout, lamp off", "in 100 a second", 0.5, 0.0, 3.0, 0.05, &"now", &"SR1", F],
	[&"split.lift_fall", &"split", "FALLS IN THE LIFT", "exposure lost a second aboard the car", "in 100 a second", 2.0, 0.0, 10.0, 0.25, &"now", &"SR1", F],
	[&"split.first_at", &"split", "FALSE SIGHTS FROM", "no false sight below this exposure", "in 100", 30.0, 5.0, 95.0, 5.0, &"now", &"SR1", W],
	[&"split.calm_at", &"split", "FALSE CALM FROM", "at this exposure and above the heartbeat stops and the picture is clean", "in 100", 90.0, 50.0, 100.0, 5.0, &"now", &"SR1", W],
	[&"split.every", &"split", "A CHANCE EVERY", "seconds between chances of a false sight", "s", 6.0, 2.0, 30.0, 1.0, &"now", &"SR1", F],
	[&"split.chance", &"split", "CHANCE AT THE TOP", "the chance of a false sight at full exposure (none at FALSE SIGHTS FROM)", "%", 35.0, 0.0, 100.0, 5.0, &"now", &"SR1", W],
	[&"split.lasts", &"split", "A FALSE SIGHT LASTS", "seconds, unless it is touched or lit by a flare first", "s", 10.0, 3.0, 30.0, 1.0, &"now", &"SR1", F],
	# VC1: a player's microphone level (0 to 15) as a noise where they were. Whisper is levels 1 to 4, talk 5 to 10,
	# shout 11 to 15; below 1, silent. Read only with the run flag voice on.
	[&"noise.voice_whisper", &"voice", "A WHISPER CARRIES", "microphone levels 1 to 4", "m", 2.0, 0.0, 6.0, 0.5, &"now", &"VC1", F],
	[&"noise.voice_talk", &"voice", "TALKING CARRIES", "microphone levels 5 to 10", "m", 8.0, 2.0, 16.0, 0.5, &"now", &"VC1", F],
	[&"noise.voice_shout", &"voice", "A SHOUT CARRIES", "microphone levels 11 to 15", "m", 16.0, 6.0, 30.0, 1.0, &"now", &"VC1", F],
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
	# PY1 (sim/run.gd "PY1"): pay and quota grow by the floor's place in its cycle (1 to 7), times its cycle's row.
	[&"pay.cycle1", &"earning", "PAY AND QUOTA, CYCLE 1", "floors 1 to 7: pay and quotas times this", "times", 1.0, 0.5, 4.0, 0.25, &"floor", &"PY1", F],
	[&"pay.cycle2", &"earning", "PAY AND QUOTA, CYCLE 2", "floors 8 to 14: pay and quotas times this", "times", 2.0, 0.5, 8.0, 0.25, &"floor", &"PY1", F],
	[&"pay.cycle3", &"earning", "PAY AND QUOTA, CYCLE 3 ON", "floor 15 and deeper: pay and quotas times this", "times", 4.0, 0.5, 16.0, 0.25, &"floor", &"PY1", F],
	[&"record.reach", &"earning", "RECORDING REACH", "how near the resident the needle writes", "m", 9.0, 4.0, 16.0, 0.5, &"now", &"LS5", F],
	[&"record.rate", &"earning", "PAY RATE UP CLOSE", "credits a second at the nearest", "a second", 140.0, 40.0, 400.0, 10.0, &"now", &"LS5", F],
	# LS1 (North Star B7, sim/last_stand.gd): on in the game's rooms. The last player up in a crew of two or more earns this
	# many times what they record while alone; stamped as the spotlight begins and shown then. Today's is LastStand.BONUS.
	[&"last_stand.bonus", &"earning", "SOLE SURVIVOR PAYS", "times what the last player on their feet records while alone (from a crew of two)", "times", 1.5, 1.0, 3.0, 0.05, &"next", &"B7", F],
	[&"day.first", &"earning", "DAY 1 OWES", "in floor-1 quotas", "quotas", 1.5, 0.5, 4.0, 0.5, &"day", &"LS5", F],
	[&"day.lights_out", &"earning", "LIGHTS OUT AFTER", "once more than half the crew is in bed", "s", 20.0, 5.0, 60.0, 5.0, &"next", &"LS5", F],
	[&"marks.pad", &"earning", "ARROWS ON THE PAD", "the Annex's marks, a floor", "arrows", 3.0, 0.0, 9.0, 1.0, &"floor", &"LS5", W],
	[&"badge.chance", &"earning", "BADGE CHANCE ON FLOOR 1", "an old crew badge hidden in distant searchable furniture", "%", 75.0, 0.0, 100.0, 1.0, &"floor", &"T30", W],
	[&"badge.depth_chance", &"earning", "BADGE CHANCE, EACH FLOOR DEEPER", "percentage points added per floor, up to certainty", "%", 8.0, 0.0, 25.0, 1.0, &"floor", &"T30", W],
	# Hiding.
	[&"hide.in_slow", &"hiding", "GETTING IN, QUIETLY", "seconds to get into a hide quietly", "s", 1.5, 0.5, 4.0, 0.1, &"next", &"LS6", F],
	[&"hide.in_fast", &"hiding", "GETTING IN, FAST AND LOUD", "seconds to get into a hide fast", "s", 0.5, 0.2, 2.0, 0.1, &"next", &"LS6", F],
	[&"hide.reach", &"hiding", "HIDE FROM WITHIN", "how near a hide F works", "m", 1.2, 0.8, 2.5, 0.1, &"floor", &"LS6", F],
	# The pressures of cycle 2 and deeper (DF1, sim/run.gd "Pressures"; docs/floors/difficulty.md section 2): on in the
	# game's rooms with cycles, from floor 8. Each "CYCLE 2" row is floors 8 to 14, each "CYCLE 3 ON" row floor 15 and
	# deeper. Today's are Run.PRESSURE_*; each row has a value that switches it off, named in what it changes.
	[&"pressure.quota", &"pressure", "QUOTAS, CYCLE 2", "floor and day quotas times this (1 is off)", "times", 1.5, 1.0, 4.0, 0.05, &"floor", &"DF1", F],
	[&"pressure.quota3", &"pressure", "QUOTAS, CYCLE 3 ON", "floor and day quotas times this (1 is off)", "times", 2.25, 1.0, 6.0, 0.05, &"floor", &"DF1", F],
	[&"pressure.heals", &"pressure", "HEALS A FLOOR, CYCLE 2", "times the crew can be helped up on one floor, salts included (0 is no limit)", "heals", 2.0, 0.0, 9.0, 1.0, &"floor", &"DF1", W],
	[&"pressure.heals3", &"pressure", "HEALS A FLOOR, CYCLE 3 ON", "times the crew can be helped up on one floor, salts included (0 is no limit)", "heals", 1.0, 0.0, 9.0, 1.0, &"floor", &"DF1", W],
	[&"pressure.watchers", &"pressure", "WATCHERS NEEDED, CYCLE 2", "eyes that hold a watched resident; never more than the crew on its feet less one (2 is off)", "watchers", 3.0, 2.0, 7.0, 1.0, &"floor", &"DF1", W],
	[&"pressure.watchers3", &"pressure", "WATCHERS NEEDED, CYCLE 3 ON", "eyes that hold a watched resident; never more than the crew on its feet less one (2 is off)", "watchers", 3.0, 2.0, 7.0, 1.0, &"floor", &"DF1", W],
	[&"pressure.near_light", &"pressure", "NEAR LIGHT REACH, CYCLE 2", "the light around you on your own screen (4 is off, 0 is none)", "m", 1.5, 0.0, 4.0, 0.5, &"floor", &"DF1", F],
	[&"pressure.near_light3", &"pressure", "NEAR LIGHT REACH, CYCLE 3 ON", "the light around you on your own screen (4 is off, 0 is none)", "m", 0.0, 0.0, 4.0, 0.5, &"floor", &"DF1", F],
	[&"pressure.tenant_minutes", &"pressure", "TENANT ARRIVES AFTER, CYCLE 2", "minutes on a floor, when sooner than ARRIVES AFTER (0 is off)", "min", 8.0, 0.0, 30.0, 1.0, &"next", &"DF1", W],
	[&"pressure.tenant_minutes3", &"pressure", "TENANT ARRIVES AFTER, CYCLE 3 ON", "minutes on a floor, when sooner than ARRIVES AFTER (0 is off)", "min", 6.0, 0.0, 30.0, 1.0, &"next", &"DF1", W],
	# ED1, the elevator deal (sim/deal.gd; on in the game's rooms). Today's are Deal's constants and its CARD table.
	# A card's odds are its boon's chance in twelfths (6 prints 1 in 2, 9 prints 3 in 4). Off (tests only) nothing reads them.
	[&"deal.ride", &"deal", "A RIDE WITH A CARD LASTS", "the ride down is at least this long when a card is dealt: the time to choose (4 s after the choice is made, once nothing is left to choose)", "s", 15.0, 6.0, 40.0, 1.0, &"next", &"ED1", F],
	[&"deal.squeak_in", &"deal", "SQUEAKY SOLES IN THE DECK", "the card can be dealt", "on/off", 1.0, 0.0, 1.0, 1.0, &"next", &"ED1", W],
	[&"deal.squeak", &"deal", "SQUEAKY SOLES: BOON CHANCE", "in 12: hazard pay; else the carrier's shoes squeak", "in 12", 6.0, 1.0, 11.0, 1.0, &"next", &"ED1", W],
	[&"deal.torch_in", &"deal", "NOVELTY TORCH IN THE DECK", "the card can be dealt", "on/off", 1.0, 0.0, 1.0, 1.0, &"next", &"ED1", W],
	[&"deal.torch", &"deal", "NOVELTY TORCH: BOON CHANCE", "in 12: hazard pay; else the carrier's light is a novelty torch", "in 12", 6.0, 1.0, 11.0, 1.0, &"next", &"ED1", W],
	[&"deal.second_in", &"deal", "SECOND OPINION IN THE DECK", "the card can be dealt", "on/off", 1.0, 0.0, 1.0, 1.0, &"next", &"ED1", W],
	[&"deal.second", &"deal", "SECOND OPINION: BOON CHANCE", "in 12: one look through a crewmate's eyes; else the carrier squeaks", "in 12", 9.0, 1.0, 11.0, 1.0, &"next", &"ED1", W],
	[&"deal.dark_in", &"deal", "LIGHTS OUT IN THE DECK", "the card can be dealt", "on/off", 1.0, 0.0, 1.0, 1.0, &"next", &"ED1", W],
	[&"deal.dark", &"deal", "LIGHTS OUT: BOON CHANCE", "in 12: dark and paid more; else dark for nothing", "in 12", 6.0, 1.0, 11.0, 1.0, &"next", &"ED1", W],
	[&"deal.express_in", &"deal", "EXPRESS IN THE DECK", "the card can be dealt (only where skipping a floor is safe)", "on/off", 1.0, 0.0, 1.0, 1.0, &"next", &"ED1", W],
	[&"deal.express", &"deal", "EXPRESS: BOON CHANCE", "in 12: skip a floor for more pay; else the same and it is awake", "in 12", 6.0, 1.0, 11.0, 1.0, &"next", &"ED1", W],
	[&"deal.double_in", &"deal", "DOUBLE OR NOTHING", "after a boon the carrier may draw again", "on/off", 1.0, 0.0, 1.0, 1.0, &"next", &"ED1", W],
	[&"deal.double_drop", &"deal", "DOUBLE OR NOTHING ODDS WORSE BY", "in 12, off the second card's boon chance (never under 1 in 12)", "in 12", 3.0, 1.0, 6.0, 1.0, &"next", &"ED1", W],
	[&"deal.hazard_pay", &"deal", "HAZARD PAY", "the carrier's readings pay this many times", "times", 1.5, 1.0, 3.0, 0.05, &"next", &"ED1", F],
	[&"deal.dark_pay", &"deal", "LIGHTS OUT PAYS", "every reading on the dark floor pays this many times", "times", 2.0, 1.0, 4.0, 0.05, &"next", &"ED1", F],
	[&"deal.express_pay", &"deal", "EXPRESS PAYS", "every reading on the floor after the skip pays this many times", "times", 2.0, 1.0, 4.0, 0.05, &"next", &"ED1", F],
	[&"deal.squeak_loud", &"deal", "SQUEAKY SOLES CARRY", "the carrier's footsteps this many times as far to a resident that hears", "times", 1.6, 1.0, 3.0, 0.1, &"now", &"ED1", F],
	[&"deal.torch_dim", &"deal", "NOVELTY TORCH STRENGTH", "the carrier's near light, in 100 of a normal one (it flickers too)", "in 100", 45.0, 10.0, 100.0, 5.0, &"now", &"ED1", W],
	[&"deal.second_time", &"deal", "SECOND OPINION LASTS", "the look through a crewmate's eyes", "s", 10.0, 5.0, 30.0, 1.0, &"next", &"ED1", F],
	# Player speeds, last (the owner: "player speeds come last").
	[&"player.walk", &"moving", "WALK", "a player's walking speed", "m/s", 3.0, 2.0, 4.0, 0.1, &"floor", &"LS6", F],
	[&"player.sprint", &"moving", "SPRINT", "a player's sprinting speed", "m/s", 5.0, 3.5, 7.0, 0.1, &"floor", &"LS6", F],
	[&"player.creep", &"moving", "CREEP", "a player's creeping speed", "m/s", 1.2, 0.6, 2.0, 0.1, &"floor", &"LS6", F],
	[&"player.raised", &"moving", "WALK WITH THE INSTRUMENT UP", "the cap while recording", "m/s", 2.2, 1.0, 4.0, 0.1, &"floor", &"LS6", F],
]

## The pieces whose rows the rules read today (`wired`). LS4, LS5 and LS6 add theirs as they wire them.
const WIRED_PIECES: Array[StringName] = [&"LS1", &"AR5", &"DF1", &"WD1", &"RR1"]
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
	# PL2: the Ward's lift.
	&"ward.lift_minutes",
	# WC1: the Ward's call and web.
	&"rigger.call_heard", &"rigger.cut_heard", &"ward.lift_clock", &"ward.carry_time", &"ward.cut_time",
	# WG1: the Ward's layout.
	&"ward.spread", &"ward.rise",
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
	# RN1: the Reactor's power and its four.
	&"reactor.power_hold", &"reactor.wake_after", &"reactor.wake_gap", &"reactor.crawl_time", &"reactor.crawl_speed",
	&"reactor.run_speed", &"reactor.alone_scale", &"reactor.pair_scale", &"reactor.crawl_keep", &"reactor.feed", &"reactor.stand_off",
	&"reactor.senses", &"reactor.sight_dark", &"reactor.sight_lit", &"reactor.sight_glow", &"reactor.sight_creep", &"reactor.lamp_glow",
	&"reactor.hear_walk", &"reactor.hear_sprint", &"reactor.hear_socket", &"reactor.search_time", &"reactor.search_speed", &"reactor.noise_draws",
	&"reactor.hear_wall", &"reactor.lunge_range", &"reactor.lunge_speed", &"reactor.wake_alone", &"reactor.wake_pair", &"reactor.wake_late", &"reactor.flinch", &"reactor.board",
	# T22b: the second Orderly's first floor, the flare and the lamp (already read by the rules), recording, the
	# quota's growth and the Annex's pad.
	&"orderly2.first_floor",
	&"flare.throw", &"flare.reach", &"flare.stun", &"flare.blind", &"flare.noise", &"lamp.seconds", &"lamp.range",
	&"record.reach", &"record.rate", &"quota.step", &"marks.pad",
	# T22c: the party table, now that client/hide_view.gd's table prompt prints the tuned numbers too.
	&"party.free_time", &"party.free_anger", &"party.reach",
	# OR2: the Orderly fix.
	&"orderly.reach_walk", &"orderly.dirty_from",
	# MA1 and DR1: the owner's playtest of 20 Nov.
	&"minder.after_hunt", &"minder.anger_hide", &"minder.anger_open", &"minder.stalk", &"down.ring",
	# LS1: the sole survivor's bonus (North Star B7).
	&"last_stand.bonus",
	# ED1: the elevator deal.
	&"deal.ride", &"deal.squeak_in", &"deal.squeak", &"deal.torch_in", &"deal.torch", &"deal.second_in", &"deal.second",
	&"deal.dark_in", &"deal.dark", &"deal.express_in", &"deal.express", &"deal.double_in", &"deal.double_drop",
	&"deal.hazard_pay", &"deal.dark_pay", &"deal.express_pay", &"deal.squeak_loud", &"deal.torch_dim", &"deal.second_time",
	# SR1: split reality.
	&"split.read_rise", &"split.alone_rise", &"split.alone_m", &"split.dark_rise", &"split.lift_fall", &"split.first_at",
	&"split.calm_at", &"split.every", &"split.chance", &"split.lasts",
	# PY1: pay and quota by the cycle.
	&"pay.cycle1", &"pay.cycle2", &"pay.cycle3",
	# VC1: the microphone.
	&"groundskeeper.voice", &"minder.voice", &"reactor.voice", &"rigger.voice_reach",
	&"noise.voice_whisper", &"noise.voice_talk", &"noise.voice_shout",
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
