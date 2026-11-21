# OR2, the Orderly fix (the owner's 20 Nov playtest of the Clinic; sim/entity.gd "The Orderly fix", sim/orderly_fix.gd,
# sim/run.gd with_orderly_fix, net/host_rules.gd orderly_fix, client/air_sound.gd). Proved:
#   1. A walker is caught: a player walking steadily away (3 m/s, never looking) down a long route from a chasing
#      Orderly is caught within CATCH_WITHIN seconds with the fix on; with it off they are not (the old swipe that
#      stands still and is walked out of, with its cancelled reaches). A sprinter (5 m/s) for a whole stamina tank
#      is not caught with it on; a walker who turns to look as the reach starts cancels it the same tick and is
#      never caught while looking, and the Orderly does not move while held. With furniture (the residents' walk
#      round solids) and without.
#   2. The trolley through the air (client only; headless, so these are the computed numbers, never a listen): on
#      the same storey with a clear view, the air's gain is the rules' own; behind a wall where the walk is long, much
#      lower than the rules' straight line; on the other storey at most CROSS_STOREY of it, and small on average; a
#      place with no walk to it, silent. The trolley's level falls at least 15 dB from beside you to 30 m (it fell 3).
#   3. Two Orderlies and two players whose nearest is the same: with the fix the second chases the other player, off
#      both chase the same; with one player both chase them. Chasing the same player, the second's route
#      (flank_path) shares fewer cells with the first's than the plain shortest route on many floors, and never more;
#      and stepping, the second's route is that one.
#   4. The starts (net/host_rules.gd prepare, depth 2 and 3, two Orderlies): in the dirty part (OrderlyFix.dirt at
#      least DIRTY_FROM in 100), never the same cell, at least SECOND_APART_MIN apart by walking, the same twice for a
#      seed, and over the seeds many different cells. Off, the first starts at plan.entity_start as always.
#   5. Off changes nothing: a bot run made without the new parameter and one made with it false are the same on
#      every tick (and with it true they differ, so the check can fail).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Follow = preload("res://sim/follow.gd")
const Furniture = preload("res://sim/furniture.gd")
const Stamina = preload("res://sim/stamina.gd")
const Settings = preload("res://sim/settings.gd")
const OrderlyFix = preload("res://sim/orderly_fix.gd")
const M = preload("res://sim/jsmath.gd")
const Bot = preload("res://sim/bot.gd")
const Plans = preload("res://tests/plans.gd")
const HostRules = preload("res://net/host_rules.gd")
const PropO2 = preload("res://tests/prop_second_orderly.gd")
const AirSound = preload("res://client/air_sound.gd")
const Sfx = preload("res://client/sfx.gd")

const DT := 0.05
const EPS := 1e-9
## The game's hunt speed (paced).
const HUNT := 3.8
## A walker is caught within this many seconds.
const CATCH_WITHIN := 12.0
## The walker starts this many cells ahead of the Orderly.
const AHEAD := 3

# ---------------------------------------------------------------------------------------------
# Helpers.

## A long route on `plan`: from the Orderly's start to the cell farthest from it by walking.
static func long_route(plan: Floor.FloorPlan) -> Array[Floor.Pos]:
	var from := plan.entity_start
	var dist := Floor.distances_from(plan, from)
	var best := -1
	var far := -1
	for i in dist.size():
		if dist[i] > far:
			far = dist[i]
			best = i
	return Floor.find_path(plan, from, Floor.pos_from_index(plan, best))

static func hunter(plan: Floor.FloorPlan, at: Floor.Pos) -> Entity.OrderlyState:
	var o := Entity.create_orderly(plan)
	o.body = Move.body_at_cell(plan, at)
	o.mode = &"hunting"
	o.replan_in = 0.0
	return o

static func view(id: String, body: Move.Body, yaw: float, blind: bool) -> Entity.PlayerView:
	return Entity.PlayerView.make(id, body, Bot.BOT_EYE, yaw, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true, blind)

