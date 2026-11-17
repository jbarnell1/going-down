# The Annex's crew marks: arrows the crew puts on the floor, as pure rules. No engine random, no
# clock (the caller passes every time in), no rendering. Everything is a function from a MarksState
# to a new MarksState; a state you pass in is never edited, so states can be shared and compared.
#
# The design (docs/floors/annex.md section 2 and the owner's answers): the whole crew shares ONE
# pad of marks per floor (default 3, a parameter so the skill tree can raise it). Anyone can place
# from it and anyone can peel any mark back onto it. Marks are immune to false sights and to the
# Temp; nothing in this file can be told to hide, fake or move one, and the only way to remove a
# mark is peel().
#
# API (all static, all pure):
#   MarksState.start_floor(pad_size := DEFAULT_PAD) -> MarksState   a new floor: full pad, no marks
#   begin_place(s, player, body, yaw, status, gait, aboard, now) -> MarkResult
#       Starts the half-second placing (the two-step choice). Refused (ok false, reason set, state
#       unchanged) when the pad is empty, the player is sprinting, caught/down or aboard the car,
#       or is already placing. Records the spot and direction at the START (turning during the
#       half second does not turn the arrow). Does not take from the pad yet.
#   finish_place(s, player, status, gait, aboard, now) -> MarkResult
#       Completes it once now - started >= PLACE_SECONDS. Refused if too early, nothing was begun,
#       the player now sprints / is down / is aboard, or the pad ran empty meanwhile (a friend
#       took the last one). On success: pad - 1, a Mark appended, and result.noise is the slap.
#   cancel_place(s, player) -> MarksState         drop an unfinished placing (costs nothing)
#   peel(s, mark_id, player, status) -> MarkResult
#       Any player peels any mark (not while down). Pad + 1, never above pad_size. Instant here;
#       the client's hold-F-for-PEEL_SECONDS is a client concern, PEEL_SECONDS is exported for it.
#   set_pad_size(s, n) -> MarksState              skill-tree upgrade: raises the size, and the
#       pad by the same amount. Never lowers (a smaller n is ignored).
#   snap_dir(yaw) -> int                          0..7, see below.
#   MarksState.pad / pad_size / marks / pending / next_id: read-only data.
#   Invariant: pad + marks.size() == pad_size.
#
# status is the RunPlayer status (&"ok" places; anything else, such as &"caught", is down);
# gait is the stamina.gd gait (&"sprint" is refused); aboard is RunPlayer.aboard.
#
# Directions: yaw as in sim/bot.gd and three.js (0 faces -z, positive turns toward -x, radians).
# A mark's dir is that yaw snapped to the nearest of eight, 0 = -z, counting counter-clockwise as
# seen from above: 1 = -z/-x, 2 = -x, 3 = +z/-x, 4 = +z, 5 = +z/+x, 6 = +x, 7 = -z/+x.
# dir_vector(dir) gives the unit (dx, dz). The placer's id is kept for colour and initial
# (initial_of); marks are numbered by placement order (Mark.id, never reused).
extends RefCounted

const Move = preload("res://sim/move.gd")

const DEFAULT_PAD := 3
## The half second the design asks for while placing.
const PLACE_SECONDS := 0.5
## The hold the client asks for before a peel (the rules peel instantly when told to).
const PEEL_SECONDS := 1.0
## How far the slap carries, in metres (a Hearing resident will hear it).
const NOISE_RADIUS := 8.0
const EPS := 1e-9

class Mark:
	var id: int
	var x: float
	var z: float
	var level: int
	var dir: int
	var player: String
	## Time the placing finished.
	var placed_at: float

	static func make(id_: int, x_: float, z_: float, level_: int, dir_: int, player_: String, at: float) -> Mark:
		var m := Mark.new()
		m.id = id_
		m.x = x_
		m.z = z_
		m.level = level_
		m.dir = dir_
		m.player = player_
		m.placed_at = at
		return m

## A placing that has begun and not finished.
class Pending:
	var player: String
	var x: float
	var z: float
	var level: int
	var dir: int
	var started_at: float

## Where a noise is, how far it carries and who made it.
class NoiseEvent:
	var kind: StringName = &"mark_slap"
	var x: float
	var z: float
	var level: int
	var radius: float
	var player: String
	var at: float

