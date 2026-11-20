# WD1: the Rigger is really in the Hanging Ward as played, what brings him, and how hard he is. The rules are the
# Ward's own (sim/ward/state.gd, arm.gd), stepped as the host steps them (net/host.gd _step_ward_review); the run's
# reading and quota path is sim/run.gd step_ward; the figures are client/ward/view.gd (with the private media pack in
# GD_PACKS_DIR; those checks SKIP without it, as on CI). The bot crews are sim/ward/bots.gd (tools/ward_hunt.gd runs
# the long table).
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Arm = preload("res://sim/ward/arm.gd")
const House = preload("res://sim/ward/house.gd")
const Settings = preload("res://sim/settings.gd")
const Run = preload("res://sim/run.gd")
const Instr = preload("res://sim/instrument.gd")
const Bots = preload("res://sim/ward/bots.gd")
const SEED := 8143

## A Ward with the lift gone at t = 0, and the tuning given ({id: value}).
static func _ward(given: Dictionary = {}, seed_value := SEED, crew := 4) -> Ward:
	var w := Ward.new(seed_value)
	w.tuning = Settings.make(given) if not given.is_empty() else null
	w.crew_size = crew
	w.leave(0.0)
	return w

## The ground-floor point of a room of house `h` (feet).
static func _room(w: Ward, h: int, area: StringName) -> Vector3:
	var a: Vector3 = w.houses[h].areas[area]
	return w.houses[h].to_world(Vector3(a.x, 0.0, a.z))

## Steps the Ward from `from` for `seconds`, each tick calling `rows.call(now)` for the crew. All events.
static func _run(w: Ward, from: float, seconds: float, rows: Callable) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var now := from
	while now < from + seconds - 1e-6:
		now += 0.05
		out.append_array(w.step(now, 0.05, 30.0, rows.call(now)))
	return out

