# The real Host and two real Clients share the Ward over lossy in-memory links. No network ports.
extends RefCounted

const T = preload("res://tests/t.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Tape = preload("res://sim/tape.gd")
const Instr = preload("res://sim/instrument.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Ward = preload("res://sim/ward/state.gd")
const Protocol = preload("res://net/protocol.gd")
const Footing = preload("res://sim/ward/footing.gd")
const House = preload("res://sim/ward/house.gd")
const Wire = preload("res://net/ward_wire.gd")

class Exercise:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var clients: Array[Client] = []
	var names: Array[String] = ["one", "two"]
	var bodies: Array[Vector3] = [Vector3(7.0, 0, 7.0), Vector3(7.0, 0, 7.0)]
	var held: Array[bool] = [false, false]
	var raised: Array[bool] = [false, false]
	var now := 0.0
	var peak := 0.0

	func _init(on: bool) -> void:
		net = Transport.MemoryNetwork.new("ward", Transport.LinkConfig.make(0.023, 0.069, 0.12, 0.22, 0.08, 0.17))
		rules = HostRules.new(false, 1, [], on)
		host = Host.new(net.connect_peer("host"), "ward-net", names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
		for id in names:
			clients.append(Client.new(net.connect_peer(id), "host", id, now))
		if on:
			host.start_ward_review(8143)

	func tick_for(seconds: float) -> void:
		for frame in ceili(seconds / 0.025):
			now += 0.025
			net.now = now
			for i in clients.size():
				var c := clients[i]
				c.receive(now)
				var local := Client.LocalFrame.new()
				local.body = Move.Body.make(bodies[i].x, bodies[i].z, 0, bodies[i].y)
				local.use = held[i]
				local.raised = raised[i]
				c.frame(now, local)
			host.update(now)
			var current: Variant = host.world().get("ward")
			if current is Dictionary:
				peak = maxf(peak, current.armPoints.size())

	func ward_events(kind: String) -> int:
		var count := 0
		for row in host.event_log:
			if JSON.parse_string(row.text).get("type", "") == "ward_" + kind:
				count += 1
		return count

func test_two_clients_see_the_host_ward(t: T) -> void:
	var ex := Exercise.new(true)
	ex.tick_for(6.5)
	var ward := ex.host._ward_review
	t.check(ward.phase == &"away", "host starts collection after its real lift leaves")
	t.check(ward.collection_at > ex.host.state.t + 590.0 and ward.collection_at <= ex.host.state.t + 600.0, "the deadline is ten minutes from the host floor departure")
	for c in ex.clients:
		t.check(c.latest.get("ward") != null and c.latest.ward.collectionAt == ward.collection_at, "both clients see the same host deadline")
	ex.held[0] = true
	ex.tick_for(0.45)
	t.check(not ward.bridge_lowered and ward.encounter == &"idle", "press far from the switch cannot move the bridge")
	ex.held[0] = false
	ex.tick_for(0.45)
	var control: Dictionary = ward.switches[0]
	ex.bodies[0] = control.position
	ex.tick_for(0.45)
	ex.held[0] = true
	ex.raised[0] = true
	ex.raised[1] = true
	ex.tick_for(0.4)
	t.check(ward.bridge_lowered and ward.encounter == &"warning", "one host-validated press lowers the bridge and warns before climbing")
	t.eq(ex.ward_events("bridge"), 1, "duplicate input and held button produce one bridge event")
	var fixture: House = ward.houses[int(control.house)]
	var probe: Vector3 = fixture.areas[&"entry"]
	ex.bodies[1] = fixture.to_world(probe - Vector3.UP * 1.25)
	ex.tick_for(1.45)
	t.check(ward.encounter == &"climbing", "the warned line becomes the climbing line")
	for c in ex.clients:
		t.check(c.latest.ward.bridgeLowered and c.latest.ward.house == control.house and c.latest.ward.encounter == "climbing", "both clients agree on the raised load")
	ex.tick_for(5.0)
	t.check(ex.peak > 1 and ex.ward_events("contact") == 1 and ward.caught.has("two"), "one host hand reached and touched the endangered player")
	t.eq(ex.ward_events("bridge"), 1, "a long hold never toggles the bridge back")

	# Jump near the host deadline after verifying the original ten-minute schedule above.
	ward.collection_at = ex.host.state.t + 0.5
	ex.tick_for(0.8)
	t.check(ward.phase == &"boarding" and ward.depart_at > ward.collection_at, "host opens its Ward boarding phase")
	for c in ex.clients:
		t.check(c.latest.ward.departAt == ward.depart_at and c.latest.ward.phase == "boarding", "both eyes have the host's departure deadline")
	var reconnect := Client.new(ex.net.connect_peer("fresh"), "host", "fresh", ex.now)
	ex.clients.append(reconnect)
	ex.bodies.append(Vector3.ZERO)
	ex.held.append(false)
	ex.raised.append(false)
	ex.tick_for(0.65)
	t.check(reconnect.latest != null and reconnect.latest.ward.phase == "boarding"
		and reconnect.latest.ward.departAt == ward.depart_at and not reconnect.playing,
		"a fresh connection gets the same in-progress boarding clock")
	t.check(reconnect.latest.ward.caught.has("two"), "fresh spectator also receives the caught roster")
	var foyer: House = ward.houses[0]
	ex.bodies[0] = foyer.to_world(Vector3(foyer.floor_bounds.position.x - 0.12, 0.15, foyer.floor_bounds.get_center().y)) - Vector3.BACK * 1.5
	ex.tick_for(0.45)
	ward.depart_at = ex.host.state.t + 0.45
	ex.tick_for(1.2)
	t.eq(ward.boarded, ["one"], "physical cabin position makes only one return")
	t.eq(ward.left_behind, ["two"], "the rest are lost only on actual departure")
	for c in ex.clients:
		t.check(c.latest.ward.boarded == ["one"] and c.latest.ward.leftBehind == ["two"], "both clients receive the same final crew split")
	var summary := ex.host.state.summary
	t.check(summary != null and summary.total > 0.0, "the standard bank counts the actual limb reading aboard")
	t.check(summary != null and summary.shares["one"] == summary.total and summary.shares["two"] == 0.0, "only the physical boarder receives a share")
	t.check(ex.host.state.wallets["one"].credits == floori(summary.total) and (not ex.host.state.wallets.has("two") or ex.host.state.wallets["two"].credits == 0), "the real day settles both wallets")
	t.eq(ex.ward_events("tapes_lost"), 1, "the host discards the tapes that did not leave the floor")
	t.check(ex.host.state.going_up, "the normal ride home starts on Ward departure")
	var wallet := int(ex.host.state.wallets["one"].credits)
	for frame in 180:
		if Run.at_home(ex.host.state):
			break
		ex.tick_for(0.05)
	t.check(Run.at_home(ex.host.state) and int(ex.host.state.wallets["one"].credits) == wallet, "standard prison arrival retains the banked wallet")
	var boarder: Run.RunPlayer = ex.host.state.players[0]
	var left: Run.RunPlayer = ex.host.state.players[1]
	t.check(boarder.aboard and not left.aboard, "only the boarder reaches the prison inside the car")

func test_ward_off_keeps_old_world_shape(t: T) -> void:
	var ex := Exercise.new(false)
	ex.tick_for(6.5)
	var world := ex.host.world()
	t.check(not world.has("ward"), "normal room has no Ward state")
	t.eq(Protocol.enc_world(world).size(), 15, "normal room keeps original world array")
	for c in ex.clients:
		t.check(c.latest != null and not c.latest.has("ward"), "normal client gets no Ward fields")

func test_ward_wire_rejects_malformed_payloads(t: T) -> void:
	var ward := Ward.new(8143)
	var good := Wire.encode(ward.snapshot())
	t.check(not Wire.decode(good).is_empty(), "good optional block decodes")
	var bad := good.duplicate(true)
	bad[7] = [[0, 0, INF]]
	t.check(Wire.decode(bad).is_empty(), "non-finite arm point is rejected")
	bad = good.duplicate(true)
	bad[4] = 8
	t.check(Wire.decode(bad).is_empty(), "unknown house is rejected")

func test_ward_extension_does_not_claim_shop_slot(t: T) -> void:
	var ex := Exercise.new(false)
	var world := ex.host.world()
	var legacy := Protocol.enc_world(world)
	var shop := {"credits": [{"playerId": "one", "credits": 125}], "cabinets": [], "glows": [], "toys": [], "timers": [], "wake": -1.0}
	var shop_only_world := world.duplicate()
	shop_only_world["shop"] = shop
	var shop_only := Protocol.enc_world(shop_only_world)
	var ward := Ward.new(8143)
	world["ward"] = ward.snapshot()
	var review_only := Protocol.enc_world(world)
	t.eq(review_only.size(), Protocol.WORLD_FLOOR_EXTENSIONS_INDEX + 1, "review has the extra keyed slot")
	t.check(review_only[Protocol.WORLD_SHOP_INDEX] == null, "review null-pads the reserved shop slot")
	world["shop"] = shop
	var combined := Protocol.enc_world(world)
	for variant: Array in [legacy, shop_only, review_only, combined]:
		var welcome := JSON.stringify([1, "W", "one", "seed", 1, 1, variant])
		var parsed: Variant = Protocol.decode(welcome)
		t.check(parsed != null, "old, shop-only, review-only and combined layouts all decode")
		if parsed == null:
			continue
		var has_review := variant.size() == Protocol.WORLD_FLOOR_EXTENSIONS_INDEX + 1
		t.eq(parsed.world.has("ward"), has_review, "only the dedicated floor slot contains Ward")
		var has_shop := variant.size() > Protocol.WORLD_SHOP_INDEX and variant[Protocol.WORLD_SHOP_INDEX] != null
		t.eq(parsed.world.has("shop"), has_shop, "Shop has its own slot")
		if has_shop:
			t.eq(parsed.world.shop.credits[0].credits, 125, "the real Shop codec preserves the wallet")


func test_walking_clearance_obeys_the_door(t: T) -> void:
	var ward := Ward.new(8143)
	var fixture: House = ward.houses[1]
	var outside := fixture.to_world(Vector3(0.0, 0.0, -0.56))
	var inside := fixture.to_world(Vector3(0.0, 0.0, 0.42))
	t.check(ward.walk_clear(outside, inside), "a short walk crosses an open front door")
	ward.requested_doors[1] = false
	t.check(not ward.walk_clear(outside, inside), "the same walk is blocked by the shut leaf")
	var wall_entry := fixture.to_world(Vector3(1.1, 0.0, 0.42))
	t.check(not ward.walk_clear(outside, wall_entry), "a diagonal walk cannot cut through the jamb")


func test_the_game_host_refuses_a_walk_through_a_closed_ward_door(t: T) -> void:
	var ex := Exercise.new(true)
	ex.tick_for(0.8)
	var w := ex.host._ward_review
	var fixture: House = w.houses[1]
	var outside := fixture.to_world(Vector3(0, 0, -0.48))
	var inside := fixture.to_world(Vector3(0, 0, 0.31))
	ex.bodies[0] = outside
	ex.tick_for(0.4)
	ex.host._trusted.erase("one")
	w.requested_doors[1] = false
	ex.bodies[0] = inside
	ex.tick_for(0.35)
	var player: Host.HostPlayer = ex.host._players["one"]
	t.check(Vector3(player.body.x, player.body.y, player.body.z).distance_to(outside) < 0.03, "a real client input is held at the closed leaf")
	w.requested_doors[1] = true
	ex.tick_for(0.5)
	t.check(Vector3(player.body.x, player.body.y, player.body.z).distance_to(inside) < 0.03, "the same real client crosses once open")

func test_limb_distance_uses_standard_rates_and_repeat_factor(t: T) -> void:
	var ex := Exercise.new(true)
	var s := ex.host.state
	var body := Move.Body.make(50, 50, 0, 0)
	var held := Vector3(50, Instr.INSTRUMENT_HEIGHT, 50)
	var inst := Instr.create_instrument()
	inst.raised = true
	var et := Instr.EntityTick.make("rigger-1", &"rigger", s.orderly, s.orderly, [])
	et.acting = true
	et.limb = PackedVector3Array([held + Vector3(-1, 0, 3), held + Vector3(1, 0, 3)])
	var entities: Array[Instr.EntityTick] = [et]
	var factor := Instr.repeat_factor(2)
	var repeat := func(_id: String, _trait: StringName) -> float: return factor
	var take := Instr.step_instrument(s.plan, inst, body, true, entities, repeat, 0.05)
	t.check(take.recorded and is_equal_approx(take.instrument.rate, Instr.rate_at(3.0) * factor), "use closest point on the actual limb and the standard repeated rate")
	et.limb = PackedVector3Array([held + Vector3(-1, 0, 12), held + Vector3(1, 0, 12)])
	t.check(not Instr.step_instrument(s.plan, inst, body, true, entities, repeat, 0.05).recorded, "a far limb cannot pay")

func test_an_uncaught_outside_player_cannot_bank_their_tape(t: T) -> void:
	var ex := Exercise.new(true)
	var s := ex.host.state.copy()
	var crew := s.crew.copy()
	var rows := {}
	var aboard: Array[String] = ["one"]
	for i in crew.members.size():
		var member := crew.members[i].copy()
		var reading := Tape.Reading.new()
		reading.id = "reading-%d" % i
		reading.player_id = member.id
		reading.entity_id = "rigger-1"
		reading.trait_name = &"rigger"
		reading.value = 100.0 if i == 0 else 275.0
		member.tape = Tape.add_reading(member.tape, reading)
		crew.members[i] = member
		rows[member.id] = {"position": Vector3.ZERO, "active": true, "aboard": i == 0}
	s.crew = crew
	var result := Run.step_ward(s, [], rows, PackedVector3Array(), &"departed", 0.0, aboard, 0.05, [])
	t.eq(result.state.summary.total, 100.0, "only the boarder's tape goes into the bank")
	for event in result.events:
		if event.type == "ward_tapes_lost":
			t.eq(event.value, 275.0, "the uncaught outside player's own recorded tape is lost")
			return
	t.check(false, "departure reported no lost tapes")

func test_fixed_walkways_and_ground_floor_doors_are_walkable_both_ways(t: T) -> void:
	for seed: int in [0, 26, 8143, 31827, 4059166054]:
		var ward := Ward.new(seed)
		for house: House in ward.houses:
			var outside := house.to_world(Vector3(0, 0.15, -0.75))
			var inside := house.to_world(Vector3(0, 0.0, 0.42))
			t.check(ward.walk_clear(outside, inside) and ward.walk_clear(inside, outside), "open entry has supported floor on both sides for seed %d" % seed)
		for edge: Dictionary in ward.layout.bridges:
			if edge.kind != "fixed":
				continue
			var path: Array = edge.path
			for i in range(1, path.size()):
				var a := Footing.path_point(path[i - 1])
				var b := Footing.path_point(path[i])
				t.check(ward.walk_clear(a, b) and ward.walk_clear(b, a), "each fixed span joins its docks and corners for seed %d" % seed)

func test_host_stops_a_walker_at_an_unsupported_gallery_edge(t: T) -> void:
	var ex := Exercise.new(true)
	var ward := ex.host._ward_review
	var site: Dictionary = ward.layout.houses[0]
	var edge := float(site.y) + float(site.d) * 0.5 + 1.6
	var start := Vector3(float(site.x) + 0.45, float(site.z) + 0.15, edge - 0.45)
	ex.bodies[0] = start
	ex.tick_for(0.8)
	ex.host._trusted.erase("one")
	var boundary := start + Vector3.BACK * 0.23
	ex.bodies[0] = boundary
	ex.tick_for(0.4)
	var hp: Host.HostPlayer = ex.host._players["one"]
	t.check(absf(hp.body.z - boundary.z) < 0.025, "a real packet advances along supported decking")
	ex.bodies[0] = boundary + Vector3.BACK * 0.36
	ex.tick_for(0.45)
	t.check(absf(hp.body.z - boundary.z) < 0.025, "a real packet cannot step through the unsupported edge")
	var local := ward.walk(start, Vector2(0, 0.8))
	t.check(local.z > start.z + 0.15 and local.z < edge - 0.1, "a physical forward input predicts stopping short of the edge")

func test_raising_the_bridge_cannot_remove_footing_under_the_crew(t: T) -> void:
	var ward := Ward.new(8143)
	ward.leave(0)
	var switch: Dictionary = ward.switches[0]
	var open := {"operator": {"position": switch.position, "use": true}}
	ward.step(1.0, 0.05, 30.0, open)
	t.check(ward.bridge_lowered, "the winch lowers the shortcut")
	var mid := Vector3.INF
	for span: Dictionary in ward.footing.spans:
		if span.shortcut:
			var p: Vector3 = span.from
			var q: Vector3 = span.to
			mid = p.lerp(q, 0.5)
			break
	var flat := Vector2(mid.x, mid.z)
	t.check(is_finite(ward.footing.height_at(flat, true)) and not is_finite(ward.footing.height_at(flat, false)), "lowered deck has footing over open air")
	open["walker"] = {"position": mid}
	ward.step(2.0, 0.05, 30.0, open)
	t.check(ward.bridge_lowered, "the winch cannot retract beneath a walker")
	open.erase("walker")
	ward.step(3.0, 0.05, 30.0, open)
	t.check(not ward.bridge_lowered, "the shortcut can retract once clear")
