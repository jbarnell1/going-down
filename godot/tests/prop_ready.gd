# Ready-up on the server (docs/floors/findables-and-day.md section 2, FD5; server/room.gd, net/host.gd
# admit_only). The real room, behind a stand-in for the WebSocket door that records what is sent and when:
#   - a run never starts with a player in it who has not sent ready (seeded random lobbies: joins, leaves,
#     ready, un-ready, START from anyone at any time), and it starts exactly when the rules say: everyone
#     ready for the 5 s count, or the host's START WITHOUT;
#   - every ready player's first run message (the lobby saying the run is on) is sent on the same update;
#   - un-ready or a new arrival during the count stops it; the host leaving passes the host on in arrival order;
#   - START WITHOUT is refused from anyone but the host, and before 30 s;
#   - a newcomer who is not ready is not admitted at a stop, and is at the first stop after they ready;
#   - the server still writes no file.
# Run alone: npm run godot:test -- prop_ready
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Room = preload("res://server/room.gd")
const WsServer = preload("res://net/ws_server.gd")
const Protocol = preload("res://net/protocol.gd")

## The door, without sockets: the test pushes its events; everything sent is kept with the room's update number.
class FakeDoor extends WsServer:
	var room: Object = null
	## [update, id, text] in order.
	var sent: Array = []
	var kicked: Array = []

	func _init() -> void:
		super._init("unused-test-secret", true, func(_s: String) -> void: pass)

	func send(id: String, text: String) -> void:
		sent.append([int(room.get("updates")) if room != null else 0, id, text])

	func kick(id: String, code: int, reason: String) -> void:
		kicked.append([id, code, reason])

	func joined(id: String, name: String) -> void:
		events.append({"kind": "joined", "id": id, "name": name})

	func left(id: String) -> void:
		events.append({"kind": "left", "id": id})

	func msg(id: String, data: String) -> void:
		events.append({"kind": "message", "id": id, "data": data})

static func _room() -> Room:
	var door := FakeDoor.new()
	var room := Room.new(door, func(_s: String) -> void: pass)
	door.room = room
	# A run that never ends by itself in these tests, and the floor quota off (nothing here plays).
	room.fixed_seed = "ready-1"
	room.quota = false
	return room

static func _door(room: Room) -> FakeDoor:
	return room._ws as FakeDoor

static func _ready_msg(on: bool) -> String:
	return "m|" + JSON.stringify({"t": "ready", "on": on})

const START := "m|{\"t\":\"start\"}"

## The roster of the run now on (player ids in the host's list at its start).
static func _roster(room: Room) -> Array[String]:
	var out: Array[String] = []
	for p in room.host.state.players:
		out.append(p.id)
	return out

# ---- the seeded lobbies ---------------------------------------------------------------------------