static func _kinds(events: Array[Dictionary], kind: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in events:
		if e.kind == kind:
			out.append(e)
	return out

## A house other than the parlour and the laundry maisonette (front door entry), and one that is the maisonette.
static func _door_house(w: Ward) -> int:
	for i in range(1, w.houses.size()):
		if not w.houses[i].search_window.has_volume():
			return i
	return 1

# ---------------------------------------------------------------------------------------------
# 1. Is he there: a sprint brings the loaded line, the climb, the hang and the arm; the arm takes a player who stays.

func test_a_sprint_brings_the_line_the_climb_and_the_hand(t: T) -> void:
	var w := _ward()
	var h := _door_house(w)
	var at := _room(w, h, &"entry")
	var sprinting := true
	var rows := func(_now: float) -> Dictionary:
		return {"p1": {"position": at, "sprint": sprinting}}
	var evs := _run(w, 0.0, 0.1, rows)
	var loaded := _kinds(evs, &"line_loaded")
	t.check(loaded.size() == 1 and int(loaded[0].house) == h, "a sprint on a house's floor loads that house's line: %s" % str(loaded))
	sprinting = false
	t.eq(w.encounter, &"warning", "first only the loaded line is heard")
	t.eq(w.posed_limb(0.1).size(), 0, "nothing of him is there yet")
	evs = _run(w, 0.1, Ward.WARN_SECONDS + 0.1, rows)
	t.eq(w.encounter, &"climbing", "then he climbs")
	t.check(w.posed_limb(1.1).size() == 2, "the climbing body is posed (the view draws it)")
	evs = _run(w, 1.05, Ward.CLIMB_SECONDS + 0.1, rows)
	t.eq(w.encounter, &"searching", "then he hangs at the house and searches it")
	var contact := -1.0
	var reached := 0
	var now := 1.05 + Ward.CLIMB_SECONDS + 0.1
	while now < 30.0 and contact < 0.0:
		var e := _run(w, now, 0.05, rows)
		now += 0.05
		reached = maxi(reached, w.posed_limb(now).size())
		if not _kinds(e, &"contact").is_empty():
			contact = now
	t.check(reached > 2, "the arm pays out into the house (%d points)" % reached)
	t.check(contact > 0.0 and w.caught.has("p1"), "a player who stays where the noise was is taken")
	var warn := contact - float(loaded[0].at)
	t.check(warn >= 4.0, "the line loaded %.2f s before the hand touched (at least 4 s)" % warn)
	t.note("loaded at %.2f, caught at %.2f: %.2f s of warning" % [float(loaded[0].at), contact, warn])

func test_a_player_who_walks_out_is_not_taken(t: T) -> void:
	var w := _ward({&"rigger.steps_reach": 0.0, &"rigger.door_heard": 0.0})
	var h := _door_house(w)
	var inside := _room(w, h, &"entry")
	var out := w.houses[h].to_world(Vector3(0, 0.15, -1.2))
	var rows := func(now: float) -> Dictionary:
		return {"p1": {"position": inside if now < 0.2 else out, "sprint": now < 0.2}}
	var evs := _run(w, 0.0, 30.0, rows)
	t.eq(_kinds(evs, &"line_loaded").size(), 1, "the line loads once")
	t.check(not w.caught.has("p1"), "leaving the house on the cue is enough")

func test_creeping_is_never_heard(t: T) -> void:
	var w := _ward()
	var h := _door_house(w)
	var a := _room(w, h, &"entry")
	var b := _room(w, h, &"rear")
	# Creep back and forth between two rooms for a minute (1.2 m/s).
	var rows := func(now: float) -> Dictionary:
		var k := fmod(now * 1.2, 2.0 * a.distance_to(b)) / a.distance_to(b)
		return {"p1": {"position": a.lerp(b, k if k <= 1.0 else 2.0 - k), "creep": true}}
	var evs := _run(w, 0.0, 60.0, rows)
	t.eq(_kinds(evs, &"line_loaded").size(), 0, "creeping on a house floor never brings him")

## Walking (not creeping) near where he is brings him; far off it does not.
static func _walk_heard(given: Dictionary, near: bool) -> bool:
	var w := _ward(given)
	var h := w.lair
	if not near:
		var far := -1
		var best := 0.0
		for i in w.houses.size():
			var d := w._flat(_room(w, i, &"entry"), h)
			if d > best:
				best = d
				far = i
		h = far
	var a := _room(w, h, &"entry")
	var b := a + Vector3(0.6, 0, 0)
	var rows := func(now: float) -> Dictionary:
		var k := fmod(now * 3.0, 1.2) / 0.6
		return {"p1": {"position": a.lerp(b, k if k <= 1.0 else 2.0 - k)}}
	return not _kinds(_run(w, 0.0, 10.0, rows), &"line_loaded").is_empty()

func test_walking_is_heard_near_him_and_not_far_off(t: T) -> void:
	t.check(_walk_heard({}, true), "walking on the floor of the house below which he lives brings him")
	t.check(not _walk_heard({}, false), "walking at the far end of the Ward does not")
	t.check(not _walk_heard({&"rigger.steps_reach": 0.0}, true), "with HEARS A WALK WITHIN at 0, walking is never heard")

func test_the_winch_a_door_and_a_flare_are_heard(t: T) -> void:
	var w := _ward()
	var button: Dictionary = w.switches[0]
	var evs := _run(w, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": button.position, "use": true}})
	var loaded := _kinds(evs, &"line_loaded")
	t.check(loaded.size() == 1 and int(loaded[0].house) == int(button.house), "the winch motor loads the line at its house")
	var w2 := _ward()
	var h := _door_house(w2)
	var door := w2.houses[h].to_world(Vector3(0, 0, -0.3))
	evs = _run(w2, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": door, "use": true}})
	t.check(_kinds(evs, &"line_loaded").size() == 1 and w2.resident_house == h, "a door worked loads its house's line")
	var w3 := _ward({&"rigger.door_heard": 0.0})
	evs = _run(w3, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": w3.houses[h].to_world(Vector3(0, 0, -0.3)), "use": true}})
	t.eq(_kinds(evs, &"line_loaded").size(), 0, "with HEARS A DOOR off, a door is silent")
	var w4 := _ward()
	t.eq(_kinds(w4.hear_at(_room(w4, h, &"middle"), 1.0), &"line_loaded").size(), 1, "a flare's burst in a house loads its line")

func test_sprints_on_galleries_and_walkways_are_heard(t: T) -> void:
	var w := _ward()
	var h := _door_house(w)
	var gallery := w.houses[h].to_world(Vector3(0, 0.15, -0.8))
	var evs := _run(w, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": gallery, "sprint": true}})
	t.check(_kinds(evs, &"line_loaded").size() == 1 and w.resident_house == h, "a sprint on a gallery loads that house's line")
	var w2 := _ward({&"rigger.open_heard": 0.0})
	evs = _run(w2, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": gallery, "sprint": true}})
	t.eq(_kinds(evs, &"line_loaded").size(), 0, "with HEARS SPRINTS OUT OF DOORS off, a gallery sprint is silent")

func test_a_second_noise_brings_him_on_next(t: T) -> void:
	for on: bool in [true, false]:
		var w := _ward({} if on else {&"rigger.move_on": 0.0})
		var h := _door_house(w)
		var other := 1 if h != 1 else 2
		var a := _room(w, h, &"entry")
		var b := _room(w, other, &"entry")
		var rows := func(now: float) -> Dictionary:
			return {"p1": {"position": a if now < 0.2 else Vector3(0, 50, 0), "sprint": now < 0.2},
				"p2": {"position": b if now > 6.0 and now < 6.2 else Vector3(0, 60, 0), "sprint": now > 6.0 and now < 6.2}}
		var evs := _run(w, 0.0, 60.0, rows)
		var houses := _kinds(evs, &"line_loaded").map(func(e: Dictionary) -> int: return int(e.house))
		if on:
			t.check(houses == [h, other], "busy at one house, he goes on to the second noise, with its line loading: %s" % str(houses))
		else:
			t.check(houses == [h], "with MOVES ON off, the second noise is lost: %s" % str(houses))

func test_his_search_records_only_from_inside_the_house(t: T) -> void:
	var w := _ward()
	var h := _door_house(w)
	var inside := _room(w, h, &"rear")
	var outside := w.houses[h].to_world(Vector3(0, 0.15, -0.8))
	var crew := {"in": {"position": inside}, "out": {"position": outside}}
	_run(w, 0.0, 0.05, func(_n: float) -> Dictionary: return {"in": {"position": _room(w, h, &"entry"), "sprint": true}})
	_run(w, 0.05, 1.2, func(_n: float) -> Dictionary: return {})
	t.eq(w.encounter, &"climbing", "climbing")
	t.eq(w.recorders(crew), null, "his climb is recorded by anyone near (no one is left out)")
	_run(w, 1.25, 3.0, func(_n: float) -> Dictionary: return {})
	t.eq(w.encounter, &"searching", "searching")
	var who: Variant = w.recorders(crew)
	t.check(who is Dictionary and (who as Dictionary).has("in") and not (who as Dictionary).has("out"), "his search: only the player inside: %s" % str(who))
	w.tuning = Settings.make({&"rigger.record_inside": 0.0})
	t.eq(w.recorders(crew), null, "with SEARCH RECORDS ONLY INSIDE off, anyone near records it")

## The run's own reading path counts the Ward's readings towards the floor quota (and the day).
func test_ward_readings_count_towards_the_quota(t: T) -> void:
	var ids: Array[String] = ["p1"]
	var s := Run.create_run("wd1", ids, [], false, true)
	s.depth = 6
	s = Run.with_quota(s)
	t.eq(s.floor_needed, Run.floor_quota(6, 1), "floor 6 asks its quota")
	s.floor_needed = 50
	var held := Vector3(s.players[0].body.x, s.players[0].body.y + Instr.INSTRUMENT_HEIGHT, s.players[0].body.z)
	var limb := PackedVector3Array([held + Vector3(-1, 0, 2), held + Vector3(1, 0, 2)])
	var none := PackedVector3Array()
	var input := Run.PlayerInput.new()
	input.id = "p1"
	input.raised = true
	var inputs: Array[Run.PlayerInput] = [input]
	var pos := Vector3(s.players[0].body.x, s.players[0].body.y, s.players[0].body.z)
	var rows := {"p1": {"position": pos, "aboard": false, "active": true}}
	var nobody: Array[String] = []
	var cues: Array[Dictionary] = []
	var met := false
	for k in 120:
		var r := Run.step_ward(s, inputs, rows, limb if k < 60 else none, &"away", 0.0, nobody, 0.05, cues)
		s = r.state
		for e in r.events:
			met = met or e["type"] == "quotaMet"
	t.check(s.floor_earned > 0.0, "a closed Ward reading counts towards the floor quota: %.1f" % s.floor_earned)
	t.check(met, "and the quota is met on the Ward as on any floor")
	t.note("floor 6 asks %d alone, %d for four" % [Run.floor_quota(6, 1), Run.floor_quota(6, 4)])

# ---------------------------------------------------------------------------------------------
# 2. The bots, a few fixed seeds (tools/ward_hunt.gd runs hundreds).

func test_bot_crews_meet_him_and_every_catch_is_warned(t: T) -> void:
	var lines: Array[String] = []
	var careless_caught := 0
	var sensible_home := 0
	var stays := 0
	var warn := INF
	var came := 0
	for seed_value: int in [1, 2, 3]:
		for skill: StringName in [&"careless", &"sensible"]:
			var r := Bots.stay(seed_value, 4, skill)
			stays += 1
			came += 1 if r.comes > 0 else 0
			warn = minf(warn, r.warn_min)
			if skill == &"careless":
				careless_caught += int(r.caught_n)
			else:
				sensible_home += int(r.home)
			lines.append("%s seed %d: came %d, caught %d, home %d, recorded %d of %d" % [skill, seed_value, r.comes, r.caught_n, r.home, roundi(r.earned), r.needed])
	t.eq(came, stays, "he comes in every stay")
	t.check(careless_caught >= 2, "careless crews of four lose players (%d over three stays)" % careless_caught)
	t.check(sensible_home >= 9, "sensible crews of four mostly get home (%d of 12)" % sensible_home)
	t.check(warn >= 4.0, "no catch comes sooner than 4 s after its loaded line (shortest %.2f s)" % warn)
	t.note("; ".join(lines))

# ---------------------------------------------------------------------------------------------
# 3. The figures: with the media pack, the climbing body and the searching hand are drawn where the rules pose them.

func test_his_figure_and_hand_are_drawn(t: T) -> void:
	var dir := OS.get_environment("GD_PACKS_DIR")
	if not ResourceLoader.exists("res://assets/ward/rigger.glb"):
		if dir.is_empty() or not FileAccess.file_exists(dir.path_join("WardGroundMedia.pck")):
			t.note("skipped: pack not found (set GD_PACKS_DIR to the folder holding WardGroundMedia.pck)")
			return
		ProjectSettings.load_resource_pack(dir.path_join("WardGroundMedia.pck"), false)
	t.check(ResourceLoader.exists("res://assets/ward/rigger.glb") and ResourceLoader.exists("res://assets/ward/search-hand.glb"), "the figure and the hand are there")
	load("res://client/main.gd")
	var View: GDScript = load("res://client/ward/view.gd")
	var w := _ward()
	var h := _door_house(w)
	var view: Node3D = View.new(SEED, Vector3.ZERO)
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	var crew := []
	t.check(view.rigger != null and view.hand != null, "the Rigger's figure and hand are built")
	_run(w, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": _room(w, h, &"entry"), "sprint": true}})
	view.show_host(w.snapshot(0.3), 0.3, "me", crew)
	t.check(not view.rigger.visible and not view.hand.visible, "while only the line is loaded he is not seen")
	_run(w, 0.05, 1.5, func(_n: float) -> Dictionary: return {})
	view.show_host(w.snapshot(1.55), 1.55, "me", crew)
	t.check(view.rigger.visible, "climbing: the body is drawn on the line")
	_run(w, 1.55, 5.0, func(_n: float) -> Dictionary: return {})
	view.show_host(w.snapshot(6.55), 6.55, "me", crew)
	var tip: Vector3 = w.posed_limb(6.55)[-1]
	t.check(view.rigger.visible and view.hand.visible and view.hand.global_position.distance_to(tip) < 0.05, "searching: the hand is drawn at the posed limb's end (%s, %s)" % [view.hand.global_position, tip])
	view.queue_free()

# ---------------------------------------------------------------------------------------------
# tests/prop_settings.gd test_rigger_numbers: every one of the Rigger's rows moves what it names.

static func settings_proof(t: T) -> void:
	t.check(_walk_heard({}, true) and not _walk_heard({&"rigger.steps_reach": 0.0}, true), "rigger.steps_reach")
	var w := _ward()
	t.eq(Settings.f(w.tuning, &"rigger.click_reach", Ward.CLICK_REACH), Ward.CLICK_REACH, "rigger.click_reach is today's constant unset")
	t.check(_clicks_turn_the_hand({}) and not _clicks_turn_the_hand({&"rigger.click_reach": 0.0}), "rigger.click_reach")
	for id: StringName in [&"rigger.room_warn", &"rigger.probe", &"rigger.arm_speed", &"rigger.arm_back"]:
		var plain := _arm_of({}, 4)
		var tuned := _arm_of({id: 2.0}, 4)
		var field: String = {&"rigger.room_warn": "warning_seconds", &"rigger.probe": "probe_seconds", &"rigger.arm_speed": "out_speed", &"rigger.arm_back": "in_speed"}[id]
		t.check(is_equal_approx(float(plain.get(field)), Settings.today(id)) and is_equal_approx(float(tuned.get(field)), 2.0), "%s sets the arm's %s" % [id, field])
	var alone := _arm_of({&"rigger.alone_arm_speed": 2.0}, 1)
	var crew := _arm_of({&"rigger.alone_arm_speed": 2.0}, 2)
	t.check(is_equal_approx(alone.out_speed, 2.0) and is_equal_approx(crew.out_speed, Settings.today(&"rigger.arm_speed")), "rigger.alone_arm_speed is the arm's speed for a crew of one only")
	# The four switches are proved by the scenes above (open_heard, door_heard, move_on, record_inside); here: unset is on.
	for id: StringName in [&"rigger.open_heard", &"rigger.door_heard", &"rigger.move_on", &"rigger.record_inside"]:
		t.eq(Settings.today(id), 1.0, "%s is on today" % id)

static func _arm_of(given: Dictionary, crew: int) -> Arm:
	var w := _ward(given, SEED, crew)
	var h := _door_house(w)
	_run(w, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": _room(w, h, &"entry"), "sprint": true}})
	_run(w, 0.05, Ward.WARN_SECONDS + Ward.CLIMB_SECONDS + 0.1, func(_n: float) -> Dictionary: return {})
	return w.arm

## A player recording beside the hand in the entry while it heads elsewhere turns it back to the entry.
static func _clicks_turn_the_hand(given: Dictionary) -> bool:
	var w := _ward(given)
	var h := _door_house(w)
	_run(w, 0.0, 0.05, func(_n: float) -> Dictionary: return {"p1": {"position": _room(w, h, &"rear"), "sprint": true}})
	var house := w.houses[h]
	var at := 0.05
	var tip := Vector3.ZERO
	var room := &""
	# On its way to the rear, the hand passes through another room: wait for it there.
	while at < 12.0:
		_run(w, at, 0.05, func(_n: float) -> Dictionary: return {})
		at += 0.05
		if w.arm != null and w.arm.phase == &"extending" and w.arm.points.size() > 1:
			tip = w.arm.points[-1]
			room = house.area_at(tip)
			if room != &"" and room != w.arm.search_area:
				break
		room = &""
	if room == &"":
		return false
	# Beside the hand, out of its touch (0.46 m), on the room's wider side.
	var side := 0.9 if tip.x < 0.0 else -0.9
	var stand := house.to_world(Vector3(tip.x + side, 0.0, tip.z))
	_run(w, at, 0.05, func(_n: float) -> Dictionary: return {"p2": {"position": stand, "recording": true, "creep": true}})
	return w.arm._pending.size() > 0 and w.arm._pending[0] == room
