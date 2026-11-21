# Split reality, first playable slice (SR1; North Star E1 to E5). Pure rules: no drawing, no network.
#
# What it is (the design's words are in the North Star, section E):
#   - Exposure (E1): each player's own number, 0 to 1, never shown. It rises while that player has the
#     instrument up (taking readings), while nobody is near them (alone) and while they stand in the dark (a
#     blink or the blackout, without their lamp lit). It falls in the lift (E5, aboard the car). The rates are live
#     settings (split.*). On floor 1 to 5 places only: never in the prison, Practice, the Ward or the Reactor.
#   - False sights (E2, the first three): decided here, on the host, from the run's seed, the floor, the day, the
#     player and how many chances have come, and the player's exposure. One player sees each; nobody else is ever
#     sent it (net/host.gd _world_for). They begin only in quiet moments (A5): no blink, nobody down, and no
#     resident within QUIET_METRES of the player, the Minder not running anyone down, the Groundskeeper not coming.
#       phantom: the floor's own resident standing where the real one is not (at least APART_METRES from it), in
#                the player's view; it is heard first (the client plays its sound for HEARD_FIRST seconds before
#                it is drawn).
#       face:    one crewmate drawn as the floor's resident. Guard (fairness): it begins only while every real
#                resident is further than FACE_GUARD_METRES from both the player and the crewmate, and it ends the
#                tick a real resident comes that near either of them. A real catch range is far inside that
#                (Entity.CATCH_RANGE, the reach, the Minder's grab, the Groundskeeper's reach), so a crewmate
#                wearing the resident's face is never anywhere near a real catch.
#       exit:    a lift door drawn on a plain wall (Walls.WALL between two cells) in the player's view. The wall is
#                the floor plan's, so walking into it is walking into the wall.
#   - The touch test (E4): walking into a false sight (within TOUCH_METRES of it, or of the crewmate) or a flare
#     burst lighting it (within flare.reach with a clear line) shows the truth: the sight is marked gone and the
#     client shows it fall apart for REVEAL_SECONDS, then it is dropped.
#   - The witness rule (E3): nothing here enters the resident, the instrument, the catch, the tapes or the quota.
#     The state lives in RunState.split, which only this file reads. A phantom has no body in the rules.
#   - False calm (E1): at split.calm_at and above, the player's view says calm: the client stops the tells.
#
# Not here (second wave or later): wrong labels, the blind spot, the lying announcer, curses, items that clear
# exposure on the floor, the resident wearing a crewmate's face, lens locks (E6).
#
# Called by net/host_rules.gd (the `split_` flag) after the run's step, on the step's own new state.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Walls = preload("res://sim/walls.gd")
const Places = preload("res://sim/places.gd")
const Instr = preload("res://sim/instrument.gd")
const Settings = preload("res://sim/settings.gd")
const Flare = preload("res://sim/flare.gd")
const Rng = preload("res://sim/rng.gd")

## The game's values of the live settings (sim/settings.gd split.*). Rates are in 100 a second.
const READ_RISE := 0.35
const ALONE_RISE := 0.15
const ALONE_METRES := 8.0
const DARK_RISE := 0.5
const LIFT_FALL := 2.0
const FIRST_AT := 30
const CALM_AT := 90
const EVERY := 6.0
const CHANCE := 35
const LASTS := 10.0

## Fixed (the fairness contract, never a setting).
const QUIET_METRES := 15.0
const APART_METRES := 8.0
const FACE_GUARD_METRES := 8.0
const TOUCH_METRES := 1.0
const REVEAL_SECONDS := 0.8
const HEARD_FIRST := 1.5
const FLARED_RECENT := 30.0
const PHANTOM_NEAR := 6.0
const PHANTOM_FAR := 14.0
const EXIT_NEAR := 4.0
const EXIT_FAR := 12.0
const FACE_NEAR := 3.0
const FACE_FAR := 15.0
## The places that have false sights in this slice (floors 1 to 5).
const PLACES: Array[StringName] = [Places.CLINIC, Places.ANNEX, Places.PLAYROOM, Places.ARBORETUM]
const KINDS: Array[StringName] = [&"phantom", &"exit", &"face"]
## Floors 1 to 5 of each cycle: never the Hanging Ward (6) or the Reactor (7), whatever plan they stand on.
const LAST_FLOOR := 5

