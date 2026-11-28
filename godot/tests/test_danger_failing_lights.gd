# The Clinic's failing lights (sim/dangers/failing_lights.gd; client/dangers/failing_lights_view.gd).
#   1. Placed from the seed: the same circuits twice, and in a fresh engine process.
#   2. Fair on every floor: corridor only, far from the lift, nothing opening onto its sides, on a loop (going round
#      always exists), clear of everything the base keeps clear, a straight approach, a lit beat a walker crosses.
#   3. Heard first: the wind-down starts at least a second before every dark, over 300 s of host ticks, and the dark
#      region the rules ask for is exactly the dark state's time; the lift's blink holds the beat, never cuts a warning.
#   4. The resident's own rule: a watched Orderly in the dark core moves; lit, it is held; at the core's edge (still
#      half in the light beside the run) it is held even while dark.
#   5. Passive: it never holds, blinds, pushes, pins or downs anyone, and makes no noise; with it on, a run is the run
#      without it until the Orderly first stands in a dark core.
#   6. The screen: dark whenever the rules are dark (early dark, late light by the DRAWN time); one light at most; a
#      warning that sags where it can be seen; nothing flashing more than three times a second; the amber strip and
#      the dimmed box exactly the rules' core; the sounds in the mix; the warning whole in a blink; a readable notice.
#   7. Every number a live setting (test_setting_failing_lights_<name>).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Rng = preload("res://sim/rng.gd")
const Clinic = preload("res://sim/clinic.gd")
const Bot = preload("res://sim/bot.gd")
const Places = preload("res://sim/places.gd")
const Relocate = preload("res://sim/relocate.gd")
const HostRules = preload("res://net/host_rules.gd")
const Dangers = preload("res://sim/dangers.gd")
const DangerFx = preload("res://sim/dangers/effects.gd")
const Api = preload("res://sim/dangers/api.gd")
const Settings = preload("res://sim/settings.gd")
const FL = preload("res://sim/dangers/failing_lights.gd")
const View = preload("res://client/dangers/failing_lights_view.gd")
const DangersView = preload("res://client/dangers/dangers_view.gd")
const KindView = preload("res://client/dangers/kind_view.gd")
const Shop = preload("res://sim/shop.gd")
const ClinicDress = preload("res://client/clinic_dress.gd")

const DT := 0.05
const KIND := &"failing_lights"
## Set in the child engine of the fresh-process check: it only writes the digest.
const CHILD_ENV := "DG1_DIGEST_OUT"

static func _child() -> bool:
	return OS.get_environment(CHILD_ENV) != ""

# --- helpers: the real run --------------------------------------------------------------------------------

static func _rules(kinds: Array) -> HostRules:
	var r := HostRules.new(true, 1, [], false, false, true)
	r.dangers = Dangers.resolve(kinds)
	return r

static func _inputs(s: Run.RunState, bodies: Dictionary, yaws: Dictionary = {}) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		var b: Move.Body = bodies.get(p.id, p.body)
		var i := Run.PlayerInput.make(p.id, b, 1.65, float(yaws.get(p.id, 0.0)), 0.0, 90.0, 70.0)
		i.gait = &"walk"
		out.append(i)
	return out

## A Clinic run with the kind on, stepped twice with nobody moving: [rules, state].
static func _run(seed: String, tuning: Dictionary = {}) -> Array:
	var r := _rules([KIND])
	var s := r.prepare(Run.create_run(seed, ["a", "b"] as Array[String]))
	if not tuning.is_empty():
		s = Run.with_tuning(s, tuning)
	for _k in 2:
		s = r.step(s, _inputs(s, {}), DT).state
	return [r, s]

static func _records(s: Run.RunState) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if s.dangers == null:
		return out
	for r in (s.dangers as Dangers.DangerFloor).records:
		if r["kind"] == KIND:
			out.append(r)
	return out

static func _digest(recs: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for r in recs:
		parts.append("%d %.3f %.3f %.3f %d %.4f %s %s" % [int(r["level"]), float(r["x"]), float(r["y"]), float(r["z"]), int(r["level"]),
			float(r["yaw"]), str(r["n"]), str((r["k"] as Dictionary).get("core"))])
	return " | ".join(parts)

# --- helpers: the kind on its own ---------------------------------------------------------------------------

## A Place for `seed` at `depth` straight from the Clinic's generator (keep_clear empty unless given).
static func _place_of(seed: String, depth: int, tuning: Dictionary = {}, keep: Array[Dictionary] = []) -> Api.Place:
	var p := Api.Place.new()
	p.plan = Clinic.generate_clinic(seed, depth)
	p.place = &"clinic"
	p.depth = depth
	p.floor_seed = seed
	p.tuning = Settings.make(tuning) if not tuning.is_empty() else null
	p.rng = Rng.make_rng(seed + ":danger:" + String(KIND))
	p.lift_steps = Floor.distances_from(p.plan, p.plan.landing)
	p.keep_clear = keep
	return p

## Steps one record on its own for `secs` from the doors opening, with a fake tick: the state changes
## [[t, state]] and the dark regions asked for [[from, until, x0, z0, x1, z1]].
static func _drive(rec0: Dictionary, secs: float, tuning: Dictionary = {}, lit: Callable = Callable()) -> Dictionary:
	var rec := rec0.duplicate(true)
	rec["since"] = 0.0
	if not rec.has("state"):
		rec["state"] = FL.LIT
	var changes: Array = [[0.0, StringName(rec["state"])]]
	var darks: Array = []
	var other: Array = []
	var ask := Api.Asks.new()
	ask._do = func(op: StringName, _r: Dictionary, a: Array) -> bool:
		if op == &"dark":
			darks.append([float(a[6]) if float(a[6]) >= 0.0 else ask.t, float(a[5]), a[1], a[2], a[3], a[4]])
		else:
			other.append(op)
		return true
	var k := Api.Tick.new()
	k.tuning = Settings.make(tuning) if not tuning.is_empty() else null
	k.place = &"clinic"
	k.dt = DT
	if lit.is_valid():
		k._lit = func(_l: int, _x: float, _z: float) -> bool: return lit.call(k.t)
	var kind := FL.new()
	var t0 := 100.0
	for n in roundi(secs / DT) + 1:
		k.t = t0 + n * DT
		k.floor_t = n * DT
		ask.t = k.t
		var before := StringName(rec["state"])
		kind.step(rec, k, ask)
		if StringName(rec["state"]) != before:
			changes.append([k.t, StringName(rec["state"])])
	ask._do = Callable()  # the lambda holds `ask`: break the cycle
	k._lit = Callable()
	return {"changes": changes, "darks": darks, "other": other, "rec": rec, "t0": t0}

# --- 1. from the seed ----------------------------------------------------------------------------------------

## The runs of several floors as one line: three first floors through the real run, three deeper ones (two runs
## each, many candidates, so any draw that is not the kind's own shows) straight from the generator.
static func _many() -> String:
	var parts: Array[String] = []
	for i in 3:
		parts.append(_digest(_records(_run("dg1-seed-%d" % i)[1])))
		parts.append(_digest(FL.new().place(_place_of("dg1-seed-deep-%d" % i, 2))))
	return " || ".join(parts)

func test_placed_from_the_seed(t: T) -> void:
	var a := _records(_run("dg1-seed")[1])
	var many := _many()
	if _child():
		var f := FileAccess.open(OS.get_environment(CHILD_ENV), FileAccess.WRITE)
		f.store_string(many)
		f.close()
		return
	var b := _records(_run("dg1-seed")[1])
	t.check(not a.is_empty(), "the Clinic's first floor gets a failing run")
	t.eq(_digest(a), _digest(b), "the same seed puts the same runs in the same places")
	t.eq(_many(), many, "six floors twice: the same runs")
	t.eq(StringName(a[0]["state"]) if not a.is_empty() else &"", FL.LIT, "a run starts lit")
	t.check(_digest(_records(_run("dg1-seed-other")[1])) != _digest(a), "another seed puts it elsewhere")
	# The same in a fresh engine: the child runs only this test and writes its digest.
	var out := ProjectSettings.globalize_path("user://dg1_digest.txt")
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	OS.set_environment(CHILD_ENV, out)
	var log: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script",
		"res://tests/run_tests.gd", "--", "test_danger_failing_lights", "--port-base=7061"], log, true)
	OS.unset_environment(CHILD_ENV)
	var got := FileAccess.get_file_as_string(out) if FileAccess.file_exists(out) else "<none>"
	t.eq(got, many, "a fresh engine process places the very same runs on six floors")

