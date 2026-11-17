# Hiding off the Playroom (docs/floors/traits-and-hiding.md section 4, T19b): getting into a hide,
# sitting in it, leaning to its gap and getting out, as a pure state machine with sim/seek.gd's numbers,
# and the reasons a resident has to look into a hide. The Playroom keeps seek.gd untouched; this runs on
# the Clinic and the Annex (sim/run.gd steps it before the resident). The hides are sim/hides.gd's list.
#
# Keys (the run's PlayerInput.hide_use is a press of F, or the client's Ctrl-walk into a desk):
#   in   a press within Seek.HIDE_REACH of a hide's front spot: IN_SLOW (1.5 s), or IN_FAST (0.5 s) with
#        sprint held, which makes a noise (the frame rattles, the door bangs, a chair scrapes). A desk is
#        always IN_DESK (1.0 s) and never fast: Ctrl is a creep. A full hide refuses you.
#   out  a press inside: OUT_SLOW (1.0 s), or OUT_FAST (0.4 s) with a noise (never from a desk).
#   W held inside: peeking (leaning to the gap). Getting in or out is out in the open.
# Where the body is: the player's own while getting in; the hide's inside spot inside; its front spot
# while getting out. A pulled-out player (release) stands at the front spot.
#
# A reason (the Playroom's, section 4) belongs to a hide until it is empty again:
#   seen  the resident had the player in its view (within Seek.SIGHT_RANGE, within Seek.SIGHT_HALF_DEG of
#         its face, a clear line from its head to one of Seek.BODY_POINTS on them) on a tick of getting in;
#   fast  a fast entry or exit;
#   tick  an instrument ticking inside within Seek.TICK_REASON_RANGE of the resident.
# Events: hideStart {playerId, hide, fast}, hideIn, hideLeave {fast}, hideOut, hideFull, flap (the noise),
# reason {hide, why, playerId}: the same shapes as seek.gd's.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Seek = preload("res://sim/seek.gd")
const Playroom = preload("res://sim/playroom.gd")
const Hides = preload("res://sim/hides.gd")
const M = preload("res://sim/jsmath.gd")

## The desk's one new number: crawling under takes this long, and is never fast.
const IN_DESK := 1.0
const EPS := 1e-9

class HideFloor:
	var plan: Floor.FloorPlan
	var hides: Array[Playroom.Hide] = []

	## `list` null means Hides.hides_for(plan).
	static func make(plan_: Floor.FloorPlan, list: Variant = null) -> HideFloor:
		var f := HideFloor.new()
		f.plan = plan_
		if list == null:
			f.hides = Hides.hides_for(plan_, plan_.seed)
		else:
			for h: Playroom.Hide in list:
				f.hides.append(h)
		return f

class HidePlayer:
	var id: String
	## &"out" | &"entering" | &"inside" | &"leaving"
	var phase: StringName = &"out"
	var hide: int = -1
	var phase_left: float = 0.0
	var peeking: bool = false
	## In the resident's view on some tick of getting in.
	var seen_entering: bool = false
	## Where they stood when they began getting in: the last place they were seen out.
	var spot: Move.Body = null

	func copy() -> HidePlayer:
		var p := HidePlayer.new()
		p.id = id
		p.phase = phase
		p.hide = hide
		p.phase_left = phase_left
		p.peeking = peeking
		p.seen_entering = seen_entering
		p.spot = spot
		return p

class HidingState:
	var t: float = 0.0
	var floor: HideFloor
	var players: Array[HidePlayer] = []
	## hide id -> why (String), for hides with a reason; dropped when the hide is empty.
	var reasons: Dictionary = {}

	func copy() -> HidingState:
		var s := HidingState.new()
		s.t = t
		s.floor = floor
		s.players = players
		s.reasons = reasons
		return s