## A chase down `route`: the Orderly at its start hunting, the player AHEAD cells on walking it at `speed` for at most
## `limit` seconds, never looking back (blind), unless `look`: then they stop and face it the tick its reach starts.
## Returns {caught: seconds or -1, reaches, cancels, held_moved (a held tick it moved on), walked (metres)}.
static func chase(plan: Floor.FloorPlan, route: Array[Floor.Pos], speed: float, limit: float, reach: float, solids: Move.Solids, look := false) -> Dictionary:
	var o := hunter(plan, route[0])
	var body := Move.body_at_cell(plan, route[AHEAD])
	var walk := Follow.PathWalk.make(route, AHEAD + 1)
	var out := {"caught": -1.0, "reaches": 0, "cancels": 0, "held_moved": false, "walked": 0.0}
	var looking := false
	var t := 0.0
	while t < limit - EPS:
		t += DT
		if not looking:
			var nb := Follow.step_path_walk(plan, walk, body, speed * DT, Bot.BOT_RADIUS, solids)
			out["walked"] = float(out["walked"]) + M.hypot2(nb.x - body.x, nb.z - body.z)
			body = nb
		var yaw := Entity.yaw_toward(o.body.x - body.x, o.body.z - body.z) if looking else Entity.yaw_toward(-(o.body.x - body.x), -(o.body.z - body.z))
		var players: Array[Entity.PlayerView] = [view("p0", body, yaw, not looking)]
		var r := Entity.step_entity(plan, o, players, DT, HUNT, true, 1, solids, false, reach)
		if r.state.held and (r.state.body.x != o.body.x or r.state.body.z != o.body.z):
			out["held_moved"] = true
		o = r.state
		for e in r.events:
			match str(e["type"]):
				"windUp":
					out["reaches"] = int(out["reaches"]) + 1
					if look:
						looking = true
				"windUpCancelled":
					out["cancels"] = int(out["cancels"]) + 1
				"caught":
					out["caught"] = t
		if float(out["caught"]) >= 0.0:
			break
	return out

## Clinic floors with a route of at least `cells` cells.
static func routes(quick: bool, cells: int) -> Array:
	var out: Array = []
	for depth: int in [1, 2, 3]:
		for i in (2 if quick else 10):
			var plan := Plans.plan("seed-%d" % i, depth)
			var route := long_route(plan)
			if route.size() >= cells:
				out.append([plan, route])
	return out

# ---------------------------------------------------------------------------------------------
# 1. A walker is caught; a sprinter and a watcher are not.

func test_a_walker_is_caught_and_a_sprinter_and_a_watcher_are_not(t: T) -> void:
	var tried := 0
	var lines: Array[String] = []
	var tank := Settings.today(&"stamina.tank")
	for pr: Array in routes(t.quick, 36):
		var plan: Floor.FloorPlan = pr[0]
		var route: Array[Floor.Pos] = []
		route.assign(pr[1])
		var furn := Furniture.solids_of(plan, true)
		for solids: Move.Solids in [null, furn if furn != null and furn.count() > 0 else null]:
			var tag := "%s/%d%s" % [plan.seed, plan.depth, " furniture" if solids != null else ""]
			tried += 1
			var on := chase(plan, route, Stamina.WALK_SPEED, CATCH_WITHIN, 1.0, solids)
			t.check(float(on["caught"]) >= 0.0, "%s: a walker walking away is caught within %.0f s with the fix (%s)" % [tag, CATCH_WITHIN, str(on)])
			var off := chase(plan, route, Stamina.WALK_SPEED, CATCH_WITHIN, 0.0, solids)
			t.check(float(off["caught"]) < 0.0 and int(off["cancels"]) >= 1, "%s: off, the walker walks out of its standing swipe (%s)" % [tag, str(off)])
			var sprint := chase(plan, route, Stamina.SPRINT_SPEED, tank, 1.0, solids)
			t.check(float(sprint["caught"]) < 0.0, "%s: a sprinter for a whole tank (%.0f s) gets away (%s)" % [tag, tank, str(sprint)])
			var watch := chase(plan, route, Stamina.WALK_SPEED, CATCH_WITHIN, 1.0, solids, true)
			t.check(float(watch["caught"]) < 0.0 and int(watch["reaches"]) >= 1 and int(watch["cancels"]) >= 1 and not bool(watch["held_moved"]),
				"%s: turning to look as the reach starts cancels it, and it never moves while held (%s)" % [tag, str(watch)])
			lines.append("%s caught at %.2f s" % [tag, float(on["caught"])])
	t.check(tried >= 4, "enough long routes (%d)" % tried)
	t.note("%d chases; %s" % [tried, ", ".join(lines.slice(0, 6))])