# --- 2. fair on every floor ----------------------------------------------------------------------------------

## Every rule a placed circuit must keep; returns the first broken one ("" if none).
static func _broken(s: Run.RunState, rec: Dictionary) -> String:
	var plan := s.plan
	var kk: Dictionary = rec["k"]
	var cells: Array = kk["cells"]
	var steps := Floor.distances_from(plan, plan.landing)
	var far := 0
	for d in steps:
		far = maxi(far, d)
	var barred := Relocate.barred(plan, plan.seed, PackedFloat64Array([s.car.rect.x0, s.car.rect.z0, s.car.rect.x1, s.car.rect.z1]), s.car.level)
	var clear := Dangers.keep_clear_of(s, null)
	var band := {}
	for c: Array in cells:
		band[Floor.pos_index(plan, Floor.Pos.make(c[0], c[1], c[2]))] = true
	var cs := float(plan.cell_size)
	for c: Array in cells:
		var pi := Floor.pos_index(plan, Floor.Pos.make(c[0], c[1], c[2]))
		if Floor.cell_at(plan, c[0], c[1], c[2]) != Floor.CORRIDOR:
			return "a cell that is not corridor"
		if barred.has(pi):
			return "a barred cell (hide spot, lobby, landing, stair or the car's zone)"
		if steps[pi] < ceili(FL.FROM / 100.0 * far):
			return "a cell nearer the lift than %d in 100 of the far end" % int(FL.FROM)
		for st in Floor.STEPS:
			if Walls.edge_kind(plan, c[0], c[1], c[2], c[1] + st.x, c[2] + st.y) == Walls.RAIL:
				return "a balcony rail beside it"
		for k: Dictionary in clear:
			if int(k["level"]) == int(c[0]) and Vector2(float(k["x"]) - (c[1] + 0.5) * cs, float(k["z"]) - (c[2] + 0.5) * cs).length() < float(k["r"]) + 0.3:
				return "a cell on something the base keeps clear"
	if not FL.on_loop(plan, cells):
		return "not on a loop: shutting it strands a cell"
	# Nothing opens onto its sides: every step out of the band goes on along its own line past an end.
	var along_x := absf(float(rec["yaw"])) < 0.1
	var len_m := float(rec["n"][0])
	for c: Array in cells:
		for nb in Floor.neighbours(plan, Floor.Pos.make(c[0], c[1], c[2])):
			if band.has(Floor.pos_index(plan, nb)):
				continue
			var across_same: bool = (nb.y == int(c[2])) if along_x else (nb.x == int(c[1]))
			var out_along := absf(((nb.x + 0.5) * cs - float(rec["x"])) if along_x else ((nb.y + 0.5) * cs - float(rec["z"]))) > len_m / 2.0
			if nb.level != int(c[0]) or not across_same or not out_along:
				return "an opening onto its side"
	# The core: inside the band, MARGIN short of each end.
	var core: Array = kk["core"]
	var half_core := ((float(core[2]) - float(core[0])) if along_x else (float(core[3]) - float(core[1]))) / 2.0
	if absf(half_core - (len_m / 2.0 - FL.MARGIN)) > 1e-6:
		return "the dark core does not stop %.1f m short of each end" % FL.MARGIN
	# The lit beat: a walker crosses the whole run on one lit beat with a second to spare.
	var lit := float(rec["n"][3])
	var warn := float(rec["n"][4])
	if lit - warn < len_m / FL.CROSS_SPEED + FL.CROSS_SPARE:
		return "the lit beat is too short to cross on"
	if warn < 1.0:
		return "a warning under a second"
	# The approach: the hall runs straight on past one end for at least APPROACH cells.
	var ok := false
	var first: Array = cells[0]
	var last: Array = cells[-1]
	for e: Array in [[first, -1], [last, 1]]:
		var c: Array = e[0]
		var run := 0
		for m in range(1, FL.APPROACH + 1):
			var x: int = c[1] + (e[1] * m if along_x else 0)
			var y: int = c[2] + (0 if along_x else e[1] * m)
			if Floor.cell_at(plan, c[0], x, y) == Floor.CORRIDOR:
				run += 1
		ok = ok or run >= FL.APPROACH
	if not ok:
		return "no straight approach to it"
	return ""

