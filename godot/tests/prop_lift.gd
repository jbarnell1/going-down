# The car (North Star C5 and C6, owner decision V9): "about four metres square, so a full crew fits and
# has room to change sides before the bell", decided as 4 m by 4 m (two map squares each way) with a
# 1.8 m door, so BANK and DOWN are each 2 m wide. Checked everywhere the car is defined:
#   - the rules (sim/run.gd car_geometry): the size, the door centred on the landing cell, the two halves
#     and who votes where, a full crew of eight standing in it and each able to cross to the other half;
#   - the floor plans (Clinic, Annex, Prison): every cell the car's floor covers is void on both levels
#     (no walkable cell, room or door: the shaft and the lobby are kept clear), the landing is walkable,
#     and no walkable cell lies inside the car;
#   - the client (client/lift.gd, client/level.gd): the lift as DRAWN (measured from its meshes) is the
#     rules' car, its floor paint splits it into the same two halves, its doorway and door panels are the
#     rules' door, the landing wall's opening is the rules' door, the call button is within the call
#     reach and the hold button is where the client offers it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Prison = preload("res://sim/prison.gd")
const Floor = preload("res://sim/floor.gd")
const Landing = preload("res://sim/landing.gd")
const Move = preload("res://sim/move.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const PlayLink = preload("res://client/play_link.gd")
const LevelScript = preload("res://client/level.gd")
const LiftScript = preload("res://client/lift.gd")

## The decided car (V9), metres.
const WIDTH := 4.0
const DEPTH := 4.0
const DOOR := 1.8
## The drawn walls are this thick (lift.gd), so the drawn box is this much bigger on each side.
const WALL := 0.04
## Drawn sizes may differ from the rules' by this much (paint margins, wall faces).
const SLACK := 0.06

static func _plans(quick: bool) -> Array[Floor.FloorPlan]:
	var out: Array[Floor.FloorPlan] = []
	for depth: int in [1, 2, 3, 4, 5]:
		for i in (6 if quick else 40):
			out.append(Clinic.generate_clinic("seed-%d" % i, depth))
	for depth: int in [1, 3]:
		for i in (3 if quick else 12):
			out.append(Annex.generate_annex("seed-%d" % i, depth))
	out.append(Prison.prison_plan())
	return out

static func _tag(p: Floor.FloorPlan) -> String:
	return "%s %s d%d" % [p.place, p.seed, p.depth]

## Car-local (u into the car, v to the right walking in) of a world point.
static func _uv(c: Run.CarGeometry, x: float, z: float) -> Vector2:
	var l := Run.car_local(c, x, z)
	return Vector2(l[0], l[1])

## A rules rectangle in car-local u and v.
static func _rect_uv(c: Run.CarGeometry, r: Run.Rect) -> Rect2:
	var a := _uv(c, r.x0, r.z0)
	var b := _uv(c, r.x1, r.z1)
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	return Rect2(lo, Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) - lo)

static func _near(a: float, b: float, eps: float = 1e-9) -> bool:
	return absf(a - b) <= eps

