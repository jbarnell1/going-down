# Live settings, piece LS2 (docs/floors/live-settings.md section 7): the desk (net/tuning_desk.gd), the file,
# who the host is (server/room.gd _settings_host_id) and the wire (the room's "tune" and "tuneNo" messages, the
# host's "tuned" event and the snapshot's tune block). Proved here:
#   1. The desk: a change is checked by Settings.check (range, pair, an unknown or unwired id), at most ten a
#      second from one connection ("busy"), snapped to the step, kept only while it differs from the game's;
#      RESET and reset all put the game's values back; the notice's words.
#   2. Holding: with a run on, a `floor` value is not in force on any tick before the run's "carLeft" and is on
#      the first tick after; a `day` value the same around "lightsOut"; `now` and `next` values at once.
#   3. The file: after a change it parses and holds only what differs; a desk made on it has the same values in
#      force; one bad entry is skipped (logged) and the rest kept; a file that does not parse changes nothing and
#      is kept as .bad at the next save; a hand edit is in force at the next look (2 s) and announced as THE
#      HOUSE; the history has one line a change; a desk without a file writes nothing.
#   4. Two real clients over WebSockets (127.0.0.1): the first in is the host; the host's change reaches both
#      with the same notice and the same list; a non-host's change is never sent by its RoomClient, and one sent
#      anyway is refused ("host") without closing the connection, as is an out-of-range one ("range"); in a run
#      the snapshots carry the host's revision and list to both clients within 2 s, the "tuned" event reaches
#      each once, and the Orderly hunts at the set speed on both screens (and back at today's after a reset);
#      the host leaving passes the key in arrival order; a server restarted on the same file has the change in
#      force on its first tick; a "tune" that is not a Dictionary closes the connection as any bad message.
extends RefCounted