func test_fair_on_every_floor(t: T) -> void:
	if _child():
		return
	var n := 40 if t.quick else 400
	var placed := 0
	var floors_with := 0
	var bad := 0
	for i in n:
		var s: Run.RunState = _run("dg1-fair-%d" % i)[1]
		var recs := _records(s)
		if not recs.is_empty():
			floors_with += 1
		for r in recs:
			placed += 1
			var why := _broken(s, r)
			if why != "" and bad < 5:
				bad += 1
				t.check(false, "floor %d run %d: %s" % [i, int(r["id"]), why])
	t.check(floors_with >= int(n * 0.95), "nearly every floor has a run (%d of %d)" % [floors_with, n])
	t.note("%d floors, %d runs placed" % [n, placed])
	# Deeper floors (two runs) straight from the generator, and the candidates' own rules on depth 2.
	var deep := 20 if t.quick else 200
	for i in deep:
		var p := _place_of("dg1-deep-%d" % i, 2)
		var recs: Array[Dictionary] = FL.new().place(p)
		for a in recs.size():
			if not FL.on_loop(p.plan, recs[a]["k"]["cells"]):
				t.check(false, "depth 2 floor %d: a run off a loop" % i)
			for b in range(a + 1, recs.size()):
				var d := Floor.distances_from(p.plan, Floor.Pos.make(recs[a]["k"]["cells"][0][0], recs[a]["k"]["cells"][0][1], recs[a]["k"]["cells"][0][2]))
				var c0: Array = recs[b]["k"]["cells"][0]
				var steps := d[Floor.pos_index(p.plan, Floor.Pos.make(c0[0], c0[1], c0[2]))]
				t.check(steps < 0 or steps * 2 >= FL.APART_M - 4.0, "depth 2 floor %d: two runs apart (%d steps)" % [i, steps])

func test_the_loop_check_finds_a_stranding_stretch(t: T) -> void:
	if _child():
		return
	# Every candidate already has nothing opening onto its sides, so on these layouts the loop check rarely if ever
	# rejects one; it is the guard behind that. Proved here on its own: shutting the corridor cell in front of a
	# one-door room strands the room; shutting a placed run strands nothing.
	var p := _place_of("dg1-loop", 2)
	var plan := p.plan
	var doors := {}
	for d in plan.doors:
		for end: Vector2i in [Vector2i(d.ax, d.ay), Vector2i(d.bx, d.by)]:
			var rid := Floor.room_id_at(plan, d.level, end.x, end.y)
			if rid >= 0:
				doors[rid] = (doors.get(rid, []) as Array) + [d]
	var tried := 0
	for rid: int in doors:
		var list: Array = doors[rid]
		if list.size() != 1 or plan.rooms[rid].kind == &"lobby":
			continue
		var d: Floor.Door = list[0]
		var outside := Vector2i(d.ax, d.ay) if Floor.room_id_at(plan, d.level, d.ax, d.ay) != rid else Vector2i(d.bx, d.by)
		if Floor.cell_at(plan, d.level, outside.x, outside.y) != Floor.CORRIDOR:
			continue
		tried += 1
		t.check(not FL.on_loop(plan, [[d.level, outside.x, outside.y]]), "shutting the cell before room %d's only door strands it" % rid)
		if tried >= 3:
			break
	t.check(tried > 0, "a one-door room to try")
	for r in FL.new().place(p):
		t.check(FL.on_loop(plan, r["k"]["cells"]), "a placed run strands nothing")

# --- 3. heard first ----------------------------------------------------------------------------------------

func test_wind_down_a_second_before_every_dark(t: T) -> void:
	if _child():
		return
	for seed: String in ["dg1-beat-1", "dg1-beat-2", "dg1-beat-3"]:
		var recs: Array[Dictionary] = FL.new().place(_place_of(seed, 2))
		if not t.check(not recs.is_empty(), "%s: a run to drive" % seed):
			continue
		var out := _drive(recs[0], 300.0)
		var ch: Array = out["changes"]
		var darks: Array = out["darks"]
		var t0 := float(out["t0"])
		var n_dark := 0
		var warn_at := -1.0
		var ok := true
		var first_dark := -1.0
		for c: Array in ch:
			if c[1] == FL.WARN:
				warn_at = float(c[0])
			elif c[1] == FL.DARK:
				n_dark += 1
				if first_dark < 0.0:
					first_dark = float(c[0]) - t0
				if warn_at < 0.0 or float(c[0]) - warn_at < 1.0 - 1e-6:
					ok = false
				warn_at = -1.0
		t.check(ok, "%s: every dark comes at least 1 s after its wind-down starts" % seed)
		t.check(n_dark >= 20, "%s: it keeps its beat (%d darks in 300 s)" % [seed, n_dark])
		t.check(first_dark >= FL.FIRST_AFTER, "%s: not dark in the first %.0f s after the doors open (%.2f)" % [seed, FL.FIRST_AFTER, first_dark])
		t.eq(darks.size(), n_dark + (1 if StringName(ch[-1][1]) == FL.WARN else 0), "%s: one dark region asked for each dark" % seed)
		# Each region: from the dark state's start to the next lit, announced at the wind-down's start.
		var regions_ok := true
		var di := 0
		for j in ch.size():
			if ch[j][1] != FL.DARK:
				continue
			var start := float(ch[j][0])
			var end := float(ch[j + 1][0]) if j + 1 < ch.size() else INF
			var r: Array = darks[di]
			di += 1
			if absf(float(r[0]) - start) > DT + 1e-6 or (end < INF and absf(float(r[1]) - end) > DT + 1e-6):
				regions_ok = false
		t.check(regions_ok, "%s: the dark region lasts exactly the dark state" % seed)
		t.eq((out["other"] as Array).size(), 0, "%s: it asks for nothing but its dark" % seed)

func test_the_lifts_blink_holds_the_beat(t: T) -> void:
	if _child():
		return
	# The lift's blink or blackout (k.lit false at the run) from 20 s to 26 s and from 41 s to 41.4 s after the doors
	# open: no wind-down starts in it, and every dark still comes a whole warning after its wind-down began.
	var t0 := 100.0
	var blink := func(ht: float) -> bool:
		var f := ht - t0
		return not ((f >= 20.0 and f < 26.0) or (f >= 41.0 and f < 41.4))
	var held := 0
	for seed: String in ["dg1-blink-1", "dg1-blink-2", "dg1-blink-3", "dg1-blink-4"]:
		var recs: Array[Dictionary] = FL.new().place(_place_of(seed, 2))
		if not t.check(not recs.is_empty(), "%s: a run to drive" % seed):
			continue
		var out := _drive(recs[0], 120.0, {}, blink)
		var ch: Array = out["changes"]
		var in_blink := 0
		var short := 0
		var warn_at := -1.0
		for c: Array in ch:
			if c[1] == FL.WARN:
				warn_at = float(c[0])
				if not blink.call(warn_at):
					in_blink += 1
				var f := warn_at - t0
				if absf(f - 26.0) < DT * 1.5 or absf(f - 41.4) < DT * 1.5:
					held += 1
			elif c[1] == FL.DARK and (warn_at < 0.0 or float(c[0]) - warn_at < FL.WARN_S - DT - 1e-6):
				short += 1
		t.eq(in_blink, 0, "%s: no wind-down starts while the lift's blink darkens the floor" % seed)
		t.eq(short, 0, "%s: every dark still comes a whole warning after its wind-down" % seed)
		t.check(ch.size() > 12, "%s: it carries on after the blink (%d changes)" % [seed, ch.size()])
	t.check(held > 0, "a wind-down due in a blink was held to its end (%d times)" % held)

