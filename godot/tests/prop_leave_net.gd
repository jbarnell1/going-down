# A player leaving mid-run (LV1; the Esc menu's LEAVE RUN: net/room_client.gd leave(), which sends the run's
# "leave" and closes the socket; net/host.gd _leave, server/room.gd "left"). The dedicated server's room over
# real sockets, crews of two and three:
#   - the crew left behind does not wait for the leaver: not active, not aboard for CAR WAITING FOR, out of the
#     run as "leftBehind"; the rest board and ride down, and BANK home;
#   - the room's host (the first in) leaving passes the host to the next, whose settings changes still answer;
#   - a downed leaver does not hold the crew: their ten seconds end as anyone's do;
#   - the last one leaving ends the run, and a new player can start one;
#   - the leaver coming back is a new late joiner (one of them in the room, never a second in the run);
#   - with the voice, the leaver leaves the mic list.
# The server listens on 127.0.0.1, on its own port of this process's test block (tests/test_ports.gd).
# Run alone: npm run godot:test -- prop_leave_net
extends RefCounted

const T = preload("res://tests/t.gd")
const Client = preload("res://net/client.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")

const SECRET := "leave-net-test-passphrase"
const TestPorts = preload("res://tests/test_ports.gd")
static var PORT: int = TestPorts.port(TestPorts.LEAVE)

class Net:
	var ws: WsServer
	var room: Room
	var now := 0.0
	var clients: Array[RoomClient] = []

	func _init(port: int) -> void:
		var say := func(_l: String) -> void: pass
		ws = WsServer.new(SECRET, false, say)
		ws.listen(port, "127.0.0.1")
		room = Room.new(ws, say)
		room.fixed_seed = "leave-net"
		room.quota = false

	func join(port: int, name: String) -> RoomClient:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
		clients.append(rc)
		return rc

	## Every client still on sends its input each frame: the body the host holds for it, mic listening.
	func run(secs: float, until: Callable = Callable()) -> bool:
		var end := now + secs
		while now < end:
			now += 0.02
			ws.poll(now)
			room.update(now)
			for rc: RoomClient in clients:
				if rc.status == "closed":
					continue
				rc.poll(now)
				if rc.client != null and rc.status == "running":
					var lf := Client.LocalFrame.new()
					var hp: Variant = room.host._players.get(rc.my_id) if room.host != null else null
					lf.body = hp.body if hp != null and hp.body != null else Move.Body.make(0.0, 9.3, 0, 0.0)
					lf.mic = true
					rc.frame(now, lf)
			if until.is_valid() and until.call():
				return true
			OS.delay_msec(2)
		return false

	func stop() -> void:
		for rc: RoomClient in clients:
			if rc.status != "closed":
				rc.leave()
		run(0.2)
		ws.stop()

const NAMES: Array[String] = ["Ann", "Bob", "Cy"]

## `n` players join, all ready, the run starts with all of them. Returns them, or [] on failure.
static func _crew(t: T, net: Net, n: int, tag: String) -> Array[RoomClient]:
	var out: Array[RoomClient] = []
	for i in n:
		var rc := net.join(PORT, NAMES[i])
		if not t.check(net.run(5.0, func() -> bool: return rc.status == "lobby"), "%s: %s in the lobby" % [tag, NAMES[i]]):
			return []
		out.append(rc)
	for rc in out:
		rc.set_ready(true)
	var all_on := func() -> bool:
		if net.room.host == null:
			return false
		for rc in out:
			if rc.status != "running" or rc.client == null or not rc.client.playing:
				return false
		return true
	if not t.check(net.run(15.0, all_on), "%s: the run is on for all %d" % [tag, n]):
		return []
	net.run(0.5)
	return out

static func _rp(net: Net, id: String) -> Run.RunPlayer:
	for p in net.room.host.state.players:
		if p.id == id:
			return p
	return null

