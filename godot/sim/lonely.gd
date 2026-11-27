# The Temp's own mechanic: Lonely (docs/floors/traits-and-hiding.md section 2 "The Temp: Lonely"; T19c). The
# owner, 17 Nov: "Let's make lonely mean out of sight from anyone else, and a certain distance away." It goes
# only for a player who is alone; the moment they are not, it turns its back, walks off where nobody can see it
# and turns up near someone else (sim/relocate.gd's Lonely row). Pure and deterministic; sim/run.gd calls step()
# once a tick for a Lonely resident (Run.with_lonely: net/host_rules.gd turns it on for the game's rooms; tests
# and every stored result leave it off, and then the Temp keeps the Orderly's Stillness rules).
#
# Lonely (lonely_ids). The people are every player on their feet with an input (in the car too) and every
# player down on the carpet; a caught, out or left-behind player is nobody. A player it may go for (Person.prey:
# on their feet, with an input, out of the car) is lonely when every other person is
#   1. more than COMPANY_NEAR (8 m) away in a straight line, or on another level; and
#   2. not joined to them by a clear line (Sight.has_line_of_sight, eye to eye, whichever way either faces)
#      within COMPANY_LINE (20 m).
# So a friend within 8 m is company even through a wall, and so is one you could see within 20 m by turning
# round. A crewmate down on the carpet is company while they lie there (healing is safe from it). With one
# person on the floor that one is always lonely. Becoming lonely and ceasing to be both take effect the tick
# the positions say so, from this tick's positions: the rule leans to the player.
#
# What it does while hunting (OrderlyState.lonely_phase):
#   lurk      it stands where it is (where relocation put it, out of view near the most isolated player),
#             clicking once every 4 s (the stapler, sim/entity.gd). Nobody lonely: it stays here.
#   approach  someone is lonely: it strolls at APPROACH_SPEED towards its target if that one is lonely, else
#             towards the lonely player nearest by walking. One click per 1.2 m.
#   chase     a lonely player with a clear line from its face within CHASE_RANGE (16 m) and inside
#             CHASE_CONE degrees either side of where its paper face points: from that tick it chases them at
#             CHASE_SPEED (3.9 m/s: above a walk, below a sprint), with no creep. Within Entity.CATCH_RANGE it
#             winds up (Entity.WIND_UP_TIME) and catches. "chaseStarted" {playerId, at, yaw}.
#             - The tick its target stops being lonely it stops, cancels any wind-up and breaks off.
#             - No clear line to the target for LOST_TIME (4 s): back to approach.
#             - "chaseEnded" {playerId, why: "company" | "lost" | "caught" | "gone"} on every way out.
#   breakoff  it turns its back and walks away at BREAK_OFF_SPEED by the shortest path to the nearest cell
#             that is no nearer the player it left and that no person has a clear line to (the first of those
#             that also passes relocation's own out-of-view test, Relocate.out_of_view, when one of the
#             nearest FULL_TRIES does), and stands there.
#             sim/relocate.gd's Lonely row takes it away once it has been out of view for 1 s (rested, and
#             with a cell to go to). Without relocation, or after BREAK_OFF_GIVE_UP seconds, it lurks again.
# Looking at it does nothing: it is never held, and the host's seen reports are not applied to it (net/host.gd
# reads sim/run.gd's resident_of). The one hold it honours is the host's catch hold (net/host.gd
# _confirm_catch: a catch waits for its victim's screen), so a wind-up whose time is up completes only on a
# tick that hold is not on (Entity.held_by_grace of the last tick).
#
# The solo run (the owner, 17 Nov: "Lonely, but it's slower than a single player"): with a crew of one the
# player is always lonely, so it is always coming; it chases at SOLO_CHASE_SPEED (2.6 m/s), slower than a walk
# (3.0) and faster than a walk with the instrument up (2.2). Walking away always works; recording it while it
# comes does not, for long.
#
# The instrument (sim/instrument.gd "lonely"): it records only while it chases (chasing), and only on the
# instrument of the player it chases (sim/run.gd sets the tick's holders). Everything else (waking, the
# stapler, dormancy, bending over a downed player, the stand after a relocation) is the shared resident rules
# of sim/entity.gd, unchanged.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Follow = preload("res://sim/follow.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")
const Entity = preload("res://sim/entity.gd")
const M = preload("res://sim/jsmath.gd")
const Relocate = preload("res://sim/relocate.gd")