# --- 4. the resident's own rule ----------------------------------------------------------------------------

## The Orderly placed at `along` metres from the run's middle (along it), hunting, watched by both players from
## the far end of the band; forced into `state`, stepped `ticks`: [moved metres, orderly seen].
static func _watched(seed: String, along: float, state: StringName, ticks: int, flash := false) -> Array:
	var rs := _run(seed)
	var r: HostRules = rs[0]
	var s: Run.RunState = rs[1]
	var recs := _records(s)
	if recs.is_empty():
		return [-1.0, false]
	var rec := recs[0]
	var along_x := absf(float(rec["yaw"])) < 0.1
	var len_m := float(rec["n"][0])
	var dir := Vector2(1, 0) if along_x else Vector2(0, 1)
	var mid := Vector2(float(rec["x"]), float(rec["z"]))
	var o := mid + dir * along
	var w := mid - dir * (len_m / 2.0 - 0.4)
	var lv := int(rec["level"])
	var y := float(rec["y"])
	s.phase = &"away"
	s.orderly.mode = &"hunting"
	s.orderly.body = Move.Body.make(o.x, o.y, lv, y)
	var yaw := atan2(-(o.x - w.x), -(o.y - w.y))
	var body := Move.Body.make(w.x, w.y, lv, y)
	Dangers.force_state(s, int(rec["id"]), state)
	if flash:
		# The shop's flashbulb lit in player a's hand for the whole stretch (as sim/shop.gd keeps it).
		s.shop = true
		s.shop_state = Shop.ShopState.new()
		(s.shop_state as Shop.ShopState).flashes["a"] = s.t + 60.0
	var start := s.orderly.body
	var seen := false
	for _k in ticks:
		var res := r.step(s, _inputs(s, {"a": body, "b": body}, {"a": yaw, "b": yaw}), DT)
		s = res.state
		seen = s.orderly.seen
	var moved := Vector2(s.orderly.body.x - start.x, s.orderly.body.z - start.z).length()
	return [moved, seen]

func test_the_dark_core_unholds_the_orderly(t: T) -> void:
	if _child():
		return
	for seed: String in ["dg1-rule-1", "dg1-rule-2"]:
		var lit := _watched(seed, 0.0, FL.LIT, 10)
		t.check(float(lit[0]) >= 0.0 and float(lit[0]) < 1e-6 and bool(lit[1]), "%s: lit, a watched Orderly in the run is held (moved %.2f m)" % [seed, float(lit[0])])
		var dark := _watched(seed, 0.0, FL.DARK, 10)
		t.check(float(dark[0]) > 0.3 and not bool(dark[1]), "%s: dark, the same Orderly in the core is unseen and moves (%.2f m)" % [seed, float(dark[0])])
		var rs := _run(seed)
		var len_m := float(_records(rs[1])[0]["n"][0])
		# Its centre 1 m from the run's open end: half in the light beside it, so still held while dark.
		var edge := _watched(seed, len_m / 2.0 - 1.0, FL.DARK, 10)
		t.check(float(edge[0]) < 1e-6 and bool(edge[1]), "%s: dark, an Orderly 1 m from the run's end is still held (moved %.2f m)" % [seed, float(edge[0])])
		# The gift: a lit flashbulb still holds it in the dark core, exactly as in the lift's blink.
		var flashed := _watched(seed, 0.0, FL.DARK, 10, true)
		t.check(float(flashed[0]) >= 0.0 and float(flashed[0]) < 1e-6, "%s: dark, a flashbulb still holds the Orderly in the core (moved %.2f m)" % [seed, float(flashed[0])])

# --- 5. passive -------------------------------------------------------------------------------------------

func test_passive_it_never_touches_a_player(t: T) -> void:
	if _child():
		return
	var src := FileAccess.get_file_as_string("res://sim/dangers/failing_lights.gd")
	for ask: String in ["ask.noise", "ask.stumble", "ask.hold", "ask.blind", "ask.push", "ask.hang", "ask.ledge", "ask.send_out", "ask.close_edge", "ask.solid", "ask.prompt"]:
		t.check(not src.contains(ask + "("), "the rules never call %s" % ask)

## One line per tick (the base test's shape): phase, the run's own events, players, the resident.
static func _line(s: Run.RunState, events: Array[Dictionary]) -> String:
	var parts: Array[String] = ["%.3f %s %d" % [s.t, s.phase, s.depth]]
	for e in events:
		var ty := str(e.get("type", ""))
		if not ty.begins_with("danger"):
			parts.append("%s@%.3f:%s" % [ty, float(e.get("t", -1.0)), str(e.get("playerId", ""))])
	for p in s.players:
		parts.append("%s %s %.4f,%.4f,%d" % [p.id, p.status, p.body.x, p.body.z, p.body.level])
	if s.orderly != null:
		parts.append("o %.4f,%.4f %s" % [s.orderly.body.x, s.orderly.body.z, str(s.orderly.mode)])
	return " | ".join(parts)

## Whether the resident stood in a dark core at this state's time.
static func _resident_in_dark(s: Run.RunState) -> bool:
	if s.dangers == null or s.orderly == null:
		return false
	var b := s.orderly.body
	return DangerFx.dark_at(s.dangers, b.level, b.x, b.z, s.t)

