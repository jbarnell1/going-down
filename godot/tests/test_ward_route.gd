# PL3: "A player who lowers a bridge must always have a walkable way back to the lift." In the two-player run
# (tools/play_late.mjs, seed late-1, floor 6, Ward seed 183025961) Ann lowered the winch bridge at house 2 and the
# tool's route back to the lift (main.gd `wardroute`) answered "no route" for the whole wait. Checked here:
#   - the game does not strand her: from her exact spot, bridge lowered, every door open, the Ward's own walk model
#     (sim/ward/state.gd walk, the one the screen walks with and the host checks every step against) reaches the
#     lift's mouth, with the lift away and while it boards;
#   - the tool's route (client/ward/route.gd) finds that way well inside the search the test channel allows: the
#     plain breadth-first search it replaces needed some 6500 spots, about 13 s, over its 12 s cap;
#   - every step of the route is one the walk model takes (each waypoint is where a 0.3 m push from the one before
#     lands).
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Route = preload("res://client/ward/route.gd")
const Reach = preload("res://tests/prop_ward_reach.gd")

const SEED := 183025961
## Ann's feet after the winch (her screen's body in the run's log).
const ANN := Vector3(-0.839090466499329, 0.229150623083115, 15.2903966903687)
## Spots the route may search: a fifth of the 6500 the old search needed.
const BUDGET := 1300

static func _ward(phase: StringName) -> Ward:
	var w := Ward.new(SEED)
	w.bridge_lowered = true
	w.phase = phase
	for i in w.houses.size():
		w.requested_doors[i] = true
	return w

## Where play_late.mjs sends her: beside the lift, in the parlour.
static func _goal(w: Ward) -> Vector2:
	var door := w.lift_door()
	return Vector2(door.x - 0.3, door.z + 2.2)

func test_the_game_has_a_way_back_from_annes_spot(t: T) -> void:
	for phase: StringName in [&"away", &"boarding"]:
		var w := _ward(phase)
		t.check(w.walk_clear(ANN, ANN), "%s: her spot is one the walk model stands on" % phase)
		var g := Reach._grid(w)
		var back := Reach._reach(w, ANN, g.lo)
		var mouth := w.lift_door() + Vector3(0, 0, 0.5)
		var near := INF
		for k: Vector3i in back:
			near = minf(near, (back[k] as Vector3).distance_to(mouth))
		t.check(near < Reach.CELL, "%s: from her spot the walk model reaches the lift's mouth (nearest %.2f m)" % [phase, near])

func test_the_tools_route_finds_it_within_its_search(t: T) -> void:
	for phase: StringName in [&"away", &"boarding"]:
		var w := _ward(phase)
		var stats := {}
		var route := Route.find(w, ANN, _goal(w), 0.45, BUDGET, 0, stats)
		t.check(not route.is_empty() and int(stats.get("expanded", 0)) <= BUDGET,
			"%s: a route back to the lift within %d spots searched (%d searched, %d waypoints)" % [phase, BUDGET, int(stats.get("expanded", -1)), route.size()])
		if route.is_empty():
			continue
		t.check((route[0] as Vector3).is_equal_approx(ANN) and Vector2(route[-1].x, route[-1].z).distance_to(_goal(w)) < 0.45, "%s: from her feet to within 0.45 m of the goal" % phase)
		var bad := -1
		for i in range(1, route.size()):
			var a: Vector3 = route[i - 1]
			var b: Vector3 = route[i]
			# One of the eight 0.3 m pushes the search makes lands there (a push into a rail slides along it).
			var lands := false
			for d in 8:
				lands = lands or w.walk(a, Vector2.from_angle(d * PI / 4.0) * Route.STEP).distance_to(b) < 0.001
			if not lands:
				bad = i
				break
		t.check(bad < 0, "%s: every step of the route is one the walk model takes (first bad step %d)" % [phase, bad])

func test_no_route_when_there_is_none(t: T) -> void:
	# A goal off every deck: the search ends empty (within its budget) rather than inventing a way.
	var w := _ward(&"away")
	var stats := {}
	var route := Route.find(w, ANN, Vector2(200.0, 200.0), 0.45, 300, 0, stats)
	t.check(route.is_empty() and int(stats.get("expanded", 0)) <= 300, "an unreachable goal gives no route (%d searched)" % int(stats.get("expanded", -1)))