## Company: within this straight-line distance on the same level (metres)...
const COMPANY_NEAR := 8.0
## ...or a clear line within this distance (metres).
const COMPANY_LINE := 20.0
## The stroll towards a lonely player (m/s).
const APPROACH_SPEED := 2.0
## The chase (m/s): slightly faster than a walking player (Stamina.WALK_SPEED 3.0), slower than a sprint (5.0).
## Its own constant, not the Orderly's hunt speed.
const CHASE_SPEED := 3.9
## The chase in a solo run (m/s): slower than a walk, faster than a walk with the instrument up.
const SOLO_CHASE_SPEED := 2.6
## A chase starts on a lonely player in a clear line within this many metres...
const CHASE_RANGE := 16.0
## ...and within this many degrees either side of where its face points.
const CHASE_CONE := 60.0
## Seconds without a clear line to the chased player before it goes back to approaching.
const LOST_TIME := 4.0
## Walking away after a break-off (m/s).
const BREAK_OFF_SPEED := 3.9
## Seconds in a break-off before it gives up waiting to relocate and lurks again.
const BREAK_OFF_GIVE_UP := 30.0
## How far (by walking, cells) it looks for somewhere out of every line to walk off to.
const HIDE_SEARCH_STEPS := 30
## The heights (metres above a cell's floor) a hiding cell must be out of every line at.
const HIDE_HEIGHTS: Array[float] = [1.0, 1.8]
## At most this many cells get relocation's full out-of-view test.
const FULL_TRIES := 16
## Its face, as a height above its feet (the paper face of a 1.8 m figure).
const FACE_HEIGHT := 1.6
## A player's chest, for the chase's line (metres above their feet).
const CHEST := 1.0
const EPS := 1e-9

## A player as Lonely sees them.
class Person:
	var id: String
	var body: Move.Body
	## Eye height above their feet.
	var eye: float
	## It may go for them: on their feet, with an input, out of the car. Otherwise only company.
	var prey: bool

	static func make(id_: String, body_: Move.Body, eye_: float, prey_: bool) -> Person:
		var p := Person.new()
		p.id = id_
		p.body = body_
		p.eye = eye_
		p.prey = prey_
		return p

# ---------------------------------------------------------------------------------------------
# Who is lonely.

## Whether `a` has company in `b` (see the header): within COMPANY_NEAR on the same level, or a clear line eye
## to eye within COMPANY_LINE.
## `line_block` (DG0, sim/dangers.gd): (a body, b body) -> true when a danger's closed door cuts the line; none by default.
static func company(plan: Floor.FloorPlan, a: Person, b: Person, line_block: Callable = Callable()) -> bool:
	if a.body.level == b.body.level and M.hypot2(a.body.x - b.body.x, a.body.z - b.body.z) <= COMPANY_NEAR + EPS:
		return true
	var ea := Sight.eye_point(a.body, a.eye)
	var eb := Sight.eye_point(b.body, b.eye)
	if M.hypot3(ea.x - eb.x, ea.y - eb.y, ea.z - eb.z) > COMPANY_LINE + EPS:
		return false
	if line_block.is_valid() and line_block.call(a.body, b.body):
		return false
	return Sight.has_line_of_sight(plan, ea, eb)

## Whether person `p` is lonely among `people` (see the header).
static func is_lonely(plan: Floor.FloorPlan, people: Array[Person], p: Person, line_block: Callable = Callable()) -> bool:
	for q in people:
		if q != p and company(plan, p, q, line_block):
			return false
	return true

## The players it may go for who are lonely this tick, {id: true}.
static func lonely_ids(plan: Floor.FloorPlan, people: Array[Person], line_block: Callable = Callable()) -> Dictionary:
	var out := {}
	for p in people:
		if p.prey and is_lonely(plan, people, p, line_block):
			out[p.id] = true
	return out

static func _person(people: Array[Person], id: Variant) -> Person:
	for p in people:
		if id != null and p.id == str(id):
			return p
	return null