const T = preload("res://tests/t.gd")
const Settings = preload("res://sim/settings.gd")
const TuningDesk = preload("res://net/tuning_desk.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Client = preload("res://net/client.gd")
const LocalRoom = preload("res://net/local_room.gd")
const SettingsPanel = preload("res://client/settings_panel.gd")

const SECRET := "settings-test-passphrase"
const DIR := "user://ls_settings_test"
const PORT_A := 4497
const PORT_B := 4498

static func _fresh_dir() -> String:
	var abs := ProjectSettings.globalize_path(DIR)
	if DirAccess.dir_exists_absolute(abs):
		for f in DirAccess.get_files_at(abs):
			DirAccess.remove_absolute(abs + "/" + f)
	else:
		DirAccess.make_dir_recursive_absolute(abs)
	return DIR

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

# ---------------------------------------------------------------------------------------------
# 1. The desk.

func test_desk_checks_and_words(t: T) -> void:
	var d := TuningDesk.new()
	var r := d.ask(&"orderly.speed", 3.61, "Jon", "c1", 0.0)
	t.eq(r[0], &"", "a fair change is taken")
	t.eq(d.asked.get(&"orderly.speed"), 3.6, "snapped to the step")
	t.eq(str(r[1]["line"]), "JON SET ORDERLY HUNT SPEED 3.80 > 3.60 M/S", "the notice's words")
	t.eq(d.rev, 1, "the revision bumps")
	t.eq(d.ask(&"orderly.speed", 9.0, "Jon", "c1", 0.0)[0], &"range", "over most: range")
	t.eq(d.ask(&"orderly.speed", NAN, "Jon", "c1", 0.0)[0], &"range", "NaN: range")
	t.eq(d.ask(&"orderly.speed", "3.6", "Jon", "c1", 0.0)[0], &"range", "a string: range")
	t.eq(d.ask(&"orderly.sped", 3.6, "Jon", "c1", 0.0)[0], &"id", "unknown: id")
	t.eq(d.ask(&"player.walk", 3.5, "Jon", "c1", 0.0)[0], &"id", "a row nothing reads yet: id")
	t.eq(d.ask(&"lift.floors_min", 13, "Jon", "c1", 0.0)[0], &"pair", "fewest floors over most: pair")
	t.eq(d.asked.get(&"orderly.speed"), 3.6, "a refused value changed nothing")
	t.eq(d.rev, 1, "and the revision stayed")
	# Ten a second from one connection, then busy; another connection is not held up.
	var busy := 0
	for k in 12:
		if d.ask(&"down.time", 11.0 + k, "Jon", "c2", 5.0)[0] == &"busy":
			busy += 1
	t.eq(busy, 2, "the eleventh and twelfth change in a second are busy")
	t.eq(d.ask(&"down.time", 30.0, "Jon", "c3", 5.0)[0], &"", "another connection is not busy")
	t.eq(d.ask(&"down.time", 31.0, "Jon", "c2", 6.1)[0], &"", "a second later it is taken again")
	# The game's value again: not kept, and the words say so.
	var back := d.ask(&"down.time", 10.0, "Jon", "c4", 7.0)
	t.check(not d.asked.has(&"down.time"), "today's value is not kept")
	t.eq(str(back[1]["line"]), "JON PUT DOWN FOR, BEFORE YOU ARE OUT BACK TO 10 S", "the reset's words")
	t.eq(d.ask(&"down.time", 10.0, "Jon", "c4", 7.0)[1], {}, "asking for what is already in force changes nothing")
	var rs := d.reset(&"orderly.speed", "Jon", "c4", 7.0)
	t.check(rs[0] == &"" and d.asked.is_empty(), "RESET puts the game's value back")
	d.ask(&"minder.run_speed", 6.0, "Jon", "c5", 8.0)
	d.ask(&"lift.floor_time", 3.0, "Jon", "c5", 8.0)
	var all := d.reset_all("Jon", "c5", 8.0)
	t.check(all[0] == &"" and d.asked.is_empty() and d.in_force().is_empty(), "reset all empties the list")
	t.eq(str(all[1]["line"]), "JON PUT EVERY SETTING BACK", "reset all's words")
	t.eq(d.join_line(), "", "nothing changed: no join line")
	d.ask(&"orderly.speed", 3.5, "Jon", "c6", 9.0)
	t.eq(d.join_line(), "1 SETTING IS CHANGED TONIGHT. F8 TO SEE.", "a joiner's line")
	t.eq(TuningDesk.line_for({"kind": "set", "by": "Jon", "id": "player.sprint", "was": 5.0, "v": 5.5, "when": "floor"}),
		"JON SET SPRINT 5.0 > 5.5 M/S. FROM THE NEXT FLOOR.", "a value that waits says so")
	t.eq(TuningDesk.line_for({"kind": "house", "id": "down.time", "was": 10.0, "v": 14.0, "when": "next"}), "THE HOUSE SET DOWN FOR, BEFORE YOU ARE OUT 10 > 14 S", "a hand edit's words")

# ---------------------------------------------------------------------------------------------
# 2. Holding: floor values wait for the car to leave, day values for lights out.

## A run that steps nothing but the clock, and says "carLeft" on tick `car_at` and "lightsOut" on `lights_at`.
class Script_:
	var car_at := 0
	var lights_at := 0
	var n := 0

	func step(s: Run.RunState, _inputs: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
		n += 1
		var r := Run.RunStep.new()
		var ns := s.copy()
		ns.t = s.t + dt
		r.state = ns
		if n == car_at:
			r.events.append({"type": "carLeft", "t": ns.t, "reason": "down"})
		if n == lights_at:
			r.events.append({"type": "lightsOut", "t": ns.t})
		return r

class Pipes:
	var hp: Transport.Pipe

	func _init() -> void:
		hp = Transport.Pipe.new("host", func(_to: String, _d: String) -> void: pass, func(_d: String) -> void: pass)

func test_floor_and_day_values_wait_for_the_car_and_the_night(t: T) -> void:
	var d := TuningDesk.new()
	d.accept_unwired = true
	var sc := Script_.new()
	sc.car_at = 40
	sc.lights_at = 80
	var pipes := Pipes.new()
	var roster: Array[String] = ["p0"]
	var host := Host.new(pipes.hp, "ls2-hold", roster, 0.0, Callable(), Callable(sc, "step"))
	d.run_started()
	host.set_tuning(d.in_force(), d.rev)
	var seen := []  # per tick: [walk in force, day.first in force, down.time in force]
	host.on_tick = func(events: Array) -> void:
		if d.on_events(events):
			host.set_tuning(d.in_force(), d.rev)
	var asked_at := 10
	for k in 100:
		if k == asked_at:
			# Between two ticks: a floor value, a day value and a `next` value.
			for a: Array in [[&"player.walk", 3.5], [&"day.first", 2.0], [&"down.time", 20.0]]:
				var res := d.ask(a[0], a[1], "Jon", "", 0.0)
				t.eq(res[0], &"", "%s taken" % a[0])
				host.set_tuning(d.in_force(), d.rev, res[1])
		# What step k + 1 reads: the state's tuning before it.
		var tu := host.state.tuning
		host.update((k + 1) * Host.TICK + 1e-6)
		seen.append([Settings.f(tu, &"player.walk", -1.0), Settings.f(tu, &"day.first", -1.0), Settings.f(tu, &"down.time", -1.0)])
	# seen[k] is what step k + 1 read; the carLeft tick is step 40, so the walk is read from step 41 (seen[40]).
	var bad := 0
	for k in seen.size():
		var walk_want := 3.5 if k >= sc.car_at else -1.0
		var day_want := 2.0 if k >= sc.lights_at else -1.0
		var down_want := 20.0 if k >= asked_at else -1.0
		if seen[k][0] != walk_want or seen[k][1] != day_want or seen[k][2] != down_want:
			bad += 1
			if bad <= 3:
				t.check(false, "tick %d: walk %s (want %s), day %s (want %s), down %s (want %s)" % [k + 1, seen[k][0], walk_want, seen[k][1], day_want, seen[k][2], down_want])
	t.eq(bad, 0, "ticks with the wrong values in force")
	t.check(d.waiting().is_empty(), "nothing waits once the car has left and the lights are out")
	var tuned := 0
	for le in host.event_log:
		if str(le.e.get("type")) == "tuned":
			tuned += 1
	t.eq(tuned, 3, "one tuned event a change")
	t.note("asked on tick %d: the down timer in force from tick %d, the walk from the tick after carLeft (%d), DAY 1 OWES after lightsOut (%d)" % [asked_at + 1, asked_at + 1, sc.car_at + 1, sc.lights_at + 1])

# ---------------------------------------------------------------------------------------------
# 3. The file.

func test_the_file(t: T) -> void:
	var dir := _fresh_dir()
	var path := dir + "/settings.json"
	var d := TuningDesk.new(path)
	t.check(not FileAccess.file_exists(path), "no file until a change")
	d.ask(&"orderly.speed", 3.6, "Jon", "", 0.0)
	d.ask(&"down.time", 14, "Jon", "", 0.0)
	d.ask(&"down.time", 10, "Jon", "", 0.0)
	var j: Variant = _read_json(path)
	t.check(j is Dictionary and int(j["v"]) == 1 and int(j["rev"]) == 3 and str(j["by"]) == "Jon", "the file parses: %s" % str(j))
	t.eq((j as Dictionary).get("set"), {"orderly.speed": 3.6}, "it holds only what differs from the game's")
	t.check(not FileAccess.file_exists(path + ".tmp"), "no .tmp left behind")
	var log_lines := FileAccess.get_file_as_string(path + ".log").strip_edges().split("\n")
	t.eq(log_lines.size(), 3, "the history has one line a change")
	t.check(log_lines[0].ends_with("Jon\torderly.speed\t3.80\t3.60"), "a history line: %s" % log_lines[0])
	var d2 := TuningDesk.new(path)
	t.eq(d2.in_force(), {&"orderly.speed": 3.6}, "a desk made on the file has the same values in force")
	t.eq(d2.rev, 3, "and its revision")
	# One bad entry: skipped and logged, the rest kept.
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "rev": 7, "set": {"orderly.speed": 9.0, "down.time": 14, "orderly.sped": 3.0, "minder.run_speed": "fast"}}))
	f.close()
	var d3 := TuningDesk.new(path)
	t.eq(d3.in_force(), {&"down.time": 14.0}, "the good entry is kept")
	t.check(d3.logged.size() == 3 and d3.logged.any(func(l: String) -> bool: return l.contains("orderly.speed 9") and l.contains("outside 2.40 to 4.80")), "each bad one is logged: %s" % str(d3.logged))
	# A file that does not parse: nothing changes; kept as .bad at the next save.
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{not json")
	f.close()
	var d4 := TuningDesk.new(path)
	t.check(d4.asked.is_empty() and d4.logged.size() == 1 and d4.logged[0].contains("does not parse"), "a file that does not parse changes nothing: %s" % str(d4.logged))
	d4.ask(&"orderly.speed", 3.5, "Jon", "", 0.0)
	t.eq(FileAccess.get_file_as_string(path + ".bad"), "{not json", "kept as .bad at the next save")
	t.eq((_read_json(path) as Dictionary).get("set"), {"orderly.speed": 3.5}, "and the new file written")
	# A hand edit: in force at the next look, announced as THE HOUSE.
	OS.delay_msec(1100)
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"v": 1, "rev": 2, "set": {"orderly.speed": 3.5, "down.time": 20}}))
	f.close()
	var rev0 := d4.rev
	var notes: Array[Dictionary] = d4.poll(3.5)
	t.check(notes.size() == 1 and str(notes[0]["line"]) == "THE HOUSE SET DOWN FOR, BEFORE YOU ARE OUT 10 > 20 S", "the hand edit is announced: %s" % str(notes))
	t.eq(d4.in_force(), {&"orderly.speed": 3.5, &"down.time": 20.0}, "and in force")
	t.check(d4.rev > rev0, "the revision bumps (%d > %d)" % [d4.rev, rev0])
	# A desk without a file writes nothing.
	var none := TuningDesk.new()
	none.ask(&"orderly.speed", 3.6, "Jon", "", 0.0)
	t.check(none.path.is_empty() and none.saved_at.is_empty(), "a desk without a file writes nothing")

