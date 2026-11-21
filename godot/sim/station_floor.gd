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
#    normal down rules (or out without them). A player just healed is not caught again for GRACE. RX2: a crawler
#    comes no nearer than reactor.crawl_keep to anyone on their feet (it never stands up within reach of them);
#    the catcher stays over its catch (goes after nobody else) while they lie down, as the run's resident bends over
#    its catch, and stands off reactor.stand_off seconds once they are healed (reactor.feed 0: it hunts on); the
#    pursuit is scaled by reactor.alone_scale alone and reactor.pair_scale in twos (pursuit_speed). Awake bodies
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
const Sight = preload("res://sim/sight.gd")
const Noises = preload("res://sim/noise.gd")
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
const RUN_SPEED := 2.6
## RX2 (tools/station_crews.gd measured these): the pursuit alone and in twos, how near a crawler may come to
## anyone on their feet, whether a catcher stays over its victim (1) and how long it stands off after a heal.
const ALONE_SCALE := 100.0
const PAIR_SCALE := 100.0
const CRAWL_KEEP := 3.0
const FEED := 1.0
const STAND_OFF := 5.0
## RX3, the senses (live settings reactor.*; tools/station_crews.gd measured these): on (1) or today's all-knowing
## chase (0); sight in the emergency light, once the power is back, for a lit or glowing player, for a creeping one;
## an emergency lamp's glow; hearing a walk and a sprint; the socket's clunk; how long a search lasts and its pace;
## how many of the four one noise draws.
const SENSES := 1.0
const SIGHT_DARK := 6.0
const SIGHT_LIT := 16.0
const SIGHT_GLOW := 10.0
const SIGHT_CREEP := 2.5
const LAMP_GLOW := 2.0
const HEAR_WALK := 6.0
const HEAR_SPRINT := 10.0
const HEAR_SOCKET := 0.0
## RX3: seconds every awake body holds still when the mains come back; the Reactor's boarding, doors open to the bell.
const FLINCH := 3.5
const BOARD := 60.0
const SEARCH_TIME := 8.0
const SEARCH_SPEED := 1.2
const NOISE_DRAWS := 2
## The game's own noise radii (sim/noise.gd), read through the same settings (noise.emote, noise.drop).
const NOISE_EMOTE := Noises.EMOTE
const NOISE_DROP := Noises.DROP
const MOVING := 0.2
## RX3 (the design lead's direction, 20 Nov): through a wall a walk is heard only this near; within this of its
## hunted player a body lunges at this speed (a burst the player sees and hears coming); with a crew of one or two
## only this many of the four wake at the cut, the others WAKE_LATE seconds after it.
const HEAR_WALL := 3.0
const LUNGE_RANGE := 2.0
const LUNGE_SPEED := 4.5
const WAKE_ALONE := 2
const WAKE_PAIR := 3
const WAKE_LATE := 90.0
const ARRIVE := 1.0
const WANDER := 2
const WANDER_HOLD := 3.0
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
	## RX2: the player this body has put down and stays over while they lie there ("" none).
	var feeding: String = ""
	## RX2: host time until which it stands off after its victim was healed.
	var quiet_until: float = -INF
	## RX3, the senses: "search" (wanders round `goal` for `left` seconds), "hunt" (goes for `target`, sensed this
	## tick), "seek" (goes to `goal`, where it last sensed someone or heard a noise), "drift" (back to the hall's
	## middle). `wander` counts the wander points picked (the next one is a hash of the seed, the seat and it).
	var mode: String = "search"
	var target: String = ""
	var goal: Vector2 = Vector2.INF
	var left: float = 0.0
	var wander: int = 0
	var wander_to: Vector2 = Vector2.INF
	var wander_left: float = 0.0

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
		b.feeding = feeding
		b.quiet_until = quiet_until
		b.mode = mode
		b.target = target
		b.goal = goal
		b.left = left
		b.wander = wander
		b.wander_to = wander_to
		b.wander_left = wander_left
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
	## RX3: where each player stood last tick ({id: Vector2}): a walk is heard only when they moved.
	var moved: Dictionary = {}
	## RX3: the crew's size the last tick (how many of the four wake at the cut); host time the power came back
	## (-INF before); this tick's host time.
	var crew_n: int = 4
	var restored_at: float = -INF
	var seq_t: float = 0.0

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
		c.moved = moved.duplicate()
		c.crew_n = crew_n
		c.restored_at = restored_at
		c.seq_t = seq_t
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
	## RX3: their lamp is on (seen further); they made a sound emote this tick (heard as a point noise).
	var lit: bool = false
	var shout: bool = false
	## PY1 (the run's economy_fix): they own Soft Shoes, so a walk is heard Noises.SOFT_SHOES as far.
	var soft: bool = false
	## VC1 (sim/run.gd "VC1"): how far their real voice carries to the four this tick (0: silent). Heard like a walk,
	## through walls, standing or moving; Soft Shoes never shortens it.
	var voice_r: float = 0.0

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