## A clear line from its face to the player's eyes or chest. `line_block` (DG0): (its body, their body) -> true when a
## danger's shut door is between them (none by default: nothing blocks).
static func line_to(plan: Floor.FloorPlan, o: Entity.OrderlyState, p: Person, line_block: Callable = Callable()) -> bool:
	if line_block.is_valid() and line_block.call(o.body, p.body):
		return false
	var face := Sight.Point3.make(o.body.x, o.body.y + FACE_HEIGHT, o.body.z, o.body.level)
	return Sight.has_line_of_sight(plan, face, Sight.eye_point(p.body, p.eye)) \
		or Sight.has_line_of_sight(plan, face, Sight.Point3.make(p.body.x, p.body.y + CHEST, p.body.z, p.body.level))

## It sees `p` well enough to start a chase: within CHASE_RANGE, inside CHASE_CONE of its face, a clear line.
static func sees(plan: Floor.FloorPlan, o: Entity.OrderlyState, p: Person, line_block: Callable = Callable()) -> bool:
	var dx := p.body.x - o.body.x
	var dz := p.body.z - o.body.z
	if M.hypot3(dx, p.body.y - o.body.y, dz) > CHASE_RANGE + EPS:
		return false
	if M.hypot2(dx, dz) > 1e-6:
		var off := absf(Entity._wrap_angle(Entity.yaw_toward(dx, dz) - o.yaw))
		if off > deg_to_rad(CHASE_CONE) + EPS:
			return false
	return line_to(plan, o, p, line_block)

## It is chasing this tick (the instrument's "acting"): in a chase, its wind-up included, or catching now.
static func chasing(prev: Entity.OrderlyState, next: Entity.OrderlyState) -> bool:
	if next.relocated:
		return false
	return next.lonely_phase == &"chase" or (prev.lonely_phase == &"chase" and next.lonely_phase == &"" and next.mode != &"hunting")

## Who it is chasing this tick (see chasing), or "".
static func chased(prev: Entity.OrderlyState, next: Entity.OrderlyState) -> String:
	if not chasing(prev, next):
		return ""
	var id: Variant = next.lonely_target if next.lonely_phase == &"chase" else prev.lonely_target
	return str(id) if id != null else ""

# ---------------------------------------------------------------------------------------------
# The step.

## A view of `p` for Entity's walking code (_hunt): active, seeing nothing.
static func _view(p: Person) -> Entity.PlayerView:
	return Entity.PlayerView.make(p.id, p.body, p.eye, 0.0, 0.0, 90.0, 70.0, true, true)