func test_with_it_on_the_run_is_the_same_until_the_dark_holds_the_orderly(t: T) -> void:
	if _child():
		return
	var secs := 30.0 if t.quick else 120.0
	var compared := 0
	for seed: String in ["dg1-same-1", "dg1-same-2", "dg1-same-3"]:
		var ids: Array[String] = ["a", "b"]
		var off_r := HostRules.new(true, 1, Places.FULL, false, false, true)
		var on_r := HostRules.new(true, 1, Places.FULL, false, false, true)
		on_r.dangers = Dangers.resolve([KIND])
		var s_off := off_r.prepare(Run.create_run(seed, ids, Places.FULL))
		var s_on := on_r.prepare(Run.create_run(seed, ids, Places.FULL))
		var bots: Array = []
		for n in ids.size():
			bots.append(Bot.create_bot(s_off.plan, ids[n], "%s:bots" % seed, 0.3 + 0.3 * n))
		var downs_by_danger := 0
		var was_dark := false
		for _k in roundi(secs / DT):
			var ins: Array[Run.PlayerInput] = []
			for n in ids.size():
				var p := s_off.players[n]
				var b: Bot.Bot = bots[n]
				if p.status == &"ok":
					Bot.step_bot(s_off.plan, b, DT, s_off.orderly.body)
					var i := Run.PlayerInput.make(p.id, b.body, 1.65, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
					ins.append(i)
			var a := off_r.step(s_off, ins, DT)
			var c := on_r.step(s_on, ins, DT)
			for e in c.events:
				var ty := str(e.get("type", ""))
				if ty in ["dangerStumble", "dangerHold", "dangerBlind", "dangerPush", "dangerPinned", "dangerNoise"] \
						or (ty == "downed" and str(e.get("by", "")) == "danger"):
					downs_by_danger += 1
			was_dark = was_dark or _resident_in_dark(s_on)
			s_off = a.state
			s_on = c.state
			if was_dark:
				break
			if not t.check(_line(s_off, a.events) == _line(s_on, c.events), "%s: the same run tick for tick while the Orderly is never in the dark (t %.2f)" % [seed, s_on.t]):
				break
			compared += 1
		t.eq(downs_by_danger, 0, "%s: nothing held, blinded, pushed, pinned, noised or downed by the lights" % seed)
	t.check(compared > roundi(secs / DT), "compared a good stretch (%d ticks)" % compared)

# --- 6. the screen -------------------------------------------------------------------------------------------

func test_screen_dark_whenever_the_rules_are(t: T) -> void:
	if _child():
		return
	var recs: Array[Dictionary] = FL.new().place(_place_of("dg1-screen", 2))
	if not t.check(not recs.is_empty(), "a run to draw"):
		return
	var out := _drive(recs[0], 120.0)
	var ch: Array = out["changes"]
	var darks: Array = out["darks"]
	var warn := float(recs[0]["n"][4])
	var bad := 0
	var dark_ticks := 0
	var j := 0
	# At every host time, with the screen's clock up to 0.1 s off either way and the state the snapshot carries.
	for n in roundi(120.0 / DT):
		var ht := float(out["t0"]) + n * DT
		while j + 1 < ch.size() and float(ch[j + 1][0]) <= ht + 1e-9:
			j += 1
		var rules_dark := false
		for r: Array in darks:
			if ht >= float(r[0]) - 1e-9 and ht < float(r[1]) - 1e-9:
				rules_dark = true
		if not rules_dark:
			continue
		dark_ticks += 1
		for e: float in [-0.1, 0.0, 0.1]:
			var look := View.look_at_time(StringName(ch[j][1]), maxf(0.0, ht + e - float(ch[j][0])), warn)
			if look.y < 0.5 or look.x > 0.0:
				bad += 1
	t.check(dark_ticks > 100, "the rules were dark for a while (%d ticks)" % dark_ticks)
	t.eq(bad, 0, "the screen draws the run dark whenever the rules have it dark")
	t.eq(View.look_at_time(FL.LIT, 0.05, warn), Vector2(0.0, 1.0), "late light: the first moment of a lit state is still dark")
	t.eq(View.look_at_time(FL.WARN, warn - 0.05, warn), Vector2(0.0, 1.0), "early dark: the last moment of the warning is already dark")
	t.check(View.look_at_time(FL.LIT, 3.0, warn).x > 0.6, "lit, the tubes burn")
	t.eq(View.look_at_time(FL.WARN, 0.7, warn), View.look_at_time(FL.WARN, 0.7, warn), "from host time only: the same moment looks the same")

## A stand-in for the level's lamp tables (client/level.gd main_lights, _base_energy, panels).
class FakeLevel:
	extends Node3D
	var main_lights: Array[Light3D] = []
	var _base_energy: Array[float] = []
	var panels: Array = []
	var _level := 1.0

func test_the_view_lights_with_one_lamp_and_takes_the_runs_over(t: T) -> void:
	if _child():
		return
	var level := FakeLevel.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(level)
	var rec := {"id": 0, "kind": KIND, "x": 20.0, "y": 0.0, "z": 10.0, "level": 0, "yaw": 0.0, "state": FL.LIT, "since": 0.0,
		"n": [10.0, 2.0, 3.9, 9.0, 1.5, 2.5]}
	# Three lamps over the run, one just past its end, one far away.
	for x: float in [16.0, 20.0, 24.0, 26.5, 40.0]:
		var l := SpotLight3D.new()
		l.position = Vector3(x, 3.15, 10.0)
		level.add_child(l)
		level.main_lights.append(l)
		level._base_energy.append(1.0)
	var v := View.new()
	level.add_child(v)
	v.build(rec, {"level": level})
	var omni := 0
	var shadows := 0
	for c in v.find_children("*", "Light3D", true, false):
		omni += 1
		shadows += 1 if (c as Light3D).shadow_enabled else 0
	t.eq(omni, 1, "one light of its own")
	t.eq(shadows, 0, "and it casts no shadow")
	var inside := 0
	for i in 3:
		inside += 1 if level.main_lights[i].get_parent() != level and not level.main_lights[i].is_visible_in_tree() else 0
	t.eq(inside, 3, "the level's three lamps over the run are taken over (stand-ins in their place)")
	t.check(level.main_lights[3].get_parent() == level and level.main_lights[4].get_parent() == level, "the others stay the level's")
	rec["state"] = FL.DARK
	v.frame(rec, 0.5, 0.016)
	t.check(v.shown_dark and v.shown_k == 0.0, "dark: drawn dark")
	t.eq(level._base_energy[3], View.NEIGHBOUR_SAG, "the lamp just past the end sags with the dark")
	t.eq(level._base_energy[4], 1.0, "a far lamp does not")
	rec["state"] = FL.LIT
	rec["since"] = 1.0
	v.frame(rec, 4.0, 0.016)
	t.check(not v.shown_dark and v.shown_k > 0.6, "lit again: the tubes burn")
	t.eq(level._base_energy[3], 1.0, "and the lamp past the end is back")
	level.free()

## A view on a stand-in level, built from a record lit since 0 (the run of the lamp test): [level, view, rec].
func _view() -> Array:
	var level := FakeLevel.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(level)
	var rec := {"id": 0, "kind": KIND, "x": 20.0, "y": 0.0, "z": 10.0, "level": 0, "yaw": 0.0, "state": FL.LIT, "since": 0.0,
		"n": [10.0, 2.0, 3.9, 9.0, 1.5, 2.5]}
	var v := View.new()
	level.add_child(v)
	v.build(rec, {"level": level})
	return [level, v, rec]

## The strengths drawn over one whole cycle from the warning's start, every millisecond: [secs, k].
static func _cycle_ks(warn: float, dark: float, lit: float) -> Array:
	var out: Array = []
	var total := warn + dark + lit
	for i in roundi(total * 1000.0):
		var x := i / 1000.0
		var k: float
		if x < warn:
			k = View.look_at_time(FL.WARN, x, warn).x
		elif x < warn + dark:
			k = View.look_at_time(FL.DARK, x - warn, warn).x
		else:
			k = View.look_at_time(FL.LIT, x - warn - dark, warn).x
		out.append([x, k])
	return out

func test_the_screen_never_flashes_more_than_three_times_a_second(t: T) -> void:
	if _child():
		return
	# A flash is a pair of opposite changes; a change is a step of more than 0.2 in the tubes' strength. In any one
	# second of a whole cycle there are at most six changes (three flashes), at today's warning, the shortest and the
	# longest.
	for warn: float in [FL.WARN_S, FL.WARN_MIN, 3.0]:
		var ks := _cycle_ks(warn, FL.DARK_S, 6.0)
		var changes: Array[float] = []
		for i in range(1, ks.size()):
			if absf(float(ks[i][1]) - float(ks[i - 1][1])) > 0.2:
				changes.append(float(ks[i][0]))
		var most := 0
		for a in changes.size():
			var n := 0
			for b in range(a, changes.size()):
				if changes[b] - changes[a] < 1.0:
					n += 1
			most = maxi(most, n)
		t.check(most <= 6, "warning %.1f s: at most six big changes in any second (%d)" % [warn, most])
		t.check(changes.size() >= 3, "warning %.1f s: the sag and the strike are there to see (%d changes)" % [warn, changes.size()])

func test_the_warning_sags_where_it_can_be_seen(t: T) -> void:
	if _child():
		return
	var lv: Array = _view()
	var level: FakeLevel = lv[0]
	var v: View = lv[1]
	var rec: Dictionary = lv[2]
	var warn := float(rec["n"][4])
	# A slow, deep sag: the last third of the warning at most 0.4 of the lit strength, each third held a third of it.
	var thirds: Array[float] = []
	for third in 3:
		thirds.append(View.look_at_time(FL.WARN, (third + 0.5) * warn / 3.0, warn).x)
	t.check(thirds[0] > 0.85 and thirds[1] < 0.7 and thirds[2] < 0.4, "the warning sags in three steps (%s)" % str(thirds))
	t.check(View.end_glow_at(FL.WARN, warn * 0.8, warn) > 0.3 and View.end_glow_at(FL.LIT, 3.0, warn) == 0.0, "the tube ends glow orange while it winds down, black when lit")
	# The lamps past each end sag with it, and the view's own lamp.
	rec["state"] = FL.WARN
	rec["since"] = 10.0
	v.frame(rec, 10.0 + warn * 0.85, 0.016)
	t.check(v.shown_neighbour < 0.65 and v.shown_k < 0.4 and not v.shown_dark, "late in the warning: the lamps past its ends at %.2f, the tubes at %.2f, not yet dark" % [v.shown_neighbour, v.shown_k])
	level.free()

func test_the_light_comes_back_by_the_drawn_time(t: T) -> void:
	if _child():
		return
	var lv: Array = _view()
	var level: FakeLevel = lv[0]
	var v: View = lv[1]
	var rec: Dictionary = lv[2]
	# Lit again from host time 50 (the dark's end). This screen's clock runs on, but it draws snapshots 0.3 s behind:
	# it stays dark until the drawn time is GUARD past the dark's end.
	rec["state"] = FL.LIT
	rec["since"] = 50.0
	var bad := 0
	for i in 80:
		var ht := 50.0 + i * 0.01
		v.drawn_override = maxf(0.0, ht - 0.3)
		v.frame(rec, ht, 0.01)
		if v.drawn_override < 50.0 + View.GUARD - 1e-6 and (not v.shown_dark or v.shown_k > 0.0):
			bad += 1
	t.eq(bad, 0, "with the drawn snapshots 0.3 s behind, nothing lights before they pass the dark's end")
	v.drawn_override = 51.5
	v.frame(rec, 51.8, 0.01)
	t.check(not v.shown_dark and v.shown_k > 0.6, "once they have, the tubes burn")
	# The dark core's multiply follows the drawn dark exactly.
	v.drawn_override = 50.05
	v.frame(rec, 50.35, 0.01)
	t.check(v.shown_dark and v.shown_dim == View.DIM, "drawn dark: the core drawn at %.2f" % View.DIM)
	v.drawn_override = 51.5
	v.frame(rec, 51.8, 0.01)
	t.eq(v.shown_dim, 1.0, "lit: the core not dimmed")
	level.free()

func test_the_strip_and_the_dim_are_exactly_the_core(t: T) -> void:
	if _child():
		return
	var lv: Array = _view()
	var level: FakeLevel = lv[0]
	var v: View = lv[1]
	var rec: Dictionary = lv[2]
	var core_len := 2.0 * float(rec["n"][2])
	t.check(absf(((v._strips[0] as MeshInstance3D).mesh as BoxMesh).size.x - core_len) < 1e-4, "the amber strip is the rules' dark core long (%.2f m)" % core_len)
	var aabb := (v._dim_box as MeshInstance3D).mesh.get_aabb()
	t.check(absf(float(v._dim_mat.get_shader_parameter("core")) - float(rec["n"][2])) < 1e-4 and absf(aabb.end.x - float(rec["n"][2]) - View.RAMP) < 1e-3 and absf(aabb.position.x + float(rec["n"][2]) + View.RAMP) < 1e-3, "the shade is full over the core, easing out only past its ends (%.2f to %.2f m)" % [aabb.position.x, aabb.end.x])
	# The ease is long enough to read as light dying away from 12 m down the hall, not a ruled edge: as far as the
	# lamps past each end that sag with it.
	t.check(View.RAMP >= View.NEIGHBOUR_REACH, "the ease past each end is %.1f m (at least %.1f m)" % [View.RAMP, View.NEIGHBOUR_REACH])
	# And the rules' core is that long: placed runs send n[2] = half the core.
	var recs: Array[Dictionary] = FL.new().place(_place_of("dg1-core", 2))
	t.check(not recs.is_empty(), "runs to measure")
	for r in recs:
		var c: Array = r["k"]["core"]
		var along := absf(float(r["yaw"])) < 0.1
		var clen := (float(c[2]) - float(c[0])) if along else (float(c[3]) - float(c[1]))
		t.check(absf(clen - 2.0 * float(r["n"][2])) < 1e-6, "a run at %.1f, %.1f: the core it darkens is the strip's length" % [float(r["x"]), float(r["z"])])
	level.free()

func test_its_sounds_sit_in_the_mix(t: T) -> void:
	if _child():
		return
	# Each stream in its category's band (kind_view.gd BANDS), no clipped sample, peak at most -1 dBFS.
	var cats := {"buzz": &"room", "wind": &"effect", "out": &"effect", "dark": &"ambience", "strike": &"effect"}
	for name: String in cats:
		var st: AudioStreamWAV = load(View.SND + name + ".wav")
		var m := KindView.measure(st)
		t.check(KindView.in_band(m, cats[name]), "%s.wav sits in the %s band: loudness %.1f dBFS, peak %.1f dBFS, %d clipped" % [name, cats[name], float(m["loud_db"]), float(m["peak_db"]), int(m["clipped"])])
	# Played through the base's mix: every player at Sfx.BASE_DB or lower, max_db 0, its category's bus, unit size and
	# range; the loops loop.
	var lv: Array = _view()
	var level: FakeLevel = lv[0]
	var v: View = lv[1]
	var rec: Dictionary = lv[2]
	var players := {}
	var steps: Array = [[FL.LIT, 0.0, 3.0], [FL.WARN, 10.0, 10.2], [FL.DARK, 11.5, 11.7], [FL.LIT, 14.0, 14.4], [FL.LIT, 14.0, 14.9]]
	for st: Array in steps:
		rec["state"] = st[0]
		rec["since"] = st[1]
		v.drawn_override = st[2]
		v.frame(rec, st[2], 0.016)
		for c in v.get_children():
			if c is AudioStreamPlayer3D:
				players[c] = true
	var bad := 0
	var loops := 0
	var buses := {}
	for p: AudioStreamPlayer3D in players:
		buses[str(p.bus)] = true
		var fits := false
		for cat: StringName in KindView.CATS:
			var row: Array = KindView.CATS[cat]
			if StringName(row[0]) == StringName(p.bus) and absf(float(row[1]) - p.unit_size) < 1e-6 and absf(float(row[2]) - p.max_distance) < 1e-6:
				fits = true
		if not fits or p.volume_db > Sfx.BASE_DB + 1e-6 or p.max_db > 0.0:
			bad += 1
		var w := p.stream as AudioStreamWAV
		if w != null and w.loop_mode == AudioStreamWAV.LOOP_FORWARD:
			loops += 1
	t.check(players.size() >= 5, "the cycle plays its sounds (%d players)" % players.size())
	t.eq(bad, 0, "every one at the house level (Sfx.BASE_DB at most), a category's bus, unit size and range")
	t.check(loops >= 2, "the hum and the starter's ticks loop (%d)" % loops)
	t.check(buses.has("Ambience") and buses.has("Effects"), "the hum and ticks on the Ambience bus, the cues on Effects (%s)" % str(buses.keys()))
	level.free()

func test_the_near_light_keeps_its_ground_in_the_dark(t: T) -> void:
	if _child():
		return
	# The base's near light (kind_view.gd near_light_reach/near_light_at): no shade within half its reach of the camera,
	# full shade from its reach out; with no near light, the shade as it was.
	var r := KindView.NEAR_LIGHT_REACH
	t.eq(View.shade_left(0.0, r * 0.4, 3.9, r), 1.0, "at the player's feet in the core: nothing shaded")
	t.check(absf(View.shade_left(0.0, r * 1.2, 3.9, r) - View.DIM) < 1e-6, "beyond the near light: the full shade")
	t.check(View.shade_left(0.0, r * 0.75, 3.9, r) > View.DIM and View.shade_left(0.0, r * 0.75, 3.9, r) < 1.0, "between: easing")
	t.check(absf(View.shade_left(0.0, 0.5, 3.9, 0.0) - View.DIM) < 1e-6, "no near light: the full shade")
	# The view hands the camera point and reach to its shade every dark frame.
	var lv: Array = _view()
	var level: FakeLevel = lv[0]
	var v: View = lv[1]
	var rec: Dictionary = lv[2]
	var dv := DangersView.new()
	dv.near_at = Vector3(20.0, 1.6, 10.0)
	dv.near_reach = r
	v.base = dv
	rec["state"] = FL.DARK
	rec["since"] = 10.0
	v.frame(rec, 10.5, 0.016)
	t.eq(v._dim_mat.get_shader_parameter("cam"), Vector3(20.0, 1.6, 10.0), "the shade knows where the camera is")
	t.eq(float(v._dim_mat.get_shader_parameter("reach")), r, "and how far the near light reaches")
	v.base = null
	dv.free()
	level.free()

func test_the_warning_plays_whole_in_a_blink(t: T) -> void:
	if _child():
		return
	var lv: Array = _view()
	var level: FakeLevel = lv[0]
	var v: View = lv[1]
	var rec: Dictionary = lv[2]
	var dv := DangersView.new()
	dv.blink_dark = true
	v.base = dv
	rec["state"] = FL.WARN
	rec["since"] = 10.0
	v.frame(rec, 10.05, 0.016)
	var cues := 0
	for c in v.get_children():
		if c is AudioStreamPlayer3D and (c as AudioStreamPlayer3D).stream != null and (c as AudioStreamPlayer3D).stream.resource_path.ends_with("wind.wav"):
			cues += 1
	t.eq(cues, 1, "the wind-down plays even while the lift's blink darkens the floor")
	v.base = null
	dv.free()
	level.free()

func test_the_notice_can_be_read(t: T) -> void:
	if _child():
		return
	var img := View.notice_image()
	# The sheet is NOTICE_SIZE.y tall: a body row (17 texels) at least 3 cm, the heading's (24) at least 4.5 cm, on a
	# sheet no wider than 0.42 m.
	var per := View.NOTICE_SIZE.y / float(img.get_height())
	t.check(per * 17.0 >= 0.03 and per * 24.0 >= 0.045, "rows %.1f cm, heading %.1f cm" % [per * 1700.0, per * 2400.0])
	t.check(per * img.get_width() <= 0.42, "the sheet %.2f m wide" % (per * img.get_width()))
	var inked := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).v < 0.3:
				inked += 1
	t.check(inked > 500, "it has lettering on it (%d dark texels)" % inked)
	# Hung so its foot clears the bumper rail, as the Clinic's eye-height pieces do (client/clinic_dress.gd EYE_LO).
	t.check(View.NOTICE_Y - View.NOTICE_SIZE.y / 2.0 >= ClinicDress.EYE_LO, "its foot at %.2f m, above the rail (%.2f m)" % [View.NOTICE_Y - View.NOTICE_SIZE.y / 2.0, ClinicDress.EYE_LO])