## One seeded lobby: random arrivals, leaves, readies, un-readies and STARTs, with an oracle of the rules.
## Returns what it saw.
static func _lobby(t: T, seed_text: String, steps: int) -> Dictionary:
	var rng := Rng.make_rng(seed_text)
	var room := _room()
	var door := _door(room)
	var now := 0.0
	var next_id := 1
	var order: Array[String] = []     # the test's own arrival order
	var ready_at := {}                # id -> when they readied (the oracle's)
	var count_from := -1.0            # when everyone was last all ready with nobody new since (oracle)
	var seen := {"runs": 0, "counted": 0, "without": 0, "refused": 0, "stopped": 0, "hostPassed": 0}
	var bad := 0
	for step in steps:
		# Steps of 1/8 s: exact in binary, so the oracle's sums and the room's agree to the bit.
		now += 0.125
		var host_before := order[0] if not order.is_empty() else ""
		var arrived := false
		var start_from := ""
		var r := rng.next()
		if room.host == null:
			if r < 0.05 and order.size() < 6:
				var id := "c%d" % next_id
				next_id += 1
				door.joined(id, "P%d" % next_id)
				order.append(id)
				arrived = true
			elif r < 0.08 and not order.is_empty():
				var id: String = order[rng.int_in(0, order.size() - 1)]
				door.left(id)
				order.erase(id)
				ready_at.erase(id)
			elif r < 0.25 and not order.is_empty():
				var id: String = order[rng.int_in(0, order.size() - 1)]
				door.msg(id, _ready_msg(true))
				if not ready_at.has(id):
					ready_at[id] = now
			elif r < 0.29 and not order.is_empty():
				var id: String = order[rng.int_in(0, order.size() - 1)]
				door.msg(id, _ready_msg(false))
				if ready_at.has(id) and count_from >= 0.0:
					seen["stopped"] += 1
				ready_at.erase(id)
			elif r < 0.33 and not order.is_empty():
				start_from = order[rng.int_in(0, order.size() - 1)]
				door.msg(start_from, START)
		elif r < 0.05:
			room._end_run()
			ready_at.clear()
		# The oracle, before the update: the count, and what may start this update.
		var all_ready := not order.is_empty()
		for id in order:
			all_ready = all_ready and ready_at.has(id)
		var host_now := order[0] if not order.is_empty() else ""
		if host_before != "" and host_now != host_before and host_before not in order:
			seen["hostPassed"] += 1
		if arrived or not all_ready or room.host != null:
			count_from = -1.0
		var expect_without := start_from != "" and start_from == host_now and ready_at.has(host_now) and now - float(ready_at[host_now]) >= Room.WITHOUT_AFTER
		var expect_count := count_from >= 0.0 and now >= count_from + Room.COUNT
		var was_running := room.host != null
		var sent0 := door.sent.size()
		room.update(now)
		if all_ready and count_from < 0.0 and room.host == null and not was_running:
			count_from = now
		t.check(room.host_id == host_now, "%s step %d: the host is the first in arrival order (room %s, want %s)" % [seed_text, step, room.host_id, host_now])
		if start_from != "" and not expect_without and room.host != null and not was_running and not expect_count:
			bad += 1
			t.check(false, "%s step %d: START from %s (host %s) started a run the rules refuse" % [seed_text, step, start_from, host_now])
		if start_from != "" and not expect_without and not was_running:
			seen["refused"] += 1
		if room.host != null and not was_running:
			seen["runs"] += 1
			seen["counted" if expect_count else "without"] += 1
			t.check(expect_count or expect_without, "%s step %d: a run started with neither the count done nor the host's START WITHOUT" % [seed_text, step])
			var roster := _roster(room)
			for id in roster:
				t.check(ready_at.has(id), "%s step %d: %s is in the run without having sent ready" % [seed_text, step, id])
			for id in order:
				if ready_at.has(id):
					t.check(id in roster, "%s step %d: ready %s was left out of the run" % [seed_text, step, id])
			# Every ready player's first run message: the lobby saying the run is on, all on this update.
			var first := {}
			for i in range(sent0, door.sent.size()):
				var e: Array = door.sent[i]
				if str(e[2]).contains("\"running\":true") and not first.has(e[1]):
					first[e[1]] = int(e[0])
			for id in roster:
				t.check(first.get(id, -1) == room.updates, "%s step %d: %s was told the run is on on update %s, not this one (%d)" % [seed_text, step, id, str(first.get(id, -1)), room.updates])
			ready_at.clear()
			count_from = -1.0
		elif room.host == null and expect_count:
			t.check(false, "%s step %d: everyone ready for the count and no run" % [seed_text, step])
		if bad > 4:
			break
	return seen

func test_a_run_never_starts_with_a_player_who_is_not_ready(t: T) -> void:
	var lobbies := 12 if t.quick else 60
	var total := {"runs": 0, "counted": 0, "without": 0, "refused": 0, "stopped": 0, "hostPassed": 0}
	for k in lobbies:
		var seen := _lobby(t, "ready-lobby-%d" % k, 3000)
		for key: String in total:
			total[key] += int(seen[key])
	t.note("%d lobbies: %s" % [lobbies, JSON.stringify(total)])
	t.check(total["counted"] > 0 and total["without"] > 0, "not vacuous: runs started by the count and by START WITHOUT (%s)" % JSON.stringify(total))
	t.check(total["refused"] > 10 and total["stopped"] > 0 and total["hostPassed"] > 0, "not vacuous: refused STARTs, stopped counts and a host passed on (%s)" % JSON.stringify(total))