## Advances the Lonely resident by dt seconds. `views`: every player's view this tick (only for whether it is
## seen: firstSeen and waking); `solo`: a crew of one; `relocating`: the run relocates it (a break-off then
## waits for that). `chase`: the chase speed the host set (live settings, sim/run.gd _tuned_chase), or -1 for
## CHASE_SPEED (SOLO_CHASE_SPEED solo). Never mutates `prev`.
static func step(plan: Floor.FloorPlan, prev: Entity.OrderlyState, people: Array[Person], views: Array[Entity.PlayerView], dt: float, solo: bool, relocating: bool, chase: float = -1.0, solids: Move.Solids = null, line_block: Callable = Callable()) -> Entity.StepResult:
	var k := Entity.kind_of(prev)
	var t := prev.t + dt
	var s := prev.copy()
	s.t = t
	s.moving = false
	s.speed = 0.0
	s.relocated = false
	s.held = false
	s.frozen = false
	s.need = 1
	if not s.watchers.is_empty():
		var none: Array[String] = []
		s.watchers = none
	var res := Entity.StepResult.new()
	res.state = s
	var events := res.events

	# Seen: only for the first sighting and waking. Looking never holds it.
	var seer := Entity.seen_by(plan, prev.body, views, k)
	s.seen = seer != null
	if seer != null and not prev.ever_seen:
		s.ever_seen = true
		events.append({"type": "firstSeen", "t": t, "playerId": seer.id})
	s.unwatched_for = 0.0
	var standing := prev.stand_left > EPS
	if standing:
		s.stand_left = maxf(0.0, prev.stand_left - dt)
	var lonely := lonely_ids(plan, people, line_block)
	s.lonely_quiet = prev.lonely_quiet + dt if lonely.is_empty() else 0.0

	match s.mode:
		&"waiting":
			if s.seen:
				s.seen_total += dt
			var near := _nearest_prey(plan, s.body, people, null)
			var close := near != null and _walk_steps(plan, s.body, near) * plan.cell_size < Entity.WAKE_DISTANCE
			if s.seen_total >= Entity.WAKE_SEEN_TIME - EPS or close or t >= Entity.WAKE_TIMEOUT - EPS:
				_wake(s, events)
		&"dormant":
			s.dormant_left -= dt
			if s.dormant_left <= EPS:
				s.dormant_left = 0.0
				_wake(s, events)
		&"bending":
			s.anim = &"bend"
			s.anim_time += dt
			return res

	if standing:
		s.anim = &"idle"
		_finish(prev, res, dt, k)
		return res
	s.anim_time += dt
	if s.mode == &"waiting" or s.mode == &"dormant":
		s.anim = &"idle"
		_finish(prev, res, dt, k)
		return res

	if s.mode == &"windUp":
		_wind_up(plan, prev, s, people, lonely, events)
		_finish(prev, res, dt, k)
		return res

	# Hunting.
	if s.lonely_phase == &"":
		s.lonely_phase = &"lurk"
	if s.lonely_phase == &"breakoff":
		_step_break_off(plan, s, people, dt, k, relocating, solids)
		_finish(prev, res, dt, k)
		return res
	if s.lonely_phase == &"chase":
		var target := _person(people, s.lonely_target)
		if target == null or not target.prey:
			_end_chase(s, events, "gone")
			s.lonely_phase = &"lurk"
		elif not lonely.has(target.id):
			_end_chase(s, events, "company")
			_break_off(plan, s, people, target.id, k)
			_step_break_off(plan, s, people, dt, k, relocating, solids)
			_finish(prev, res, dt, k)
			return res
		else:
			s.lonely_lost = 0.0 if line_to(plan, s, target, line_block) else prev.lonely_lost + dt
			if s.lonely_lost >= LOST_TIME - EPS:
				_end_chase(s, events, "lost")
				s.lonely_phase = &"approach"
	if s.lonely_phase != &"chase":
		# Anyone lonely in its sight? The nearest of them, from this tick.
		var best: Person = null
		var best_d := INF
		for p in people:
			if lonely.has(p.id) and sees(plan, s, p, line_block):
				var d := M.hypot2(p.body.x - s.body.x, p.body.z - s.body.z)
				if d < best_d - EPS:
					best_d = d
					best = p
		if best != null:
			s.lonely_phase = &"chase"
			s.lonely_target = best.id
			s.lonely_lost = 0.0
			s.replan_in = 0.0
			s.path = []
			events.append({"type": "chaseStarted", "t": t, "playerId": best.id, "at": s.body, "yaw": s.yaw})
	if s.lonely_phase == &"chase":
		var target := _person(people, s.lonely_target)
		if _catch_range(s, target):
			_start_wind_up(s, target, events)
		else:
			var one: Array[Entity.PlayerView] = [_view(target)]
			Entity._hunt(plan, s, one, dt, (SOLO_CHASE_SPEED if solo else CHASE_SPEED) if chase < 0.0 else chase, false, k, solids)
		_finish(prev, res, dt, k)
		return res

	# Approach or lurk.
	var goal := _person(people, s.target_id)
	if goal == null or not lonely.has(goal.id):
		goal = _nearest_prey(plan, s.body, people, lonely)
	if goal == null:
		s.lonely_phase = &"lurk"
		s.anim = &"idle"
		s.path = []
		_finish(prev, res, dt, k)
		return res
	s.lonely_phase = &"approach"
	if s.target_id == null or str(s.target_id) != goal.id:
		s.target_id = goal.id
		s.replan_in = 0.0
		s.path = []
	var view: Array[Entity.PlayerView] = [_view(goal)]
	Entity._hunt(plan, s, view, dt, APPROACH_SPEED, false, k, solids)
	_finish(prev, res, dt, k)
	return res

## The stapler (sim/entity.gd), after the tick's rules.
static func _finish(prev: Entity.OrderlyState, res: Entity.StepResult, dt: float, k: Entity.BodySettings) -> void:
	if k.clicks():
		Entity._stapler(prev, res, dt, k)

static func _wake(s: Entity.OrderlyState, events: Array[Dictionary]) -> void:
	s.mode = &"hunting"
	s.replan_in = 0.0
	s.lonely_phase = &"lurk"
	events.append({"type": "startedHunting", "t": s.t})

