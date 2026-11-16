# Floors against src/sim/clinic.ts and floor.ts: 40 complete plans field by field (cells, rooms,
# doors, stairs, landing, entity start, sightlines, side branches, the lift and its car, paths and
# distances), and the plan hash of the 800 floors the property tests use.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")
const Landing = preload("res://sim/landing.gd")
const Run = preload("res://sim/run.gd")

const CELL_CHAR := {&"void": "v", &"corridor": "c", &"room": "r", &"stair": "s", &"landing": "l", &"atriumOpen": "o"}

static func compact(p: Floor.FloorPlan) -> Dictionary:
	var cells: Array = []
	for level in 2:
		var s := PackedStringArray()
		for k: StringName in p.cells[level]:
			s.append(CELL_CHAR[k])
		cells.append("".join(s))
	var rooms: Array = []
	for r in p.rooms:
		rooms.append([r.id, r.level, String(r.kind), r.x, r.y, r.w, r.h, String(r.branch)])
	var doors: Array = []
	for d in p.doors:
		doors.append([d.level, d.ax, d.ay, d.bx, d.by])
	var stairs: Array = []
	for s in p.stairs:
		stairs.append([s.x, s.y, String(s.dir), s.length])
	var sl: Array = []
	for s in p.sightlines:
		sl.append([s.level, s.x1, s.y1, s.x2, s.y2, s.length])
	var room_at := func(d: Floor.Door, end: String) -> int:
		var x := d.ax if end == "a" else d.bx
		var y := d.ay if end == "a" else d.by
		for rr in p.rooms:
			if rr.level == d.level and x >= rr.x and x < rr.x + rr.w and y >= rr.y and y < rr.y + rr.h:
				return rr.id
		return -1
	var branches: Array = []
	for g in Floor.side_branches(p.rooms, p.doors, room_at):
		branches.append(Array(g))
	var dist := Floor.distances_from(p, p.landing)
	var sum := 0
	var mx := -1
	var reach := 0
	for d in dist:
		if d >= 0:
			sum += d
			reach += 1
			mx = maxi(mx, d)
	var path: Array = []
	for q in Floor.find_path(p, p.landing, p.entity_start):
		path.append([q.level, q.x, q.y])
	var ascii := (Floor.render_ascii(p, 0) + "|" + Floor.render_ascii(p, 1)).md5_text().substr(0, 8)
	return {
		"seed": p.seed, "depth": p.depth, "width": p.width, "height": p.height, "cellSize": p.cell_size, "place": String(p.place),
		"cells": cells, "rooms": rooms, "doors": doors, "stairs": stairs, "landing": Snap.pos(p.landing), "entityStart": Snap.pos(p.entity_start),
		"sightlines": sl, "hash": Floor.hash_plan(p), "sideBranches": branches, "elevatorWall": String(Landing.elevator_wall(p)),
		"landingFacing": String(Landing.landing_facing(p)), "ascii": ascii, "dist": {"sum": sum, "max": mx, "reach": reach}, "path": path,
		"car": Snap.car(Run.car_geometry(p)),
	}

func test_forty_plans_field_by_field(t: T) -> void:
	var ref: Dictionary = Snap.load_ref("floors.json")
	var total := Snap.Diff.new()
	for want: Dictionary in ref["floors"]:
		var p := Plans.plan(want["seed"], want["depth"])
		var got := compact(p)
		var d := Snap.compare(got, want, "%s d%d" % [want["seed"], want["depth"]])
		total.add(d)
		t.check(d.bad == 0 and d.inexact == 0, "%s d%d: %s" % [want["seed"], want["depth"], d.summary()])
	t.note("40 plans: %s" % total.summary())

func test_eight_hundred_plan_hashes(t: T) -> void:
	var ref: Dictionary = Snap.load_ref("floors.json")
	var hashes: Array = ref["hashes"]
	var plans := Plans.property_plans(t.quick)
	var wrong := 0
	for i in plans.size():
		# The reference lists all 800 (depth-major, 200 seeds a depth); the quick set is seed-0..9 of each.
		var k := i if not t.quick else (plans[i].depth - 1) * 200 + i % Plans.QUICK_SEEDS
		if Floor.hash_plan(plans[i]) != hashes[k]:
			wrong += 1
			t.check(false, "hashPlan %s d%d" % [plans[i].seed, plans[i].depth])
	t.note("%d floors (seed-0..%d, depths 1-4): %d hashes differ" % [plans.size(), plans.size() / 4 - 1, wrong])