func test_the_rules_car_is_four_metres_square_with_a_wide_door(t: T) -> void:
	t.eq(Run.CAR_WIDTH, WIDTH, "run.gd CAR_WIDTH")
	t.eq(Run.CAR_DEPTH, DEPTH, "run.gd CAR_DEPTH")
	t.eq(Run.CAR_DOOR_WIDTH, DOOR, "run.gd CAR_DOOR_WIDTH")
	var checked := 0
	for p in _plans(t.quick):
		var c := Run.car_geometry(p)
		var tag := _tag(p)
		checked += 1
		t.check(_near(c.width, WIDTH) and _near(c.depth, DEPTH) and _near(c.door_width, DOOR), "%s: car %s by %s, door %s" % [tag, c.width, c.depth, c.door_width])
		var all := _rect_uv(c, c.rect)
		var bank := _rect_uv(c, c.bank)
		var down := _rect_uv(c, c.down)
		t.check(_near(all.position.x, 0.0, 1e-6) and _near(all.size.x, DEPTH, 1e-6) and _near(all.position.y, -WIDTH / 2.0, 1e-6) and _near(all.size.y, WIDTH, 1e-6),
			"%s: the car's floor is not 4 by 4 from the doors: %s" % [tag, all])
		# BANK is the left half walking in, DOWN the right: each 2 m wide and the car's full depth.
		t.check(_near(bank.position.y, -WIDTH / 2.0, 1e-6) and _near(bank.size.y, WIDTH / 2.0, 1e-6) and _near(bank.size.x, DEPTH, 1e-6), "%s: BANK half %s" % [tag, bank])
		t.check(_near(down.position.y, 0.0, 1e-6) and _near(down.size.y, WIDTH / 2.0, 1e-6) and _near(down.size.x, DEPTH, 1e-6), "%s: DOWN half %s" % [tag, down])
		# The door is centred on the landing cell's wall, so half the doorway opens onto each half.
		var s := float(p.cell_size)
		var mid := _uv(c, (p.landing.x + 0.5) * s, (p.landing.y + 0.5) * s)
		t.check(_near(mid.y, 0.0, 1e-9) and _near(mid.x, -s / 2.0, 1e-9), "%s: the door is not centred on the landing cell (%s)" % [tag, mid])
		# Who stands where votes where, anywhere along the car.
		for u: float in [0.4, 2.0, 3.6]:
			t.eq(Run.car_side(c, Run.car_body(c, u, -1.9)), &"bank", "%s: u %s by the left wall" % [tag, u])
			t.eq(Run.car_side(c, Run.car_body(c, u, -0.05)), &"bank", "%s: u %s just left of the line" % [tag, u])
			t.eq(Run.car_side(c, Run.car_body(c, u, 0.05)), &"down", "%s: u %s just right of the line" % [tag, u])
			t.eq(Run.car_side(c, Run.car_body(c, u, 1.9)), &"down", "%s: u %s by the right wall" % [tag, u])
		t.eq(Run.car_side(c, Run.car_body(c, 4.2, 0.5)), null, "%s: behind the back wall" % tag)
		t.eq(Run.car_side(c, Run.car_body(c, 2.0, 2.2)), null, "%s: beyond a side wall" % tag)
	t.note("%d floors: the car is %s by %s m, door %s m, BANK and DOWN %s m wide each" % [checked, WIDTH, DEPTH, DOOR, WIDTH / 2.0])

## Eight players stand in the car at once (two by two along it, a metre either side of the middle line),
## and every one of them can walk straight across to the other half with the car's own walls.
func test_a_full_crew_fits_and_can_change_sides(t: T) -> void:
	var st := Run.create_run("seed-1", ["a", "b", "c", "d", "e", "f", "g", "h"] as Array[String])
	st = st.copy()
	st.phase = &"boarding"
	var c := st.car
	var r := 0.3
	var spots: Array[Vector2] = []
	for i in 8:
		spots.append(Vector2(0.6 + 0.9 * floorf(i / 2.0), -1.0 if i % 2 == 0 else 1.0))
	for i in spots.size():
		for j in range(i + 1, spots.size()):
			t.check(spots[i].distance_to(spots[j]) >= 2.0 * r, "spots %d and %d overlap" % [i, j])
	for sp in spots:
		var b := Run.car_body(c, sp.x, sp.y)
		t.check(Run.in_car(c, b), "spot %s is not in the car" % sp)
		var across := -2.0 * sp.y
		var moved := Run.move_in_run(st, b, c.right_x * across, c.right_z * across, r)
		var before: Variant = Run.car_side(c, b)
		var after: Variant = Run.car_side(c, moved)
		t.check(before != null and after != null and before != after, "from %s: %s -> %s" % [sp, before, after])
	# Each player's start spot is in the car, on a half, and no two overlap.
	for i in st.players.size():
		t.check(Run.car_side(c, st.players[i].body) != null, "player %d starts outside the car's halves" % i)

func test_the_car_space_is_clear_on_every_plan(t: T) -> void:
	var checked := 0
	var cells := 0
	for p in _plans(t.quick):
		var c := Run.car_geometry(p)
		var tag := _tag(p)
		checked += 1
		var s := float(p.cell_size)
		t.check(Floor.is_walkable(p, p.landing.level, p.landing.x, p.landing.y), "%s: the landing is not walkable" % tag)
		t.check(Landing.elevator_wall(p) != &"", "%s: the landing has no elevator wall" % tag)
		# Every cell the car's floor covers (shrunk a hair, so sharing an edge does not count).
		var x0 := floori((c.rect.x0 + 1e-6) / s)
		var x1 := floori((c.rect.x1 - 1e-6) / s)
		var z0 := floori((c.rect.z0 + 1e-6) / s)
		var z1 := floori((c.rect.z1 - 1e-6) / s)
		var bad := PackedStringArray()
		for y in range(z0, z1 + 1):
			for x in range(x0, x1 + 1):
				if not Floor.in_bounds(p, x, y):
					continue
				for level in 2:
					cells += 1
					var k := Floor.cell_at(p, level, x, y)
					if k != Floor.VOID or Floor.room_id_at(p, level, x, y) != -1:
						bad.append("L%d %d,%d is %s" % [level, x, y, k])
		for d in p.doors:
			for e: Vector2i in [Vector2i(d.ax, d.ay), Vector2i(d.bx, d.by)]:
				if e.x >= x0 and e.x <= x1 and e.y >= z0 and e.y <= z1:
					bad.append("a door at %s" % str(e))
		t.check(bad.is_empty(), "%s: the car's space is not clear: %s" % [tag, ", ".join(bad.slice(0, 4))])
		# No walkable cell's centre is inside the car.
		for y in p.height:
			for x in p.width:
				if Floor.is_walkable(p, c.level, x, y) and Run.in_car(c, Move.Body.make((x + 0.5) * s, (y + 0.5) * s, c.level, c.floor_y)):
					t.check(false, "%s: walkable cell L%d %d,%d is inside the car" % [tag, c.level, x, y])
	t.note("%d floors (Clinic, Annex, Prison): %d cells under or over the car, all void" % [checked, cells])

