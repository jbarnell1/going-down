# The Reactor's rules on the generated station (RN1; docs/floors/the-intact-crew.md "The generating station",
# docs/floors/native-late-floors.md "Rules (worker 2)"). Stepped by sim/run.gd (_step_station) on a floor whose
# place is the Reactor, as the Arboretum's Groundskeeper is: the run's own lift, downs, heals and boarding stay
# the run's. What this file owns, all on host time:
#  - The power. Lit on arrival. The first player to pass the landing into the hall starts the hold (the live
#    setting reactor.power_hold, today's 45 s, stamped when the hold starts); when it runs out the power cuts
#    ("powerCut"). Emergency light stays (the plan's emergency lamps). Restored by installing the fuse.
#  - The four bodies (seats 1 to 4, at the plan's anchors). They lie still while the power is on. After the cut,
#    body i stirs reactor.wake_after + i * reactor.wake_gap seconds in; the first stir is the floor's sound cue
#    ("stationStir"), heard before anything can reach anyone: a crawling body never catches. Each crawls (the
#    downloaded zombie crawl) for reactor.crawl_time at reactor.crawl_speed, then stands and pursues at
#    reactor.run_speed (compare the player's 3 m/s walk and 5 m/s sprint) the nearest player on their feet it can
#    walk to, routed through the plan (Floor cells, Follow.step_path_walk as the Orderly walks), never through the
#    crawl. Standing within REACH of its prey for WIND seconds is a catch: the run puts the player down by its
#    normal down rules (or out without them). A player just healed is not caught again for GRACE. Awake bodies
#    stay awake and dangerous through boarding, after the power is back.
#  - The fuse: at one of the plan's fuse spots, chosen from the seed. F held (PlayerInput.use, a fresh press)
#    within USE_REACH picks it up once the power is out; the holder installs it at the cabinet the same way:
#    "powerRestored". A holder who goes down, out or leaves drops it where they are.
#  - The cassette: on the table beside the lift, glowing. A fresh F press within TAPE_REACH takes it (any time).
#    Dropped like the fuse. Whoever holds it aboard when the car leaves has carried it out ("tapeExtracted"); the
#    host banks it in the archive (sim/reactor_archive.gd).
#  - The lift needs power to return: the run refuses the call until the power is restored (sim/run.gd), and the
#    floor asks no quota (nothing here gives a reading). The car leaving always goes up (the Reactor's return).
# Nothing here draws a random number after the floor is made; the four's moves depend on the crew only.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Settings = preload("res://sim/settings.gd")
const Station = preload("res://sim/station.gd")
const Entity = preload("res://sim/entity.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

enum Power { NORMAL, EMERGENCY, RESTORED }

## Today's numbers (the old floor's, net/reactor_review.gd and sim/reactor.gd), the live settings' game values.
const POWER_HOLD := 45.0
const WAKE_AFTER := 1.1
const WAKE_GAP := 0.62
const CRAWL_TIME := 4.2
const CRAWL_SPEED := 0.43
const RUN_SPEED := 3.4
const REACH := 0.72
const WIND := 0.43
const USE_REACH := 2.0
const TAPE_REACH := 2.2
const GRACE := 2.2
const RADIUS := 0.3
const REPLAN := 0.5
## The lying pose's roll and lift as it fades over REST_FADE seconds after a body stirs (seat_poses).
const REST_FADE := 1.25
const CRAWL_CLIP := 5.13
const RUN_CLIP := 0.8
const RUN_CLIP_RATE := 3.4 / 3.03

class Body4:
	var seat: int
	var body: Move.Body
	var yaw: float
	## "still", "zombie_crawl" or "zombie_run" (the clips the old floor named).
	var phase: String = "still"
	var clock: float = 0.0
	var wind: float = 0.0
	var victim: String = ""
	var path: Array[Floor.Pos] = []
	var path_next: int = 0
	var replan_in: float = 0.0

	func copy() -> Body4:
		var b := Body4.new()
		b.seat = seat
		b.body = body
		b.yaw = yaw
		b.phase = phase
		b.clock = clock
		b.wind = wind
		b.victim = victim
		b.path = path
		b.path_next = path_next
		b.replan_in = replan_in
		return b

class StationFloor:
	var plan: Floor.FloorPlan
	var seed_value: int
	var power: int = Power.NORMAL
	## -1 until someone passes the landing; then the host seconds left before the cut (0 after it).
	var hold_left: float = -1.0
	## Seconds since the cut (0 before).
	var awake: float = 0.0
	var holder: String = ""
	var fuse: Vector3
	var cabinet: Vector3
	var fuse_uses: int = 0
	var collected: bool = false
	var cassette_holder: String = ""
	var tape: Vector3
	var returned: bool = false
	var extracted: bool = false
	var stirred: bool = false
	var bodies: Array[Body4] = []
	## The action a held F last did, by player ("" while released): only a fresh press acts.
	var use_before: Dictionary = {}
	## Host time until which a just-healed player cannot be caught.
	var grace: Dictionary = {}
	var low: Dictionary = {}
	var rev: int = 0
	var seq: int = 0

	func copy() -> StationFloor:
		var c := StationFloor.new()
		c.plan = plan
		c.seed_value = seed_value
		c.power = power
		c.hold_left = hold_left
		c.awake = awake
		c.holder = holder
		c.fuse = fuse
		c.cabinet = cabinet
		c.fuse_uses = fuse_uses
		c.collected = collected
		c.cassette_holder = cassette_holder
		c.tape = tape
		c.returned = returned
		c.extracted = extracted
		c.stirred = stirred
		for b in bodies:
			c.bodies.append(b.copy())
		c.use_before = use_before.duplicate()
		c.grace = grace.duplicate()
		c.low = low.duplicate()
		c.rev = rev
		c.seq = seq
		return c

## One player as the rules see them this tick.
class Crew:
	var id: String
	var body: Move.Body
	## "ok", "down", "out", "caught", "leftBehind".
	var status: StringName
	var gait: StringName = &"walk"
	var use: bool = false
	var active: bool = false

	static func make(id_: String, body_: Move.Body, status_: StringName, gait_: StringName, use_: bool, active_: bool) -> Crew:
		var c := Crew.new()
		c.id = id_
		c.body = body_
		c.status = status_
		c.gait = gait_
		c.use = use_
		c.active = active_
		return c

## The fuse spot the seed picks (an index into plan.station["fuse_spots"]).
static func fuse_index(plan: Floor.FloorPlan) -> int:
	var spots: Array = plan.station["fuse_spots"]
	return Rng.make_rng("station-fuse:%s:%d" % [plan.seed, plan.depth]).int_in(0, spots.size() - 1)

## The floor's state as the crew arrives: lit, the four lying where the plan puts them.
static func make(plan: Floor.FloorPlan) -> StationFloor:
	var st := StationFloor.new()
	st.plan = plan
	st.seed_value = plan.seed.hash() & 0x7fffffff
	var a := plan.station
	st.fuse = (a["fuse_spots"] as Array)[fuse_index(plan)]
	st.cabinet = (a["cabinet"] as Dictionary)["at"]
	var r := Rng.make_rng("station-tape:%s:%d" % [plan.seed, plan.depth])
	var plinth: Vector3 = a["plinth"]
	st.tape = plinth + Vector3(r.next() * 0.14 - 0.07, Station.PLINTH_TOP, r.next() * 0.12)
	for d: Dictionary in a["bodies"]:
		var b := Body4.new()
		b.seat = int(d["seat"])
		var at: Vector3 = d["at"]
		b.body = Move.Body.make(at.x, at.z, 0, 0.0)
		b.yaw = float(d["yaw"])
		b.clock = 0.65 + 0.43 * (b.seat - 1)
		st.bodies.append(b)
	return st

static func _flat(a: Vector3, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

## Seconds after the cut that body `i` (0-based) stirs.
static func wake_at(i: int, tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"reactor.wake_after", WAKE_AFTER) + float(i) * Settings.f(tuning, &"reactor.wake_gap", WAKE_GAP)

## Whether a body is in the hall proper (past the landing): the hold starts then.
static func passed_landing(plan: Floor.FloorPlan, b: Move.Body) -> bool:
	var land: Rect2 = plan.station["landing"]
	var hall: Rect2 = plan.station["hall"]
	return b.z < land.position.y and b.z >= hall.position.y and b.x >= hall.position.x - 12.0 and b.x <= hall.end.x + 12.0

## One tick. `crew`: everyone in the run. Returns the ids caught this tick (on their feet; the run puts them down).
static func step(st: StationFloor, crew: Array[Crew], t: float, dt: float, tuning: Settings.Values, events: Array[Dictionary]) -> Array[String]:
	st.seq += 1
	var plan := st.plan
	var by_id := {}
	for c in crew:
		by_id[c.id] = c
		st.low[c.id] = c.gait == &"creep" or c.status == &"down"
	for id: String in st.low.keys():
		if not by_id.has(id):
			st.low.erase(id)
	# Whoever carries something and is no longer on their feet (down, out, gone) drops it where they are.
	_drop_if_gone(st, by_id, events, t)

	# The power.
	if st.power == Power.NORMAL:
		if st.hold_left < 0.0:
			for c in crew:
				if c.status == &"ok" and c.active and passed_landing(plan, c.body):
					st.hold_left = Settings.f(tuning, &"reactor.power_hold", POWER_HOLD)
					st.rev += 1
					events.append({"type": "powerHold", "t": t, "playerId": c.id, "len": st.hold_left})
					break
		else:
			st.hold_left -= dt
		# The hold started (never -1 again: a float a hair under zero is the cut, not a fresh hold).
		if st.hold_left > -1.0 + 1e-6 and st.hold_left <= 1e-9:
			st.hold_left = 0.0
			st.power = Power.EMERGENCY
			st.rev += 1
			events.append({"type": "powerCut", "t": t})
	elif st.power != Power.NORMAL:
		st.awake += dt

	# Uses: a fresh F press, nearest thing first in the old floor's order: fuse, socket, cassette.
	for c in crew:
		if not c.use or c.status != &"ok" or not c.active:
			st.use_before.erase(c.id)
			continue
		if st.use_before.has(c.id):
			continue
		var action := ""
		if st.power == Power.EMERGENCY and st.holder.is_empty() and _flat(st.fuse, c.body) < USE_REACH:
			st.holder = c.id
			action = "fuseTaken"
		elif st.power == Power.EMERGENCY and st.holder == c.id and _flat(st.cabinet, c.body) < USE_REACH:
			st.power = Power.RESTORED
			st.holder = ""
			st.fuse_uses += 1
			action = "powerRestored"
		elif not st.collected and _flat(st.tape, c.body) < TAPE_REACH:
			st.collected = true
			st.cassette_holder = c.id
			action = "tapeTaken"
		if not action.is_empty():
			st.use_before[c.id] = action
			st.rev += 1
			events.append({"type": action, "t": t, "playerId": c.id})
	# The fuse rides with its holder (fuseAt follows them).
	if not st.holder.is_empty() and by_id.has(st.holder):
		var hb: Move.Body = (by_id[st.holder] as Crew).body
		st.fuse = Vector3(hb.x, 1.0, hb.z)
	if not st.cassette_holder.is_empty() and by_id.has(st.cassette_holder):
		var cb: Move.Body = (by_id[st.cassette_holder] as Crew).body
		st.tape = Vector3(cb.x, 1.0, cb.z)

	# The four.
	var caught: Array[String] = []
	if st.power == Power.NORMAL:
		return caught
	var crawl_time := Settings.f(tuning, &"reactor.crawl_time", CRAWL_TIME)
	var crawl_speed := Settings.f(tuning, &"reactor.crawl_speed", CRAWL_SPEED)
	var run_speed := Settings.f(tuning, &"reactor.run_speed", RUN_SPEED)
	var prey: Array[Crew] = []
	for c in crew:
		if c.status == &"ok" and c.active and t >= float(st.grace.get(c.id, -INF)):
			prey.append(c)
	for i in st.bodies.size():
		var b := st.bodies[i]
		var age := st.awake - wake_at(i, tuning)
		if age < 0.0:
			continue
		if not st.stirred:
			st.stirred = true
			st.rev += 1
			events.append({"type": "stationStir", "t": t, "seat": b.seat, "x": b.body.x, "z": b.body.z})
		var crawl := age < crawl_time
		var clip := "zombie_crawl" if crawl else "zombie_run"
		if b.phase != clip:
			b.clock = 0.0
			b.phase = clip
			b.replan_in = 0.0
			if not crawl:
				events.append({"type": "bodyStands", "t": t, "seat": b.seat})
		b.clock = fmod(b.clock + dt * (1.0 if crawl else RUN_CLIP_RATE), CRAWL_CLIP if crawl else RUN_CLIP)
		_move(st, b, prey, (crawl_speed if crawl else run_speed) * dt, dt)
		if crawl:
			b.wind = 0.0
			continue
		# A catch: within reach of its prey long enough.
		var target: Crew = null
		var gap := INF
		for c in prey:
			var d := M.hypot2(c.body.x - b.body.x, c.body.z - b.body.z)
			if c.body.level == b.body.level and d < gap:
				gap = d
				target = c
		if target == null or gap > REACH:
			b.wind = 0.0
			b.victim = ""
			continue
		if b.victim != target.id:
			b.wind = 0.0
		b.victim = target.id
		b.wind += dt
		if b.wind >= WIND - 1e-9 and not caught.has(target.id):
			caught.append(target.id)
			b.wind = 0.0
	for id in caught:
		for k in prey.size():
			if prey[k].id == id:
				prey.remove_at(k)
				break
	return caught

## Moves one body up to `dist` metres toward the nearest prey it can walk to (never through the crawl).
static func _move(st: StationFloor, b: Body4, prey: Array[Crew], dist: float, dt: float) -> void:
	var plan := st.plan
	b.replan_in -= dt
	if b.replan_in <= 1e-9 or b.path.is_empty():
		b.replan_in = REPLAN
		b.path = _route(plan, b.body, prey)
		b.path_next = 1 if b.path.size() > 1 else 0
	if b.path.is_empty():
		return
	var before := b.body
	var last := b.path[b.path.size() - 1]
	var here := Move.cell_of(plan, before)
	if b.path.size() <= 1 or (here.x == last.x and here.y == last.y):
		# The prey's own cell (or the landing, for prey in the car): straight at the nearest prey.
		var goal: Move.Body = null
		var best := INF
		for c in prey:
			var d := M.hypot2(c.body.x - before.x, c.body.z - before.z)
			if d < best:
				best = d
				goal = c.body
		if goal == null:
			return
		var dx := goal.x - before.x
		var dz := goal.z - before.z
		var d2 := M.hypot2(dx, dz)
		var step := minf(dist, d2 - 0.35)
		if step > 1e-6:
			b.body = Move.move_with_collision(plan, before, dx / d2 * step, dz / d2 * step, RADIUS)
	else:
		var walk := Follow.PathWalk.make(b.path, b.path_next)
		b.body = Follow.step_path_walk(plan, walk, before, dist, RADIUS)
		b.path_next = walk.next
	var mx := b.body.x - before.x
	var mz := b.body.z - before.z
	if M.hypot2(mx, mz) > 1e-6:
		b.yaw = Entity.yaw_toward(mx, mz)
	else:
		b.replan_in = 0.0

## The cell route from a body to the nearest prey by walking, crawl cells excluded; prey off the plan (in the car)
## is reached at the landing. Empty when nobody can be reached.
static func _route(plan: Floor.FloorPlan, from: Move.Body, prey: Array[Crew]) -> Array[Floor.Pos]:
	var none: Array[Floor.Pos] = []
	if prey.is_empty():
		return none
	var want := {}
	var n := plan.width * plan.height
	for c in prey:
		var cell := Move.cell_of(plan, c.body)
		if not Floor.is_walkable(plan, 0, cell.x, cell.y):
			cell = plan.landing
		if Station.creep_only(plan, cell.x, cell.y):
			continue
		want[cell.y * plan.width + cell.x] = true
	if want.is_empty():
		return none
	var start := Move.cell_of(plan, from)
	if not Floor.is_walkable(plan, 0, start.x, start.y):
		return none
	var crawl := {}
	for c: Vector2i in plan.station["crawl"]:
		crawl[c.y * plan.width + c.x] = true
	var adj := Floor.adjacency_of(plan)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-2)
	var s0 := start.y * plan.width + start.x
	parent[s0] = -1
	var queue := PackedInt32Array([s0])
	var head := 0
	var found := -1
	while head < queue.size():
		var at := queue[head]
		head += 1
		if want.has(at):
			found = at
			break
		for k in range(adj.start[at], adj.start[at + 1]):
			var to := adj.list[k]
			if to >= n or parent[to] != -2 or crawl.has(to):
				continue
			parent[to] = at
			queue.append(to)
	if found < 0:
		return none
	var rev: Array[Floor.Pos] = []
	var cur := found
	while cur != -1:
		rev.append(Floor.Pos.make(0, cur % plan.width, cur / plan.width))
		cur = parent[cur]
	var out: Array[Floor.Pos] = []
	for i in range(rev.size() - 1, -1, -1):
		out.append(rev[i])
	return out

## Drops what `id` carries where they stand.
static func drop_carried(st: StationFloor, id: String, at: Move.Body, events: Array[Dictionary], t: float) -> void:
	if st.holder == id:
		st.holder = ""
		st.fuse = Vector3(at.x, Station.FUSE_Y, at.z)
		st.rev += 1
		events.append({"type": "fuseDropped", "t": t, "playerId": id, "x": at.x, "z": at.z})
	if st.cassette_holder == id:
		st.cassette_holder = ""
		st.collected = false
		st.tape = Vector3(at.x, 0.05, at.z)
		st.rev += 1
		events.append({"type": "tapeDropped", "t": t, "playerId": id, "x": at.x, "z": at.z, "cassette": true})

static func _drop_if_gone(st: StationFloor, by_id: Dictionary, events: Array[Dictionary], t: float) -> void:
	for id: String in [st.holder, st.cassette_holder]:
		if id.is_empty():
			continue
		var c: Crew = by_id.get(id)
		if c == null:
			# Gone from the run: where the rules last had what they carried.
			if st.holder == id:
				st.holder = ""
				st.fuse.y = Station.FUSE_Y
			if st.cassette_holder == id:
				st.cassette_holder = ""
				st.collected = false
				st.tape.y = 0.05
			st.rev += 1
		elif c.status != &"ok" or not c.active:
			drop_carried(st, id, c.body, events, t)

## The car leaves with `aboard` (ids): the lift has gone up with them; the tape is out if its holder is aboard.
static func board(st: StationFloor, aboard: Array, t: float, events: Array[Dictionary]) -> void:
	st.returned = true
	st.rev += 1
	if not st.cassette_holder.is_empty() and aboard.has(st.cassette_holder):
		st.extracted = true
		events.append({"type": "tapeExtracted", "t": t, "playerId": st.cassette_holder})

## The four's poses as the old block carried them: [x, y, z, yaw, roll, phase, clock].
static func seat_poses(st: StationFloor, tuning: Settings.Values) -> Array:
	var poses := []
	for i in st.bodies.size():
		var b := st.bodies[i]
		var age := st.awake - wake_at(i, tuning) if st.power != Power.NORMAL else -1.0
		var rest := 1.0 - smoothstep(0.0, REST_FADE, age)
		poses.append([b.body.x, b.body.y + (0.23 if i % 2 == 0 else 0.27) * rest, b.body.z, b.yaw,
			(-1.29 if i % 2 == 0 else 1.32) * rest, b.phase, b.clock])
	return poses