## RX3: seconds after the cut that body `i` stirs on this floor: wake_at, and reactor.wake_late more for the bodies a
## small crew does not wake at the cut (reactor.wake_alone of the four for one player, reactor.wake_pair for two).
static func wake_time(st: StationFloor, i: int, tuning: Settings.Values) -> float:
	var n := st.crew_n
	var woken := 4
	if n == 1:
		woken = Settings.i(tuning, &"reactor.wake_alone", WAKE_ALONE)
	elif n == 2:
		woken = Settings.i(tuning, &"reactor.wake_pair", WAKE_PAIR)
	return wake_at(i, tuning) + (Settings.f(tuning, &"reactor.wake_late", WAKE_LATE) if i >= woken else 0.0)

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
			st.restored_at = t
			action = "powerRestored"
			# RX3: the mains come back: every awake body flinches and holds still reactor.flinch seconds.
			var flinch := Settings.f(tuning, &"reactor.flinch", FLINCH)
			for i in st.bodies.size():
				if st.awake - wake_time(st, i, tuning) >= 0.0:
					st.bodies[i].quiet_until = maxf(st.bodies[i].quiet_until, t + flinch)
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
	# RX3: who moved since last tick (a walk is heard only while it moves).
	var moving := {}
	st.crew_n = crew.size()
	st.seq_t = t
	for c in crew:
		var prev: Variant = st.moved.get(c.id)
		moving[c.id] = prev is Vector2 and Vector2(c.body.x, c.body.z).distance_to(prev) > MOVING * dt
		st.moved[c.id] = Vector2(c.body.x, c.body.z)
	if st.power == Power.NORMAL:
		return caught
	var crawl_time := Settings.f(tuning, &"reactor.crawl_time", CRAWL_TIME)
	var crawl_speed := Settings.f(tuning, &"reactor.crawl_speed", CRAWL_SPEED)
	var run_speed := pursuit_speed(crew.size(), tuning)
	var keep := Settings.f(tuning, &"reactor.crawl_keep", CRAWL_KEEP)
	var feed := Settings.f(tuning, &"reactor.feed", FEED) > 0.5
	var stand_off := Settings.f(tuning, &"reactor.stand_off", STAND_OFF)
	var prey: Array[Crew] = []
	for c in crew:
		if c.status == &"ok" and c.active and t >= float(st.grace.get(c.id, -INF)):
			prey.append(c)
	var senses := Settings.f(tuning, &"reactor.senses", SENSES) > 0.5
	var search_speed := Settings.f(tuning, &"reactor.search_speed", SEARCH_SPEED)
	var drawn := _noises_drawn(st, crew, t, tuning, events) if senses else {}
	for i in st.bodies.size():
		var b := st.bodies[i]
		var age := st.awake - wake_time(st, i, tuning)
		if age < 0.0:
			continue
		# RX2: a body that has put someone down stays over them (goes after nobody else) while they lie there; healed,
		# it stands off for reactor.stand_off seconds; out or gone, it hunts again at once.
		if not b.feeding.is_empty():
			var v: Crew = by_id.get(b.feeding)
			if v != null and v.status == &"down":
				b.wind = 0.0
				b.victim = ""
				b.clock = fmod(b.clock + dt * RUN_CLIP_RATE, RUN_CLIP)
				continue
			if v != null and v.status == &"ok":
				b.quiet_until = t + stand_off
			b.feeding = ""
		if t < b.quiet_until - 1e-9:
			b.wind = 0.0
			b.victim = ""
			continue
		if not st.stirred:
			st.stirred = true
			st.rev += 1
			events.append({"type": "stationStir", "t": t, "seat": b.seat, "x": b.body.x, "z": b.body.z})
		var crawl := age < crawl_time
		# RX3: with the senses it goes only for whom it senses (else where it last sensed someone or heard a noise).
		var sensed: Array[Crew] = prey
		var slow := false
		if senses:
			sensed = _sense(st, b, crawl, prey, moving, drawn.get(i, Vector2.INF), tuning, dt)
			slow = b.mode == "search" or b.mode == "drift"
		var clip := "zombie_crawl" if crawl else ("zombie_walk" if slow else "zombie_run")
		if b.phase != clip:
			var before_phase := b.phase
			b.clock = 0.0
			b.phase = clip
			b.replan_in = 0.0
			if not crawl and (before_phase == "zombie_crawl" or before_phase == "still"):
				events.append({"type": "bodyStands", "t": t, "seat": b.seat})
		var rate := 1.0 if crawl else (RUN_CLIP_RATE * search_speed / run_speed if slow else RUN_CLIP_RATE)
		b.clock = fmod(b.clock + dt * rate, CRAWL_CLIP if crawl else RUN_CLIP)
		var was := b.body
		if senses:
			var pace := crawl_speed if crawl else (search_speed if slow else run_speed)
			if not crawl and b.mode == "hunt" and by_id.has(b.target):
				var tc: Crew = by_id[b.target]
				if M.hypot2(tc.body.x - b.body.x, tc.body.z - b.body.z) <= Settings.f(tuning, &"reactor.lunge_range", LUNGE_RANGE):
					pace = maxf(pace, Settings.f(tuning, &"reactor.lunge_speed", LUNGE_SPEED))
			_move(st, b, _aim(b, by_id), pace * dt, dt)
		else:
			_move(st, b, prey, (crawl_speed if crawl else run_speed) * dt, dt)
		if crawl:
			# RX2: a crawler comes no nearer than reactor.crawl_keep to anyone on their feet, so it never stands up
			# already within reach of them.
			if keep > 0.0 and _nearest(prey, b.body) < keep and _nearest(prey, b.body) < _nearest(prey, was):
				b.body = was
			b.wind = 0.0
			continue
		# A catch: within reach of its prey long enough (with the senses, only someone it senses).
		var target: Crew = null
		var gap := INF
		for c in sensed:
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
			if feed:
				b.feeding = target.id
				b.victim = ""
	for id in caught:
		for k in prey.size():
			if prey[k].id == id:
				prey.remove_at(k)
				break
	return caught