# ---------------------------------------------------------------------------------------------
# 4. Two clients over the network.

class Net:
	var ws: WsServer
	var room: Room
	var said: Array[String] = []
	var now := 0.0
	var clients: Array = []

	func _init(port: int, settings: String) -> void:
		var say := func(l: String) -> void: said.append(l)
		ws = WsServer.new(SECRET, false, say)
		ws.listen(port, "127.0.0.1")
		room = Room.new(ws, say)
		if not settings.is_empty():
			room.desk = TuningDesk.new(settings, say)
		room.fixed_seed = "ls2-net"
		room.days = false
		room.quota = false
		room.relocation = false
		room.watchers = false

	func join(port: int, name: String) -> RoomClient:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
		clients.append(rc)
		return rc

	## Runs `secs` of room time (or until `until` returns true), every client sending a frame.
	func run(secs: float, until: Callable = Callable()) -> bool:
		var end := now + secs
		while now < end:
			now += 0.02
			ws.poll(now)
			room.update(now)
			for rc: RoomClient in clients:
				rc.poll(now)
				if rc.client != null and rc.status == "running":
					rc.frame(now, _local(rc))
			if until.is_valid() and until.call():
				return true
			OS.delay_msec(3)
		return false

	## On the landing just out of the car (the first player on the left, the second on the right), looking into the
	## car (so the Orderly is never in its view).
	func _local(rc: RoomClient) -> Client.LocalFrame:
		var lf := Client.LocalFrame.new()
		var c := rc.client
		lf.body = Move.Body.make(0.0, 0.0, 0, 0.0)
		if c.latest != null:
			for p: Dictionary in c.latest["players"]:
				if p["id"] == c.id:
					lf.body = p["body"]
		var s := room.host.state if room.host != null else null
		if s != null:
			lf.yaw = Entity.yaw_toward(s.car.in_x, s.car.in_z)
			lf.body = Run.car_body(s.car, -1.0, -0.5 if clients.find(rc) == 0 else 0.5)
		lf.eye = 1.65
		lf.h_fov_deg = 90.0
		lf.v_fov_deg = 70.0
		return lf

	func stop() -> void:
		for rc: RoomClient in clients:
			if rc.status != "closed":
				rc.leave()
		run(0.2)
		ws.stop()

