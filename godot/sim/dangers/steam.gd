# Dangers, the Reactor's steam (DG6). A passive danger: it never takes anyone down. Pure logic on host time.
#
# Each record is one jet: a band of floor across the way, under a split steam line, on a cycle.
#   - The hall's jet: a pipe crossing the turbine hall overhead; its band is the hall's whole width at one row.
#     The sheet stops at waist height, so a creeping player passes under it.
#   - The crawl's jet: a split tray pipe in the cable crawl's long leg; its band is one crawl cell, floor to roof.
#     Nobody passes under it; you wait.
# The cycle: rest -> build (steam.build: the knocks, the hiss rising, the valve lamp blinking) -> jet (steam.jet:
# the sheet, the lamp red) -> rest (steam.rest_lit while the station has power, steam.rest_dark in the emergency
# light). Jets on one floor are spread evenly round the cycle (record i of n starts i/n of a beat behind), so two
# are never live together except in a purge.
# The power (read from the tick's run events, the station's own): at the cut ("powerCut", steam.purge_cut) and when
# the fuse goes in ("powerRestored", steam.purge_restore) every jet drops what it is doing and purges: build, then
# a jet of steam.purge, then the cycle restarts from there in its spread.
# The hazard: from steam.grace into a jet to its end (the grace covers a screen drawing the steam a little late).
# A player on their feet whose body touches a live band (and is not creeping under the hall's sheet) flinches,
# once per jet: pushed back out of the band on the side they came from, held there for steam.flinch_hold and blind
# for steam.blind, and they cry out: a noise of steam.cry blamed on them (the four hear it as any point noise;
# from inside the crawl the cry is heard at the crawl's nearer mouth, outside it) and the cue `steam_cry` at them.
# Nothing here draws a random number after place(); every record carries its whole state.
extends "res://sim/dangers/kind.gd"

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Settings = preload("res://sim/settings.gd")
const Station = preload("res://sim/station.gd")
const StationFloor = preload("res://sim/station_floor.gd")

const REST := &"rest"
const BUILD := &"build"
const JET := &"jet"

## Today's numbers (the live settings' game values, danger.steam.*).
const BUILD_S := 1.5
const JET_S := 2.0
const REST_LIT := 6.5
const REST_DARK := 10.5
const PURGE := 2.5
const PURGE_CUT := 1.0
const PURGE_RESTORE := 1.0
const GRACE := 0.25
const CRY := 10.0
const BLIND := 1.0
const FLINCH_HOLD := 0.4
const HALL := 1
const CRAWL := 1

## A player's body radius (the walk model's).
const RADIUS := 0.3
## What scalds: this far either side of the pipe's line (the band's middle), across the band's width.
const HAZARD_HALF := 0.6
## How far clear of the scalding a flinch stands a body's middle.
const CLEAR := 0.7
## The station's fuse reach (sim/station_floor.gd USE_REACH): no band comes nearer a fuse spot or the cabinet.
const USE_REACH := 2.0
## The fewest hall cells a band spans (the hall is five wide).
const BAND_MIN := 3
## The most the base moves a player in one push (sim/dangers.gd PUSH_MAX).
const PUSH_MAX := 2.0
## Rows a second hall jet keeps from the first.
const HALL_GAP := 3
const EPS := 1e-6

## The power as the station's step has it (sim/station_floor.gd Power).
const POWER_NORMAL := 0
const POWER_EMERGENCY := 1
const POWER_RESTORED := 2

## Which band a record is (n[4]).
const WHICH_HALL := 0
const WHICH_CRAWL := 1

## n: what screens get, eight numbers.
const N_X0 := 0
const N_Z0 := 1
const N_X1 := 2
const N_Z1 := 3
const N_WHICH := 4
const N_POWER := 5
const N_PURGE := 6
const N_LEN := 7

func kind_name() -> StringName:
	return &"steam"

func states() -> Array[StringName]:
	return [REST, BUILD, JET]

static func s(tuning: Settings.Values, name: String, fallback: float) -> float:
	return Settings.f(tuning, StringName("danger.steam." + name), fallback)

## Seconds of rest after a jet with the station's power `power`.
static func rest_len(tuning: Settings.Values, power: int) -> float:
	return s(tuning, "rest_dark", REST_DARK) if power == POWER_EMERGENCY else s(tuning, "rest_lit", REST_LIT)

## One whole beat with that power.
static func period(tuning: Settings.Values, power: int) -> float:
	return s(tuning, "build", BUILD_S) + s(tuning, "jet", JET_S) + rest_len(tuning, power)

