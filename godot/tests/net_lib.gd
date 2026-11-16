# Helpers of the network tests (ref_net.gd, net_scene.gd, prop_net.gd): the scene setups of
# tools/net_script.ts and tests/net/harness.ts, plain data and digests of messages and frames.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Stamina = preload("res://sim/stamina.gd")
const Snap = preload("res://tests/snap.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const HostRules = preload("res://net/host_rules.gd")

const FRAME := 1.0 / 60.0
const GAITS: Array[String] = ["walk", "creep", "sprint"]
const NET_TAINT := {"value": true, "rate": true, "recorded": true, "tickHz": true, "loudness": true, "tickPhase": true,
	"ticks": true, "total": true, "peakRate": true, "lostValue": true, "carriedValue": true, "shares": true, "open": true}

## tests/net/harness.ts huntSetup: players on the landing, the Orderly hunting, the car away.
static func hunt_setup(s: Run.RunState) -> Run.RunState:
	var out := s.copy()
	var players: Array[Run.RunPlayer] = []
	for i in s.players.size():
		var p := s.players[i].copy()
		p.body = Run.car_body(s.car, -0.7 - 0.45 * floorf(i / 2.0), 0.45 if i % 2 == 1 else -0.45)
		p.aboard = false
		players.append(p)
	out.players = players
	out.phase = &"away"
	var o := s.orderly.copy()
	o.mode = &"hunting"
	out.orderly = o
	return out

## tools/net_script.ts nearOrderly: the Orderly at the first cell `cells` steps from the landing.
static func near_orderly(s: Run.RunState, cells: int) -> Run.RunState:
	if cells <= 0:
		return s
	var d := Floor.distances_from(s.plan, s.plan.landing)
	for i in d.size():
		var p := Floor.pos_from_index(s.plan, i)
		if d[i] == cells and p.level == s.plan.landing.level:
			var out := s.copy()
			var o := s.orderly.copy()
			o.body = Move.body_at_cell(s.plan, p)
			out.orderly = o
			return out
	push_error("no cell %d steps from the landing" % cells)
	return s

## Plain data of anything the network layer holds (bodies, tanks, nested messages).
static func plain(v: Variant) -> Variant:
	if v is Move.Body:
		return Protocol.body_plain(v)
	if v is Stamina.Stamina:
		return {"level": v.level, "winded": v.winded}
	if v is StringName:
		return String(v)
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(plain(x))
		return out
	if v is Dictionary:
		var d: Dictionary = v
		var out := {}
		for k: Variant in d:
			out[k] = plain(d[k])
		return out
	return v

static func _hexify(v: Variant, mask: bool) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if f == floorf(f) and absf(f) < Snap.TWO53:
				return int(f)
			return "h" + Snap.M.to_hex(f)
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var out := {}
			for k: Variant in d:
				out[k] = "~" if (mask and NET_TAINT.has(k)) else _hexify(d[k], mask)
			return out
		TYPE_ARRAY:
			var out: Array = []
			for x: Variant in v:
				out.append(_hexify(x, mask))
			return out
	return v

## [masked, full] digests of a send [t, from, to, data] (dump_reference.ts canonNet).
static func message_digests(s: Array) -> Array[String]:
	var rec := {"t": s[0], "from": s[1], "to": s[2], "msg": plain(Protocol.decode(s[3]))}
	return [JSON.stringify(_hexify(rec, true), "", true).md5_text().substr(0, 8), JSON.stringify(_hexify(rec, false), "", true).md5_text().substr(0, 8)]

static func client_stats(c: Client) -> Dictionary:
	var s := c.stats
	return {"frames": s.frames, "darkFrames": s.dark_frames, "guardDarkFrames": s.guard_dark_frames, "reports": s.reports, "inputs": s.inputs,
		"inputBytes": s.input_bytes, "maxInputBytes": s.max_input_bytes, "snapshots": s.snapshots, "maxReleaseJump": s.max_release_jump,
		"releases": s.releases, "bigReleases": s.big_releases, "latches": s.latches, "falseLatches": s.false_latches}

## tools/net_script.ts frameRecord.
static func frame_record(c: Client, f: Client.Frame, corrected: Stamina.Stamina) -> Dictionary:
	var players: Array = []
	for p in f.players:
		players.append({"id": p["id"], "body": Protocol.body_plain(p["body"]), "yaw": p["yaw"], "pitch": p["pitch"], "active": p["active"], "status": p["status"], "gait": p["gait"]})
	var o: Variant = null
	if f.orderly != null:
		var po: Dictionary = f.orderly
		o = {"x": po["x"], "y": po["y"], "z": po["z"], "level": po["level"], "yaw": po["yaw"], "anim": po["anim"], "animTime": po["animTime"]}
	return {
		"dark": f.dark, "orderly": o, "visible": f.visible, "held": f.held, "seeing": f.seeing, "taken": f.taken, "depth": f.depth,
		"players": players, "renderTime": f.render_time, "placed": Protocol.body_plain(f.placed) if f.placed != null else null,
		"id": c.id, "playing": c.playing, "localDepth": c.local_depth, "events": c.events.size(), "latchReleased": c.latch_released,
		"hostStamina": {"level": c.host_stamina.level, "winded": c.host_stamina.winded} if c.host_stamina != null else null,
		"corrected": {"level": corrected.level, "winded": corrected.winded} if corrected != null else null,
	}

static func link_of(d: Dictionary) -> Transport.LinkConfig:
	var c := Transport.LinkConfig.new()
	c.delay = float(d.get("delay", 0.0))
	c.jitter = float(d.get("jitter", 0.0))
	c.loss = float(d.get("loss", 0.0))
	c.reorder = float(d.get("reorder", 0.0))
	c.reorder_delay = float(d.get("reorderDelay", 0.0))
	c.duplicate = float(d.get("duplicate", 0.0))
	return c

