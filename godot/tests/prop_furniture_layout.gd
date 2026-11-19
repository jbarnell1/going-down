# T20j: restored seating and planters share one layout across the host, prediction and drawing.
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Landing = preload("res://sim/landing.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Playroom = preload("res://sim/playroom.gd")
const Run = preload("res://sim/run.gd")
const PropFurniture = preload("res://tests/prop_furniture.gd")
const HostRules = preload("res://net/host_rules.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Protocol = preload("res://net/protocol.gd")
const RoomClient = preload("res://net/room_client.gd")
const Session = preload("res://net/session.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const LevelScript = preload("res://client/level.gd")
const PlayLink = preload("res://client/play_link.gd")
const TEST_PASSPHRASE := "layout-test-passphrase"

func test_layout_is_seeded_and_preserves_existing_pieces(t: T) -> void:
	var ids: Array[String] = ["a"]
	var run := HostRules.new(true, 1).prepare(Run.create_run("layout", ids))
	t.check(not run.furniture_layout, "restored layout is off by default")
	var breaks := 0
	var break_rooms := 0
	for spec: Array in [[Places.CLINIC_ONLY, 1], [Places.CLINIC_ONLY, 6], [[Places.ANNEX], 3], [[Places.ANNEX], 7]]:
		var deck: Array = spec[0]
		var depth: int = spec[1]
		for i in (4 if t.quick else 16):
			var seed := "layout-%d" % i
			var plan := Places.generate(seed, depth, deck)
			var again := Places.generate(seed, depth, deck)
			var baseline := Furniture.pieces_for(plan)
			var restored := Furniture.pieces_for(plan, "", -1, true)
			var rows := Furniture.plain(restored)
			t.eq(rows.slice(0, baseline.size()), Furniture.plain(baseline), "%s/%d: existing furniture and search IDs" % [seed, depth])
			t.eq(rows, Furniture.plain(Furniture.pieces_for(again, "", -1, true)), "%s/%d: independently generated layout" % [seed, depth])
			breaks += _check_additions(t, plan, restored, baseline.size())
			for room in plan.rooms:
				if room.kind == &"break":
					break_rooms += 1
	t.check(breaks > 0, "sample contains break-room tables and chairs")
	t.note("%d break-room table sets in %d break rooms" % [breaks, break_rooms])

static func _check_additions(t: T, plan: Floor.FloorPlan, pieces: Array[Furniture.Piece], from: int) -> int:
	var doors := Playroom._door_cells(plan)
	var dist := Floor.distances_from(plan, plan.landing)
	var kinds_by_room := {}
	var chairs_by_table := {}
	var breaks := 0
	var label := "%s/%d" % [plan.seed, plan.depth]
	for p: Furniture.Piece in pieces.slice(from):
		var room := plan.rooms[p.room]
		var expected: Array
		match room.kind:
			&"lobby":
				expected = [&"chair_waiting"] if plan.place == &"clinic" else [&"chair_row"]
			&"atrium":
				expected = [&"bench", &"planter"]
			&"break":
				expected = [&"break_table", &"chair"]
			_:
				expected = []
		t.check(expected.has(p.kind) and p.solid and not p.searchable and p.hide < 0,
			"%s: restored %s in %s is an approved solid piece" % [label, p.kind, room.kind])
		var kinds: Dictionary = kinds_by_room.get_or_add(room.id, {})
		kinds[p.kind] = int(kinds.get(p.kind, 0)) + 1
		var normal := Furniture.dir_vec(p.wall)
		var wall_edge := (p.foot.end.x if normal.x > 0 else p.foot.position.x) if normal.x != 0 else (p.foot.end.y if normal.y > 0 else p.foot.position.y)
		t.check((normal != Vector2i.ZERO and absi(wall_edge - p.wall_at) <= Furniture.INSET + 2), "%s: %s sits against a wall" % [label, p.kind])
		if room.kind == &"lobby":
			var lift_dir := Furniture.dir_vec(Landing.elevator_wall(plan))
			t.eq(Vector2(normal).dot(Vector2(lift_dir)), 0.0, "%s: lobby seating sits on a side wall" % label)
		for y in range(p.foot.position.y / Furniture.CM, (p.foot.end.y - 1) / Furniture.CM + 1):
			for x in range(p.foot.position.x / Furniture.CM, (p.foot.end.x - 1) / Furniture.CM + 1):
				var cell := Floor.Pos.make(p.level, x, y)
				var idx := Floor.pos_index(plan, cell)
				var landing_min := Furniture.LOBBY_LANDING_STEPS if room.kind == &"lobby" else Furniture.LANDING_STEPS + 1
				t.check(not doors.has(idx) and dist[idx] >= landing_min and Floor.cell_at(plan, p.level, x, y) == Floor.ROOM,
					"%s: %s clear of door and landing at %d,%d" % [label, p.kind, x, y])
		if p.kind == &"break_table":
			chairs_by_table[p.id] = 0
			breaks += 1
		elif p.kind == &"chair":
			if t.check(chairs_by_table.has(p.group), "%s: break-room chair belongs to its table" % label):
				chairs_by_table[p.group] += 1
	for count: int in chairs_by_table.values():
		t.eq(count, 2, "%s: two chairs sit beside each table" % label)
	for r in plan.rooms:
		var kinds: Dictionary = kinds_by_room.get(r.id, {})
		if r.kind == &"lobby":
			t.check(not kinds.is_empty(), "%s: lobby has seats" % label)
		elif r.kind == &"atrium":
			t.check(kinds.has(&"bench") and kinds.has(&"planter"), "%s: atrium has a bench and planter" % label)
	return breaks

func test_restored_layout_keeps_the_floor_reachable(t: T) -> void:
	for depth: int in [1, 3]:
		var plan := Places.generate("layout-0", depth, Places.FULL)
		var car := Run.car_geometry(plan)
		var grid := PropFurniture._grid(plan)
		var baseline := Furniture.solids_of(plan)
		var restored := Furniture.solids_of(plan, true)
		t.check(baseline.boxes != restored.boxes, "%s: exercised the added collision boxes" % plan.place)
		var prior := PropFurniture.reach(grid, baseline)
		var seen := PropFurniture.reach(grid, restored)
		t.eq(PropFurniture.cells_of(grid, seen), PropFurniture.cells_of(grid, prior), "%s: all floor cells still reachable" % plan.place)
		for door in plan.doors:
			for cell: Vector2i in [Vector2i(door.ax, door.ay), Vector2i(door.bx, door.by)]:
				var x := (cell.x + 0.5) * plan.cell_size
				var z := (cell.y + 0.5) * plan.cell_size
				if PropFurniture.joined(grid, baseline, prior, door.level, x, z):
					t.check(PropFurniture.joined(grid, restored, seen, door.level, x, z), "%s: door at %s" % [plan.place, cell])
		var doorway := Run.car_body(car, -0.6, 0.0)
		t.check(PropFurniture.joined(grid, restored, seen, doorway.level, doorway.x, doorway.z), "%s: lift doorway still reachable" % plan.place)
		for h in Hides.hides_for(plan):
			t.check(PropFurniture.joined(grid, restored, seen, h.level, h.front.x / 100.0, h.front.y / 100.0), "%s: hide %d still reachable" % [plan.place, h.id])
		var n_search := 0
		for p in Furniture.pieces_for(plan):
			if not p.searchable:
				continue
			var at := Vector2(Furniture.search_stand_cm(p)) / 100.0
			if PropFurniture.joined(grid, baseline, prior, p.level, at.x, at.y):
				n_search += 1
				t.check(PropFurniture.joined(grid, restored, seen, p.level, at.x, at.y), "%s: search %d still reachable" % [plan.place, p.id])
		t.check(n_search > 0, "%s: exercised actual search spots" % plan.place)

func test_full_deck_solo_enables_layout(t: T) -> void:
	var previous := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.days = false
	room.start_run()
	var link := PlayLink.new(room, true)
	var snap := {}
	for i in 5:
		snap = link.step(i * 0.05, {})
		if snap.has("plan"):
			break
	var state := room.host.state
	t.check(state.furniture_layout, "solo room uses the restored layout")
	t.check(Run.solids_in(state).boxes != Furniture.solids_of(state.plan).boxes, "solo room has the restored collision geometry")
	t.check(snap.has("plan") and snap["plan"].get("furnitureLayout") == true, "solo client received the restored layout")
	room.leave()
	Session.deck = previous

func test_dedicated_host_wire_prediction_and_geometry_agree(t: T) -> void:
	var previous := Session.deck
	Session.deck = Places.FULL
	for depth: int in [1, 3]:
		for enabled: bool in [false, true]:
			_check_network_layout(t, depth, enabled)
	Session.deck = previous

static func _check_network_layout(t: T, depth: int, enabled: bool) -> void:
	var say := func(_line: String) -> void: pass
	var ws := WsServer.new(TEST_PASSPHRASE, false, say)
	if not t.check(ws.listen(0, "127.0.0.1") == OK, "start loopback server on a free port"):
		return
	var room := Room.new(ws, say)
	room.first_depth = depth
	room.fixed_seed = "layout-0"
	room.days = false
	room.quota = false
	if not enabled:
		room.furniture_layout = false
	var client := RoomClient.new()
	var link := PlayLink.new(client, false)
	var error := client.connect_to("ws://127.0.0.1:%d" % ws._tcp.get_local_port(), TEST_PASSPHRASE, "tester")
	if t.check(error == OK, "connect to loopback server"):
		var snap := {}
		for i in 350:
			var now := i * 0.05
			ws.poll(now)
			room.update(now)
			snap = link.step(now, {})
			if client.status == "lobby" and not client.my_ready:
				client.set_ready(true)
			if snap.has("plan"):
				break
			OS.delay_msec(1)
		if t.check(snap.has("plan") and room.host != null, "client received the seeded floor from the dedicated host (room running %s, client %s)" % [room.running(), client.status]):
			_check_shared_geometry(t, room.host.state, link, snap["plan"], enabled)
	client.leave()
	ws.stop()

static func _check_shared_geometry(t: T, state: Run.RunState, link: PlayLink, plan_dict: Dictionary, enabled: bool) -> void:
	var code := Protocol.SOLID_RESTORED if enabled else Protocol.SOLID_BASELINE
	t.eq(link.rc.client.latest.get("solid"), code, "solid layout code over the wire")
	t.eq(plan_dict.get("furnitureLayout", false), enabled, "wire selects the drawn layout")
	var host_solids := Run.solids_in(state)
	var client_solids := Furniture.solids_of(link.plan, bool(plan_dict.get("furnitureLayout", false)))
	t.check(host_solids.boxes == client_solids.boxes, "host and client have the same solid geometry")
	var plan := state.plan
	var baseline := Furniture.pieces_for(plan)
	var restored := Furniture.pieces_for(plan, "", -1, true)
	var expected := restored if enabled else baseline
	var level: Node3D = LevelScript.new()
	if enabled:
		level.call("build", plan_dict, plan.seed, link.plan, link.hides)
		if plan.place == Places.ANNEX:
			t.check(is_same(level.get_meta("annex").hides, link.hides), "the view uses the same resolved hides as the room client")
	else:
		level.call("build", plan_dict, plan.seed)
	t.eq(Furniture.plain(level.get("pieces")), Furniture.plain(expected), "the client draws the host's precise furniture layout")
	var drawn: Dictionary = {}
	for row: Dictionary in level.get("furniture_drawn"):
		drawn[row["piece"]] = row["rect"]
	for p: Furniture.Piece in expected.slice(baseline.size()):
		if t.check(drawn.has(p.id), "restored %s has a visible model" % p.kind):
			var r: Rect2 = drawn[p.id]
			var foot := Rect2(Vector2(p.foot.position) / 100.0, Vector2(p.foot.size) / 100.0)
			t.check(r.position.distance_to(foot.position) < 0.05 and r.end.distance_to(foot.end) < 0.05, "%s mesh aligns with its solid footprint" % p.kind)
		var x := p.x / 100.0
		var z := p.y / 100.0
		t.eq(Move.box_clearance(host_solids, p.level, x, z), 0.0, "%s centre is solid on host" % p.kind)
	level.free()
	for p: Furniture.Piece in restored.slice(baseline.size()):
		if plan.rooms[p.room].kind != &"lobby":
			continue
		var inward := -Vector2(Furniture.dir_vec(p.wall))
		var at := Vector2(p.x, p.y) / 100.0 + inward * (p.d / 200.0 + 0.45)
		var delta := -inward * 0.6
		link.body = Move.Body.make(at.x, at.y, p.level, Move.feet_height(plan, p.level, at.x, at.y))
		var host_body := Run.move_in_run(state, link.body, delta.x, delta.y, Session.PLAYER_RADIUS)
		t.check(link.nudge(delta.x, delta.y).get("ok") == true and link.body.same(host_body), "prediction matches host collision at the lobby seating")
		var moved := Vector2(link.body.x, link.body.z).distance_to(at)
		t.check(moved < 0.3 if enabled else moved > 0.5, "the restored chair affects travel only when switched on")
		return
	t.check(false, "sample contains a lobby chair to walk into")