class SplitState extends RefCounted:
	## {player id: exposure 0..1}
	var exposure: Dictionary = {}
	## Every live false sight: {id, for, kind, x, y, z, level, yaw, who, from, until, gone (-1 or the reveal time)}.
	var sights: Array[Dictionary] = []
	## The floor the sights and the chances belong to.
	var plan: Floor.FloorPlan = null
	var next_roll := -1.0
	var rolls := 0
	var seq := 0
	## {victim id: [flarer id, host time]}: the last crewmate who flared each player (E2, wrong face).
	var flared_by: Dictionary = {}

	func copy() -> SplitState:
		var c := SplitState.new()
		c.exposure = exposure.duplicate()
		c.sights = sights.duplicate()
		c.plan = plan
		c.next_roll = next_roll
		c.rolls = rolls
		c.seq = seq
		c.flared_by = flared_by.duplicate()
		return c

## The run with split reality on (exposure 0 for everyone).
static func with_split(s0: Run.RunState) -> Run.RunState:
	var s := s0.copy()
	var sp := SplitState.new()
	sp.plan = s.plan
	s.split = sp
	return s

static func of(s: Run.RunState) -> SplitState:
	return s.split as SplitState if s.split != null else null

static func exposure_of(s: Run.RunState, id: String) -> float:
	var sp := of(s)
	return float(sp.exposure.get(id, 0.0)) if sp != null else 0.0

static func calm(s: Run.RunState, id: String) -> bool:
	return of(s) != null and exposure_of(s, id) * 100.0 >= float(Settings.i(s.tuning, &"split.calm_at", CALM_AT)) - 1e-9

## The floors with false sights: the four places of floors 1 to 5, never the prison, Practice, the Ward or the Reactor.
static func sight_floor(s: Run.RunState) -> bool:
	return s.plan != null and s.depth >= 1 and not s.orientation and not Run.at_home(s) and s.station == null and PLACES.has(s.plan.place) 			and (s.depth - 1) % Places.CYCLE_FLOORS < LAST_FLOOR

## What player `id`'s own screen is sent (net/host.gd _world_for): their exposure, whether it is false calm, and
## their own sights only. Null with the flag off.
static func view(s: Run.RunState, id: String) -> Variant:
	var sp := of(s)
	if sp == null:
		return null
	var rows: Array = []
	for g in sp.sights:
		if g["for"] == id:
			rows.append(g.duplicate())
	return {"e": exposure_of(s, id), "calm": calm(s, id), "sights": rows}

# ---------------------------------------------------------------------------------------------
# The step.

## One tick, after the run's own step: `s` is the step's new state (replaced in place, as the doorway shadow is).
static func step(s: Run.RunState, inputs: Array[Run.PlayerInput], dt: float, events: Array[Dictionary]) -> void:
	var old := of(s)
	if old == null:
		return
	var sp := old.copy()
	var input_of := {}
	for i in inputs:
		input_of[i.id] = i
	if sp.plan != s.plan:
		sp.plan = s.plan
		sp.sights = []
		sp.flared_by = {}
		sp.next_roll = s.t + Settings.f(s.tuning, &"split.every", EVERY)
	for e in events:
		if e.get("type") == "flareUsed" and str(e.get("blind", "")) != "":
			sp.flared_by[str(e["blind"])] = [str(e["playerId"]), s.t]
	_step_exposure(s, sp, input_of, dt)
	_end_sights(s, sp, input_of, events)
	if sight_floor(s) and s.t >= sp.next_roll - 1e-9:
		sp.next_roll = s.t + Settings.f(s.tuning, &"split.every", EVERY)
		sp.rolls += 1
		for p in s.players:
			if input_of.has(p.id):
				_roll(s, sp, p, input_of[p.id])
	s.split = sp

static func _rise(s: Run.RunState, p: Run.RunPlayer, input_of: Dictionary) -> float:
	var rate := 0.0
	var m := Instr.member(s.crew, p.id)
	if m != null and m.instrument.raised:
		rate += Settings.f(s.tuning, &"split.read_rise", READ_RISE)
	var near := Settings.f(s.tuning, &"split.alone_m", ALONE_METRES)
	var alone := true
	for q in s.players:
		if q.id != p.id and q.status == &"ok" and input_of.has(q.id) and q.body.level == p.body.level \
				and Vector2(q.body.x - p.body.x, q.body.z - p.body.z).length() <= near:
			alone = false
			break
	if alone:
		rate += Settings.f(s.tuning, &"split.alone_rise", ALONE_RISE)
	if Run.blinking(s) and not bool(Run.lamp_of(s, p.id).get("on", false)):
		rate += Settings.f(s.tuning, &"split.dark_rise", DARK_RISE)
	return rate / 100.0

