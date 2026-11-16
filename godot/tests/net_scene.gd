# Replays a scene of tools/net_script.ts through the GDScript network port: the same machines, clocks
# and seeded in-memory network, every machine handed the recorded LocalFrame on every frame (the event
# loop of tests/net/harness.ts Session.run). Records what tests/ref_net.gd compares.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")
const NetSceneLib = preload("res://tests/net_lib.gd")

class Machine:
	var id: String
	var spec: Dictionary
	var k := 0
	var client: Client = null
	var gone := false
	var rows: Array
	var row := PackedInt64Array()
	var leave_at: Variant

var want: Dictionary
var net: Transport.MemoryNetwork
var host: Host
var rules: HostRules = null
var machines: Array[Machine] = []
var g := 0.0
var near := 0
var sends: Array:
	get:
		return net.sends
var frames := {}
var clients := {}
var host_states: Array = []

func _init(want_: Dictionary) -> void:
	want = want_
	var seed: String = want["seed"]
	net = Transport.MemoryNetwork.new("%s:net" % seed)
	net.log_sends = true
	var host_t := net.connect_peer("host")
	near = int(want.get("near", 0))
	if want["setup"] == "rules":
		rules = HostRules.new(bool(want["entity"]), 1)
	var roster: Array[String] = []
	for id: String in want["roster"]:
		roster.append(id)
	var step := Callable(rules, "step") if rules != null else Callable()
	host = Host.new(host_t, seed, roster, 0.0, _prepare, step)
	for ms: Dictionary in want["machines"]:
		var m := Machine.new()
		m.id = ms["id"]
		m.spec = ms
		m.rows = want["inputs"][m.id]
		m.row.resize(11)
		m.row.fill(0)
		m.leave_at = ms["leaveAt"]
		machines.append(m)
		frames[m.id] = []

func _prepare(s0: Run.RunState) -> Run.RunState:
	var s := rules.prepare(s0) if rules != null else NetSceneLib.hunt_setup(s0)
	return NetSceneLib.near_orderly(s, int(want["near"]))

func _connect(m: Machine) -> void:
	var t := net.connect_peer(m.id)
	net.set_link("host", m.id, NetSceneLib.link_of(m.spec["down"]))
	net.set_link(m.id, "host", NetSceneLib.link_of(m.spec["up"]))
	m.client = Client.new(t, "host", m.id, g + float(m.spec["offset"]))
	clients[m.id] = m.client

func _next_frame_at(m: Machine) -> float:
	return float(m.spec["phase"]) + m.k * NetSceneLib.FRAME

func run() -> void:
	var until: float = want["until"]
	var recorded := _host_states(0)
	while true:
		var next := INF if host.ended else host.next_tick_at()
		for m in machines:
			if m.gone:
				continue
			if m.client == null:
				next = minf(next, float(m.spec["joinAt"]))
			else:
				next = minf(next, _next_frame_at(m))
				if m.leave_at != null:
					next = minf(next, float(m.leave_at))
		var d: Variant = net.next_delivery()
		if d != null:
			next = minf(next, d)
		if next > until:
			break
		g = maxf(g, next)
		net.now = g
		for m in machines:
			if m.gone:
				continue
			if m.client == null and float(m.spec["joinAt"]) <= g:
				_connect(m)
			elif m.client != null and m.leave_at != null and float(m.leave_at) <= g:
				m.client.leave()
				m.gone = true
		host.update(g)
		recorded = _host_states(recorded)
		for m in machines:
			if m.client != null and not m.gone:
				m.client.receive(g + float(m.spec["offset"]))
		for m in machines:
			if m.client == null or m.gone or _next_frame_at(m) > g + 1e-12:
				continue
			_frame(m)
			m.k += 1
	g = until
	net.now = until

func _host_states(from: int) -> int:
	for k in range(from, host.tick + 1):
		var st := host.state_at(k)
		var evs: Array = []
		for l in host.event_log:
			if l.tick == k:
				evs.append(l.e)
		host_states.append([k, st, evs])
	return host.tick + 1

func _frame(m: Machine) -> void:
	var c := m.client
	var delta: Array = m.rows[m.k] if m.k < m.rows.size() else [0]
	var mask: int = delta[0]
	var j := 1
	for i in 11:
		if mask & (1 << i):
			m.row[i] += int(delta[j])
			j += 1
	var r := m.row
	var lf := Client.LocalFrame.new()
	lf.body = Move.Body.make(r[0] / 100.0, r[1] / 100.0, 1 if r[3] == 1 else 0, r[2] / 100.0)
	lf.yaw = r[4] / 1000.0
	lf.pitch = r[5] / 1000.0
	lf.eye = r[6] / 100.0
	lf.h_fov_deg = r[7] / 100.0
	lf.v_fov_deg = r[8] / 100.0
	var flags := r[9]
	lf.raised = (flags & 1) != 0
	lf.hold_doors = (flags & 2) != 0
	lf.call = (flags & 4) != 0
	lf.pick_up = (flags & 8) != 0
	lf.gait = NetSceneLib.GAITS[(flags >> 4) & 3]
	var corrected: Stamina.Stamina = null
	if flags & 64:
		var st := Stamina.Stamina.new()
		st.level = r[10] / 1000.0
		st.winded = (flags & 128) != 0
		lf.stamina = st
		corrected = c.correct_stamina(st)
	var f := c.frame(g + float(m.spec["offset"]), lf)
	(frames[m.id] as Array).append(NetSceneLib.frame_record(c, f, corrected))

