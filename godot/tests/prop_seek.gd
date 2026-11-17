# The Minder and the count (docs/floors/playarea.md sections 2 to 5, 7 and 8): the nine properties of
# section 5, the count clock, every provocation, hides in and out, health and the last count.
#
# The oracles here are the test's own: the clock, the found rules, the provocations and the health
# rates are restated from the design and worked out with this file's geometry (angles by atan2, not
# seek.gd's cosines; bodies from playroom.gd's hide list, not seek.gd's). Only Sight.has_line_of_sight
# (the clear line the design names) and the floor's own lists (playroom.gd) are shared. seek.gd is
# driven only through create_seek, step_seek and the state it returns.
#
# Sizes: 40 Playrooms (seed-0..39, depths 1 to 4 in turn); 6 in the quick set. The statistical checks
# (the 1 in n share, the third of counts) run at the default sizes only.
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Seek = preload("res://sim/seek.gd")
const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Sight = preload("res://sim/sight.gd")
const Rng = preload("res://sim/rng.gd")
const Me = preload("res://tests/prop_seek.gd")

const DT := 0.05
const QUICK_FLOORS := 6
const FLOORS := 40

# The design's numbers, restated (not imported).
const O_HIDE := 6.0
const O_LENGTHS: Array[float] = [30.0, 35.0, 40.0, 45.0]
const O_LAST := 40.0
const O_LAST_AFTER := 6.0
const O_CALM := 15.0
const O_SIGHT_RANGE := 12.0
const O_SIGHT_HALF := PI / 3.0
const O_FOUND := 1.0
const O_TOUCH := 0.9
const O_GAP_RANGE := 4.0
const O_GAP_HALF := PI / 6.0
const O_LOOK := 2.0
const O_LOOK_REACH := 0.5
const O_BUMP := 0.5
const O_TICK_RANGE := 5.0
const O_REACH := 1.2
const O_IN := [1.5, 0.5]
const O_OUT := [1.0, 0.4]
const O_WALK := 3.0
const O_SPRINT := 8.0
const O_REST := 1.0
## The Minder's head above its feet, and the heights tested on a player's body (seek.gd's doc).
const O_HEAD := 1.4
const O_POINTS: Array[float] = [0.3, 0.9, 1.5]
## Within this of an edge a judgement is borderline and either answer is accepted.
const BAND := 1e-6
const TEPS := 1e-6

const BOT_RADIUS := 0.3
const CREEP := 1.2
const WALK := 3.0
const SPRINT := 5.0

static var _floors := {}

# =============================================================================================
# Floors.

class Fl:
	var plan: Floor.FloorPlan
	var data: Seek.SeekFloor
	var hides: Dictionary  # id -> Playroom.Hide (from playroom.gd)
	var hide_list: Array[Playroom.Hide]
	var squeak: Dictionary
	var zones: Array[Playroom.Zone]
	var walkway: Array[Floor.Pos] = []

static func floor_of(i: int) -> Fl:
	if not _floors.has(i):
		var f := Fl.new()
		f.plan = Playroom.generate_playroom("seed-%d" % i, 1 + i % 4)
		f.data = Seek.SeekFloor.make(f.plan)
		f.hide_list = Playroom.hides(f.plan, f.plan.seed)
		f.hides = {}
		for h in f.hide_list:
			f.hides[h.id] = h
		f.squeak = {}
		for k in Playroom.squeakers(f.plan, f.plan.seed):
			f.squeak[k] = true
		f.zones = Playroom.zones(f.plan)
		for y in f.plan.height:
			for x in f.plan.width:
				if Floor.cell_at(f.plan, 0, x, y) == Floor.CORRIDOR:
					f.walkway.append(Floor.Pos.make(0, x, y))
		_floors[i] = f
	return _floors[i]

static func floor_count(t: T) -> int:
	return QUICK_FLOORS if t.quick else FLOORS

static func pt(plan: Floor.FloorPlan, cm: Vector2i, level: int) -> Move.Body:
	var x := cm.x / 100.0
	var z := cm.y / 100.0
	return Move.Body.make(x, z, level, Move.feet_height(plan, level, x, z))

static func cell_body(plan: Floor.FloorPlan, c: Floor.Pos) -> Move.Body:
	return Move.body_at_cell(plan, c)

static func inp(id: String, b: Move.Body, gait: StringName = &"creep") -> Seek.SeekInput:
	return Seek.SeekInput.make(id, b, gait)

static func flin(call: bool = false, by: String = "", boarding: bool = false, riding: bool = false) -> Seek.FloorInput:
	var f := Seek.FloorInput.new()
	f.call = call
	f.call_by = by
	f.boarding = boarding
	f.riding = riding
	return f

static func horiz(a: Move.Body, b: Move.Body) -> float:
	return sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z))

# =============================================================================================
# The test's own geometry.

static func _wrap(a: float) -> float:
	var r := fmod(a, 2.0 * PI)
	if r > PI:
		r -= 2.0 * PI
	if r < -PI:
		r += 2.0 * PI
	return r

## 1 inside, 0 outside, -1 too close to call: horizontal range and the angle off its facing.
static func cone(mb: Move.Body, yaw: float, x: float, z: float, range_: float, half: float) -> int:
	var dx := x - mb.x
	var dz := z - mb.z
	var d := sqrt(dx * dx + dz * dz)
	if d > range_ + BAND:
		return 0
	var r_edge := absf(d - range_) <= BAND
	if d < 1e-9:
		return -1 if r_edge else 1
	# Its face points along (-sin yaw, -cos yaw); the way to the point has the yaw atan2(-dx, -dz).
	var off := absf(_wrap(atan2(-dx, -dz) - yaw))
	if off > half + BAND:
		return 0
	if absf(off - half) <= BAND or r_edge:
		return -1
	return 1

static func clear_line(plan: Floor.FloorPlan, mb: Move.Body, x: float, y: float, z: float, level: int) -> bool:
	var head := Sight.Point3.make(mb.x, mb.y + O_HEAD, mb.z, mb.level)
	return Sight.has_line_of_sight(plan, head, Sight.Point3.make(x, y, z, level))

## Rule 1, three-valued.
static func o_sight(plan: Floor.FloorPlan, mb: Move.Body, yaw: float, b: Move.Body) -> int:
	var c := cone(mb, yaw, b.x, b.z, O_SIGHT_RANGE, O_SIGHT_HALF)
	if c == 0:
		return 0
	for h in O_POINTS:
		if clear_line(plan, mb, b.x, b.y + h, b.z, b.level):
			return c
	return 0

## Rule 4, three-valued.
static func o_gap(plan: Floor.FloorPlan, mb: Move.Body, yaw: float, h: Playroom.Hide) -> int:
	var e := pt(plan, h.inside, h.level)
	var c := cone(mb, yaw, e.x, e.z, O_GAP_RANGE, O_GAP_HALF)
	if c == 0:
		return 0
	return c if clear_line(plan, mb, e.x, e.y + h.eye / 100.0, e.z, e.level) else 0

## Within `reach` on the same level, three-valued.
static func o_near(mb: Move.Body, b: Move.Body, reach: float) -> int:
	if b.level != mb.level:
		return 0
	var d := horiz(mb, b)
	if absf(d - reach) <= BAND:
		return -1
	return 1 if d < reach else 0

## The test's own lookup of a player in a state.
static func pl(s: Seek.SeekState, id: String) -> Seek.SeekPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

## Whether a test light lights the Minder: the cone through Sight.can_see, no margin, to its range.
static func o_light(plan: Floor.FloorPlan, l: Seek.Light, mb: Move.Body) -> bool:
	var v := Sight.Viewer.new()
	v.body = Move.Body.make(l.x, l.z, l.level, l.y)
	v.eye = 0.0
	v.yaw = l.yaw
	v.pitch = l.pitch
	v.h_fov_deg = 2.0 * l.half_deg
	v.v_fov_deg = 2.0 * l.half_deg
	return Sight.can_see(plan, v, mb, 0.0, l.range, 2.3, 0.35)

# =============================================================================================
# A run with the oracle watching every tick.

