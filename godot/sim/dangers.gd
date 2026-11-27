# Dangers (DG0): the shared base every danger plugs into. Pure rules, no drawing, no network.
#
# Off unless asked: a run made without dangers has RunState.dangers == null and nothing here ever runs
# (net/host_rules.gd dangers, the last parameter; data/dangers.json "enabled", which ships empty; the start argument
# dangers=<kind,kind|all|0>). With kinds enabled, net/host_rules.gd step() calls step() after the run's tick (and
# net/host.gd on the Hanging Ward, after the Ward's), on the tick's own new state. It writes `dangers` and, through
# the asks, the players' statuses, bodies and the run's down list, always by the run's own rules.
#
# A floor's dangers: as the crew reaches a floor (never the prison, a ride, Practice), the enabled kinds whose data
# line lists the floor's place are drawn by this file's own generator (floor seed + ":danger:pick"), at most
# danger.per_floor of them (danger.per_floor_deep from floor danger.deep_from), and each places its records with its
# own generator (floor seed + ":danger:" + kind). Every tick each record steps in id order. A kind changes the game
# only through the asks (sim/dangers/api.gd Asks):
#  - noise: heard by the floor's resident on the next run tick exactly as its own noises (sim/run.gd: the
#    Groundskeeper's heard noises, the Minder's lumps of anger, the Reactor's point noises; net/host.gd: the Rigger's
#    loud noise). The Orderly and the Temp never hunt by sound.
#  - dark: a rectangle where a Stillness resident is unseen, as in a blink (sim/run.gd _step_stillness).
#  - close_edge / open_edge: a door between two cells shut for walking (a box in Run.solids_in, host and screens) and
#    sight (Stillness views, the Temp's company line), never within 0.9 m of anyone, never longer than
#    danger.door_max: the base reopens it at its time, so nobody is ever sealed in.
#  - solid / unsolid: a kind's own box in the walk model.
#  - stumble / hold / blind / push: a player held where they stand, blinded, or moved by the walk model.
#  - hang / ledge / send_out (active kinds only, never on the Ward): the run's own down ("downed" by "danger") with
#    the body pinned; a crewmate's heal is the cut down or the pull up; the down timer's "out" is the run's own. Each
#    is refused when it would leave the crew nobody up (on their feet, not pinned, not in the car).
#  - prompt and cue: what screens show and play.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Settings = preload("res://sim/settings.gd")
const Places = preload("res://sim/places.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Api = preload("res://sim/dangers/api.gd")
const Effects = preload("res://sim/dangers/effects.gd")
const DangerFloor = Effects.DangerFloor

## Every kind: name -> its rules file. A kind whose file does not exist yet is skipped. One line per kind,
## alphabetical; kinds never edit this list.
const KINDS := {
	&"badge_doors": "res://sim/dangers/badge_doors.gd",
	&"failing_lights": "res://sim/dangers/failing_lights.gd",
	&"grabber": "res://sim/dangers/grabber.gd",
	&"gusts": "res://sim/dangers/gusts.gd",
	&"roost": "res://sim/dangers/roost.gd",
	&"snare": "res://sim/dangers/snare.gd",
	&"steam": "res://sim/dangers/steam.gd",
	&"test_tile": "res://sim/dangers/test_tile.gd",
	&"trapdoor": "res://sim/dangers/trapdoor.gd",
	&"waking_toys": "res://sim/dangers/waking_toys.gd",
}
## Kinds allowed to read the resident's feet (Api.Tick.resident(): its level, x and z). badge_doors: a door never shuts
## on the Temp, and the lead ruled it may see where the Temp stands to time its doors.
const RESIDENT_READERS: Array[StringName] = [&"badge_doors"]
const DATA_PATH := "res://data/dangers.json"

## Base live settings' game values (sim/settings.gd rows danger.*).
const PER_FLOOR := 1
const PER_FLOOR_DEEP := 2
const DEEP_FROM := 8
const DOOR_MAX := 30.0
const HOLD_MAX := 3.0
const DARK_MAX := 10.0
## How far ahead a dark region may be announced (seconds).
const DARK_LEAD := 5.0
## Nobody within this of a doorway's middle when it shuts (metres).
const DOOR_CLEAR := 0.9
## The most a push moves a player (metres).
const PUSH_MAX := 2.0
const PLAYER_RADIUS := 0.3
const EPS := 1e-9

static var _data: Dictionary = {}
static var _instances: Dictionary = {}

## data/dangers.json, read once: {"enabled": [...], "kinds": {kind: {places, active, test_only}}}.
static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_data = parsed
	return _data

## The data line of a kind ({} when none).
static func info(kind: StringName) -> Dictionary:
	var kinds: Dictionary = data().get("kinds", {})
	return kinds.get(String(kind), {})

## Whether the kind's rules file exists in this build.
static func exists(kind: StringName) -> bool:
	return KINDS.has(kind) and ResourceLoader.exists(String(KINDS[kind]))

## The kind's instance (one per kind), or null.
static func kind_of(kind: StringName) -> RefCounted:
	if _instances.has(kind):
		return _instances[kind]
	if not exists(kind):
		return null
	var script: Script = load(String(KINDS[kind]))
	var inst: RefCounted = script.new()
	_instances[kind] = inst
	return inst

## Every kind `all` turns on: those with a file, not test_only, alphabetical.
static func all_kinds() -> Array[StringName]:
	var out: Array[StringName] = []
	var names: Array = KINDS.keys()
	names.sort()
	for k: StringName in names:
		if exists(k) and not bool(info(k).get("test_only", false)):
			out.append(k)
	return out

## A list of names as asked (strings or names, "all", "0"), kept to kinds with a file, sorted, unique.
static func resolve(asked: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for raw: Variant in asked:
		var name := StringName(str(raw).strip_edges())
		if name == &"all":
			for k in all_kinds():
				if not out.has(k):
					out.append(k)
		elif name != &"" and name != &"0" and exists(name) and not out.has(name):
			out.append(name)
	out.sort()
	return out

## The enabled list from data/dangers.json (ships empty).
static func data_enabled() -> Array[StringName]:
	return resolve(data().get("enabled", []))

## The run with these kinds on (unchanged with none).
static func with_dangers(s0: Run.RunState, kinds: Array) -> Run.RunState:
	var list := resolve(kinds)
	if list.is_empty():
		return s0
	var s := s0.copy()
	var d := DangerFloor.new()
	d.kinds = list
	s.dangers = d
	return s

static func _f(s: Run.RunState, id: StringName, fallback: float) -> float:
	return Settings.f(s.tuning, id, fallback)

# ---------------------------------------------------------------------------------------------
# The step.

## The floor the dangers belong to, or "" (the prison, a ride, Practice, an ended run).
static func floor_key(s: Run.RunState, ward: Variant) -> String:
	if s.plan == null or s.orientation or s.depth < 1 or Run.at_home(s) or s.phase == &"riding" or s.phase == &"ended":
		return ""
	return "%d:%d:%d" % [s.day_index, s.depth, 1 if ward != null else 0]

## The place a kind's data line names for this floor.
static func place_of(s: Run.RunState, ward: Variant) -> StringName:
	return &"ward" if ward != null else s.plan.place

class Ctx:
	extends RefCounted
	var s: Run.RunState
	var d: DangerFloor
	var players: Array[Run.RunPlayer]
	var events: Array[Dictionary]
	var t: float
	var ward: Variant
	var kind: StringName
	var changed_players := false

## One step after the run's tick (see the header). Mutates `s` (a state this tick made: dangers, players, down,
## spots) and appends to `events`. `ward`: the Hanging Ward's rules object when stepped by net/host.gd there.
static func step(s: Run.RunState, inputs: Array[Run.PlayerInput], dt: float, events: Array[Dictionary], ward: Variant = null) -> void:
	if s.dangers == null:
		return
	var d := (s.dangers as DangerFloor).copy()
	var t := s.t
	# The noises of the last step were heard by this tick's run.
	d.heard = []
	d.prompts = []
	var c := Ctx.new()
	c.s = s
	c.d = d
	c.players = s.players.duplicate()
	c.events = events
	c.t = t
	c.ward = ward
	# Pins first: healed, out or gone players come down off their pin onto its stand spot.
	_settle_pins(c)
	var key := floor_key(s, ward)
	if key != d.floor_key:
		_new_floor(c, key)
	for e in events:
		if e["type"] == "doorsOpened" and str(e.get("reason", "")) == "arrival":
			d.opened_at = t
	_expire(c)
	if not d.records.is_empty():
		var k := _tick(c, inputs, dt)
		var ask := Api.Asks.new()
		ask.t = t
		var records: Array[Dictionary] = []
		for r0 in d.records:
			var rec: Dictionary = r0.duplicate(true)
			var kind := kind_of(StringName(rec["kind"]))
			if kind == null:
				records.append(rec)
				continue
			c.kind = StringName(rec["kind"])
			k._reader = RESIDENT_READERS.has(c.kind)
			ask._do = _doer(c)
			if d.forced.has(int(rec["id"])):
				kind.force(rec, StringName(d.forced[int(rec["id"])]), k, ask)
			else:
				kind.step(rec, k, ask)
			records.append(rec)
		d.records = records
		d.forced = {}
	# Where each player stood this tick (a kind's "still").
	var last := {}
	for p in c.players:
		last[p.id] = p.body
	d.last = last
	s.dangers = d
	if c.changed_players:
		s.players = c.players

static func _doer(c: Ctx) -> Callable:
	return func(op: StringName, rec: Dictionary, args: Array) -> bool:
		return _ask(c, op, rec, args)

## A new floor: everything of the last one goes, and the kinds drawn for this one place their records.
static func _new_floor(c: Ctx, key: String) -> void:
	var d := c.d
	d.floor_key = key
	d.records = []
	d.dark = []
	d.doors = []
	d.solids = {}
	d.fx = {}
	d.pins = {}
	d.opened_at = -1.0
	d.dirty()
	if key == "":
		return
	var s := c.s
	var place := place_of(s, c.ward)
	var candidates: Array[StringName] = []
	for k in d.kinds:
		var places: Array = info(k).get("places", [])
		if places.has(String(place)) and kind_of(k) != null:
			if c.ward != null and bool(info(k).get("active", false)):
				continue
			candidates.append(k)
	if candidates.is_empty():
		return
	var floor_seed := Run.day_seed(s.seed, s.day_index) + ":%d" % s.depth
	var want := Settings.i(s.tuning, &"danger.per_floor_deep", PER_FLOOR_DEEP) if s.depth >= Settings.i(s.tuning, &"danger.deep_from", DEEP_FROM) \
		else Settings.i(s.tuning, &"danger.per_floor", PER_FLOOR)
	var pick := Rng.make_rng(floor_seed + ":danger:pick")
	var chosen: Array[StringName] = []
	var pool := candidates.duplicate()
	while chosen.size() < want and not pool.is_empty():
		var i := int(floor(pick.next() * float(pool.size())))
		chosen.append(pool[i])
		pool.remove_at(i)
	chosen.sort()
	var clear := keep_clear_of(s, c.ward)
	var steps := PackedInt32Array()
	if s.plan != null and c.ward == null:
		steps = Floor.distances_from(s.plan, s.plan.landing)
	for k in chosen:
		var p := Api.Place.new()
		p.plan = s.plan if c.ward == null else null
		p.ward = c.ward
		p.place = place
		p.depth = s.depth
		p.floor_seed = floor_seed
		p.tuning = s.tuning
		p.car = s.car if c.ward == null else null
		p.rng = Rng.make_rng(floor_seed + ":danger:" + String(k))
		p.lift_steps = steps
		p.keep_clear = clear
		p.taken = d.records.duplicate()
		var placed: Array[Dictionary] = kind_of(k).place(p)
		var first: StringName = kind_of(k).states()[0]
		for r in placed:
			var rec := r.duplicate(true)
			rec["id"] = d.next_id
			d.next_id += 1
			rec["kind"] = k
			rec["since"] = c.t
			if not rec.has("state"):
				rec["state"] = first
			for f: String in ["x", "y", "z", "yaw"]:
				rec[f] = float(rec.get(f, 0.0))
			rec["level"] = int(rec.get("level", 0))
			if not rec.has("n"):
				rec["n"] = []
			if not rec.has("k"):
				rec["k"] = {}
			d.records.append(rec)

## The discs nothing may be placed on: the lift and landing, both sides of every doorway, every hide, every piece of
## furniture (findables and hides among them), the Playroom's table, the Reactor's cabinet.
static func keep_clear_of(s: Run.RunState, ward: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if ward != null or s.plan == null:
		return out
	var plan := s.plan
	var cs := float(plan.cell_size)
	out.append({"x": (plan.landing.x + 0.5) * cs, "z": (plan.landing.y + 0.5) * cs, "level": plan.landing.level, "r": 4.0})
	if s.car != null:
		var r := s.car.rect
		out.append({"x": (r.x0 + r.x1) * 0.5, "z": (r.z0 + r.z1) * 0.5, "level": s.car.level, "r": maxf(r.x1 - r.x0, r.z1 - r.z0)})
	for door in plan.doors:
		out.append({"x": (door.ax + door.bx + 1) * 0.5 * cs, "z": (door.ay + door.by + 1) * 0.5 * cs, "level": door.level, "r": 1.4})
		out.append({"x": (door.ax + 0.5) * cs, "z": (door.ay + 0.5) * cs, "level": door.level, "r": 0.8})
		out.append({"x": (door.bx + 0.5) * cs, "z": (door.by + 0.5) * cs, "level": door.level, "r": 0.8})
	if plan.place != Places.REACTOR:
		for h in Hides.hides_for(plan):
			out.append({"x": h.inside.x / 100.0, "z": h.inside.y / 100.0, "level": h.level, "r": 1.2})
			out.append({"x": h.front.x / 100.0, "z": h.front.y / 100.0, "level": h.level, "r": 1.0})
	if plan.place == Places.CLINIC or plan.place == Places.ANNEX:
		for piece in Furniture.pieces_for(plan, plan.seed, plan.depth, s.furniture_layout):
			out.append({"x": piece.x / 100.0, "z": piece.y / 100.0, "level": piece.level, "r": maxf(piece.w, piece.d) / 200.0 + 0.6})
	for key: String in plan.station:
		var v: Variant = plan.station[key]
		if v is Vector3:
			out.append({"x": (v as Vector3).x, "z": (v as Vector3).z, "level": 0, "r": 2.0})
	return out

## Pins end when the player is no longer down (healed, out, or the car left them): they come down onto the stand
## spot. An "out" this tick moves its red spot there too.
static func _settle_pins(c: Ctx) -> void:
	var d := c.d
	if d.pins.is_empty():
		return
	var pins := d.pins.duplicate()
	var ids: Array = pins.keys()
	ids.sort()
	for id: String in ids:
		var k := _index_of(c.players, id)
		var pin: Dictionary = pins[id]
		if k >= 0 and c.players[k].status == &"down":
			continue
		pins.erase(id)
		if k < 0:
			continue
		# Healed: onto the stand spot; out (or left by the car): where they fall (a ledge's fall spot; a hang's stand).
		var stand: Move.Body = pin["stand"] if c.players[k].status == &"ok" else pin.get("fall", pin["stand"])
		var np := c.players[k].copy()
		np.body = stand
		c.players[k] = np
		c.changed_players = true
		var spots: Array[Dictionary] = c.s.spots.duplicate()
		for i in spots.size():
			if str(spots[i]["playerId"]) == id:
				var sp := spots[i].duplicate()
				sp["x"] = Run._cm(stand.x)
				sp["z"] = Run._cm(stand.z)
				sp["y"] = Run._cm(stand.y)
				sp["level"] = stand.level
				spots[i] = sp
		c.s.spots = spots
		c.events.append({"type": "dangerUnpinned", "t": c.t, "id": int(pin["rec"]), "playerId": id, "at": stand,
			"why": "healed" if np.status == &"ok" else String(np.status)})
	d.pins = pins

## Dark regions, closed doors and player effects whose time is over.
static func _expire(c: Ctx) -> void:
	var d := c.d
	var t := c.t
	var dark: Array = []
	for r: Array in d.dark:
		if t < float(r[5]) - EPS:
			dark.append(r)
	d.dark = dark
	var doors: Array = []
	for e: Array in d.doors:
		if t < float(e[5]) - EPS:
			doors.append(e)
		else:
			c.events.append({"type": "dangerDoor", "t": t, "id": int(e[6]), "level": int(e[0]), "ax": int(e[1]), "ay": int(e[2]),
				"bx": int(e[3]), "by": int(e[4]), "open": true})
	if doors.size() != d.doors.size():
		d.doors = doors
		d.dirty()
	var fx := {}
	for id: String in d.fx:
		if t < float(d.fx[id]["until"]) - EPS:
			fx[id] = d.fx[id]
	d.fx = fx

static func _index_of(players: Array[Run.RunPlayer], id: String) -> int:
	for i in players.size():
		if players[i].id == id:
			return i
	return -1

## What every kind may read this tick.
static func _tick(c: Ctx, inputs: Array[Run.PlayerInput], dt: float) -> Api.Tick:
	var s := c.s
	var d := c.d
	var k := Api.Tick.new()
	k.t = c.t
	k.dt = dt
	k.phase = s.phase
	k.place = place_of(s, c.ward)
	k.depth = s.depth
	k.plan = s.plan if c.ward == null else null
	k.ward = c.ward
	k.tuning = s.tuning
	k.floor_t = c.t - d.opened_at if d.opened_at >= 0.0 else -1.0
	k.events = c.events
	# Its feet only (level, x, z; y kept so the body is whole), never its mode, target or anything else.
	k._resident = Move.Body.make(s.orderly.body.x, s.orderly.body.z, s.orderly.body.level, s.orderly.body.y) if s.orderly != null and s.orderly.body != null else null
	var blink := Run.blinking(s)
	k._lit = func(level: int, x: float, z: float) -> bool:
		return not blink and not Effects.dark_at(d, level, x, z, c.t)
	var input_of := {}
	for i in inputs:
		input_of[i.id] = i
	var last: Dictionary = d.last
	for p in c.players:
		var w := Api.Who.new()
		w.id = p.id
		w.body = p.body
		var inp: Run.PlayerInput = input_of.get(p.id)
		w.yaw = inp.yaw if inp != null else 0.0
		w.use = inp != null and inp.use
		if k.plan != null and p.body != null:
			w.cell = Move.cell_of(k.plan, p.body)
		var before: Move.Body = last.get(p.id)
		var moved := before != null and p.body != null and (before.level != p.body.level or absf(before.x - p.body.x) > 1e-6 or absf(before.z - p.body.z) > 1e-6)
		w.gait = inp.gait if inp != null else &"walk"
		w.speed = w.gait if moved else &"still"
		w.down = p.status == &"down"
		w.stance = &"crawl" if w.down else &"stand"
		w.out = p.status == &"out" or p.status == &"caught" or p.status == &"leftBehind"
		w.pinned = d.pins.has(p.id)
		w.aboard = p.aboard
		w.up = p.status == &"ok" and inp != null and not w.pinned
		w.hidden = _hidden(s, p.id)
		var fm: Variant = d.fx.get(p.id + "|move")
		if fm is Dictionary:
			w.held_until = float(fm["until"])
		var fb: Variant = d.fx.get(p.id + "|blind")
		if fb is Dictionary:
			w.blind_until = float(fb["until"])
		k.players.append(w)
	return k

static func _hidden(s: Run.RunState, id: String) -> bool:
	if s.hiding != null:
		var h: Variant = Run.Hiding.player_of(s.hiding, id)
		if h != null and h.phase == &"inside":
			return true
	if s.seek != null:
		var sp: Variant = Run.Seek.player_of(s.seek, id)
		if sp != null and sp.phase == &"inside":
			return true
	return false

## Up players other than `except`: on their feet with nothing holding them, out of the car.
static func up_count(c: Ctx, except: String) -> int:
	var n := 0
	for p in c.players:
		if p.id != except and p.status == &"ok" and not p.aboard and not c.d.pins.has(p.id):
			n += 1
	return n

# ---------------------------------------------------------------------------------------------
# The asks.

static func _ask(c: Ctx, op: StringName, rec: Dictionary, a: Array) -> bool:
	var s := c.s
	var d := c.d
	var t := c.t
	var rid := int(rec["id"])
	match op:
		&"noise":
			var at: Move.Body = a[0]
			var loud := float(a[1])
			if at == null or loud <= 0.0:
				return false
			d.heard.append([at.x, at.y, at.z, at.level, loud, str(a[2])])
			c.events.append({"type": "dangerNoise", "t": t, "id": rid, "kind": String(c.kind), "x": at.x, "y": at.y, "z": at.z,
				"level": at.level, "loud": loud, "by": str(a[2])})
			return true
		&"dark":
			# From `from` (now, or announced up to DARK_LEAD ahead, so every screen darkens on time), until `until`.
			var from := clampf(float(a[6]) if a.size() > 6 and float(a[6]) >= 0.0 else t, t, t + DARK_LEAD)
			var until := minf(float(a[5]), from + _f(s, &"danger.dark_max", DARK_MAX))
			if until <= from:
				return false
			var row := [int(a[0]), minf(a[1], a[3]), minf(a[2], a[4]), maxf(a[1], a[3]), maxf(a[2], a[4]), until, rid, from]
			var dark: Array = []
			for r: Array in d.dark:
				if not (int(r[6]) == rid and r.slice(0, 5) == row.slice(0, 5)):
					dark.append(r)
			dark.append(row)
			d.dark = dark
			return true
		&"close_edge":
			return _close_edge(c, rid, int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4]), float(a[5]))
		&"open_edge":
			var doors: Array = []
			var found := false
			for e: Array in d.doors:
				if int(e[0]) == int(a[0]) and _same_edge(e, int(a[1]), int(a[2]), int(a[3]), int(a[4])):
					found = true
				else:
					doors.append(e)
			if not found:
				return false
			d.doors = doors
			d.dirty()
			c.events.append({"type": "dangerDoor", "t": t, "id": rid, "level": int(a[0]), "ax": int(a[1]), "ay": int(a[2]),
				"bx": int(a[3]), "by": int(a[4]), "open": true})
			return true
		&"solid":
			if c.ward != null:
				return false
			var solids := d.solids.duplicate()
			solids["%d:%d" % [rid, int(a[0])]] = [int(a[1]), minf(a[2], a[4]), minf(a[3], a[5]), maxf(a[2], a[4]), maxf(a[3], a[5])]
			d.solids = solids
			d.dirty()
			return true
		&"unsolid":
			var key := "%d:%d" % [rid, int(a[0])]
			if not d.solids.has(key):
				return false
			var solids := d.solids.duplicate()
			solids.erase(key)
			d.solids = solids
			d.dirty()
			return true
		&"stumble", &"hold":
			var id := str(a[0])
			var k := _index_of(c.players, id)
			if k < 0 or c.players[k].status != &"ok" or c.players[k].aboard or d.pins.has(id):
				return false
			var secs := clampf(float(a[1]), 0.0, _f(s, &"danger.hold_max", HOLD_MAX))
			if secs <= 0.0:
				return false
			var body := c.players[k].body
			var fx := d.fx.duplicate()
			fx[id + "|move"] = {"kind": op, "until": t + secs, "body": body}
			d.fx = fx
			c.events.append({"type": "dangerStumble" if op == &"stumble" else "dangerHold", "t": t, "id": rid, "playerId": id,
				"until": t + secs, "at": body})
			if op == &"stumble":
				_ask(c, &"noise", rec, [body, float(a[2]), id])
			return true
		&"blind":
			var id := str(a[0])
			var k := _index_of(c.players, id)
			if k < 0 or c.players[k].status != &"ok":
				return false
			var secs := clampf(float(a[1]), 0.0, _f(s, &"danger.hold_max", HOLD_MAX))
			if secs <= 0.0:
				return false
			var fx := d.fx.duplicate()
			fx[id + "|blind"] = {"kind": &"blind", "until": t + secs, "body": null}
			d.fx = fx
			c.events.append({"type": "dangerBlind", "t": t, "id": rid, "playerId": id, "until": t + secs})
			return true
		&"push":
			var id := str(a[0])
			var k := _index_of(c.players, id)
			if k < 0 or c.players[k].status != &"ok" or c.players[k].aboard or d.pins.has(id) or c.ward != null:
				return false
			var v := Vector2(float(a[1]), float(a[2])).limit_length(PUSH_MAX)
			var np := c.players[k].copy()
			var probe := s.copy()
			probe.dangers = d
			np.body = Run.move_in_run(probe, np.body, v.x, v.y, PLAYER_RADIUS)
			c.players[k] = np
			c.changed_players = true
			c.events.append({"type": "dangerPush", "t": t, "id": rid, "playerId": id, "at": np.body})
			return true
		&"pin":
			var id := str(a[0])
			var k := _index_of(c.players, id)
			if not _active_ok(c, id, k):
				return false
			var at: Move.Body = a[2]
			var stand: Move.Body = a[3]
			if at == null or stand == null:
				return false
			var np := c.players[k].copy()
			np.body = at
			c.players[k] = np
			# A ledge: its own timer (secs) and the spot it falls to when nobody pulls them up in time.
			var ledge := StringName(a[1]) == &"ledge"
			var fall: Move.Body = a[5] if ledge and a.size() > 5 and a[5] != null else stand
			var secs := float(a[4]) if ledge and a.size() > 4 else -1.0
			if ledge and secs <= 0.0:
				return false
			var pins := d.pins.duplicate()
			pins[id] = {"style": StringName(a[1]), "at": at, "stand": stand, "fall": fall, "rec": rid}
			d.pins = pins
			var fx := d.fx.duplicate()
			fx.erase(id + "|move")
			fx.erase(id + "|blind")
			d.fx = fx
			c.events.append({"type": "dangerPinned", "t": t, "id": rid, "playerId": id, "style": String(a[1]), "at": at, "stand": stand,
				"fall": fall, "until": t + secs if ledge else t + Run.down_time(s)})
			Run._go_down(s, c.players, k, t, &"danger", c.events)
			if ledge:
				var down := s.down.duplicate()
				var dd: Run.Downed = (down[id] as Run.Downed).copy()
				dd.until = t + secs
				down[id] = dd
				s.down = down
				c.events[c.events.size() - 1]["until"] = dd.until
			c.changed_players = true
			return true
		&"send_out":
			var id := str(a[0])
			var k := _index_of(c.players, id)
			if not _active_ok(c, id, k):
				return false
			Run._go_down(s, c.players, k, t, &"danger", c.events)
			# Out by the run's own rule on its next tick (the tape drops and the red spot is left there).
			var down := s.down.duplicate()
			var dd: Run.Downed = (down[id] as Run.Downed).copy()
			dd.until = t
			down[id] = dd
			s.down = down
			c.changed_players = true
			c.events.append({"type": "dangerOut", "t": t, "id": rid, "playerId": id})
			return true
		&"prompt":
			d.prompts.append([rid, str(a[0]), float(a[1])])
			return true
		&"cue":
			var at: Move.Body = a[1]
			if at == null:
				return false
			c.events.append({"type": "dangerCue", "t": t, "id": rid, "kind": String(c.kind), "cue": String(a[0]),
				"x": at.x, "y": at.y, "z": at.z, "level": at.level})
			return true
	return false

## Whether an active ask may take player `id` (index k): an active kind, not on the Ward, the down rule on, the
## player up, and someone else still up after.
static func _active_ok(c: Ctx, id: String, k: int) -> bool:
	if k < 0 or c.ward != null or not c.s.downs or not bool(info(c.kind).get("active", false)):
		return false
	var p := c.players[k]
	if p.status != &"ok" or p.aboard or c.d.pins.has(id):
		return false
	return up_count(c, id) >= 1

static func _same_edge(e: Array, ax: int, ay: int, bx: int, by: int) -> bool:
	return (int(e[1]) == ax and int(e[2]) == ay and int(e[3]) == bx and int(e[4]) == by) \
		or (int(e[1]) == bx and int(e[2]) == by and int(e[3]) == ax and int(e[4]) == ay)

static func _close_edge(c: Ctx, rid: int, level: int, ax: int, ay: int, bx: int, by: int, until0: float) -> bool:
	var s := c.s
	var d := c.d
	var t := c.t
	if c.ward != null or s.plan == null or absi(ax - bx) + absi(ay - by) != 1 or not Floor.has_door(s.plan, level, ax, ay, bx, by):
		return false
	if until0 <= t or until0 > t + _f(s, &"danger.door_max", DOOR_MAX) + EPS:
		return false
	var cs := float(s.plan.cell_size)
	var mx := (ax + bx + 1) * 0.5 * cs
	var mz := (ay + by + 1) * 0.5 * cs
	for p in c.players:
		if p.body != null and p.body.level == level and Vector2(p.body.x - mx, p.body.z - mz).length() < DOOR_CLEAR + EPS:
			return false
	for o: Variant in [s.orderly, s.orderly2]:
		if o != null and o.body != null and o.body.level == level and Vector2(o.body.x - mx, o.body.z - mz).length() < DOOR_CLEAR + EPS:
			return false
	var doors: Array = []
	for e: Array in d.doors:
		if not (int(e[0]) == level and _same_edge(e, ax, ay, bx, by)):
			doors.append(e)
	var was := doors.size() != d.doors.size()
	doors.append([level, ax, ay, bx, by, until0, rid])
	d.doors = doors
	d.dirty()
	if not was:
		c.events.append({"type": "dangerDoor", "t": t, "id": rid, "level": level, "ax": ax, "ay": ay, "bx": bx, "by": by, "open": false, "until": until0})
	return true

# ---------------------------------------------------------------------------------------------
# The Hanging Ward (net/host.gd): noises heard by the Rigger.

## The noises the last step made, as [Vector3 at, loud], for net/host.gd to hand the Rigger (Ward.hear_loud).
static func heard_on_ward(s: Run.RunState) -> Array:
	var out: Array = []
	if s.dangers == null:
		return out
	for h: Array in (s.dangers as DangerFloor).heard:
		out.append([Vector3(float(h[0]), float(h[1]), float(h[2])), float(h[4])])
	return out

# ---------------------------------------------------------------------------------------------
# The snapshot (net/host.gd world, Protocol "dg").

## The world's "dangers" block, or null (no dangers in the run, or nothing on this floor).
static func block(s: Run.RunState) -> Variant:
	if s.dangers == null:
		return null
	var d: DangerFloor = s.dangers
	if not d.showing() and d.prompts.is_empty():
		return null
	var r: Array = []
	for rec in d.records:
		r.append({"id": int(rec["id"]), "kind": String(rec["kind"]), "x": float(rec["x"]), "y": float(rec["y"]), "z": float(rec["z"]),
			"level": int(rec["level"]), "yaw": float(rec["yaw"]), "state": String(rec["state"]), "since": float(rec["since"]),
			"n": (rec["n"] as Array).duplicate()})
	var dark: Array = []
	for x: Array in d.dark:
		dark.append([x[0], x[1], x[2], x[3], x[4], x[5], x[7]])
	var doors: Array = []
	for e: Array in d.doors:
		doors.append(e.slice(0, 6))
	var solids: Array = []
	var keys: Array = d.solids.keys()
	keys.sort()
	for key: String in keys:
		solids.append((d.solids[key] as Array).duplicate())
	var fx: Array = []
	var ids: Array = d.fx.keys()
	ids.sort()
	for id: String in ids:
		fx.append([id.get_slice("|", 0), String(d.fx[id]["kind"]), float(d.fx[id]["until"])])
	var pins: Array = []
	ids = d.pins.keys()
	ids.sort()
	for id: String in ids:
		var at: Move.Body = d.pins[id]["at"]
		pins.append([id, String(d.pins[id]["style"]), at.x, at.y, at.z, int(d.pins[id]["rec"])])
	return {"r": r, "dark": dark, "doors": doors, "solids": solids, "fx": fx, "pins": pins, "prompts": d.prompts.duplicate(true)}

## Test channel: force record `id` into `state` at the next step. False when there is no such record or state.
static func force_state(s: Run.RunState, id: int, state: StringName) -> bool:
	if s.dangers == null:
		return false
	var d: DangerFloor = s.dangers
	for rec in d.records:
		if int(rec["id"]) == id:
			var kind := kind_of(StringName(rec["kind"]))
			if kind == null or not kind.states().has(state):
				return false
			var forced := d.forced.duplicate()
			forced[id] = state
			d.forced = forced
			return true
	return false
