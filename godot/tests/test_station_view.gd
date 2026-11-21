# RN2: the Reactor's generating station drawn by the main game (client/station_view.gd, station_crew_view.gd,
# station_faces.gd; docs/floors/native-late-floors.md "On screen"). The plan is sim/station.gd's; the reactor
# block is hand-made in the shapes sim/station.gd's header lists. Headless: no window.
extends RefCounted

const T = preload("res://tests/t.gd")
const Station = preload("res://sim/station.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const View = preload("res://client/station_view.gd")
const Crew = preload("res://client/station_crew_view.gd")
const Faces = preload("res://client/station_faces.gd")
const Main = preload("res://client/main.gd")
const Floor = preload("res://sim/floor.gd")

static func _level(plan: RefCounted) -> Level:
	var level := Level.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(level)
	var fp: Floor.FloorPlan = plan
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _view(level: Level) -> Node3D:
	return level.get_meta(&"station") if level.has_meta(&"station") else null

static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)

func _block(power: int, crew: Array, me_at: Vector3, holder: Variant = 0, cassette := false) -> Dictionary:
	return {"native": true, "power": power, "time": 3.0, "holder": holder, "fuseUses": 0, "cassette": cassette, "lift": false,
		"players": {"p1": [me_at.x, me_at.y, me_at.z]}, "crew": crew, "status": {"p1": "up"}, "cassetteHolder": "",
		"extracted": false, "fuseAt": [4.0, 0.07, 10.0], "tapeAt": [20.0, 0.9, 30.0], "seats": [1, 2, 3, 4]}

func test_the_station_builds_for_many_seeds_and_puts_each_anchor_where_it_says(t: T) -> void:
	for i in 8:
		var fp := Station.generate_station("rn2-%d" % i, 7)
		var level := _level(fp)
		var view := _view(level)
		if not t.check(view != null, "seed %d: the station view dressed the level" % i):
			level.free()
			continue
		var a: Dictionary = fp.station
		var placed: Array = view.get("placed")
		var want := {"rotor": [a["rotor"]], "cabinet": [a["cabinet"]], "plinth": [a["plinth"]], "sill": [a["sill"]],
			"locker": a["lockers"], "time_card": a["time_cards"], "growth": a["growths"], "lamp": a["lamps"]}
		for kind: String in want:
			var list: Array = want[kind]
			var got: Array = placed.filter(func(p: Dictionary) -> bool: return str(p["kind"]) == kind)
			t.eq(got.size(), list.size(), "seed %d: one %s drawn per anchor" % [i, kind])
			for k in mini(got.size(), list.size()):
				var d := _flat(got[k]["at"]).distance_to(_flat(View.v3(list[k])))
				# AR1: a growth roots on the pipe run of its kind on the anchor's wall, slid along it clear of doorways
				# and lamps (client/station_dress.gd), so it is drawn near its anchor rather than on it; the rest exactly.
				var reach := 2.5 if kind == "growth" else 0.01
				t.check(d < reach, "seed %d: %s %d drawn at its anchor (%.2f m off)" % [i, kind, k, d])
		var check: Dictionary = view.call(&"check")
		t.check(int(check["drawn"].get("glass", 0)) == (a["glass"] as Array).size(), "seed %d: every wired-glass edge is glass (%s)" % [i, check["drawn"]])
		t.check(int(check["drawn"].get("crawl", 0)) == (a["crawl"] as Array).size(), "seed %d: cable trays over every crawl cell" % i)
		t.check(int(check["lights"]["battens"]) > 10, "seed %d: the mains light the floor (%d battens)" % [i, check["lights"]["battens"]])
		level.free()

func test_the_lights_follow_the_power(t: T) -> void:
	var level := _level(Station.generate_station("rn2-lights", 7))
	var view := _view(level)
	var em := 0
	for d: Dictionary in view.get("lamps"):
		em += int(bool(d["emergency"]))
	t.check(em > 0, "some lamps are on the emergency circuit")
	for step: Array in [[0, "the mains"], [1, "the cut"], [2, "restored"]]:
		view.call(&"set_power", int(step[0]))
		view.call(&"_apply")
		var l: Dictionary = view.call(&"lights")
		if int(step[0]) == 1:
			t.eq(int(l["battensOn"]), 0, "%s: every batten is out" % step[1])
			t.eq(int(l["lampsOn"]), em, "%s: only the emergency lamps stay" % step[1])
			t.check(float(l["near"]) > 0.5, "%s: the player's near light comes up" % step[1])
			t.check((l["ambient"] as Color).v < 0.15, "%s: the room goes dark" % step[1])
		else:
			t.eq(int(l["battensOn"]), int(l["battens"]), "%s: every batten is on" % step[1])
			t.eq(int(l["lampsOn"]), int(l["lamps"]), "%s: every amber lamp is on" % step[1])
			t.check(float(l["near"]) < 0.01, "%s: no near light needed" % step[1])
	level.free()