# --- 7. live settings ---------------------------------------------------------------------------------------

## Seconds of each state over a driven stretch, after the first cycle: {state: [lengths]}.
static func _lengths(tuning: Dictionary) -> Dictionary:
	var recs: Array[Dictionary] = FL.new().place(_place_of("dg1-set", 2, tuning))
	var out := {FL.LIT: [], FL.WARN: [], FL.DARK: []}
	if recs.is_empty():
		return out
	var ch: Array = _drive(recs[0], 80.0, tuning)["changes"]
	for j in range(1, ch.size() - 1):
		(out[StringName(ch[j][1])] as Array).append(float(ch[j + 1][0]) - float(ch[j][0]))
	return out

static func _all_near(xs: Array, want: float) -> bool:
	if xs.is_empty():
		return false
	for x: float in xs:
		if absf(x - want) > DT + 1e-6:
			return false
	return true

func test_setting_failing_lights_lit(t: T) -> void:
	if _child():
		return
	var l := _lengths({&"danger.failing_lights.lit": 14.0})
	t.check(_all_near(l[FL.LIT], 14.0 - FL.WARN_S), "lit 14 s: lit for 12.5 s before each 1.5 s wind-down (%s)" % str(l[FL.LIT]))
	t.check(_all_near(_lengths({})[FL.LIT], FL.LIT_S - FL.WARN_S), "today: 7.5 s")