class HideInput:
	var id: String
	var body: Move.Body
	## F pressed this tick (or the Ctrl-walk into a desk), and sprint held as it was.
	var use: bool = false
	var fast: bool = false
	## W held inside a hide.
	var peek: bool = false
	## Their instrument ticked on the tick before.
	var ticking: bool = false

	static func make(id_: String, body_: Move.Body) -> HideInput:
		var i := HideInput.new()
		i.id = id_
		i.body = body_
		return i

## The resident as the reasons see it: where it stands, which way its face points, its head's height.
class Watcher:
	var body: Move.Body
	var yaw: float
	var head: float

	static func make(body_: Move.Body, yaw_: float, head_: float) -> Watcher:
		var w := Watcher.new()
		w.body = body_
		w.yaw = yaw_
		w.head = head_
		return w

class HidingStep:
	var state: HidingState
	var events: Array[Dictionary] = []

static func create(plan: Floor.FloorPlan, list: Variant = null) -> HidingState:
	var s := HidingState.new()
	s.floor = HideFloor.make(plan, list)
	return s

static func player_of(s: HidingState, id: String) -> HidePlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

static func hide_of(s: HidingState, id: int) -> Playroom.Hide:
	return s.floor.hides[id] if id >= 0 and id < s.floor.hides.size() else null

static func inside_body(s: HidingState, h: Playroom.Hide) -> Move.Body:
	return Seek.hide_inside_body(s.floor.plan, h)

static func front_body(s: HidingState, h: Playroom.Hide) -> Move.Body:
	return Seek.hide_front_body(s.floor.plan, h)

## Where the rules hold a player's body, or null when they are out (their own body).
static func held_body(s: HidingState, p: HidePlayer) -> Move.Body:
	var h := hide_of(s, p.hide)
	if h == null:
		return null
	if p.phase == &"inside":
		return inside_body(s, h)
	if p.phase == &"leaving":
		return front_body(s, h)
	return null

## The hide whose front is within Seek.HIDE_REACH of `b` (the nearest), or null.
static func hide_in_reach(s: HidingState, b: Move.Body) -> Playroom.Hide:
	var best: Playroom.Hide = null
	var best_d := INF
	for h in s.floor.hides:
		if h.level != b.level:
			continue
		var d := M.hypot2(h.front.x / 100.0 - b.x, h.front.y / 100.0 - b.z)
		if d <= Seek.HIDE_REACH and d < best_d:
			best = h
			best_d = d
	return best

static func occupants(s: HidingState, hide: int) -> int:
	var n := 0
	for p in s.players:
		if p.phase != &"out" and p.hide == hide:
			n += 1
	return n

## The resident's view (section 4's reason): within Seek.SIGHT_RANGE and Seek.SIGHT_HALF_DEG of its face,
## with a clear line from its head to one of Seek.BODY_POINTS on the body.
static func in_view(plan: Floor.FloorPlan, w: Watcher, b: Move.Body) -> bool:
	if w == null:
		return false
	var dx := b.x - w.body.x
	var dz := b.z - w.body.z
	var d := M.hypot2(dx, dz)
	if d > Seek.SIGHT_RANGE:
		return false
	if d > 1e-9 and (dx * -M.sin_js(w.yaw) + dz * -M.cos_js(w.yaw)) / d < Seek.SIGHT_COS:
		return false
	var head := Sight.Point3.make(w.body.x, w.body.y + w.head, w.body.z, w.body.level)
	for hgt in Seek.BODY_POINTS:
		if Sight.has_line_of_sight(plan, head, Sight.Point3.make(b.x, b.y + hgt, b.z, b.level)):
			return true
	return false

static func _reason(s: HidingState, hide: int, why: String, by: String, t: float, events: Array[Dictionary]) -> void:
	if hide < 0 or s.reasons.has(hide):
		return
	s.reasons[hide] = why
	events.append({"type": "reason", "t": t, "hide": hide, "why": why, "playerId": by})

