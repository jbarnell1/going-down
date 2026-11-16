# Snapshots of the ported state as plain data with the TypeScript field names, the canonical digest
# the reference files carry per tick, and reading and comparing the reference files.
# Must build exactly what godot/tools/dump_reference.ts builds (snapOrderly, snapCrew, ...).
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Bot = preload("res://sim/bot.gd")
const Follow = preload("res://sim/follow.gd")
const Run = preload("res://sim/run.gd")
const Stamina = preload("res://sim/stamina.gd")
const M = preload("res://sim/jsmath.gd")

## Fields derived from rate_at's pow, masked in the `exact` digest (as in dump_reference.ts).
const TAINT := {"value": true, "rate": true, "recorded": true, "tickHz": true, "loudness": true, "tickPhase": true,
	"ticks": true, "total": true, "peakRate": true, "lostValue": true, "carriedValue": true, "shares": true}

const TWO53 := 9007199254740992.0

# ---------------------------------------------------------------------------------------------
# Reference files.

static func load_ref(name: String) -> Variant:
	var text := FileAccess.get_file_as_string("res://tests/reference/" + name)
	if text.is_empty():
		push_error("missing reference file %s: run npm run godot:reference" % name)
		return null
	return decode(JSON.parse_string(text))

## JSON from a reference file to native values: "~hex" strings become exact floats, integral
## numbers become ints.
static func decode(v: Variant) -> Variant:
	if v is String:
		var s: String = v
		if s.begins_with("~") and s.length() == 17:
			return M.from_hex(s.substr(1))
		return s
	if v is float:
		var f: float = v
		if f == floorf(f) and absf(f) < TWO53:
			return int(f)
		return f
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(decode(x))
		return out
	if v is Dictionary:
		var d: Dictionary = v
		var out := {}
		for k: Variant in d:
			out[k] = decode(d[k])
		return out
	return v

# ---------------------------------------------------------------------------------------------
# The canonical digest.

## Plain data ready for the canonical text: floats that are not safe integers become "h" + bits.
static func hexify(v: Variant, mask: bool) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if f == floorf(f) and absf(f) < TWO53:
				return int(f)
			return "h" + M.to_hex(f)
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var out := {}
			for k: Variant in d:
				out[k] = "~" if (mask and TAINT.has(k)) else hexify(d[k], mask)
			return out
		TYPE_ARRAY:
			var out: Array = []
			for x: Variant in v:
				out.append(hexify(x, mask))
			return out
		TYPE_STRING_NAME:
			return String(v)
	return v

## The first 8 hex digits of the MD5 of the canonical text (dump_reference.ts canon + fnv).
static func digest(plain: Variant, mask: bool) -> String:
	return JSON.stringify(hexify(plain, mask), "", true).md5_text().substr(0, 8)

# ---------------------------------------------------------------------------------------------
# Comparing.

class Diff:
	## Values that differ by more than the tolerance (or in type, text, flags, shape).
	var bad := 0
	## Floats that differ but within the tolerance.
	var inexact := 0
	var compared := 0
	var first := ""

	func add(o: Diff) -> void:
		bad += o.bad
		inexact += o.inexact
		compared += o.compared
		if first.is_empty():
			first = o.first

	func ok() -> bool:
		return bad == 0

	func summary() -> String:
		return "%d values, %d differ%s, %d floats within 1e-9 but not identical" % [compared, bad, (" (first: %s)" % first) if bad > 0 else "", inexact]

const TOL := 1e-9

static func compare(got: Variant, want: Variant, path: String = "") -> Diff:
	var d := Diff.new()
	_cmp(got, want, path, d)
	return d

static func _num(v: Variant) -> bool:
	return v is int or v is float

static func _cmp(got: Variant, want: Variant, path: String, d: Diff) -> void:
	if got is StringName:
		got = String(got)
	if _num(got) and _num(want):
		d.compared += 1
		var g := float(got)
		var w := float(want)
		if g == w or (is_nan(g) and is_nan(w)):
			return
		if absf(g - w) <= TOL:
			d.inexact += 1
			return
		d.bad += 1
		if d.first.is_empty():
			d.first = "%s: got %s want %s" % [path, M.to_hex(g) if g != floorf(g) else str(g), M.to_hex(w) if w != floorf(w) else str(w)]
		return
	if got is Array and want is Array:
		var ga: Array = got
		var wa: Array = want
		if ga.size() != wa.size():
			d.bad += 1
			if d.first.is_empty():
				d.first = "%s: %d items, want %d" % [path, ga.size(), wa.size()]
		for i in mini(ga.size(), wa.size()):
			_cmp(ga[i], wa[i], "%s[%d]" % [path, i], d)
		return
	if got is Dictionary and want is Dictionary:
		var gd: Dictionary = got
		var wd: Dictionary = want
		for k: Variant in wd:
			if not gd.has(k):
				d.bad += 1
				if d.first.is_empty():
					d.first = "%s.%s missing" % [path, k]
				continue
			_cmp(gd[k], wd[k], "%s.%s" % [path, k], d)
		for k: Variant in gd:
			if not wd.has(k):
				d.bad += 1
				if d.first.is_empty():
					d.first = "%s.%s unexpected" % [path, k]
		return
	d.compared += 1
	if typeof(got) != typeof(want) or got != want:
		d.bad += 1
		if d.first.is_empty():
			d.first = "%s: got %s want %s" % [path, str(got), str(want)]