func test_the_four_show_the_block_with_their_seats_and_faces(t: T) -> void:
	var fp := Station.generate_station("rn2-crew", 7)
	var level := _level(fp)
	var view := _view(level)
	var crew: Node3D = view.get("crew")
	t.eq((crew.get("figures") as Array).size(), 4, "four figures")
	var faces := {}
	for i in 4:
		var d: Dictionary = crew.call(&"describe", i)
		t.eq(str(d["state"]), "lying", "seat %d lies still under power" % (i + 1))
		t.check(_flat(d["at"]).distance_to(_flat(View.v3(fp.station["bodies"][i]))) < 0.01, "seat %d lies where the plan put it" % (i + 1))
		t.eq(str(d["numberHash"]), CrewView.texture_hash(CrewView.number_texture(int(fp.station["bodies"][i]["seat"]))), "seat %d's number on its patch" % (i + 1))
		t.eq(str(d["faceHash"]), CrewView.texture_hash(Faces.damaged(i + 1)), "seat %d wears its own face" % (i + 1))
		t.check(float(d["glow"]) >= 0.9, "seat %d's screen is lit pale" % (i + 1))
		faces[str(d["faceHash"])] = true
	t.eq(faces.size(), 4, "four different faces")
	# The cut: the scrape first, then the block's states.
	crew.call(&"set_power", 1)
	crew.set(&"_cue_at", crew.get(&"_cue_at") - 1.0)
	var poses := [[10, 0, 10, 0.3, 0, "still", 0.0], [11, 0, 10, 0.3, 0, "zombie_crawl", 1.0], [12, 0, 10, 0.3, 0, "zombie_run", 0.2], [13, 0, 10, 0.3, 0, "stand", 0.4]]
	crew.call(&"show_blocks", null, {"crew": poses}, 1.0)
	var want := ["lying", "crawling", "pursuing", "standing"]
	for i in 4:
		var d: Dictionary = crew.call(&"describe", i)
		t.eq(str(d["state"]), want[i], "seat %d shows the block's state" % (i + 1))
		t.check(_flat(d["at"]).distance_to(Vector2(10 + i, 10)) < 0.01, "seat %d stands where the block says" % (i + 1))
		t.eq(str(d["clip"]), str(crew.call(&"clip_for", want[i])), "seat %d plays the clip for its state" % (i + 1))
	level.free()

func test_the_four_are_heard_before_they_move_and_are_smoothed_like_the_others(t: T) -> void:
	var level := _level(Station.generate_station("rn2-heard", 7))
	var crew: Node3D = _view(level).get("crew")
	var moving := [[10, 0, 10, 0, 0, "zombie_crawl", 0.5], [11, 0, 10, 0, 0, "still", 0], [12, 0, 10, 0, 0, "still", 0], [13, 0, 10, 0, 0, "still", 0]]
	crew.call(&"show_blocks", null, {"crew": moving}, 1.0)
	t.eq(str(crew.call(&"describe", 0)["state"]), "lying", "a crawl before its sound has been heard is drawn still")
	t.check(float(crew.get(&"_cue_at")) >= 0.0, "the scrape started")
	crew.set(&"_cue_at", crew.get(&"_cue_at") - 1.0)
	crew.call(&"show_blocks", null, {"crew": moving}, 1.0)
	t.eq(str(crew.call(&"describe", 0)["state"]), "crawling", "after the scrape it crawls")
	var a := [[10, 0, 10, 0, 0, "zombie_run", 0.1]]
	var b := [[11, 0, 10, 0, 0, "zombie_run", 0.3]]
	crew.call(&"show_blocks", {"crew": a}, {"crew": b}, 0.5)
	var at: Vector3 = crew.call(&"describe", 0)["at"]
	t.check(absf(at.x - 10.5) < 0.01, "drawn between the two snapshots at the render time (x %.2f)" % at.x)
	level.free()

