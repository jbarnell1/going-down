extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Sight = preload("res://sim/sight.gd")
const Entity = preload("res://sim/entity.gd")
const Seek = preload("res://sim/seek.gd")
const Places = preload("res://sim/places.gd")
const Stamina = preload("res://sim/stamina.gd")
const Search = preload("res://tests/prop_search.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")

static func _pair(s: Run.RunState, occluded: bool) -> Array[Move.Body]:
	for y in s.plan.height:
		for x in s.plan.width:
			if not Floor.is_walkable(s.plan, 0, x, y):
				continue
			var a := Move.body_at_cell(s.plan, Floor.Pos.make(0, x, y))
			for step: Vector2i in [Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(0, 2)]:
				if not Floor.is_walkable(s.plan, 0, x + step.x, y + step.y):
					continue
				var b := Move.body_at_cell(s.plan, Floor.Pos.make(0, x + step.x, y + step.y))
				if not Run.in_car(s.car, a) and not Run.in_car(s.car, b) and Sight.has_line_of_sight(s.plan, Sight.eye_point(a, 1.65), Sight.eye_point(b, 1.2)) != occluded:
					return [a, b]
	return []

func test_confirmed_catch_is_once_per_event_only_when_seen(t: T) -> void:
	var s := Run.create_run("shaken-sightlines", ["A", "B"])
	s.nerve_passive = true
	s.phase = &"away"
	s.seek_off = true
	for hidden: bool in [false, true]:
		var pair := _pair(s, hidden)
		if not t.check(pair.size() == 2, "tested seeded geometry contains the requested sightline"):
			continue
		s.players[0].body = pair[0]
		s.players[0].aboard = false
		s.players[1].body = pair[1]
		s.players[1].aboard = false
		s.nerve_readings = {"A": 40.0, "B": 60.0}
		var yaw := Entity.yaw_toward(pair[1].x - pair[0].x, pair[1].z - pair[0].z)
		var input := Run.PlayerInput.make("A", pair[0], 1.65, yaw, 0.0, 90.0, 70.0)
		var victim := Run.PlayerInput.make("B", pair[1], 1.65, yaw, 0.0, 90.0, 70.0)
		var event := {"type": "caught", "t": s.t, "playerId": "B"}
		var after := s.copy()
		Run._step_nerve(s, after, {"A": input, "B": victim}, 0.0, [event, event])
		t.eq(Run.nerve_of(after, "A"), 40.0 if hidden else 25.0, "wall blocks the visual loss, and duplicate catches only charge once")
		t.eq(Run.nerve_of(after, "B"), 60.0, "being the victim is not witnessing its own catch")
		var later := after.copy()
		later.t += 1.0
		Run._step_nerve(after, later, {"A": input}, 0.0, [event])
		t.eq(Run.nerve_of(later, "A"), Run.nerve_of(after, "A"), "a duplicated snapshot or old event does not take nerve again")
		var fresh := {"type": "caught", "t": later.t, "playerId": "B"}
		Run._step_nerve(after, later, {"A": input}, 0.0, [fresh])
		t.eq(Run.nerve_of(later, "A"), 40.0 if hidden else 10.0, "a new confirmed catch of the same crewmate may be witnessed again")
		input.yaw += PI
		Run._step_nerve(s, after, {"A": input}, 0.0, [event])
		t.eq(Run.nerve_of(after, "A"), 40.0, "looking back the other way does not witness the catch")
		input.yaw = yaw
		after.nerve_passive = false
		Run._step_nerve(s, after, {"A": input}, 0.0, [event])
		t.check(after.nerve_readings.is_empty(), "toggle off omits catch loss")

func test_playroom_found_inside_a_hide_is_occluded(t: T) -> void:
	var s := Run.create_run("shaken-playroom", ["A", "B"], [Places.PLAYROOM])
	var pair := _pair(s, false)
	if not t.check(pair.size() == 2, "open line on the Playroom plan"):
		return
	Run._sync_seek(s)
	var found := Seek.player_of(s.seek, "B")
	if not t.check(found != null, "Playroom resident knows the victim"):
		return
	s.players[0].body = pair[0]
	s.players[0].aboard = false
	s.players[1].body = pair[1]
	var yaw := Entity.yaw_toward(pair[1].x - pair[0].x, pair[1].z - pair[0].z)
	var input := Run.PlayerInput.make("A", pair[0], 1.65, yaw, 0.0, 90.0, 70.0)
	t.check(Run._catch_in_view(s, s.players[0], input, s.players[1]), "open trace can see a crewmate on their feet")
	found.phase = &"inside"
	found.status = &"found"
	t.check(not Run._catch_in_view(s, s.players[0], input, s.players[1]), "Minder finding a crewmate still concealed does not cost a witness")