## The lift as drawn is the rules' car: measured from its meshes, not from its settings.
func test_the_drawn_lift_is_the_rules_car(t: T) -> void:
	var plans: Array[Floor.FloorPlan] = [Clinic.generate_clinic("seed-2", 1), Annex.generate_annex("seed-1", 3), Prison.prison_plan()]
	for p in plans:
		var c := Run.car_geometry(p)
		var tag := _tag(p)
		var lv: Node3D = LevelScript.new()
		lv.set("props_on", false)
		lv.call("build", PlanDump.dump(p, c), "lift-check")
		var lift: Node3D = LiftScript.new()
		lift.call("build", PlanDump.car_plain(c), lv.call("lift_left_wall"))
		var d: Dictionary = lift.call("drawn_car")
		var box: AABB = d["box"]
		var hw := c.width / 2.0
		t.check(_near(box.position.x, -hw - WALL, SLACK) and _near(box.position.x + box.size.x, hw + WALL, SLACK),
			"%s: the drawn car is %.2f m wide (x %.2f..%.2f), the rules' %.2f" % [tag, box.size.x, box.position.x, box.position.x + box.size.x, c.width])
		t.check(_near(box.position.z, -c.depth - WALL, SLACK), "%s: the drawn car is %.2f m deep, the rules' %.2f" % [tag, -box.position.z, c.depth])
		var bank: AABB = d["bank"]
		var down: AABB = d["down"]
		t.check(_near(bank.position.x, -hw, SLACK) and _near(bank.position.x + bank.size.x, 0.0, SLACK) and bank.size.z >= c.depth - 2.0 * SLACK,
			"%s: the BANK paint covers x %.2f..%.2f, %.2f deep; the rules' half is x %.2f..0, %.2f deep" % [tag, bank.position.x, bank.position.x + bank.size.x, bank.size.z, -hw, c.depth])
		t.check(_near(down.position.x, 0.0, SLACK) and _near(down.position.x + down.size.x, hw, SLACK) and down.size.z >= c.depth - 2.0 * SLACK,
			"%s: the DOWN paint covers x %.2f..%.2f, %.2f deep; the rules' half is x 0..%.2f, %.2f deep" % [tag, down.position.x, down.position.x + down.size.x, down.size.z, hw, c.depth])
		t.check(_near(float(d["doorway"]), c.door_width, 1e-3), "%s: the drawn doorway is %.3f m, the rules' door %.3f" % [tag, float(d["doorway"]), c.door_width])
		t.check(_near(float(d["panels"]), c.door_width, 1e-3), "%s: the door panels cover %.3f m shut, the rules' door %.3f" % [tag, float(d["panels"]), c.door_width])
		var call_at: Vector3 = lift.get("call_at")
		t.check(Vector2(call_at.x, call_at.z).length() <= Run.CALL_REACH - 0.3, "%s: the call button is drawn %.2f m from the door's centre, beyond the call reach" % [tag, Vector2(call_at.x, call_at.z).length()])
		lift.free()
		# The landing wall's opening for the lift.
		t.check(_near(float(lv.get("lift_half")) * 2.0, c.door_width, 1e-9), "%s: the landing wall's opening is %.2f m, the rules' door %.2f" % [tag, float(lv.get("lift_half")) * 2.0, c.door_width])
		lv.free()
	# The hold button: beside the doorway on the front wall, offered where it is drawn.
	var hb: Vector2 = LiftScript.HOLD_BUTTON
	t.check(hb.x > DOOR / 2.0 and hb.x < WIDTH / 2.0, "the hold button (v %.2f) is not on the front wall beside the doorway" % hb.x)
	t.eq(PlayLink.HOLD_BUTTON_V, hb.x, "the hold button the client offers is where it is drawn")
