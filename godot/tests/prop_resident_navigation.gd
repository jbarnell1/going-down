extends RefCounted

const T = preload("res://tests/t.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Lonely = preload("res://sim/lonely.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Relocate = preload("res://sim/relocate.gd")
const Run = preload("res://sim/run.gd")
const HostRules = preload("res://net/host_rules.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Ready = preload("res://tests/prop_ready.gd")

const DT := 0.05
const RADIUS := 0.35
const IDS: Array[String] = ["crew"]

static func _point(plan: Floor.FloorPlan, x: float, z: float, level: int = 0) -> Move.Body:
	return Move.Body.make(x, z, level, Move.feet_height(plan, level, x, z))

static func _gap(a: Move.Body, b: Move.Body) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))

## Check the straight path clients interpolate between consecutive host poses, as well as the end.
static func _clear_sweep(solids: Move.Solids, a: Move.Body, b: Move.Body) -> bool:
	for i in range(1, 6):
		var at := i / 5.0
		if Move.box_clearance(solids, b.level, lerpf(a.x, b.x, at), lerpf(a.z, b.z, at)) < RADIUS - 1e-5:
			return false
	return true

static func _open_plan() -> Floor.FloorPlan:
	var plan := Floor.FloorPlan.new()
	plan.width = 6
	plan.height = 3
	plan.cell_size = 2
	plan.cells[0].resize(plan.width * plan.height)
	plan.cells[0].fill(Floor.CORRIDOR)
	plan.cells[1].resize(plan.width * plan.height)
	plan.cells[1].fill(Floor.VOID)
	plan.landing = Floor.Pos.make(0, 0, 1)
	plan.entity_start = plan.landing
	return plan

func test_routes_between_two_pieces_and_caches_an_impossible_goal(t: T) -> void:
	var plan := _open_plan()
	var solids := Move.Solids.new()
	solids.add(0, 3.0, 0.0, 4.7, 4.0)
	solids.add(0, 6.0, 2.0, 7.7, 6.0)
	var start := _point(plan, 1.0, 3.0)
	var goal := _point(plan, 10.0, 3.0)
	var walk := Follow.ResidentWalk.new()
	var cur := start
	var total := 0.0
	var crossed := [false, false]
	for _i in 300:
		var next := Follow.step_resident_walk(plan, walk, cur, goal, 0.18, RADIUS, solids)
		t.check(_clear_sweep(solids, cur, next), "the resident's swept pose clears both solid pieces (%.4f, %.4f to %.4f, %.4f)" % [cur.x, cur.z, next.x, next.z])
		if next.x > 3.0 and next.x < 4.7 and next.z >= 4.0 + RADIUS - 1e-5:
			crossed[0] = true
		if next.x > 6.0 and next.x < 7.7 and next.z <= 2.0 - RADIUS + 1e-5:
			crossed[1] = true
		total += _gap(cur, next)
		cur = next
		if cur.same(goal):
			break
	t.check(crossed[0] and crossed[1] and _gap(cur, goal) < 0.01, "the resident walks above the first piece, below the second and reaches the target")
	t.check(total > _gap(start, goal) + 1.0, "the resident walked a detour of %.2f m" % total)

	# The same goal is now separated by a floor-wide barrier. A failed search is reused while the
	# target stays put, and the walker can take a new route when the target becomes reachable again.
	var sealed := Move.Solids.new()
	sealed.add(0, 5.0, 0.0, 5.7, 6.0)
	walk = Follow.ResidentWalk.new()
	var started := Time.get_ticks_usec()
	cur = Follow.step_resident_walk(plan, walk, start, goal, 0.18, RADIUS, sealed)
	var blocked_us := Time.get_ticks_usec() - started
	var points := walk.points
	started = Time.get_ticks_usec()
	for _i in 300:
		cur = Follow.step_resident_walk(plan, walk, cur, goal, 0.18, RADIUS, sealed)
	var repeated_us := Time.get_ticks_usec() - started
	t.check(is_same(walk.points, points) and walk.points.is_empty() and cur.same(start), "retrying a sealed goal reuses its failed route and leaves the resident clear")
	var new_goal := _point(plan, 4.0, 3.0)
	for _i in 100:
		cur = Follow.step_resident_walk(plan, walk, cur, new_goal, 0.18, RADIUS, sealed)
	t.check(_gap(cur, new_goal) < 0.01, "a reachable goal resumes movement after the failed route")
	t.note("blocked search %.2f ms, 300 unchanged chase ticks %.2f ms" % [blocked_us / 1000.0, repeated_us / 1000.0])