func test_exact_threshold_and_real_sprint_duration(t: T) -> void:
	var s := Run.with_paced(Run.create_run("shaken-sprint", ["A"]))
	s.nerve_passive = true
	s.nerve_readings = {"A": 25.0}
	t.check(not Run.shaken(s, "A"), "25 itself is calm")
	t.eq(Run.sprint_seconds(s, "A"), Stamina.PACED_SPRINT_SECONDS, "at the boundary, the paced campaign tank stays the normal seven seconds")
	s.paced = false
	t.eq(Run.sprint_seconds(s, "A"), Stamina.SPRINT_SECONDS, "at the boundary, the reference tank stays five seconds")
	s.paced = true
	s.nerve_readings["A"] = 24.9999
	for medic: bool in [false, true]:
		s.field_dressing = medic
		var wallet := Upgrades.UpgradeState.make()
		wallet.owned.assign(["second_wind", "field_dressing"])
		s.wallets = {"A": wallet}
		var dur := Run.sprint_seconds(s, "A")
		var want := 3.3 if medic else 3.0
		t.check(is_equal_approx(dur, want), "the confirmed tank has the expected full sprint duration")
		var tank := Stamina.Stamina.make(1.0, false, dur)
		tank = Stamina.step_stamina(tank, &"sprint", Stamina.SPRINT_SPEED, want - 0.001)
		t.check(tank.level > 0.0 and not tank.winded, "still sprinting one millisecond before expiry")
		tank = Stamina.step_stamina(tank, &"sprint", Stamina.SPRINT_SPEED, 0.002)
		t.check(tank.winded and tank.level == 0.0, "ordinary stamina actually expires at the confirmed duration")
		var gait := Stamina.gait_for(Stamina.Stamina.make(1.0, false, dur), true, false, true, INF)
		t.eq(Stamina.speed_for(gait, INF), Stamina.SPRINT_SPEED, "top speed and gait stay the normal sprint")
		t.note("Shaken full sprint %.3f s, Medic %s" % [dur, medic])
	s.nerve_readings["A"] = 0.0
	t.check(Run.shaken(s, "A") and s.players[0].status == &"ok", "zero applies the same effect as just below 25")
	s.nerve_passive = false
	t.check(not Run.shaken(s, "A") and is_equal_approx(Run.sprint_seconds(s, "A"), 7.7), "off returns to normal trained stamina")

func test_careful_search_deadline_stamps_on_hold_and_preserves_porter(t: T) -> void:
	var s := Search.find_run("porter-search", ["p0"], 1, false, false, true)
	s = Run.with_quick_fingers(Run.with_deep_pockets(Run.with_shop(Run.with_inventory(s))))
	s = Search.open_doors(s)
	var piece := Search.piece_with(s.find, "credits", 2)
	if not t.check(piece != null, "seeded ordinary drawer is reachable"):
		return
	var stand := Search.stand(piece)
	for porter: bool in [false, true]:
		var wallet := Upgrades.UpgradeState.make()
		if porter:
			wallet.owned.assign(["deep_pockets", "quick_fingers"])
		var base := s.copy()
		base.wallets = {"p0": wallet}
		for fast: bool in [false, true]:
			var input := Search.one(Search.inp("p0", stand[0], stand[1], true, fast))
			for low: bool in [false, true]:
				var attempt := base.copy()
				attempt.nerve_passive = true
				attempt.nerve_readings = {"p0": 24.0 if low else 25.0}
				var first := Run.step_run(attempt, input, 0.05)
				var starts := Search.of_type(first.events, "searchStart")
				if not t.check(starts.size() == 1, "ordinary held search starts once"):
					continue
				var expected := (0.8 if fast else (4.0 if low else 2.5)) / (2.2 if porter else 1.0)
				var row: Dictionary = starts[0]
				var seconds := float(row.done) - float(row.from)
				t.check(is_equal_approx(seconds, expected), "host stamps exact deadline for the actual search")
				t.eq(bool(row.get("silent", false)), porter, "Quick Fingers stays silent")
				t.eq(Search.of_type(first.events, "searchNoise").size(), int(fast and not porter), "rushed sound stays unchanged")
				if low and not fast:
					t.note("Shaken careful search %.6f s, Quick Fingers %s" % [seconds, porter])
				var during := first.state.copy()
				during.nerve_readings = {"p0": 25.0 if low else 24.0}
				var next := Run.step_run(during, input, 0.05)
				t.eq(next.state.find.searches.p0.done, row.done, "a Nerve change leaves the existing hold's deadline intact")

func test_quoted_threshold_survives_wire_rounding_and_old_view(t: T) -> void:
	var net := Transport.MemoryNetwork.new("shaken-wire")
	var host := Host.new(net.connect_peer("host"), "shaken-wire", ["A"], 0.0)
	var world := host.world()
	world["nerve"] = Run.Nerve.view(24.9999)
	var wire := {"type": "welcome", "you": "A", "seed": "shaken-wire", "playing": true, "evFrom": 1, "world": world}
	var packet: Variant = Protocol.decode(Protocol.encode(wire))
	if not t.check(packet != null, "real packet with Shaken flag decodes"):
		return
	t.eq(packet.world.nerve[0], 25.0, "number may round to the threshold in transit")
	var hud := Hud.new()
	hud.nerve = packet.world.nerve
	t.check(hud.nerve_shaken() and hud.nerve_lines()[0] == "NERVE 24/100  SHAKEN", "HUD stays below 25 while trusting the actual unrounded host flag")
	world["nerve"] = world["nerve"].slice(0, 5)
	var older: Variant = Protocol.decode(Protocol.encode(wire))
	if t.check(older != null, "private passive reading still decodes"):
		hud.nerve = older.world.nerve
		t.check(not hud.nerve_shaken(), "legacy passive view cannot enable a new effect")
	hud.free()