## RX3: the point noises of this tick, as [x, z, radius]: a sound emote by anyone on their feet (noise.emote), a
## flare's burst (its own noise), a dropped fuse or tape (noise.drop), the cabinet's socket taking the fuse
## (reactor.hear_socket). Then, for each noise, the reactor.noise_draws nearest of the four that hear it (inside its
## radius, awake, not feeding, standing off or hunting) go to it; a body that hears two goes to the nearer.
## Returns {body index: Vector2 where to go}.
static func _noises_drawn(st: StationFloor, crew: Array[Crew], t: float, tuning: Settings.Values, events: Array[Dictionary]) -> Dictionary:
	var noises: Array = []
	for c in crew:
		if c.shout and c.status == &"ok" and c.active:
			noises.append([c.body.x, c.body.z, Settings.f(tuning, &"noise.emote", NOISE_EMOTE)])
	for e in events:
		if absf(float(e.get("t", -INF)) - t) > 1e-9:
			continue
		match str(e.get("type", "")):
			"flareUsed": noises.append([float(e["x"]), float(e["z"]), float(e.get("noise", 12.0))])
			"fuseDropped", "tapeDropped": noises.append([float(e["x"]), float(e["z"]), Settings.f(tuning, &"noise.drop", NOISE_DROP)])
			"powerRestored": noises.append([st.cabinet.x, st.cabinet.z, Settings.f(tuning, &"reactor.hear_socket", HEAR_SOCKET)])
	var out := {}
	if noises.is_empty():
		return out
	var draws := Settings.i(tuning, &"reactor.noise_draws", NOISE_DRAWS)
	var best := {}
	for n: Array in noises:
		var near: Array = []
		for i in st.bodies.size():
			var b := st.bodies[i]
			if st.awake - wake_time(st, i, tuning) < 0.0 or not b.feeding.is_empty() or t < b.quiet_until - 1e-9 or b.mode == "hunt":
				continue
			var d := M.hypot2(float(n[0]) - b.body.x, float(n[1]) - b.body.z)
			if d <= float(n[2]) + 1e-9:
				near.append([d, i])
		near.sort_custom(func(a: Array, c: Array) -> bool: return a[0] < c[0] or (a[0] == c[0] and a[1] < c[1]))
		for k in mini(draws, near.size()):
			var i: int = near[k][1]
			if not best.has(i) or float(near[k][0]) < float(best[i]) - 1e-9:
				best[i] = near[k][0]
				out[i] = Vector2(float(n[0]), float(n[1]))
	return out