# --- placement ----------------------------------------------------------------------------------------------

func place(p: Api.Place) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if p.plan == null or p.plan.station.is_empty() or p.place != Station.PLACE:
		return out
	var want_hall := Settings.i(p.tuning, &"danger.steam.hall", HALL)
	var want_crawl := Settings.i(p.tuning, &"danger.steam.crawl", CRAWL)
	var bands := hall_bands(p)
	var picked: Array[Rect2] = []
	# A row across the hall's whole width when the floor has one (no lane to walk round); else the trimmed rows.
	var full: Array[Rect2] = []
	var trimmed: Array[Rect2] = []
	var hall_rect: Rect2 = p.plan.station["hall"]
	for b in bands:
		if absf(b.size.x - hall_rect.size.x) < EPS:
			full.append(b)
		else:
			trimmed.append(b)
	for pool: Array[Rect2] in [full, trimmed]:
		while picked.size() < want_hall and not pool.is_empty():
			var band: Rect2 = pool.pop_at(p.rng.int_in(0, pool.size() - 1))
			var near := false
			for q in picked:
				if absf(q.position.y - band.position.y) < HALL_GAP * Station.CELL - EPS:
					near = true
			if not near:
				picked.append(band)
	picked.sort_custom(func(u: Rect2, v: Rect2) -> bool: return u.position.y < v.position.y)
	for band in picked:
		out.append(_record(band, WHICH_HALL))
	var cells := crawl_cells(p)
	var cpool := cells.duplicate()
	var cpicked := 0
	while cpicked < want_crawl and not cpool.is_empty():
		var c: Vector2i = cpool.pop_at(p.rng.int_in(0, cpool.size() - 1))
		out.append(_record(Rect2(float(c.x) * Station.CELL, float(c.y) * Station.CELL, Station.CELL, Station.CELL), WHICH_CRAWL))
		cpicked += 1
		# A second crawl jet keeps two cells off the first.
		var keep: Array = []
		for o: Vector2i in cpool:
			if absi(o.y - c.y) > 2:
				keep.append(o)
		cpool = keep
	# Spread round the beat: record i of n waits i/n of a beat longer before its first build.
	for i in out.size():
		(out[i]["k"] as Dictionary)["offset"] = float(i) / float(out.size())
	return out

func _record(band: Rect2, which: int) -> Dictionary:
	var c := band.get_center()
	return {"x": c.x, "y": 0.0, "z": c.y, "level": 0, "yaw": 0.0, "state": REST,
		"n": [band.position.x, band.position.y, band.end.x, band.end.y, float(which), float(POWER_NORMAL), 0.0, 0.0],
		"k": {"band": [band.position.x, band.position.y, band.end.x, band.end.y], "which": which, "power": POWER_NORMAL,
			"started": false, "rest_end": 0.0, "purge": false, "offset": 0.0, "hit": {}, "side": {}}}

## The hall's bands a jet may cross, one per usable row (canonical rows are the plan's rows; mirroring changes only
## x): south of the rotor and the row after it, three rows clear of the hall's south end, not a row with a doorway out
## of the hall, not on or beside a row where one of the four lies. In a row, the band is the hall's cells that keep
## clear of the base's keep-clear discs (a doorway's approach in the next row trims the cell in front of it), the
## fuse's reach of every fuse spot and the cabinet, and other kinds' records: the run of such cells through the hall's
## middle, at least BAND_MIN cells wide (the whole width where nothing is near).
static func hall_bands(p: Api.Place) -> Array[Rect2]:
	var plan := p.plan
	var a := plan.station
	var hall: Rect2 = a["hall"]
	var top := int(round(hall.position.y / Station.CELL))
	var bottom := int(round(hall.end.y / Station.CELL)) - 1
	var x0 := int(round(hall.position.x / Station.CELL))
	var x1 := int(round(hall.end.x / Station.CELL)) - 1
	var mid := (x0 + x1) / 2
	var banned := {}
	for d in plan.doors:
		var a_in := d.ax >= x0 and d.ax <= x1
		var b_in := d.bx >= x0 and d.bx <= x1
		if a_in == b_in:
			continue
		banned[d.ay if a_in else d.by] = true
	for b: Dictionary in a["bodies"]:
		var row := int(floor((b["at"] as Vector3).z / Station.CELL))
		for k in range(row - 1, row + 2):
			banned[k] = true
	var out: Array[Rect2] = []
	for r in range(top + 2, bottom - 2):
		if banned.has(r):
			continue
		var ok := {}
		for cx in range(x0, x1 + 1):
			ok[cx] = _band_clear(p, Rect2(float(cx) * Station.CELL, float(r) * Station.CELL, Station.CELL, Station.CELL))
		if not bool(ok[mid]):
			continue
		var lo := mid
		var hi := mid
		while lo - 1 >= x0 and bool(ok[lo - 1]):
			lo -= 1
		while hi + 1 <= x1 and bool(ok[hi + 1]):
			hi += 1
		if hi - lo + 1 < BAND_MIN:
			continue
		out.append(Rect2(float(lo) * Station.CELL, float(r) * Station.CELL, float(hi - lo + 1) * Station.CELL, Station.CELL))
	return out

