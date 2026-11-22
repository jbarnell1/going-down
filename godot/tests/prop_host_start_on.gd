# HP1: the host's START ON, the floor picker of a shared room's Ready-up screen (server/room.gd, the block at the
# end; net/room_client.gd set_start_on; client/start_screen.gd and client/main.gd start_on_choices). Over real
# sockets with the dedicated server's room, two players:
#   - only the host may choose; a guest's choice is refused and changes nothing;
#   - a floor the solo picker does not offer is refused; so is any choice while a run is on;
#   - the guest's screen shows the host's choice before anyone readies;
#   - starting on 6 puts both players on the real Hanging Ward (its block, the crawling Rigger, the lift called
#     from the station), on 7 on the Reactor, with no orientation prelude;
#   - the choice goes back to the normal start when the host leaves;
#   - HP1b: the host (only) ends a host-playtest run for everyone, back to the lobby, and can start again; a
#     campaign run is never ended that way; the Esc menu offers END RUN only to the host of a playtest, STAY first.
# Without sockets: a room whose host chose a floor and then the normal start again starts the very same run
# (world, lobby text and the first ticks) as a room nobody touched, and its lobby says nothing new.
# The server listens on 127.0.0.1, on its own port of this process's test block (tests/test_ports.gd).
# Run alone: npm run godot:test -- prop_host_start_on
extends RefCounted