## RX3: whether body `b` senses player `c` this tick. It hears a sprint within reactor.hear_sprint and a walk within
## reactor.hear_walk (straight distance, through walls: only while they move); a creep, never. It sees them with a
## clear line (eye to chest) within reactor.sight_dark in the emergency light (reactor.sight_lit once the power is
## back), at least reactor.sight_glow when their lamp is on, they carry the glowing tape or stand within
## reactor.lamp_glow of an emergency lamp, and no further than reactor.sight_creep while they creep.
static func senses_player(st: StationFloor, b: Body4, crawl: bool, c: Crew, moving: bool, tuning: Settings.Values) -> bool:
	if c.body.level != b.body.level:
		return false
	# Down among the cable trays a player is out of their sight and too low to hear (the crawl loses them).
	var cc := Move.cell_of(st.plan, c.body)
	if Station.creep_only(st.plan, cc.x, cc.y):
		return false
	var d := M.hypot2(c.body.x - b.body.x, c.body.z - b.body.z)
	if moving and c.gait == &"sprint" and d <= Settings.f(tuning, &"reactor.hear_sprint", HEAR_SPRINT):
		return true
	# PY1: Soft Shoes (c.soft) shortens both a walk's reaches, round the open and through walls, by Noises.SOFT_SHOES.
	var walk_reach := Settings.f(tuning, &"reactor.hear_walk", HEAR_WALK)
	var wall_reach := Settings.f(tuning, &"reactor.hear_wall", HEAR_WALL)
	if c.soft:
		walk_reach *= Noises.SOFT_SHOES
		wall_reach *= Noises.SOFT_SHOES
	var walk_heard := moving and c.gait == &"walk" and d <= walk_reach
	if walk_heard and d <= wall_reach:
		return true
	# VC1: a voice within its reach, through walls.
	if c.voice_r > 0.0 and d <= c.voice_r:
		return true
	# The lit sight only once their flinch at the mains coming back is over.
	var lit_now := st.power == Power.RESTORED and st.seq_t >= st.restored_at + Settings.f(tuning, &"reactor.flinch", FLINCH) - 1e-9
	var see := Settings.f(tuning, &"reactor.sight_lit", SIGHT_LIT) if lit_now else Settings.f(tuning, &"reactor.sight_dark", SIGHT_DARK)
	if c.lit or st.cassette_holder == c.id or _under_lamp(st, c.body, Settings.f(tuning, &"reactor.lamp_glow", LAMP_GLOW)):
		see = maxf(see, Settings.f(tuning, &"reactor.sight_glow", SIGHT_GLOW))
	var creep := c.gait == &"creep"
	if creep:
		see = minf(see, Settings.f(tuning, &"reactor.sight_creep", SIGHT_CREEP))
	if d > see and not walk_heard:
		return false
	# A walk beyond the wall's reach is heard only with a clear line (round a corner it is lost).
	return Sight.has_line_of_sight(st.plan, Sight.Point3.make(b.body.x, 0.4 if crawl else 1.6, b.body.z, b.body.level),
		Sight.Point3.make(c.body.x, 0.6 if creep else 1.2, c.body.z, c.body.level))

static func _under_lamp(st: StationFloor, at: Move.Body, r: float) -> bool:
	if r <= 0.0:
		return false
	for l: Dictionary in st.plan.station.get("lamps", []):
		if bool(l.get("emergency", false)):
			var p: Vector3 = l["at"]
			if M.hypot2(p.x - at.x, p.z - at.z) <= r:
				return true
	return false