## The Orderly hunting from the walkable cell furthest from the landing (the room's run).
static func hunt_from_far(room: Room) -> void:
	var s := room.host.state
	var plan := s.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var best := -1
	for i in dist.size():
		if dist[i] > (dist[best] if best >= 0 else -1) and Floor.pos_from_index(plan, i).level == plan.landing.level:
			best = i
	var o := Places.create_resident(plan)
	o.body = Move.body_at_cell(plan, Floor.pos_from_index(plan, best))
	o.mode = &"hunting"
	o.replan_in = 0.0
	room.host.replace_orderly(o)

## The fastest the Orderly was drawn hunting on each client's screen over `secs` of room time.
static func top_speed(net: Net, secs: float) -> PackedFloat64Array:
	var top := PackedFloat64Array()
	top.resize(net.clients.size())
	var end := net.now + secs
	while net.now < end:
		net.run(0.1)
		for i in net.clients.size():
			var rc: RoomClient = net.clients[i]
			if rc.client != null and rc.client.latest != null:
				var o: Dictionary = rc.client.latest["orderly"]
				if str(o["mode"]) == "hunting":
					top[i] = maxf(top[i], float(o["speed"]))
	return top

func test_two_clients_over_the_network(t: T) -> void:
	var dir := _fresh_dir()
	var path := dir + "/settings.json"
	var net := Net.new(PORT_A, path)
	var a := net.join(PORT_A, "Ann")
	net.run(3.0, func() -> bool: return a.status == "lobby" and a.tune_host != "")
	var b := net.join(PORT_A, "Bob")
	# Bob is on a slow link: everything he sends and gets is 0.15 s late.
	b.delay = 0.15
	net.run(3.0, func() -> bool: return b.status == "lobby" and b.tune_host != "")
	t.check(a.is_host() and not b.is_host() and b.tune_host == a.my_id, "the first in is the host (%s, %s)" % [a.tune_host, b.tune_host])
	t.eq(net.room._settings_host_id(), a.my_id, "the room's one host function agrees")
	# The host's change: both get the same line and the same list.
	t.check(a.tune_set(&"orderly.speed", 3.6), "the host's change is sent")
	net.run(2.0, func() -> bool: return not a.tune_lines.is_empty() and not b.tune_lines.is_empty())
	var line := "ANN SET ORDERLY HUNT SPEED 3.80 > 3.60 M/S"
	t.check(Array(a.tune_lines) == [line] and Array(b.tune_lines) == [line], "both show the notice word for word: %s / %s" % [str(a.tune_lines), str(b.tune_lines)])
	t.check(a.tune_asked == {&"orderly.speed": 3.6} and b.tune_asked == a.tune_asked, "both hold the same list: %s / %s" % [str(a.tune_asked), str(b.tune_asked)])
	# A non-host: its RoomClient never sends; one sent anyway is refused and nothing changes.
	t.check(not b.tune_set(&"orderly.speed", 2.5), "the non-host's RoomClient does not send")
	b._queue("m|" + JSON.stringify({"t": "tune", "id": "orderly.speed", "v": 2.5}))
	a._queue("m|" + JSON.stringify({"t": "tune", "id": "orderly.speed", "v": 9.0}))
	net.run(2.0, func() -> bool: return not b.tune_refusals.is_empty() and not a.tune_refusals.is_empty())
	t.check(b.tune_refusals.size() == 1 and b.tune_refusals[0]["why"] == "host", "a non-host's change is refused: %s" % str(b.tune_refusals))
	t.check(a.tune_refusals.size() == 1 and a.tune_refusals[0]["why"] == "range", "an out-of-range one is refused: %s" % str(a.tune_refusals))
	t.check(a.status == "lobby" and b.status == "lobby", "neither connection closed (%s, %s)" % [a.status, b.status])
	t.eq(net.room.desk.asked, {&"orderly.speed": 3.6}, "the refusals changed nothing")
	t.eq((_read_json(path) as Dictionary).get("set"), {"orderly.speed": 3.6}, "the server's file holds the change")
	# A run: both screens get the revision and the list, and the Orderly hunts at 3.60.
	a.start_run()
	net.run(5.0, func() -> bool: return a.client != null and b.client != null and a.client.tune_rev == net.room.desk.rev and b.client.tune_rev == net.room.desk.rev)
	t.check(a.client != null and b.client != null, "both are in the run")
	if a.client == null or b.client == null:
		net.stop()
		return
	t.check(a.client.tune_in_force == {&"orderly.speed": 3.6} and b.client.tune_in_force == a.client.tune_in_force, "both hold the run's list: %s / %s" % [str(a.client.tune_in_force), str(b.client.tune_in_force)])
	t.eq(Settings.f(net.room.host.state.tuning, &"orderly.speed", -1.0), 3.6, "the run has it in force from its first tick")
	net.run(2.0)
	hunt_from_far(net.room)
	var slow := top_speed(net, 3.0)
	# Back to today's (a change during the run: in force at once, with a tuned event to everyone).
	t.check(a.tune_reset(&"orderly.speed"), "the host's reset is sent")
	net.run(1.0)
	hunt_from_far(net.room)
	var fast := top_speed(net, 3.0)
	for i in 2:
		t.check(absf(slow[i] - 3.6) < 0.02, "client %d: the Orderly was drawn hunting at %.3f m/s, set to 3.60" % [i, slow[i]])
		t.check(absf(fast[i] - Run.PACED_HUNT_SPEED) < 0.02, "client %d: after the reset at %.3f m/s, today's %.2f" % [i, fast[i], Run.PACED_HUNT_SPEED])
	for rc: RoomClient in [a, b]:
		var tuned := rc.client.events.filter(func(e: Dictionary) -> bool: return e.get("type") == "tuned")
		t.check(tuned.size() == 1 and str(tuned[0]["line"]) == "ANN PUT ORDERLY HUNT SPEED BACK TO 3.80 M/S" and float(tuned[0]["was"]) == 3.6 and float(tuned[0]["v"]) == 3.8,
			"%s: the tuned event once, with the old and the new value: %s" % [rc.my_id, str(tuned)])
	t.check(b.tune_lines.size() == 2 and b.tune_lines[1] == "ANN PUT ORDERLY HUNT SPEED BACK TO 3.80 M/S", "the reset's notice: %s" % str(b.tune_lines))
	# Set again, for the restart.
	a.tune_set(&"down.time", 14.0)
	net.run(1.0)
	# The host leaves: the key passes in arrival order.
	a.leave()
	net.run(2.0, func() -> bool: return b.tune_host == b.my_id)
	t.check(b.is_host(), "the host left: the next in arrival order holds the key (%s)" % b.tune_host)
	t.check(b.tune_set(&"orderly.dark_speed", 3.5), "and their change is sent")
	net.run(1.0)
	t.eq(net.room.desk.asked.get(&"orderly.dark_speed"), 3.5, "and taken")
	# A tune that is not a Dictionary closes the connection, as any bad room message.
	b._queue("m|[1,2]")
	net.run(1.0, func() -> bool: return b.status == "closed")
	t.eq(b.status, "closed", "a message that is not a Dictionary closes the connection")
	net.stop()
	var saved: Variant = _read_json(path)
	t.eq((saved as Dictionary).get("set"), {"down.time": 14.0, "orderly.dark_speed": 3.5}, "the file after the night")
	# A restarted server on the same file: in force on the run's first tick, and in a joiner's list.
	var net2 := Net.new(PORT_B, path)
	var c := net2.join(PORT_B, "Cat")
	net2.run(3.0, func() -> bool: return c.status == "lobby" and c.tune_host != "")
	t.check(c.tune_asked == {&"down.time": 14.0, &"orderly.dark_speed": 3.5}, "the restarted server's list reaches a joiner: %s" % str(c.tune_asked))
	t.check(c.tune_lines.size() == 1 and c.tune_lines[0] == "2 SETTINGS ARE CHANGED TONIGHT. F8 TO SEE.", "with the join line: %s" % str(c.tune_lines))
	c.start_run()
	net2.run(3.0, func() -> bool: return net2.room.host != null)
	net2.run(0.5)
	t.check(net2.room.host != null and Settings.f(net2.room.host.state.tuning, &"down.time", -1.0) == 14.0, "the restarted server's run has it in force")
	if net2.room.host != null:
		var first := net2.room.host.state_at(1)
		t.check(first != null and Settings.f(first.tuning, &"orderly.dark_speed", -1.0) == 3.5, "on its first tick")
	net2.stop()
	var leaks := net.said.filter(func(l: String) -> bool: return l.contains(SECRET))
	t.check(leaks.is_empty(), "no server line holds the passphrase")
	t.note("over WebSockets: host %s; the Orderly drawn at %.2f then %.2f m/s; file %s" % [a.my_id, slow[1], fast[1], JSON.stringify((saved as Dictionary).get("set"))])