func test_prompts_only_in_reach_and_only_when_the_rules_would_take_it(t: T) -> void:
	var socket := Vector3(30.0, 1.05, 34.0)
	var near_fuse := Vector3(4.5, 0, 10.0)
	t.eq(View.prompt_for(_block(1, [], near_fuse), "p1", socket), View.FUSE_PROMPT, "the cut, the fuse in reach: take it")
	t.eq(View.prompt_for(_block(0, [], near_fuse), "p1", socket), "", "with the mains on the rules do not give the fuse")
	t.eq(View.prompt_for(_block(1, [], Vector3(7.0, 0, 10.0)), "p1", socket), "", "out of reach (3 m): nothing")
	t.eq(View.prompt_for(_block(1, [], near_fuse, "p2"), "p1", socket), "", "someone else holds it")
	t.eq(View.prompt_for(_block(1, [], socket + Vector3(0.8, -1.05, 0), "p1"), "p1", socket), View.INSTALL_PROMPT, "holding it at the socket: install")
	t.eq(View.prompt_for(_block(1, [], socket + Vector3(2.5, -1.05, 0), "p1"), "p1", socket), "", "holding it, out of the socket's reach")
	t.eq(View.prompt_for(_block(2, [], socket + Vector3(0.8, -1.05, 0), "p1"), "p1", socket), "", "restored: nothing to install")
	t.eq(View.prompt_for(_block(0, [], Vector3(20.5, 0, 30.0)), "p1", socket), View.TAPE_PROMPT, "the cassette in reach")
	t.eq(View.prompt_for(_block(0, [], Vector3(20.5, 0, 30.0), 0, true), "p1", socket), "", "the cassette already taken")
	var down := _block(1, [], near_fuse)
	down["status"] = {"p1": "down"}
	t.eq(View.prompt_for(down, "p1", socket), "", "a downed player gets no prompt")

func test_the_native_station_never_swaps_scenes(t: T) -> void:
	var b := _block(0, [], Vector3.ZERO)
	var latest := {"depth": 7, "reactor": b}
	t.eq(Main.floor_handover(latest), "", "a native station block stays in the main scene")
	b.erase("native")
	t.eq(Main.floor_handover(latest), "reactor", "the old block (flag off) still hands over to the pack's scene")

func test_nothing_of_the_station_on_other_places(t: T) -> void:
	var level := _level(Clinic.generate_clinic("rn2-clinic", 1))
	t.check(not level.has_meta(&"station"), "a Clinic has no station view")
	var found := false
	for c: Node in level.get_children():
		found = found or c.name == "StationView"
	t.check(not found, "no station node on the Clinic")
	level.free()

func test_the_crawl_creeps_a_standing_player(t: T) -> void:
	var fp := Station.generate_station("rn2-crawl", 7)
	var level := _level(fp)
	var view := _view(level)
	for c: Vector2i in fp.station["crawl"]:
		var x := (c.x + 0.5) * 2.0
		var z := (c.y + 0.5) * 2.0
		t.check(bool(view.call(&"crouch_at", x, z)) == Station.creep_only(fp, c.x, c.y), "crawl cell %s creeps" % c)
	var hall: Rect2 = fp.station["hall"]
	t.check(not bool(view.call(&"crouch_at", hall.get_center().x, hall.get_center().y)), "the hall does not")
	level.free()

# IP1: the four wear the tape's four faces from the game's own files (assets/station/faces), not the fallback
# drawings, and crawl and run with the downloaded clips (assets/station/crew_zombie.glb).
func test_the_four_wear_the_tapes_faces_and_its_crawl_from_the_game(t: T) -> void:
	Faces._cache.clear()
	var level := _level(Station.generate_station("rn2-pack", 7))
	var crew: Node3D = _view(level).get("crew")
	for n in range(1, 5):
		t.check(ResourceLoader.exists(Faces.FACE % n), "seat %d's drawing ships in the game" % n)
		t.check(CrewView.image_hash(Faces.drawing(n)) != CrewView.image_hash(Faces.own_drawing(n)), "seat %d wears the tape's drawing" % n)
		t.eq(str(crew.call(&"describe", n - 1)["faceHash"]), CrewView.texture_hash(Faces.damaged(n)), "and it is on seat %d's screen" % n)
	t.check(bool(crew.get("zombie_clips")), "the four have the downloaded crawl and run")
	t.eq(str(crew.call(&"clip_for", "crawling")), "station/zombie_crawl", "crawling plays the downloaded crawl")
	t.eq(str(crew.call(&"clip_for", "pursuing")), "station/zombie_run", "pursuing plays the downloaded run")
	Faces._cache.clear()
	level.free()
