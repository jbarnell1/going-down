# DG6, the Reactor's steam (sim/dangers/steam.gd, client/dangers/steam_view.gd) on the dangers base (sim/dangers.gd).
# Held here:
#   - placement on many generated stations: the hall's band is a whole hall row clear of the rotor, the hall's south
#     end, every doorway, the four and the fuse's reach; the crawl's band is one long-leg cell two or more steps from
#     each mouth, not under its lamp; every band clear of the base's keep-clear discs; only on the Reactor;
#   - a careful way always exists: with the crawl's band taken out, every fuse spot, the cabinet and the lift are a
#     walk from the landing; creeping passes under the hall's band; the cabinet-to-lift walk never crosses a band;
#   - the beat in all three power states (lit, the cut, restored): at most one band live outside a purge, none live
#     longer than its jet (or purge), every hazard at least steam.build + steam.grace (over a second) after its build
#     begins, a purge at the cut and at the restore, each with its build first;
#   - the flinch: a walker into a live band is pushed back out on their own side, blinded and cries out once per jet;
#     a creeper passes the hall's band but not the crawl's; 200 random entries are never pushed into a wall, the crawl,
#     another band or the car; a cry inside the crawl is heard at a mouth, outside it;
#   - passive: it never downs, pins or sends anyone out (the kind's asks, and bot runs through the base);
#   - the same seed, the same jets (twice here, and the recorded fingerprint from another process);
#   - the base: with the kind off or not enabled nothing changes; enabled, it is placed only on the Reactor;
#   - the drawn steam is thin (a body behind it always shows: the most it hides is bounded);
#   - every number is a live setting (test_setting_steam_*).
extends RefCounted

