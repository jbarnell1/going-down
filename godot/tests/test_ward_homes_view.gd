# WH1: a Ward of homes (the run flag ward_homes) can be walked on a screen: client/ward/view.gd draws each home from
# its rules (sim/ward/house.gd): the walls with their windows cut, the stairs, the inner doorways and every piece of
# furniture as a plain box where the rules have it. Dressing with real props is stage 2. Checked on the view as built.
extends RefCounted

#
# WH1d: the homes' hides on the screen. The North Star: "Every floor has places to hide, and a view out of each"; the
# owner, 21 Nov: "The camera correctly being placed in the hiding spot means you don't need to add stuff as a mask over
# the camera itself, the objects do it for you." Checked here: each kind's camera sits at its eye height inside the
# furniture, near its open side, looking out and turned only within its limits, inside nothing drawn and with a clear
# view out; the prompt in and out in every floor's words; in the real game scene F gets in and out, the camera is the
# hide's, nothing is drawn over it and the walk is frozen; a hidden crewmate is drawn in the hide; and a shut inner door
# rattles, at the door, when, and only when, it is what stopped the hand. With the flag off none of it exists.
const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")
const Hides = preload("res://sim/hides.gd")
const HidesView = preload("res://client/ward/hides_view.gd")
const HideViewScript = preload("res://client/hide_view.gd")
const Game = preload("res://client/main.gd")
const GameScene = preload("res://main.tscn")
const LocalRoom = preload("res://net/local_room.gd")
const TestSwitches = preload("res://net/test_switches.gd")
const Session = preload("res://net/session.gd")
const HostRules = preload("res://net/host_rules.gd")
const Move = preload("res://sim/move.gd")
const Homes = preload("res://sim/ward/homes.gd")
const Dress = preload("res://client/ward/dress.gd")
const HomesDress = preload("res://client/ward/homes_dress.gd")
const DT := 0.05

static func _homes() -> Dictionary:
	var o := Layout.options(null)
	o["homes"] = 1
	return o

## The first hide of each kind over the seeds: {kind: [seed, house, hide]}.
static func _one_of_each(seeds: Array) -> Dictionary:
	var out := {}
	for seed_value: int in seeds:
		var w := Ward.new(seed_value, _homes())
		for i in w.houses.size():
			for k in w.houses[i].hides.size():
				var kind := StringName(w.houses[i].hides[k].kind)
				if not out.has(kind):
					out[kind] = [seed_value, i, k]
	return out

## The drawn parts of a hide's hollow shape (client/ward/view.gd hide_pieces), as boxes local to its house. WH3: a
## bed, table or bath is drawn by its model instead (_model_faces).
static func _parts(view: View, house: int, hide: int) -> Array[AABB]:
	var out: Array[AABB] = []
	for row: Dictionary in view.hide_pieces:
		if int(row.house) != house or int(row.hide) != hide:
			continue
		for anchor: Node in (row.node as Node3D).get_children():
			if anchor.get_child_count() == 0 or not ((anchor as Node3D).get_child(0) is MeshInstance3D):
				continue
			var mesh := ((anchor as Node3D).get_child(0) as MeshInstance3D).mesh as BoxMesh
			var at := (anchor as Node3D).position
			out.append(AABB(at - mesh.size * 0.5, mesh.size))
	return out

## WH3: the triangles of a hide's model as drawn (client/ward/homes_dress.gd add_model), local to its house; empty for a
## hide drawn in boxes.
static func _model_faces(view: View, house: int, hide: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for row: Dictionary in view.hide_pieces:
		if int(row.house) != house or int(row.hide) != hide:
			continue
		for child: Node in (row.node as Node3D).get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).mesh is ArrayMesh:
				var mi := child as MeshInstance3D
				var xf := (row.node as Node3D).transform * mi.transform
				for p in mi.mesh.get_faces():
					out.append(xf * p)
	return out

static func _view(seed_value: int, layout: Array) -> View:
	var view := View.new(seed_value, Vector3.ZERO, layout)
	view.own_hud = false
	view.own_camera = false
	view.own_environment = false
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	return view