static func _step_exposure(s: Run.RunState, sp: SplitState, input_of: Dictionary, dt: float) -> void:
	for p in s.players:
		if p.status != &"ok" or not input_of.has(p.id):
			continue
		var e := float(sp.exposure.get(p.id, 0.0))
		if p.aboard or s.phase == &"riding":
			e -= Settings.f(s.tuning, &"split.lift_fall", LIFT_FALL) / 100.0 * dt
		elif sight_floor(s):
			e += _rise(s, p, input_of) * dt
		sp.exposure[p.id] = clampf(e, 0.0, 1.0)

## The real residents' bodies on this floor (none with the resident off).
static func residents(s: Run.RunState) -> Array[Move.Body]:
	var out: Array[Move.Body] = []
	if s.seek_off:
		return out
	if s.seek != null:
		out.append(s.seek.minder.body)
	elif s.garden != null:
		out.append(s.garden.keeper.body)
	elif s.orderly != null:
		out.append(s.orderly.body)
	if s.orderly2 != null:
		out.append(s.orderly2.body)
	return out

static func _dist(a: Move.Body, x: float, y: float, z: float) -> float:
	return Vector3(a.x - x, a.y - y, a.z - z).length()

static func _resident_within(s: Run.RunState, x: float, y: float, z: float, metres: float) -> bool:
	for b in residents(s):
		if _dist(b, x, y, z) < metres:
			return true
	return false

## A quiet moment for player `p` (A5: false sights only begin in quiet moments, never during a chase).
static func quiet(s: Run.RunState, p: Run.RunPlayer) -> bool:
	if s.phase != &"away" and s.phase != &"coming":
		return false
	if Run.blinking(s) or not s.down.is_empty():
		return false
	if s.seek != null and s.seek.minder.mode in [&"run", &"catch", &"grab", &"drag"]:
		return false
	if s.garden != null and s.garden.keeper.mode in [&"coming", &"lean", &"strike"]:
		return false
	return not _resident_within(s, p.body.x, p.body.y, p.body.z, QUIET_METRES)

static func _hash01(text: String) -> float:
	return float(Rng.hash_seed(text) % 100000) / 100000.0

## The seeded key of one player's chance: the same seed, floor, day, player and chance give the same sight.
static func _key(s: Run.RunState, sp: SplitState, id: String) -> String:
	return "%s:split:%d:%d:%s:%d" % [s.seed, s.depth, s.day_index, id, sp.rolls]

## The chance of a false sight at exposure `e` (0 below split.first_at, split.chance at the top).
static func chance_at(s: Run.RunState, e: float) -> float:
	var first := float(Settings.i(s.tuning, &"split.first_at", FIRST_AT)) / 100.0
	if e < first or first >= 1.0:
		return 0.0
	var top := float(Settings.i(s.tuning, &"split.chance", CHANCE)) / 100.0
	return top * clampf((e - first) / maxf(1.0 - first, 1e-6), 0.0, 1.0) if e < 1.0 else top

static func _roll(s: Run.RunState, sp: SplitState, p: Run.RunPlayer, i: Run.PlayerInput) -> void:
	if p.status != &"ok" or p.aboard:
		return
	for g in sp.sights:
		if g["for"] == p.id:
			return
	if not quiet(s, p):
		return
	var key := _key(s, sp, p.id)
	if _hash01(key + ":roll") >= chance_at(s, float(sp.exposure.get(p.id, 0.0))):
		return
	var first := Rng.hash_seed(key + ":kind") % KINDS.size()
	for n in KINDS.size():
		var kind := KINDS[(first + n) % KINDS.size()]
		var g := place(s, sp, kind, p, i, key)
		if not g.is_empty():
			sp.seq += 1
			g["id"] = sp.seq
			g["for"] = p.id
			g["kind"] = String(kind)
			g["from"] = s.t + (HEARD_FIRST if kind == &"phantom" else 0.0)
			g["until"] = s.t + Settings.f(s.tuning, &"split.lasts", LASTS)
			g["gone"] = -1.0
			sp.sights.append(g)
			return

