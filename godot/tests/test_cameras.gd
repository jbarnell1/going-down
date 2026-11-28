# CAM1 (North Star F3: "A downed player watches the building's security cameras. Only some rooms have one, the feeds
# cycle, and the picture is too grainy to read a sign or a face." "They can hear the living near whichever camera they
# are watching."; B7: "every camera feed locks onto them"; never bend: "A downed player has something to do within
# seconds", "Everything about a floor comes from one seed, identical for every player"). sim/cameras.gd, client/cam_feed.gd.
#   1. The same seed gives the same cameras twice in one process, and in fresh processes (tests/cameras_digest.gd).
#   2. Every floor of every place, on many seeds, has at least two cameras, the first at the lift landing; the Ward too.
#   3. No lens sits in a wall, a hide or a piece of furniture, nor off the floor (checked here, not with the placer's own
#      test), and none hangs low.
#   4. Placing them changes nothing recorded: the plan, its hides and its furniture are as they were, and no file of the
#      rules (sim/, net/, server/) reads sim/cameras.gd.
#   5. The captions are plain: CAM n, the floor, a place name; never a resident's name.
#   6. Out, the first feed is up within two seconds (at once: the camera that sees where you fell), with nobody left too.
#   7. The feeds cycle by themselves to a camera with someone living in it; the keys step next and back, on to the
#      crewmates' eyes, which stay until a key.
#   8. LS1: with one living player left, the feeds lock on the cameras that show them, else on their eyes.
#   9. The bodies: one per camera, each with its lamp; the one watched through is hidden.
extends RefCounted

