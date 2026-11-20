# A late joiner on the late floors (LJ1; server/room.gd ready-up, net/host.gd _admit). The dedicated server's room
# over real sockets, with the game's defaults (late floors, the Ward and the Reactor as places, cycles):
#   - a player who joins while the crew is ON the Hanging Ward (floor 6) and readies waits through the whole floor
#     (the Ward has no stop of its own) and is admitted as the Ward's lift arrives at the Reactor (floor 7), one of
#     the Reactor's crew from that tick;
#   - a player who joins while the crew is ON the Reactor and readies is admitted as the car arrives at the prison;
#   - a joiner who never readies is admitted at neither stop (as on floors 1 to 5: tests/prop_ready.gd).
# The server listens on 127.0.0.1:4856 (run it alone if another check uses that port).
# Run alone: npm run godot:test -- prop_late_admit
extends RefCounted

const T = preload("res://tests/t.gd")
const Client = preload("res://net/client.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const HostRules = preload("res://net/host_rules.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Ward = preload("res://sim/ward/state.gd")

const SECRET := "late-admit-test-passphrase"
const PORT := 4856

class Net:
	var ws: WsServer
	var room: Room
	var now := 0.0
	var clients: Array[RoomClient] = []

	func _init(port: int, depth: int) -> void:
		var say := func(_l: String) -> void: pass
		ws = WsServer.new(SECRET, false, say)
		ws.listen(port, "127.0.0.1")
		room = Room.new(ws, say)
		room.fixed_seed = "late-admit"
		room.quota = false
		room.first_depth = depth

	func join(port: int, name: String) -> RoomClient:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
		clients.append(rc)
		return rc

	## Every client sends its input each frame: the body the host holds for it (it stands still), so the host
	## counts it as present (the Ward's lift takes only those it sees aboard).
	func run(secs: float, until: Callable = Callable()) -> bool:
		var end := now + secs
		while now < end:
			now += 0.02
			ws.poll(now)
			room.update(now)
			for rc: RoomClient in clients:
				rc.poll(now)
				if rc.client != null and rc.status == "running":
					var lf := Client.LocalFrame.new()
					var hp: Variant = room.host._players.get(rc.my_id) if room.host != null else null
					lf.body = hp.body if hp != null and hp.body != null else Move.Body.make(0.0, 9.3, 0, 0.0)
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

## Ann alone starts the run on `depth`; Cy joins once it is on and readies when `ready`. Returns [Ann, Cy] or [].
static func _crew(t: T, net: Net, ready: bool, tag: String) -> Array[RoomClient]:
	var ann := net.join(PORT, "Ann")
	if not t.check(net.run(5.0, func() -> bool: return ann.status == "lobby"), "%s: Ann in the lobby" % tag):
		return []
	ann.set_ready(true)
	if not t.check(net.run(12.0, func() -> bool: return net.room.host != null and ann.status == "running" and ann.client.playing), "%s: Ann's run is on" % tag):
		return []
	net.run(1.0)
	var cy := net.join(PORT, "Cy")
	if not t.check(net.run(8.0, func() -> bool: return cy.status == "running" and net.room.host._players.has(cy.my_id)), "%s: Cy joins the run as a spectator" % tag):
		return []
	if ready:
		cy.set_ready(true)
	net.run(1.0)
	return [ann, cy]

static func _in_station_crew(net: Net, id: String) -> bool:
	var w: Dictionary = net.room.host.world()
	return w.has("reactor") and (w["reactor"]["status"] as Dictionary).has(id)

func test_a_joiner_on_the_ward_is_admitted_at_the_reactor(t: T) -> void:
	for ready: bool in [true, false]:
		var tag := "Ward, %s" % ("ready" if ready else "never ready")
		var net := Net.new(PORT, HostRules.WARD_DEPTH)
		var crew := _crew(t, net, ready, tag)
		if crew.is_empty():
			net.stop()
			continue
		var cy := crew[1]
		var host := net.room.host
		t.check(host._ward_review != null and host.state.depth == HostRules.WARD_DEPTH and host.ward_native(), "%s: the crew is on the native Ward" % tag)
		# The whole floor is no stop: Cy waits.
		net.run(2.0)
		t.check(not net.room.in_run(cy.my_id) and not cy.client.playing, "%s: Cy waits while the crew is on the Ward" % tag)
		t.eq(str(cy.client.latest.get("depth", -1)) if cy.client.latest != null else "none", "6", "%s: Cy's screen gets the Ward's snapshots while waiting" % tag)
		t.check(cy.client.latest != null and cy.client.latest.has("ward"), "%s: with the Ward's block" % tag)
		t.eq(cy.run_depth, HostRules.WARD_DEPTH, "%s: Cy's Ready-up says the crew is on floor 6" % tag)
		# The Ward's lift back: boarding now, leaving in 0.3 s with Ann aboard (she stands where the lift put her).
		var w: Ward = host._ward_review
		w.phase = &"boarding"
		w.collection_at = host.state.t
		w.depart_at = host.state.t + 0.3
		var arrived := net.run(20.0, func() -> bool: return net.room.host.state.depth == HostRules.REACTOR_DEPTH)
		t.check(arrived and net.room.host.state.plan.place == Places.REACTOR, "%s: the Ward's lift rides down to the Reactor (depth %d, Ward %s boarded %s left %s, phase %s)" % [tag, net.room.host.state.depth, w.phase, w.boarded, w.left_behind, net.room.host.state.phase])
		net.run(1.0)
		if ready:
			t.check(net.room.in_run(cy.my_id) and cy.client.playing, "%s: Cy is admitted as the car arrives at the Reactor" % tag)
			t.check(_in_station_crew(net, cy.my_id), "%s: and is one of the Reactor's crew" % tag)
		else:
			t.check(not net.room.in_run(cy.my_id) and not cy.client.playing, "%s: Cy, not ready, is not admitted at the Reactor" % tag)
		net.stop()

func test_a_joiner_on_the_reactor_is_admitted_at_the_prison(t: T) -> void:
	for ready: bool in [true, false]:
		var tag := "Reactor, %s" % ("ready" if ready else "never ready")
		var net := Net.new(PORT, HostRules.REACTOR_DEPTH)
		var crew := _crew(t, net, ready, tag)
		if crew.is_empty():
			net.stop()
			continue
		var cy := crew[1]
		var host := net.room.host
		t.check(host.state.plan.place == Places.REACTOR and host.state.station != null, "%s: the crew is on the Reactor (the station)" % tag)
		net.run(2.0)
		t.check(not net.room.in_run(cy.my_id) and not cy.client.playing, "%s: Cy waits while the crew is on the Reactor" % tag)
		t.check(cy.client.latest != null and cy.client.latest.has("reactor") and int(cy.client.latest.depth) == HostRules.REACTOR_DEPTH, "%s: Cy's screen gets the Reactor's snapshots while waiting" % tag)
		t.eq(cy.run_depth, HostRules.REACTOR_DEPTH, "%s: Cy's Ready-up says the crew is on floor 7" % tag)
		# The car leaves for the prison (as the Reactor's bell sends it: sim/run.gd _ride_up) and arrives now.
		var s := host.state.copy()
		s.phase = &"riding"
		s.going_up = true
		s.timer = 0.0
		host.state = s
		var home := net.run(5.0, func() -> bool: return net.room.host.state.depth == 0)
		t.check(home, "%s: the car arrives at the prison" % tag)
		net.run(1.0)
		if ready:
			t.check(net.room.in_run(cy.my_id) and cy.client.playing, "%s: Cy is admitted as the car arrives at the prison" % tag)
		else:
			t.check(not net.room.in_run(cy.my_id) and not cy.client.playing, "%s: Cy, not ready, is not admitted at the prison" % tag)
		net.stop()