func test_setting_failing_lights_warn(t: T) -> void:
	if _child():
		return
	t.check(_all_near(_lengths({&"danger.failing_lights.warn": 2.5})[FL.WARN], 2.5), "warn 2.5 s: the wind-down lasts 2.5 s")
	t.check(_all_near(_lengths({&"danger.failing_lights.warn": 0.5})[FL.WARN], 1.0), "never under a second, whatever is asked")

func test_setting_failing_lights_dark(t: T) -> void:
	if _child():
		return
	t.check(_all_near(_lengths({&"danger.failing_lights.dark": 4.0})[FL.DARK], 4.0), "dark 4 s: dark for 4 s")
	t.check(_all_near(_lengths({})[FL.DARK], FL.DARK_S), "today: 2.5 s")

func test_setting_failing_lights_length(t: T) -> void:
	if _child():
		return
	var a: Array[Dictionary] = FL.new().place(_place_of("dg1-len", 2, {&"danger.failing_lights.length": 3.0}))
	var b: Array[Dictionary] = FL.new().place(_place_of("dg1-len", 2))
	t.check(not a.is_empty() and float(a[0]["n"][0]) == 6.0, "length 3: a run 6 m long")
	t.check(not b.is_empty() and float(b[0]["n"][0]) == 10.0, "today: 10 m")