## The crawl's long leg cells a jet may fill: at least two cells from each mouth along the crawl, not the turn,
## not the cell under the crawl's lamp, clear of the keep-clear discs.
static func crawl_cells(p: Api.Place) -> Array[Vector2i]:
	var plan := p.plan
	var a := plan.station
	var crawl: Array = a["crawl"]
	var by_x := {}
	for c: Vector2i in crawl:
		by_x[c.x] = int(by_x.get(c.x, 0)) + 1
	var col := -1
	var most := 0
	for x: int in by_x:
		if int(by_x[x]) > most:
			most = int(by_x[x])
			col = x
	var leg: Array[Vector2i] = []
	for c: Vector2i in crawl:
		if c.x == col:
			leg.append(c)
	if leg.is_empty():
		return leg
	leg.sort_custom(func(u: Vector2i, v: Vector2i) -> bool: return u.y < v.y)
	var in_crawl := {}
	for c: Vector2i in crawl:
		in_crawl[c] = true
	# Steps along the crawl from each mouth's crawl cell.
	var mouth_cells: Array[Vector2i] = []
	for m: Array in a["crawl_mouths"]:
		var ca := Vector2i(int(m[0]), int(m[1]))
		var cb := Vector2i(int(m[2]), int(m[3]))
		mouth_cells.append(cb if in_crawl.has(cb) else ca)
	var lamp_cells := {}
	for l: Dictionary in a.get("lamps", []):
		var at: Vector3 = l["at"]
		lamp_cells[Station.cell_of(at.x, at.z)] = true
	var turn := leg[0]
	var out: Array[Vector2i] = []
	for c in leg:
		if c == turn or lamp_cells.has(c):
			continue
		var ok := true
		for m in mouth_cells:
			if _crawl_steps(in_crawl, m, c) < 2:
				ok = false
		if not ok:
			continue
		var band := Rect2(float(c.x) * Station.CELL, float(c.y) * Station.CELL, Station.CELL, Station.CELL)
		if not _band_clear(p, band):
			continue
		out.append(c)
	return out

static func _crawl_steps(in_crawl: Dictionary, from: Vector2i, to: Vector2i) -> int:
	var seen := {from: 0}
	var queue: Array[Vector2i] = [from]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		if c == to:
			return int(seen[c])
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if in_crawl.has(n) and not seen.has(n):
				seen[n] = int(seen[c]) + 1
				queue.append(n)
	return 1 << 20

## A band touches no keep-clear disc, comes no nearer than the fuse's reach to a fuse spot or the cabinet, keeps off
## the landing and the switch room, and keeps 3 m from other kinds' records.
static func _band_clear(p: Api.Place, band: Rect2) -> bool:
	var a := p.plan.station
	var land: Rect2 = a["landing"]
	if band.intersects(land.grow(Station.CELL)):
		return false
	var cab: Vector3 = (a["cabinet"] as Dictionary)["at"]
	if _rect_gap(band, cab.x, cab.z) < USE_REACH:
		return false
	for f: Vector3 in a.get("fuse_spots", []):
		if _rect_gap(band, f.x, f.z) < USE_REACH:
			return false
	var rooms: Dictionary = a.get("rooms", {})
	if rooms.has("switch"):
		var sw: Floor.Room = p.plan.rooms[int(rooms["switch"])]
		var sr := Rect2(float(sw.x) * Station.CELL, float(sw.y) * Station.CELL, float(sw.w) * Station.CELL, float(sw.h) * Station.CELL)
		if band.intersects(sr):
			return false
	# The keep-clear discs, sampled across the band.
	var step := 0.5
	var z := band.position.y + 0.25
	while z < band.end.y:
		var x := band.position.x + 0.25
		while x < band.end.x:
			if not p.clear(0, x, z, 0.25):
				return false
			x += step
		z += step
	for o: Dictionary in p.taken:
		if int(o.get("level", 0)) == 0 and _rect_gap(band, float(o.get("x", 0.0)), float(o.get("z", 0.0))) < 3.0:
			return false
	return true