## RX3: one body's knowledge for this tick (see the header); returns whom it senses.
static func _sense(st: StationFloor, b: Body4, crawl: bool, prey: Array[Crew], moving: Dictionary, noise: Vector2, tuning: Settings.Values, dt: float) -> Array[Crew]:
	var found: Array[Crew] = []
	var nearest: Crew = null
	var best := INF
	for c in prey:
		if senses_player(st, b, crawl, c, bool(moving.get(c.id, false)), tuning):
			found.append(c)
			var d := M.hypot2(c.body.x - b.body.x, c.body.z - b.body.z)
			if d < best - 1e-9:
				best = d
				nearest = c
	if nearest != null:
		if b.mode != "hunt" or b.target != nearest.id:
			b.replan_in = 0.0
		b.mode = "hunt"
		b.target = nearest.id
		b.goal = Vector2(nearest.body.x, nearest.body.z)
		return found
	if b.mode == "hunt":
		# Lost them: to the last place it sensed them.
		b.mode = "seek"
		b.target = ""
		b.replan_in = 0.0
	if noise != Vector2.INF:
		b.mode = "seek"
		b.goal = noise
		b.replan_in = 0.0
	var here := Vector2(b.body.x, b.body.z)
	match b.mode:
		"seek":
			if b.goal == Vector2.INF or here.distance_to(b.goal) <= ARRIVE:
				_start_search(b, tuning)
		"drift":
			var hall: Rect2 = st.plan.station["hall"]
			b.goal = hall.get_center()
			if here.distance_to(b.goal) <= 2.0:
				_start_search(b, tuning)
		_:
			if b.goal == Vector2.INF:
				_start_search(b, tuning)
			b.left -= dt
			b.wander_left -= dt
			if b.left <= 0.0:
				b.mode = "drift"
				b.replan_in = 0.0
			elif b.wander_to == Vector2.INF or here.distance_to(b.wander_to) <= ARRIVE or b.wander_left <= 0.0:
				b.wander_to = _wander_point(st, b)
				b.wander_left = WANDER_HOLD
				b.replan_in = 0.0
	return found

static func _start_search(b: Body4, tuning: Settings.Values) -> void:
	b.mode = "search"
	b.left = Settings.f(tuning, &"reactor.search_time", SEARCH_TIME)
	b.wander_to = Vector2.INF
	b.wander_left = 0.0
	b.goal = Vector2(b.body.x, b.body.z) if b.goal == Vector2.INF else b.goal

## The next place a searching body looks: a walkable cell (not the crawl) within WANDER cells of where it searches,
## picked by a hash of the floor's seed, its seat and how many it has picked.
static func _wander_point(st: StationFloor, b: Body4) -> Vector2:
	var plan := st.plan
	var g := b.goal if b.goal != Vector2.INF else Vector2(b.body.x, b.body.z)
	var centre := Station.cell_of(g.x, g.y)
	var cells: Array[Vector2i] = []
	for dy in range(-WANDER, WANDER + 1):
		for dx in range(-WANDER, WANDER + 1):
			var cx := centre.x + dx
			var cy := centre.y + dy
			if cx >= 0 and cy >= 0 and cx < plan.width and cy < plan.height and Floor.is_walkable(plan, 0, cx, cy) and not Station.creep_only(plan, cx, cy):
				cells.append(Vector2i(cx, cy))
	b.wander += 1
	if cells.is_empty():
		return g
	var h := ("station-wander:%d:%d:%d" % [st.seed_value, b.seat, b.wander]).hash() & 0x7fffffff
	var c := cells[h % cells.size()]
	return Vector2(Station.wc(c.x), Station.wc(c.y))

## Whom `_move` walks to: its hunted player, or a stand-in at the place it goes.
static func _aim(b: Body4, by_id: Dictionary) -> Array[Crew]:
	var out: Array[Crew] = []
	if b.mode == "hunt" and by_id.has(b.target):
		out.append(by_id[b.target])
		return out
	var to := b.wander_to if b.mode == "search" and b.wander_to != Vector2.INF else b.goal
	if to == Vector2.INF:
		return out
	out.append(Crew.make("", Move.Body.make(to.x, to.y, b.body.level, 0.0), &"ok", &"walk", false, true))
	return out

## RX2: the pursuit speed for a crew of `size` (the run's players): reactor.run_speed, times reactor.alone_scale
## (in 100) alone and reactor.pair_scale in twos, as the Temp chases a lone player slower (sim/lonely.gd).
static func pursuit_speed(size: int, tuning: Settings.Values) -> float:
	var full := Settings.f(tuning, &"reactor.run_speed", RUN_SPEED)
	if size <= 1:
		return full * Settings.f(tuning, &"reactor.alone_scale", ALONE_SCALE) / 100.0
	if size == 2:
		return full * Settings.f(tuning, &"reactor.pair_scale", PAIR_SCALE) / 100.0
	return full

static func _nearest(prey: Array[Crew], at: Move.Body) -> float:
	var best := INF
	for c in prey:
		if c.body.level == at.level:
			best = minf(best, M.hypot2(c.body.x - at.x, c.body.z - at.z))
	return best

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
		var age := st.awake - wake_time(st, i, tuning) if st.power != Power.NORMAL else -1.0
		var rest := 1.0 - smoothstep(0.0, REST_FADE, age)
		poses.append([b.body.x, b.body.y + (0.23 if i % 2 == 0 else 0.27) * rest, b.body.z, b.yaw,
			(-1.29 if i % 2 == 0 else 1.32) * rest, b.phase, b.clock])
	return poses