## Find two points separated by real furniture, with a line that would otherwise be walkable.
static func _across_piece(s: Run.RunState, solids: Move.Solids) -> Array[Move.Body]:
	for level in 2:
		var boxes: PackedFloat64Array = solids.boxes[level]
		for i in range(0, boxes.size(), 4):
			var mx := (boxes[i] + boxes[i + 2]) * 0.5
			var mz := (boxes[i + 1] + boxes[i + 3]) * 0.5
			var pairs: Array = [
				[_point(s.plan, boxes[i] - 0.65, mz, level), _point(s.plan, boxes[i + 2] + 0.65, mz, level)],
				[_point(s.plan, mx, boxes[i + 1] - 0.65, level), _point(s.plan, mx, boxes[i + 3] + 0.65, level)],
			]
			for p: Array in pairs:
				var from: Move.Body = p[0]
				var to: Move.Body = p[1]
				if Run.in_car(s.car, from) or Run.in_car(s.car, to):
					continue
				if Move.clear_at(s.plan, solids, level, from.x, from.z, RADIUS + 0.03) \
						and Move.clear_at(s.plan, solids, level, to.x, to.z, RADIUS + 0.03) \
						and Move.straight_to(s.plan, null, from, to, RADIUS):
					return [from, to]
	return []

static func _host_at(place: StringName, on: bool, start_depth: int = 1) -> HostRules:
	return HostRules.new(true, start_depth, [place], false, false, false, false, false, false, false, false, place == Places.ANNEX, false, false, true, false, false, true, on)

static func _set_pursuit(s: Run.RunState, from: Move.Body, to: Move.Body) -> void:
	s.phase = &"away"
	s.orderly.body = from
	s.orderly.yaw = Entity.yaw_toward(to.x - from.x, to.z - from.z)
	s.orderly.mode = &"hunting"
	s.players[0].body = to
	s.players[0].aboard = false

static func _viewer(body: Move.Body, yaw: float, blind: bool) -> Array[Run.PlayerInput]:
	var inp := Run.PlayerInput.make(IDS[0], body, 1.65, yaw, 0.0, 90.0, 70.0)
	inp.blind = blind
	return [inp]

func test_host_pursuit_clinic_and_annex_and_original_path_with_flag_off(t: T) -> void:
	for place: StringName in [Places.CLINIC, Places.ANNEX]:
		var host := _host_at(place, true)
		var s := host.prepare(Run.create_run("furniture-nav-13", IDS, [place]))
		var solids := Run.solids_in(s)
		var pair := _across_piece(s, solids)
		if not t.check(pair.size() == 2, "%s has a walkable pair across a real piece" % place):
			continue
		var from := pair[0]
		var to := pair[1]
		_set_pursuit(s, from, to)
		var old_host := _host_at(place, false)
		var old := old_host.prepare(Run.create_run("furniture-nav-13", IDS, [place]))
		_set_pursuit(old, from, to)
		var clean := old.copy()
		clean.furniture = false
		var away := Entity.yaw_toward(to.x - from.x, to.z - from.z)
		var input := _viewer(to, away, place == Places.CLINIC)
		var old_hit := false
		var old_path_same := true
		var live_armed := false
		var replay := s
		var peak := 0
		for _i in 130:
			var before := s.orderly.body
			var started := Time.get_ticks_usec()
			s = host.step(s, input, DT).state
			peak = maxi(peak, Time.get_ticks_usec() - started)
			replay = host.step(replay, input, DT).state
			t.check(s.orderly.body.same(replay.orderly.body), "%s authoritative positions repeat exactly" % place)
			t.check(_clear_sweep(solids, before, s.orderly.body), "%s resident does not clip through the shared furniture (%.4f, %.4f to %.4f, %.4f)" % [place, before.x, before.z, s.orderly.body.x, s.orderly.body.z])
			if old.orderly.mode != &"windUp":
				var old_before := old.orderly.body
				old = old_host.step(old, input, DT).state
				clean = old_host.step(clean, input, DT).state
				old_hit = old_hit or not _clear_sweep(solids, old_before, old.orderly.body)
				old_path_same = old_path_same and old.orderly.body.same(clean.orderly.body)
			if s.orderly.mode == &"windUp":
				live_armed = true
				break
		t.check(old_hit and old_path_same and not old.resident_navigation, "%s flag off keeps the pre-existing path through the footprint" % place)
		t.check(live_armed, "%s resident can still reach its prey after routing around the obstruction" % place)
		t.note("%s pursuit peak authoritative tick %.2f ms" % [place, peak / 1000.0])
		if place == Places.CLINIC and live_armed:
			var look := _viewer(to, Entity.yaw_toward(s.orderly.body.x - to.x, s.orderly.body.z - to.z), false)
			var held := host.step(s, look, DT).state.orderly
			t.check(held.held and held.body.same(s.orderly.body) and held.yaw == s.orderly.yaw and held.mode != &"windUp", "looking still freezes the Orderly and cancels the reach")
			var blind := _viewer(to, away, true)
			var grace := host.step(s, look, DT).state
			for _j in 4:
				grace = host.step(grace, blind, DT).state
				t.check(grace.orderly.body.same(held.body) and grace.orderly.held, "the watcher's grace holds the same pose")