# ---- the count, by hand ---------------------------------------------------------------------------

func test_the_count_and_what_stops_it(t: T) -> void:
	var room := _room()
	var door := _door(room)
	door.joined("c1", "Ann")
	door.joined("c2", "Bob")
	room.update(0.0)
	t.eq(room.host_id, "c1", "the first in the room is the host")
	door.msg("c1", _ready_msg(true))
	room.update(0.1)
	t.eq(room.start_at, -1.0, "one of two ready: no count")
	door.msg("c2", _ready_msg(true))
	room.update(0.2)
	t.check(absf(room.start_at - 5.2) < 1e-9, "everyone ready: a 5 s count (ends %.2f)" % room.start_at)
	var lob: Dictionary = _last_lobby(door, "c2")
	t.check(absf(float(lob.get("startAt", -1.0)) - 5.2) < 1e-9 and str(lob.get("host", "")) == "c1", "the lobby carries startAt and the host (%s)" % JSON.stringify(lob))
	t.check((lob["people"] as Array).all(func(row: Array) -> bool: return row.size() >= 3 and row[2] == true), "the people rows carry the ready flag (%s)" % JSON.stringify(lob["people"]))
	# Un-ready during the count stops it; ready again starts it from 5.
	door.msg("c2", _ready_msg(false))
	room.update(2.0)
	t.eq(room.start_at, -1.0, "un-ready during the count stops it")
	door.msg("c2", _ready_msg(true))
	room.update(2.1)
	t.check(absf(room.start_at - 7.1) < 1e-9, "ready again: the count starts again from 5 (ends %.2f)" % room.start_at)
	# A new arrival stops it, even if they ready on the same update.
	door.joined("c3", "Cy")
	door.msg("c3", _ready_msg(true))
	room.update(3.0)
	t.check(room.start_at < 0.0 or absf(room.start_at - 8.0) < 1e-9, "a new arrival stops the count; it starts again from 5 once all are ready (ends %.2f)" % room.start_at)
	t.check(room.host == null, "no run yet")
	room.update(7.9)
	t.check(room.host == null, "no run before the new count ends")
	room.update(8.0)
	t.check(room.host != null and _roster(room).size() == 3, "the run starts when the count ends, with all three")
	# The host leaving passes the host on in arrival order.
	door.left("c1")
	room.update(8.1)
	t.eq(room.host_id, "c2", "the host left: the next in arrival order is the host")
	door.left("c2")
	room.update(8.2)
	t.eq(room.host_id, "c3", "and again")

static func _last_lobby(door: FakeDoor, id: String) -> Dictionary:
	for i in range(door.sent.size() - 1, -1, -1):
		var e: Array = door.sent[i]
		if e[1] == id and str(e[2]).begins_with("m|") and str(e[2]).contains("\"t\":\"lobby\""):
			return JSON.parse_string(str(e[2]).substr(2))
	return {}

# ---- START WITHOUT --------------------------------------------------------------------------------