class MarksState:
	var pad: int
	var pad_size: int
	var marks: Array[Mark] = []
	var pending: Array[Pending] = []
	var next_id: int = 0

	## A new floor: a full pad and nothing on the walls.
	static func start_floor(pad_size_: int = 3) -> MarksState:
		var s := MarksState.new()
		s.pad_size = maxi(0, pad_size_)
		s.pad = s.pad_size
		return s

	func copy() -> MarksState:
		var s := MarksState.new()
		s.pad = pad
		s.pad_size = pad_size
		# Marks and pendings are never edited after creation, so the copy shares them.
		s.marks = marks.duplicate()
		s.pending = pending.duplicate()
		s.next_id = next_id
		return s

class MarkResult:
	var ok: bool = false
	var reason: StringName = &""
	var state: MarksState
	## Set only by a successful finish_place.
	var noise: NoiseEvent = null
	## The mark placed or peeled, when there is one.
	var mark: Mark = null

static func _fail(s: MarksState, reason: StringName) -> MarkResult:
	var r := MarkResult.new()
	r.state = s
	r.reason = reason
	return r

## Nearest of eight directions for a yaw (any finite float, radians).
static func snap_dir(yaw: float) -> int:
	var k := int(roundf(yaw / (PI / 4.0)))
	return posmod(k, 8)

## Unit (dx, dz) for a direction index.
static func dir_vector(dir: int) -> Vector2:
	var a := float(posmod(dir, 8)) * (PI / 4.0)
	return Vector2(-sin(a), -cos(a))

## The letter drawn on a player's marks.
static func initial_of(player: String) -> String:
	return player.substr(0, 1).to_upper()

static func _blocked(status: StringName, gait: StringName, aboard: bool) -> StringName:
	if status != &"ok":
		return &"down"
	if aboard:
		return &"in_car"
	if gait == &"sprint":
		return &"sprinting"
	return &""

static func _pending_index(s: MarksState, player: String) -> int:
	for i in s.pending.size():
		if s.pending[i].player == player:
			return i
	return -1

static func begin_place(s: MarksState, player: String, body: Move.Body, yaw: float, status: StringName, gait: StringName, aboard: bool, now: float) -> MarkResult:
	var why := _blocked(status, gait, aboard)
	if why != &"":
		return _fail(s, why)
	if s.pad <= 0:
		return _fail(s, &"pad_empty")
	if _pending_index(s, player) >= 0:
		return _fail(s, &"busy")
	var p := Pending.new()
	p.player = player
	p.x = body.x
	p.z = body.z
	p.level = body.level
	p.dir = snap_dir(yaw)
	p.started_at = now
	var n := s.copy()
	n.pending.append(p)
	var r := MarkResult.new()
	r.ok = true
	r.state = n
	return r

static func finish_place(s: MarksState, player: String, status: StringName, gait: StringName, aboard: bool, now: float) -> MarkResult:
	var i := _pending_index(s, player)
	if i < 0:
		return _fail(s, &"not_started")
	var why := _blocked(status, gait, aboard)
	if why != &"":
		return _fail(s, why)
	var p := s.pending[i]
	if now - p.started_at < PLACE_SECONDS - EPS:
		return _fail(s, &"too_early")
	if s.pad <= 0:
		return _fail(s, &"pad_empty")
	var n := s.copy()
	n.pending.remove_at(i)
	n.pad -= 1
	var m := Mark.make(n.next_id, p.x, p.z, p.level, p.dir, player, now)
	n.next_id += 1
	n.marks.append(m)
	var noise := NoiseEvent.new()
	noise.x = p.x
	noise.z = p.z
	noise.level = p.level
	noise.radius = NOISE_RADIUS
	noise.player = player
	noise.at = now
	var r := MarkResult.new()
	r.ok = true
	r.state = n
	r.noise = noise
	r.mark = m
	return r

static func cancel_place(s: MarksState, player: String) -> MarksState:
	var i := _pending_index(s, player)
	if i < 0:
		return s
	var n := s.copy()
	n.pending.remove_at(i)
	return n

static func peel(s: MarksState, mark_id: int, _player: String, status: StringName) -> MarkResult:
	if status != &"ok":
		return _fail(s, &"down")
	var idx := -1
	for i in s.marks.size():
		if s.marks[i].id == mark_id:
			idx = i
	if idx < 0:
		return _fail(s, &"no_such_mark")
	var n := s.copy()
	var m := n.marks[idx]
	n.marks.remove_at(idx)
	n.pad = mini(n.pad + 1, n.pad_size)
	var r := MarkResult.new()
	r.ok = true
	r.state = n
	r.mark = m
	return r

static func set_pad_size(s: MarksState, size: int) -> MarksState:
	if size <= s.pad_size:
		return s
	var n := s.copy()
	n.pad += size - n.pad_size
	n.pad_size = size
	return n
