# A whole networked session in one process, port of tests/net/harness.ts (Session): a host machine
# (the host's own player's client on a perfect link) and remote players' machines, all over the
# in-memory network, on one global clock with every machine's own clock offset from it. Each client
# renders at 60 frames a second in its own local time; a bot (sim/bot.gd) drives each player.
# Event-driven: time jumps to the next frame, tick or delivery. Bit for bit the TypeScript session
# for the same seed (the counts of tests/prop_net.gd are compared with TypeScript's).
extends RefCounted

const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Session = preload("res://net/session.gd")
const Pose = preload("res://net/pose.gd")
const NetLib = preload("res://tests/net_lib.gd")

const FRAME := 1.0 / 60.0

## The network of a session (tests/net/harness.ts NetConfig).
class NetConfig:
	var delay_min := 0.0
	var delay_max := 0.0
	var jitter := 0.0
	var loss := 0.0
	var reorder := 0.0
	var reorder_delay := 0.0
	var duplicate := 0.0

## The hostile network of the property tests (harness.ts LOSSY), and none at all (ZERO).
static func lossy() -> NetConfig:
	var n := NetConfig.new()
	n.delay_max = 0.25
	n.jitter = 0.06
	n.loss = 0.05
	n.reorder = 0.05
	n.reorder_delay = 0.1
	n.duplicate = 0.03
	return n

static func zero() -> NetConfig:
	return NetConfig.new()

class Machine:
	var id: String
	## Local clock = global time + offset.
	var offset: float
	var phase: float
	var k := 0
	var client: Client
	var bot: Bot.Bot = null
	var bot_depth := 0
	var body: Move.Body = null
	var rng: Rng
	var frames := 0
	var gone := false
	## The last frame this machine drew.
	var last: Client.Frame = null

var net: Transport.MemoryNetwork
var host: Host
var machines: Array[Machine] = []
var g := 0.0
var seed: String
var _cfg: NetConfig
var _rng: Rng
## Called after every frame: (machine, record Dictionary {g, local, rt, dark, seeing, held, pose, depth, cam, frame}).
var on_frame: Callable
## Called after every host update that ran a tick.
var on_tick: Callable
## Microseconds spent in host updates that ran a tick (receiving, the tick, every snapshot), and the worst.
var host_us := 0
var host_max_us := 0

func _init(seed_: String, remotes: int, cfg: NetConfig) -> void:
	seed = seed_
	_cfg = cfg
	_rng = Rng.make_rng("%s:session" % seed)
	net = Transport.MemoryNetwork.new("%s:net" % seed)
	var ids: Array[String] = []
	for i in remotes + 1:
		ids.append("p%d" % i)
	var host_t := net.connect_peer("host")
	host = Host.new(host_t, seed, ids, 0.0, NetLib.hunt_setup)
	for id in ids:
		add_machine(id, id != "p0")

## Connects a player's machine (a remote one gets a lossy link drawn from the config).
func add_machine(id: String, remote: bool) -> Machine:
	var n := _cfg
	var t := net.connect_peer(id)
	if remote:
		for pair: Array in [["host", id], [id, "host"]]:
			var delay := n.delay_min + _rng.next() * (n.delay_max - n.delay_min)
			net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
	var m := Machine.new()
	m.id = id
	m.offset = (_rng.next() - 0.5) * 200.0
	m.phase = g + _rng.next() * FRAME
	m.client = Client.new(t, "host", id, g + m.offset)
	m.rng = Rng.make_rng("%s:%s:intents" % [seed, id])
	machines.append(m)
	return m

func next_frame_at(m: Machine) -> float:
	return m.phase + m.k * FRAME