# ---------------------------------------------------------------------------------------------
# 2. The trolley through the air (computed numbers only: nobody listens in a headless test).

static func _moving_at(plan: Floor.FloorPlan, at: Floor.Pos) -> Entity.OrderlyState:
	var o := Entity.create_orderly(plan)
	o.body = Move.body_at_cell(plan, at)
	o.moving = true
	return o

func test_the_trolley_is_heard_through_the_air_not_through_walls_and_floors(t: T) -> void:
	var cs := 2.0
	var open_pairs := 0
	var wall_pairs := 0
	var storey_pairs := 0
	var storey_sum := 0.0
	var silent := 0
	for i in (4 if t.quick else 10):
		var plan := Plans.plan("seed-%d" % i, 2)
		var cells: Array[Floor.Pos] = []
		for idx in plan.width * plan.height * 2:
			var p := Floor.pos_from_index(plan, idx)
			if Floor.is_walkable(plan, p.level, p.x, p.y) and (p.x + p.y * 3 + i) % 7 == 0:
				cells.append(p)
		for a in cells.size():
			var ear := Move.body_at_cell(plan, cells[a])
			for b in cells.size():
				if a == b:
					continue
				var src := _moving_at(plan, cells[b])
				var line := M.hypot2(ear.x - src.body.x, ear.z - src.body.z)
				if line > 14.0:
					continue
				var straight := Entity.audibility(plan, src, ear, Bot.BOT_EYE)
				var air := AirSound.audibility(plan, src, ear, Bot.BOT_EYE)
				t.check(air.gain <= straight.gain + EPS, "%s: the air is never louder than the rules (%.3f > %.3f)" % [plan.seed, air.gain, straight.gain])
				var walk := AirSound.air_metres(plan, ear, src.body)
				if walk < 0.0:
					silent += 1
					t.check(air.gain == 0.0, "%s: no walk to it, silent" % plan.seed)
				elif ear.level != src.body.level:
					storey_pairs += 1
					storey_sum += air.gain
					t.check(air.gain <= AirSound.CROSS_STOREY * straight.gain + EPS, "%s: the other storey keeps at most %.2f (%.3f of %.3f)" % [plan.seed, AirSound.CROSS_STOREY, air.gain, straight.gain])
				elif not straight.muffled and walk <= line + cs * 1.5:
					open_pairs += 1
					t.check(air.gain >= straight.gain * 0.6, "%s: in the open the air is the rules' (%.3f of %.3f)" % [plan.seed, air.gain, straight.gain])
				elif walk >= line + 16.0:
					wall_pairs += 1
					t.check(air.gain <= straight.gain * 0.5, "%s: behind a wall with a long walk it is much quieter (%.3f of %.3f, walk %.0f m, line %.0f m)" % [plan.seed, air.gain, straight.gain, walk, line])
	t.check(open_pairs > 20 and wall_pairs > 5 and storey_pairs > 5, "enough pairs: open %d, behind walls %d, other storey %d" % [open_pairs, wall_pairs, storey_pairs])
	t.check(storey_pairs == 0 or storey_sum / storey_pairs < 0.08, "the other storey is quiet on average (%.3f)" % (storey_sum / maxf(1.0, storey_pairs)))
	var near := Sfx.trolley_db(1.0, false)
	var at30 := Sfx.trolley_db(M.pow_js(1.0 - 30.0 / Entity.HEAR_RANGE, 2.0), false)
	t.check(near - at30 >= 15.0, "the trolley falls %.1f dB from beside you to 30 m (at least 15)" % (near - at30))
	t.note("pairs: open %d, behind walls %d, other storey %d (mean gain %.3f), no walk %d; trolley %.1f dB near, %.1f at 30 m" % [open_pairs, wall_pairs, storey_pairs, storey_sum / maxf(1.0, storey_pairs), silent, near, at30])

# ---------------------------------------------------------------------------------------------
# 3. Two Orderlies: different players, their own ways.

## One tick for both: the first as always, the second given the first (fix) or not.
static func both(plan: Floor.FloorPlan, a: Entity.OrderlyState, b: Entity.OrderlyState, players: Array[Entity.PlayerView], fix: bool) -> Array:
	var ra := Entity.step_entity(plan, a, players, DT, HUNT, true, 1, null, false, 1.0 if fix else 0.0)
	var rb := Entity.step_entity(plan, b, players, DT, HUNT, true, 1, null, false, 1.0 if fix else 0.0, ra.state if fix else null)
	return [ra.state, rb.state]