static func _viewer(i: Run.PlayerInput) -> Sight.Viewer:
	var v := Sight.Viewer.new()
	v.body = i.body
	v.eye = i.eye
	v.yaw = i.yaw
	v.pitch = i.pitch
	v.h_fov_deg = i.h_fov_deg
	v.v_fov_deg = i.v_fov_deg
	return v

static func _seen(s: Run.RunState, i: Run.PlayerInput, x: float, y: float, z: float) -> bool:
	var eye := Sight.Point3.make(i.body.x, i.body.y + i.eye, i.body.z, i.body.level)
	return Sight.in_view_cone(_viewer(i), x, y, z, 0.0) and Sight.has_line_of_sight(s.plan, eye, Sight.Point3.make(x, y, z, i.body.level))

static func floor_y(level: int) -> float:
	return Move.LEVEL_HEIGHT if level == 1 else 0.0

## Where a sight of `kind` goes for player `p` (with input `i`), or {} when none fits. Seeded by `key`.
static func place(s: Run.RunState, sp: SplitState, kind: StringName, p: Run.RunPlayer, i: Run.PlayerInput, key: String) -> Dictionary:
	match kind:
		&"phantom":
			return _place_phantom(s, p, i, key)
		&"exit":
			return _place_exit(s, p, i, key)
		&"face":
			return _place_face(s, sp, p, i, key)
	return {}

static func _face_yaw(fx: float, fz: float, tx: float, tz: float) -> float:
	return atan2(-(tx - fx), -(tz - fz))

static func _place_phantom(s: Run.RunState, p: Run.RunPlayer, i: Run.PlayerInput, key: String) -> Dictionary:
	var plan := s.plan
	var cs := float(plan.cell_size)
	var n := plan.width * plan.height
	if n <= 0:
		return {}
	var level := p.body.level
	var y := floor_y(level)
	var start := Rng.hash_seed(key + ":phantom") % n
	for k in n:
		var c := (start + k) % n
		var cx := c % plan.width
		var cy := c / plan.width
		if not Floor.is_walkable(plan, level, cx, cy):
			continue
		var x := (cx + 0.5) * cs
		var z := (cy + 0.5) * cs
		var d := Vector2(x - p.body.x, z - p.body.z).length()
		if d < PHANTOM_NEAR or d > PHANTOM_FAR:
			continue
		if _resident_within(s, x, y, z, APART_METRES) or _player_within(s, x, z, level, 2.0):
			continue
		if not _seen(s, i, x, y + 1.2, z):
			continue
		return {"x": x, "y": y, "z": z, "level": level, "yaw": _face_yaw(x, z, p.body.x, p.body.z), "who": ""}
	return {}

static func _player_within(s: Run.RunState, x: float, z: float, level: int, metres: float) -> bool:
	for q in s.players:
		if q.body.level == level and Vector2(q.body.x - x, q.body.z - z).length() < metres:
			return true
	return false

const SIDES: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## A plain wall in view: the edge between a walkable cell and its neighbour that the plan makes a wall. The sight
## stands on the wall's face, its yaw facing into the walkable cell.
static func _place_exit(s: Run.RunState, p: Run.RunPlayer, i: Run.PlayerInput, key: String) -> Dictionary:
	var plan := s.plan
	var cs := float(plan.cell_size)
	var n := plan.width * plan.height
	if n <= 0:
		return {}
	var level := p.body.level
	var y := floor_y(level)
	var landing := Vector2((plan.landing.x + 0.5) * cs, (plan.landing.y + 0.5) * cs) if plan.landing != null else Vector2.INF
	var start := Rng.hash_seed(key + ":exit") % n
	for k in n:
		var c := (start + k) % n
		var cx := c % plan.width
		var cy := c / plan.width
		if not Floor.is_walkable(plan, level, cx, cy):
			continue
		for side in SIDES:
			if Walls.edge_kind(plan, level, cx, cy, cx + side.x, cy + side.y) != Walls.WALL:
				continue
			var x := (cx + 0.5 + side.x * 0.5) * cs
			var z := (cy + 0.5 + side.y * 0.5) * cs
			var d := Vector2(x - p.body.x, z - p.body.z).length()
			if d < EXIT_NEAR or d > EXIT_FAR or Vector2(x, z).distance_to(landing) < 6.0:
				continue
			# The face of the wall, a little into the cell, is what the player must see.
			var fx := x - side.x * 0.3
			var fz := z - side.y * 0.3
			if not _seen(s, i, fx, y + 1.2, fz):
				continue
			return {"x": x, "y": y, "z": z, "level": level, "yaw": atan2(float(side.x), float(side.y)), "who": ""}
	return {}