const T = preload("res://tests/t.gd")
const Client = preload("res://net/client.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const Protocol = preload("res://net/protocol.gd")
const HostRules = preload("res://net/host_rules.gd")
const Move = preload("res://sim/move.gd")
const StartScreen = preload("res://client/start_screen.gd")
const Game = preload("res://client/main.gd")
const EscMenu = preload("res://client/esc_menu.gd")

const SECRET := "start-on-test-passphrase"
const TestPorts = preload("res://tests/test_ports.gd")
static var PORT: int = TestPorts.port(TestPorts.START_ON)

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
		room.fixed_seed = "start-on-net"
		room.orientation_campaign = true

	func join(port: int, name: String) -> RoomClient:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
		clients.append(rc)
		return rc

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

## Two players in the lobby, the first the host (and told so). [] on failure.
static func _pair(t: T, net: Net, tag: String) -> Array[RoomClient]:
	var out: Array[RoomClient] = []
	for n: String in ["Ann", "Bob"]:
		var rc := net.join(PORT, n)
		if not t.check(net.run(5.0, func() -> bool: return rc.status == "lobby" and rc.host_id != ""), "%s: %s in the lobby" % [tag, n]):
			return []
		out.append(rc)
	var told := net.run(3.0, func() -> bool: return out[0].is_host() and out[1].host_id == out[0].my_id)
	t.check(told, "%s: the first in is the host" % tag)
	return out

## A message the client's own guard would not send (a guest's, or a bad depth), straight down the socket.
static func _forge(rc: RoomClient, m: Dictionary) -> void:
	rc._queue("m|" + JSON.stringify(m))
	rc._flush(rc._now)

func test_only_the_host_chooses_and_the_guest_sees_it(t: T) -> void:
	var tag := "host only"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty():
		net.stop()
		return
	var host_rc := crew[0]
	var guest := crew[1]
	t.check(not guest.set_start_on(6), "%s: the guest's own client does not send it" % tag)
	_forge(guest, {"t": "startOn", "depth": 6})
	var refused := net.run(3.0, func() -> bool: return not guest.start_on_refusals.is_empty())
	t.check(refused and str(guest.start_on_refusals[0]["why"]) == "host", "%s: a guest's choice is refused as not the host's (%s)" % [tag, guest.start_on_refusals])
	t.eq(net.room.start_on, -1, "%s: and changes nothing" % tag)
	t.check(host_rc.set_start_on(6), "%s: the host's client sends it" % tag)
	var seen := net.run(3.0, func() -> bool: return guest.start_on == 6 and host_rc.start_on == 6)
	t.check(seen and net.room.start_on == 6, "%s: the room takes the host's floor 6 and the guest's lobby shows it (guest %d)" % [tag, guest.start_on])
	t.check(host_rc.start_on_refusals.is_empty(), "%s: the host was not refused" % tag)
	var choices := Game.start_on_choices()
	var notice := StartScreen.start_on_notice(guest.start_on, choices)
	t.check(notice.begins_with("HOST PLAYTEST: STARTING ON FLOOR 6, THE HANGING WARD"), "%s: the guest's Ready-up reads it (%s)" % [tag, notice])
	t.eq(StartScreen.start_on_notice(-1, choices), "", "%s: the normal start shows nothing" % tag)
	# The Ready-up screen: the host has the row, the guest does not.
	var screen: StartScreen = StartScreen.new()
	screen.screen = "lobby"
	screen.start_on_choices = choices
	screen.start_on = 6
	t.check(not screen._order().has("starton"), "%s: a guest's screen has no START ON row" % tag)
	screen.start_on_host = true
	t.check(screen._order().has("starton"), "%s: the host's has" % tag)
	var asked: Array[int] = []
	screen.start_on_pressed.connect(func(d: int) -> void: asked.append(d))
	screen.step_start_on(1)
	screen.step_start_on(-1)
	t.eq(asked, [7, 5] as Array[int], "%s: right and left step along the floors from 6" % tag)
	screen.free()
	net.stop()

func test_floors_not_offered_are_refused(t: T) -> void:
	var tag := "bad depth"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty():
		net.stop()
		return
	var offered := net.room.start_on_destinations()
	var solo: Array[int] = []
	for d: Dictionary in Game.LocalRoom.playtest_destinations("", Game.Places.FULL):
		solo.append(int(d["depth"]))
	t.eq(offered, solo, "%s: the room offers the solo picker's floors" % tag)
	t.check(offered.has(6) and offered.has(7), "%s: the Ward and the Reactor among them" % tag)
	var bad: Array = [99, -5, 9, "6", 2.5, null]
	for v: Variant in bad:
		_forge(crew[0], {"t": "startOn", "depth": v})
	var all_refused := net.run(4.0, func() -> bool: return crew[0].start_on_refusals.size() >= bad.size())
	var whys: Array[String] = []
	for r: Dictionary in crew[0].start_on_refusals:
		whys.append(str(r["why"]))
	t.check(all_refused and whys.count("depth") == bad.size(), "%s: each is refused as not a floor on offer (%s)" % [tag, whys])
	t.eq(net.room.start_on, -1, "%s: the room is still on the normal start" % tag)
	t.check(crew[0].status == "lobby", "%s: and the host is still connected" % tag)
	net.stop()

## The pair chooses `depth`, readies, and the run is on for both. False on failure.
static func _start_on(t: T, net: Net, crew: Array[RoomClient], depth: int, tag: String) -> bool:
	crew[0].set_start_on(depth)
	if not t.check(net.run(3.0, func() -> bool: return crew[1].start_on == depth), "%s: the guest sees floor %d chosen" % [tag, depth]):
		return false
	for rc in crew:
		rc.set_ready(true)
	var on := func() -> bool:
		if net.room.host == null:
			return false
		for rc in crew:
			if rc.status != "running" or rc.client == null or not rc.client.playing:
				return false
		return true
	return t.check(net.run(20.0, on), "%s: the run is on for both" % tag)

func test_starting_on_the_ward(t: T) -> void:
	var tag := "floor 6"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty() or not _start_on(t, net, crew, 6, tag):
		net.stop()
		return
	var host := net.room.host
	t.check(net.room.playtest_run, "%s: a playtest run" % tag)
	t.eq(host.state.depth, 6, "%s: on floor 6" % tag)
	t.check(host.state.orientation_resume == null, "%s: no orientation prelude" % tag)
	var w: Dictionary = host.world()
	t.check(w.has("ward") and not w.has("reactor"), "%s: the world has the Ward" % tag)
	t.check(host.rigger_roam() and w["ward"].has("rigger"), "%s: with the crawling Rigger" % tag)
	t.check(host.ward_call_rule() and w["ward"].get("extras", {}).get("called") == true, "%s: and the lift called from the station" % tag)
	var both := net.run(5.0, func() -> bool: return crew[0].client.latest != null and crew[1].client.latest != null and crew[0].client.latest.has("ward") and crew[1].client.latest.has("ward"))
	t.check(both and crew[0].client.latest.ward.seed == crew[1].client.latest.ward.seed and crew[0].client.latest.ward.seed == w["ward"]["seed"], "%s: both players are on the same Ward" % tag)
	# While a run is on, the host's choice is refused.
	crew[0].set_start_on(1)
	var refused := net.run(3.0, func() -> bool: return not crew[0].start_on_refusals.is_empty())
	t.check(refused and str(crew[0].start_on_refusals[0]["why"]) == "running", "%s: a choice during the run is refused (%s)" % [tag, crew[0].start_on_refusals])
	t.eq(net.room.start_on, 6, "%s: and changes nothing" % tag)
	net.stop()

func test_starting_on_the_reactor(t: T) -> void:
	var tag := "floor 7"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty() or not _start_on(t, net, crew, 7, tag):
		net.stop()
		return
	var host := net.room.host
	t.eq(host.state.depth, 7, "%s: on floor 7" % tag)
	var w: Dictionary = host.world()
	t.check(w.has("reactor") and not w.has("ward"), "%s: the world has the Reactor" % tag)
	t.check(net.room.rules.reactor_place, "%s: the generated Reactor of a normal run" % tag)
	var both := net.run(5.0, func() -> bool: return crew[0].client.latest != null and crew[1].client.latest != null and crew[0].client.latest.has("reactor") and crew[1].client.latest.has("reactor"))
	t.check(both, "%s: both players are on the Reactor" % tag)
	net.stop()

func test_the_choice_resets_when_the_host_leaves(t: T) -> void:
	var tag := "host leaves"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty():
		net.stop()
		return
	crew[0].set_start_on(6)
	t.check(net.run(3.0, func() -> bool: return crew[1].start_on == 6), "%s: the guest sees floor 6" % tag)
	crew[0].leave()
	var passed := net.run(4.0, func() -> bool: return crew[1].host_id == crew[1].my_id and crew[1].start_on == -1)
	t.check(passed and net.room.start_on == -1, "%s: the new host's room is back on the normal start (room %d, seen %d)" % [tag, net.room.start_on, crew[1].start_on])
	net.stop()

func test_the_host_ends_a_playtest_for_everyone(t: T) -> void:
	var tag := "end run"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty() or not _start_on(t, net, crew, 3, tag):
		net.stop()
		return
	t.check(net.run(3.0, func() -> bool: return crew[0].playtest_on and crew[1].playtest_on), "%s: both screens know the run is a playtest" % tag)
	var epoch0 := net.room.epoch
	t.check(not crew[1].end_run(), "%s: the guest's own client does not send it" % tag)
	_forge(crew[1], {"t": "endRun"})
	var refused := net.run(3.0, func() -> bool: return not crew[1].end_run_refusals.is_empty())
	t.check(refused and crew[1].end_run_refusals[0] == "host", "%s: a guest's END RUN is refused (%s)" % [tag, crew[1].end_run_refusals])
	t.check(net.room.host != null, "%s: and the run goes on" % tag)
	t.check(crew[0].end_run(), "%s: the host's client sends it" % tag)
	var back := net.run(4.0, func() -> bool: return net.room.host == null and crew[0].status == "lobby" and crew[1].status == "lobby" and crew[0].client == null and crew[1].client == null)
	t.check(back, "%s: the run is over and both are back in the lobby" % tag)
	t.check(not crew[0].playtest_on and not crew[1].my_ready, "%s: no playtest on, everyone readies again" % tag)
	t.eq(net.room.start_on, 3, "%s: the host's floor is still chosen" % tag)
	for rc in crew:
		rc.set_ready(true)
	var again := net.run(15.0, func() -> bool: return net.room.host != null and crew[0].status == "running" and crew[1].status == "running")
	t.check(again and net.room.epoch == epoch0 + 1 and net.room.host.state.depth == 3, "%s: and a new run starts from it (epoch %d)" % [tag, net.room.epoch])
	net.stop()

func test_a_campaign_run_is_never_ended(t: T) -> void:
	var tag := "campaign"
	var net := Net.new(PORT)
	var crew := _pair(t, net, tag)
	if crew.is_empty():
		net.stop()
		return
	for rc in crew:
		rc.set_ready(true)
	if not t.check(net.run(15.0, func() -> bool: return net.room.host != null and crew[0].status == "running"), "%s: a normal run is on" % tag):
		net.stop()
		return
	net.run(1.0)
	t.check(not net.room.playtest_run and not crew[0].playtest_on, "%s: not a playtest, and no screen says it is" % tag)
	crew[0].end_run()
	var refused := net.run(3.0, func() -> bool: return not crew[0].end_run_refusals.is_empty())
	t.check(refused and crew[0].end_run_refusals[0] == "campaign", "%s: the host's END RUN is refused (%s)" % [tag, crew[0].end_run_refusals])
	t.check(net.room.host != null and crew[0].status == "running", "%s: the run goes on" % tag)
	net.stop()

func test_the_esc_menu_offers_end_run_only_in_a_playtest(t: T) -> void:
	var menu: EscMenu = EscMenu.new()
	menu.in_run = true
	menu.is_host = true
	menu.playtest = false
	var ids := func() -> Array: return menu.rows().map(func(r: Dictionary) -> String: return str(r["id"]))
	t.check(not ids.call().has("end_ask"), "a campaign run's host has no END RUN")
	menu.playtest = true
	menu.is_host = false
	t.check(not ids.call().has("end_ask"), "a guest has none")
	menu.is_host = true
	t.check(ids.call().has("end_ask"), "the host of a playtest has it")
	menu.sel = ids.call().find("end_ask")
	var chosen: Array[String] = []
	menu.chose.connect(func(id: String) -> void: chosen.append(id))
	menu.activate()
	t.eq(menu.page, "end", "it asks first")
	t.eq(menu._heading(), "END THIS PLAYTEST? EVERYONE RETURNS TO THE LOBBY.", "in those words")
	t.eq(str(menu.rows()[menu.sel]["id"]), "back", "with STAY chosen")
	t.check(chosen.is_empty(), "and nothing is done yet")
	menu.move(1)
	menu.activate()
	t.eq(chosen, ["end"] as Array[String], "END RUN asks the game to end it")
	menu.free()

## A room with two ready players and no sockets, its run started; `touch` chose a floor and then the normal start.
static func _quiet_room(touch: int) -> Room:
	var say := func(_l: String) -> void: pass
	var room := Room.new(WsServer.new(SECRET, false, say), say)
	room.fixed_seed = "start-on-digest"
	room.orientation_campaign = true
	room.people = {"a": "Ann", "b": "Bob"}
	room._pick_host()
	if touch >= 0:
		room._on_start_on("a", {"depth": touch})
		if touch != 6:
			room._on_start_on("a", {"depth": -1})
	room.ready = {"a": 0.0, "b": 0.0}
	room._start(0.0)
	return room

static func _digest(room: Room) -> String:
	var out := [room._lobby_text(0.0), Protocol.world_json(room.host.world())]
	var now := 0.0
	for i in 40:
		now += 0.05
		room.host.update(now)
		out.append(Protocol.world_json(room.host.world()))
	out.append(room._lobby_text(now))
	return "|".join(out).sha256_text()

func test_the_normal_start_is_unchanged(t: T) -> void:
	var untouched := _quiet_room(-1)
	t.check(not untouched.playtest_run and untouched.rules._depth == 1, "an untouched room starts a normal run from floor 1 (playtest %s, depth %d, rules %d)" % [untouched.playtest_run, untouched.host.state.depth, untouched.rules._depth])
	t.check(untouched.host.state.orientation_resume != null, "with its orientation prelude")
	t.check(not untouched._lobby_text(0.0).contains("startOn") and not untouched._lobby_text(0.0).contains("playtest"), "and its lobby says nothing new")
	var a := _digest(untouched)
	var back := _quiet_room(3)
	t.check(not back.playtest_run, "a room whose host chose floor 3 and then the normal start runs normally")
	t.eq(_digest(back), a, "the same run, tick for tick, world and lobby, as a room nobody touched")
	var chosen := _quiet_room(6)
	t.check(chosen.playtest_run and chosen._lobby_text(0.0).contains("\"startOn\":6"), "a chosen floor is a playtest and its lobby says so")
	t.check(_digest(chosen) != a, "and the digest tells it apart (it sees the start)")