# ---------------------------------------------------------------------------------------------
# Snapshots.

static func pos(p: Floor.Pos) -> Dictionary:
	return {"level": p.level, "x": p.x, "y": p.y}

static func body(b: Move.Body) -> Variant:
	if b == null:
		return null
	return {"x": b.x, "z": b.z, "level": b.level, "y": b.y}

static func path_plain(path: Array[Floor.Pos]) -> Array:
	var out: Array = []
	for p in path:
		out.append(pos(p))
	return out

static func orderly(s: Entity.OrderlyState) -> Dictionary:
	return {
		"t": s.t, "body": body(s.body), "yaw": s.yaw, "mode": String(s.mode), "anim": String(s.anim), "animTime": s.anim_time,
		"seen": s.seen, "held": s.held, "frozen": s.frozen, "moving": s.moving, "everSeen": s.ever_seen, "seenTotal": s.seen_total,
		"lastSeenAt": s.last_seen_at, "targetId": s.target_id, "speed": s.speed, "preySpeed": s.prey_speed, "preyX": s.prey_x,
		"preyZ": s.prey_z, "preyId": s.prey_id, "path": null if s.path.is_empty() else path_plain(s.path), "pathNext": s.path_next,
		"replanIn": s.replan_in, "windUpLeft": s.wind_up_left, "windUpTarget": s.wind_up_target, "dormantLeft": s.dormant_left,
	}

static func stamina(s: Stamina.Stamina) -> Dictionary:
	return {"level": s.level, "winded": s.winded}

static func reading(r: TapeLib.Reading) -> Dictionary:
	return {"id": r.id, "playerId": r.player_id, "entityId": r.entity_id, "trait": String(r.trait_name), "value": r.value,
		"duration": r.duration, "peakRate": r.peak_rate, "closedAt": r.closed_at}

static func tape(t: TapeLib.Tape) -> Dictionary:
	var rs: Array = []
	for r in t.readings:
		rs.append(reading(r))
	return {"id": t.id, "ownerId": t.owner_id, "total": t.total, "readings": rs}

static func instrument(i: Instr.Instrument) -> Dictionary:
	var cur: Variant = null
	if i.current != null:
		var c := i.current
		cur = {"entityId": c.entity_id, "trait": String(c.trait_name), "value": c.value, "duration": c.duration, "quiet": c.quiet, "peakRate": c.peak_rate}
	return {"raised": i.raised, "needle": String(i.needle), "current": cur, "rate": i.rate, "factor": i.factor, "distance": i.distance,
		"tickHz": i.tick_hz, "loudness": i.loudness, "tickPhase": i.tick_phase, "ticks": i.ticks, "recorded": i.recorded}

static func crew(c: Instr.CrewState) -> Dictionary:
	var members: Array = []
	for m in c.members:
		var carrying: Array = []
		for t in m.carrying:
			carrying.append(tape(t))
		members.append({"id": m.id, "body": body(m.body), "active": m.active, "instrument": instrument(m.instrument), "tape": tape(m.tape), "carrying": carrying})
	var fl: Array = []
	for f in c.floor:
		fl.append({"tape": tape(f.tape), "at": body(f.at)})
	var slips: Array = []
	for s in c.slips_printed:
		slips.append(String(s))
	return {"t": c.t, "members": members, "floor": fl, "slipsPrinted": slips, "repeats": c.repeats.duplicate(), "nextTape": c.next_tape, "nextReading": c.next_reading}

static func walk(w: Variant) -> Variant:
	if w == null:
		return null
	var pw: Follow.PathWalk = w
	return {"next": pw.next, "path": path_plain(pw.path)}