func test_setting_failing_lights_count(t: T) -> void:
	if _child():
		return
	var one := 0
	var three := 0
	for i in 6:
		one += FL.new().place(_place_of("dg1-count-%d" % i, 2, {&"danger.failing_lights.count": 1.0})).size()
		three += FL.new().place(_place_of("dg1-count-%d" % i, 2, {&"danger.failing_lights.count": 3.0})).size()
	t.eq(one, 6, "count 1: one run on each deeper floor")
	t.check(three > one, "count 3: more runs where they fit (%d on 6 floors)" % three)

func test_setting_failing_lights_first_count(t: T) -> void:
	if _child():
		return
	var two := 0
	var today := 0
	for i in 6:
		two += FL.new().place(_place_of("dg1-first-%d" % i, 1, {&"danger.failing_lights.first_count": 2.0})).size()
		today += FL.new().place(_place_of("dg1-first-%d" % i, 1)).size()
	t.eq(today, 6, "today: one run on the first floor")
	t.check(two > 6, "first_count 2: more on the first floor (%d on 6)" % two)

func test_setting_failing_lights_apart(t: T) -> void:
	if _child():
		return
	var near := 0
	var far := 0
	for i in 6:
		var tun := {&"danger.failing_lights.count": 4.0, &"danger.failing_lights.apart": 40.0}
		var p := _place_of("dg1-apart-%d" % i, 2, tun)
		var recs: Array[Dictionary] = FL.new().place(p)
		far += recs.size()
		near += FL.new().place(_place_of("dg1-apart-%d" % i, 2, {&"danger.failing_lights.count": 4.0, &"danger.failing_lights.apart": 8.0})).size()
		for a in recs.size():
			var c: Array = recs[a]["k"]["cells"][recs[a]["k"]["cells"].size() / 2]
			var d := Floor.distances_from(p.plan, Floor.Pos.make(c[0], c[1], c[2]))
			for b in recs.size():
				if b == a:
					continue
				for cb: Array in recs[b]["k"]["cells"]:
					var steps := d[Floor.pos_index(p.plan, Floor.Pos.make(cb[0], cb[1], cb[2]))]
					t.check(steps < 0 or steps * 2 >= 40, "apart 40 m: runs at least 40 m apart by walking (%d m)" % (steps * 2))
	t.check(far < near, "apart 40 m fits fewer runs than 8 m (%d against %d)" % [far, near])

func test_setting_failing_lights_from(t: T) -> void:
	if _child():
		return
	var p := _place_of("dg1-from", 2, {&"danger.failing_lights.from": 85.0})
	var recs: Array[Dictionary] = FL.new().place(p)
	var far := 0
	for d in p.lift_steps:
		far = maxi(far, d)
	var ok := not recs.is_empty()
	var low := 1 << 30
	for r in recs:
		for c: Array in r["k"]["cells"]:
			var st := p.lift_steps[Floor.pos_index(p.plan, Floor.Pos.make(c[0], c[1], c[2]))]
			low = mini(low, st)
			ok = ok and st >= ceili(0.85 * far)
	t.check(ok, "from 85: every cell at least 85 in 100 of the walk to the far end (nearest %d of %d)" % [low, far])