## The flat distance from a point to a rectangle (0 inside).
static func _rect_gap(r: Rect2, x: float, z: float) -> float:
	var dx := maxf(maxf(r.position.x - x, 0.0), x - r.end.x)
	var dz := maxf(maxf(r.position.y - z, 0.0), z - r.end.y)
	return sqrt(dx * dx + dz * dz)

# --- the beat ------------------------------------------------------------------------------------------------

func step(rec: Dictionary, k: Api.Tick, ask: Api.Asks) -> void:
	var kk: Dictionary = rec["k"]
	var tuning := k.tuning
	var t := k.t
	var purge_now := false
	for e: Dictionary in k.events:
		match str(e.get("type", "")):
			"powerCut":
				kk["power"] = POWER_EMERGENCY
				if s(tuning, "purge_cut", PURGE_CUT) > 0.5:
					purge_now = true
			"powerRestored":
				kk["power"] = POWER_RESTORED
				if s(tuning, "purge_restore", PURGE_RESTORE) > 0.5:
					purge_now = true
	var power := int(kk["power"])
	if not bool(kk["started"]):
		kk["started"] = true
		kk["rest_end"] = t + rest_len(tuning, power) + float(kk["offset"]) * period(tuning, power)
	var state := StringName(rec["state"])
	var age := t - float(rec.get("since", t))
	if purge_now:
		kk["purge"] = true
		ask.set_state(rec, BUILD)
	elif state == REST:
		if t >= float(kk["rest_end"]) - EPS:
			ask.set_state(rec, BUILD)
	elif state == BUILD:
		if age >= s(tuning, "build", BUILD_S) - EPS:
			ask.set_state(rec, JET)
			kk["hit"] = {}
	elif state == JET:
		if age >= jet_len(tuning, bool(kk["purge"])) - EPS:
			ask.set_state(rec, REST)
			var after := rest_len(tuning, power)
			if bool(kk["purge"]):
				after += float(kk["offset"]) * period(tuning, power)
			kk["rest_end"] = t + after
			kk["purge"] = false
	state = StringName(rec["state"])
	if state == JET and t - float(rec["since"]) >= s(tuning, "grace", GRACE) - EPS:
		_scald(rec, k, ask)
	# Where everyone was this tick (the side they come from).
	var side: Dictionary = kk["side"]
	for w in k.players:
		side[w.id] = w.body.z
	var n: Array = rec["n"]
	n[N_POWER] = float(power)
	n[N_PURGE] = 1.0 if bool(kk["purge"]) else 0.0
	n[N_LEN] = _state_len(rec, tuning)

## The longest hold a flinch may ask: whole host ticks, at least one tick fewer than the four's catch wind-up takes.
static func hold_most(dt: float) -> float:
	return float(ceili(StationFloor.WIND / dt - 1e-6) - 1) * dt

static func jet_len(tuning: Settings.Values, purge: bool) -> float:
	return s(tuning, "purge", PURGE) if purge else s(tuning, "jet", JET_S)

## How long the record's present state lasts (screens draw the build's rise and the jet's tail from it).
static func _state_len(rec: Dictionary, tuning: Settings.Values) -> float:
	var kk: Dictionary = rec["k"]
	match StringName(rec["state"]):
		BUILD:
			return s(tuning, "build", BUILD_S)
		JET:
			return jet_len(tuning, bool(kk["purge"]))
		_:
			return maxf(0.0, float(kk["rest_end"]) - float(rec.get("since", 0.0)))

## The band a record covers, in world metres (x0, z0, x1, z1 as a Rect2).
static func band_of(rec: Dictionary) -> Rect2:
	var b: Array = (rec["k"] as Dictionary)["band"] if rec.has("k") else [rec["n"][0], rec["n"][1], rec["n"][2], rec["n"][3]]
	return Rect2(float(b[0]), float(b[1]), float(b[2]) - float(b[0]), float(b[3]) - float(b[1]))

## What scalds: the band's width, HAZARD_HALF either side of the pipe's line (the band's middle). The whole cell
## stays the band for placement; the drawn steam covers exactly this (client/dangers/steam_view.gd).
static func hazard_of(rec: Dictionary) -> Rect2:
	var band := band_of(rec)
	var mid := band.get_center().y
	return Rect2(band.position.x, mid - HAZARD_HALF, band.size.x, 2.0 * HAZARD_HALF)