## The leaver as the remaining client's newest snapshot shows them ({} when not listed).
static func _seen(rc: RoomClient, id: String) -> Dictionary:
	if rc.client == null or rc.client.latest == null:
		return {}
	for p: Dictionary in rc.client.latest["players"]:
		if str(p["id"]) == id:
			return p
	return {}

## The names main.gd's CAR WAITING FOR would print from this client's newest snapshot (client/main.gd
## car_waiting_text: aboard, active and "ok").
static func _waiting_for(rc: RoomClient) -> Array[String]:
	var who: Array[String] = []
	if rc.client == null or rc.client.latest == null:
		return who
	for p: Dictionary in rc.client.latest["players"]:
		if bool(p["aboard"]) and bool(p["active"]) and str(p["status"]) == "ok":
			who.append(str(p["id"]))
	return who

## Puts every player in `stay` on the car's `side` half, the doors open and the bell 0.3 s from going.
static func _board(net: Net, stay: Array[RoomClient], side: StringName) -> void:
	var host := net.room.host
	var car: Run.CarGeometry = host.state.car
	var sign := 1.0 if Run.car_side(car, Run.car_body(car, 1.2, 1.0)) == side else -1.0
	var k := 0
	for rc in stay:
		host._place(rc.my_id, Run.car_body(car, 0.9 + 0.6 * k, sign * 0.8), host.state.depth, host.state)
		k += 1
	net.run(0.6)
	var s := host.state.copy()
	s.phase = &"boarding"
	s.bell_left = 0.3
	host.state = s

## Rides the remaining crew down a floor and then BANKs them home. Checks both.
static func _ride_and_bank(t: T, net: Net, stay: Array[RoomClient], tag: String) -> void:
	var d0: int = net.room.host.state.depth
	_board(net, stay, &"down")
	var down := net.run(20.0, func() -> bool: return net.room.host != null and net.room.host.state.depth == d0 + 1 and net.room.host.state.phase != &"riding")
	t.check(down, "%s: the rest of the crew rides down without the leaver (depth %d, phase %s)" % [tag, net.room.host.state.depth, net.room.host.state.phase])
	for rc in stay:
		var rp := _rp(net, rc.my_id)
		t.eq(str(rp.status) if rp != null else "missing", "ok", "%s: %s arrived on their feet" % [tag, rc.my_id])
	net.run(1.0)
	_board(net, stay, &"bank")
	var home := net.run(30.0, func() -> bool: return net.room.host != null and Run.at_home(net.room.host.state))
	t.check(home, "%s: and BANKs home (depth %d, phase %s)" % [tag, net.room.host.state.depth, net.room.host.state.phase])

func test_a_crewmate_leaving_is_not_waited_for(t: T) -> void:
	for n: int in [2, 3]:
		var tag := "crew of %d, the last in leaves" % n
		var net := Net.new(PORT)
		var crew := _crew(t, net, n, tag)
		if crew.is_empty():
			net.stop()
			continue
		var leaver: RoomClient = crew[n - 1]
		var stay: Array[RoomClient] = crew.slice(0, n - 1)
		var lid := leaver.my_id
		t.check(_waiting_for(stay[0]).has(lid) or net.room.host.state.phase != &"unloading", "%s: before leaving, the leaver is someone the car could wait for" % tag)
		leaver.leave()
		net.run(1.0)
		var hp: Variant = net.room.host._players.get(lid)
		t.check(hp != null and hp.left and not hp.connected, "%s: the host marks the leaver left" % tag)
		t.check(not net.room.people.has(lid), "%s: the room's list no longer has them" % tag)
		var rp := _rp(net, lid)
		t.eq(str(rp.status) if rp != null else "missing", "leftBehind", "%s: the run counts the leaver out" % tag)
		var seen := _seen(stay[0], lid)
		t.check(not seen.is_empty() and not bool(seen["active"]) and str(seen["status"]) == "leftBehind", "%s: the others' screens show them gone (%s)" % [tag, seen])
		t.check(not _waiting_for(stay[0]).has(lid), "%s: CAR WAITING FOR never names the leaver" % tag)
		t.check(not net.room.in_run(lid), "%s: the room no longer counts them in the run" % tag)
		t.check(Run.deal_crew(net.room.host.state).find(lid) < 0, "%s: the elevator deal's vote has no seat for them" % tag)
		_ride_and_bank(t, net, stay, tag)
		net.stop()

