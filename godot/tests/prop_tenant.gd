# The Tenant clock (TT1; net/host_rules.gd tenant_timer, client/tenant_clock.gd). The owner, 19 Nov: "a Timer that
# says Tenant arrives in: xx:xx, with a ten minute timer per level. If timer runs out, just play a door slam or
# something similar from our sound library and an intercom voice that says players failed to reach quota in time."
# Proved here:
#   1. Off by default, and with it off nothing changes: the same seeded run through HostRules with the flag off and
#      on is the same state, tick for tick, over two floors and their clocks running out, and the same events but
#      the one "tenantArrived" a floor; with it off there is no such event and no "tenant" block, ever. So at zero
#      nothing else happens (no catch, no phase change, the quota as it was).
#   2. With it on: the clock starts the tick the doors open on arrival, runs the setting's length in host time, the
#      moment comes exactly once a floor at that length (and again on the next floor), says whether the quota was
#      met, and the block is gone while the car rides. Never in the prison, never on Practice.
#   3. The setting (tenant.minutes) sets the length: 2, 10 (today's) and 30 minutes; a change mid-floor waits for
#      the next floor.
#   4. The screen's words: 10:00, 09:59, 01:00, 00:01, THE TENANT IS HERE; the warning colour in the last minute;
#      nothing during a ride or beside a Ward or Reactor block. The wire: the block survives the protocol, and a
#      world without it encodes as before.
#   5. The announcer: a second after the moment, the "tenant" line (quota not met) or "tenant_met" (met), once per
#      event, with its subtitle; not for another floor's event nor beside the Ward's clock. Both lines are recorded
#      in both voices, and the slam is a recording on the Scare bus.
#   6. Over WebSockets (127.0.0.1 on a port of the test block, one room, its real HostRules): two clients show the same remaining time
#      within one tick, a late joiner's screen agrees, and with the clock set to 2 minutes both get the moment once.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const HostRules = preload("res://net/host_rules.gd")
const Protocol = preload("res://net/protocol.gd")
const TenantClock = preload("res://client/tenant_clock.gd")
const AnnouncerScript = preload("res://client/announcer.gd")
const SfxScript = preload("res://client/sfx.gd")
const PropSettings = preload("res://tests/prop_settings.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const Client = preload("res://net/client.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Session = preload("res://net/session.gd")

const DT := 0.05
const SECRET := "tenant-test-passphrase"
const TestPorts = preload("res://tests/test_ports.gd")
static var PORT: int = TestPorts.port(TestPorts.TENANT)

## The game's rules with the Tenant clock `on` (the resident and the quota on, the deck the game's).
static func rules(on: bool, entity_on := true, days := false) -> HostRules:
	var r := HostRules.new(entity_on, 1, Places.FULL, days, true, true)
	r.tenant_timer = on
	return r

## Everyone stands where they are, looking along +x (inputs a player would send, nothing pressed).
static func still(s: Run.RunState) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		if p.status == &"ok" or p.status == &"down":
			out.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
	return out

## The car rides on from here (test-only: the ride, without boarding).
static func ride_on(s: Run.RunState) -> Run.RunState:
	var n := s.copy()
	n.phase = &"riding"
	n.timer = 1.0
	return n

static func without_tenant(events: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in events:
		if e["type"] != "tenantArrived":
			out.append(e)
	return out

## One lane of a run through its own rules.
class Lane:
	var r: HostRules
	var s: Run.RunState
	var opened := []        # host times the doors opened on arrival
	var arrivals: Array = []   # the tenantArrived events
	var blocks_riding := 0  # ticks a block was shown while the car rode

	func _init(rules_: HostRules, seed: String, tuning: Dictionary) -> void:
		r = rules_
		s = r.prepare(Run.create_run(seed, ["p0", "p1"]))
		if not tuning.is_empty():
			s = Run.with_tuning(s, tuning)

	static func still(st: Run.RunState) -> Array[Run.PlayerInput]:
		var out: Array[Run.PlayerInput] = []
		for p in st.players:
			if p.status == &"ok" or p.status == &"down":
				out.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
		return out

	func tick() -> Array[Dictionary]:
		var st := r.step(s, Lane.still(s), 0.05)
		s = st.state
		for e in st.events:
			if e["type"] == "doorsOpened" and str(e.get("reason", "")) == "arrival":
				opened.append(s.t)
			elif e["type"] == "tenantArrived":
				arrivals.append(e)
		if s.phase == &"riding" and r.tenant_block(s) != null:
			blocks_riding += 1
		return st.events

func test_off_is_untouched_and_on_adds_only_the_moment(t: T) -> void:
	var minutes := 2.0
	var given := {&"tenant.minutes": minutes}
	var off := Lane.new(rules(false), "tt1-two-floors", given)
	var on := Lane.new(rules(true), "tt1-two-floors", given)
	t.check(not rules(false).tenant_timer and not HostRules.new(true, 1).tenant_timer, "off unless asked")
	var per_floor := int((minutes * 60.0 + 20.0) / DT)
	var differ := 0
	var off_blocks := 0
	var off_events := 0
	var phase_at_zero := ""
	var quota_at_zero := []
	var caught := 0
	for floor in 2:
		if floor == 1:
			off.s = ride_on(off.s)
			on.s = ride_on(on.s)
		for k in per_floor:
			var before_phase := String(on.s.phase)
			var before_quota := [on.s.floor_earned, on.s.floor_needed, on.s.quota_met]
			var eo := off.tick()
			var en := on.tick()
			if PropSettings.fingerprint(off.s, eo) != PropSettings.fingerprint(on.s, without_tenant(en)):
				differ += 1
			if off.r.tenant_block(off.s) != null:
				off_blocks += 1
			for e in eo:
				if e["type"] == "tenantArrived":
					off_events += 1
				elif e["type"] == "caught":
					caught += 1
			for e in en:
				if e["type"] == "tenantArrived":
					phase_at_zero = "%s>%s" % [before_phase, String(on.s.phase)]
					quota_at_zero = [before_quota, [on.s.floor_earned, on.s.floor_needed, on.s.quota_met]]
	t.eq(differ, 0, "flag off and on: the same state and events (but the moment) on every tick of two floors")
	t.eq(off_events, 0, "flag off: no tenantArrived, ever")
	t.eq(off_blocks, 0, "flag off: no tenant block, ever")
	t.eq(on.arrivals.size(), 2, "flag on: the moment once a floor, two floors: %s" % str(on.arrivals))
	t.eq(on.opened.size(), 2, "the doors opened on arrival twice")
	if on.arrivals.size() == 2 and on.opened.size() == 2:
		for i in 2:
			var e: Dictionary = on.arrivals[i]
			t.check(absf(float(e["t"]) - (float(on.opened[i]) + minutes * 60.0)) < DT + 1e-6, "floor %d: at the doors' opening + %d s (%.2f, opened %.2f)" % [i + 1, int(minutes * 60.0), float(e["t"]), float(on.opened[i])])
			t.eq(int(e["depth"]), i + 1, "the event names its floor")
			t.check(e.has("quotaMet") and not bool(e["quotaMet"]), "nobody recorded: quotaMet is false")
	t.eq(on.r.tenant_arrivals, 2, "the rules counted two moments")
	t.eq(on.blocks_riding, 0, "no block while the car rides")
	t.check(phase_at_zero == "away>away", "the phase at zero is unchanged (%s)" % phase_at_zero)
	t.check(quota_at_zero.size() == 2 and quota_at_zero[0] == quota_at_zero[1], "the quota at zero is unchanged: %s" % str(quota_at_zero))
	t.note("two floors of %d s each, %d catches on the way, the moments at %s" % [int(minutes * 60.0), caught, str(on.arrivals.map(func(e: Dictionary) -> float: return e["t"]))])

func test_the_clock_starts_at_arrival_and_not_at_home_or_practice(t: T) -> void:
	# Floor 1: nothing before the doors open, then {at, len} from that tick.
	var lane := Lane.new(rules(true), "tt1-start", {})
	var before_open := 0
	for k in 400:
		lane.tick()
		if lane.opened.is_empty() and lane.r.tenant_block(lane.s) != null:
			before_open += 1
		if not lane.opened.is_empty():
			break
	t.eq(before_open, 0, "no clock before the doors open")
	var b: Variant = lane.r.tenant_block(lane.s)
	t.check(b is Dictionary and absf(float(b["len"]) - 600.0) < 1e-9 and absf(float(b["at"]) - (lane.s.t + 600.0)) < 1e-6, "ten minutes from the doors opening: %s at %.2f" % [str(b), lane.s.t])
	# The quota met (with no resident there is nothing to record, so the quota is off: nothing is owed) says so.
	var free := Lane.new(rules(true, false), "tt1-met", {&"tenant.minutes": 2.0})
	for k in int(140.0 / DT):
		free.tick()
	t.check(free.arrivals.size() == 1 and bool(free.arrivals[0]["quotaMet"]), "nothing owed: quotaMet is true (%s)" % str(free.arrivals))
	# The prison: home in the day loop, the doors open on depth 0 and no clock starts.
	var home_rules := rules(true, true, true)
	var hs := home_rules.prepare(Run.create_run("tt1-home", ["p0"]))
	var ev: Array[Dictionary] = []
	Run._arrive_home(hs, hs.players, hs.t, ev)
	var home_blocks := 0
	var home_opened := 0
	for k in int(30.0 / DT):
		var st := home_rules.step(hs, still(hs), DT)
		hs = st.state
		for e in st.events:
			if e["type"] == "doorsOpened":
				home_opened += 1
		if home_rules.tenant_block(hs) != null:
			home_blocks += 1
	t.check(hs.depth == 0 and Run.at_home(hs), "the run is in the prison (depth %d)" % hs.depth)
	t.eq(home_blocks, 0, "no clock in the prison (doors opened %d times)" % home_opened)
	t.check(not HostRules.tenant_floor(hs), "the prison is not a Tenant floor")
	# Practice (the orientation floor).
	var pr := rules(true)
	pr.enable_orientation()
	var ps := pr.prepare(Run.create_run("tt1-practice", ["p0"]))
	var practice_blocks := 0
	var practice_opened := 0
	for k in int(30.0 / DT):
		var st2 := pr.step(ps, still(ps), DT)
		ps = st2.state
		for e in st2.events:
			if e["type"] == "doorsOpened":
				practice_opened += 1
		if pr.tenant_block(ps) != null:
			practice_blocks += 1
	t.check(ps.orientation, "the run is Practice")
	t.eq(practice_blocks, 0, "no clock on Practice (doors opened %d times)" % practice_opened)

func test_the_setting_sets_the_length(t: T) -> void:
	var row := Settings.row(&"tenant.minutes")
	t.check(row != null and row.wired and row.whole and row.lo == 2.0 and row.hi == 30.0 and row.step == 1.0 and row.today == float(HostRules.TENANT_MINUTES) and row.holds == &"next",
		"the row: 2 to 30 minutes, step 1, today's 10, stamped when the clock starts")
	t.eq(Settings.text(&"tenant.minutes", 10.0), "10 MIN", "the panel's words")
	for m: float in [2.0, 10.0, 30.0]:
		var lane := Lane.new(rules(true), "tt1-len-%d" % int(m), {} if m == 10.0 else {&"tenant.minutes": m})
		while lane.opened.is_empty() and lane.s.t < 30.0:
			lane.tick()
		var b: Variant = lane.r.tenant_block(lane.s)
		t.check(b is Dictionary and absf(float(b["len"]) - m * 60.0) < 1e-9, "%d minutes: the clock is %s" % [int(m), str(b)])
		# A change mid-floor waits for the next floor.
		lane.s = Run.with_tuning(lane.s, {&"tenant.minutes": 5.0})
		lane.tick()
		var b2: Variant = lane.r.tenant_block(lane.s)
		t.check(b2 is Dictionary and float(b2["len"]) == float(b["len"]) and float(b2["at"]) == float(b["at"]), "%d minutes: a change mid-floor leaves the running clock alone" % int(m))

func test_the_screen_words_and_colour(t: T) -> void:
	t.eq(TenantClock.text(600.0), "TENANT ARRIVES IN 10:00", "10:00")
	t.eq(TenantClock.text(599.95), "TENANT ARRIVES IN 10:00", "a tick after: still 10:00 (rounded up)")
	t.eq(TenantClock.text(599.0), "TENANT ARRIVES IN 09:59", "09:59")
	t.eq(TenantClock.text(60.0), "TENANT ARRIVES IN 01:00", "01:00")
	t.eq(TenantClock.text(0.01), "TENANT ARRIVES IN 00:01", "00:01")
	t.eq(TenantClock.text(0.0), "THE TENANT IS HERE", "zero")
	t.eq(TenantClock.text(-42.0), "THE TENANT IS HERE", "for the rest of the floor")
	t.eq(TenantClock.text(1800.0), "TENANT ARRIVES IN 30:00", "the longest clock")
	t.check(not TenantClock.warn(61.0) and not TenantClock.warn(60.05), "no warning before the last minute")
	t.check(TenantClock.warn(60.0) and TenantClock.warn(0.01) and TenantClock.warn(0.0) and TenantClock.warn(-5.0), "the warning colour in the last minute and after")
	var w := {"phase": "away", "depth": 1, "ht": 100.0, "tenant": {"at": 699.0, "len": 600.0}}
	t.eq(TenantClock.line(w), {"text": "TENANT ARRIVES IN 09:59", "warn": false}, "from a world: at - ht")
	t.eq(TenantClock.line({"phase": "away", "depth": 1, "ht": 1.0}), {"text": "", "warn": false}, "no block, no line")
	var riding := w.duplicate()
	riding["phase"] = "riding"
	t.eq(TenantClock.line(riding)["text"], "", "nothing during a ride")
	var ward := w.duplicate()
	ward["ward"] = {}
	t.eq(TenantClock.line(ward)["text"], "", "nothing beside the Ward's own clock")
	var reactor := w.duplicate()
	reactor["reactor"] = {}
	t.eq(TenantClock.line(reactor)["text"], "", "nothing beside the Reactor's")
	t.eq(TenantClock.line(null)["text"], "", "nothing before a world")

func test_the_block_on_the_wire(t: T) -> void:
	var base := {"tick": 3, "ht": 12.0, "phase": "away", "depth": 2, "timer": 0.0, "floorsAway": null, "bellLeft": 0.0, "holdLeft": 0.0,
		"held": false, "blink": null, "orderly": Protocol.orderly_snap(Places.create_resident(Places.generate("tt1-wire", 1, Places.FULL, false))),
		"players": [], "crew": [], "floor": [], "summary": null}
	var plain := Protocol.world_json(base)
	t.check(not plain.contains("tenant"), "a world without the clock encodes as before")
	var with := base.duplicate()
	with["tenant"] = {"at": 612.05, "len": 600.0}
	var text := Protocol.world_json(with)
	var c := Protocol._V.new()
	var back := Protocol.dec_world(c, JSON.parse_string(text))
	t.check(not c.bad and back.get("tenant") is Dictionary, "the block decodes")
	if back.get("tenant") is Dictionary:
		t.check(absf(float(back["tenant"]["at"]) - 612.05) < 1e-9 and absf(float(back["tenant"]["len"]) - 600.0) < 1e-9, "at and len survive: %s" % str(back["tenant"]))
	var c2 := Protocol._V.new()
	var bad: Variant = JSON.parse_string(text.replace("\"tenant\":[612.05,600]", "\"tenant\":[612.05]"))
	Protocol.dec_world(c2, bad)
	t.check(text.contains("\"tenant\":[612.05,600]") and c2.bad, "a malformed block is refused")

func _announcer() -> Node:
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "p0"
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	a.use_manifest(m if m is Dictionary else {})
	return a

static func _spoken(a: Node, moment: String) -> Array:
	return a.request_log.filter(func(r: Dictionary) -> bool: return r.moment == moment)

func test_the_announcer_says_the_true_line_once(t: T) -> void:
	var a := _announcer()
	var here := {"phase": "away", "depth": 1, "ht": 600.0, "tenant": {"at": 600.0, "len": 600.0}}
	a.tenant_latest = here
	a.on_events([{"type": "tenantArrived", "t": 600.0, "depth": 1, "quotaMet": false}], 1, {"earned": 10, "needed": 400})
	a.clock_ms = AnnouncerScript.TENANT_DELAY_MS - 1
	a.update()
	t.eq(_spoken(a, "tenant").size(), 0, "nothing in the second after the slam")
	a.clock_ms = AnnouncerScript.TENANT_DELAY_MS
	a.update()
	t.eq(_spoken(a, "tenant").size(), 1, "a second after: the line, once")
	t.eq(_spoken(a, "tenant_met").size(), 0, "not the met line")
	a.clock_ms += 100
	a.update()
	t.eq(str(a.shown()), "Time's up! Your crew has failed to reach quota in time. The Tenant will see you now.", "its subtitle")
	t.eq(_spoken(a, "tenant").size(), 1, "still once")
	# The next floor: the met line, when the quota was met.
	a.clock_ms += 20000
	a.update()
	var next := here.duplicate()
	next["depth"] = 2
	a.tenant_latest = next
	a.on_events([{"type": "tenantArrived", "t": 1300.0, "depth": 2, "quotaMet": true}], 1, null)
	a.clock_ms += AnnouncerScript.TENANT_DELAY_MS
	a.update()
	t.eq(_spoken(a, "tenant_met").size(), 1, "the next floor, quota met: the met line")
	a.clock_ms += 100
	a.update()
	t.eq(str(a.shown()), "Time's up! Your quota was met, well done. The Tenant is here all the same.", "its subtitle")
	# Another floor's event, or beside the Ward's clock: nothing.
	a.clock_ms += 20000
	a.update()
	a.on_events([{"type": "tenantArrived", "t": 2000.0, "depth": 1, "quotaMet": false}], 1, null)
	var ward := next.duplicate()
	ward["ward"] = {}
	a.tenant_latest = ward
	a.on_events([{"type": "tenantArrived", "t": 2000.0, "depth": 2, "quotaMet": false}], 1, null)
	a.clock_ms += 3000
	a.update()
	t.eq(_spoken(a, "tenant").size() + _spoken(a, "tenant_met").size(), 2, "not for another floor, nor beside the Ward's clock")
	# The lines never name a rule: the only words about the Tenant are that it is coming or here.
	for id: String in ["tenant_1", "tenant_met_1"]:
		t.check(a.lines.has(id) and str(a.lines[id].moment) == ("tenant" if id == "tenant_1" else "tenant_met"), "%s is in the manifest" % id)
		for v: String in ["bella"]:
			t.check(ResourceLoader.exists("res://assets/voice/%s/%s.mp3" % [v, id]), "%s/%s is recorded in the game" % [v, id])
	t.eq(int(a.priority.get("tenant", 0)), 4, "the line's priority")
	a.free()

func test_the_slam_is_a_recording_on_the_scare_bus(t: T) -> void:
	var spec: Array = SfxScript.RECORDED.get("tenant_slam", [])
	t.check(spec.size() == 2 and spec[0] == "scare" and spec[1] == "clinic/slam_1", "tenant_slam: the Clinic's slam as a scare: %s" % str(spec))
	t.eq(SfxScript.CATS["scare"][0], "Scare", "the scare category plays on the Scare bus")
	t.check(ResourceLoader.exists("res://assets/sfx/clinic/slam_1.ogg"), "the recording ships")
	t.check(SfxScript.TENANT_SLAM_DB > 0.0 and SfxScript.TENANT_SLAM_DB <= 6.5, "its lift keeps the file's peak under the Master ceiling (%.1f dB)" % SfxScript.TENANT_SLAM_DB)
	# One sound a moment: the screen plays it for an event of the floor it shows, and only then.
	var w := {"depth": 3}
	t.check(TenantClock.arrived_here({"type": "tenantArrived", "depth": 3}, w), "an event of this floor")
	t.check(not TenantClock.arrived_here({"type": "tenantArrived", "depth": 2}, w), "not another floor's")
	t.check(not TenantClock.arrived_here({"type": "tenantArrived", "depth": 3}, {"depth": 3, "reactor": {}}), "not beside the Reactor's clock")

# ---------------------------------------------------------------------------------------------
# 6. Over WebSockets.

class Net:
	var ws: WsServer
	var room: Room
	var now := 0.0
	var clients: Array = []

	func _init(port: int) -> void:
		var say := func(_l: String) -> void: pass
		ws = WsServer.new("tenant-test-passphrase", false, say)
		ws.listen(port, "127.0.0.1")
		room = Room.new(ws, say)
		room.fixed_seed = "tt1-net"
		room.days = false
		room.quota = false
		room.relocation = false
		room.watchers = false

	func join(port: int, name: String) -> RoomClient:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, "tenant-test-passphrase", name)
		clients.append(rc)
		return rc

	func run(secs: float, until: Callable = Callable(), each: Callable = Callable()) -> bool:
		var end := now + secs
		while now < end:
			now += 0.02
			ws.poll(now)
			room.update(now)
			for rc: RoomClient in clients:
				rc.poll(now)
				if rc.client != null and rc.status == "running":
					rc.frame(now, _local(rc))
			if each.is_valid():
				each.call()
			if until.is_valid() and until.call():
				return true
			OS.delay_msec(1)
		return false

	## In the car, looking into it, so the Orderly is never seen and nobody is in its way.
	func _local(rc: RoomClient) -> Client.LocalFrame:
		var lf := Client.LocalFrame.new()
		var s := room.host.state if room.host != null else null
		lf.body = Move.Body.make(0.0, 0.0, 0, 0.0)
		if s != null:
			lf.yaw = Entity.yaw_toward(s.car.in_x, s.car.in_z)
			lf.body = Run.car_body(s.car, 1.5, -0.5 if clients.find(rc) == 0 else 0.5)
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

static func _left(rc: RoomClient) -> Variant:
	return TenantClock.left_of(rc.client.latest) if rc.client != null else null

func test_two_clients_and_a_late_joiner_over_the_network(t: T) -> void:
	var net := Net.new(PORT)
	var a := net.join(PORT, "Ann")
	net.run(3.0, func() -> bool: return a.status == "lobby" and a.tune_host != "")
	var b := net.join(PORT, "Bob")
	net.run(3.0, func() -> bool: return b.status == "lobby")
	# Two minutes on this floor, set by the host before the run.
	t.check(a.tune_set(&"tenant.minutes", 2.0), "the host sets the clock to 2 minutes")
	net.run(1.0)
	a.set_ready(true)
	b.set_ready(true)
	var shown := func() -> bool: return _left(a) != null and _left(b) != null
	net.run(15.0, shown)
	t.check(shown.call(), "both screens show the clock")
	if not shown.call():
		net.stop()
		return
	t.check(net.room.rules != null and net.room.rules.tenant_timer, "the server's room asks for the clock")
	# The same second on both screens, within a tick, and the host's own deadline.
	var worst := [0.0]
	var samples := [0]
	var at_ok := [true]
	var compare := func() -> void:
		var la: Variant = _left(a)
		var lb: Variant = _left(b)
		if la != null and lb != null:
			worst[0] = maxf(worst[0], absf(float(la) - float(lb)))
			samples[0] += 1
			var hb: Variant = net.room.host.tenant_block()
			if hb == null or absf(float(a.client.latest["tenant"]["at"]) - Protocol.q3(float(hb["at"]))) > 1e-9 or a.client.latest["tenant"]["at"] != b.client.latest["tenant"]["at"]:
				at_ok[0] = false
	net.run(5.0, Callable(), compare)
	t.check(samples[0] > 100 and worst[0] <= Session.TICK + 1e-6, "the two screens' remaining time within one tick: worst %.3f s over %d frames" % [worst[0], samples[0]])
	t.check(at_ok[0], "both carry the host's deadline, to the millisecond")
	t.check(absf(float(a.client.latest["tenant"]["len"]) - 120.0) < 1e-9, "the clock is 2 minutes long")
	var text_a := TenantClock.text(float(_left(a)))
	t.check(text_a.begins_with("TENANT ARRIVES IN 01:"), "the words: %s" % text_a)
	# A late joiner: their welcome carries the clock, and their screen agrees.
	var c := net.join(PORT, "Cat")
	var c_shows := func() -> bool: return _left(c) != null
	net.run(6.0, c_shows)
	t.check(c_shows.call(), "the late joiner's screen shows the clock (status %s)" % c.status)
	if c_shows.call():
		net.run(0.5)
		t.check(absf(float(_left(c)) - float(_left(a))) <= Session.TICK + 1e-6, "and agrees within a tick (%.3f, %.3f)" % [float(_left(c)), float(_left(a))])
	# To zero: the moment reaches both once, and both screens say the Tenant is here. Two minutes of room time over
	# the sockets take about a minute and a half, so the quick suite leaves this part to the default size (the moment
	# itself, once a floor, is proved above without the network).
	if t.quick:
		net.stop()
		t.note("over WebSockets: worst gap %.3f s over %d frames (quick: the run to zero is left to the default size)" % [worst[0], samples[0]])
		return
	var here :=func() -> bool: return _left(a) != null and float(_left(a)) <= 0.0 and _left(b) != null and float(_left(b)) <= 0.0
	net.run(130.0, here)
	net.run(1.0)
	t.check(here.call(), "both reach zero")
	for rc: RoomClient in [a, b]:
		var got := rc.client.events.filter(func(e: Dictionary) -> bool: return e.get("type") == "tenantArrived")
		t.eq(got.size(), 1, "%s: the moment once" % rc.my_id)
		t.eq(TenantClock.line(rc.client.latest)["text"], "THE TENANT IS HERE", "%s: the words at zero" % rc.my_id)
		t.check(bool(TenantClock.line(rc.client.latest)["warn"]), "%s: in the warning colour" % rc.my_id)
	t.check(str(net.room.host.state.phase) in ["away", "unloading"], "nothing else happened at zero: the car is still %s" % str(net.room.host.state.phase))
	net.stop()
	t.note("over WebSockets: worst gap %.3f s over %d frames" % [worst[0], samples[0]])