class Run:
	var t: T
	var f: Fl
	var plan: Floor.FloorPlan
	var state: Seek.SeekState
	var tag: String
	var hide_list: Array[Playroom.Hide] = []
	var events: Array[Dictionary] = []
	var last_events: Array[Dictionary] = []
	# The test's own clock.
	var counting := false
	var t0 := 0.0
	var len := 0.0
	var last := false
	var n := 0
	var ended := 0
	var end_t := -1.0e9
	var called := false
	var done := false
	var pending_last: Variant = null
	var hide_body: Move.Body = null
	var hide_yaw := 0.0
	# Totals, lowest and highest the borderline ticks allow.
	var smin := {}
	var smax := {}
	var gmin := {}
	var gmax := {}
	var looks := {}
	var marks := {}  # player id -> [zone, hide, mark time, drawn hide]
	var reason_t := {}
	var found_in_count := {}
	var last_body := {}
	# Tallies.
	var counts_seen := 0
	var found_by_cause := {}
	var counts_with_found := 0
	var found_this_count := 0
	var counts_finished := 0

	func now() -> float:
		return state.t

	func player(id: String) -> Seek.SeekPlayer:
		return Me.pl(state, id)

	func step(inputs: Array[Seek.SeekInput], fl: Seek.FloorInput = null) -> Array[Dictionary]:
		if fl == null:
			fl = Seek.FloorInput.new()
		var prev := state
		var r := Seek.step_seek(prev, inputs, DT, fl)
		state = r.state
		last_events = r.events
		for e in r.events:
			events.append(e)
		_check(prev, r.state, r.events, inputs, fl)
		return r.events

	func fail(msg: String) -> void:
		t.check(false, "%s t=%.2f: %s" % [tag, state.t, msg])

	func phase_at(time: float) -> StringName:
		if not counting:
			return &"none"
		return &"hide" if time < t0 + O_HIDE - TEPS else &"seek"

	func may_provoke(time: float, fl: Seek.FloorInput) -> bool:
		return not counting and not called and not done and not fl.riding and not fl.boarding \
			and (ended == 0 or time >= end_t + O_CALM - TEPS)

	## The provocations this input makes this tick, by the test's geometry: [sure causes, possible causes].
	func causes_of(prev: Seek.SeekState, ps: Seek.SeekPlayer, pp: Seek.SeekPlayer, i: Seek.SeekInput, evs: Array[Dictionary]) -> Array:
		var sure := {}
		var maybe := {}
		if i.dropped_tape:
			sure[&"tape"] = true
		if pp == null or pp.status != &"ok":
			return [sure, sure.merged(maybe)]
		var moved: bool = last_body.has(i.id) and (last_body[i.id].level != i.body.level or Me.horiz(last_body[i.id], i.body) > 1e-6)
		if ps.phase == &"out":
			if i.gait == &"sprint":
				sure[&"sprint"] = true
			if moved and i.gait != &"creep":
				var c := Move.cell_of(plan, i.body)
				if f.squeak.has(Floor.pos_index(plan, c)):
					sure[&"squeaker"] = true
				var r_now := Floor.room_id_at(plan, c.level, c.x, c.y)
				var pc := Move.cell_of(plan, last_body[i.id])
				var r_before := Floor.room_id_at(plan, pc.level, pc.x, pc.y)
				if r_now >= 0 and plan.rooms[r_now].kind == &"ballpit" and r_before != r_now:
					sure[&"ballpit"] = true
		for e in evs:
			if (e["type"] == "hideStart" or e["type"] == "hideLeave") and e["playerId"] == i.id and e["fast"]:
				sure[&"flap"] = true
		if i.emote_sound:
			sure[&"emote"] = true
		if i.voice:
			sure[&"voice"] = true
		if ps.phase != &"inside":
			var b := Me.o_near(prev.minder.body, ps.body, O_BUMP)
			if b == 1:
				sure[&"bump"] = true
			elif b == -1:
				maybe[&"bump"] = true
		if i.light != null and Me.o_light(plan, i.light, prev.minder.body):
			sure[&"light"] = true
		return [sure, sure.merged(maybe)]

	func _check(prev: Seek.SeekState, s: Seek.SeekState, evs: Array[Dictionary], inputs: Array[Seek.SeekInput], fl: Seek.FloorInput) -> void:
		var time := s.t
		var was_counting := counting
		var input_of := {}
		for i in inputs:
			input_of[i.id] = i
		var started := false
		# The clock.
		for e in evs:
			if e["type"] == "countEnd":
				if not counting:
					fail("a count ended that was not running")
				elif absf(time - (t0 + O_HIDE + len)) > TEPS:
					fail("count %d ended at %.4f, want %.4f" % [n, time, t0 + O_HIDE + len])
				counting = false
				ended += 1
				end_t = time
				counts_finished += 1
				if found_this_count > 0:
					counts_with_found += 1
				if last:
					done = true
				for p in s.players:
					if p.status == &"found":
						fail("%s still found, not taken, after the count" % p.id)
		for e in evs:
			if e["type"] != "count":
				continue
			started = true
			var why: String = e["why"]
			if counting:
				fail("a count started during a count")
			if why == "call":
				if not e["last"] or absf(float(e["len"]) - O_LAST) > TEPS:
					fail("the call's count is not the last count of 40 s: %s" % str(e))
				if pending_last != null and absf(time - float(pending_last)) > TEPS:
					fail("the last count started at %.4f, want %.4f" % [time, float(pending_last)])
				if pending_last == null and not (fl.call and not called):
					fail("a last count started with no call")
				called = true
				pending_last = null
			else:
				if not may_provoke(time, fl):
					fail("count started by %s (%s) when nothing may provoke (calm %s, called %s, ride %s, boarding %s)" % [e["by"], why, str(ended > 0 and time < end_t + O_CALM - TEPS), str(called), str(fl.riding), str(fl.boarding)])
				var want_len: float = O_LENGTHS[mini(n, O_LENGTHS.size() - 1)]
				if absf(float(e["len"]) - want_len) > TEPS or e["last"]:
					fail("count %d is %s s, want %s" % [n + 1, str(e["len"]), str(want_len)])
				var by: String = e["by"]
				var ci: Seek.SeekInput = input_of.get(by, null)
				if ci == null:
					fail("count started by %s who sent no input" % by)
				else:
					var pp := Me.pl(prev, by)
					var cs: Array = causes_of(prev, Me.pl(s, by), pp, ci, evs)
					var maybe: Dictionary = cs[1]
					if not maybe.has(StringName(why)):
						fail("count started by %s for %s, which the test does not see" % [by, why])
					if why == "horn":
						fail("the horn started a count")
			if int(e["n"]) != n + 1 or absf(float(e["t0"]) - time) > TEPS:
				fail("count event %s: want n %d and t0 now" % [str(e), n + 1])
			n += 1
			counting = true
			t0 = time
			len = float(e["len"])
			last = e["last"]
			counts_seen += 1
			found_this_count = 0
			smin = {}
			smax = {}
			gmin = {}
			gmax = {}
			looks = {}
			marks = {}
			reason_t = {}
			found_in_count = {}
			hide_body = s.minder.body
			hide_yaw = s.minder.yaw
		# A call during a count: the last count is due LAST_AFTER after it ends.
		if fl.call and not called and not done and not started:
			if was_counting and counting:
				pending_last = t0 + O_HIDE + len + O_LAST_AFTER
				called = true
			elif not counting:
				fail("the call started no count")
		# Provocations that must have started a count (no provocation is missed).
		if not started and may_provoke(time, fl) and not was_counting:
			for i in inputs:
				if not i.active:
					continue
				var cs: Array = causes_of(prev, Me.pl(s, i.id), Me.pl(prev, i.id), i, evs)
				var sure: Dictionary = cs[0]
				if not sure.is_empty():
					fail("%s provoked (%s) and no count started" % [i.id, str(sure.keys())])
		var phase := phase_at(time)
		var by_type := {}
		for e in evs:
			var ty: String = e["type"]
			if not by_type.has(ty):
				by_type[ty] = []
			by_type[ty].append(e)
		# The 6 seconds are free.
		if phase == &"hide":
			if time > t0 + TEPS:
				if not s.minder.body.same(hide_body) or s.minder.yaw != hide_yaw:
					fail("the Minder moved or turned in the 6 s")
			for ty: String in ["reason", "found", "look", "lookDone", "draw", "sweep", "taken"]:
				if by_type.has(ty):
					fail("a %s event in the 6 s" % ty)
			for p in s.players:
				if p.sight != 0.0 or p.gap != 0.0:
					fail("%s has a total in the 6 s (sight %.3f, gap %.3f)" % [p.id, p.sight, p.gap])
		# Found.
		var found_of := {}
		for e: Dictionary in by_type.get("found", []):
			var pid: String = e["playerId"]
			if found_of.has(pid):
				fail("%s found twice in one tick" % pid)
			found_of[pid] = e
			if phase != &"seek":
				fail("%s found (%s) outside a count's search" % [pid, e["cause"]])
		for e: Dictionary in by_type.get("look", []):
			looks[int(e["hide"])] = time
		var done_hides := {}
		for e: Dictionary in by_type.get("lookDone", []):
			var h: int = e["hide"]
			done_hides[h] = true
			var hd: Playroom.Hide = f.hides[h]
			var fb := Me.pt(plan, hd.front, hd.level)
			if fb.level != s.minder.body.level or Me.horiz(fb, s.minder.body) > O_LOOK_REACH + BAND:
				fail("looked in hide %d from %.2f m off its front" % [h, Me.horiz(fb, s.minder.body)])
			if not looks.has(h) or absf(time - float(looks[h]) - O_LOOK) > TEPS:
				fail("finished looking in hide %d without %.1f s at it" % [h, O_LOOK])
		if phase == &"seek":
			for p in s.players:
				var i: Seek.SeekInput = input_of.get(p.id, null)
				var pp := Me.pl(prev, p.id)
				if i == null or not i.active or pp == null or pp.status != &"ok":
					if found_of.has(p.id):
						fail("%s found though not in play" % p.id)
					continue
				var body := i.body
				if p.phase == &"inside":
					var hd: Playroom.Hide = f.hides[p.hide]
					body = Me.pt(plan, hd.inside, hd.level)
				elif p.phase == &"leaving":
					var hd2: Playroom.Hide = f.hides[p.hide]
					body = Me.pt(plan, hd2.front, hd2.level)
				var sure := {}
				var maybe := {}
				var mb := s.minder.body
				var yaw := s.minder.yaw
				if p.phase != &"inside":
					var sv := Me.o_sight(plan, mb, yaw, body)
					if sv == 1:
						smin[p.id] = float(smin.get(p.id, 0.0)) + DT
					if sv != 0:
						smax[p.id] = float(smax.get(p.id, 0.0)) + DT
					if float(smin.get(p.id, 0.0)) >= O_FOUND - TEPS:
						sure[&"sight"] = true
					if float(smax.get(p.id, 0.0)) >= O_FOUND - TEPS:
						maybe[&"sight"] = true
					var tv := Me.o_near(mb, body, O_TOUCH)
					if tv == 1:
						sure[&"touch"] = true
					if tv != 0:
						maybe[&"touch"] = true
				elif i.peek:
					if not p.peeking and p.status == &"ok":
						fail("%s holds W inside a hide and is not peeking" % p.id)
					var gv := Me.o_gap(plan, mb, yaw, f.hides[p.hide])
					if gv == 1:
						gmin[p.id] = float(gmin.get(p.id, 0.0)) + DT
					if gv != 0:
						gmax[p.id] = float(gmax.get(p.id, 0.0)) + DT
					if float(gmin.get(p.id, 0.0)) >= O_FOUND - TEPS:
						sure[&"gap"] = true
					if float(gmax.get(p.id, 0.0)) >= O_FOUND - TEPS:
						maybe[&"gap"] = true
				if p.phase != &"out" and done_hides.has(p.hide):
					sure[&"look"] = true
					maybe[&"look"] = true
				if found_of.has(p.id):
					var cause := StringName(found_of[p.id]["cause"])
					if not maybe.has(cause):
						fail("%s found by %s, which the test's geometry does not show (it shows %s)" % [p.id, cause, str(maybe.keys())])
					found_by_cause[cause] = int(found_by_cause.get(cause, 0)) + 1
					found_in_count[p.id] = true
					found_this_count += 1
					if cause == &"look" and marks.has(p.id):
						var mk: Array = marks[p.id]
						var h: int = mk[1]
						if h != int(mk[3]) and not (reason_t.has(h) and float(reason_t[h]) >= float(mk[2])):
							fail("%s found looking in hide %d of cleared zone %d with no reason" % [p.id, h, mk[0]])
				elif not sure.is_empty():
					fail("%s has %s true and is not found" % [p.id, str(sure.keys())])
		# Cleared means cleared: marks.
		for e: Dictionary in by_type.get("reason", []):
			reason_t[int(e["hide"])] = time
			if phase != &"seek":
				fail("a reason logged outside a count's search")
		for e: Dictionary in by_type.get("draw", []):
			var z: int = e["zone"]
			var drawn: int = e["hide"]
			var list: Array = []
			for h in hide_list:
				if h.zone == z:
					list.append(h.id)
			if int(e["n"]) != list.size():
				fail("draw in zone %d says n %s, the zone has %d" % [z, str(e["n"]), list.size()])
			if drawn >= 0 and not list.has(drawn):
				fail("drew hide %d, not in zone %d" % [drawn, z])
			for p in s.players:
				if p.status == &"ok" and p.phase == &"inside" and (f.hides[p.hide] as Playroom.Hide).zone == z:
					marks[p.id] = [z, p.hide, time, drawn]
		for pid: String in marks.keys():
			var p := Me.pl(s, pid)
			var mk: Array = marks[pid]
			if p == null or p.phase != &"inside" or p.hide != int(mk[1]):
				marks.erase(pid)
		# Taken only during a count, and only the found.
		for e: Dictionary in by_type.get("taken", []):
			var pid: String = e["playerId"]
			if not was_counting:
				fail("%s taken while no count was running" % pid)
			var pp := Me.pl(prev, pid)
			if pp == null or (pp.status != &"found" and not found_of.has(pid)):
				fail("%s taken without being found" % pid)
		for p in s.players:
			var pp := Me.pl(prev, p.id)
			if pp != null and pp.status != &"ok" and p.status == &"ok":
				fail("%s back in play by itself" % p.id)
			if p.status == &"found" and (pp == null or pp.status != &"found") and not found_of.has(p.id):
				fail("%s found with no event" % p.id)
		# Health.
		for p in s.players:
			var pp := Me.pl(prev, p.id)
			if pp == null:
				continue
			if p.health < 0.0 or p.health > 100.0:
				fail("%s health %.3f out of 0..100" % [p.id, p.health])
			var i: Seek.SeekInput = input_of.get(p.id, null)
			if counting or ended == 0:
				if p.health != pp.health:
					fail("%s health changed %.3f -> %.3f %s" % [p.id, pp.health, p.health, "during a count" if counting else "before the first count ended"])
			elif i != null and i.active and pp.status == &"ok" and not fl.riding:
				var moved: bool = last_body.has(p.id) and (last_body[p.id].level != i.body.level or Me.horiz(last_body[p.id], i.body) > 1e-6)
				var rate := O_REST
				if p.phase == &"out" and moved:
					if i.gait == &"sprint":
						rate = -O_SPRINT
					elif i.gait == &"walk":
						rate = -O_WALK
				var want := clampf(pp.health + rate * DT, 0.0, 100.0)
				if absf(p.health - want) > 1e-9:
					fail("%s health %.6f, want %.6f (%s, moved %s)" % [p.id, p.health, want, i.gait, str(moved)])
				if i.gait == &"creep" and p.health < pp.health:
					fail("%s lost health creeping" % p.id)
				if p.health <= 0.0 and p.status != &"down":
					fail("%s at 0 health and not down" % p.id)
			elif p.health != pp.health:
				fail("%s health changed out of play" % p.id)
		for i in inputs:
			if i.active:
				last_body[i.id] = i.body