const T = preload("res://tests/t.gd")
const Steam = preload("res://sim/dangers/steam.gd")
const Api = preload("res://sim/dangers/api.gd")
const Dangers = preload("res://sim/dangers.gd")
const Station = preload("res://sim/station.gd")
const SR = preload("res://sim/station_floor.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Run = preload("res://sim/run.gd")
const Settings = preload("res://sim/settings.gd")
const Places = preload("res://sim/places.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const View = preload("res://client/dangers/steam_view.gd")
const KindView = preload("res://client/dangers/kind_view.gd")
const PS = preload("res://tests/prop_station.gd")
const HostRules = preload("res://net/host_rules.gd")
const M = preload("res://sim/jsmath.gd")
const NetT = preload("res://tests/test_dangers_net.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Session = preload("res://net/session.gd")
const PlayLink = preload("res://client/play_link.gd")
const DangerFx = preload("res://sim/dangers/effects.gd")

const DT := 0.05
## The fingerprint of the jets placed on FIXED_SEEDS (recorded once; another process must place the same).
const FIXED_SEEDS: Array[String] = ["steam-a", "steam-b", "steam-c"]
const FIXED_PRINT := "3096496298"
## The most the drawn steam may hide of a body behind it (0 clear, 1 opaque).
const MOST_HIDDEN := 0.6

static func _seeds(t: T, quick: int, full: int) -> int:
	return quick if t.quick else full

## The jets of a station floor, placed as the base places them (its keep-clear discs, the kind's own generator).
static func place(seed: String, tuning: Settings.Values = null) -> Dictionary:
	var plan := Station.generate_station(seed, 7)
	var s := Run.RunState.new()
	s.plan = plan
	s.car = Run.car_geometry(plan)
	var p := Api.Place.new()
	p.plan = plan
	p.place = plan.place
	p.depth = 7
	p.floor_seed = seed
	p.tuning = tuning
	p.car = s.car
	p.rng = Rng.make_rng(seed + ":danger:steam")
	p.lift_steps = Floor.distances_from(plan, plan.landing)
	p.keep_clear = Dangers.keep_clear_of(s, null)
	var recs: Array[Dictionary] = Steam.new().place(p)
	for i in recs.size():
		recs[i]["id"] = i
		recs[i]["kind"] = &"steam"
		recs[i]["since"] = 0.0
	return {"plan": plan, "recs": recs, "p": p}

## A stand-in for the base: steps the records and logs every ask [t, id, op, args].
class Sim:
	var recs: Array[Dictionary]
	var plan: Floor.FloorPlan
	var tuning: Settings.Values
	var log: Array = []
	var t := 0.0
	var kind := Steam.new()

	func tick(players: Array[Api.Who], events: Array[Dictionary]) -> void:
		var k := Api.Tick.new()
		k.t = t
		k.dt = DT
		k.place = &"reactor"
		k.depth = 7
		k.plan = plan
		k.tuning = tuning
		k.floor_t = t
		k.players = players
		k.events = events
		var ask := Api.Asks.new()
		ask.t = t
		ask._do = func(op: StringName, rec: Dictionary, args: Array) -> bool:
			log.append([t, int(rec["id"]), op, args])
			return true
		for rec in recs:
			kind.step(rec, k, ask)
		t += DT

static func sim_of(f: Dictionary, tuning: Settings.Values = null) -> Sim:
	var sm := Sim.new()
	sm.recs = f["recs"]
	sm.plan = f["plan"]
	sm.tuning = tuning
	return sm

static func who(id: String, x: float, z: float, speed: StringName) -> Api.Who:
	var w := Api.Who.new()
	w.id = id
	w.body = Move.Body.make(x, z, 0, 0.0)
	w.speed = speed
	# The input's gait as the base reports it (still keeps the walk's gait unless set).
	w.gait = speed if speed != &"still" else &"walk"
	w.up = true
	return w

static func _rows(rec: Dictionary) -> Rect2:
	return Steam.band_of(rec)

# --- placement ----------------------------------------------------------------------------------------------------

func test_steam_placement(t: T) -> void:
	var n := _seeds(t, 40, 400)
	var no_hall := 0
	var no_crawl := 0
	var full := 0
	for i in n:
		var f := place("steam-place-%d" % i)
		var plan: Floor.FloorPlan = f["plan"]
		var p: Api.Place = f["p"]
		var a := plan.station
		var hall: Rect2 = a["hall"]
		var top := int(round(hall.position.y / 2.0))
		var bottom := int(round(hall.end.y / 2.0)) - 1
		var halls := 0
		var crawls := 0
		for rec: Dictionary in f["recs"]:
			var band := _rows(rec)
			var which := int(rec["k"]["which"])
			# Clear of every keep-clear disc, the fuse's reach of every fuse spot and the cabinet.
			for d: Dictionary in p.keep_clear:
				var gap := Steam._rect_gap(band, float(d["x"]), float(d["z"]))
				t.check(gap >= float(d["r"]) - 0.26, "seed %d: a band within a keep-clear disc (%s)" % [i, str(d)])
			for fs: Vector3 in a["fuse_spots"]:
				t.check(Steam._rect_gap(band, fs.x, fs.z) >= Steam.USE_REACH, "seed %d: a band within reach of a fuse spot" % i)
			var cab: Vector3 = a["cabinet"]["at"]
			t.check(Steam._rect_gap(band, cab.x, cab.z) >= Steam.USE_REACH, "seed %d: a band within reach of the cabinet" % i)
			if which == Steam.WHICH_HALL:
				halls += 1
				var r := int(round(band.position.y / 2.0))
				var mid_x := hall.get_center().x
				t.check(band.position.x >= hall.position.x - 1e-6 and band.end.x <= hall.end.x + 1e-6 and band.position.x < mid_x and band.end.x > mid_x and band.size.x >= Steam.BAND_MIN * 2.0 - 1e-6, "seed %d: the hall's band is not a run of three or more hall cells through its middle" % i)
				if is_equal_approx(band.size.x, hall.size.x):
					full += 1
				for d in plan.doors:
					for cell: Vector2i in [Vector2i(d.ax, d.ay), Vector2i(d.bx, d.by)]:
						t.check(not band.has_point(Vector2((cell.x + 0.5) * 2.0, (cell.y + 0.5) * 2.0)), "seed %d: the hall's band covers a doorway's cell" % i)
				t.check(r >= top + 2 and r <= bottom - 3, "seed %d: hall band row %d outside %d..%d" % [i, r, top + 2, bottom - 3])
				for b: Dictionary in a["bodies"]:
					var br := int(floor((b["at"] as Vector3).z / 2.0))
					t.check(absi(br - r) > 1, "seed %d: the hall's band beside one of the four" % i)
			else:
				crawls += 1
				var c := Station.cell_of(band.get_center().x, band.get_center().y)
				t.check(Station.creep_only(plan, c.x, c.y), "seed %d: the crawl's band is not in the crawl" % i)
				for l: Dictionary in a["lamps"]:
					var at: Vector3 = l["at"]
					t.check(Station.cell_of(at.x, at.z) != c, "seed %d: the crawl's band under a lamp" % i)
		if halls == 0:
			no_hall += 1
		if crawls == 0:
			no_crawl += 1
		t.check(halls <= Steam.HALL and crawls <= Steam.CRAWL, "seed %d: too many jets" % i)
	t.note("%d floors: %d without a hall jet (%d hall jets the hall's whole width), %d without a crawl jet" % [n, no_hall, full, no_crawl])
	if not t.quick:
		t.check(no_hall * 5 <= n, "a hall jet on fewer than four floors in five (%d of %d without)" % [no_hall, n])
		t.check(no_crawl * 10 <= n, "a crawl jet on fewer than nine floors in ten (%d of %d without)" % [no_crawl, n])

func test_steam_only_on_the_reactor(t: T) -> void:
	var plan := Places.generate("steam-clinic", 1)
	var p := Api.Place.new()
	p.plan = plan
	p.place = plan.place
	p.rng = Rng.make_rng("steam-clinic:danger:steam")
	t.eq(Steam.new().place(p).size(), 0, "jets placed off the Reactor")

## Cells a band covers.
static func _cells(band: Rect2) -> Dictionary:
	var out := {}
	for cz in range(int(round(band.position.y / 2.0)), int(round(band.end.y / 2.0))):
		for cx in range(int(round(band.position.x / 2.0)), int(round(band.end.x / 2.0))):
			out[Vector2i(cx, cz)] = true
	return out

## Walking steps from `from` with `blocked` cells removed (the crawl counts as walkable: a creep).
static func _reach(plan: Floor.FloorPlan, from: Vector2i, blocked: Dictionary) -> Dictionary:
	var adj := Floor.adjacency_of(plan)
	var seen := {from: 0}
	var queue: Array[Vector2i] = [from]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_front()
		var at := c.y * plan.width + c.x
		for k in range(adj.start[at], adj.start[at + 1]):
			var to := adj.list[k]
			if to >= plan.width * plan.height:
				continue
			var cc := Vector2i(to % plan.width, to / plan.width)
			if seen.has(cc) or blocked.has(cc):
				continue
			seen[cc] = int(seen[c]) + 1
			queue.append(cc)
	return seen

func test_steam_ways_through(t: T) -> void:
	var n := _seeds(t, 40, 400)
	var loop_round := 0
	var halls := 0
	for i in n:
		var f := place("steam-ways-%d" % i)
		var plan: Floor.FloorPlan = f["plan"]
		var a := plan.station
		var land := Vector2i(plan.landing.x, plan.landing.y)
		var cab: Vector3 = a["cabinet"]["at"]
		var targets: Array[Vector2i] = [Station.cell_of(cab.x, cab.z), land]
		for fs: Vector3 in a["fuse_spots"]:
			targets.append(Station.cell_of(fs.x, fs.z))
		var all_bands := {}
		for rec: Dictionary in f["recs"]:
			var cells := _cells(_rows(rec))
			all_bands.merge(cells)
			var which := int(rec["k"]["which"])
			var seen := _reach(plan, land, cells)
			var ok := true
			for tg in targets:
				ok = ok and seen.has(tg)
			if which == Steam.WHICH_CRAWL:
				# Walking, with the crawl's band live: everything still a walk away.
				t.check(ok, "seed %d: the crawl's live band cuts off a fuse spot, the cabinet or the lift" % i)
			else:
				halls += 1
				if ok:
					loop_round += 1
		# The dash from the cabinet to the lift (the shortest walk) never crosses a band.
		var from_cab := _reach(plan, Station.cell_of(cab.x, cab.z), {})
		var cur := land
		var guard := 0
		while int(from_cab.get(cur, 0)) > 0 and guard < 400:
			t.check(not all_bands.has(cur), "seed %d: the cabinet-to-lift walk crosses a band at %s" % [i, str(cur)])
			var best := cur
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nb: Vector2i = cur + d
				if from_cab.has(nb) and int(from_cab[nb]) < int(from_cab[best]):
					best = nb
			if best == cur:
				break
			cur = best
			guard += 1
	t.note("%d hall jets; the loop (hall, gallery, crawl) goes round the live hall band on %d (creeping under always does)" % [halls, loop_round])

# --- the beat --------------------------------------------------------------------------------------------------------

## Runs a floor for `secs` with the cut at `cut` and the restore at `restore` (host time); returns per-record spans
## [{id, build_at, jet_at, end, purge}] and the log.
static func run_beat(f: Dictionary, secs: float, cut: float, restore: float, tuning: Settings.Values = null) -> Dictionary:
	var sm := sim_of(f, tuning)
	var spans: Array = []
	var open := {}
	var before := {}
	var live_max := 0
	var purge_live_max := 0
	var no_one: Array[Api.Who] = []
	while sm.t < secs:
		var ev: Array[Dictionary] = []
		if absf(sm.t - cut) < DT * 0.5:
			ev.append({"type": "powerCut", "t": sm.t})
		if absf(sm.t - restore) < DT * 0.5:
			ev.append({"type": "powerRestored", "t": sm.t})
		sm.tick(no_one, ev)
		var live := 0
		var purging := false
		for rec in sm.recs:
			var id := int(rec["id"])
			var st := StringName(rec["state"])
			var was: StringName = before.get(id, &"rest")
			if st != was:
				if st == Steam.BUILD:
					open[id] = {"id": id, "build_at": float(rec["since"]), "jet_at": -1.0, "end": -1.0, "purge": bool(rec["k"]["purge"])}
				elif st == Steam.JET and open.has(id):
					open[id]["jet_at"] = float(rec["since"])
					open[id]["purge"] = bool(rec["k"]["purge"])
				elif st == Steam.REST and open.has(id):
					open[id]["end"] = float(rec["since"])
					spans.append(open[id])
					open.erase(id)
				before[id] = st
			if st == Steam.JET:
				live += 1
				purging = purging or bool(rec["k"]["purge"])
		if purging:
			purge_live_max = maxi(purge_live_max, live)
		else:
			live_max = maxi(live_max, live)
	return {"spans": spans, "live_max": live_max, "log": sm.log}

func test_steam_beat(t: T) -> void:
	var n := _seeds(t, 20, 200)
	var build := Steam.BUILD_S
	var grace := Steam.GRACE
	for i in n:
		var f := place("steam-beat-%d" % i)
		if (f["recs"] as Array).is_empty():
			continue
		var cut := 30.0 + float(i % 7)
		var restore := cut + 40.0 + float(i % 5) * 1.3
		var r := run_beat(f, restore + 40.0, cut, restore)
		t.check(int(r["live_max"]) <= 1, "seed %d: two bands live together outside a purge" % i)
		var purges_cut := 0
		var purges_restore := 0
		var lit_spans := 0
		var dark_spans := 0
		for sp: Dictionary in r["spans"]:
			var jet_at := float(sp["jet_at"])
			var end := float(sp["end"])
			var b0 := float(sp["build_at"])
			t.check(jet_at >= 0.0, "seed %d: a jet with no build before it" % i)
			# Heard first: the hazard starts build + grace after the knocks begin, and that is over a second.
			t.check(jet_at + grace - b0 >= build + grace - 1e-6 and jet_at + grace - b0 >= 1.0, "seed %d: a hazard %.2f s after its build" % [i, jet_at + grace - b0])
			var most := Steam.PURGE if bool(sp["purge"]) else Steam.JET_S
			t.check(end - jet_at <= most + DT + 1e-6, "seed %d: a band live %.2f s (most %.2f)" % [i, end - jet_at, most])
			if bool(sp["purge"]):
				# A purge starts a build, or rides one already under way (its knocks were already heard).
				if b0 <= cut + 1e-6 and b0 > cut - Steam.BUILD_S - 1e-6:
					purges_cut += 1
				elif b0 <= restore + 1e-6 and b0 > restore - Steam.BUILD_S - 1e-6:
					purges_restore += 1
				else:
					t.check(false, "seed %d: a purge at %.2f, not at the cut or the restore" % [i, b0])
			elif b0 < cut:
				lit_spans += 1
			elif b0 < restore:
				dark_spans += 1
		var count := (f["recs"] as Array).size()
		t.eq(purges_cut, count, "seed %d: every jet purges at the cut" % i)
		t.eq(purges_restore, count, "seed %d: every jet purges at the restore" % i)
		t.check(lit_spans >= count and dark_spans >= count, "seed %d: the beat runs in the light and in the cut (%d, %d)" % [i, lit_spans, dark_spans])

func test_steam_beat_slower_in_the_dark(t: T) -> void:
	var f := place("steam-dark")
	var r := run_beat(f, 200.0, 60.0, 1e9)
	var lit_gaps: Array[float] = []
	var dark_gaps: Array[float] = []
	var last := {}
	for sp: Dictionary in r["spans"]:
		var id := int(sp["id"])
		var b0 := float(sp["build_at"])
		if last.has(id) and not bool(sp["purge"]):
			(lit_gaps if b0 < 60.0 else dark_gaps).append(b0 - float(last[id]))
		last[id] = b0
	t.check(not lit_gaps.is_empty() and not dark_gaps.is_empty(), "no beats measured")
	if not lit_gaps.is_empty() and not dark_gaps.is_empty():
		t.check(absf(lit_gaps[-1] - (Steam.BUILD_S + Steam.JET_S + Steam.REST_LIT)) < 0.11, "the lit beat is %.2f s" % lit_gaps[-1])
		t.check(absf(dark_gaps[-1] - (Steam.BUILD_S + Steam.JET_S + Steam.REST_DARK)) < 0.11, "the dark beat is %.2f s" % dark_gaps[-1])

# --- the flinch -----------------------------------------------------------------------------------------------------

## The first floor of a run of seeds with both a hall and a crawl jet; [floor, hall record, crawl record].
static func both(prefix: String) -> Array:
	for i in 200:
		var f := place("%s-%d" % [prefix, i])
		var h: Variant = null
		var c: Variant = null
		for rec: Dictionary in f["recs"]:
			if int(rec["k"]["which"]) == Steam.WHICH_HALL:
				h = rec
			else:
				c = rec
		if h != null and c != null:
			return [f, h, c]
	return []

## Forces `rec` into its jet past the grace and steps once with `players` (their last tick at `prev` z).
static func hit_once(f: Dictionary, rec: Dictionary, players: Array[Api.Who], prev: Dictionary) -> Array:
	var sm := sim_of(f)
	sm.recs = [rec]
	rec["state"] = Steam.JET
	rec["since"] = 0.0
	rec["k"]["started"] = true
	rec["k"]["hit"] = {}
	rec["k"]["side"] = prev.duplicate()
	sm.t = Steam.GRACE + 0.1
	sm.tick(players, [])
	return sm.log

static func ops(log: Array, op: StringName) -> Array:
	var out: Array = []
	for e: Array in log:
		if e[2] == op:
			out.append(e)
	return out

func test_steam_flinch(t: T) -> void:
	var b := both("steam-flinch")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var f: Dictionary = b[0]
	var hall: Dictionary = b[1]
	var crawl: Dictionary = b[2]
	var band := Steam.hazard_of(hall)
	var x := band.get_center().x
	var mid := band.get_center().y
	# What scalds is HAZARD_HALF either side of the line: a walker stopped 0.9 m off it is not touched, 0.3 m off is.
	for off: float in [-0.9, 0.9]:
		t.eq(ops(hit_once(f, hall.duplicate(true), [who("e", x, mid + off, &"walk")], {"e": mid + off}), &"push").size(), 0, "a walker stopped %.1f m off the line is not scalded" % off)
	for off: float in [-0.3, 0.3]:
		t.eq(ops(hit_once(f, hall.duplicate(true), [who("e", x, mid + off, &"walk")], {"e": mid + off * 3.0}), &"push").size(), 1, "a walker %.1f m off the line is scalded" % off)
	# A walker from the north, just into the steam: pushed north (dz < 0), stood clear of it.
	var w := who("p1", x, band.position.y - 0.2, &"walk")
	var log := hit_once(f, hall.duplicate(true), [w], {"p1": band.position.y - 0.5})
	var push := ops(log, &"push")
	t.eq(push.size(), 1, "a walker into the hall's live steam is pushed once")
	if push.size() == 1:
		var dz := float(push[0][3][2])
		var gap := band.position.y - (w.body.z + dz)
		t.check(dz < 0.0 and gap >= 0.6 - 1e-6 and gap <= 0.8 + 1e-6, "pushed back north, stood %.2f m clear of the steam (dz %.2f)" % [gap, dz])
	t.eq(ops(log, &"blind").size(), 1, "blinded once")
	var holds := ops(log, &"hold")
	t.check(holds.size() == 1 and is_equal_approx(float(holds[0][3][1]), Steam.FLINCH_HOLD), "held once for steam.flinch_hold")
	# The hold comes after the push, so it holds them where the push left them.
	var order: Array = []
	for e: Array in log:
		order.append(e[2])
	t.check(order.find(&"push") >= 0 and order.find(&"push") < order.find(&"hold"), "held after the push (%s)" % str(order))
	var noise := ops(log, &"noise")
	t.check(noise.size() == 1 and str(noise[0][3][2]) == "p1" and is_equal_approx(float(noise[0][3][1]), Steam.CRY), "a cry of steam.cry blamed on them")
	t.check(ops(log, &"cue").size() == 1 and ops(log, &"cue")[0][3][0] == &"steam_cry", "the cry's cue at them")
	# From the south: pushed south.
	var w2 := who("p2", x, band.end.y + 0.1, &"sprint")
	var log2 := hit_once(f, hall.duplicate(true), [w2], {"p2": band.end.y + 0.45})
	var push2 := ops(log2, &"push")
	t.check(push2.size() == 1 and float(push2[0][3][2]) > 0.0, "a walker from the south is pushed back south")
	# A creeper passes under the hall's sheet.
	t.eq(hit_once(f, hall.duplicate(true), [who("p3", x, band.get_center().y, &"creep")], {"p3": band.position.y - 0.2}).size(), 0, "a creeper under the hall's sheet is untouched")
	# By the base's input gait (Who.gait, also while standing still): crouched in place passes; stood up in place, the
	# tick after creeping in, is scalded.
	var crouched := who("g1", x, mid, &"still")
	crouched.gait = &"creep"
	t.eq(hit_once(f, hall.duplicate(true), [crouched], {"g1": mid}).size(), 0, "crouched in place (gait creep, still) passes under")
	var sm := sim_of(f)
	var stood_rec := hall.duplicate(true)
	sm.recs = [stood_rec]
	stood_rec["state"] = Steam.JET
	stood_rec["since"] = 0.0
	stood_rec["k"]["started"] = true
	sm.t = Steam.GRACE + 0.1
	sm.tick([who("g2", x, mid, &"creep")], [])
	t.eq(sm.log.size(), 0, "crept in under the sheet: untouched")
	var stood := who("g2", x, mid, &"still")
	stood.gait = &"walk"
	sm.tick([stood], [])
	t.eq(ops(sm.log, &"push").size(), 1, "stood up in place after creeping (gait walk, still) is scalded")
	# The crawl's band: a creeper is hit (nobody passes under).
	var cb := Steam.hazard_of(crawl)
	var log3 := hit_once(f, crawl.duplicate(true), [who("p5", cb.get_center().x, cb.position.y + 0.15, &"creep")], {"p5": cb.position.y - 0.4})
	t.eq(ops(log3, &"push").size(), 1, "a creeper into the crawl's live band flinches")
	# Once per jet: a second tick inside does nothing more.
	var once := hall.duplicate(true)
	var sm2 := sim_of(f)
	sm2.recs = [once]
	once["state"] = Steam.JET
	once["since"] = 0.0
	once["k"]["started"] = true
	sm2.t = Steam.GRACE + 0.1
	var stay := who("p6", x, band.get_center().y, &"walk")
	sm2.tick([stay], [])
	sm2.tick([stay], [])
	t.eq(ops(sm2.log, &"push").size(), 1, "one flinch per player per jet")
	# Not before the grace, not in the build, not down, not in the car.
	var early := hall.duplicate(true)
	var sm3 := sim_of(f)
	sm3.recs = [early]
	early["state"] = Steam.JET
	early["since"] = 0.0
	early["k"]["started"] = true
	sm3.t = 0.1
	sm3.tick([who("p7", x, band.get_center().y, &"walk")], [])
	t.eq(sm3.log.size(), 0, "no flinch inside the grace")
	var down := who("p8", x, band.get_center().y, &"walk")
	down.up = false
	down.down = true
	t.eq(hit_once(f, hall.duplicate(true), [down], {}).size(), 0, "a downed player is never pushed")

func test_steam_push_lands_clear(t: T) -> void:
	var b := both("steam-push")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var f: Dictionary = b[0]
	var plan: Floor.FloorPlan = f["plan"]
	var car := Run.car_geometry(plan)
	var rng := Rng.make_rng("steam-push-entries")
	var bands: Array[Rect2] = []
	for rec: Dictionary in f["recs"]:
		bands.append(Steam.hazard_of(rec))
	var tried := 0
	for i in 200:
		var rec: Dictionary = (b[1] if i % 2 == 0 else b[2]).duplicate(true)
		var band := _rows(rec)
		var x := band.position.x + 0.35 + rng.next() * (band.size.x - 0.7)
		var z := band.position.y + rng.next() * band.size.y
		var start := Move.move_with_collision(plan, Move.Body.make(x, z, 0, 0.0), 0.0, 0.0, Steam.RADIUS)
		var prev := {}
		if rng.next() < 0.6:
			prev["r"] = band.position.y - 0.4 if rng.next() < 0.5 else band.end.y + 0.4
		var w := who("r", start.x, start.z, &"walk" if rng.next() < 0.5 else &"still")
		var log := hit_once(f, rec, [w], prev)
		var push := ops(log, &"push")
		if push.is_empty():
			continue
		tried += 1
		var dz := float(push[0][3][2])
		var out := Move.move_with_collision(plan, w.body, 0.0, dz, Steam.RADIUS)
		for other in bands:
			t.check(not Steam.touches(other, out.x, out.z), "entry %d: pushed into the steam (%.2f, %.2f)" % [i, out.x, out.z])
		t.check(Move.wall_clearance(plan, 0, out.x, out.z) >= Steam.RADIUS - 0.02, "entry %d: pushed into a wall" % i)
		var c := Station.cell_of(out.x, out.z)
		if int(rec["k"]["which"]) == Steam.WHICH_HALL:
			t.check(not Station.creep_only(plan, c.x, c.y), "entry %d: a standing player pushed into the crawl" % i)
		if car != null:
			var r := car.rect
			t.check(not (out.x > r.x0 and out.x < r.x1 and out.z > r.z0 and out.z < r.z1), "entry %d: pushed into the car" % i)
	t.check(tried >= 120, "only %d of 200 entries flinched" % tried)

func test_steam_cry_from_the_crawl(t: T) -> void:
	var b := both("steam-cry")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var f: Dictionary = b[0]
	var plan: Floor.FloorPlan = f["plan"]
	var cb := _rows(b[2])
	var log := hit_once(f, (b[2] as Dictionary).duplicate(true), [who("c", cb.get_center().x, cb.get_center().y, &"creep")], {})
	var noise := ops(log, &"noise")
	if not t.eq(noise.size(), 1, "a cry from the crawl"):
		return
	var at: Move.Body = noise[0][3][0]
	var c := Station.cell_of(at.x, at.z)
	t.check(not Station.creep_only(plan, c.x, c.y) and Floor.is_walkable(plan, 0, c.x, c.y), "the crawl's cry is heard outside the crawl (%s)" % str(c))
	var by_mouth := false
	for m: Array in plan.station["crawl_mouths"]:
		by_mouth = by_mouth or (c == Vector2i(int(m[0]), int(m[1]))) or (c == Vector2i(int(m[2]), int(m[3])))
	t.check(by_mouth, "the crawl's cry is heard at a mouth")
	# From the hall: where they stand.
	var hb := _rows(b[1])
	var log2 := hit_once(f, (b[1] as Dictionary).duplicate(true), [who("h", hb.get_center().x, hb.get_center().y, &"walk")], {})
	var n2 := ops(log2, &"noise")
	t.check(n2.size() == 1 and is_equal_approx((n2[0][3][0] as Move.Body).z, hb.get_center().y), "the hall's cry is heard where they stand")

func test_steam_passive(t: T) -> void:
	var n := _seeds(t, 10, 60)
	var hits := 0
	for i in n:
		var f := place("steam-passive-%d" % i)
		if (f["recs"] as Array).is_empty():
			continue
		var plan: Floor.FloorPlan = f["plan"]
		var sm := sim_of(f)
		var hall: Rect2 = plan.station["hall"]
		# Four walkers pacing the hall up and down through the bands, the power cut at 20 s, back at 50 s.
		var zs: Array[float] = [hall.position.y + 1.0, hall.position.y + 4.0, hall.end.y - 4.0, hall.end.y - 1.0]
		var vs: Array[float] = [3.0, -3.0, 5.0, -1.2]
		while sm.t < 70.0:
			var ws: Array[Api.Who] = []
			for k in 4:
				zs[k] += vs[k] * DT
				if zs[k] < hall.position.y + 0.5 or zs[k] > hall.end.y - 0.5:
					vs[k] = -vs[k]
				ws.append(who("w%d" % k, hall.position.x + 1.0 + 2.5 * k, zs[k], &"creep" if absf(vs[k]) < 2.0 else &"walk"))
			var ev: Array[Dictionary] = []
			if absf(sm.t - 20.0) < DT * 0.5:
				ev.append({"type": "powerCut", "t": sm.t})
			if absf(sm.t - 50.0) < DT * 0.5:
				ev.append({"type": "powerRestored", "t": sm.t})
			sm.tick(ws, ev)
		for e: Array in sm.log:
			t.check(not [&"pin", &"send_out", &"stumble", &"dark", &"close_edge", &"solid"].has(e[2]), "seed %d: the steam asked %s" % [i, e[2]])
			if e[2] == &"hold":
				t.check(float(e[3][1]) <= 1.0 + 1e-6, "seed %d: a hold of %.2f s" % [i, float(e[3][1])])
			if e[2] == &"push":
				hits += 1
	t.note("%d flinches among the pacing walkers" % hits)
	t.check(hits > 0, "nobody pacing the hall ever met the steam")

func test_steam_same_seed(t: T) -> void:
	var print_a := fingerprint()
	var print_b := fingerprint()
	t.eq(print_a, print_b, "the same seeds place the same jets twice")
	if FIXED_PRINT.is_empty():
		t.note("fingerprint %s" % print_a)
	else:
		t.eq(print_a, FIXED_PRINT, "the jets differ from those another process placed")

static func fingerprint() -> String:
	var parts := PackedStringArray()
	for seed in FIXED_SEEDS:
		var f := place(seed)
		var r := run_beat(f, 40.0, 20.0, 32.0)
		for rec: Dictionary in f["recs"]:
			parts.append("%s|%s|%.3f" % [str(rec["k"]["band"]), str(rec["k"]["which"]), float(rec["k"]["offset"])])
		for sp: Dictionary in r["spans"]:
			parts.append("%d:%.2f:%.2f:%.2f" % [int(sp["id"]), float(sp["build_at"]), float(sp["jet_at"]), float(sp["end"])])
	return str("|".join(parts).hash())

# --- through the base: a whole run --------------------------------------------------------------------------------

## One line per tick: phase, every event but the dangers' own, every player, the four.
static func _line(s: Run.RunState, events: Array[Dictionary]) -> String:
	var parts: Array[String] = ["%.3f %s %d" % [s.t, s.phase, s.depth]]
	for e in events:
		var ty := str(e.get("type", ""))
		if not ty.begins_with("danger"):
			parts.append("%s@%.3f:%s" % [ty, float(e.get("t", -1.0)), str(e.get("playerId", ""))])
	for p in s.players:
		parts.append("%s %s %.4f,%.4f" % [p.id, p.status, p.body.x, p.body.z])
	if s.station != null:
		for b in (s.station as SR.StationFloor).bodies:
			parts.append("%d %.4f,%.4f %s %s" % [b.seat, b.body.x, b.body.z, b.phase, b.mode])
	return " | ".join(parts)

## A Reactor run (floor 7, the station) of `size` scripted players who walk up and down the hall through its middle,
## at a walk, for `secs`; the power holds `hold` seconds. Returns {lines, events (the dangers' and the downs'), state}.
static func pace_run(seed: String, size: int, kinds: Array, secs: float, tuning: Dictionary = {}, hold := 45.0) -> Dictionary:
	var r := PS.rules(7, true)
	r.dangers = Dangers.resolve(kinds)
	var s := r.prepare(Run.create_run(seed, PS._ids(size), r.deck, true, true, true))
	var tun := tuning.duplicate()
	tun[&"reactor.power_hold"] = hold
	s = Run.with_tuning(s, tun)
	var lines := PackedStringArray()
	var evs: Array = []
	var legs := {}
	var seen := false
	var woke := false
	for k in int(secs / DT):
		var inputs: Array[Run.PlayerInput] = []
		var st: SR.StationFloor = s.station
		for n in s.players.size():
			var p := s.players[n]
			var b := p.body
			if st != null and p.status == &"ok":
				var hall: Rect2 = st.plan.station["hall"]
				var x := hall.position.x + 3.0 + 2.0 * float(n % 3)
				var up: bool = legs.get(p.id, true)
				var goal := Move.Body.make(x, hall.position.y + 2.5 if up else hall.end.y + 3.0, 0, 0.0)
				if M.hypot2(goal.x - b.x, goal.z - b.z) < 0.8:
					legs[p.id] = not up
				b = PS._toward(s, b, goal, 3.0 * DT)
			inputs.append(Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0))
		var res := r.step(s, inputs, DT)
		s = res.state
		lines.append(_line(s, res.events))
		if s.dangers != null:
			for rec: Dictionary in (s.dangers as Dangers.DangerFloor).records:
				if rec["kind"] == &"steam":
					seen = true
					if StringName(rec["state"]) != Steam.REST:
						woke = true
		for e in res.events:
			var ty := str(e["type"])
			if ty.begins_with("danger") or ty in ["downed", "out", "caught", "powerCut", "powerRestored"]:
				evs.append(e)
	return {"lines": lines, "events": evs, "state": s, "seen": seen, "woke": woke}

func test_steam_off_or_quiet_changes_nothing(t: T) -> void:
	var secs := 30.0 if t.quick else 90.0
	var seeds: Array = ["steam-off-1"] if t.quick else ["steam-off-1", "steam-off-2", "steam-off-3"]
	# Jets that never vent (the longest rests, no purges): the run with the kind on is the run without it, tick for
	# tick, through the cut.
	var quiet := {&"danger.steam.rest_lit": 1e6, &"danger.steam.rest_dark": 1e6, &"danger.steam.purge_cut": 0.0, &"danger.steam.purge_restore": 0.0}
	for seed: String in seeds:
		var off := pace_run(seed, 2, [], secs, quiet, 15.0)
		var on := pace_run(seed, 2, ["steam"], secs, quiet, 15.0)
		var first := -1
		for k in (off["lines"] as PackedStringArray).size():
			if off["lines"][k] != on["lines"][k]:
				first = k
				break
		t.check(first < 0, "%s: a quiet steam changed the run (first difference at tick %d)" % [seed, first])
		t.check(bool(on["seen"]), "%s: no steam placed on the Reactor" % seed)
		t.check(not bool(on["woke"]), "%s: a quiet steam left its rest (a purge or a beat with both off)" % seed)
	# Not on another floor: a Clinic run with the kind on places nothing.
	var r := HostRules.new(true, 1, [], false, false, true)
	r.dangers = Dangers.resolve(["steam"])
	var s := r.prepare(Run.create_run("steam-clinic-run", ["a"] as Array[String]))
	for _k in 3:
		s = r.step(s, [Run.PlayerInput.make("a", s.players[0].body, 1.65, 0.0, 0.0, 90.0, 70.0)] as Array[Run.PlayerInput], DT).state
	var none := s.dangers == null or (s.dangers as Dangers.DangerFloor).records.is_empty()
	t.check(none, "steam placed on the Clinic")

func test_steam_never_downs_anyone(t: T) -> void:
	# The four held asleep (the power never cuts): walkers pace the hall through the steam; it never downs anyone.
	var seeds := 3 if t.quick else 20
	var flinches := 0
	for i in seeds:
		var res := pace_run("steam-down-%d" % i, 2 + i % 3, ["steam"], 60.0 if t.quick else 90.0, {}, 1e6)
		for e: Dictionary in res["events"]:
			var ty := str(e["type"])
			t.check(not (ty in ["downed", "out", "caught", "dangerPinned", "dangerOut"]), "seed %d: %s with the four asleep" % [i, ty])
			if ty == "dangerPush":
				flinches += 1
	t.note("%d flinches over %d floors" % [flinches, seeds])
	t.check(flinches > 0, "nobody walking the hall ever met the steam")

func test_steam_flinch_in_a_run(t: T) -> void:
	# Through the base: each flinch is a push, a blind, the cry's cue and its noise, together.
	var res := pace_run("steam-run-flinch", 1, ["steam"], 40.0, {}, 1e6)
	var pushes := 0
	var blinds := 0
	var cries := 0
	var noises := 0
	var holds := 0
	for e: Dictionary in res["events"]:
		match str(e["type"]):
			"dangerHold": holds += 1
			"dangerPush": pushes += 1
			"dangerBlind": blinds += 1
			"dangerCue": cries += 1 if str(e.get("cue", "")) == "steam_cry" else 0
			"dangerNoise": noises += 1
	t.check(pushes > 0 and pushes == blinds and blinds == cries and cries == noises and noises == holds, "push %d, hold %d, blind %d, cry %d, noise %d" % [pushes, holds, blinds, cries, noises])

func test_steam_cry_heard_as_a_flare(t: T) -> void:
	# The four hear a cry exactly as they hear a flare's burst of the same reach at the same place.
	var plan := Station.generate_station("steam-ear", 7)
	var st := SR.make(plan)
	st.power = SR.Power.EMERGENCY
	st.awake = 60.0
	var hall: Rect2 = plan.station["hall"]
	var crew: Array[SR.Crew] = []
	var drew := 0
	# Every metre down the hall's middle and beyond its south end: the same bodies drawn to the same place.
	var z := hall.position.y + 0.5
	while z < hall.end.y + 20.0:
		var at := Vector2(hall.get_center().x, z)
		var cry := SR._noises_drawn(st, crew, 10.0, null, [] as Array[Dictionary], [[at.x, at.y, Steam.CRY]])
		var flare := SR._noises_drawn(st, crew, 10.0, null, [{"type": "flareUsed", "t": 10.0, "x": at.x, "z": at.y, "noise": Steam.CRY}] as Array[Dictionary])
		t.eq(str(cry), str(flare), "a cry at z %.1f draws the bodies a flare of the same reach draws" % z)
		if not cry.is_empty():
			drew += 1
		z += 1.0
	t.check(drew > 0, "the cry drew nobody anywhere")

# --- the drawn steam -------------------------------------------------------------------------------------------------

func test_steam_view_in_the_station(t: T) -> void:
	# Built in a real drawn station (its anchors read, nothing of it changed) and played through a whole beat: no
	# script error, the hall's line spans the hall wall to wall, the stencils are there, no light added.
	var b := both("steam-view")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var f: Dictionary = b[0]
	var plan: Floor.FloorPlan = f["plan"]
	var root := (Engine.get_main_loop() as SceneTree).root
	var level := Level.new()
	root.add_child(level)
	level.build(PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan)
	var hall: Rect2 = plan.station["hall"]
	for rec: Dictionary in [b[1], b[2]]:
		var v: Node3D = View.new()
		level.add_child(v)
		v.position = Vector3(float(rec["x"]), 0.0, float(rec["z"]))
		var r := (rec as Dictionary).duplicate(true)
		r.erase("k")
		r["n"][Steam.N_LEN] = Steam.REST_LIT
		v.build(r, {"plan": plan, "place": &"reactor", "depth": 7, "level": level, "floor_seed": plan.seed})
		var labels := 0
		var lights := 0
		var lo := INF
		var hi := -INF
		for c in v.get_children():
			if c is Label3D:
				labels += 1
			if c is Light3D:
				lights += 1
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is CylinderMesh:
				var aabb := (c as MeshInstance3D).get_aabb()
				var xf := (c as Node3D).global_transform
				lo = minf(lo, (xf * aabb.position).x)
				lo = minf(lo, (xf * aabb.end).x)
				hi = maxf(hi, (xf * aabb.position).x)
				hi = maxf(hi, (xf * aabb.end).x)
		t.eq(lights, 0, "the steam adds no light")
		if int(rec["k"]["which"]) == Steam.WHICH_HALL:
			t.check(lo <= hall.position.x + 0.2 and hi >= hall.end.x - 0.2, "the hall's line spans the hall (%.2f..%.2f, hall %.2f..%.2f)" % [lo, hi, hall.position.x, hall.end.x])
			t.eq(labels, 2, "a stencil facing each way down the hall")
		else:
			t.eq(labels, 1, "the stencil on the crawl's hatch")
		# A whole beat by host time: rest, build, jet (purge and plain), rest again, in each power.
		var ht := 0.0
		var players := 0
		for power: int in [Steam.POWER_NORMAL, Steam.POWER_EMERGENCY, Steam.POWER_RESTORED]:
			for leg: Array in [[Steam.BUILD, Steam.BUILD_S, 0.0], [Steam.JET, Steam.PURGE, 1.0], [Steam.REST, 2.0, 0.0], [Steam.BUILD, Steam.BUILD_S, 0.0], [Steam.JET, Steam.JET_S, 0.0], [Steam.REST, 1.0, 0.0]]:
				var before := r.duplicate(true)
				r["state"] = leg[0]
				r["since"] = ht
				r["n"][Steam.N_POWER] = float(power)
				r["n"][Steam.N_PURGE] = float(leg[2])
				r["n"][Steam.N_LEN] = float(leg[1])
				v.changed(r, before, ht)
				var end := ht + float(leg[1])
				while ht < end:
					v.frame(r, ht, 0.1)
					ht += 0.1
					# Every sound it plays goes through the mix: never louder than its stream, at most BASE_DB.
					for c in v.get_children():
						if c is AudioStreamPlayer3D:
							var ap := c as AudioStreamPlayer3D
							players += 1
							t.check(ap.max_db == 0.0 and ap.volume_db <= Sfx.BASE_DB + 1e-4, "a steam sound at %.1f dB, max_db %.1f" % [ap.volume_db, ap.max_db])
		t.check(players > 0, "no steam sound played through a whole beat")
		v.event({"type": "dangerCue", "id": r["id"], "cue": "steam_cry", "x": r["x"], "y": 0.0, "z": r["z"]}, ht)
		v.event({"type": "dangerBlind", "id": r["id"], "playerId": "", "until": ht + 1.0}, ht)
	level.free()

func test_steam_drawn_over_what_scalds(t: T) -> void:
	# The steam on screen covers exactly the ground that scalds: each sheet layer at the hazard's edge (within 0.15 m),
	# the puffs out to it, the stain its full depth; a creeper's eyes (1.13 m) are under the hall's sheet.
	var b := both("steam-drawn")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var root := (Engine.get_main_loop() as SceneTree).root
	for rec: Dictionary in [b[1], b[2]]:
		var v: Node3D = View.new()
		root.add_child(v)
		var r := (rec as Dictionary).duplicate(true)
		r.erase("k")
		v.build(r, {"plan": b[0]["plan"], "place": &"reactor", "depth": 7, "level": null, "floor_seed": ""})
		var half := Steam.HAZARD_HALF
		var sheets: Array = v.get(&"sheets")
		t.eq(sheets.size(), 2, "two sheet layers")
		for mi: MeshInstance3D in sheets:
			t.check(absf(mi.position.z) >= half - 0.15 - 1e-6 and absf(mi.position.z) <= half + 1e-6, "a sheet layer %.2f m off the line (hazard %.2f)" % [mi.position.z, half])
		var stain: MeshInstance3D = v.get(&"stain")
		# The wet patch is where a player's own point is scalded: the hazard plus the body's radius either side (1.8 m),
		# dark almost to its edge (at least 0.08 darker at 0.85 m off the line, on average across it), nothing beyond.
		var depth := 2.0 * (half + Steam.RADIUS)
		t.check(stain != null and absf((stain.mesh as QuadMesh).size.y - depth) < 1e-6, "the stain is %.2f m deep (where your point is scalded: %.2f)" % [(stain.mesh as QuadMesh).size.y, depth])
		var img: Image = View.stain_image(7 if int(rec["k"]["which"]) == Steam.WHICH_HALL else 11)
		for off: float in [-0.85, 0.85]:
			var row := int(round((off / (depth * 0.5) * 0.5 + 0.5) * float(img.get_height() - 1)))
			var sum := 0.0
			for x in img.get_width():
				sum += img.get_pixel(x, row).r * View.STAIN_MOST
			var mean := sum / float(img.get_width())
			t.check(mean >= 0.08, "the stain darkens the floor by %.3f on average %.2f m off the line (at least 0.08)" % [mean, off])
		# Wet concrete, not a painted band: the outline wanders across the length (its outermost dark row moves by at
		# least 4 cm between columns), and the darkness through the middle varies along it.
		var lo_row := img.get_height()
		var hi_row := -1
		var mids: Array[float] = []
		for x in range(int(img.get_width() * 0.2), int(img.get_width() * 0.8)):
			var last := -1
			for y in range(img.get_height() / 2, img.get_height()):
				if img.get_pixel(x, y).r >= 0.2:
					last = y
			lo_row = mini(lo_row, last)
			hi_row = maxi(hi_row, last)
		# Block means (32 px along, the middle half across): wetter and drier stretches, not only the odd blotch.
		for bx in range(1, 7):
			var sum_b := 0.0
			var n_b := 0
			for x in range(bx * 32, bx * 32 + 32):
				for y in range(img.get_height() / 4, img.get_height() * 3 / 4):
					sum_b += img.get_pixel(x, y).r
					n_b += 1
			mids.append(sum_b / float(n_b))
		var wander := float(hi_row - lo_row) / float(img.get_height() - 1) * depth
		var dark_lo := mids.min() as float
		var dark_hi := mids.max() as float
		t.check(wander >= 0.04, "the stain's edge wanders %.3f m along the hall (at least 0.04)" % wander)
		t.check(dark_hi - dark_lo >= 0.12, "the stain's darkness varies %.2f along its length, block to block (at least 0.12)" % (dark_hi - dark_lo))
		# A damp patch, not a hole: drawn with the transparent things (it writes ALPHA), darkening by at most half.
		var sm := stain.material_override as ShaderMaterial
		t.check(sm.shader.code.contains("ALPHA =") and float(sm.get_shader_parameter("most")) <= 0.5 + 1e-6, "the stain darkens the floor by at most half")
		var puffs: CPUParticles3D = v.get(&"puffs")
		t.check(puffs.emission_box_extents.z >= half - 0.15 - 1e-6, "the puffs roll out to the hazard's edge (%.2f)" % puffs.emission_box_extents.z)
		if int(rec["k"]["which"]) == Steam.WHICH_HALL:
			t.check(View.SHEET_LOW > 1.13 + 0.05, "a creeper's eyes are under the hall's sheet")
			# The bright root and the seam's dense puffs stay above a standing head, so they hide no body.
			var low := float(v.call(&"lowest_high"))
			t.check(low >= View.HIGH_ONLY - 1e-6, "the root and seam reach down to %.2f m (at most %.2f)" % [low, View.HIGH_ONLY])
			t.eq((v.get(&"roots") as Array).size(), 2, "a root either side of the split")
			# The root clumps along the seam and moves by the record's host time, never the screen's own clock.
			for mi: MeshInstance3D in v.get(&"roots"):
				var rm := mi.material_override as ShaderMaterial
				t.check(float(rm.get_shader_parameter("clumps")) == 1.0 and not rm.shader.code.contains("TIME"), "the root clumps and runs on host time")
		# Every steam player never plays louder than its file however close.
		for c in v.get_children():
			if c is AudioStreamPlayer3D:
				t.eq((c as AudioStreamPlayer3D).max_db, 0.0, "max_db 0 on %s" % c.name)
		v.free()

func test_steam_sounds_sit_in_the_mix(t: T) -> void:
	# Every steam stream sits in its category's band of the game's mix (the base's measure() and in_band(): no clipped
	# sample, peak at most -1 dBFS, loudness inside the band), and plays through the base at Sfx.BASE_DB plus a trim
	# that only lowers it.
	var v: Node3D = View.new()
	v.call(&"_make_streams")
	for sound: String in View.MIX:
		var row: Array = View.MIX[sound]
		var m: Dictionary = KindView.measure(View._streams[sound])
		t.check(KindView.in_band(m, row[0]), "%s (%s): peak %.1f dBFS, loudness %.1f dBFS, %d clipped; band %s" % [sound, row[0], float(m["peak_db"]), float(m["loud_db"]), int(m["clipped"]), str(KindView.BANDS[row[0]])])
		t.check(float(row[2]) <= 0.0, "%s's trim only lowers it" % sound)
		t.note("%s: %s, loudness %.1f dBFS, peak %.1f dBFS, clipped %d, trim %.1f dB" % [sound, row[0], float(m["loud_db"]), float(m["peak_db"]), int(m["clipped"]), float(row[2])])
	v.free()

func test_steam_prefers_a_whole_row(t: T) -> void:
	# Where the floor has a hall row clear across its whole width, the hall's jet is on one (no lane to walk round).
	var n := _seeds(t, 40, 400)
	var with_full := 0
	var on_full := 0
	for i in n:
		var f := place("steam-place-%d" % i)
		var full := false
		for band in Steam.hall_bands(f["p"]):
			full = full or absf(band.size.x - (f["plan"].station["hall"] as Rect2).size.x) < 1e-6
		if not full:
			continue
		with_full += 1
		for rec: Dictionary in f["recs"]:
			if int(rec["k"]["which"]) == Steam.WHICH_HALL:
				var ok := absf(Steam.band_of(rec).size.x - (f["plan"].station["hall"] as Rect2).size.x) < 1e-6
				t.check(ok, "seed %d: a trimmed row picked where a whole one exists" % i)
				if ok:
					on_full += 1
	t.note("%d of %d floors have a whole-width row; the jet is on it on %d" % [with_full, n, on_full])

func test_steam_drawn_on_schedule(t: T) -> void:
	# A screen whose "jet" snapshot is late (here 0.3 s, a slow link) draws the steam once the build has run its length
	# by host time, not when the snapshot comes; a build not yet run draws none. And in the cut the jet's curtain is
	# reddened by the lamp, with no more opacity; a scald bursts a puff at the victim.
	var b := both("steam-sched")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var root := (Engine.get_main_loop() as SceneTree).root
	var v: Node3D = View.new()
	root.add_child(v)
	var r := (b[1] as Dictionary).duplicate(true)
	r.erase("k")
	v.build(r, {"plan": b[0]["plan"], "place": &"reactor", "depth": 7, "level": null, "floor_seed": ""})
	r["state"] = Steam.BUILD
	r["since"] = 10.0
	r["n"][Steam.N_LEN] = Steam.BUILD_S
	v.changed(r, r, 10.0)
	var sheets: Array = v.get(&"sheets")
	v.frame(r, 10.0 + Steam.BUILD_S - 0.2, 0.1)
	t.check(not (sheets[0] as Node3D).visible or float(((sheets[0] as MeshInstance3D).material_override as ShaderMaterial).get_shader_parameter("strength")) <= 0.25 + 1e-6, "only wisps before the build has run")
	v.frame(r, 10.0 + Steam.BUILD_S + 0.3, 0.1)
	var sm := (sheets[0] as MeshInstance3D).material_override as ShaderMaterial
	t.check((sheets[0] as Node3D).visible and float(sm.get_shader_parameter("strength")) >= 0.99, "the jet drawn 0.3 s after the build ran, the snapshot still saying build")
	# The cut: the curtain reddened while it runs, its opacity unchanged.
	r["state"] = Steam.JET
	r["since"] = 20.0
	r["n"][Steam.N_POWER] = float(Steam.POWER_EMERGENCY)
	r["n"][Steam.N_LEN] = Steam.JET_S
	v.changed(r, r, 20.5)
	var tint: Color = sm.get_shader_parameter("tint")
	t.check(tint.r > tint.g * 1.6 and tint.r <= 0.61, "the cut's jet curtain is reddened (%s), no brighter than 0.6" % str(tint))
	t.eq(float(sm.get_shader_parameter("most")), View.SHEET_ALPHA, "no more opacity in the cut")
	v.event({"type": "dangerCue", "id": r["id"], "cue": "steam_cry", "x": r["x"], "y": 0.0, "z": r["z"]}, 20.6)
	t.eq(int(v.get(&"bursts")), 1, "a scald bursts a puff at the victim")
	v.free()

func test_steam_thin(t: T) -> void:
	var b := both("steam-thin")
	if not t.check(not b.is_empty(), "no floor with both jets"):
		return
	var root := (Engine.get_main_loop() as SceneTree).root
	for rec: Dictionary in [b[1], b[2]]:
		var v: Node3D = View.new()
		root.add_child(v)
		v.position = Vector3(float(rec["x"]), 0.0, float(rec["z"]))
		var r := (rec as Dictionary).duplicate(true)
		r.erase("k")
		v.build(r, {"plan": b[0]["plan"], "place": &"reactor", "depth": 7, "level": null, "floor_seed": ""})
		var hidden := float(v.call(&"most_hidden"))
		t.check(hidden <= MOST_HIDDEN, "the %s steam hides %.2f of a body behind it (most %.2f)" % ["hall's" if int(rec["k"]["which"]) == 0 else "crawl's", hidden, MOST_HIDDEN])
		t.note("%s steam hides at most %.2f" % ["hall" if int(rec["k"]["which"]) == 0 else "crawl", hidden])
		# Drawn only in the jet (a few wisps late in the build), never at rest.
		r["state"] = Steam.REST
		v.changed(r, r, 0.0)
		var shown := false
		for c in v.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is QuadMesh and c.material_override is ShaderMaterial and (c as Node3D).visible and (c.material_override as ShaderMaterial).shader.code.contains("strength"):
				shown = true
		t.check(not shown, "steam drawn at rest")
		r["state"] = Steam.JET
		r["since"] = 0.0
		r["n"][Steam.N_LEN] = Steam.JET_S
		v.changed(r, r, 0.5)
		var drawn := false
		for c in v.get_children():
			if c is MeshInstance3D and (c as Node3D).visible and c.material_override is ShaderMaterial and (c.material_override as ShaderMaterial).shader.code.contains("strength"):
				drawn = true
		t.check(drawn, "no steam drawn in the jet")
		v.free()

# --- live settings ----------------------------------------------------------------------------------------------------

static func tune(id: String, v: float) -> Settings.Values:
	return Settings.make({StringName("danger.steam." + id): v})

static func first_span(f: Dictionary, tuning: Settings.Values, cut := 1e9, restore := 1e9, secs := 40.0) -> Array:
	return run_beat(f, secs, cut, restore, tuning)["spans"]

func test_setting_steam_build(t: T) -> void:
	var sp: Dictionary = first_span(place("steam-set"), tune("build", 2.5))[0]
	t.check(absf(float(sp["jet_at"]) - float(sp["build_at"]) - 2.5) < DT + 1e-6, "steam.build 2.5 gives a %.2f s build" % (float(sp["jet_at"]) - float(sp["build_at"])))

func test_setting_steam_jet(t: T) -> void:
	var sp: Dictionary = first_span(place("steam-set"), tune("jet", 3.5))[0]
	t.check(absf(float(sp["end"]) - float(sp["jet_at"]) - 3.5) < DT + 1e-6, "steam.jet 3.5 gives a %.2f s jet" % (float(sp["end"]) - float(sp["jet_at"])))

func test_setting_steam_rest_lit(t: T) -> void:
	var a: Array = first_span(place("steam-set"), null, 1e9, 1e9, 60.0)
	var b: Array = first_span(place("steam-set"), tune("rest_lit", 12.0), 1e9, 1e9, 60.0)
	t.check(b.size() < a.size(), "a longer lit rest gives fewer jets (%d, %d)" % [a.size(), b.size()])

func test_setting_steam_rest_dark(t: T) -> void:
	var a: Array = first_span(place("steam-set"), null, 1.0, 1e9, 80.0)
	var b: Array = first_span(place("steam-set"), tune("rest_dark", 25.0), 1.0, 1e9, 80.0)
	t.check(b.size() < a.size(), "a longer dark rest gives fewer jets (%d, %d)" % [a.size(), b.size()])

func test_setting_steam_purge(t: T) -> void:
	for sp: Dictionary in first_span(place("steam-set"), tune("purge", 4.0), 10.0):
		if bool(sp["purge"]):
			t.check(absf(float(sp["end"]) - float(sp["jet_at"]) - 4.0) < DT + 1e-6, "steam.purge 4 gives a %.2f s purge" % (float(sp["end"]) - float(sp["jet_at"])))
			return
	t.check(false, "no purge seen")

static func _purges(spans: Array) -> int:
	var n := 0
	for sp: Dictionary in spans:
		if bool(sp["purge"]):
			n += 1
	return n

func test_setting_steam_purge_cut(t: T) -> void:
	t.check(_purges(first_span(place("steam-set"), null, 10.0)) > 0, "a purge at the cut")
	t.eq(_purges(first_span(place("steam-set"), tune("purge_cut", 0.0), 10.0)), 0, "steam.purge_cut 0: no purge at the cut")

func test_setting_steam_purge_restore(t: T) -> void:
	t.check(_purges(first_span(place("steam-set"), tune("purge_cut", 0.0), 5.0, 15.0)) > 0, "a purge at the restore")
	t.eq(_purges(first_span(place("steam-set"), Settings.make({&"danger.steam.purge_cut": 0.0, &"danger.steam.purge_restore": 0.0}), 5.0, 15.0)), 0, "steam.purge_restore 0: no purge at the restore")

func test_setting_steam_grace(t: T) -> void:
	var b := both("steam-flinch")
	var f: Dictionary = b[0]
	var band := _rows(b[1])
	var rec: Dictionary = (b[1] as Dictionary).duplicate(true)
	var sm := sim_of(f, tune("grace", 0.45))
	sm.recs = [rec]
	rec["state"] = Steam.JET
	rec["since"] = 0.0
	rec["k"]["started"] = true
	sm.t = 0.35
	sm.tick([who("g", band.get_center().x, band.get_center().y, &"walk")], [])
	t.eq(sm.log.size(), 0, "steam.grace 0.45: no flinch 0.35 s into the jet")
	t.check(hit_once(f, (b[1] as Dictionary).duplicate(true), [who("g", band.get_center().x, band.get_center().y, &"walk")], {}).size() > 0, "a flinch past the default grace")

func test_setting_steam_cry(t: T) -> void:
	var b := both("steam-flinch")
	var f: Dictionary = b[0]
	var band := _rows(b[1])
	var rec: Dictionary = (b[1] as Dictionary).duplicate(true)
	var sm := sim_of(f, tune("cry", 16.0))
	sm.recs = [rec]
	rec["state"] = Steam.JET
	rec["since"] = 0.0
	rec["k"]["started"] = true
	sm.t = 0.4
	sm.tick([who("g", band.get_center().x, band.get_center().y, &"walk")], [])
	var n := ops(sm.log, &"noise")
	t.check(n.size() == 1 and is_equal_approx(float(n[0][3][1]), 16.0), "steam.cry 16 gives a 16 m cry")

func test_steam_hold_never_covers_a_catch(t: T) -> void:
	# The four catch by standing within REACH of their prey for WIND (sim/station_floor.gd). A flinch's hold is always
	# shorter than WIND, at the default, at the setting's most, and even if a larger number were asked: so a body
	# winding up when the hold lands has not finished when the player can move again, and still catches only if it
	# keeps them in reach by its own rule. Counted in host ticks: the hold ends at least one tick before the wind.
	var b := both("steam-flinch")
	var f: Dictionary = b[0]
	var band := Steam.hazard_of(b[1])
	var row_most := 0.0
	for row: Array in Settings.ROWS:
		if row[0] == &"danger.steam.flinch_hold":
			row_most = float(row[7])
			t.check(float(row[5]) < SR.WIND and float(row[7]) < SR.WIND, "the setting's default %.2f and most %.2f are under the four's wind %.2f" % [float(row[5]), float(row[7]), SR.WIND])
	for v: float in [Steam.FLINCH_HOLD, row_most, 1.0, 3.0]:
		var rec: Dictionary = (b[1] as Dictionary).duplicate(true)
		var sm := sim_of(f, tune("flinch_hold", v))
		sm.recs = [rec]
		rec["state"] = Steam.JET
		rec["since"] = 0.0
		rec["k"]["started"] = true
		sm.t = 0.4
		sm.tick([who("g", band.get_center().x, band.get_center().y, &"walk")], [])
		var holds := ops(sm.log, &"hold")
		if not t.eq(holds.size(), 1, "asked %.2f: one hold" % v):
			continue
		var held := float(holds[0][3][1])
		var held_ticks := ceili(held / DT - 1e-6)
		var wind_ticks := ceili(SR.WIND / DT - 1e-6)
		t.check(held < SR.WIND and held_ticks < wind_ticks, "asked %.2f: held %.2f s (%d ticks) against a wind of %.2f s (%d ticks)" % [v, held, held_ticks, SR.WIND, wind_ticks])

func test_setting_steam_flinch_hold(t: T) -> void:
	var b := both("steam-flinch")
	var f: Dictionary = b[0]
	var band := Steam.hazard_of(b[1])
	for v: float in [0.3, 0.0]:
		var rec: Dictionary = (b[1] as Dictionary).duplicate(true)
		var sm := sim_of(f, tune("flinch_hold", v))
		sm.recs = [rec]
		rec["state"] = Steam.JET
		rec["since"] = 0.0
		rec["k"]["started"] = true
		sm.t = 0.4
		sm.tick([who("g", band.get_center().x, band.get_center().y, &"walk")], [])
		var log := ops(sm.log, &"hold")
		if v > 0.0:
			t.check(log.size() == 1 and is_equal_approx(float(log[0][3][1]), v), "steam.flinch_hold %.1f holds for %.1f s" % [v, v])
		else:
			t.eq(log.size(), 0, "steam.flinch_hold 0: no hold")

func test_setting_steam_blind(t: T) -> void:
	var b := both("steam-flinch")
	var f: Dictionary = b[0]
	var band := _rows(b[1])
	var rec: Dictionary = (b[1] as Dictionary).duplicate(true)
	var sm := sim_of(f, tune("blind", 1.8))
	sm.recs = [rec]
	rec["state"] = Steam.JET
	rec["since"] = 0.0
	rec["k"]["started"] = true
	sm.t = 0.4
	sm.tick([who("g", band.get_center().x, band.get_center().y, &"walk")], [])
	var n := ops(sm.log, &"blind")
	t.check(n.size() == 1 and is_equal_approx(float(n[0][3][1]), 1.8), "steam.blind 1.8 blinds for 1.8 s")

static func _count(seed_prefix: String, tuning: Settings.Values, which: int) -> int:
	var total := 0
	for i in 10:
		for rec: Dictionary in place("%s-%d" % [seed_prefix, i], tuning)["recs"]:
			if int(rec["k"]["which"]) == which:
				total += 1
	return total

func test_setting_steam_hall(t: T) -> void:
	t.eq(_count("steam-count", tune("hall", 0.0), Steam.WHICH_HALL), 0, "steam.hall 0: no hall jets")
	t.check(_count("steam-count", tune("hall", 2.0), Steam.WHICH_HALL) > _count("steam-count", null, Steam.WHICH_HALL), "steam.hall 2: more hall jets")

func test_setting_steam_crawl(t: T) -> void:
	t.eq(_count("steam-count", tune("crawl", 0.0), Steam.WHICH_CRAWL), 0, "steam.crawl 0: no crawl jets")
	t.check(_count("steam-count", tune("crawl", 2.0), Steam.WHICH_CRAWL) > _count("steam-count", null, Steam.WHICH_CRAWL), "steam.crawl 2: more crawl jets")

# --- the flinch over the network (the base's own-screen hold: net/host.gd, net/client.gd, client/play_link.gd) -------

## The rooms' rules with the dangers on; at host time `at`, the steam's flinch on "ann" exactly as steam.gd's _scald
## asks it in one tick (push back, hold FLINCH_HOLD, blind BLIND), through the base's own executor.
class FlinchRules extends HostRules:
	var at := INF
	var dx := 0.0
	var dz := 0.0
	var fired := -1.0
	var asked: Array[Dictionary] = []

	func step(before: Run.RunState, raw: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
		var r := super.step(before, raw, dt)
		if fired < 0.0 and r.state.t >= at - 1e-9 and r.state.dangers != null:
			fired = r.state.t
			var s := r.state
			var c := Dangers.Ctx.new()
			c.s = s
			c.d = (s.dangers as DangerFx.DangerFloor).copy()
			c.d.heard = c.d.heard.duplicate()
			c.d.prompts = c.d.prompts.duplicate()
			c.players = s.players.duplicate()
			c.events = []
			c.t = s.t
			c.kind = &"steam"
			var rec := {"id": 0, "kind": &"steam"}
			Dangers._ask(c, &"push", rec, ["ann", dx, dz])
			Dangers._ask(c, &"hold", rec, ["ann", Steam.FLINCH_HOLD])
			Dangers._ask(c, &"blind", rec, ["ann", Steam.BLIND])
			s.dangers = c.d
			s.players = c.players
			asked = c.events
			r.events.append_array(c.events)
		return r

class FlinchRig:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: FlinchRules
	var links := {}
	var now := 0.0
	var host_step := 0.0
	var _last := Vector3.INF

	func _init(run_seed: String, delay: float) -> void:
		rules = FlinchRules.new(false, 1, Places.FULL, false, false, true)
		rules.dangers = [&"test_tile"]
		net = Transport.MemoryNetwork.new(run_seed, Transport.LinkConfig.make(delay))
		var roster: Array[String] = ["ann", "bob"]
		host = Host.new(net.connect_peer("host"), run_seed, roster, now, Callable(rules, "prepare"), Callable(rules, "step"), [])
		for p in host.state.players:
			host.place_player(p.id, p.body)
		for id in roster:
			var c := Client.new(net.connect_peer(id), "host", id, now, Session.INTERP_DELAY, Session.INPUT_INTERVAL)
			c.floor_deck = rules.deck
			links[id] = PlayLink.new(NetT.Seat.new(c, id), false)

	func frame(f: float, yaw: float) -> void:
		now += NetT.DT
		net.now = now
		host.update(now)
		for id: String in links:
			(links[id] as PlayLink).step(now, {"dt": NetT.DT, "f": f if id == "ann" else 0.0, "r": 0.0, "yaw": yaw, "pitch": 0.0, "use": false, "hfov": 90.0, "vfov": 70.0})
		var b: Move.Body = host._players["ann"].body
		if b != null:
			var v := Vector3(b.x, b.y, b.z)
			if not is_inf(_last.x):
				host_step = maxf(host_step, (v - _last).length())
			_last = v

	func host_body() -> Vector3:
		var b: Move.Body = host._players["ann"].body
		return Vector3(b.x, b.y, b.z)

	func screen_body() -> Vector3:
		var b: Move.Body = (links["ann"] as PlayLink).body
		return Vector3(b.x, b.y, b.z) if b != null else Vector3.INF

	func client() -> Client:
		return (links["ann"] as PlayLink).client()

## ann walks on; the flinch throws her 1.3 m back the way she came, holds her FLINCH_HOLD and blinds her, as steam.gd
## asks it. Her own screen must stand where the host holds her for the whole hold (nothing can be caught on a spot her
## screen has left), and when it ends her screen and the host are at the same place, with no jump on the host.
static func _flinch_over_the_net(t: T, delay: float) -> void:
	var tag := "flinch, %d ms each way" % roundi(delay * 1000.0)
	var rig := FlinchRig.new("dg6-net-%d" % roundi(delay * 1000.0), delay)
	for _i in ceili(1.5 / NetT.DT):
		rig.frame(0.0, 0.0)
	# A straight run of floor far from the landing with 3.5 m ahead (as test_dangers_net finds one).
	var plan := rig.host.state.plan
	var steps := Floor.distances_from(plan, plan.landing)
	var start: Move.Body = null
	var yaw := 0.0
	for i in steps.size():
		var pos := Floor.pos_from_index(plan, i)
		if start != null or pos.level != 0 or steps[i] < 3:
			continue
		var at := Move.body_at_cell(plan, pos)
		for y: float in [0.0, PI * 0.5, PI, PI * 1.5]:
			var b := at
			for _k in 40:
				b = Session.move_local(plan, "unloading", b, -sin(y) * 0.1, -cos(y) * 0.1)
			if start == null and Vector2(b.x - at.x, b.z - at.z).length() > 3.5:
				start = at
				yaw = y
	if not t.check(start != null, "%s: a straight run of floor" % tag):
		return
	rig.host.place_player("ann", start)
	rig.host.place_player("bob", Move.Body.make(start.x + 0.8, start.z, start.level, start.y))
	for _i in ceili(1.0 / NetT.DT):
		rig.frame(0.0, yaw)
	rig.host_step = 0.0
	rig._last = Vector3.INF
	# Walking forward is (-sin yaw, -cos yaw); thrown back is the other way, 1.3 m.
	rig.rules.at = rig.host.state.t + 0.6
	rig.rules.dx = sin(yaw) * 1.3
	rig.rules.dz = cos(yaw) * 1.3
	var held := Vector3.INF
	var until := INF
	var worst := 0.0
	var held_frames := 0
	var release_gap := -1.0
	var was_held := false
	var host_screen_after := 0.0
	var released_at := -1.0
	for _i in ceili((0.6 + Steam.FLINCH_HOLD + 1.5 + 4.0 * delay) / NetT.DT):
		rig.frame(1.0, yaw)
		if rig.rules.fired >= 0.0 and is_inf(until):
			for e in rig.rules.asked:
				if e["type"] == "dangerHold":
					var b: Move.Body = e["at"]
					held = Vector3(b.x, b.y, b.z)
					until = float(e["until"])
					# The push itself is a placement (one jump by design); from here on the host's body must not jump.
					rig.host_step = 0.0
					rig._last = rig.host_body()
		if is_inf(until):
			continue
		var c := rig.client()
		var block: Variant = (c.latest as Dictionary).get("dangers") if c.latest is Dictionary else null
		var hn := c.clock.host_time(rig.now)
		if DangerFx.block_holds(block, "ann", hn):
			was_held = true
			held_frames += 1
			worst = maxf(worst, (rig.screen_body() - held).length())
		elif was_held and release_gap < 0.0:
			# The first frame after the hold on her own screen: both where the hold left her (one frame of walk at most).
			release_gap = maxf((rig.screen_body() - held).length(), (rig.host_body() - held).length())
			released_at = rig.now
		elif released_at >= 0.0 and rig.now - released_at > 2.0 * delay + 0.2:
			host_screen_after = maxf(host_screen_after, (rig.host_body() - rig.screen_body()).length())
	t.check(held_frames > 0, "%s: her screen is told of the hold (%d frames)" % [tag, held_frames])
	t.check(worst <= NetT.SAME, "%s: held, her own screen stands where the host holds her (at most %.3f m off)" % [tag, worst])
	t.check(release_gap >= 0.0 and release_gap <= 0.1, "%s: when the hold ends her screen and the host are at the held spot (%.3f m)" % [tag, release_gap])
	t.check(rig.host_step <= NetT.STEP_MAX, "%s: after the push, the host's body never jumps (largest move %.2f m)" % [tag, rig.host_step])
	t.check(host_screen_after <= 3.0 * (2.0 * delay + 0.15), "%s: walking on, the host keeps with her screen (at most %.2f m behind)" % [tag, host_screen_after])
	t.eq(rig.host.stats.clamped_inputs, 0, "%s: the host never refuses a step" % tag)

func test_steam_flinch_same_on_her_screen_and_the_host(t: T) -> void:
	# One of the four catches by the host's body (sim/station_floor.gd: within REACH for WIND). While she is held her
	# own screen stands exactly where the host holds her, and after it both walk on together, so a body closing on her
	# closes on the spot her screen shows; and the hold is always fewer ticks than the wind
	# (test_steam_hold_never_covers_a_catch), so no catch completes inside the hold alone.
	var original := Session.deck
	Session.deck = Places.FULL
	for delay: float in [0.0, 0.2]:
		_flinch_over_the_net(t, delay)
	Session.deck = original