## Every solid box drawn under a house's root, in the root's frame.
static func _solids(root: Node3D) -> Array[AABB]:
	var out: Array[AABB] = []
	for child: Node in root.get_children():
		if child is StaticBody3D:
			var shape := (child.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
			var at := (child as Node3D).position
			out.append(AABB(at - shape.size * 0.5, shape.size))
	return out

func test_the_homes_are_drawn_where_the_rules_have_them(t: T) -> void:
	var opts := Layout.options(null)
	opts["homes"] = 1
	for seed_value: int in [8143, 26]:
		var view := _view(seed_value, Layout.to_wire(opts))
		t.eq(view.houses.size(), 8, "seed %d: eight houses drawn" % seed_value)
		var missing: Array[String] = []
		var through: Array[String] = []
		for house: Dictionary in view.houses:
			var fixture: House = house.fixture
			if not t.check(fixture.homes(), "seed %d: the view's house is a home" % seed_value):
				continue
			var solids := _solids(house.root)
			for piece: Dictionary in fixture.furniture:
				var box: AABB = piece.box
				var found := false
				for s in solids:
					if s.position.is_equal_approx(box.position) and s.size.is_equal_approx(box.size):
						found = true
						break
				if not found:
					missing.append("%s %s" % [piece.kind, str(box)])
			# A window is a hole on the screen: nothing drawn solid fills its middle.
			for o: Dictionary in fixture.openings():
				var hole: AABB = o.hole
				if not hole.has_volume():
					continue
				for s in solids:
					if s.has_point(hole.get_center()):
						through.append("%s window %s" % [fixture.plan.type, o.wall])
		t.check(missing.is_empty(), "seed %d: every piece of furniture is drawn as a box where the rules have it: %s" % [seed_value, str(missing.slice(0, 6))])
		t.check(through.is_empty(), "seed %d: every window the hand comes in by is open on the screen: %s" % [seed_value, str(through.slice(0, 6))])
		view.queue_free()

## WH2: each home's front door leaf is drawn on the jamb its plan names (sim/ward/homes.gd front_leaf), and, open, it
## stands where the rules say it does (tests/ward_home_clear.gd checks nothing else stands there and that it is in no
## doorway's way); the lift's house hangs it on the right jamb, so it no longer stands across the parlour's doorway.
func test_the_front_doors_leaf_is_drawn_where_the_rules_have_it(t: T) -> void:
	for seed_value: int in [8143, 26]:
		var view := _view(seed_value, Layout.to_wire(_homes()))
		var wrong: Array[String] = []
		for i in view.houses.size():
			var fixture: House = view.houses[i].fixture
			var side := int(fixture.plan.door.hinge)
			var hinge: Node3D = view.door_hinges[i]
			if not is_equal_approx(hinge.rotation.y, Dress.door_open(side)):
				wrong.append("house %d: the leaf is not open into the house (%.2f)" % [i, hinge.rotation.y])
			# The leaf itself: the hinge's first box, in the house's frame.
			var anchor := hinge.get_child(0) as Node3D
			var size := ((anchor.get_child(0) as MeshInstance3D).mesh as BoxMesh).size
			var lo := Vector3(INF, INF, INF)
			var hi := -lo
			for corner in 8:
				var c := anchor.position + Vector3(size.x * (0.5 if (corner & 1) != 0 else -0.5), size.y * (0.5 if (corner & 2) != 0 else -0.5), size.z * (0.5 if (corner & 4) != 0 else -0.5))
				var p := hinge.transform * c
				lo = lo.min(p)
				hi = hi.max(p)
			var drawn := Rect2(lo.x, lo.z, hi.x - lo.x, hi.z - lo.z)
			var rest: Rect2 = Homes.front_leaf(fixture.door.get_center().x, fixture.door.size.x, side).rest
			if not rest.grow(0.005).encloses(drawn):
				wrong.append("house %d: the open leaf %s is drawn outside %s" % [i, str(drawn), str(rest)])
		t.check(wrong.is_empty(), "seed %d: every front door's leaf is drawn, open, where the rules have it: %s" % [seed_value, str(wrong.slice(0, 4))])
		t.eq(int(view.houses[0].fixture.plan.door.hinge), 1, "seed %d: the lift's house hangs its front door on the right jamb" % seed_value)
		view.queue_free()

# --- WH1d: the hides on the screen. ---

func test_each_hide_kind_puts_the_camera_inside_looking_out(t: T) -> void:
	var picks := _one_of_each([8143, 26, 0, 31827])
	for kind: StringName in [&"bed", &"wardrobe", &"table", &"bath"]:
		if not t.check(picks.has(kind), "a %s hide in the homes of the seeds tried" % kind):
			continue
		var p: Array = picks[kind]
		var view := _view(int(p[0]), Layout.to_wire(_homes()))
		var model: Ward = view.walk_model
		var house: int = p[1]
		var hide: int = p[2]
		var fixture: House = model.houses[house]
		var row: Dictionary = fixture.hides[hide]
		var box: AABB = row.box
		var d := HidesView.out_local(fixture, hide)
		var gy := HidesView.out_yaw(fixture, hide)
		# Turned right round and up: the camera is held to the hide's view.
		var cam := HidesView.camera(model, house, hide, gy + PI, 1.0)
		var at := fixture.to_local(Vector3(cam.x, cam.y, cam.z))
		t.check(at.x > box.position.x and at.x < box.end.x and at.z > box.position.z and at.z < box.end.z,
			"%s: the camera is inside the furniture (%s in %s)" % [kind, str(at), str(box)])
		t.check(absf(at.y - box.position.y - float(Hides.WARD_SPEC[kind][1])) < 1e-4, "%s: at its eye height, %.2f m (%.3f)" % [kind, float(Hides.WARD_SPEC[kind][1]), at.y - box.position.y])
		var face := (box.end if d.x + d.z > 0.0 else box.position)
		var to_face := absf((face.x - at.x) * d.x + (face.z - at.z) * d.z)
		t.check(absf(to_face - float(HidesView.INSET[kind])) < 1e-4, "%s: %.2f m in from its open side (%.3f)" % [kind, float(HidesView.INSET[kind]), to_face])
		var probes: Dictionary = fixture.areas if int(row.level) == 0 else fixture.upper_areas(int(row.level))
		var room: Vector3 = probes.get(row.room, box.get_center())
		t.check((room - box.get_center()).dot(d) > 0.0, "%s: its open side faces its room" % kind)
		var looking := Vector3(-sin(float(cam.yaw)), 0.0, -cos(float(cam.yaw)))
		var out_world := fixture.to_world(at + d) - fixture.to_world(at)
		var half := deg_to_rad(float(HidesView.VIEW_HALF[kind]))
		t.check(absf(wrapf(float(cam.yaw) - gy, -PI, PI)) <= half + 1e-4 and looking.dot(out_world) >= cos(half) - 1e-3,
			"%s: turned only within %d degrees of straight out" % [kind, int(HidesView.VIEW_HALF[kind])])
		t.eq(float(cam.pitch), HidesView.PITCH, "%s: and up only so far" % kind)
		var straight := HidesView.camera(model, house, hide, gy, 0.0)
		t.check(absf(wrapf(float(straight.yaw) - gy, -PI, PI)) < 1e-6, "%s: looking straight out is allowed" % kind)
		# Nothing is drawn over the picture, and the furniture is no solid box round the eyes: the camera is inside none
		# of the hollow shape's parts, and the way straight out of it is clear.
		var parts := _parts(view, house, hide)
		var faces := _model_faces(view, house, hide)
		t.check(not parts.is_empty() or not faces.is_empty(), "%s: drawn as a hollow shape or its model" % kind)
		var blocked: Array[String] = []
		for part in parts:
			if part.has_point(at) or part.intersects_segment(at, at + d * (float(HidesView.INSET[kind]) + 0.25)) != null:
				blocked.append(str(part))
		if HomesDress.segment_hits(faces, at, at + d * (float(HidesView.INSET[kind]) + 0.25)):
			blocked.append("its model")
		t.check(blocked.is_empty(), "%s: nothing round the eyes and a clear view out of the open side: %s" % [kind, str(blocked)])
		for root_child: Node in (view.houses[house].root as Node3D).get_children():
			if root_child is StaticBody3D:
				var shape := ((root_child as Node3D).get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
				var solid := AABB((root_child as Node3D).position - shape.size * 0.5, shape.size)
				if solid.is_equal_approx(box):
					t.check(not ((root_child as Node3D).get_child(0) as Node3D).visible, "%s: its solid box is not drawn" % kind)
		view.queue_free()

func test_the_prompt_in_and_out(t: T) -> void:
	var near := {"me": {"status": "ok"}, "wardHide": {"in": false, "kind": ""}, "nearHide": 70, "nearHideKind": "bed"}
	t.eq(HideViewScript.ward_note(near), "F  HIDE: UNDER THE BED    SHIFT+F  QUICK BUT LOUD", "by a bed: every floor's words")
	near["nearHideKind"] = "wardrobe"
	t.eq(HideViewScript.ward_note(near), "F  HIDE: IN THE WARDROBE    SHIFT+F  QUICK BUT LOUD", "by a wardrobe")
	near["nearHideKind"] = "bath"
	t.eq(HideViewScript.ward_note(near), "F  HIDE: IN THE BATH    SHIFT+F  QUICK BUT LOUD", "by a bath")
	near["nearHideKind"] = "table"
	t.eq(HideViewScript.ward_note(near), "F  HIDE: UNDER THE TABLE    SHIFT+F  QUICK BUT LOUD", "by a table")
	t.eq(HideViewScript.ward_note({"me": {"status": "ok"}, "wardHide": {"in": true, "kind": "bed"}, "nearHide": -1}), "F  GET OUT", "in one: how to get out")
	t.eq(HideViewScript.ward_note({"me": {"status": "ok"}, "wardHide": {"in": false, "kind": ""}, "nearHide": -1}), "", "by none: nothing")
	t.eq(HideViewScript.ward_note({"me": {"status": "caught"}, "wardHide": {"in": false, "kind": ""}, "nearHide": 3, "nearHideKind": "bed"}), "", "caught: nothing")
	t.eq(HideViewScript.ward_note({"me": {"status": "ok"}, "nearHide": 3, "nearHideKind": "bed"}), "", "off the Ward's homes: not this prompt")

func test_a_hidden_crewmate_is_drawn_in_the_hide(t: T) -> void:
	var picks := _one_of_each([8143, 26, 0, 31827])
	for kind: StringName in [&"bed", &"wardrobe"]:
		if not t.check(picks.has(kind), "a %s hide" % kind):
			continue
		var p: Array = picks[kind]
		var model := Ward.new(int(p[0]), _homes())
		var fixture: House = model.houses[int(p[1])]
		var box: AABB = fixture.hides[int(p[2])].box
		var latest := {"ward": {"extras": {"inner": [], "hidden": {"p2": [int(p[1]), int(p[2])], "p3": [int(p[1]), int(p[2])]}}}}
		var shown: Array[Vector3] = []
		for id: String in ["p2", "p3"]:
			var o := {"id": id, "x": 0.0, "y": 0.0, "z": 0.0, "yaw": 0.0, "gait": "walk"}
			HidesView.place_figure(model, latest, o)
			var at := fixture.to_local(Vector3(float(o.x), float(o.y), float(o.z)))
			t.check(at.x > box.position.x and at.x < box.end.x and at.z > box.position.z and at.z < box.end.z and absf(at.y - box.position.y) < 1e-4,
				"%s: %s is drawn in the hide, not standing in the room" % [kind, id])
			t.check(absf(wrapf(float(o.yaw) - HidesView.out_yaw(fixture, int(p[2])), -PI, PI)) < 1e-6, "%s: facing out of it" % kind)
			if kind == &"bed":
				t.eq(str(o.get("crewPose", "")), "prone", "under a bed: lying down")
			else:
				t.check(not o.has("crewPose") and str(o.gait) == "walk", "in a wardrobe: standing")
			shown.append(at)
		t.check(shown[0].distance_to(shown[1]) > 0.3, "%s: two in one hide side by side" % kind)
		var standing := {"id": "p4", "x": 1.0, "y": 0.0, "z": 2.0, "yaw": 0.5, "gait": "walk"}
		HidesView.place_figure(model, latest, standing)
		t.eq(standing, {"id": "p4", "x": 1.0, "y": 0.0, "z": 2.0, "yaw": 0.5, "gait": "walk"}, "one not hidden is drawn where they are")

## Every home's front-door arm, every ground-floor room and every inner door: shut that door alone, and the hand is
## stopped by it exactly when the room has no way in with it shut and one with it open.
func test_the_hand_is_stopped_by_a_shut_door_when_and_only_when_it_stands_in_the_way(t: T) -> void:
	var stopped := 0
	var through := 0
	var wrong: Array[String] = []
	for seed_value: int in [8143, 26]:
		var w := Ward.new(seed_value, _homes())
		for i in w.houses.size():
			var h := w.houses[i]
			for k in h.inner_doors.size():
				for room: StringName in h.areas:
					for j in h.inner_open.size():
						h.inner_open[j] = 1
					var arm := h.make_arm()
					arm.inner_doors_open(h.inner_open)
					var open_way := not arm._find_route(h.areas[room]).is_empty()
					h.inner_open[k] = 0
					arm.inner_doors_open(h.inner_open)
					var shut_way := not arm._find_route(h.areas[room]).is_empty()
					arm.hear(room)
					arm.step(arm.warning_seconds + 0.01, {})
					var want := k if open_way and not shut_way else -1
					if arm.door_stopped != want:
						wrong.append("seed %d house %d door %d room %s: %d, want %d" % [seed_value, i, k, room, arm.door_stopped, want])
					if want >= 0:
						stopped += 1
					else:
						through += 1
			for j in h.inner_open.size():
				h.inner_open[j] = 1
	t.check(stopped > 0 and through > 0, "some shut doors stand in the hand's only way (%d), others not (%d)" % [stopped, through])
	t.check(wrong.is_empty(), "the hand is stopped by the door exactly then: %s" % str(wrong.slice(0, 6)))

## A ground-floor room behind one door from the front door: [house, room, door], or [].
static func _behind_a_door(w: Ward) -> Array:
	for i in w.houses.size():
		var h := w.houses[i]
		for k in h.inner_doors.size():
			for room: StringName in h.areas:
				var arm := h.make_arm()
				if arm._find_route(h.areas[room]).is_empty():
					continue
				h.inner_open[k] = 0
				arm.inner_doors_open(h.inner_open)
				var blocked := arm._find_route(h.areas[room]).is_empty()
				h.inner_open[k] = 1
				if blocked:
					return [i, room, k]
	return []

## The Ward hears a room; stepped for `seconds`: every door_rattle event.
static func _rattles(w: Ward, house: int, room: StringName, seconds: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	w._hear(house, room, 0.1, events)
	var now := 0.1
	while now < seconds:
		now += DT
		for e in w.step(now, DT, 30.0, {}):
			if e.kind == &"door_rattle":
				out.append(e)
	return out

func test_a_shut_door_that_stops_the_hand_rattles_at_the_door(t: T) -> void:
	var w := Ward.new(8143, _homes())
	w.leave(0.0)
	var pick := _behind_a_door(w)
	if not t.check(not pick.is_empty(), "a room behind one door"):
		return
	var house: int = pick[0]
	var door: int = pick[2]
	var events: Array[Dictionary] = []
	t.check(w.use_inner_door(house, door, false, 0.05, events), "the door is shut")
	var heard := _rattles(w, house, pick[1], 25.0)
	var at := w.houses[house].to_world(w.houses[house].inner_doors[door].at)
	var here := 0
	for e in heard:
		t.check(int(e.house) == house and w.houses[int(e.house)].inner_open[int(e.door)] == 0, "every rattle is of a shut door")
		if int(e.door) == door and Vector3(float(e.x), float(e.y), float(e.z)).distance_to(at) < 0.02:
			here += 1
	t.check(here >= 1, "the shut door rattles where it stands when it stops the hand (%d)" % here)
	# The same search with the door open: no rattle.
	var w2 := Ward.new(8143, _homes())
	w2.leave(0.0)
	t.eq(_rattles(w2, house, pick[1], 25.0).size(), 0, "with every door open nothing rattles")
	# The crawling Rigger, as the game's rooms play him: every door shut, a noise in that room; a rattle is only ever of
	# a shut door, and with every door open there is none.
	for shut: bool in [true, false]:
		var r := Ward.new(8143, _homes())
		r.crew_size = 4
		r.enable_roam()
		r.leave(0.0)
		var ev: Array[Dictionary] = []
		if shut:
			for i in r.houses.size():
				for k in r.houses[i].inner_doors.size():
					r.use_inner_door(i, k, false, 0.05, ev)
		r.hear_at(r.houses[house].to_world(r.houses[house].areas[pick[1]]) - Vector3.UP * House.ARM_HEIGHT, 0.1)
		var now := 0.1
		var got := 0
		var bad := 0
		while now < 120.0:
			now += DT
			for e in r.step(now, DT, 30.0, {}):
				if e.kind == &"door_rattle":
					got += 1
					if r.houses[int(e.house)].inner_open[int(e.door)] != 0:
						bad += 1
		t.eq(bad, 0, "crawling Rigger, doors %s: every rattle is of a shut door" % ("shut" if shut else "open"))
		if shut:
			t.check(got >= 1, "crawling Rigger, every door shut: the hand is stopped and a door rattles (%d in 120 s)" % got)
		else:
			t.eq(got, 0, "crawling Rigger, every door open: no rattle")
	# The screen plays it at the door, in 3D, with the hand nowhere in view.
	var view := _view(8143, Layout.to_wire(_homes()))
	view.play_event({"type": "ward_door_rattle", "house": house, "door": door, "x": at.x, "y": at.y, "z": at.z, "t": 1.0})
	t.eq(view.rattles.size(), 1, "the screen plays the rattle")
	var sound := view.get_node_or_null("DoorRattle") as AudioStreamPlayer3D
	t.check(sound != null and sound.stream != null and sound.global_position.distance_to(at + Vector3.UP) < 0.01, "a recording, in 3D, at the door")
	t.check(view.hand == null or not view.hand.visible, "and no hand in view for it")
	view.queue_free()

func test_flag_off_nothing_rattles_and_no_hides_on_screen(t: T) -> void:
	for options: Dictionary in [{}, Layout.options(null)]:
		var w := Ward.new(8143, options)
		w.leave(0.0)
		var count := 0
		for i in w.houses.size():
			var events: Array[Dictionary] = []
			w._hear(i, w.houses[i].front_room(), 0.05, events)
		var now := 0.1
		while now < 40.0:
			now += DT
			for e in w.step(now, DT, 30.0, {}):
				if e.kind == &"door_rattle":
					count += 1
			if w.arm != null and w.arm.door_stopped != -1:
				count += 100
		t.eq(count, 0, "today's Ward: no rattle, and its arm is never stopped by a door")
	t.check(not HidesView.on({"ward": {"phase": "away"}}) and not HidesView.on({"ward": {"extras": {"called": true}}}), "a block without the homes has no hides on screen")
	t.eq(HidesView.hidden_of({"ward": {"phase": "away"}}, "p1"), [], "and nobody in one")

## In the real game scene, with the homes: by each kind of hide the prompt, F gets in, the camera is the hide's with
## nothing drawn over it, the walk is frozen, the view turns only so far, and F gets out again.
func test_in_the_game_f_hides_and_the_camera_is_the_hides(t: T) -> void:
	var original := Session.deck
	TestSwitches.ward_homes = true
	var tree := Engine.get_main_loop() as SceneTree
	var game := GameScene.instantiate() as Game
	game.automated = true
	tree.root.add_child(game)
	game.start.playtest_available = true
	_frames(game, 30)
	game._open_playtest()
	game.start.press(str(HostRules.WARD_DEPTH))
	var lr := game.link.rc as LocalRoom
	TestSwitches.ward_homes = false
	t.check(lr.rules.ward_homes, "the room's Ward has the homes")
	if lr.host._ward_review != null:
		# The Ward's own clock: the lift leaves once nobody is in it.
		lr.host._ward_review.called = false
	_frames(game, 20)
	var wf: Node3D = game._ward_floor
	if not t.check(wf != null and wf.view != null and wf.model.houses[0].homes(), "the main scene hosts the Ward of homes"):
		game.free()
		Session.deck = original
		return
	var model: Ward = wf.model
	var tried := 0
	for kind: StringName in [&"bed", &"wardrobe", &"table", &"bath"]:
		var pick := []
		for i in model.houses.size():
			for k in model.houses[i].hides.size():
				if pick.is_empty() and StringName(model.houses[i].hides[k].kind) == kind and HidesView.stand_spot(model, i, k).is_finite():
					pick = [i, k]
		if pick.is_empty():
			t.note("no %s by which to stand in this Ward" % kind)
			continue
		tried += 1
		var house: int = pick[0]
		var hide: int = pick[1]
		var spot := HidesView.stand_spot(model, house, hide)
		lr.host._place(LocalRoom.ME, Move.Body.make(spot.x, spot.z, 0, spot.y), lr.host.state.depth, lr.host.state)
		_frames(game, 12)
		t.eq(int(game.snap.get("nearHide", -1)), house * 64 + hide, "%s: the hide in reach" % kind)
		var prompt := "F  HIDE: %s    SHIFT+F  QUICK BUT LOUD" % str(HideViewScript.KIND_NAMES[String(kind)])
		t.eq(game.hud.seek_note, prompt, "%s: the prompt" % kind)
		_key(KEY_F, true)
		_frames(game, 4)
		_key(KEY_F, false)
		_frames(game, 24)
		var row: Variant = lr.host._ward_review.hidden.get(LocalRoom.ME)
		t.check(row is Dictionary and int(row.house) == house and int(row.hide) == hide, "%s: F gets in" % kind)
		var hc: Dictionary = game.snap.get("hideCam", {})
		t.check(hc.get("ward", false) == true and int(hc.get("house", -1)) == house and int(hc.get("hide", -1)) == hide, "%s: the camera is the hide's" % kind)
		var want := HidesView.camera(model, house, hide, game.yaw, game.pitch)
		var want_at := Vector3(want.x, want.y, want.z)
		t.check(game.cam.position.distance_to(want_at) < 0.015, "%s: the camera at the hide's eye (%s against %s)" % [kind, str(game.cam.position), str(want_at)])
		t.check(absf(wrapf(game.yaw - float(want.gapYaw), -PI, PI)) < 1e-3, "%s: getting in faces straight out" % kind)
		t.eq(game.hud.seek_note, "F  GET OUT", "%s: the prompt says how to get out" % kind)
		var ov: Variant = game.hide_view.overlay
		t.check(ov.mode == "" and not HideViewScript.HideOverlay.draws_anything(ov.mode, ov.catch_k, ov.hat), "%s: nothing is drawn over the picture" % kind)
		# Frozen: W walks nobody out of a hide.
		var before := Vector3(game.link.body.x, game.link.body.y, game.link.body.z)
		_key(KEY_W, true)
		_frames(game, 30)
		_key(KEY_W, false)
		_frames(game, 4)
		t.check(Vector3(game.link.body.x, game.link.body.y, game.link.body.z).distance_to(before) < 1e-4, "%s: the walk is frozen in a hide" % kind)
		t.check(lr.host._ward_review.hidden.has(LocalRoom.ME), "%s: and they are still in it" % kind)
		# Turning: only as far as the hide's view.
		game.yaw = float(want.gapYaw) + PI * 0.9
		_frames(game, 3)
		t.check(absf(wrapf(game.yaw - float(want.gapYaw), -PI, PI)) <= float(want.gapHalf) + 1e-3, "%s: the view turns only so far" % kind)
		_key(KEY_F, true)
		_frames(game, 4)
		_key(KEY_F, false)
		_frames(game, 24)
		t.check(not lr.host._ward_review.hidden.has(LocalRoom.ME), "%s: F gets out" % kind)
		t.check((game.snap.get("hideCam", {}) as Dictionary).is_empty(), "%s: the camera is the player's again" % kind)
		var inner: Array = (lr.host._ward_review as Ward).inner_doors_wire()
		t.check(inner.all(func(m: int) -> bool: return m == 0), "%s: the F for the hide works no door" % kind)
	t.check(tried >= 2, "at least two kinds of hide tried in the game (%d)" % tried)
	game.free()
	Session.deck = original

static func _key(code: Key, down: bool) -> void:
	var k := InputEventKey.new()
	k.pressed = down
	k.keycode = code
	k.physical_keycode = code
	Input.parse_input_event(k)
	Input.flush_buffered_events()

static func _frames(game: Node, n: int) -> void:
	for i in n:
		game._process(1.0 / 60.0)
		OS.delay_usec(16667)