## Runs the session until global time `until`.
func run(until: float) -> void:
	while true:
		var next := INF if host.ended else host.next_tick_at()
		for m in machines:
			if not m.gone:
				next = minf(next, next_frame_at(m))
		var d: Variant = net.next_delivery()
		if d != null:
			next = minf(next, d)
		if next > until:
			break
		g = maxf(g, next)
		net.now = g
		var tick := host.tick
		var t0 := Time.get_ticks_usec()
		host.update(g)
		if host.tick != tick:
			var us := Time.get_ticks_usec() - t0
			host_us += us
			host_max_us = maxi(host_max_us, us)
		if host.tick != tick and on_tick.is_valid():
			on_tick.call(self)
		for m in machines:
			if not m.gone:
				m.client.receive(g + m.offset)
		for m in machines:
			if m.gone or next_frame_at(m) > g + 1e-12:
				continue
			_frame(m)
			m.k += 1
	g = until
	net.now = until

func _my_status(m: Machine) -> Variant:
	var latest: Variant = m.client.latest
	if latest == null:
		return null
	for p: Dictionary in latest["players"]:
		if p["id"] == m.client.id:
			return p["status"]
	return null

func _frame(m: Machine) -> void:
	var local := g + m.offset
	var c := m.client
	m.frames += 1
	var plan := Session.plan_for(seed, c.local_depth)
	# The bot flees (sprints) from the Orderly where this machine last drew it, if it is close behind.
	var seen: Variant = m.last.orderly if m.last != null else null
	# Taken (the screen latched blind at the end of a wind-up on it): the game holds the player still.
	var taken := m.last != null and m.last.taken
	if m.bot != null and not taken and m.bot_depth == c.local_depth and c.playing and _my_status(m) == "ok":
		Bot.step_bot(plan, m.bot, FRAME, Pose.pose_body(seen) if seen != null else null)
	if m.bot != null:
		m.body = m.bot.body
	var v: Variant = Bot.bot_view(m.bot) if m.bot != null else null
	var car := Session.car_for(plan)
	var body := m.body if m.body != null else Run.car_body(car, 0.8, 0.0)
	# Intents: the instrument up some of the time; the call pressed every 2 s within reach of the doors.
	var near_door := M.hypot2(body.x - car.door_x, body.z - car.door_z) <= Run.CALL_REACH - 0.3
	var slot := int(floorf(g * 2.0 + float(m.id.substr(1).to_int())))
	var lf := Client.LocalFrame.new()
	lf.body = body
	lf.eye = Bot.BOT_EYE
	lf.yaw = v.yaw if v != null else 0.0
	lf.pitch = v.pitch if v != null else 0.0
	lf.h_fov_deg = v.h_fov_deg if v != null else 90.0
	lf.v_fov_deg = v.v_fov_deg if v != null else 70.0
	var gait := String(m.bot.move_gait) if m.bot != null else "walk"
	# A sprinting bot has its instrument down (a raised instrument rules out a sprint).
	lf.raised = slot % 5 < 2 and gait != "sprint"
	lf.call = near_door and m.frames % 120 == 7
	lf.gait = gait
	var f := c.frame(local, lf)
	m.last = f
	if f.placed != null:
		_adopt(m, f.placed, c.local_depth)
	var cam := Pose.Camera.make(f.placed if f.placed != null else lf.body, lf.eye, lf.yaw, lf.pitch, lf.h_fov_deg, lf.v_fov_deg)
	if on_frame.is_valid():
		on_frame.call(m, {"g": g, "local": local, "rt": f.render_time, "dark": f.dark, "seeing": f.seeing, "held": f.held, "pose": f.orderly, "depth": f.depth, "cam": cam, "frame": f})

## The host moved the player: the bot starts again from there.
func _adopt(m: Machine, body: Move.Body, depth: int) -> void:
	m.body = body
	var plan := Session.plan_for(seed, depth)
	var cell := Move.cell_of(plan, body)
	var start := cell if Floor.is_walkable(plan, cell.level, cell.x, cell.y) else plan.landing
	var watch := m.rng.next()
	var oblivious := m.rng.next() < 0.25
	m.bot = Bot.create_bot(plan, m.id, "%s:%s:%d:%d" % [seed, m.id, depth, m.frames], watch, oblivious, start)
	m.bot.body = body
	m.bot_depth = depth

## A machine leaves the session (sends leave and drops off the network).
func leave(id: String) -> void:
	for m in machines:
		if m.id == id and not m.gone:
			m.client.leave()
			m.gone = true