static func _walk_steps(plan: Floor.FloorPlan, from: Move.Body, p: Person) -> int:
	var d := Entity._distances_cached(plan, Move.cell_of(plan, from))[Floor.pos_index(plan, Move.cell_of(plan, p.body))]
	return d if d >= 0 else 1 << 30

## The player it may go for nearest by walking (ties: straight line, then list order); only those in `only` (a
## {id: true} Dictionary) unless it is null.
static func _nearest_prey(plan: Floor.FloorPlan, from: Move.Body, people: Array[Person], only: Variant) -> Person:
	var best: Person = null
	var best_steps := 1 << 30
	var best_line := INF
	for p in people:
		if not p.prey or (only != null and not (only as Dictionary).has(p.id)):
			continue
		var steps := _walk_steps(plan, from, p)
		if steps >= 1 << 30:
			continue
		var line := M.hypot2(p.body.x - from.x, p.body.z - from.z)
		if best == null or steps < best_steps or (steps == best_steps and line < best_line):
			best = p
			best_steps = steps
			best_line = line
	return best

static func _catch_range(s: Entity.OrderlyState, p: Person) -> bool:
	return p != null and p.body.level == s.body.level and M.hypot2(p.body.x - s.body.x, p.body.z - s.body.z) <= Entity.CATCH_RANGE

static func _start_wind_up(s: Entity.OrderlyState, p: Person, events: Array[Dictionary]) -> void:
	s.mode = &"windUp"
	s.wind_up_target = p.id
	s.wind_up_left = Entity.WIND_UP_TIME
	s.anim = &"reach"
	s.anim_time = 0.0
	events.append({"type": "windUp", "t": s.t, "playerId": p.id})

static func _end_chase(s: Entity.OrderlyState, events: Array[Dictionary], why: String) -> void:
	events.append({"type": "chaseEnded", "t": s.t, "playerId": str(s.lonely_target) if s.lonely_target != null else "", "why": why})
	s.lonely_lost = 0.0

## The wind-up: cancelled (and a break-off) the tick its target is not lonely; the catch when its time is up
## and the host's catch hold is off.
static func _wind_up(plan: Floor.FloorPlan, prev: Entity.OrderlyState, s: Entity.OrderlyState, people: Array[Person], lonely: Dictionary, events: Array[Dictionary]) -> void:
	var target := _person(people, s.wind_up_target)
	var id := str(s.wind_up_target) if s.wind_up_target != null else ""
	var reach := target != null and target.prey and target.body.level == s.body.level \
		and M.hypot2(target.body.x - s.body.x, target.body.z - s.body.z) <= Entity.REACH_RANGE
	if target == null or not lonely.has(target.id) or not reach:
		events.append({"type": "windUpCancelled", "t": s.t, "playerId": id})
		s.mode = &"hunting"
		s.wind_up_target = null
		s.wind_up_left = 0.0
		s.anim = &"idle"
		if target != null and target.prey and not lonely.has(target.id):
			_end_chase(s, events, "company")
			_break_off(plan, s, people, target.id, Entity.kind_of(s))
		return
	s.yaw = Entity._turn_toward(s.yaw, Entity.yaw_toward(target.body.x - s.body.x, target.body.z - s.body.z), Entity.TURN_RATE * (s.t - prev.t))
	s.anim = &"reach"
	s.wind_up_left = maxf(0.0, s.wind_up_left - (s.t - prev.t))
	if s.wind_up_left > EPS or Entity.held_by_grace(prev):
		return
	events.append({"type": "caught", "t": s.t, "playerId": target.id})
	_end_chase(s, events, "caught")
	s.mode = &"dormant"
	s.dormant_left = Entity.DORMANT_TIME
	s.wind_up_target = null
	s.wind_up_left = 0.0
	s.path = []
	s.target_id = null
	s.anim = &"idle"
	s.lonely_phase = &""
	s.lonely_target = null

# ---------------------------------------------------------------------------------------------
# Breaking off.

## Out of every person's line, standing on cell `c` (its centre at HIDE_HEIGHTS).
static func _hidden_cell(plan: Floor.FloorPlan, people: Array[Person], c: Floor.Pos) -> bool:
	var b := Move.body_at_cell(plan, c)
	for p in people:
		var e := Sight.eye_point(p.body, p.eye)
		for h in HIDE_HEIGHTS:
			if Sight.has_line_of_sight(plan, e, Sight.Point3.make(b.x, b.y + h, b.z, b.level)):
				return false
	return true