func test_the_room_host_leaving_passes_the_host_on(t: T) -> void:
	for n: int in [2, 3]:
		var tag := "crew of %d, the host leaves" % n
		var net := Net.new(PORT)
		var crew := _crew(t, net, n, tag)
		if crew.is_empty():
			net.stop()
			continue
		t.eq(net.room.host_id, crew[0].my_id, "%s: the first in is the host" % tag)
		crew[0].leave()
		var stay: Array[RoomClient] = crew.slice(1, n)
		var passed := net.run(4.0, func() -> bool: return stay[0].host_id == stay[0].my_id)
		t.check(passed and net.room.host_id == stay[0].my_id, "%s: the next in is the host now (room %s)" % [tag, net.room.host_id])
		net.run(0.5)
		var rev0 := stay[0].tune_rev
		stay[0].tune_set(&"orderly.speed", 3.6)
		var tuned := net.run(4.0, func() -> bool: return stay[0].tune_rev > rev0)
		t.check(tuned and stay[0].tune_refusals.is_empty(), "%s: the new host's settings change is taken (refusals %s)" % [tag, stay[0].tune_refusals])
		var tick0: int = net.room.host.tick
		net.run(1.0)
		t.check(net.room.host.tick > tick0, "%s: the run goes on" % tag)
		_ride_and_bank(t, net, stay, tag)
		net.stop()

func test_a_downed_leaver_does_not_hold_the_crew(t: T) -> void:
	for n: int in [2, 3]:
		var tag := "crew of %d, the downed one leaves" % n
		var net := Net.new(PORT)
		var crew := _crew(t, net, n, tag)
		if crew.is_empty():
			net.stop()
			continue
		var leaver: RoomClient = crew[n - 1]
		var lid := leaver.my_id
		var host := net.room.host
		var s := host.state.copy()
		var players: Array[Run.RunPlayer] = s.players.duplicate()
		var k := -1
		for i in players.size():
			if players[i].id == lid:
				k = i
		var ev: Array[Dictionary] = []
		Run._go_down(s, players, k, s.t, &"catch", ev)
		s.players = players
		host.state = s
		net.run(0.5)
		t.eq(str(_rp(net, lid).status), "down", "%s: the leaver is down" % tag)
		leaver.leave()
		var ends := net.run(Run.down_time(host.state) + 3.0, func() -> bool: return _rp(net, lid).status != &"down" and not net.room.host.state.down.has(lid))
		t.check(ends, "%s: their down time ends as anyone's does (status %s, still in the ring list %s)" % [tag, _rp(net, lid).status, net.room.host.state.down.has(lid)])
		t.check(net.room.host.state.phase != &"ended", "%s: the run is not wiped" % tag)
		var stay: Array[RoomClient] = crew.slice(0, n - 1)
		for rc in stay:
			t.eq(str(_rp(net, rc.my_id).status), "ok", "%s: %s is still on their feet" % [tag, rc.my_id])
		t.check(not _waiting_for(stay[0]).has(lid), "%s: CAR WAITING FOR never names them" % tag)
		_ride_and_bank(t, net, stay, tag)
		net.stop()