static func new_run(t: T, f: Fl, ids: Array[String], tag: String, data: Seek.SeekFloor = null) -> Run:
	var r := Run.new()
	r.t = t
	r.f = f
	r.plan = f.plan
	r.tag = "%s %s d%d" % [tag, f.plan.seed, f.plan.depth]
	r.state = Seek.create_seek(f.plan, ids, data if data != null else f.data)
	r.hide_list = data.hides if data != null else f.hide_list
	return r

## Steps with the same inputs (bodies unchanged) for `secs` seconds.
static func idle(r: Run, inputs: Array[Seek.SeekInput], secs: float, fl: Seek.FloorInput = null) -> void:
	var k := int(roundf(secs / DT))
	for _i in k:
		r.step(inputs, fl)

static func has_event(evs: Array[Dictionary], ty: String) -> Dictionary:
	for e in evs:
		if e["type"] == ty:
			return e
	return {}

## Walkway cells at least `far` m from the Minder's start, in a seeded order.
static func far_cells(f: Fl, far: float, rng: Rng) -> Array[Floor.Pos]:
	var start := cell_body(f.plan, f.plan.entity_start)
	var out: Array[Floor.Pos] = []
	for c in f.walkway:
		if horiz(cell_body(f.plan, c), start) >= far:
			out.append(c)
	for i in range(out.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp := out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

## A count started and run to its end with its starter gone (inactive), so nobody is hunted.
static func run_out_count(r: Run, id: String, b: Move.Body) -> void:
	var s := inp(id, b, &"sprint")
	r.step([s])
	var gone := inp(id, b)
	gone.active = false
	while r.counting:
		r.step([gone])

# =============================================================================================
# The count clock: 6 s, then 30, 35, 40, 45, 45; the 15 s; rides and boarding.

func test_count_clock(t: T) -> void:
	var f := floor_of(0)
	var rng := Rng.make_rng("prop_seek:clock")
	var spot := cell_body(f.plan, far_cells(f, 10.0, rng)[0])
	var r := new_run(t, f, ["a"], "clock")
	idle(r, [inp("a", spot)], 1.0)
	var lens: Array[float] = []
	for k in 5:
		var e0 := r.events.size()
		run_out_count(r, "a", spot)
		var c := {}
		var end := {}
		for e: Dictionary in r.events.slice(e0):
			if e["type"] == "count":
				c = e
			if e["type"] == "countEnd":
				end = e
		lens.append(float(c.get("len", -1.0)))
		t.check(not c.is_empty() and not end.is_empty() and absf(float(end["t"]) - float(c["t0"]) - O_HIDE - float(c["len"])) < TEPS, "count %d ran from %s to %s" % [k + 1, str(c.get("t0")), str(end.get("t"))])
		# The 15 s: a sprint 0.05 s short of it starts nothing, a sprint at it starts the next count.
		var gone := inp("a", spot)
		gone.active = false
		idle(r, [gone], O_CALM - 2.0 * DT)
		if k < 4:
			var evs := r.step([inp("a", spot, &"sprint")])
			t.check(has_event(evs, "count").is_empty(), "count %d: a sprint 14.95 s after it started one" % (k + 1))
	t.eq(str(lens), str([30.0, 35.0, 40.0, 45.0, 45.0]), "count lengths")
	# Ride and boarding: no count can start.
	var r2 := new_run(t, f, ["a"], "clock-ride")
	idle(r2, [inp("a", spot)], 0.5)
	var evs2 := r2.step([inp("a", spot, &"sprint")], flin(false, "", false, true))
	var evs3 := r2.step([inp("a", spot, &"sprint")], flin(false, "", true, false))
	t.check(has_event(evs2, "count").is_empty() and has_event(evs3, "count").is_empty(), "a count started in a ride or while boarding")
	var evs4 := r2.step([inp("a", spot, &"sprint")])
	t.check(not has_event(evs4, "count").is_empty(), "a sprint after the ride started no count")
	t.note("five counts: %s s after 6 s to hide; 15 s of calm checked to the tick; none in a ride or boarding" % str(lens))

# =============================================================================================
# Property 2: any provocation, one tick, anywhere; the horn is harmless; walking and creeping never.

## [squeaker cell, a walkable neighbour] on level 0, or [].
static func squeaker_pair(f: Fl) -> Array:
	for k: int in f.squeak.keys():
		var c := Floor.pos_from_index(f.plan, k)
		for d: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
			var nb := Floor.Pos.make(c.level, c.x + d.x, c.y + d.y)
			if Floor.can_step(f.plan, nb, c) and not f.squeak.has(Floor.pos_index(f.plan, nb)) \
				and Floor.room_id_at(f.plan, c.level, c.x, c.y) == Floor.room_id_at(f.plan, nb.level, nb.x, nb.y):
				return [c, nb]
	return []

## [walkway cell, ball-pit room cell] joined by a door, or [].
static func ballpit_door(f: Fl) -> Array:
	for d in f.plan.doors:
		var ra := Floor.room_id_at(f.plan, d.level, d.ax, d.ay)
		var rb := Floor.room_id_at(f.plan, d.level, d.bx, d.by)
		if rb >= 0 and f.plan.rooms[rb].kind == &"ballpit" and Floor.cell_at(f.plan, d.level, d.ax, d.ay) == Floor.CORRIDOR:
			return [Floor.Pos.make(d.level, d.ax, d.ay), Floor.Pos.make(d.level, d.bx, d.by)]
		if ra >= 0 and f.plan.rooms[ra].kind == &"ballpit" and Floor.cell_at(f.plan, d.level, d.bx, d.by) == Floor.CORRIDOR:
			return [Floor.Pos.make(d.level, d.bx, d.by), Floor.Pos.make(d.level, d.ax, d.ay)]
	return []

## Steps once with `doing` after 0.2 s of quiet at `before`; returns the count event or {}.
static func provoke_once(t: T, f: Fl, before: Move.Body, doing: Seek.SeekInput, tag: String, quiet_secs: float = 0.2) -> Dictionary:
	var r := new_run(t, f, [doing.id], tag)
	idle(r, [inp(doing.id, before)], quiet_secs)
	var evs := r.step([doing])
	var c := has_event(evs, "count")
	if not c.is_empty():
		t.check(c["by"] == doing.id and absf(float(c["t0"]) - r.now()) < TEPS, "%s: count %s not by %s now" % [tag, str(c), doing.id])
	return c

func test_provocations(t: T) -> void:
	var rows := {}
	var floors := floor_count(t)
	for fi in floors:
		var f := floor_of(fi)
		var rng := Rng.make_rng("prop_seek:provoke:%d" % fi)
		var cells := far_cells(f, 8.0, rng)
		var a := cell_body(f.plan, cells[0])
		var step_to := func(b: Move.Body, dx: float) -> Move.Body:
			return Move.Body.make(b.x + dx, b.z, b.level, b.y)
		var expect := func(c: Dictionary, why: String, tag: String) -> void:
			t.check(not c.is_empty() and c["why"] == why, "%s d%d %s: got %s" % [f.plan.seed, f.plan.depth, tag, str(c)])
			if not c.is_empty() and c["why"] == why:
				rows[why] = int(rows.get(why, 0)) + 1
		var refuse := func(c: Dictionary, tag: String) -> void:
			t.check(c.is_empty(), "%s d%d %s started a count: %s" % [f.plan.seed, f.plan.depth, tag, str(c)])
		# Sprinting.
		expect.call(provoke_once(t, f, a, inp("p", step_to.call(a, 0.25), &"sprint"), "sprint"), "sprint", "sprint")
		# A squeaker tile, faster than a creep; at a creep it is silent.
		var sq := squeaker_pair(f)
		if not sq.is_empty():
			var nb := cell_body(f.plan, sq[1])
			var on := cell_body(f.plan, sq[0])
			expect.call(provoke_once(t, f, nb, inp("p", on, &"walk"), "squeaker"), "squeaker", "squeaker")
			refuse.call(provoke_once(t, f, nb, inp("p", on, &"creep"), "squeaker-creep"), "creeping onto a squeaker")
		# The ball pit, entered faster than a creep.
		var bp := ballpit_door(f)
		if not bp.is_empty():
			var outside := cell_body(f.plan, bp[0])
			var inside := cell_body(f.plan, bp[1])
			expect.call(provoke_once(t, f, outside, inp("p", inside, &"walk"), "ballpit"), "ballpit", "ballpit")
			refuse.call(provoke_once(t, f, outside, inp("p", inside, &"creep"), "ballpit-creep"), "creeping into the ball pit")
		# A flap let go; the slow way in and out is silent.
		var mb := cell_body(f.plan, f.plan.entity_start)
		var hd: Playroom.Hide = f.hide_list[rng.int_in(0, f.hide_list.size() - 1)]
		while horiz(pt(f.plan, hd.front, hd.level), mb) < 3.0:
			hd = f.hide_list[rng.int_in(0, f.hide_list.size() - 1)]
		var front := pt(f.plan, hd.front, hd.level)
		var fast := inp("p", front)
		fast.use = true
		fast.fast = true
		expect.call(provoke_once(t, f, front, fast, "flap"), "flap", "flap")
		var rs := new_run(t, f, ["p"], "slow-hide")
		idle(rs, [inp("p", front)], 0.2)
		var slow := inp("p", front)
		slow.use = true
		rs.step([slow])
		idle(rs, [inp("p", front)], 1.6)
		t.check(rs.player("p").phase == &"inside", "%s: not inside after the slow way in" % rs.tag)
		var slow_out := inp("p", front)
		slow_out.use = true
		rs.step([slow_out])
		idle(rs, [inp("p", front)], 1.1)
		t.check(rs.player("p").phase == &"out", "%s: not out after the slow way out" % rs.tag)
		t.check(rs.counts_seen == 0, "%s: the slow way in or out started a count" % rs.tag)
		# The fast way out lets the flap go too.
		var rf := new_run(t, f, ["p"], "fast-out")
		rf.step([slow])
		idle(rf, [inp("p", front)], 1.6)
		var fast_out := inp("p", front)
		fast_out.use = true
		fast_out.fast = true
		var c_out := has_event(rf.step([fast_out]), "count")
		expect.call(c_out, "flap", "fast way out")
		# A dropped tape; an emote with a sound; a voice.
		var tape := inp("p", a)
		tape.dropped_tape = true
		expect.call(provoke_once(t, f, a, tape, "tape"), "tape", "tape")
		var emote := inp("p", a)
		emote.emote_sound = true
		expect.call(provoke_once(t, f, a, emote, "emote"), "emote", "emote")
		var voice := inp("p", a)
		voice.voice = true
		expect.call(provoke_once(t, f, a, voice, "voice"), "voice", "voice")
		# The party horn: harmless (owner). The instrument ticking cannot start one.
		var horn := inp("p", a)
		horn.horn = true
		refuse.call(provoke_once(t, f, a, horn, "horn"), "the party horn")
		var tick := inp("p", a)
		tick.ticking = true
		refuse.call(provoke_once(t, f, a, tick, "tick"), "the instrument ticking")
		# Bumping the Minder: within 0.5 m. At 0.7 m, creeping, nothing.
		var near := Move.Body.make(mb.x + 0.4, mb.z, mb.level, mb.y)
		var close := Move.Body.make(mb.x + 0.7, mb.z, mb.level, mb.y)
		expect.call(provoke_once(t, f, a, inp("p", near), "bump", DT), "bump", "bump")
		refuse.call(provoke_once(t, f, a, inp("p", close), "no-bump", DT), "creeping 0.7 m from it")
		# A light on it: the test light from 1.5 m on a side with a clear line, aimed at it; aimed away, nothing.
		for d: Vector2 in [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]:
			var lx := mb.x + 1.5 * d.x
			var lz := mb.z + 1.5 * d.y
			var src := Sight.Point3.make(lx, mb.y + 1.2, lz, mb.level)
			if not Sight.has_line_of_sight(f.plan, src, Sight.Point3.make(mb.x, mb.y + 1.2, mb.z, mb.level)):
				continue
			var light := inp("p", a)
			light.light = Seek.Light.make(lx, mb.y + 1.2, lz, mb.level, atan2(1.5 * d.x, 1.5 * d.y), 0.0, 20.0, 10.0)
			expect.call(provoke_once(t, f, a, light, "light", DT), "light", "light")
			var dark := inp("p", a)
			dark.light = Seek.Light.make(lx, mb.y + 1.2, lz, mb.level, atan2(-1.5 * d.x, -1.5 * d.y), 0.0, 20.0, 10.0)
			refuse.call(provoke_once(t, f, a, dark, "light-away", DT), "a light aimed away")
			break
		# After the call nothing provokes.
		var rc := new_run(t, f, ["p"], "called")
		idle(rc, [inp("p", a)], 0.2)
		rc.step([inp("p", a)], flin(true, "p"))
		var gone := inp("p", a)
		gone.active = false
		while not rc.done:
			rc.step([gone])
		idle(rc, [gone], O_CALM + 1.0)
		var after := has_event(rc.step([inp("p", step_to.call(a, 0.25), &"sprint")]), "count")
		refuse.call(after, "a sprint after the last count")
		# Walking and creeping, for 30 s, never (the oracle also checks no provocation is missed).
		var walk_a: Floor.Pos = null
		var walk_b: Floor.Pos = null
		for c in cells:
			if f.squeak.has(Floor.pos_index(f.plan, c)):
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nb2 := Floor.Pos.make(0, c.x + d.x, c.y + d.y)
				if Floor.can_step(f.plan, c, nb2) and not f.squeak.has(Floor.pos_index(f.plan, nb2)) and Floor.cell_at(f.plan, 0, nb2.x, nb2.y) == Floor.CORRIDOR:
					walk_a = c
					walk_b = nb2
					break
			if walk_a != null:
				break
		var rw := new_run(t, f, ["w", "c"], "walk")
		var wa := cell_body(f.plan, walk_a)
		var wb := cell_body(f.plan, walk_b)
		var sqc: Move.Body = cell_body(f.plan, sq[0]) if not sq.is_empty() else wb
		var sqn: Move.Body = cell_body(f.plan, sq[1]) if not sq.is_empty() else wa
		for k in int(30.0 / DT):
			var w_at := wa.x + (wb.x - wa.x) * (k % 20) / 20.0
			var w_az := wa.z + (wb.z - wa.z) * (k % 20) / 20.0
			var c_on := sqc if (k / 10) % 2 == 0 else sqn
			rw.step([inp("w", Move.Body.make(w_at, w_az, 0, wa.y), &"walk"), inp("c", c_on, &"creep")])
		var bumped := false
		for e in rw.events:
			if e["type"] == "count":
				bumped = e["why"] == "bump"
				t.check(e["why"] == "bump", "%s: walking or creeping started a count (%s)" % [rw.tag, e["why"]])
		if not bumped:
			rows["walk30s"] = int(rows.get("walk30s", 0)) + 1
		rows["horn-refused"] = int(rows.get("horn-refused", 0)) + 1
	t.note("%d floors, provocations that started a count in their tick: %s" % [floors, str(rows)])
	for why: String in ["sprint", "squeaker", "ballpit", "flap", "tape", "emote", "voice", "bump", "light"]:
		t.check(int(rows.get(why, 0)) > 0, "the %s provocation was never tried" % why)

# =============================================================================================
# Section 8: the last count.

func test_last_count(t: T) -> void:
	var f := floor_of(1)
	var rng := Rng.make_rng("prop_seek:last")
	var a := cell_body(f.plan, far_cells(f, 10.0, rng)[0])
	var gone := inp("p", a)
	gone.active = false
	# A call with no count running starts the last count at once.
	var r := new_run(t, f, ["p"], "last-now")
	idle(r, [inp("p", a)], 0.5)
	var c := has_event(r.step([inp("p", a)], flin(true, "p")), "count")
	t.check(not c.is_empty() and c["last"] and absf(float(c["len"]) - O_LAST) < TEPS and c["why"] == "call" and c["by"] == "p", "the call: %s" % str(c))
	while not r.done:
		r.step([gone])
	idle(r, [inp("p", a, &"sprint")], 5.0)
	t.check(r.counts_seen == 1, "a count after the last count")
	# A call during a count: the last count starts 6 s after that one ends (the 15 s does not delay it).
	var r2 := new_run(t, f, ["p"], "last-after")
	idle(r2, [inp("p", a)], 0.5)
	r2.step([inp("p", a, &"sprint")])
	idle(r2, [gone], 10.0)
	var evs := r2.step([gone], flin(true, "q"))
	t.check(has_event(evs, "count").is_empty(), "the call during a count started one at once")
	var end_t := -1.0
	var last_t := -1.0
	while not r2.done:
		for e in r2.step([gone]):
			if e["type"] == "countEnd" and end_t < 0.0:
				end_t = float(e["t"])
			if e["type"] == "count":
				last_t = float(e["t0"])
				t.check(e["last"] and e["by"] == "q", "the pending last count: %s" % str(e))
	t.check(absf(last_t - end_t - O_LAST_AFTER) < TEPS, "the last count started %.3f s after the count ended, want %.1f" % [last_t - end_t, O_LAST_AFTER])
	# A call in the 15 s of calm: at once.
	var r3 := new_run(t, f, ["p"], "last-calm")
	run_out_count(r3, "p", a)
	idle(r3, [gone], 3.0)
	var c3 := has_event(r3.step([gone], flin(true, "p")), "count")
	t.check(not c3.is_empty() and c3["last"], "a call in the calm did not start the last count at once")
	t.note("the call starts the last 40 s count at once, or %.0f s after a running count ends; nothing after it" % O_LAST_AFTER)

# =============================================================================================
# Hides: in and out, slow and fast; a full hide refuses; where the body is held.

func test_hides(t: T) -> void:
	var tried := 0
	for fi in floor_count(t):
		var f := floor_of(fi)
		for h in f.hide_list:
			if h.id % 7 != fi % 7:
				continue
			tried += 1
			var front := pt(f.plan, h.front, h.level)
			for fast: int in [0, 1]:
				var r := new_run(t, f, ["a"], "hide%d" % h.id)
				var u := inp("a", front)
				u.use = true
				u.fast = fast == 1
				var e0 := has_event(r.step([u]), "hideStart")
				var t_in := -1.0
				for _k in 40:
					var e := has_event(r.step([inp("a", front)]), "hideIn")
					if not e.is_empty():
						t_in = r.now()
						break
				var want_in: float = O_IN[fast]
				t.check(not e0.is_empty() and absf(t_in - float(e0["t"]) - want_in) < TEPS, "%s: in after %.3f s, want %.1f" % [r.tag, t_in - float(e0.get("t", 0.0)), want_in])
				var sp := r.player("a")
				var ins := pt(f.plan, h.inside, h.level)
				t.check(sp.phase == &"inside" and sp.hide == h.id and horiz(sp.body, ins) < 1e-9, "%s: not held at the inside spot" % r.tag)
				var o := inp("a", front)
				o.use = true
				o.fast = fast == 1
				var e1 := has_event(r.step([o]), "hideLeave")
				var t_out := -1.0
				for _k in 40:
					var e := has_event(r.step([inp("a", front)]), "hideOut")
					if not e.is_empty():
						t_out = r.now()
						break
				var want_out: float = O_OUT[fast]
				t.check(not e1.is_empty() and absf(t_out - float(e1["t"]) - want_out) < TEPS, "%s: out after %.3f s, want %.1f" % [r.tag, t_out - float(e1.get("t", 0.0)), want_out])
				t.check(r.player("a").phase == &"out" and r.player("a").hide == -1, "%s: not out" % r.tag)
			# Out of reach: nothing.
			var far := Move.Body.make(front.x + O_REACH + 0.3, front.z, front.level, front.y)
			var rr := new_run(t, f, ["a"], "reach%d" % h.id)
			var u2 := inp("a", far)
			u2.use = true
			var near_other := false
			for h2 in f.hide_list:
				if h2.level == far.level and horiz(pt(f.plan, h2.front, h2.level), far) <= O_REACH + BAND:
					near_other = true
			if not near_other:
				t.check(has_event(rr.step([u2]), "hideStart").is_empty(), "%s: got in from %.1f m" % [rr.tag, O_REACH + 0.3])
			# Full: capacity + 1 players; the last is refused.
			var ids: Array[String] = []
			for k in h.capacity + 1:
				ids.append("p%d" % k)
			var rc := new_run(t, f, ids, "full%d" % h.id)
			var refused := 0
			var ins_n := 0
			for k in ids.size():
				var all: Array[Seek.SeekInput] = []
				for j in ids.size():
					var ij := inp(ids[j], front)
					ij.use = j == k
					all.append(ij)
				var evs := rc.step(all)
				if not has_event(evs, "hideFull").is_empty():
					refused += 1
				if not has_event(evs, "hideStart").is_empty():
					ins_n += 1
			t.check(refused == 1 and ins_n == h.capacity, "%s (holds %d): %d in, %d refused" % [rc.tag, h.capacity, ins_n, refused])
	t.note("%d hides: in 1.5 s / 0.5 s, out 1.0 s / 0.4 s, held at the inside spot, full hides refuse the next player" % tried)

# =============================================================================================
# Property 1: never outside a count. A creeper kept 0.7 m in front of it, in its face, for 60 s.

func test_never_outside_a_count(t: T) -> void:
	var floors := floor_count(t)
	for fi in floors:
		var f := floor_of(fi)
		var r := new_run(t, f, ["c", "s"], "never")
		var m := r.state.minder
		for k in int(60.0 / DT):
			m = r.state.minder
			var fx := -sin(m.yaw)
			var fz := -cos(m.yaw)
			var front := Move.Body.make(m.body.x + fx * 0.7, m.body.z + fz * 0.7, m.body.level, m.body.y)
			var side := Move.Body.make(m.body.x + fx * 3.0, m.body.z + fz * 3.0, m.body.level, m.body.y)
			r.step([inp("c", front, &"creep"), inp("s", side, &"creep")])
		t.check(r.counts_seen == 0, "%s: a count started" % r.tag)
		for e in r.events:
			if e["type"] == "found" or e["type"] == "taken":
				t.check(false, "%s: %s outside a count: %s" % [r.tag, e["type"], str(e)])
				break
	t.note("%d floors: 60 s each with a creeper 0.7 m in front of it and one 3 m in its face; nobody found or taken" % floors)

# =============================================================================================
# Property 6: the 6 seconds are free.

func test_six_seconds(t: T) -> void:
	var floors := floor_count(t)
	var touch_found := 0
	for fi in floors:
		var f := floor_of(fi)
		var rng := Rng.make_rng("prop_seek:six:%d" % fi)
		var far := cell_body(f.plan, far_cells(f, 10.0, rng)[0])
		var hd: Playroom.Hide = f.hide_list[rng.int_in(0, f.hide_list.size() - 1)]
		var front := pt(f.plan, hd.front, hd.level)
		var r := new_run(t, f, ["a", "b", "c"], "six")
		r.step([inp("a", far, &"sprint"), inp("b", front), inp("c", far)])
		var m := r.state.minder
		var fx := -sin(m.yaw)
		var fz := -cos(m.yaw)
		var face := Move.Body.make(m.body.x + fx * 0.7, m.body.z + fz * 0.7, m.body.level, m.body.y)
		var k := 0
		while r.phase_at(r.now() + DT) == &"hide":
			k += 1
			# a sprints in its face, b bangs in and out of a hide, c shouts.
			var a := inp("a", Move.Body.make(face.x + 0.05 * (k % 2), face.z, face.level, face.y), &"sprint")
			var b := inp("b", front)
			b.use = k % 12 == 0
			b.fast = true
			var c := inp("c", far)
			c.voice = true
			c.emote_sound = true
			r.step([a, b, c])
		var evs := r.step([inp("a", face), inp("b", front), inp("c", far)])
		var got := false
		for e in evs:
			if e["type"] == "found" and e["playerId"] == "a":
				got = true
				if e["cause"] == "touch":
					touch_found += 1
		t.check(got, "%s: the player in its face was not found on the first tick after the 6 s" % r.tag)
	t.note("%d floors: sprinting in its face, flaps and voices in the 6 s add nothing; found the first tick after (by touch %d)" % [floors, touch_found])

# =============================================================================================
# Bots: properties 1, 3, 5, 6, 8 (hiders) and 9 over whole floors, and property 7.

class Bot:
	var id: String
	var body: Move.Body
	var gait: StringName = &"creep"
	var roam_gait: StringName = &"creep"
	var path: Array[Floor.Pos] = []
	var next := 0
	var goal_hide := -1
	var tried: Dictionary = {}
	var want_out := false
	var tape_due := false

static func bot_goto(plan: Floor.FloorPlan, b: Bot, goal: Floor.Pos, speed: float) -> bool:
	var here := Move.cell_of(plan, b.body)
	if b.path.is_empty() or not b.path[b.path.size() - 1].equals(goal):
		b.path = Floor.find_path(plan, here, goal)
		b.next = 1 if b.path.size() > 1 else 0
	if b.path.is_empty():
		return true
	var w := Follow.PathWalk.make(b.path, b.next)
	b.body = Follow.step_path_walk(plan, w, b.body, speed * DT, BOT_RADIUS)
	b.next = w.next
	return Follow.path_done(plan, w, b.body)

static func bot_hide_choice(r: Run, b: Bot, claims: Dictionary) -> int:
	var dist := Floor.distances_from(r.plan, Move.cell_of(r.plan, b.body))
	var best := -1
	var best_d := 1 << 30
	for h in r.f.hide_list:
		if b.tried.has(h.id) or int(claims.get(h.id, 0)) >= h.capacity:
			continue
		var d := dist[Floor.pos_index(r.plan, Move.cell_of(r.plan, pt(r.plan, h.front, h.level)))]
		if d >= 0 and d < best_d:
			best = h.id
			best_d = d
	return best

## One tick of hider bots: roam outside counts, hide in the nearest free hide when a count starts.
static func bot_inputs(r: Run, bots: Array[Bot], rng: Rng, provoke: bool) -> Array[Seek.SeekInput]:
	var out: Array[Seek.SeekInput] = []
	var provoker := -1
	if provoke:
		for bi in bots.size():
			var sp0 := r.player(bots[bi].id)
			if sp0 != null and sp0.status == &"ok" and sp0.phase == &"out":
				provoker = bi
				break
	var claims := {}
	for b in bots:
		if b.goal_hide >= 0:
			claims[b.goal_hide] = int(claims.get(b.goal_hide, 0)) + 1
	for bi in bots.size():
		var b := bots[bi]
		var sp := r.player(b.id)
		var i := Seek.SeekInput.make(b.id, b.body, &"creep")
		if sp == null:
			out.append(i)
			continue
		if sp.status != &"ok":
			if sp.status == &"taken":
				b.body = sp.body
			i.body = b.body
			i.dropped_tape = b.tape_due
			b.tape_due = false
			b.goal_hide = -1
			out.append(i)
			continue
		if sp.phase != &"out":
			b.body = sp.body
			i.body = b.body
			if sp.phase == &"inside" and not r.counting and b.want_out:
				i.use = true
				b.want_out = false
			out.append(i)
			continue
		if r.counting:
			if b.goal_hide < 0:
				b.goal_hide = bot_hide_choice(r, b, claims)
				if b.goal_hide >= 0:
					claims[b.goal_hide] = int(claims.get(b.goal_hide, 0)) + 1
			if b.goal_hide >= 0:
				var h: Playroom.Hide = r.f.hides[b.goal_hide]
				var fb := pt(r.plan, h.front, h.level)
				var fast_now := r.phase_at(r.now() + DT) == &"hide"
				if b.body.level == fb.level and horiz(b.body, fb) <= 1.0:
					i.use = true
					b.want_out = true
					b.tried[b.goal_hide] = true
				elif Move.cell_of(r.plan, b.body).equals(Move.cell_of(r.plan, fb)):
					var dx := fb.x - b.body.x
					var dz := fb.z - b.body.z
					var dd := sqrt(dx * dx + dz * dz)
					var stp := minf(dd, (SPRINT if fast_now else WALK) * DT)
					b.body = Move.move_with_collision(r.plan, b.body, dx / dd * stp, dz / dd * stp, BOT_RADIUS)
					i.gait = &"sprint" if fast_now else &"walk"
				else:
					bot_goto(r.plan, b, Move.cell_of(r.plan, fb), SPRINT if r.phase_at(r.now() + DT) == &"hide" else WALK)
					i.gait = &"sprint" if r.phase_at(r.now() + DT) == &"hide" else &"walk"
			i.body = b.body
			out.append(i)
			continue
		b.goal_hide = -1
		b.tried = {}
		# Roaming.
		if b.path.is_empty() or b.next >= b.path.size() - 1 and Follow.path_done(r.plan, Follow.PathWalk.make(b.path, b.next), b.body):
			var c: Floor.Pos = r.f.walkway[rng.int_in(0, r.f.walkway.size() - 1)]
			b.path = Floor.find_path(r.plan, Move.cell_of(r.plan, b.body), c)
			b.next = 1 if b.path.size() > 1 else 0
		var w := Follow.PathWalk.make(b.path, b.next)
		var speed := CREEP if b.roam_gait == &"creep" else WALK
		var gait := b.roam_gait
		if bi == provoker:
			gait = &"sprint"
			speed = SPRINT
		b.body = Follow.step_path_walk(r.plan, w, b.body, speed * DT, BOT_RADIUS)
		b.next = w.next
		i.body = b.body
		i.gait = gait
		out.append(i)
	return out

class BotTally:
	var counts := 0
	var counts_with_found := 0
	var found := {}
	var events := ""
	var downs := 0

## A whole floor: four hiders, counts provoked by sprints and squeakers, a call in the second count.
static func bot_floor(t: T, f: Fl, tag: String) -> BotTally:
	var rng := Rng.make_rng("prop_seek:bots:%s:%d" % [f.plan.seed, f.plan.depth])
	var ids: Array[String] = ["b0", "b1", "b2", "b3"]
	var r := new_run(t, f, ids, tag)
	var cells := far_cells(f, 12.0, rng)
	var bots: Array[Bot] = []
	for k in 4:
		var b := Bot.new()
		b.id = ids[k]
		b.body = cell_body(f.plan, cells[k * 7 % cells.size()])
		b.roam_gait = &"walk" if k % 2 == 1 else &"creep"
		bots.append(b)
	var call_sent := false
	var after_done := 0.0
	var limit := int(400.0 / DT)
	for _k in limit:
		var provoke := not r.counting and not r.called and r.now() >= (5.0 if r.ended == 0 else r.end_t + O_CALM + 3.0)
		var fl := Seek.FloorInput.new()
		if not call_sent and ((r.counting and r.n >= 2 and r.now() >= r.t0 + O_HIDE + 10.0) or (not r.counting and r.now() >= 200.0)):
			fl.call = true
			fl.call_by = "b0"
			call_sent = true
		var evs := r.step(bot_inputs(r, bots, rng, provoke), fl)
		for e in evs:
			if e["type"] == "down":
				for b in bots:
					if b.id == e["playerId"]:
						b.tape_due = true
		if r.done:
			after_done += DT
			if after_done >= 10.0:
				break
	var tally := BotTally.new()
	tally.counts = r.counts_finished
	tally.counts_with_found = r.counts_with_found
	tally.found = r.found_by_cause
	tally.events = canon(r.events)
	for e in r.events:
		if e["type"] == "down":
			tally.downs += 1
	t.check(r.done, "%s: the last count never ended (%d counts)" % [r.tag, r.counts_finished])
	return tally

## Events as text with every float by its bits.
static func canon(v: Variant) -> String:
	if v is float:
		var a := PackedFloat64Array([v])
		return a.to_byte_array().hex_encode()
	if v is Array:
		var parts := PackedStringArray()
		for x: Variant in v:
			parts.append(canon(x))
		return "[" + ",".join(parts) + "]"
	if v is Dictionary:
		var d: Dictionary = v
		var keys: Array = d.keys()
		keys.sort()
		var parts := PackedStringArray()
		for k: String in keys:
			parts.append(k + ":" + canon(d[k]))
		return "{" + ",".join(parts) + "}"
	return str(v)

func test_bots_whole_floors(t: T) -> void:
	var floors := floor_count(t)
	var counts := 0
	var with_found := 0
	var causes := {}
	var downs := 0
	var first := ""
	for fi in floors:
		var tally := bot_floor(t, floor_of(fi), "bots")
		counts += tally.counts
		with_found += tally.counts_with_found
		downs += tally.downs
		for c: StringName in tally.found:
			causes[c] = int(causes.get(c, 0)) + int(tally.found[c])
		if fi == 0:
			first = tally.events
	# Property 7: the same seed and inputs give the same events.
	var again := bot_floor(t, floor_of(0), "bots-again")
	t.check(again.events == first, "floor 0 played twice gave different events")
	t.note("%d floors, %d counts, %d with someone found; found by %s; %d down from health" % [floors, counts, with_found, str(causes), downs])
	if not t.quick:
		t.check(with_found * 3 >= counts, "a real threat: someone found in %d of %d counts, want a third" % [with_found, counts])
	t.check(counts >= floors * 3, "only %d counts on %d floors" % [counts, floors])

# =============================================================================================
# Property 8, second half: bots that stand in its view are all found.

func test_standing_in_view(t: T) -> void:
	var floors := floor_count(t)
	var placed := 0
	var found := 0
	for fi in floors:
		var f := floor_of(fi)
		var rng := Rng.make_rng("prop_seek:stand:%d" % fi)
		var far := cell_body(f.plan, far_cells(f, 14.0, rng)[0])
		var r := new_run(t, f, ["p", "s0", "s1"], "stand")
		var sb: Array = [null, null]
		var gone := inp("p", far)
		gone.active = false
		r.step([inp("p", far, &"sprint"), inp("s0", far), inp("s1", far)])
		while r.counting:
			var ins: Array[Seek.SeekInput] = [gone]
			for k in 2:
				if sb[k] == null and r.phase_at(r.now() + DT) == &"seek":
					var m := r.state.minder
					for c in f.walkway:
						var cb := cell_body(f.plan, c)
						var d := horiz(cb, m.body)
						if d >= 3.0 + 2.0 * k and d <= 10.0 and o_sight(f.plan, m.body, m.yaw, cb) == 1:
							sb[k] = cb
							placed += 1
							break
				ins.append(inp("s%d" % k, sb[k] if sb[k] != null else far))
			r.step(ins)
		for k in 2:
			if sb[k] != null:
				var p := r.player("s%d" % k)
				if p.status == &"taken":
					found += 1
				t.check(p.status == &"taken", "%s: s%d stood in its view and was not taken (%s)" % [r.tag, k, p.status])
	t.note("%d floors: %d bots placed in its view the moment they could be, %d taken" % [floors, placed, found])
	t.check(placed > 0, "no bot could be placed in its view")

# =============================================================================================
# Property 4: one silent, unseen hider in a zone of n hides is found in about 1 in n of seeds; the
# draw is even over the zone's hides; it is certain once it heard the hider get in.

func test_one_in_n(t: T) -> void:
	var floors := floor_count(t)
	var by_n := {}      # n -> [trials, found]
	var by_index := {}  # "n:i" -> draws of the i-th hide of a zone of n
	var certain := 0
	var certain_trials := 0
	var out_of_time := 0
	for fi in floors:
		var f := floor_of(fi)
		var rng := Rng.make_rng("prop_seek:draw:%d" % fi)
		var zone_list: Array[Playroom.Zone] = []
		for z in f.zones:
			if z.hides > 0:
				zone_list.append(z)
		var trials := 2 if t.quick else 8
		for k in trials:
			var z: Playroom.Zone = zone_list[rng.int_in(0, zone_list.size() - 1)]
			var list: Array[int] = []
			for h in f.hide_list:
				if h.zone == z.id:
					list.append(h.id)
			var mine: int = list[rng.int_in(0, list.size() - 1)]
			var h: Playroom.Hide = f.hides[mine]
			var front := pt(f.plan, h.front, h.level)
			var heard := k == trials - 1
			var r := new_run(t, f, ["h"], "draw%d" % mine)
			r.step([inp("h", front)], flin(true, "x"))
			if not heard:
				var u := inp("h", front)
				u.use = true
				r.step([u])
			var drew := -2
			var res := ""
			var pending := false
			while r.counting and res == "":
				var i := inp("h", r.player("h").body)
				if heard and r.player("h").phase == &"out" and r.phase_at(r.now() + DT) == &"seek":
					i.use = true
					i.fast = true
				for e in r.step([i]):
					if e["type"] == "draw" and int(e["zone"]) == z.id:
						drew = int(e["hide"])
					if e["type"] == "found":
						res = "found"
					if e["type"] == "lookDone" and drew >= 0 and int(e["hide"]) == drew:
						res = "found" if int(e["found"]) > 0 else "missed"
					if e["type"] == "reason" and int(e["hide"]) == mine:
						pending = true
					if e["type"] == "lookDone" and int(e["hide"]) == mine:
						pending = false
			if res == "":
				# The count ran out before it got there (a far zone on a big floor): no verdict, but a
				# heard hider must still be the hide it was walking to.
				out_of_time += 1
				if heard:
					t.check(pending, "%s: heard getting in, not found, and not on its way" % r.tag)
				continue
			if heard:
				certain_trials += 1
				if res == "found":
					certain += 1
				t.check(res == "found", "%s: heard getting in (a flap in the count) and not found" % r.tag)
				continue
			var n := list.size()
			if drew >= 0:
				var key := "%d:%d" % [n, list.find(drew)]
				by_index[key] = int(by_index.get(key, 0)) + 1
				var cell: Array = by_n.get(n, [0, 0])
				cell[0] += 1
				if res == "found":
					cell[1] += 1
				by_n[n] = cell
				t.check((res == "found") == (drew == mine), "%s: drew %d, hid in %d, result %s" % [r.tag, drew, mine, res])
			else:
				t.check(res == "found", "%s: no draw in zone %d and not found by other means" % [r.tag, z.id])
	var parts := PackedStringArray()
	for n: int in by_n:
		var cell: Array = by_n[n]
		parts.append("n=%d: %d of %d found" % [n, cell[1], cell[0]])
		if not t.quick and int(cell[0]) >= 12:
			var p := 1.0 / n
			var share := float(cell[1]) / float(cell[0])
			var tol := 4.0 * sqrt(p * (1.0 - p) / float(cell[0])) + 0.02
			t.check(absf(share - p) <= tol, "zones of %d hides: found %.3f of the time, printed 1 in %d (tolerance %.3f)" % [n, share, n, tol])
			for i in n:
				var draws := int(by_index.get("%d:%d" % [n, i], 0))
				var di := float(draws) / float(cell[0])
				t.check(absf(di - p) <= tol, "zones of %d hides: hide %d drawn %.3f of the time, want %.3f" % [n, i, di, p])
	t.note("%s; heard getting in: found %d of %d; %d trials ran out of count before it arrived" % ["; ".join(parts), certain, certain_trials, out_of_time])

# =============================================================================================
# Rule 4 in play: a peeker in a hide it heard (a flap let go in the count) is caught looking out.

func test_eye_in_the_gap(t: T) -> void:
	var tried := 0
	var causes := {}
	for fi in floor_count(t):
		var f := floor_of(fi)
		var rng := Rng.make_rng("prop_seek:gap:%d" % fi)
		var start := cell_body(f.plan, f.plan.entity_start)
		for k in (1 if t.quick else 2):
			var h: Playroom.Hide = f.hide_list[rng.int_in(0, f.hide_list.size() - 1)]
			while horiz(pt(f.plan, h.front, h.level), start) < 10.0:
				h = f.hide_list[rng.int_in(0, f.hide_list.size() - 1)]
			var front := pt(f.plan, h.front, h.level)
			var r := new_run(t, f, ["peek"], "gap%d" % h.id)
			r.step([inp("peek", front)], flin(true, "x"))
			var res := ""
			var pending := false
			while r.counting and res == "":
				var p := r.player("peek")
				var ip := inp("peek", p.body)
				if p.phase == &"out" and r.phase_at(r.now() + DT) == &"seek":
					ip.use = true
					ip.fast = true
				ip.peek = true
				for e in r.step([ip]):
					if e["type"] == "found" and e["playerId"] == "peek":
						res = e["cause"]
					if e["type"] == "reason" and int(e["hide"]) == h.id:
						pending = true
			tried += 1
			causes[res if res != "" else "out of time"] = int(causes.get(res if res != "" else "out of time", 0)) + 1
			t.check(res != "" or pending, "%s: heard getting in, peeking, not found and not on its way" % r.tag)
	t.note("%d peekers in a hide it heard: found by %s" % [tried, str(causes)])
	t.check(int(causes.get("gap", 0)) > 0, "the eye in the gap never found anyone")

# =============================================================================================
# Property 9 and section 7: health.

func test_health(t: T) -> void:
	var f := floor_of(2)
	var rng := Rng.make_rng("prop_seek:health")
	var cells := far_cells(f, 10.0, rng)
	var wa: Floor.Pos = null
	var wb: Floor.Pos = null
	for c in cells:
		for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var nb := Floor.Pos.make(0, c.x + d.x, c.y + d.y)
			if Floor.cell_at(f.plan, 0, nb.x, nb.y) == Floor.CORRIDOR and Floor.can_step(f.plan, c, nb) \
				and not f.squeak.has(Floor.pos_index(f.plan, c)) and not f.squeak.has(Floor.pos_index(f.plan, nb)):
				wa = c
				wb = nb
				break
		if wa != null:
			break
	var a := cell_body(f.plan, wa)
	var b := cell_body(f.plan, wb)
	var r := new_run(t, f, ["w", "x"], "health")
	var gone := inp("x", a)
	gone.active = false
	# Before any count: walking costs nothing.
	var kk: Array[int] = [0]
	var walker := func(gait: StringName) -> Seek.SeekInput:
		kk[0] += 1
		var s := float(kk[0] % 20) / 20.0
		return inp("w", Move.Body.make(a.x + (b.x - a.x) * s, a.z + (b.z - a.z) * s, 0, a.y), gait)
	for _i in 40:
		r.step([walker.call(&"walk"), inp("x", a)])
	t.check(r.player("w").health == 100.0, "health changed before the first count")
	# A count (started by x, who then leaves); w sits it out (the bot floors walk through counts).
	var w_gone := inp("w", a)
	w_gone.active = false
	r.step([walker.call(&"walk"), inp("x", a, &"sprint")])
	while r.counting:
		r.step([w_gone, gone])
	t.check(r.player("w").health == 100.0, "health changed during the count")
	var h0 := r.player("w").health
	for _i in 20:
		r.step([walker.call(&"walk"), gone])
	t.check(absf(r.player("w").health - (h0 - O_WALK)) < 1e-9, "walking 1 s: %.6f, want %.6f" % [r.player("w").health, h0 - O_WALK])
	h0 = r.player("w").health
	for _i in 20:
		r.step([walker.call(&"sprint"), gone])
	t.check(absf(r.player("w").health - (h0 - O_SPRINT)) < 1e-9, "sprinting 1 s: %.6f, want %.6f" % [r.player("w").health, h0 - O_SPRINT])
	h0 = r.player("w").health
	for _i in 20:
		r.step([walker.call(&"creep"), gone])
	t.check(absf(r.player("w").health - (h0 + O_REST)) < 1e-9, "creeping 1 s: %.6f, want %.6f" % [r.player("w").health, h0 + O_REST])
	h0 = r.player("w").health
	idle(r, [inp("w", a), gone], 1.0)
	t.check(absf(r.player("w").health - (h0 + O_REST)) < 1e-9, "standing 1 s: %.6f, want %.6f" % [r.player("w").health, h0 + O_REST])
	# A ride stops it.
	h0 = r.player("w").health
	for _i in 20:
		r.step([walker.call(&"walk"), gone], flin(false, "", false, true))
	t.check(r.player("w").health == h0, "health drained in a ride")
	# Walk to 0: down.
	var down := false
	for _i in int(80.0 / DT):
		for e in r.step([walker.call(&"walk"), gone]):
			if e["type"] == "down" and e["playerId"] == "w":
				down = true
		if down:
			break
	t.check(down and r.player("w").status == &"down" and r.player("w").health == 0.0, "walking to 0 health did not put the walker down")
	t.note("walk -3/s, sprint -8/s, creep and stand +1/s after the first count; nothing before it, in it or in a ride; 0 is down")

# =============================================================================================
# A zone with no hides: the sweep, no draw, cleared.

func test_zone_with_no_hides(t: T) -> void:
	var done := 0
	for fi in floor_count(t):
		var f := floor_of(fi)
		var z: Playroom.Zone = null
		for zz in f.zones:
			if zz.level == 0 and zz.kind != &"party" and zz.rooms.size() >= 1:
				z = zz
				break
		var kept: Array[Playroom.Hide] = []
		for h in f.hide_list:
			if h.zone != z.id:
				kept.append(h)
		var data := Seek.SeekFloor.make(f.plan, kept)
		var room := f.plan.rooms[z.rooms[0]]
		var spot := Move.body_at_cell(f.plan, Floor.Pos.make(0, room.x + room.w / 2, room.y + room.h / 2))
		var r := new_run(t, f, ["p"], "nohides", data)
		r.step([inp("p", spot)], flin(true, "x"))
		var drew: Dictionary = {}
		while r.counting:
			for e in r.step([inp("p", spot)]):
				if e["type"] == "draw" and int(e["zone"]) == z.id:
					drew = e
		if not drew.is_empty():
			done += 1
			t.check(int(drew["n"]) == 0 and int(drew["hide"]) == -1, "%s: the draw in a zone with no hides: %s" % [r.tag, str(drew)])
	t.note("%d zones stripped of their hides: swept, no hide drawn (n 0, hide -1), cleared, no errors" % done)