func test_orderly_approaches_hide_front_and_temp_can_break_off(t: T) -> void:
	var plan := _open_plan()
	var solids := Move.Solids.new()
	solids.add(0, 4.0, 0.0, 5.5, 4.0)
	var start := _point(plan, 1.0, 3.0)
	var goal := _point(plan, 7.0, 3.0)
	var orderly := Entity.create_orderly(plan)
	orderly.body = start
	orderly.mode = &"hunting"
	var hidden := Entity.PlayerView.make("hidden", goal, 1.65, 0.0, 0.0, 90.0, 70.0, true, true)
	hidden.hidden = true
	hidden.hide = 12
	hidden.hide_reason = true
	hidden.hide_front = goal
	hidden.hide_at = _point(plan, 7.5, 3.0)
	var found := false
	for _i in 240:
		var prior := orderly.body
		var step := Entity.step_entity(plan, orderly, [hidden], DT, -1.0, true, 1, solids)
		orderly = step.state
		t.check(_clear_sweep(solids, prior, orderly.body), "hide approach clears the intervening solid piece")
		for e in step.events:
			found = found or e.type == "lookDone"
		if found:
			break
	t.check(found and _gap(orderly.body, goal) <= Entity.LOOK_REACH + 0.01, "Orderly finds the occupied hide from its front after detouring")

	var temp := Entity.create_orderly(plan, Entity.temp_body())
	temp.body = start
	temp.mode = &"hunting"
	temp.lonely_phase = &"breakoff"
	temp.path = Floor.find_path(plan, Move.cell_of(plan, start), Move.cell_of(plan, goal))
	temp.path_next = 1
	for _i in 130:
		var prior := temp.body
		temp = Lonely.step(plan, temp, [], [], DT, false, true, -1.0, solids).state
		t.check(_clear_sweep(solids, prior, temp.body), "Temp's retreat clears the intervening solid piece")
		if _gap(temp.body, goal) < 0.01:
			break
	t.check(_gap(temp.body, goal) < 0.01 and temp.lonely_phase == &"breakoff", "Temp reaches the retreat destination and waits for relocation")