static func _place_face(s: Run.RunState, sp: SplitState, p: Run.RunPlayer, i: Run.PlayerInput, key: String) -> Dictionary:
	var order: Array[Run.RunPlayer] = []
	var flared: Variant = sp.flared_by.get(p.id)
	# E2: more likely to wear the face of someone who just flared you: they are asked first.
	if flared is Array and s.t - float(flared[1]) <= FLARED_RECENT:
		for q in s.players:
			if q.id == str(flared[0]):
				order.append(q)
	var first := Rng.hash_seed(key + ":face") % maxi(1, s.players.size())
	for k in s.players.size():
		var q := s.players[(first + k) % s.players.size()]
		if not order.has(q):
			order.append(q)
	for q in order:
		if q.id == p.id or q.status != &"ok" or q.aboard or q.body.level != p.body.level:
			continue
		var d := Vector2(q.body.x - p.body.x, q.body.z - p.body.z).length()
		if d < FACE_NEAR or d > FACE_FAR:
			continue
		if not face_guard_ok(s, p.body, q.body):
			continue
		if not _seen(s, i, q.body.x, q.body.y + 1.2, q.body.z):
			continue
		return {"x": q.body.x, "y": q.body.y, "z": q.body.z, "level": q.body.level, "yaw": 0.0, "who": q.id}
	return {}

## The wrong face's guard: every real resident further than FACE_GUARD_METRES from both the viewer and the crewmate.
static func face_guard_ok(s: Run.RunState, viewer: Move.Body, mate: Move.Body) -> bool:
	return not _resident_within(s, viewer.x, viewer.y, viewer.z, FACE_GUARD_METRES) and not _resident_within(s, mate.x, mate.y, mate.z, FACE_GUARD_METRES)

static func _player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for q in s.players:
		if q.id == id:
			return q
	return null

## Ends what has run its time, what its player can no longer see, a wrong face that the guard ends, a phantom the real
## resident has come to; reveals what was touched or lit by a flare (E4).
static func _end_sights(s: Run.RunState, sp: SplitState, input_of: Dictionary, events: Array[Dictionary]) -> void:
	var kept: Array[Dictionary] = []
	for g0 in sp.sights:
		var g := g0
		var gone := float(g["gone"])
		if gone >= 0.0:
			if s.t < gone + REVEAL_SECONDS - 1e-9:
				kept.append(g)
			continue
		var p := _player(s, str(g["for"]))
		if p == null or p.status != &"ok" or p.aboard or not input_of.has(p.id) or not sight_floor(s) or s.t >= float(g["until"]) - 1e-9:
			continue
		var at := Vector3(float(g["x"]), float(g["y"]), float(g["z"]))
		var level := int(g["level"])
		if g["kind"] == "face":
			var q := _player(s, str(g["who"]))
			if q == null or q.status != &"ok" or q.aboard or q.body.level != p.body.level or not face_guard_ok(s, p.body, q.body):
				continue
			g = g.duplicate()
			g["x"] = q.body.x
			g["y"] = q.body.y
			g["z"] = q.body.z
			at = Vector3(q.body.x, q.body.y, q.body.z)
		elif g["kind"] == "phantom" and _resident_within(s, at.x, at.y, at.z, 3.0):
			continue
		var touched := p.body.level == level and Vector2(p.body.x - at.x, p.body.z - at.z).length() <= TOUCH_METRES + (0.2 if g["kind"] == "face" else 0.0)
		var lit := false
		for e in events:
			if e.get("type") == "flareUsed" and int(e.get("level", -99)) == level:
				var burst := Move.Body.make(float(e["x"]), float(e["z"]), level, float(e["y"]))
				var spot := Move.Body.make(at.x, at.z, level, at.y)
				if Flare.within(burst, spot, Settings.f(s.tuning, &"flare.reach", Flare.REACH)) and Flare.clear(s.plan, burst, spot):
					lit = true
		if touched or lit:
			g = g.duplicate()
			g["gone"] = s.t
		kept.append(g)
	sp.sights = kept