## Whether a body (radius RADIUS) at (x, z) touches a rectangle (the hazard).
static func touches(r: Rect2, x: float, z: float) -> bool:
	# (A hair inside the edge, so a body stopped exactly at the edge is not touched.)
	var e := RADIUS - 1e-4
	return x > r.position.x - e and x < r.end.x + e and z > r.position.y - e and z < r.end.y + e

func _scald(rec: Dictionary, k: Api.Tick, ask: Api.Asks) -> void:
	var kk: Dictionary = rec["k"]
	var hit: Dictionary = kk["hit"]
	var haz := hazard_of(rec)
	var hall := int(kk["which"]) == WHICH_HALL
	var tuning := k.tuning
	for w in k.players:
		if not w.up or w.down or w.out or w.aboard or w.hidden or w.pinned or hit.has(w.id):
			continue
		if w.body.level != 0 or not touches(haz, w.body.x, w.body.z):
			continue
		if hall and low_now(w):
			continue
		hit[w.id] = true
		# Back out the way they came: the side their last tick was on, or the nearer side when already inside.
		var prev: Variant = (kk["side"] as Dictionary).get(w.id)
		var north: bool
		if prev != null and (float(prev) <= haz.position.y - RADIUS + EPS or float(prev) >= haz.end.y + RADIUS - EPS):
			north = float(prev) < haz.get_center().y
		else:
			north = w.body.z < haz.get_center().y
		# Stood CLEAR clear of the steam, so the flinch costs a step back and the walk in again.
		var to := haz.position.y - CLEAR if north else haz.end.y + CLEAR
		# Never further than a push may go: from deep in the band, out of the nearer side instead.
		if absf(to - w.body.z) > PUSH_MAX:
			to = haz.end.y + CLEAR if north else haz.position.y - CLEAR
		var dz := clampf(to - w.body.z, -PUSH_MAX, PUSH_MAX)
		ask.push(rec, w.id, 0.0, dz)
		# Held where the push left them (the base keeps a hold and a blind together), then blind.
		# Always shorter than the four's catch wind-up (sim/station_floor.gd WIND), whatever the setting: the hold alone
		# never stands a player still for a whole wind; a body still has to keep them in reach by its own rule.
		var hold := minf(s(tuning, "flinch_hold", FLINCH_HOLD), hold_most(k.dt))
		if hold > 0.0:
			ask.hold(rec, w.id, hold)
		ask.blind(rec, w.id, s(tuning, "blind", BLIND))
		var cry := s(tuning, "cry", CRY)
		if cry > 0.0:
			ask.noise(rec, cry_at(k.plan, w.body), cry, w.id)
		# The cue at where the push lands them, so the cry and its puff of steam come from where they now stand.
		ask.cue(rec, &"steam_cry", Move.Body.make(w.body.x, w.body.z + dz, w.body.level, w.body.y))

## Whether a player is low this tick: crouched by their input (the base's Who.gait, also when standing still), so a
## player crouched in place under the hall's sheet passes and one who stands up in place is scalded.
static func low_now(w: Api.Who) -> bool:
	return w.gait == &"creep"

## Where the four hear a cry from `at`: there, or, from inside the crawl (where they never hear or go), at the
## outside cell of the crawl's mouth nearest along the crawl.
static func cry_at(plan: Floor.FloorPlan, at: Move.Body) -> Move.Body:
	if plan == null or not Station.in_crawl(plan, at.level, at.x, at.z):
		return at
	var a := plan.station
	var in_crawl := {}
	for c: Vector2i in a["crawl"]:
		in_crawl[c] = true
	var here := Station.cell_of(at.x, at.z)
	var best := 1 << 30
	var out := at
	for m: Array in a["crawl_mouths"]:
		var ca := Vector2i(int(m[0]), int(m[1]))
		var cb := Vector2i(int(m[2]), int(m[3]))
		var inside := cb if in_crawl.has(cb) else ca
		var outside := ca if in_crawl.has(cb) else cb
		var d := _crawl_steps(in_crawl, here, inside)
		if d < best:
			best = d
			out = Move.Body.make(Station.wc(outside.x), Station.wc(outside.y), at.level, 0.0)
	return out

func force(rec: Dictionary, state: StringName, k: Api.Tick, ask: Api.Asks) -> void:
	var kk: Dictionary = rec["k"]
	kk["started"] = true
	if state == JET:
		kk["hit"] = {}
	if state == REST:
		kk["rest_end"] = k.t + rest_len(k.tuning, int(kk["power"]))
		kk["purge"] = false
	ask.set_state(rec, state)
	var n: Array = rec["n"]
	n[N_LEN] = _state_len(rec, k.tuning)