## One tick. `w` is the resident at the start of the tick (null: none to see anyone). Never mutates `prev`.
static func step_hiding(prev: HidingState, inputs: Array[HideInput], w: Watcher, dt: float) -> HidingStep:
	var s := prev.copy()
	var t := prev.t + dt
	s.t = t
	s.players = []
	for p in prev.players:
		s.players.append(p.copy())
	s.reasons = prev.reasons.duplicate()
	var res := HidingStep.new()
	res.state = s
	var events := res.events
	var plan := s.floor.plan
	for inp in inputs:
		var p := player_of(s, inp.id)
		if p == null:
			p = HidePlayer.new()
			p.id = inp.id
			s.players.append(p)
		var noise := false
		match p.phase:
			&"out":
				if inp.use:
					var h := hide_in_reach(s, inp.body)
					if h != null:
						if occupants(s, h.id) >= h.capacity:
							events.append({"type": "hideFull", "t": t, "playerId": p.id, "hide": h.id})
						else:
							var fast := inp.fast and h.kind != &"desk"
							p.phase = &"entering"
							p.hide = h.id
							p.phase_left = IN_DESK if h.kind == &"desk" else (Seek.IN_FAST if fast else Seek.IN_SLOW)
							p.seen_entering = false
							p.spot = inp.body
							events.append({"type": "hideStart", "t": t, "playerId": p.id, "hide": h.id, "fast": fast})
							noise = fast
			&"entering":
				p.phase_left -= dt
				if p.phase_left <= EPS:
					p.phase_left = 0.0
					p.phase = &"inside"
					events.append({"type": "hideIn", "t": t, "playerId": p.id, "hide": p.hide})
					if p.seen_entering:
						_reason(s, p.hide, "seen", p.id, t, events)
			&"inside":
				if inp.use:
					var h := hide_of(s, p.hide)
					var fast := inp.fast and h.kind != &"desk"
					p.phase = &"leaving"
					p.phase_left = Seek.OUT_FAST if fast else Seek.OUT_SLOW
					events.append({"type": "hideLeave", "t": t, "playerId": p.id, "hide": p.hide, "fast": fast})
					noise = fast
			&"leaving":
				p.phase_left -= dt
				if p.phase_left <= EPS:
					events.append({"type": "hideOut", "t": t, "playerId": p.id, "hide": p.hide})
					p.phase_left = 0.0
					p.phase = &"out"
					p.hide = -1
		p.peeking = p.phase == &"inside" and inp.peek
		if noise:
			events.append({"type": "flap", "t": t, "playerId": p.id, "hide": p.hide})
			_reason(s, p.hide, "fast", p.id, t, events)
		# Getting in is out in the open: the resident sees it from where it stands.
		if p.phase == &"entering" and w != null and in_view(plan, w, inp.body):
			p.seen_entering = true
		# The instrument ticking inside within 5 m of the resident.
		if inp.ticking and p.phase == &"inside" and w != null:
			var hb := inside_body(s, hide_of(s, p.hide))
			if hb.level == w.body.level and M.hypot2(hb.x - w.body.x, hb.z - w.body.z) <= Seek.TICK_REASON_RANGE:
				_reason(s, p.hide, "tick", p.id, t, events)
	# A reason lasts while someone is in the hide.
	for hid: int in s.reasons.keys():
		if occupants(s, hid) == 0:
			s.reasons.erase(hid)
	return res

## Pulls a player out of their hide (caught, down, gone): out, at the hide's front spot. Returns the new
## state and that body (null if they were not in a hide). Never mutates `prev`.
static func release(prev: HidingState, id: String) -> Array:
	var p := player_of(prev, id)
	if p == null or p.phase == &"out":
		return [prev, null]
	var h := hide_of(prev, p.hide)
	var s := prev.copy()
	s.players = []
	for q in prev.players:
		if q.id != id:
			s.players.append(q)
			continue
		var nq := q.copy()
		nq.phase = &"out"
		nq.hide = -1
		nq.peeking = false
		nq.phase_left = 0.0
		s.players.append(nq)
	s.reasons = prev.reasons.duplicate()
	if h != null and occupants(s, h.id) == 0:
		s.reasons.erase(h.id)
	return [s, front_body(prev, h) if h != null else null]