# ---------------------------------------------------------------------------------------------
# 5. Playing alone (LS3): the local room's own desk, the player its host; and the panel's rows.

func _alone(file: String) -> LocalRoom:
	var lr := LocalRoom.new()
	lr.open_local("ls3-alone", "Solo", true)
	lr.open_settings(file)
	lr.start_run()
	return lr

func test_playing_alone(t: T) -> void:
	var dir := _fresh_dir()
	var path := dir + "/settings.json"
	var lr := _alone(path)
	t.check(lr.is_host() and lr.tune_asked.is_empty() and lr.tune_file, "alone you are the host, nothing changed, a file to keep it in")
	var now := 0.0
	for _k in 10:
		now += 0.05
		lr.poll(now)
	var tick0 := lr.host.tick
	t.check(lr.tune_set(&"orderly.speed", 3.5), "a change alone")
	t.eq(Settings.f(lr.host.state.tuning, &"orderly.speed", -1.0), 3.5, "in force for the next tick")
	t.check(Array(lr.tune_lines).has("SOLO SET ORDERLY HUNT SPEED 3.80 > 3.50 M/S"), "the notice: %s" % str(lr.tune_lines))
	now += 0.06
	lr.poll(now)
	t.check(lr.host.tick > tick0 and lr.client.tune_rev == lr.desk.rev, "the run went on with it, and the client has the revision (%d of %d)" % [lr.client.tune_rev, lr.desk.rev])
	lr.leave()
	# Closing the game: the next session reads the file.
	var again := _alone(path)
	t.eq(again.tune_asked, {&"orderly.speed": 3.5}, "the change survives closing the game")
	t.eq(Settings.f(again.host.state.tuning, &"orderly.speed", -1.0), 3.5, "and is in force from the first tick")
	t.check(Array(again.tune_lines).has("1 SETTING IS CHANGED TONIGHT. F8 TO SEE."), "with the join line: %s" % str(again.tune_lines))
	again.leave()
	# Under automation (auto=1) the game gives no file: the saved change is not read, nothing is in force.
	var auto := _alone("")
	t.check(auto.tune_asked.is_empty() and auto.host.state.tuning == null and auto.host.tune_rev == 0 and not auto.tune_file, "automated: the saved file is ignored, the run untuned")
	auto.leave()