static func _shared(plan: Floor.FloorPlan, mine: Array[Floor.Pos], theirs: Array[Floor.Pos]) -> int:
	var seen := {}
	for i in maxi(0, theirs.size() - Entity.FLANK_FREE):
		seen[Floor.pos_index(plan, theirs[i])] = true
	var n := 0
	for p in mine:
		if seen.has(Floor.pos_index(plan, p)):
			n += 1
	return n

func test_two_orderlies_chase_different_players_by_their_own_ways(t: T) -> void:
	var configs := 0
	var fewer := 0
	var more := 0
	for pr: Array in routes(t.quick, 24):
		var plan: Floor.FloorPlan = pr[0]
		var route: Array[Floor.Pos] = []
		route.assign(pr[1])
		configs += 1
		var tag := "%s/%d" % [plan.seed, plan.depth]
		var near_body := Move.body_at_cell(plan, route[8])
		var far_body := Move.body_at_cell(plan, route[20])
		var two: Array[Entity.PlayerView] = [view("p1", near_body, 0.0, true), view("p2", far_body, 0.0, true)]
		var one: Array[Entity.PlayerView] = [view("p1", near_body, 0.0, true)]
		var a := hunter(plan, route[0])
		var b := hunter(plan, route[2])
		var on: Array = both(plan, a, b, two, true)
		t.check(str(on[0].target_id) == "p1" and str(on[1].target_id) == "p2", "%s: with the fix the second chases the other player (%s, %s)" % [tag, str(on[0].target_id), str(on[1].target_id)])
		var off: Array = both(plan, a, b, two, false)
		t.check(str(off[0].target_id) == "p1" and str(off[1].target_id) == "p1", "%s: off, both chase the nearest (%s, %s)" % [tag, str(off[0].target_id), str(off[1].target_id)])
		var alone: Array = both(plan, a, b, one, true)
		t.check(str(alone[0].target_id) == "p1" and str(alone[1].target_id) == "p1", "%s: with one player both chase them" % tag)
		# Its own way: the second's route is flank_path, and it shares no more of the first's route than the plain one.
		var target := Move.cell_of(plan, near_body)
		var flank := Entity.flank_path(plan, route[2], target, route[0])
		var plain := Floor.find_path(plan, route[2], target)
		var theirs := Floor.find_path(plan, route[0], target)
		t.check(not flank.is_empty() and Floor.pos_index(plan, flank[0]) == Floor.pos_index(plan, route[2]) and Floor.pos_index(plan, flank[flank.size() - 1]) == Floor.pos_index(plan, target), "%s: the flank route runs from it to the target" % tag)
		t.check(alone[1].path.size() == flank.size() and Floor.pos_index(plan, alone[1].path[mini(3, flank.size() - 1)]) == Floor.pos_index(plan, flank[mini(3, flank.size() - 1)]), "%s: stepping, the second walks its own route" % tag)
		var sf := _shared(plan, flank, theirs)
		var sp := _shared(plan, plain, theirs)
		if sf < sp:
			fewer += 1
		elif sf > sp:
			more += 1
		# Wider: from far apart on the floor, to a player at the far end.
		var far_target := route[route.size() - 1]
		var mid := route[route.size() / 2]
		var f2 := Entity.flank_path(plan, mid, far_target, route[0])
		var p2 := Floor.find_path(plan, mid, far_target)
		var t2 := Floor.find_path(plan, route[0], far_target)
		var sf2 := _shared(plan, f2, t2)
		var sp2 := _shared(plan, p2, t2)
		if sf2 < sp2:
			fewer += 1
		elif sf2 > sp2:
			more += 1
	t.check(configs >= 4, "enough floors (%d)" % configs)
	t.eq(more, 0, "the second's own route never shares more of the first's than the plain route")
	t.check(fewer * 3 >= configs, "the second takes another way on many floors (%d of %d pairs)" % [fewer, configs * 2])
	t.note("%d floors, the second's way shares fewer cells with the first's in %d of %d pairs" % [configs, fewer, configs * 2])

# ---------------------------------------------------------------------------------------------
# 4. Where they start.