func test_start_without_is_the_hosts_alone_and_only_after_30_s(t: T) -> void:
	var room := _room()
	var door := _door(room)
	door.joined("c1", "Ann")
	door.joined("c2", "Bob")
	door.joined("c3", "Cy")
	room.update(0.0)
	# Not ready: the host's START does nothing.
	door.msg("c1", START)
	room.update(40.0)
	t.check(room.host == null, "START from a host who is not ready is refused")
	door.msg("c1", _ready_msg(true))
	door.msg("c2", _ready_msg(true))
	room.update(50.0)
	# Bob is ready (for longer than 30 s by the end), but not the host.
	door.msg("c2", START)
	room.update(85.0)
	t.check(room.host == null, "START from a player who is not the host is refused, ready or not")
	door.msg("c3", START)
	room.update(85.5)
	t.check(room.host == null, "START from a player still reading is refused")
	t.check(_door(room).kicked.is_empty(), "and nobody is kicked for it")
	var lob := _last_lobby(door, "c1")
	t.check(absf(float(lob.get("withoutAt", -1.0)) - 80.0) < 1e-9, "the lobby says when the host may start without (%s)" % str(lob.get("withoutAt")))
	# The host readied at 50: refused at 79.9, taken at 80.
	var r2 := _room()
	var d2 := _door(r2)
	d2.joined("c1", "Ann")
	d2.joined("c2", "Bob")
	r2.update(0.0)
	d2.msg("c1", _ready_msg(true))
	r2.update(50.0)
	d2.msg("c1", START)
	r2.update(79.9)
	t.check(r2.host == null, "the host's START 29.9 s after readying is refused")
	d2.msg("c1", START)
	r2.update(80.0)
	t.check(r2.host != null, "the host's START 30 s after readying starts the run")
	if r2.host != null:
		t.eq(_roster(r2), ["c1"] as Array[String], "with the ready players only")
		t.check(not r2.in_run("c2"), "the player still reading is not in it")

# ---- late joiners ---------------------------------------------------------------------------------

func test_a_newcomer_is_admitted_only_once_ready(t: T) -> void:
	var room := _room()
	var door := _door(room)
	door.joined("c1", "Ann")
	room.update(0.0)
	door.msg("c1", _ready_msg(true))
	room.update(0.1)
	room.update(5.1)
	t.check(room.host != null, "Ann's run is on")
	if room.host == null:
		return
	# Bob joins mid-run: his client joins the run as a spectator (net/room_client.gd), not ready.
	door.joined("c2", "Bob")
	room.update(6.0)
	door.msg("c2", "n%d|%s" % [room.epoch, Protocol.encode({"type": "join", "name": "Bob", "ct": 0.0})])
	room.update(6.1)
	var hp: Variant = room.host._players.get("c2")
	t.check(hp != null and not bool(hp.in_run), "Bob is a spectator, waiting")
	# A stop (the car arrives): the host admits who it may.
	var s := room.host._admit(room.host.state)
	t.check(not _has(s, "c2"), "not ready: Bob is not admitted at this stop")
	t.check(not room.in_run("c2"), "and stays out")
	door.msg("c2", _ready_msg(true))
	room.update(6.2)
	room.host.state = room.host._admit(room.host.state)
	t.check(_has(room.host.state, "c2") and room.in_run("c2"), "ready: Bob is admitted at the first stop after")
	room.update(8.5)
	var lob := _last_lobby(door, "c1")
	var row_b: Array = []
	for row: Array in lob.get("people", []):
		if row[0] == "c2":
			row_b = row
	t.check(row_b.size() >= 5 and row_b[4] == true, "the lobby says Bob is in the run now (%s)" % str(row_b))
	t.check(int(lob.get("depth", -1)) >= 1, "and on which floor the run is (%s)" % str(lob.get("depth")))

static func _has(s: Object, id: String) -> bool:
	for p: Object in s.get("players"):
		if str(p.get("id")) == id:
			return true
	return false

# ---- the server writes no file --------------------------------------------------------------------

func test_the_server_still_writes_no_file(t: T) -> void:
	for path: String in ["res://server/room.gd", "res://net/host.gd", "res://net/ws_server.gd", "res://server/server.gd", "res://server/night_log.gd"]:
		var src := FileAccess.get_file_as_string(path)
		t.check(src != "", "%s reads" % path)
		for bad: String in ["FileAccess.WRITE", "FileAccess.READ_WRITE", "FileAccess.WRITE_READ", "ConfigFile.new()", "DirAccess", "store_string", "store_line", ".save("]:
			t.check(not src.contains(bad), "%s has no %s: the server writes no file" % [path, bad])
