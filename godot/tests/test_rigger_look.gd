# RW1: the Rigger's new figure as the Ward's view shows him, and the test channel's way to look at him.
#   1. The new figure's own clips loop as they should (climb, hang, search loop; reach, withdraw play once).
#   2. While he searches the view plays the hang clip, and through the whole loop his wrist stays at the house's
#      shoulder, where the drawn arm leaves it, with his own hand folded away.
#   3. While he climbs, the drawn arm runs from his own wrist to the host's grip on the line (no gap at the wrist),
#      the search hand at the host's last point; today's figure (figures=old) draws only the host's points, as before.
#   4. Heard before seen: while the line is only loaded (the warning) and when he is idle he is not drawn and his
#      helmet lamp is not lit.
#   5. The copied middle legs are closed where they join the body: no open ring of the mesh sits at a hip.
#   6. house_spot: every house's entry corner is in its entry room and clear to stand in.
#   7. The test channel: the Ward commands answer only with testport=, bring and the house teleport only alone; a
#      bring is heard by the host's rules at their next tick, the line loads at the player's house, and nothing else
#      in the Ward's state changes without one.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const House = preload("res://sim/ward/house.gd")
const Ward = preload("res://sim/ward/state.gd")
const Main = preload("res://client/main.gd")
const PlayLink = preload("res://client/play_link.gd")
const WardFloor = preload("res://client/ward/floor.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Client = preload("res://net/client.gd")

## One frame of the solo room at host time NOW, the player standing at BODY (the screen's input).
static func _frame(room: LocalRoom, now: float, body: Move.Body) -> void:
	room.poll(now)
	var local := Client.LocalFrame.new()
	local.body = body
	room.frame(now, local)

static func _view(force_new := true) -> View:
	var view := View.new(8143, Vector3.ZERO)
	view.own_hud = false
	view.figures_new = force_new
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	return view

static func _skeleton(view: View) -> Skeleton3D:
	var found := view.rigger.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null

## A Ward block for house 0 in `encounter`, `elapsed` seconds after the line loaded.
static func _block(view: View, encounter: String, points: Array) -> Dictionary:
	return {"encounter": encounter, "house": 0, "startedAt": 0.0, "armPoints": points, "phase": "away",
		"bridgeLowered": false, "doors": [true, true, true, true, true, true, true, true], "caught": [],
		"collectionAt": 600.0, "departAt": -1.0, "boarded": [], "leftBehind": []}

func test_the_clips_loop_as_they_should(t: T) -> void:
	var view := _view()
	var player := view.animation
	if not t.check(player != null and view.rigger.scene_file_path == View.RIGGER_V2_PATH, "the new figure and its clips"):
		view.free()
		return
	var want := {&"climb": Animation.LOOP_LINEAR, &"hang": Animation.LOOP_LINEAR, &"search": Animation.LOOP_LINEAR,
		&"reach": Animation.LOOP_NONE, &"withdraw": Animation.LOOP_NONE}
	for clip: StringName in want:
		var a: Animation = player.get_animation(clip) if player.has_animation(clip) else null
		t.check(a != null and a.loop_mode == want[clip], "%s: loop mode %d (want %d)" % [clip, a.loop_mode if a else -1, want[clip]])
	view.free()

func test_he_hangs_with_his_wrist_at_the_shoulder_while_he_searches(t: T) -> void:
	var view := _view()
	var fixture: House = view.houses[0].fixture
	var shoulder := fixture.to_world(fixture.shoulder)
	var tip := fixture.to_world(fixture.shoulder + Vector3(0, -0.4, 1.4))
	var block := _block(view, "searching", [[shoulder.x, shoulder.y, shoulder.z], [tip.x, tip.y, tip.z]])
	view._show_rigger(block, Ward.WARN_SECONDS + Ward.CLIMB_SECONDS + 3.0)
	t.eq(view.animation.assigned_animation, View.HOLD_CLIP, "the hang clip plays while he searches")
	t.check(view.animation.is_playing(), "and runs on its own (a loop)")
	var skeleton := _skeleton(view)
	var hand := skeleton.find_bone("hand")
	var worst := 0.0
	var biggest := 0.0
	var legs_moved := 0.0
	var knees: Array[int] = []
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_name(i).ends_with("_tibia"):
			knees.append(i)
	var first_knees := {}
	for k in 17:
		view.animation.seek(4.0 * k / 16.0, true)
		view._show_rigger(block, Ward.WARN_SECONDS + Ward.CLIMB_SECONDS + 3.0 + k * 0.25)
		var wrist := skeleton.global_transform * skeleton.get_bone_global_pose(hand).origin
		worst = maxf(worst, wrist.distance_to(shoulder))
		var folded := skeleton.get_bone_global_pose(hand).basis.get_scale()
		biggest = maxf(biggest, maxf(folded.x, maxf(folded.y, folded.z)))
		for knee in knees:
			var at := skeleton.get_bone_global_pose(knee).origin
			if not first_knees.has(knee):
				first_knees[knee] = at
			legs_moved = maxf(legs_moved, at.distance_to(first_knees[knee]))
	t.check(worst < 0.02, "through the whole hang his wrist stays at the house's shoulder (at most %.3f m off)" % worst)
	t.check(biggest < 0.1, "his own hand stays folded away (scale at most %.3f)" % biggest)
	t.check(legs_moved > 0.1, "his legs move while he hangs (a knee moves %.2f m)" % legs_moved)
	view.free()

func test_on_the_line_the_arm_runs_from_his_wrist_to_the_grip(t: T) -> void:
	for figure_new: bool in [true, false]:
		var view := _view(figure_new)
		var fixture: House = view.houses[0].fixture
		var ward := Ward.new(8143)
		# The host's own climb limb, half way up: two points, the grip on the line last.
		ward.resident_house = 0
		ward.encounter = &"climbing"
		ward.encounter_at = 0.0
		var now := Ward.WARN_SECONDS + Ward.CLIMB_SECONDS * 0.5
		var limb := ward.posed_limb(now)
		var points := []
		for p: Vector3 in limb:
			points.append([p.x, p.y, p.z])
		view._show_rigger(_block(view, "climbing", points), now)
		var arrays := view.ribbon.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var wrist := view.rigger.position + view.rigger.basis * view.rigger_wrist
		# The first ring of the tube is the first point drawn; the triangles start on it.
		var nearest := INF
		for v in vertices:
			nearest = minf(nearest, v.distance_to(wrist))
		if figure_new:
			t.check(nearest < View.ARM_RADII_V2.x + 0.01, "new figure: the drawn arm starts at his wrist (its nearest surface %.3f m from it)" % nearest)
			t.check(view.hand.visible and view.hand.position.distance_to(limb[-1]) < 0.01, "the search hand is at the host's grip")
			var up := (view.hand.global_transform.basis.z).normalized()
			t.check(absf(up.dot(Vector3.UP)) > 0.9, "the hand points along the line it grips")
		else:
			t.check(nearest > 0.3, "today's figure: the arm is the host's points only, as before (%.3f m from the wrist)" % nearest)
		view.free()

func test_he_is_heard_before_he_is_seen(t: T) -> void:
	var view := _view()
	var fixture: House = view.houses[0].fixture
	var shoulder := fixture.to_world(fixture.shoulder)
	view._show_rigger(_block(view, "idle", []), 1.0)
	t.check(not view.rigger.visible and not view.lamp_light.is_visible_in_tree(), "idle: not drawn, lamp dark")
	view._show_rigger(_block(view, "warning", []), Ward.WARN_SECONDS * 0.5)
	t.check(not view.rigger.visible and not view.lamp_light.is_visible_in_tree(), "the line loaded (warning): still not drawn, lamp dark")
	t.check(not view.describe_rigger().drawn and not view.describe_rigger().lamp, "and describe_rigger says so")
	view._show_rigger(_block(view, "climbing", [[shoulder.x, shoulder.y - 2.0, shoulder.z], [shoulder.x, shoulder.y - 1.0, shoulder.z]]), Ward.WARN_SECONDS + 0.2)
	t.check(view.rigger.visible and view.lamp_light.is_visible_in_tree(), "climbing: drawn, his lamp lit")
	var seen := view.describe_rigger()
	t.check(seen.drawn and seen.lamp and seen.clip == "Rigger Climb" and seen.encounter == "climbing" and (seen.head as Array).size() == 3,
		"describe_rigger: drawn, lit, the climb clip, his head (%s)" % [seen])
	view.free()

## Open rings of the mesh (edges with one face, welded by position), as [centre, radius, edges].
static func _open_rings(mesh: Mesh) -> Array:
	var count := {}
	var key := func(p: Vector3) -> Vector3i: return Vector3i(roundi(p.x * 2000.0), roundi(p.y * 2000.0), roundi(p.z * 2000.0))
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for f in range(0, index.size(), 3):
			for k in 3:
				var a: Vector3i = key.call(vertices[index[f + k]])
				var b: Vector3i = key.call(vertices[index[f + (k + 1) % 3]])
				var edge := [a, b] if a < b else [b, a]
				count[edge] = int(count.get(edge, 0)) + 1
	var links := {}
	for edge: Array in count:
		if count[edge] == 1:
			for k in 2:
				links[edge[k]] = (links.get(edge[k], []) as Array) + [edge[1 - k]]
	var seen := {}
	var rings := []
	for start: Vector3i in links:
		if seen.has(start):
			continue
		var stack := [start]
		var members := []
		while not stack.is_empty():
			var v: Vector3i = stack.pop_back()
			if seen.has(v):
				continue
			seen[v] = true
			members.append(Vector3(v) / 2000.0)
			stack.append_array(links[v])
		var centre := Vector3.ZERO
		for p: Vector3 in members:
			centre += p
		centre /= members.size()
		var radius := 0.0
		for p: Vector3 in members:
			radius = maxf(radius, p.distance_to(centre))
		rings.append([centre, radius, members.size()])
	return rings

func test_the_copied_legs_are_closed_at_the_hip(t: T) -> void:
	var figure := (load(View.RIGGER_V2_PATH) as PackedScene).instantiate()
	var skeleton := figure.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var mesh := (figure.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D).mesh
	var rings := _open_rings(mesh)
	var at_hips := []
	for ring: Array in rings:
		for i in skeleton.get_bone_count():
			if skeleton.get_bone_name(i).ends_with("_femur"):
				var hip := skeleton.get_bone_rest(i).origin
				var parent := skeleton.get_bone_parent(i)
				while parent >= 0:
					hip = skeleton.get_bone_rest(parent) * hip
					parent = skeleton.get_bone_parent(parent)
				if (ring[0] as Vector3).distance_to(hip) < 0.6 and float(ring[1]) > 0.1 and int(ring[2]) >= 12:
					at_hips.append("%s: ring of %d, radius %.2f m" % [skeleton.get_bone_name(i), ring[2], ring[1]])
	t.note("%d open rings in the mesh (the cloth's hems, the lamp's glass)" % rings.size())
	t.check(at_hips.is_empty(), "no open leg root at a hip (%s)" % [at_hips])
	figure.free()

func test_every_entry_corner_is_a_place_to_stand(t: T) -> void:
	for seed_value: int in [8143, 1, 77, 2026]:
		var ward := Ward.new(seed_value)
		for i in ward.houses.size():
			var fixture: House = ward.houses[i]
			var feet := View.house_spot(fixture, "corner")
			var room := fixture.area_at(fixture.to_local(feet + Vector3.UP * 1.25))
			t.check(room == &"entry" and ward.walk_clear(feet, feet), "seed %d house %d: the corner is in the entry and clear (%s)" % [seed_value, i, room])
			for spot: String in ["entry", "middle", "rear"]:
				var at := View.house_spot(fixture, spot)
				t.check(fixture.area_at(fixture.to_local(at + Vector3.UP * 1.25)) == StringName(spot), "seed %d house %d: %s is that room" % [seed_value, i, spot])
		t.check(not View.house_spot(ward.houses[0], "attic").is_finite(), "an unknown spot is refused")

## A solo room on the Ward played as a normal level (WN1), the player in its lift, and a main game on it.
static func _ward_main(local := true) -> Array:
	var room := LocalRoom.new()
	room.open_local("rw1-look", "Tester", true)
	room.late_archive_root = ""
	room.start_playtest(6)
	for i in 6:
		room.poll(0.05 * i)
	var main := Main.new()
	main.hud = Hud.new()
	main.link = PlayLink.new(room, local)
	main.link.body = room.host._players[LocalRoom.ME].body
	var ward_floor := WardFloor.new()
	ward_floor.setup(int(room.client.latest.ward.seed), false, 0)
	main._ward_floor = ward_floor
	return [room, main, ward_floor]

static func _drop(parts: Array) -> void:
	(parts[0] as LocalRoom).leave()
	var main: Main = parts[1]
	main.hud.free()
	(parts[2] as Node).free()
	main.free()

func test_the_ward_commands_need_testport(t: T) -> void:
	var main := Main.new()
	main.hud = Hud.new()
	for c: String in ["wardbring", "wardhouse 1", "wardlook head"]:
		t.eq(main._command(c), "unknown command", "%s without testport=" % c)
	main._test_port = 4870
	t.check(main._command("wardbring").contains("not on the Hanging Ward"), "with testport= but off the Ward: refused")
	main.hud.free()
	main.free()

func test_bring_and_house_are_for_playing_alone(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var parts := _ward_main(false)
	var main: Main = parts[1]
	var room: LocalRoom = parts[0]
	main._test_port = 4870
	t.check(room.host._ward_review != null, "the Ward runs on floor 6")
	t.check(main._command("wardbring").contains("for playing alone"), "a network link refuses wardbring")
	t.check(main._command("wardhouse 1").contains("for playing alone"), "and wardhouse")
	t.eq(room.host._test_noises.size(), 0, "nothing was queued")
	_drop(parts)
	Session.deck = original

func test_a_bring_is_heard_at_the_players_house(t: T) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	var parts := _ward_main(true)
	var main: Main = parts[1]
	var room: LocalRoom = parts[0]
	main._test_port = 4870
	var ward: Ward = room.host._ward_review
	var placed: Dictionary = JSON.parse_string(main._command("wardhouse 3 corner"))
	t.check(placed.ok and placed.house == 3.0 and placed.clear, "wardhouse 3: in house 3's corner (%s)" % [placed])
	var now := 0.3
	var local := Move.Body.make(main.link.body.x, main.link.body.z, main.link.body.level, main.link.body.y)
	# The lift leaves once the player is out of it; nothing is heard on the way (standing still).
	for i in 40:
		now += 0.05
		_frame(room, now, local)
	t.eq(String(ward.phase), "away", "the lift has left")
	t.eq(String(ward.encounter), "idle", "and with no noise he stays below")
	var bring: Dictionary = JSON.parse_string(main._command("wardbring"))
	t.check(bring.ok and bring.queued, "wardbring is queued (%s)" % [bring])
	t.eq(String(ward.encounter), "idle", "nothing happens before the host's next tick")
	var loaded := []
	for i in 4:
		now += 0.05
		_frame(room, now, local)
	for e: Dictionary in room.client.events:
		if str(e.get("type", "")) == "ward_line_loaded":
			loaded.append(int(e.house))
	t.eq(String(ward.encounter), "warning", "at the next tick the line loads (the warning before the climb)")
	t.eq(ward.resident_house, 3, "at the player's house")
	t.eq(loaded, [3], "and the screen gets the loaded line's cue, as for a flare")
	t.eq(room.host._test_noises.size(), 0, "the noise was used once")
	_drop(parts)
	Session.deck = original