const T = preload("res://tests/t.gd")
const Places = preload("res://sim/places.gd")
const Floor = preload("res://sim/floor.gd")
const Walls = preload("res://sim/walls.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Cameras = preload("res://sim/cameras.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Digest = preload("res://tests/cameras_digest.gd")
const CamFeed = preload("res://client/cam_feed.gd")
const CrewWatch = preload("res://client/crew_watch.gd")
const Main = preload("res://client/main.gd")
const DownView = preload("res://client/down_view.gd")

## Every floor of the first cycle: the Clinic twice, the Annex, the Playroom, the Arboretum, a drawn floor, the Reactor.
const DEPTHS: Array[int] = [1, 2, 3, 4, 5, 6, 7]
const RESIDENTS: Array[String] = ["ORDERLY", "TEMP", "MINDER", "GROUNDSKEEPER", "RIGGER", "KEEPER "]

static func _seeds(t: T) -> int:
	return 160 if t.full else (6 if t.quick else 50)

static func _deck() -> Array[StringName]:
	return Digest.deck()

static func _ward_options() -> Array:
	var v2 := Layout.options(null)
	var homes := Layout.options(null)
	homes["homes"] = 1
	return [{}, v2, homes]

# --- 1. one seed, one set of cameras ---------------------------------------------------------------------------

func test_the_same_cameras_twice_in_one_process(t: T) -> void:
	for s: String in ["cam-a", "cam-b", "late-5"]:
		for d in Digest.DEPTHS:
			t.eq(Digest.line(s, d), Digest.line(s, d), "%s floor %d: built twice, the same cameras" % [s, d])
			# And on one plan object twice (its caches filled by the first).
			var plan := Places.generate(s, d, _deck())
			t.eq(Digest.digest(Cameras.for_plan(plan)), Digest.digest(Cameras.for_plan(plan)), "%s floor %d: the same plan asked twice" % [s, d])
	for w: int in [183025965, 26, 8143]:
		t.eq(Digest.ward_line(w), Digest.ward_line(w), "Ward %d: built twice, the same cameras" % w)

func test_the_same_cameras_in_a_fresh_process(t: T) -> void:
	var seeds: Array[String] = ["cam-a", "cam-b"]
	var mine := {}
	for s in seeds:
		for d in Digest.DEPTHS:
			mine["%s %d" % [s, d]] = Digest.line(s, d)
	var args: Array[String] = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/cameras_digest.gd", "--"]
	args.append_array(seeds)
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	if not t.check(code == 0, "a fresh process ran the digest (exit %d)" % code):
		return
	var lines := {}
	for chunk: String in out:
		for l: String in chunk.split("\n"):
			if l.begins_with("CAMS "):
				var w := l.strip_edges().split(" ")
				lines["%s %s" % [w[1], w[2]]] = l.strip_edges()
	for k: String in mine:
		t.eq(lines.get(k, "missing"), mine[k], "%s: a fresh process hangs the same cameras" % k)
	var wargs := args.duplicate()
	wargs.resize(wargs.size() - seeds.size())
	wargs.append_array(["--ward", "183025965", "26"])
	out = []
	code = OS.execute(OS.get_executable_path(), wargs, out, true)
	t.check(code == 0, "a fresh process ran the Ward digest (exit %d)" % code)
	var wl := {}
	for chunk: String in out:
		for l: String in chunk.split("\n"):
			if l.begins_with("WARDCAMS "):
				wl[l.split(" ")[1]] = l.strip_edges()
	for w: int in [183025965, 26]:
		t.eq(wl.get(str(w), "missing"), Digest.ward_line(w), "Ward %d: a fresh process hangs the same cameras" % w)

# --- 2. every floor ---------------------------------------------------------------------------------------------

func test_every_floor_has_two_cameras_one_at_the_landing(t: T) -> void:
	var n := _seeds(t)
	var floors := 0
	var counts := {}
	for i in n:
		for d in DEPTHS:
			var plan := Places.generate("cams-%d" % i, d, _deck())
			var list := Cameras.for_plan(plan)
			floors += 1
			counts[plan.place] = mini(int(counts.get(plan.place, 99)), list.size())
			var where := "seed cams-%d floor %d (%s)" % [i, d, plan.place]
			if not t.check(list.size() >= 2, "%s: at least two cameras (%d)" % [where, list.size()]):
				continue
			var land: Dictionary = list[0]
			var lc := Vector3((plan.landing.x + 0.5) * plan.cell_size, plan.landing.level * Cameras.LH, (plan.landing.y + 0.5) * plan.cell_size)
			t.check(land["kind"] == &"landing" and int(land["level"]) == plan.landing.level and Vector2(land["pos"].x - lc.x, land["pos"].z - lc.z).length() <= 14.0,
				"%s: CAM 1 hangs at the lift landing (%s, %s from it)" % [where, land["kind"], Vector2(land["pos"].x - lc.x, land["pos"].z - lc.z).length()])
			var kinds := {}
			for k in list.size():
				t.eq(int(list[k]["n"]), k + 1, "%s: numbered in order" % where)
				kinds[list[k]["kind"]] = true
			t.check(kinds.has(&"room") or kinds.has(&"corridor") or kinds.has(&"garden"), "%s: some rooms have one, not only the landing" % where)
	t.note("%d floors; the fewest cameras by place: %s" % [floors, counts])
	var wards := 0
	for i in maxi(4, n / 2):
		for opt: Dictionary in _ward_options():
			var model := Ward.new(1000 + i * 7919, opt)
			var list := Cameras.for_ward(model, 1000 + i * 7919)
			wards += 1
			var where := "Ward %d (%s)" % [1000 + i * 7919, "today's" if opt.is_empty() else ("homes" if opt.has("homes") else "generated")]
			if t.check(list.size() >= 2, "%s: at least two cameras (%d)" % [where, list.size()]):
				t.check(list[0]["kind"] == &"landing" and (list[0]["pos"] as Vector3).distance_to(model.lift_door()) <= 12.0,
					"%s: CAM 1 is the lift's (%s m from its door)" % [where, (list[0]["pos"] as Vector3).distance_to(model.lift_door())])
	t.note("%d Wards" % wards)

# --- 3. never in a wall, a hide or furniture ---------------------------------------------------------------------

## The least distance from (x, z) to a solid wall segment on `level` (the walls as collision has them).
static func _wall_gap(plan: Floor.FloorPlan, level: int, x: float, z: float) -> float:
	var cx := int(floor(x / plan.cell_size))
	var cy := int(floor(z / plan.cell_size))
	var segs := Walls.segments_near(plan, level, cx, cy)
	var best := INF
	var p := Vector2(x, z)
	for i in range(0, segs.size(), 4):
		best = minf(best, Geometry2D.get_closest_point_to_segment(p, Vector2(segs[i], segs[i + 1]), Vector2(segs[i + 2], segs[i + 3])).distance_to(p))
	return best

func test_no_camera_in_a_wall_a_hide_or_furniture(t: T) -> void:
	var n := maxi(4, _seeds(t) / 2)
	var checked := 0
	for i in n:
		for d in DEPTHS:
			var plan := Places.generate("cams-%d" % i, d, _deck())
			var pieces := Furniture.pieces_for(plan, plan.seed, plan.depth, true)
			var hides := Hides.hides_for(plan, plan.seed)
			for c in Cameras.for_plan(plan):
				checked += 1
				var p: Vector3 = c["pos"]
				var lv := int(c["level"])
				var where := "seed cams-%d floor %d (%s) CAM %d at %s" % [i, d, plan.place, int(c["n"]), p]
				var k := Floor.cell_at(plan, lv, int(floor(p.x / plan.cell_size)), int(floor(p.z / plan.cell_size)))
				t.check(k == Floor.ROOM or k == Floor.CORRIDOR or k == Floor.LANDING, "%s: over the floor (%s)" % [where, k])
				var gap := _wall_gap(plan, lv, p.x, p.z)
				t.check(gap >= 0.15, "%s: clear of the walls (%.2f m)" % [where, gap])
				var up := p.y - lv * Cameras.LH
				t.check(up >= 2.2 and up <= 3.0, "%s: high on the wall, under the ceiling (%.2f m up)" % [where, up])
				var cm := Vector2i(roundi(p.x * 100.0), roundi(p.z * 100.0))
				for pc in pieces:
					if pc.level == lv and pc.foot.has_point(cm):
						t.check(false, "%s: inside a %s" % [where, pc.kind])
				for h in hides:
					if h.level == lv and Vector2(h.inside).distance_to(Vector2(cm)) < 60.0:
						t.check(false, "%s: inside a hide (%s)" % [where, h.kind])
	t.note("%d cameras checked" % checked)
	for i in 4:
		for opt: Dictionary in _ward_options():
			var model := Ward.new(2000 + i * 104729, opt)
			for c in Cameras.for_ward(model, 2000 + i * 104729):
				for h: Variant in model.houses:
					var local: Vector3 = (h.get("_transform") as Transform3D).affine_inverse() * (c["pos"] as Vector3)
					for b in Cameras._ward_boxes(h):
						t.check(not b.has_point(local), "Ward %d CAM %d: not inside a wall of house %d" % [2000 + i * 104729, int(c["n"]), model.houses.find(h)])

## The floor's furniture and hides as boxes, made here from sim/furniture.gd's footprints (not the placer's own list):
## a tall piece 2.1 m, any other 1.05 m; the Playroom's hides (no footprint) 1.2 m round their inside spot, 2.3 m high.
static func _dressing(plan: Floor.FloorPlan) -> Array:
	var out: Array = [[], []]
	for p in Furniture.pieces_for(plan, plan.seed, plan.depth, true):
		out[p.level].append(AABB(Vector3(p.foot.position.x * 0.01, p.level * 3.2, p.foot.position.y * 0.01), Vector3(p.foot.size.x * 0.01, 2.1 if p.tall else 1.05, p.foot.size.y * 0.01)))
	if plan.place == &"playroom":
		for h in Hides.hides_for(plan, plan.seed):
			out[h.level].append(AABB(Vector3(h.inside.x * 0.01 - 1.2, h.level * 3.2, h.inside.y * 0.01 - 1.2), Vector3(2.4, 2.3, 2.4)))
	return out

func test_a_figure_the_camera_shows_is_not_hidden_by_dressing(t: T) -> void:
	var n := maxi(3, _seeds(t) / 3)
	var shown := 0
	var cams := 0
	var empty := 0
	for i in n:
		for d in DEPTHS:
			var plan := Places.generate("cams-%d" % i, d, _deck())
			var boxes := _dressing(plan)
			var list := Cameras.for_plan(plan)
			for c in list:
				cams += 1
				var lens: Vector3 = c["pos"]
				var lv := int(c["level"])
				var any := false
				for y in plan.height:
					for x in plan.width:
						if not Floor.is_walkable(plan, lv, x, y) or Floor.cell_at(plan, lv, x, y) == Floor.STAIR:
							continue
						var at := Vector3((x + 0.5) * plan.cell_size, lv * 3.2, (y + 0.5) * plan.cell_size)
						if Vector2(at.x - lens.x, at.z - lens.z).length() > Cameras.FAR or not Cameras.shows(plan, c, at, lv):
							continue
						any = true
						shown += 1
						var head := at + Vector3(0, 1.55, 0)
						for b: AABB in boxes[lv]:
							if b.intersects_segment(lens, head):
								t.check(false, "seed cams-%d floor %d CAM %d: a figure at %s is called in view, but furniture hides its head from the lens" % [i, d, int(c["n"]), at])
								break
						# Nor behind another camera's housing (about 0.35 m round its lens, out in front of it).
						for o in list:
							if o == c or int(o["level"]) != lv:
								continue
							var front: Vector3 = (o["pos"] as Vector3) + Cameras._dir(float(o["yaw"]), float(o["pitch"])) * 0.3
							if Geometry3D.segment_intersects_sphere(lens, head, front, 0.35).size() > 0:
								t.check(false, "seed cams-%d floor %d CAM %d: a figure at %s is behind CAM %d's housing" % [i, d, int(c["n"]), at, int(o["n"])])
				if not any and c["kind"] == &"room":
					empty += 1
	t.check(shown > cams * 4, "the cameras show plenty of floor (%d spots over %d cameras)" % [shown, cams])
	t.note("%d cameras, %d spots shown, %d room cameras showing no spot" % [cams, shown, empty])

# --- 4. nothing recorded changes ------------------------------------------------------------------------------------

static func _plan_text(plan: Floor.FloorPlan) -> String:
	var parts: PackedStringArray = [str(plan.cells), str(plan.landing.x), str(plan.landing.y), str(plan.entity_start.x), str(plan.entity_start.y)]
	for r in plan.rooms:
		parts.append("%d %s %d %d %d %d %s" % [r.id, r.kind, r.x, r.y, r.w, r.h, r.branch])
	for h in Hides.hides_for(plan, plan.seed):
		parts.append("%d %s %s %s" % [h.id, h.kind, h.inside, h.front])
	for p in Furniture.pieces_for(plan, plan.seed, plan.depth, true):
		parts.append("%d %s %d %d %s %s" % [p.id, p.kind, p.x, p.y, p.facing, p.searchable])
	return "|".join(parts).sha256_text()

func test_placing_cameras_changes_nothing_recorded(t: T) -> void:
	for d in DEPTHS:
		var fresh := Places.generate("cams-same", d, _deck())
		var before := _plan_text(fresh)
		var plan := Places.generate("cams-same", d, _deck())
		Cameras.for_plan(plan)
		t.eq(_plan_text(plan), before, "floor %d (%s): the plan, its hides and its furniture are as they were" % [d, plan.place])
		t.eq(_plan_text(Places.generate("cams-same", d, _deck())), before, "floor %d: the next plan made is the same too" % d)
	# The rules never read the cameras: no file of sim/, net/ or server/ but the placer names it.
	var readers: Array[String] = []
	for dir: String in ["res://sim", "res://net", "res://server"]:
		for f in _scripts(dir):
			if f.ends_with("/cameras.gd"):
				continue
			if FileAccess.get_file_as_string(f).contains("sim/cameras.gd"):
				readers.append(f)
	t.eq(readers, [] as Array[String], "no rule reads the cameras")

static func _scripts(dir: String) -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for sub in da.get_directories():
		out.append_array(_scripts(dir + "/" + sub))
	return out

# --- 5. plain captions -----------------------------------------------------------------------------------------------

func test_the_captions_are_plain(t: T) -> void:
	var re := RegEx.create_from_string("^CAM [0-9]+  FLOOR [0-9]+  [A-Z' ]+$")
	for i in 6:
		for d in DEPTHS:
			for c in Cameras.for_plan(Places.generate("cams-%d" % i, d, _deck())):
				var line := Cameras.caption(c, d)
				t.check(re.search(line) != null, "a plain caption: %s" % line)
				for name in RESIDENTS:
					t.check(not line.contains(name), "no resident named: %s" % line)
	for c in Cameras.for_ward(Ward.new(26), 26):
		var line := Cameras.caption(c, 6)
		t.check(re.search(line) != null, "a plain Ward caption: %s" % line)
		for name in RESIDENTS:
			t.check(not line.contains(name), "no resident named on the Ward: %s" % line)

# --- the feeds --------------------------------------------------------------------------------------------------------

static func _row(id: String, index: int, status: String, at: Vector3, level := 0) -> Dictionary:
	return {"id": id, "index": index, "status": status, "x": at.x, "y": at.y, "z": at.z, "level": level, "yaw": 0.0, "pitch": 0.0,
		"gait": "walk", "active": true}

static func _snap(status: String, me_at: Vector3, others: Array) -> Dictionary:
	return {"me": {"status": status, "x": me_at.x, "y": me_at.y, "z": me_at.z, "level": 0}, "others": others, "phase": "away", "depth": 1}

## A Clinic floor, its cameras in a feed, and how to ask whether one shows a point.
class Rig:
	var plan: Floor.FloorPlan
	var feed := CamFeed.new()
	var shows: Callable
	func _init(seed: String) -> void:
		plan = Places.generate(seed, 1, Digest.deck())
		feed.use_plan(null, Cameras.for_plan(plan), 1)
		shows = func(c: Dictionary, at: Vector3, lv: int) -> bool: return Cameras.shows(plan, c, at, lv)
	## Feet on camera `i`'s floor that it shows: along its look, the first of 3 to 7 m out it shows (its aim's feet if none).
	func seen_by(i: int) -> Vector3:
		var c: Dictionary = feed.cams[i]
		var p: Vector3 = c["pos"]
		var a: Vector3 = c["aim"]
		var way := Vector3(a.x - p.x, 0, a.z - p.z).normalized()
		var lv := int(c["level"])
		for d: float in [4.0, 3.0, 5.0, 6.0, 7.0, 2.5]:
			var at := Vector3(p.x + way.x * d, lv * Cameras.LH, p.z + way.z * d)
			if Cameras.shows(plan, c, at, lv):
				return at
		return Vector3(a.x, lv * Cameras.LH, a.z)
	## The last camera on level 0 that shows its own seen_by spot.
	func good() -> int:
		for i in range(feed.cams.size() - 1, -1, -1):
			if int(feed.cams[i]["level"]) == 0 and Cameras.shows(plan, feed.cams[i], seen_by(i), 0):
				return i
		return -1
	## A floor cell's middle no camera shows, on level 0.
	func unseen() -> Vector3:
		for y in plan.height:
			for x in plan.width:
				if not Floor.is_walkable(plan, 0, x, y) or Floor.cell_at(plan, 0, x, y) == Floor.STAIR:
					continue
				var at := Vector3((x + 0.5) * plan.cell_size, 0.0, (y + 0.5) * plan.cell_size)
				var any := false
				for c in feed.cams:
					if Cameras.shows(plan, c, at, 0):
						any = true
						break
				if not any:
					return at
		return Vector3(-1, -1, -1)

func test_the_first_feed_is_up_within_two_seconds_of_going_out(t: T) -> void:
	var rig := Rig.new("cams-feed")
	var feed := rig.feed
	var w := CrewWatch.new()
	var fell := rig.seen_by(2)
	var crew := [_row("a", 1, "ok", rig.seen_by(1))]
	var out_ms := 5000
	var up_ms := -1
	for now in range(0, 9000, 50):
		var s := _snap("down" if now < out_ms else "out", fell, crew)
		var allowed := Main.watch_allowed(s, false, false, true)
		var out_now := allowed and not w.deferred and not w.asked and CrewWatch.is_out(s)
		feed.update(out_now, s, "me", "", now, rig.shows)
		w.update(s, "me", {"a": "Ann"}, allowed, DownView.OUT_LINES)
		if feed.on_cam:
			w.show_camera(feed.eye, feed.yaw, feed.pitch, feed.caption, int(feed.cams[feed.index]["n"]), DownView.OUT_LINES)
		if now < out_ms:
			t.check(not feed.on_cam and not feed.active(), "down at %d ms: no feed yet (the down view)" % now)
		elif up_ms < 0 and w.watching and w.cam >= 0:
			up_ms = now
	t.check(up_ms >= 0 and up_ms - out_ms <= 2000, "out at %d ms: the first camera feed up at %d ms (%d ms later)" % [out_ms, up_ms, up_ms - out_ms])
	t.note("first feed %d ms after going out" % (up_ms - out_ms))
	# It starts on a camera that shows where you fell.
	var first := CamFeed.new()
	first.use_plan(null, feed.cams, 1)
	first.update(true, _snap("out", fell, crew), "me", "", 0, rig.shows)
	t.check(first.on_cam and rig.shows.call(first.cams[first.index], fell, 0), "the first feed shows where you fell (CAM %d)" % (first.index + 1))
	t.check(first.caption.begins_with(Cameras.caption(first.cams[first.index], 1)), "its caption names the camera: %s" % first.caption)
	t.eq(w.note, "OUT   YOU REJOIN WHEN THE CAR NEXT MOVES", "the out screen's words stay above the caption")
	# Nobody left on their feet: the cameras still show the floor (the crewmate's eyes had nothing).
	var alone := CamFeed.new()
	alone.use_plan(null, feed.cams, 1)
	alone.update(true, _snap("out", fell, []), "me", "", 0, rig.shows)
	t.check(alone.on_cam, "with nobody left to watch, a camera feed all the same")
	# Back on your feet (the car moved): no feed.
	alone.update(false, _snap("ok", fell, []), "me", "", 100, rig.shows)
	t.check(not alone.on_cam and not alone.active(), "back in it: the feeds are gone")

func test_the_feeds_cycle_and_step(t: T) -> void:
	var rig := Rig.new("cams-feed")
	var feed := rig.feed
	var n := feed.cams.size()
	t.check(n >= 4, "a Clinic with a few cameras (%d)" % n)
	# Ann stands where a camera looks; the feed starts where you fell (by the landing).
	t.check(rig.good() > 0, "a camera that shows its own floor")
	var ann_at := rig.seen_by(rig.good())
	var crew := [_row("a", 1, "ok", ann_at), _row("b", 2, "ok", ann_at + Vector3(0.6, 0, 0))]
	var me_at := rig.seen_by(0)
	var s := _snap("out", me_at, crew)
	feed.update(true, s, "me", "", 0, rig.shows)
	var start := feed.index
	feed.update(true, s, "me", "", CamFeed.CYCLE_MS - 50, rig.shows)
	t.eq(feed.index, start, "before the cycle time: the same feed")
	feed.update(true, s, "me", "", CamFeed.CYCLE_MS + 10, rig.shows)
	t.check(feed.on_cam and rig.shows.call(feed.cams[feed.index], ann_at, 0), "after %d ms it cycles by itself, to a camera with someone living in it (CAM %d)" % [CamFeed.CYCLE_MS, feed.index + 1])
	t.eq(feed.cycles, 1, "one cycle counted")
	# Nobody in any picture: simply the next.
	var empty := CamFeed.new()
	empty.use_plan(null, feed.cams, 1)
	var far := rig.unseen()
	var s2 := _snap("out", me_at, [_row("a", 1, "ok", far)])
	empty.update(true, s2, "me", "", 0, rig.shows)
	var e0 := empty.index
	empty.update(true, s2, "me", "", CamFeed.CYCLE_MS + 1, rig.shows)
	t.eq(empty.index, (e0 + 1) % n, "with nobody in a picture it cycles to the next camera")
	# Keys: next and back; the cycle waits after a key.
	var at := feed.index
	feed.step(1)
	feed.update(true, s, "me", "", 20000, rig.shows)
	t.eq(feed.index, (at + 1) % n, "LEFT CLICK or E: the next camera")
	feed.step(-1)
	feed.update(true, s, "me", "", 20100, rig.shows)
	t.eq(feed.index, at, "Q or RIGHT CLICK: the camera before")
	feed.update(true, s, "me", "", 20100 + CamFeed.CYCLE_MS + 100, rig.shows)
	t.eq(feed.index, at, "a key holds the cycling for a while")
	feed.update(true, s, "me", "", 20100 + CamFeed.HOLD_MS + 100, rig.shows)
	t.check(feed.index != at, "then it cycles again")
	# Past the last camera: the crewmates' eyes, which stay.
	feed.jump(n - 1, 40000)
	feed.update(true, s, "me", "", 40000, rig.shows)
	feed.step(1)
	feed.update(true, s, "me", "", 40100, rig.shows)
	t.check(not feed.on_cam and feed.eyes_id == "a", "after the last camera: Ann's eyes (%s)" % feed.eyes_id)
	var w := CrewWatch.new()
	w.choose(feed.eyes_id)
	w.update(s, "me", {"a": "Ann", "b": "Bob"}, true)
	t.check(w.watching and w.watch_id == "a" and w.cam == -1 and w.caption.begins_with("WATCHING THROUGH ANN'S EYES"), "the crewmate's eyes as before: %s" % w.caption)
	feed.update(true, s, "me", "", 40100 + CamFeed.HOLD_MS + CamFeed.CYCLE_MS, rig.shows)
	t.eq(feed.eyes_id, "a", "a crewmate's eyes stay until a key")
	feed.step(1)
	feed.update(true, s, "me", "", 80000, rig.shows)
	t.eq(feed.eyes_id, "b", "the next key: Bob's eyes")
	feed.step(1)
	feed.update(true, s, "me", "", 80100, rig.shows)
	t.check(feed.on_cam and feed.index == 0, "and round to CAM 1")
	# Ann goes out while watched: back to the cameras.
	feed.step(-1)
	feed.update(true, s, "me", "", 80200, rig.shows)
	t.eq(feed.eyes_id, "b", "back: Bob's eyes")
	var gone := _snap("out", me_at, [_row("a", 1, "ok", ann_at), _row("b", 2, "out", ann_at)])
	feed.update(true, gone, "me", "", 80300, rig.shows)
	t.check(feed.on_cam, "Bob goes out while watched: back to a camera")

func test_the_feeds_lock_on_the_sole_survivor(t: T) -> void:
	var rig := Rig.new("cams-feed")
	var feed := rig.feed
	var n := feed.cams.size()
	var k := rig.good()
	t.check(k > 0, "a camera that shows its own floor")
	var bob_at := rig.seen_by(k)
	var s := _snap("out", rig.seen_by(0), [_row("a", 1, "out", rig.seen_by(1)), _row("b", 2, "ok", bob_at)])
	feed.update(true, s, "me", "b", 0, rig.shows)
	t.check(feed.on_cam and feed.locked and rig.shows.call(feed.cams[feed.index], bob_at, 0), "one up: the feed is a camera that shows Bob (CAM %d)" % (feed.index + 1))
	t.check(feed.caption.ends_with("THE LAST ONE UP"), "its caption says so: %s" % feed.caption)
	var seeing: Array[int] = []
	for i in n:
		if rig.shows.call(feed.cams[i], bob_at, 0):
			seeing.append(i)
	for i in 6:
		feed.step(1 if i % 2 == 0 else -1)
		feed.update(true, s, "me", "b", 100 + i * 100, rig.shows)
		t.check(seeing.has(feed.index), "the keys step only among the cameras that show him (CAM %d)" % (feed.index + 1))
	feed.update(true, s, "me", "b", 100 + CamFeed.CYCLE_MS + CamFeed.HOLD_MS, rig.shows)
	t.check(seeing.has(feed.index), "and it never cycles off him")
	# He walks where no camera sees: his eyes.
	var dark := rig.unseen()
	t.check(dark.x >= 0.0, "a spot no camera sees on this floor")
	var s2 := _snap("out", rig.seen_by(0), [_row("a", 1, "out", rig.seen_by(1)), _row("b", 2, "ok", dark)])
	feed.update(true, s2, "me", "b", 30000, rig.shows)
	t.check(not feed.on_cam and feed.eyes_id == "b" and feed.locked, "out of every camera's sight: through Bob's eyes")
	var w := CrewWatch.new()
	w.choose(feed.eyes_id)
	w.update(s2, "me", {"b": "Bob"}, true, [], false, [], "b")
	t.check(w.watching and w.watch_id == "b" and w.locked, "the crewmate's-eyes view, locked as LS1 had it")
	# Back in view: the cameras again.
	feed.update(true, s, "me", "b", 30100, rig.shows)
	t.check(feed.on_cam and seeing.has(feed.index), "back in a camera's sight: that camera")
	# The spotlight over: the feeds as before.
	feed.update(true, s, "me", "", 30200, rig.shows)
	t.check(not feed.locked, "no last one up: not locked")

# --- 9. the bodies ------------------------------------------------------------------------------------------------------

func test_a_body_at_every_camera_and_the_watched_one_hidden(t: T) -> void:
	var rig := Rig.new("cams-feed")
	var parent := Node3D.new()
	var feed := CamFeed.new()
	feed.use_plan(parent, rig.feed.cams, 1)
	var root := parent.get_node_or_null("SecurityCameras")
	if not t.check(root != null, "the cameras' node is under the level"):
		parent.free()
		return
	t.eq(root.get_child_count(), rig.feed.cams.size(), "one body per camera")
	for i in root.get_child_count():
		var head := root.get_child(i).get_node_or_null("Head") as Node3D
		t.check(head != null and head.get_node_or_null("Lamp") != null, "camera %d has its housing and its lamp" % (i + 1))
		if head != null:
			t.check(head.position.is_equal_approx(rig.feed.cams[i]["pos"]), "camera %d's body hangs at its lens" % (i + 1))
	var s := _snap("out", rig.seen_by(0), [])
	feed.update(true, s, "me", "", 0, rig.shows)
	for i in root.get_child_count():
		t.eq((root.get_child(i) as Node3D).visible, i != feed.index, "camera %d: %s" % [i + 1, "hidden while watched through" if i == feed.index else "shown"])
	feed.update(false, _snap("ok", Vector3.ZERO, []), "me", "", 100, rig.shows)
	for i in root.get_child_count():
		t.check((root.get_child(i) as Node3D).visible, "back in it: camera %d shown" % (i + 1))
	parent.free()
