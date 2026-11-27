# Dangers (DG0): what a kind is handed. Place (once per floor), Tick and Who (every host tick, read-only) and Asks
# (the only ways a danger touches the game). The rules of each ask are sim/dangers.gd's; this file only carries
# them, so a kind never loads the run. See .local's contract for the full list (kept in the repository's words in
# sim/dangers.gd's header).
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Settings = preload("res://sim/settings.gd")

## Placement, once per floor.
class Place:
	extends RefCounted
	## The floor plan (null on the Hanging Ward), the Ward's rules object (sim/ward/state.gd) on the Ward only.
	var plan: Floor.FloorPlan = null
	var ward: Variant = null
	var place: StringName = &""
	var depth: int = 0
	var floor_seed: String = ""
	var tuning: Settings.Values = null
	## The lift's car (sim/run.gd CarGeometry), null on the Ward.
	var car: RefCounted = null
	## This kind's own generator: floor_seed + ":danger:" + kind.
	var rng: Rng = null
	## Walking steps from the landing cell per cell index (Floor.distances_from), -1 where unreachable.
	var lift_steps: PackedInt32Array = PackedInt32Array()
	## Discs {x, z, level, r} nothing may be placed on (see clear()).
	var keep_clear: Array[Dictionary] = []
	## Records already placed on this floor by other kinds.
	var taken: Array[Dictionary] = []

	## Whether a disc of radius r at (level, x, z) touches none of keep_clear.
	func clear(level: int, x: float, z: float, r: float) -> bool:
		for c: Dictionary in keep_clear:
			if int(c["level"]) != level:
				continue
			var dx := x - float(c["x"])
			var dz := z - float(c["z"])
			var reach := r + float(c["r"])
			if dx * dx + dz * dz < reach * reach:
				return false
		return true

## One player as a kind sees them this tick.
class Who:
	extends RefCounted
	var id: String = ""
	var body: Move.Body = null
	var yaw: float = 0.0
	## The cell under them (null on the Ward).
	var cell: Floor.Pos = null
	## &"still", &"creep", &"walk", &"sprint" (still: did not move this tick).
	var speed: StringName = &"still"
	## The input's gait this tick, moving or not (&"creep" crouched, &"walk", &"sprint"): a crouched player standing
	## still reads &"creep" here and &"still" in `speed`.
	var gait: StringName = &"walk"
	## &"stand", or &"crawl" while down.
	var stance: StringName = &"stand"
	## On their feet with an input (status ok), out of nothing.
	var up := false
	var down := false
	var out := false
	var hidden := false
	var pinned := false
	var aboard := false
	## F held this tick (read-only; the kind decides what it means, e.g. a pinned player kicking).
	var use := false
	var held_until := -1.0
	var blind_until := -1.0

## What a kind may read each tick.
class Tick:
	extends RefCounted
	var t: float = 0.0
	var dt: float = 0.05
	var phase: StringName = &""
	var place: StringName = &""
	var depth: int = 0
	var plan: Floor.FloorPlan = null
	var ward: Variant = null
	var tuning: Settings.Values = null
	## Seconds since this floor's doors opened (-1 before).
	var floor_t: float = -1.0
	var players: Array[Who] = []
	## This tick's run events (read-only).
	var events: Array[Dictionary] = []
	var _lit: Callable = Callable()
	var _resident: Move.Body = null
	var _reader := false

	## False inside a danger dark region or while the lift's blink or blackout darkens the floor.
	func lit(level: int, x: float, z: float) -> bool:
		return _lit.call(level, x, z) if _lit.is_valid() else true

	## The resident's feet: null unless this kind is one of sim/dangers.gd RESIDENT_READERS.
	func resident() -> Move.Body:
		return _resident if _reader else null

	func who(id: String) -> Who:
		for w in players:
			if w.id == id:
				return w
		return null

## The asks. Each returns whether it was accepted; it takes effect at once (records step in id order).
class Asks:
	extends RefCounted
	var _do: Callable
	var t: float = 0.0

	func set_state(rec: Dictionary, state: StringName) -> bool:
		if StringName(rec.get("state", &"")) != state:
			rec["state"] = state
			rec["since"] = t
		return true

	## `cause` (DG0R3): the player who set it off when `by` is left "" on purpose (heard as the place's own noise). Only
	## that player's own noise meter reads it (client/own_noise.gd); the rules and the residents never do.
	func noise(rec: Dictionary, at: Move.Body, loud: float, by: String = "", cause: String = "") -> bool:
		return _do.call(&"noise", rec, [at, loud, by, cause])

	## Dark from host time `from` (-1: now; at most 5 s ahead, so every screen darkens on time) until `until`.
	func dark(rec: Dictionary, level: int, x0: float, z0: float, x1: float, z1: float, until: float, from: float = -1.0) -> bool:
		return _do.call(&"dark", rec, [level, x0, z0, x1, z1, until, from])

	## `resident_passes` (DG0R3): the floor's resident plans and walks as if this door were open (the kind opens it as
	## the resident comes, e.g. badge_doors); players, sight and screens still meet it shut.
	func close_edge(rec: Dictionary, level: int, ax: int, ay: int, bx: int, by: int, until: float, resident_passes := false) -> bool:
		return _do.call(&"close_edge", rec, [level, ax, ay, bx, by, until, resident_passes])

	func open_edge(rec: Dictionary, level: int, ax: int, ay: int, bx: int, by: int) -> bool:
		return _do.call(&"open_edge", rec, [level, ax, ay, bx, by])

	func solid(rec: Dictionary, key: int, level: int, x0: float, z0: float, x1: float, z1: float) -> bool:
		return _do.call(&"solid", rec, [key, level, x0, z0, x1, z1])

	func unsolid(rec: Dictionary, key: int) -> bool:
		return _do.call(&"unsolid", rec, [key])

	func stumble(rec: Dictionary, id: String, secs: float, loud: float) -> bool:
		return _do.call(&"stumble", rec, [id, secs, loud])

	func hold(rec: Dictionary, id: String, secs: float) -> bool:
		return _do.call(&"hold", rec, [id, secs])

	func blind(rec: Dictionary, id: String, secs: float) -> bool:
		return _do.call(&"blind", rec, [id, secs])

	func push(rec: Dictionary, id: String, dx: float, dz: float) -> bool:
		return _do.call(&"push", rec, [id, dx, dz])

	func hang(rec: Dictionary, id: String, at: Move.Body, stand: Move.Body) -> bool:
		return _do.call(&"pin", rec, [id, &"hang", at, stand])

	## Hangs on an edge for `secs` (the kind's own live setting); pulled up they stand at `stand`; not in time, out
	## by the run's own rule with body, tape and red spot at `fall`.
	func ledge(rec: Dictionary, id: String, at: Move.Body, stand: Move.Body, secs: float, fall: Move.Body) -> bool:
		return _do.call(&"pin", rec, [id, &"ledge", at, stand, secs, fall])

	func send_out(rec: Dictionary, id: String) -> bool:
		return _do.call(&"send_out", rec, [id])

	func prompt(rec: Dictionary, text: String, reach: float) -> bool:
		return _do.call(&"prompt", rec, [text, reach])

	func cue(rec: Dictionary, cue_name: StringName, at: Move.Body) -> bool:
		return _do.call(&"cue", rec, [cue_name, at])
