# The last one standing, and the wipe (North Star B7; task LS1). Rules data only: no drawing, no network.
# "When one living player remains, every camera feed locks onto them, the music cuts, and their tape gains a
# sole-survivor bonus. It is a spotlight. A wipe is a scene too. Everyone watches the elevator arrive at an empty
# landing. The doors open. A pause. Something steps in, and it rides up. Later, the lobby gains a standee with the
# face of the last player caught."
#
# Behind one run flag (sim/run.gd last_stand, Run.with_last_stand; net/host_rules.gd `last_stand_`, the last
# parameter). Off, nothing here is ever made or read and every run is exactly as recorded.
#
# What the rules keep (State, on RunState.stand; replaced, never edited):
#  - the spotlight: on a floor below the prison (not Practice, not during a ride, not after the end), in a crew of two
#    or more, exactly one player still up (status "ok", and on the Playroom not found or taken). `id` is that player
#    from the tick it became true to the tick it stops being true; `since` the run time it began; `mult` the bonus,
#    the live setting last_stand.bonus stamped as the spotlight begins (so the number shown is the number paid).
#    Events "lastStand" {playerId, mult} on the tick it begins and "lastStandEnd" {playerId, why} on the tick it ends
#    (why: "healed" another player is up again, "caught" the survivor is down too, "left" the floor ended for them:
#    a ride, the wipe, the end).
#  - the bonus: on every tick that STARTS in the spotlight (the state the tick is stepped from has `id`), what that
#    player's instrument records is multiplied by `mult` (Instr.EntityTick.pay, as the Groundskeeper's lean pays).
#    So the tick the spotlight begins is paid as before, and the snapshot of that tick, which already carries the
#    number, reaches every screen before any of it is earned ("Odds are printed before a chance is taken").
#  - the last catch on this floor: who (`catch_id`), by which resident (`catch_by`: orderly, temp, minder,
#    groundskeeper, four, rigger) and, with two Orderlies, which (`catch_n`).
#  - the wipe: on the tick the run says "wiped", `wipe` {at, depth, day, by, n, last} from the last catch, so every
#    screen plays the same scene from the same host time (client/wipe_scene.gd); and `standee`, the last player caught,
#    kept for the rest of the night until the next wipe replaces it (the prison draws it; sim/run.gd keeps it across
#    the day loop's new days, since the room holds the night). Not saved between nights: the room keeps no crew file.
extends RefCounted

const Instr = preload("res://sim/instrument.gd")
const Settings = preload("res://sim/settings.gd")

## The sole survivor's pay multiplier (the live setting last_stand.bonus; Claude's proposal, the brief's 1.5).
const BONUS := 1.5

class State:
	var id := ""
	var since := -1.0
	var mult := 1.0
	var catch_id := ""
	var catch_by := ""
	var catch_n := 1
	## The floor the last catch was on ("day:depth"): a new floor forgets it.
	var catch_floor := ""
	var wipe: Dictionary = {}
	var standee := ""

	func copy() -> State:
		var s := State.new()
		s.id = id
		s.since = since
		s.mult = mult
		s.catch_id = catch_id
		s.catch_by = catch_by
		s.catch_n = catch_n
		s.catch_floor = catch_floor
		s.wipe = wipe
		s.standee = standee
		return s

## The resident a floor's place names, as the scene draws it.
static func resident_of(place: StringName, ward: bool) -> String:
	if ward:
		return "rigger"
	match String(place):
		"annex":
			return "temp"
		"playroom":
			return "minder"
		"arboretum":
			return "groundskeeper"
		"reactor":
			return "four"
	return "orderly"

## Who a spotlight would fall on: the one id in `up` when `crew` is two or more and the floor counts, else "".
static func survivor(up: Array[String], crew: int, on_floor: bool) -> String:
	if not on_floor or crew < 2 or up.size() != 1:
		return ""
	return up[0]

## The state after a tick. `st` the state the tick started from (null for none yet); `up` the players up after
## it; `crew` how many players the run has; `on_floor` whether a spotlight can be here (see the header); `floor`
## "day:depth"; `resident` this floor's resident (resident_of); `events` the tick's events (appended to).
static func after_tick(st: State, up: Array[String], crew: int, on_floor: bool, t: float, floor: String, depth: int, day: int,
		resident: String, tuning: Settings.Values, events: Array[Dictionary]) -> State:
	var out := st.copy() if st != null else State.new()
	if out.catch_floor != floor:
		out.catch_id = ""
		out.catch_by = ""
		out.catch_n = 1
		out.catch_floor = floor
	var wiped := false
	for e in events:
		var ty := str(e.get("type", ""))
		if ty == "caught" or ty == "found" or (ty == "down" and resident == "minder"):
			out.catch_id = str(e.get("playerId", ""))
			out.catch_by = resident
			out.catch_n = int(e.get("n", 1))
			out.catch_floor = floor
		elif ty == "wiped":
			wiped = true
	var who := survivor(up, crew, on_floor)
	if out.id != "" and who != out.id:
		var why := "left"
		if on_floor and up.size() >= 2:
			why = "healed"
		elif on_floor and up.is_empty():
			why = "caught"
		events.append({"type": "lastStandEnd", "t": t, "playerId": out.id, "why": why})
		out.id = ""
		out.since = -1.0
		out.mult = 1.0
	if who != "" and out.id == "":
		out.id = who
		out.since = t
		out.mult = Settings.f(tuning, &"last_stand.bonus", BONUS)
		events.append({"type": "lastStand", "t": t, "playerId": who, "mult": out.mult})
	if wiped:
		out.wipe = {"at": t, "depth": depth, "day": day, "by": out.catch_by if out.catch_by != "" else resident,
			"n": out.catch_n, "last": out.catch_id}
		if out.catch_id != "":
			out.standee = out.catch_id
	return out

## The tick's entity ticks with the survivor's pay multiplied by `mult` (new ticks; the given ones untouched).
static func with_bonus(entities: Array[Instr.EntityTick], id: String, mult: float) -> Array[Instr.EntityTick]:
	if id == "" or mult == 1.0:
		return entities
	var out: Array[Instr.EntityTick] = []
	for e in entities:
		var n := Instr.EntityTick.make(e.id, e.trait_name, e.prev, e.next, e.events)
		n.acting = e.acting
		n.holders = e.holders
		n.limb = e.limb
		var pay: Dictionary = (e.pay as Dictionary).duplicate() if e.pay is Dictionary else {}
		pay[id] = float(pay.get(id, 1.0)) * mult
		n.pay = pay
		out.append(n)
	return out

## The world's "stand" block (net/host.gd, Protocol "stand"): {id, since, mult}, or null without a spotlight.
static func stand_block(st: State) -> Variant:
	if st == null or st.id == "":
		return null
	return {"id": st.id, "since": st.since, "mult": st.mult}