## Starts a break-off from player `left`: the wind-up and the chase over, a route to the nearest cell out of
## every line that is no nearer `left` than it stands now (any such cell if none is; none: it stands).
static func _break_off(plan: Floor.FloorPlan, s: Entity.OrderlyState, people: Array[Person], left: String, k: Entity.BodySettings) -> void:
	s.mode = &"hunting"
	s.lonely_phase = &"breakoff"
	s.lonely_left = left
	s.lonely_target = null
	s.lonely_lost = 0.0
	s.wind_up_target = null
	s.wind_up_left = 0.0
	s.target_id = left
	s.path = []
	s.path_next = 0
	var here := Move.cell_of(plan, s.body)
	var from := _person(people, left)
	var cs := float(plan.cell_size)
	var start_d := M.hypot2(from.body.x - s.body.x, from.body.z - s.body.z) if from != null else 0.0
	var dist := Entity._distances_cached(plan, here)
	var cells: Array[int] = []
	for i in dist.size():
		if dist[i] >= 0 and dist[i] <= HIDE_SEARCH_STEPS:
			cells.append(i)
	cells.sort_custom(func(a: int, b: int) -> bool: return dist[a] < dist[b] or (dist[a] == dist[b] and a < b))
	# The first cell that passes relocation's own out-of-view test (sim/relocate.gd, so it can leave from there),
	# trying at most FULL_TRIES of the cells that pass the quick test; else the first that passes the quick test.
	var eyes: Array[Relocate.Eye] = []
	for p in people:
		eyes.append(Relocate.Eye.make(p.id, p.body, p.eye, null, p.prey))
	var pick: Floor.Pos = null
	var quick: Floor.Pos = null
	var fallback: Floor.Pos = null
	var tries := 0
	for i in cells:
		var c := Floor.pos_from_index(plan, i)
		if not Floor.is_walkable(plan, c.level, c.x, c.y):
			continue
		var away := from == null or c.level != from.body.level \
			or M.hypot2((c.x + 0.5) * cs - from.body.x, (c.y + 0.5) * cs - from.body.z) >= start_d - EPS
		if not away and fallback != null:
			continue
		if not _hidden_cell(plan, people, c):
			continue
		if not away:
			fallback = c
			continue
		if quick == null:
			quick = c
		tries += 1
		if Relocate.out_of_view(plan, eyes, Move.body_at_cell(plan, c), k):
			pick = c
			break
		if tries >= FULL_TRIES:
			break
	if pick == null:
		pick = quick if quick != null else fallback
	if pick != null and not (pick.level == here.level and pick.x == here.x and pick.y == here.y):
		s.path = Floor.find_path(plan, here, pick)
		s.path_next = 1 if s.path.size() > 1 else 0

## One tick of a break-off: walking off along its route at BREAK_OFF_SPEED, then standing.
static func _step_break_off(plan: Floor.FloorPlan, s: Entity.OrderlyState, people: Array[Person], dt: float, k: Entity.BodySettings, relocating: bool, solids: Move.Solids) -> void:
	s.lonely_lost += dt
	var before := s.body
	if not s.path.is_empty() and s.path_next < s.path.size():
		if solids != null:
			Entity._resident_walk(plan, s, Move.body_at_cell(plan, s.path.back()), BREAK_OFF_SPEED * dt, k.radius, solids)
		else:
			var walk := Follow.PathWalk.make(s.path, s.path_next)
			s.body = Follow.step_path_walk(plan, walk, before, BREAK_OFF_SPEED * dt, k.radius)
			s.path_next = walk.next
	var mx := s.body.x - before.x
	var mz := s.body.z - before.z
	var moved := M.hypot2(mx, mz)
	s.moving = moved > 1e-9
	s.speed = moved / maxf(dt, EPS)
	if s.moving:
		s.yaw = Entity._turn_toward(s.yaw, Entity.yaw_toward(mx, mz), Entity.TURN_RATE * dt)
		s.anim = &"walk"
	else:
		s.anim = &"idle"
		s.path = []
		if not relocating or s.lonely_lost >= BREAK_OFF_GIVE_UP - EPS:
			s.lonely_phase = &"lurk"
			s.lonely_lost = 0.0