static func bot(b: Bot.Bot) -> Dictionary:
	return {
		"id": b.id, "body": body(b.body), "yaw": b.yaw, "pitch": b.pitch, "heading": b.heading, "gait": String(b.gait), "gaitLeft": b.gait_left,
		"look": String(b.look), "lookLeft": b.look_left, "lookOffset": b.look_offset, "pitchWant": b.pitch_want, "walk": walk(b.walk),
		"stuck": b.stuck, "watchfulness": b.watchfulness, "oblivious": b.oblivious, "stamina": stamina(b.stamina), "moveGait": String(b.move_gait), "alarm": b.alarm,
	}

static func wait_bot(b: Bot.WaitBot) -> Dictionary:
	var route: Array = []
	for r in b.route:
		route.append(body(r))
	return {
		"id": b.id, "style": String(b.style), "body": body(b.body), "yaw": b.yaw, "pitch": b.pitch, "stamina": stamina(b.stamina), "gait": String(b.gait),
		"mode": String(b.mode), "spot": {"u": b.spot_u, "v": b.spot_v}, "seat": {"u": b.seat_u, "v": b.seat_v}, "walk": walk(b.walk),
		"route": route, "heard": body(b.heard), "rethink": b.rethink,
	}

static func rect(r: Run.Rect) -> Dictionary:
	return {"x0": r.x0, "z0": r.z0, "x1": r.x1, "z1": r.z1}

static func car(c: Run.CarGeometry) -> Dictionary:
	return {"wall": String(c.wall), "level": c.level, "floorY": c.floor_y, "doorX": c.door_x, "doorZ": c.door_z, "inX": c.in_x, "inZ": c.in_z,
		"rightX": c.right_x, "rightZ": c.right_z, "width": c.width, "depth": c.depth, "doorWidth": c.door_width,
		"rect": rect(c.rect), "bank": rect(c.bank), "down": rect(c.down)}

static func call_plan(p: Run.CallPlan) -> Dictionary:
	var darks: Array = []
	for d in p.darks:
		darks.append({"at": d.at, "len": d.len, "warn": d.warn, "blackout": d.blackout})
	return {"delay": p.delay, "floors": p.floors, "falseStop": p.false_stop, "extra": p.extra, "wait": p.wait, "darks": darks}

static func summary(s: Run.RunSummary) -> Variant:
	if s == null:
		return null
	var tapes: Array = []
	for t in s.tapes:
		tapes.append(t)
	return {"depth": s.depth, "readings": s.readings, "total": s.total, "shares": s.shares.duplicate(), "tapes": tapes, "wiped": s.wiped}

static func run(s: Run.RunState) -> Dictionary:
	var players: Array = []
	for p in s.players:
		players.append({"id": p.id, "body": body(p.body), "status": String(p.status), "aboard": p.aboard, "side": _sn(p.side)})
	var call_v: Variant = null
	if s.call != null:
		var c := s.call
		call_v = {"index": c.index, "at": c.at, "plan": call_plan(c.plan), "floorsAway": c.floors_away, "nextAt": c.next_at,
			"stopUntil": c.stop_until, "stopDoorsOpened": c.stop_doors_opened, "stopDoorsClosed": c.stop_doors_closed}
	var blink_v: Variant = null
	if s.blink != null:
		var b := s.blink
		blink_v = {"callIndex": b.call_index, "n": b.n, "at": b.at, "len": b.len, "warn": b.warn, "blackout": b.blackout, "announced": b.announced, "endsAt": b.ends_at}
	return {
		"seed": s.seed, "t": s.t, "depth": s.depth, "planSeed": s.plan.seed, "planDepth": s.plan.depth, "car": car(s.car),
		"orderly": orderly(s.orderly), "entityId": s.entity_id, "crew": crew(s.crew), "players": players, "phase": String(s.phase),
		"timer": s.timer, "emptyFor": s.empty_for, "calls": s.calls, "lastFloors": null if s.last_floors < 0 else s.last_floors,
		"call": call_v, "blink": blink_v, "lure": s.lure, "bellLeft": s.bell_left, "holdLeft": s.hold_left, "held": s.held, "summary": summary(s.summary),
	}

static func _sn(v: Variant) -> Variant:
	if v is StringName:
		return String(v)
	return v

## An event (or anything inside one) as plain data: bodies, readings and summaries become dictionaries.
static func plain(v: Variant) -> Variant:
	if v is StringName:
		return String(v)
	if v is Move.Body:
		return body(v)
	if v is TapeLib.Reading:
		return reading(v)
	if v is Run.RunSummary:
		return summary(v)
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

static func events(list: Array[Dictionary]) -> Array:
	var out: Array = []
	for e in list:
		out.append(plain(e))
	return out