func test_relocation_skips_a_solid_arrival(t: T) -> void:
	var s := Run.create_run("furniture-nav-13", IDS)
	var body := Move.body_at_cell(s.plan, s.plan.landing)
	var eyes: Array[Relocate.Eye] = [Relocate.Eye.make(IDS[0], body, 1.65, s.plan.landing, true)]
	var kind := Entity.orderly_body()
	var cell := Relocate.arrival(s.plan, s.seed, s.depth, 0, IDS[0], eyes, {}, kind)
	if not t.check(cell != null, "the Clinic fixture has a valid out-of-view arrival"):
		return
	var blocked := Move.body_at_cell(s.plan, cell)
	var solids := Move.Solids.new()
	solids.add(blocked.level, blocked.x - 0.15, blocked.z - 0.15, blocked.x + 0.15, blocked.z + 0.15)
	var revised := Relocate.arrival(s.plan, s.seed, s.depth, 0, IDS[0], eyes, {}, kind, solids)
	t.check(revised == null or not revised.equals(cell), "relocation rejects a blocked arrival instead of landing inside furniture")
	if revised != null:
		var spot := Move.body_at_cell(s.plan, revised)
		t.check(Relocate.out_of_view(s.plan, eyes, spot, kind), "the replacement arrival remains out of sight")

func test_routes_reach_the_landing_across_long_generated_floors(t: T) -> void:
	for place: StringName in [Places.CLINIC, Places.ANNEX]:
		var s := _host_at(place, true, 3).prepare(Run.create_run("rnb-1", IDS, [place]))
		var solids := Run.solids_in(s)
		var goal := Move.body_at_cell(s.plan, s.plan.landing)
		var cur := s.orderly.body
		var cells := Floor.find_path(s.plan, Move.cell_of(s.plan, cur), s.plan.landing)
		t.check(cells.size() > 40, "%s fixture needs a long route through many doors" % place)
		var walk := Follow.ResidentWalk.new()
		var clipped := false
		var peak := 0
		for _i in 1300:
			var started := Time.get_ticks_usec()
			var next := Follow.step_resident_walk(s.plan, walk, cur, goal, 0.18, RADIUS, solids)
			peak = maxi(peak, Time.get_ticks_usec() - started)
			clipped = clipped or not _clear_sweep(solids, cur, next)
			if next.same(cur):
				break
			cur = next
		t.check(not clipped and _gap(cur, goal) < 0.02 and cur.level == goal.level, "%s keeps progressing all the way to the landing" % place)
		t.note("%s: %d cells, peak route tick %.2f ms" % [place, cells.size(), peak / 1000.0])

func test_normal_room_entry_points_enable_routing_and_empty_playroom_is_unchanged(t: T) -> void:
	var prior_deck := Session.deck
	Session.deck = Places.FULL
	var local := LocalRoom.new()
	local.open_local("furniture-nav-13", "Crew", true)
	local.start_run()
	t.check(local.host.state.resident_navigation and local.host.state.furniture, "the actual solo room enables routing with the full deck")
	local.leave()
	Session.deck = Places.CLINIC_ONLY
	local.open_local("furniture-nav-13", "Crew", true)
	local.start_run()
	t.check(not local.host.state.resident_navigation, "a restricted test deck retains the old solo behavior")
	local.leave()
	Session.deck = prior_deck

	var room := Ready._room()
	var door := Ready._door(room)
	door.joined("c1", "Crew")
	room.update(0.0)
	door.msg("c1", Ready._ready_msg(true))
	room.update(0.1)
	room.update(6.0)
	if t.check(room.host != null, "the actual server room starts from ready-up"):
		t.check(room.host.state.resident_navigation and room.host.state.furniture, "the dedicated room enables routing")
		room._end_run()
	door.room = null

	var on := _host_at(Places.PLAYROOM, true, 4)
	var off := _host_at(Places.PLAYROOM, false, 4)
	var a := on.prepare(Run.create_run("furniture-nav-13", IDS, [Places.PLAYROOM]))
	var b := off.prepare(Run.create_run("furniture-nav-13", IDS, [Places.PLAYROOM]))
	t.check(Run.solids_in(a).count() == 0, "the current Playroom adds no shared solid obstruction")
	a.phase = &"away"
	b.phase = &"away"
	var player := Move.body_at_cell(a.plan, a.plan.landing)
	var input := _viewer(player, 0.0, false)
	var moved := false
	for _i in 100:
		a = on.step(a, input, DT).state
		b = off.step(b, input, DT).state
		moved = moved or a.orderly.moving
		t.check(a.orderly.body.same(b.orderly.body) and a.orderly.anim == b.orderly.anim, "Minder keeps the same positions and animation without shared solids")
	t.check(moved, "the Playroom fixture actually moved the Minder")