func test_the_panel_reads_the_registry(t: T) -> void:
	var lr := _alone("")
	var p := SettingsPanel.new()
	p._build()
	p.rc = lr
	var d := p.describe()
	var want: Array = []
	for s in Settings.list(true):
		want.append(String(s.id))
	var got: Array = []
	for r: Dictionary in d["rows"]:
		got.append(r["id"])
	t.eq(got, want, "the panel's rows are the registry's wired rows, in its order, group by group")
	t.check(d["host"] == true and d["top"] == "HOST SETTINGS", "alone, the panel is live")
	# A pair-breaking arrow is grey: FEWEST FLOORS one under MOST cannot go up.
	lr.tune_set(&"lift.floors_min", 11)
	t.check(not p.can_step(&"lift.floors_min", 1) and p.can_step(&"lift.floors_min", -1), "the arrow that would break a pair rule is grey")
	# RESET and reset all.
	t.check(p.reset_row(&"lift.floors_min") and lr.tune_asked.is_empty(), "RESET puts the row back")
	lr.tune_set(&"orderly.speed", 3.5)
	lr.tune_set(&"down.time", 20)
	var r := p.row_words(Settings.row(&"orderly.speed"))
	t.eq(r[0], "* 3.50 M/S", "the changed marker and the value")
	t.eq(r[1], "WAS 3.80", "and what it was")
	t.check(p.reset_all() and lr.tune_asked.is_empty() and lr.desk.in_force().is_empty(), "reset all empties the list")
	# A drag is one change: the value moves while dragging and is sent once, on letting go.
	var rev0 := lr.desk.rev
	p._drag = &"orderly.speed"
	p._pending[&"orderly.speed"] = 3.4
	p._pending[&"orderly.speed"] = 3.3
	p._pending[&"orderly.speed"] = 3.2
	p._drag = &""
	p._send_pending()
	t.eq(lr.desk.rev, rev0 + 1, "a drag sends one change")
	t.eq(lr.tune_asked.get(&"orderly.speed"), 3.2, "the value let go at")
	# A waiting value (a `floor` setting, LS2's made-up one): the panel shows the value in force and that it waits.
	lr.desk.accept_unwired = true
	lr.tune_set(&"player.walk", 3.5)
	var w := p.row_words(Settings.row(&"player.walk"))
	t.check(str(w[3]) == "FROM THE NEXT FLOOR. NOW 3.0", "a waiting value says so, with the value in force: %s" % str(w))
	p.free()
	lr.leave()