func test_the_last_one_leaving_resets_the_room(t: T) -> void:
	var tag := "the last one leaves"
	var net := Net.new(PORT)
	var crew := _crew(t, net, 2, tag)
	if crew.is_empty():
		net.stop()
		return
	var epoch0 := net.room.epoch
	crew[1].leave()
	net.run(0.5)
	t.check(net.room.host != null, "%s: one left, the run goes on" % tag)
	crew[0].leave()
	var reset := net.run(3.0, func() -> bool: return net.room.host == null)
	t.check(reset and net.room.people.is_empty() and net.room.host_id == "", "%s: everyone gone, the room is back to the lobby, empty" % tag)
	var dee := net.join(PORT, "Dee")
	t.check(net.run(5.0, func() -> bool: return dee.status == "lobby"), "%s: a new player gets the lobby" % tag)
	t.eq(net.room.host_id, dee.my_id, "%s: and is its host" % tag)
	dee.set_ready(true)
	var on := net.run(15.0, func() -> bool: return net.room.host != null and dee.status == "running" and dee.client.playing)
	t.check(on and net.room.epoch == epoch0 + 1, "%s: and starts a new run (epoch %d)" % [tag, net.room.epoch])
	net.stop()

func test_a_leaver_coming_back_is_one_late_joiner(t: T) -> void:
	for n: int in [2, 3]:
		var tag := "crew of %d, the leaver comes back" % n
		var net := Net.new(PORT)
		var crew := _crew(t, net, n, tag)
		if crew.is_empty():
			net.stop()
			continue
		var old_id := crew[n - 1].my_id
		crew[n - 1].leave()
		net.run(1.0)
		var back := net.join(PORT, NAMES[n - 1])
		var joined := net.run(8.0, func() -> bool: return back.status == "running" and net.room.host._players.has(back.my_id))
		t.check(joined, "%s: they get back into the room, watching" % tag)
		t.check(back.my_id != old_id, "%s: as a new player id (%s, was %s)" % [tag, back.my_id, old_id])
		var named := 0
		for id: String in net.room.people:
			if str(net.room.people[id]) == NAMES[n - 1]:
				named += 1
		t.eq(named, 1, "%s: the room lists them once" % tag)
		t.check(not net.room.in_run(back.my_id) and not back.client.playing, "%s: not in the run until a stop admits them" % tag)
		back.set_ready(true)
		net.run(0.5)
		var stay: Array[RoomClient] = crew.slice(0, n - 1)
		var d0: int = net.room.host.state.depth
		_board(net, stay, &"down")
		net.run(20.0, func() -> bool: return net.room.host.state.depth == d0 + 1 and net.room.host.state.phase != &"riding")
		net.run(1.5)
		t.check(net.room.in_run(back.my_id) and back.client.playing, "%s: ready, they are admitted at the next floor" % tag)
		var on_feet := 0
		for p in net.room.host.state.players:
			if p.status == &"ok":
				on_feet += 1
		t.eq(on_feet, n, "%s: the run has the crew on its feet once each, no ghost" % tag)
		t.check(_rp(net, old_id) == null or _rp(net, old_id).status != &"ok", "%s: the old one is never back on its feet" % tag)
		net.stop()

func test_the_leaver_leaves_the_mic_list(t: T) -> void:
	var tag := "voice"
	var net := Net.new(PORT)
	var crew := _crew(t, net, 3, tag)
	if crew.is_empty():
		net.stop()
		return
	var w: Dictionary = net.room.host.world()
	if not t.check(w.has("mic"), "%s: the run has the voice" % tag):
		net.stop()
		return
	t.check((w["mic"] as Array).has(crew[2].my_id), "%s: the leaver's mic is listed before" % tag)
	crew[2].leave()
	net.run(1.0)
	w = net.room.host.world()
	t.check(not (w["mic"] as Array).has(crew[2].my_id), "%s: and not after (%s)" % [tag, w["mic"]])
	t.eq((w["mic"] as Array).size(), 2, "%s: the others' stay" % tag)
	var seen: Variant = crew[0].client.latest.get("mic") if crew[0].client.latest != null else null
	t.check(seen is Array and not (seen as Array).has(crew[2].my_id), "%s: a crewmate's screen drops them too (%s)" % [tag, seen])
	net.stop()