## The rules as the game's rooms make them (prop_second_orderly's), the second Orderly on, and the fix as asked.
static func rules(depth: int, fix: bool) -> HostRules:
	return HostRules.new(true, depth, [], false, false, true, true, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, true, false, false, false, false, false, false, false, fix)

func test_they_start_in_the_dirty_part_apart_and_by_the_seed(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	var firsts := {}
	var n := 0
	for depth: int in [2, 3]:
		for i in (5 if t.quick else 12):
			var seed := "start-%d" % i
			var s: Run.RunState = rules(depth, true).prepare(Run.create_run(seed, ids))
			var tag := "%s/%d" % [seed, depth]
			t.check(s.orderly_fix and s.orderly2 != null, "%s: the fix is on and there are two" % tag)
			if s.orderly2 == null:
				continue
			n += 1
			var c1 := Move.cell_of(s.plan, s.orderly.body)
			var c2 := Move.cell_of(s.plan, s.orderly2.body)
			var d1 := OrderlyFix.dirt(s.plan, c1)
			var d2 := OrderlyFix.dirt(s.plan, c2)
			t.check(d1 >= OrderlyFix.DIRTY_FROM / 100.0 - EPS and d2 >= OrderlyFix.DIRTY_FROM / 100.0 - EPS, "%s: both start in the dirty part (%.2f, %.2f)" % [tag, d1, d2])
			var apart := Floor.distances_from(s.plan, c1)[Floor.pos_index(s.plan, c2)]
			t.check(apart >= 0 and float(apart) * s.plan.cell_size >= OrderlyFix.SECOND_APART_MIN - EPS, "%s: %d cells apart by walking" % [tag, apart])
			t.check(s.orderly.mode == &"waiting" and s.orderly2.mode == &"waiting", "%s: both wait at their starts" % tag)
			var again: Run.RunState = rules(depth, true).prepare(Run.create_run(seed, ids))
			t.check(again.orderly.body.x == s.orderly.body.x and again.orderly.body.z == s.orderly.body.z and again.orderly2.body.x == s.orderly2.body.x and again.orderly2.body.z == s.orderly2.body.z, "%s: the same seed, the same starts" % tag)
			firsts["%d,%d,%d" % [c1.level, c1.x, c1.y]] = true
			var off: Run.RunState = rules(depth, false).prepare(Run.create_run(seed, ids))
			var oc := Move.cell_of(off.plan, off.orderly.body)
			t.check(not off.orderly_fix and Floor.pos_index(off.plan, oc) == Floor.pos_index(off.plan, off.plan.entity_start), "%s: off, the first starts where it always did" % tag)
	t.check(n >= 6, "enough floors (%d)" % n)
	t.check(firsts.size() * 4 >= n * 3, "different seeds, different starts (%d cells for %d floors)" % [firsts.size(), n])
	t.note("%d floors, %d different first starts" % [n, firsts.size()])

# ---------------------------------------------------------------------------------------------
# 5. Off changes nothing.

func _play(rules_of: Callable, seed: String, ticks: int) -> Array[String]:
	var ids: Array[String] = ["p0", "p1", "p2"]
	var r: HostRules = rules_of.call()
	var s: Run.RunState = r.prepare(Run.create_run(seed, ids))
	var bots: Array[Bot.Bot] = []
	for id in ids:
		bots.append(Bot.create_bot(s.plan, id, "%s:%s" % [seed, id], 0.5))
	var out: Array[String] = []
	for k in ticks:
		var step := r.step(s, PropO2.wander_inputs(s, bots, k), DT)
		s = step.state
		out.append(PropO2.digest(s, step.events))
	return out

func test_off_changes_nothing(t: T) -> void:
	var ticks := 400 if t.quick else 1600
	for seed: String in ["fix-off-1", "fix-off-2"]:
		var before := _play(func() -> HostRules: return PropO2.rules(2, true), seed, ticks)
		var off := _play(func() -> HostRules: return rules(2, false), seed, ticks)
		var on := _play(func() -> HostRules: return rules(2, true), seed, ticks)
		var same := before.size() == off.size()
		var first := -1
		for k in mini(before.size(), off.size()):
			if before[k] != off[k]:
				same = false
				first = k
				break
		t.check(same, "%s: off, every tick is as before the fix (first difference at tick %d)" % [seed, first])
		t.check(on != before, "%s: on, the run differs (the check can fail)" % seed)
