# Furniture: one list and collision (docs/floors/findables-and-day.md section 4 and FD7; sim/furniture.gd,
# sim/move.gd Solids, sim/run.gd `furniture`). Over 800 Clinics and 800 Annexes (seed-0..199 at depths 1 to 4;
# the quick set seed-0..9, 40 of each):
#   1. nobody is sealed in or stuck: a body of the player's radius (0.3 m), searched over a 25 cm grid from the
#      landing, reaches with the furniture solid every cell it reached without it, every hide's front spot, the
#      landing and the car's doorway; random walks into the pieces (Run.move_in_run on a run with furniture)
#      never end inside a solid footprint; a body standing inside a piece (put there by a drag, a grab, a
#      relocation, or the flag turning on under it) is pushed out to a spot the search reaches, and walks on;
#   2. where they stand: no piece on a door cell, in the lobby, within 3 steps of the landing or in the car's
#      zone; every plain piece against a wall; no solid footprint over the middle of a cell;
#   3. same seed, same list: generated twice alike, and every floor's hash as stored in
#      tests/reference/furniture_hashes.json (written by `npm run godot:golden -- prop_furniture`), so Windows
#      and Linux hold the same lists; same-shaped Annex rooms have identical pieces (each in its canonical frame);
#   4. what is drawn is what blocks: every floor-standing mesh the client draws (client/level.gd,
#      client/annex_view.gd) has a solid piece, and every piece a mesh, within 5 cm;
#   5. stored results unchanged: the flag is off unless asked (Run, HostRules), and off moves are exactly
#      Move.move_with_collision's; the resident walks the same path with the furniture solid as without;
#   6. the bots and the client's walks (sim/follow.gd with the solids, as client/play_link.gd walkto uses it)
#      still arrive: walks from the landing to room cells and to every hide's front cell all end there.
# Breaks (the design's): Furniture.test_break "chairs_soft" (chairs left out of the solid set: check 4 goes
# red), "randi" (the Clinic's pieces slid with randi(): check 3 goes red). PROP_FURNITURE_BREAK=chairs_soft|randi.
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Playroom = preload("res://sim/playroom.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Run = preload("res://sim/run.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const LevelScript = preload("res://client/level.gd")

const QUICK_SEEDS := 10
const SEEDS := 200
const HASHES_PATH := "res://tests/reference/furniture_hashes.json"
const R := 0.3
const STEP := 0.25
const SUB := 8
const EPS := 1e-6

static var _cache := {}

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_FURNITURE_BREAK")
	Furniture.test_break = b if b == "chairs_soft" or b == "randi" else ""

class Fl:
	var place: StringName
	var plan: Floor.FloorPlan
	var pieces: Array
	var solids: Move.Solids

static func floor_of(place: StringName, floor_seed: String, depth: int) -> Fl:
	var key := "%s:%s/%d" % [place, floor_seed, depth]
	if not _cache.has(key) or not Furniture.test_break.is_empty():
		var f := Fl.new()
		f.place = place
		f.plan = Clinic.generate_clinic(floor_seed, depth) if place == &"clinic" else Annex.generate_annex(floor_seed, depth)
		f.pieces = Furniture.pieces_for(f.plan, floor_seed, depth)
		f.solids = Furniture.solids_from(f.plan, f.pieces)
		if not Furniture.test_break.is_empty():
			return f
		_cache[key] = f
	return _cache[key]

static func floors(quick: bool, place: StringName) -> Array[Fl]:
	var out: Array[Fl] = []
	for depth: int in [1, 2, 3, 4]:
		for i in (QUICK_SEEDS if quick else SEEDS):
			out.append(floor_of(place, "seed-%d" % i, depth))
	return out

static func _key(f: Fl) -> String:
	return "%s:%s/%d" % [f.place, f.plan.seed, f.plan.depth]

## A run state that moves bodies as the run does, with the furniture on or off.
static func _view(plan: Floor.FloorPlan, on: bool) -> Run.RunState:
	var v := Run.RunState.new()
	v.plan = plan
	v.car = Run.car_geometry(plan)
	v.phase = &"away"
	v.furniture = on
	return v

# ---------------------------------------------------------------------------------------------
# The grid search: which points (STEP apart) a body of radius R reaches from the landing's centre.

class Grid:
	var plan: Floor.FloorPlan
	var gw := 0
	var gh := 0
	var per := 0
	## Walls only: 0 not yet known, 1 clear, 2 not.
	var walls := PackedByteArray()
	var segs := {}

	func node(level: int, gx: int, gz: int) -> int:
		return level * per + gz * gw + gx

static func _grid(plan: Floor.FloorPlan) -> Grid:
	var g := Grid.new()
	g.plan = plan
	g.gw = plan.width * SUB
	g.gh = plan.height * SUB
	g.per = g.gw * g.gh
	g.walls.resize(2 * g.per)
	return g

## Clear of walls by R at a grid point (cached; the cell's segments read once).
static func _walls_ok(g: Grid, n: int) -> bool:
	var v := g.walls[n]
	if v != 0:
		return v == 1
	var lv := n / g.per
	var rest := n - lv * g.per
	var gx := rest % g.gw
	var gz := rest / g.gw
	var cx := gx / SUB
	var cy := gz / SUB
	var ok := Floor.is_walkable(g.plan, lv, cx, cy)
	if ok:
		var key := lv * g.per + cy * g.gw + cx
		if not g.segs.has(key):
			g.segs[key] = Walls_near(g.plan, lv, cx, cy)
		var segs: PackedFloat64Array = g.segs[key]
		var x := gx * STEP
		var z := gz * STEP
		var i := 0
		while i < segs.size() and ok:
			var ax := segs[i]
			var az := segs[i + 1]
			var ex := segs[i + 2] - ax
			var ez := segs[i + 3] - az
			var len2 := ex * ex + ez * ez
			var t := minf(1.0, maxf(0.0, ((x - ax) * ex + (z - az) * ez) / len2)) if len2 > 0.0 else 0.0
			var qx := ax + ex * t
			var qz := az + ez * t
			if M.hypot2(x - qx, z - qz) < R - EPS:
				ok = false
			i += 4
	g.walls[n] = 1 if ok else 2
	return ok

static func Walls_near(plan: Floor.FloorPlan, level: int, cx: int, cy: int) -> PackedFloat64Array:
	return preload("res://sim/walls.gd").segments_near(plan, level, cx, cy)

static func _ok(g: Grid, solids: Move.Solids, n: int) -> bool:
	if not _walls_ok(g, n):
		return false
	if solids == null:
		return true
	var lv := n / g.per
	var rest := n - lv * g.per
	return Move.box_clearance(solids, lv, (rest % g.gw) * STEP, (rest / g.gw) * STEP) >= R - EPS

## Reached points (1) from the landing's centre, with `solids` (or walls only when null).
static func reach(g: Grid, solids: Move.Solids) -> PackedByteArray:
	var plan := g.plan
	var seen := PackedByteArray()
	seen.resize(2 * g.per)
	var start := g.node(plan.landing.level, plan.landing.x * SUB + SUB / 2, plan.landing.y * SUB + SUB / 2)
	if not _ok(g, solids, start):
		return seen
	var queue := PackedInt32Array([start])
	seen[start] = 1
	var head := 0
	while head < queue.size():
		var n := queue[head]
		head += 1
		var lv := n / g.per
		var rest := n - lv * g.per
		var gx := rest % g.gw
		var gz := rest / g.gw
		var here := Floor.Pos.make(lv, gx / SUB, gz / SUB)
		for st in Floor.STEPS:
			var nx := gx + st.x
			var nz := gz + st.y
			if nx < 0 or nz < 0 or nx >= g.gw or nz >= g.gh:
				continue
			var nl := lv
			if nx / SUB != here.x or nz / SUB != here.y:
				nl = Move._level_after_step(plan, here, nx / SUB, nz / SUB)
				if nl < 0:
					continue
			var nn := g.node(nl, nx, nz)
			if seen[nn] != 0 or not _ok(g, solids, nn):
				continue
			seen[nn] = 1
			queue.append(nn)
	return seen

## Cells (pos_index) holding a reached point.
static func cells_of(g: Grid, seen: PackedByteArray) -> Dictionary:
	var out := {}
	var w := g.plan.width
	var n := g.plan.width * g.plan.height
	for i in seen.size():
		if seen[i] == 0:
			continue
		var lv := i / g.per
		var rest := i - lv * g.per
		out[lv * n + ((rest / g.gw) / SUB) * w + (rest % g.gw) / SUB] = true
	return out

## Whether a body of radius R standing at (x, z) is clear and joined to a reached point (one within 0.36 m:
## both clear by R and closer than a body, so nothing stands between them).
static func joined(g: Grid, solids: Move.Solids, seen: PackedByteArray, level: int, x: float, z: float) -> bool:
	if not Move.clear_at(g.plan, solids, level, x, z, R):
		return false
	var bx := int(floor(x / STEP))
	var bz := int(floor(z / STEP))
	for dz in range(-1, 3):
		for dx in range(-1, 3):
			var gx := bx + dx
			var gz := bz + dz
			if gx < 0 or gz < 0 or gx >= g.gw or gz >= g.gh:
				continue
			if M.hypot2(gx * STEP - x, gz * STEP - z) > 0.36:
				continue
			var n := g.node(level, gx, gz)
			if seen[n] == 1 and Floor.is_walkable(g.plan, level, int(floor(x / g.plan.cell_size)), int(floor(z / g.plan.cell_size))):
				return true
	return false

## Whether a body (pushed out into a pocket the 25 cm grid has no point in, say) walks onto a reached
## point within a metre, with the run's own moves.
static func walks_to_reached(g: Grid, on: Run.RunState, seen: PackedByteArray, b: Move.Body) -> bool:
	var bx := int(floor(b.x / STEP))
	var bz := int(floor(b.z / STEP))
	for dz in range(-4, 6):
		for dx in range(-4, 6):
			var gx := bx + dx
			var gz := bz + dz
			if gx < 0 or gz < 0 or gx >= g.gw or gz >= g.gh or seen[g.node(b.level, gx, gz)] == 0:
				continue
			var tx := gx * STEP
			var tz := gz * STEP
			if M.hypot2(tx - b.x, tz - b.z) > 1.2:
				continue
			# Steered at it a few centimetres at a time, sliding round what is in the way.
			var e := b
			for _k in 60:
				var d := M.hypot2(tx - e.x, tz - e.z)
				if d < 0.05:
					return true
				var st := minf(d, 0.05)
				e = Run.move_in_run(on, e, (tx - e.x) / d * st, (tz - e.z) / d * st, R)
	return false

# ---------------------------------------------------------------------------------------------
# 1. Nobody sealed in, never inside, pushed out.

func test_nobody_sealed_in_or_stuck(t: T) -> void:
	_apply_break()
	for place: StringName in [&"clinic", &"annex"]:
		var lost_cells := 0
		var fronts := 0
		var bad_fronts := 0
		var moves := 0
		var inside := 0
		var pushed := 0
		var stuck := 0
		var cells_total := 0
		for f in floors(t.quick, place):
			var p := f.plan
			var g := _grid(p)
			var bare := cells_of(g, reach(g, null))
			var seen := reach(g, f.solids)
			var got := cells_of(g, seen)
			cells_total += bare.size()
			for k: int in bare:
				if not got.has(k):
					lost_cells += 1
					if lost_cells <= 5:
						var pos := Floor.pos_from_index(p, k)
						t.check(false, "%s: cell L%d %d,%d is reached without the furniture and not with it" % [_key(f), pos.level, pos.x, pos.y])
			# Every hide's front spot, the landing and the car's doorway.
			for pc: Furniture.Piece in f.pieces:
				if pc.hide < 0:
					continue
			for h in Hides.hides_for(p, p.seed):
				fronts += 1
				if not joined(g, f.solids, seen, h.level, h.front.x / 100.0, h.front.y / 100.0):
					bad_fronts += 1
					if bad_fronts <= 5:
						t.check(false, "%s: hide %d (%s)'s front spot %d,%d is not reached with the furniture" % [_key(f), h.id, h.kind, h.front.x, h.front.y])
			var lc := Move.body_at_cell(p, p.landing)
			t.check(joined(g, f.solids, seen, p.landing.level, lc.x, lc.z), "%s: the landing is not reached" % _key(f))
			var car := Run.car_geometry(p)
			var door := Run.car_body(car, -0.6, 0.0)
			t.check(joined(g, f.solids, seen, door.level, door.x, door.z), "%s: the car's doorway is not reached" % _key(f))
			# Random walks into the pieces, and bodies inside them.
			var on := _view(p, true)
			var rng := Rng.make_rng("furniture-walks:%s" % _key(f))
			var sample: Array = []
			for pc: Furniture.Piece in f.pieces:
				if pc.solid:
					sample.append(pc)
			sample = Hides._shuffled(rng, sample).slice(0, 4 if t.quick else 3)
			for pc: Furniture.Piece in sample:
				var cx := (pc.block.position.x + pc.block.end.x) / 200.0
				var cz := (pc.block.position.y + pc.block.end.y) / 200.0
				# A start beside it that the search reached.
				var start: Move.Body = null
				var best := INF
				for dz in range(-10, 11):
					for dx in range(-10, 11):
						var gx := int(floor(cx / STEP)) + dx
						var gz := int(floor(cz / STEP)) + dz
						if gx < 0 or gz < 0 or gx >= g.gw or gz >= g.gh:
							continue
						var n := g.node(pc.level, gx, gz)
						if seen[n] == 0:
							continue
						var d := M.hypot2(gx * STEP - cx, gz * STEP - cz)
						if d < best:
							best = d
							start = Move.Body.make(gx * STEP, gz * STEP, pc.level, Move.feet_height(p, pc.level, gx * STEP, gz * STEP))
				if start != null:
					var b := start
					for _i in 24:
						var tx := cx + (rng.next() - 0.5) * pc.block.size.x / 100.0
						var tz := cz + (rng.next() - 0.5) * pc.block.size.y / 100.0
						var d := M.hypot2(tx - b.x, tz - b.z)
						if d < 1e-6:
							continue
						var len := minf(d + 0.3, 0.2 + rng.next() * 0.6)
						b = Run.move_in_run(on, b, (tx - b.x) / d * len, (tz - b.z) / d * len, R)
						moves += 1
						if Move.box_clearance(f.solids, b.level, b.x, b.z) < R - EPS:
							inside += 1
							if inside <= 5:
								t.check(false, "%s: walking into piece %d (%s) ended %.3f m from it" % [_key(f), pc.id, pc.kind, Move.box_clearance(f.solids, b.level, b.x, b.z)])
				# Bodies inside it: pushed out to a reached spot, and they walk on.
				for k in 3:
					var ix := cx if k == 0 else (pc.block.position.x + 2 + rng.next() * (pc.block.size.x - 4)) / 100.0
					var iz := cz if k == 0 else (pc.block.position.y + 2 + rng.next() * (pc.block.size.y - 4)) / 100.0
					var cell := Floor.Pos.make(pc.level, int(floor(ix / 2.0)), int(floor(iz / 2.0)))
					if not Floor.is_walkable(p, cell.level, cell.x, cell.y):
						continue
					var body := Move.Body.make(ix, iz, pc.level, Move.feet_height(p, pc.level, ix, iz))
					var out := Run.move_in_run(on, body, 0.0, 0.0, R)
					pushed += 1
					var ok := joined(g, f.solids, seen, out.level, out.x, out.z) or walks_to_reached(g, on, seen, out)
					var walks := false
					for a in 8:
						var w := Run.move_in_run(on, out, cos(a * PI / 4.0) * 0.3, sin(a * PI / 4.0) * 0.3, R)
						if M.hypot2(w.x - out.x, w.z - out.z) > 0.05:
							walks = true
							break
					if not ok or not walks:
						stuck += 1
						if stuck <= 5:
							t.check(false, "%s: a body inside piece %d (%s) at %.2f,%.2f ended at %.2f,%.2f (joined %s, walks on %s)" % [
								_key(f), pc.id, pc.kind, ix, iz, out.x, out.z, ok, walks])
		t.eq(lost_cells, 0, "%s: cells lost to the furniture" % place)
		t.eq(bad_fronts, 0, "%s: hide front spots not reached" % place)
		t.eq(inside, 0, "%s: walks that ended inside a piece" % place)
		t.eq(stuck, 0, "%s: bodies left inside or stuck" % place)
		t.check(moves > 0 and pushed > 0, "%s: no walks or pushes were tried" % place)
		t.note("%s: %d floors, %d cells all still reached, %d hide fronts reached; %d moves into pieces, none inside; %d bodies pushed out of pieces, all walk on" % [
			place, floors(t.quick, place).size(), cells_total, fronts, moves, pushed])

# ---------------------------------------------------------------------------------------------
# 2. Where they stand.

func test_where_pieces_stand(t: T) -> void:
	_apply_break()
	for place: StringName in [&"clinic", &"annex"]:
		var bad := 0
		var kinds := {}
		var total := 0
		var nfl := 0
		for f in floors(t.quick, place):
			nfl += 1
			var p := f.plan
			var doors := Playroom._door_cells(p)
			var landing := Floor.distances_from(p, p.landing)
			var car := Run.car_geometry(p)
			var a := Run.car_body(car, 0.0, -car.width / 2.0)
			var b := Run.car_body(car, car.depth, car.width / 2.0)
			var car_rect := Rect2i(int(floor(minf(a.x, b.x) * 100.0)), int(floor(minf(a.z, b.z) * 100.0)), int(ceil(absf(a.x - b.x) * 100.0)), int(ceil(absf(a.z - b.z) * 100.0)))
			for pc: Furniture.Piece in f.pieces:
				total += 1
				kinds[pc.kind] = int(kinds.get(pc.kind, 0)) + 1
				var why := ""
				if pc.level == car.level and Furniture.overlaps(pc.foot, car_rect):
					why = "in the car's zone"
				for cy in range(pc.foot.position.y / 200, (pc.foot.end.y - 1) / 200 + 1):
					for cx in range(pc.foot.position.x / 200, (pc.foot.end.x - 1) / 200 + 1):
						var k := Floor.pos_index(p, Floor.Pos.make(pc.level, cx, cy))
						var rid := Floor.room_id_at(p, pc.level, cx, cy)
						if pc.hide < 0 and doors.has(k):
							why = "on door cell %d,%d" % [cx, cy]
						if rid >= 0 and p.rooms[rid].kind == &"lobby":
							why = "in the lobby"
						if landing[k] >= 0 and landing[k] <= Furniture.LANDING_STEPS:
							why = "within %d steps of the landing" % landing[k]
						var mx := cx * 200 + 100
						var my := cy * 200 + 100
						if pc.block.position.x < mx and mx < pc.block.end.x and pc.block.position.y < my and my < pc.block.end.y:
							why = "over the middle of cell %d,%d" % [cx, cy]
				if pc.hide < 0 and pc.group < 0:
					# Against a wall: its back INSET from the wall line.
					var ov := Furniture.dir_vec(pc.wall) if pc.wall != &"" else Vector2i.ZERO
					var back := 0
					if ov.x > 0:
						back = pc.wall_at - pc.foot.end.x
					elif ov.x < 0:
						back = pc.foot.position.x - pc.wall_at
					elif ov.y > 0:
						back = pc.wall_at - pc.foot.end.y
					elif ov.y < 0:
						back = pc.foot.position.y - pc.wall_at
					if ov == Vector2i.ZERO or back != Furniture.INSET:
						why = "not against a wall"
				if why != "":
					bad += 1
					if bad <= 6:
						t.check(false, "%s: piece %d (%s) at %d,%d L%d is %s" % [_key(f), pc.id, pc.kind, pc.x, pc.y, pc.level, why])
		t.eq(bad, 0, "%s: pieces where none may stand" % place)
		var parts: Array[String] = []
		var ks: Array = kinds.keys()
		ks.sort()
		for k: StringName in ks:
			parts.append("%s %.1f" % [k, float(kinds[k]) / nfl])
		t.note("%s: %d floors, %.1f pieces a floor: %s" % [place, nfl, float(total) / nfl, ", ".join(parts)])

# ---------------------------------------------------------------------------------------------
# 3. Same seed, same list; same-shaped Annex rooms alike.

func test_same_list_for_everyone(t: T) -> void:
	_apply_break()
	var stored := {}
	if not t.recording:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HASHES_PATH))
		if not t.check(parsed is Dictionary, "cannot read %s" % HASHES_PATH):
			return
		stored = parsed
	var got := {}
	var differ := 0
	var mismatched := 0
	for place: StringName in [&"clinic", &"annex"]:
		for f in floors(t.quick, place):
			var h := Furniture.hash_of(f.pieces)
			var again_plan := Clinic.generate_clinic(f.plan.seed, f.plan.depth) if place == &"clinic" else Annex.generate_annex(f.plan.seed, f.plan.depth)
			var again := Furniture.hash_of(Furniture.pieces_for(again_plan, f.plan.seed, f.plan.depth))
			if h != again:
				differ += 1
				if differ <= 3:
					t.check(false, "%s: generated twice, hashes %s and %s" % [_key(f), h, again])
			got[_key(f)] = h
			if not t.recording and str(stored.get(_key(f), "(none)")) != h:
				mismatched += 1
				if mismatched <= 3:
					t.check(false, "%s: furniture hash %s, stored %s" % [_key(f), h, str(stored.get(_key(f), "(none)"))])
	t.eq(differ, 0, "lists whose two generations differ")
	t.eq(mismatched, 0, "lists whose hash differs from %s" % HASHES_PATH.get_file())
	if t.recording:
		# godot:golden -- prop_furniture: the quick pass first, then the default, which leaves all 1600.
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(HASHES_PATH.get_base_dir()))
		var keys: Array = got.keys()
		keys.sort()
		var lines := PackedStringArray()
		for k: String in keys:
			lines.append("  %s: %s" % [JSON.stringify(k), JSON.stringify(got[k])])
		var fa := FileAccess.open(HASHES_PATH, FileAccess.WRITE)
		fa.store_string("{\n" + ",\n".join(lines) + "\n}\n")
		fa.close()
		t.note("wrote %d hashes to %s" % [keys.size(), HASHES_PATH])
	# Same-shaped Annex rooms: identical pieces in their canonical frames.
	var groups_total := 0
	var compared := 0
	var unlike := 0
	for f in floors(t.quick, &"annex"):
		var p := f.plan
		var by_key := {}
		for room in p.rooms:
			var sh := Hides.shape_of(p, room)
			var lines: Array[String] = []
			for pc: Furniture.Piece in f.pieces:
				if pc.room != room.id:
					continue
				var o := Vector2i(room.x * 200, room.y * 200)
				var c := Hides.local_to_canon(sh.sym, room.w * 200, room.h * 200, Vector2i(pc.x, pc.y) - o)
				var fv := Hides.local_to_canon(sh.sym, room.w * 200, room.h * 200, Vector2i(pc.x, pc.y) - o + Furniture.dir_vec(pc.facing) * 10) - c
				lines.append("%s %d,%d %d,%d %dx%d %s" % [pc.kind, c.x, c.y, fv.x, fv.y, pc.w, pc.d, pc.solid])
			lines.sort()
			var text := ";".join(lines)
			if not by_key.has(sh.key):
				by_key[sh.key] = [room, text]
				continue
			compared += 1
			if by_key[sh.key][1] != text:
				unlike += 1
				if unlike <= 3:
					var r0: Floor.Room = by_key[sh.key][0]
					t.check(false, "%s: room %d (%s at %d,%d) is furnished unlike room %d at %d,%d of the same shape" % [_key(f), room.id, room.kind, room.x, room.y, r0.id, r0.x, r0.y])
		groups_total += by_key.size()
	t.eq(unlike, 0, "same-shaped Annex rooms furnished unalike")
	t.check(compared > 0, "no same-shaped rooms were compared")
	t.note("%d floors each place hashed and generated twice alike; %d same-shaped Annex rooms compared, all alike" % [floors(t.quick, &"clinic").size(), compared])

# ---------------------------------------------------------------------------------------------
# 4. What is drawn is what blocks.

func test_drawn_is_solid(t: T) -> void:
	_apply_break()
	var plans: Array[Floor.FloorPlan] = []
	var n := 2 if t.quick else 6
	for i in n:
		plans.append(Clinic.generate_clinic("seed-%d" % i, 1 + i % 4))
		plans.append(Annex.generate_annex("seed-%d" % i, 1 + i % 4))
	var meshes := 0
	var bad := 0
	for p in plans:
		var list := Furniture.pieces_for(p, p.seed, p.depth)
		var lv: Node3D = LevelScript.new()
		lv.call("build", PlanDump.dump(p, Run.car_geometry(p)), "furniture-check")
		var drawn: Array = lv.get("furniture_drawn")
		var tag := "%s %s/%d" % [p.place, p.seed, p.depth]
		var seen := {}
		for d: Dictionary in drawn:
			meshes += 1
			var id := int(d["piece"])
			var r: Rect2 = d["rect"]
			if id < 0 or id >= list.size():
				bad += 1
				if bad <= 5:
					t.check(false, "%s: a floor-standing mesh (%s) with no piece" % [tag, str(d.get("kind", ""))])
				continue
			seen[id] = true
			var pc: Furniture.Piece = list[id]
			var f := Rect2(pc.foot.position.x / 100.0, pc.foot.position.y / 100.0, pc.foot.size.x / 100.0, pc.foot.size.y / 100.0)
			var off := maxf(maxf(absf(r.position.x - f.position.x), absf(r.position.y - f.position.y)), maxf(absf(r.end.x - f.end.x), absf(r.end.y - f.end.y)))
			if off > 0.05 or not pc.solid:
				bad += 1
				if bad <= 5:
					t.check(false, "%s: piece %d (%s): the mesh is %.3f m off its footprint, solid %s" % [tag, id, pc.kind, off, pc.solid])
		# The `props` test command's rows (the scripted playthroughs look at a Clinic prop from inside its room
		# and from beyond its wall): every row names its room's cell and the solid wall it stands against.
		if p.place == &"clinic":
			for sp: Dictionary in lv.get("prop_spots"):
				var cell := Floor.Pos.make(int(sp["level"]), int(sp.get("cx", -1)), int(sp.get("cy", -1)))
				var wall: Array = sp.get("wall", [0, 0])
				var side := Floor.dir_from_vec(int(wall[0]), int(wall[1])) if absi(int(wall[0])) + absi(int(wall[1])) == 1 else &""
				var wall_ok := side != &"" and Furniture._wall_solid(p, cell.level, Vector3i(cell.x, cell.y, Playroom.DIRS.find(side)))
				if Floor.room_id_at(p, cell.level, cell.x, cell.y) != int(sp["room"]) or not wall_ok:
					bad += 1
					if bad <= 5:
						t.check(false, "%s: the props row for piece %d names cell %d,%d and wall %s" % [tag, int(sp["piece"]), cell.x, cell.y, str(wall)])
		for pc: Furniture.Piece in list:
			if not seen.has(pc.id):
				bad += 1
				if bad <= 5:
					t.check(false, "%s: piece %d (%s) has no mesh" % [tag, pc.id, pc.kind])
		lv.free()
	t.eq(bad, 0, "meshes without a solid piece within 5 cm, or pieces without a mesh")
	t.check(meshes > 0, "no meshes were drawn")
	t.note("%d floors drawn: %d floor-standing meshes, each on its solid piece within 5 cm" % [plans.size(), meshes])

# ---------------------------------------------------------------------------------------------
# 5. Stored results unchanged.

func test_off_unless_asked_and_the_resident_unchanged(t: T) -> void:
	_apply_break()
	var ids: Array[String] = ["a", "b"]
	t.eq(Run.create_run("f", ids).furniture, false, "a new run has no solid furniture")
	t.eq(HostRules.new(true, 1).prepare(Run.create_run("f", ids)).furniture, false, "the rules' default")
	t.eq(HostRules.new(true, 1, [], false, false, false, false, false, false, false, false, false, false, false, true).prepare(Run.create_run("f", ids)).furniture, true, "the rules, asked")
	# Off: every move is exactly Move.move_with_collision's (no box is read).
	var same := 0
	var diff := 0
	var some: Array = floors(true, &"clinic").slice(0, 8) + floors(true, &"annex").slice(0, 8)
	for f: Fl in some:
		var p := f.plan
		var off := _view(p, false)
		var rng := Rng.make_rng("off:%s" % _key(f))
		var b := Move.body_at_cell(p, p.landing)
		var c := b
		for _i in 200:
			var a := rng.next() * TAU
			var len := rng.next() * 0.5
			var nb := Run.move_in_run(off, b, cos(a) * len, sin(a) * len, R)
			var nc := Run.move_in_run(_view(p, false), c, cos(a) * len, sin(a) * len, R)
			if nb.same(nc):
				same += 1
			else:
				diff += 1
			b = nb
			c = nc
	t.eq(diff, 0, "moves with the furniture off that differ")
	# The resident walks the same path with the furniture solid: a run whose players stand still in a room far
	# from the landing (the same bodies either way), facing a wall, for two minutes.
	var moved := 0
	var unlike := 0
	for place: StringName in [&"clinic", &"annex"]:
		for i in (2 if t.quick else 6):
			var s0 := HostRules.new(true, 1 + i % 3, [place]).prepare(Run.create_run("res-%d" % i, ids))
			var s1 := Run.with_furniture(s0)
			var start := s0.orderly.body
			var dist := Floor.distances_from(s0.plan, s0.plan.landing)
			var far := 0
			for k in dist.size():
				if dist[k] > dist[far]:
					far = k
			var stand := Move.body_at_cell(s0.plan, Floor.pos_from_index(s0.plan, far))
			for k in 2400:
				var inputs: Array[Run.PlayerInput] = []
				for id in ids:
					inputs.append(Run.PlayerInput.make(id, stand, 1.65, 0.0, 0.0, 90.0, 60.0))
				s0 = Run.step_run(s0, inputs, 0.05).state
				s1 = Run.step_run(s1, inputs, 0.05).state
				var o0: Move.Body = s0.orderly.body
				var o1: Move.Body = s1.orderly.body
				if not o0.same(o1):
					unlike += 1
					break
			if not (s0.orderly.body as Move.Body).same(start):
				moved += 1
	t.eq(unlike, 0, "runs where the resident walked differently with the furniture solid")
	t.check(moved > 0, "the resident never moved: the check is vacuous")
	t.note("%d moves alike with the furniture off; the resident walked alike in every run (%d of them it moved)" % [same, moved])

# ---------------------------------------------------------------------------------------------
# 6. The bots and the client's walks still arrive.

func test_walks_arrive(t: T) -> void:
	_apply_break()
	for place: StringName in [&"clinic", &"annex"]:
		var walks := 0
		var arrived := 0
		var fl := floors(t.quick, place)
		for f: Fl in fl.slice(0, 12 if t.quick else 60):
			var p := f.plan
			var rng := Rng.make_rng("walks:%s" % _key(f))
			var goals: Array[Floor.Pos] = []
			for h in Hides.hides_for(p, p.seed):
				goals.append(Floor.Pos.make(h.level, h.front.x / 200, h.front.y / 200))
			for room in p.rooms:
				goals.append(Floor.Pos.make(room.level, room.x + rng.int_in(0, room.w - 1), room.y + rng.int_in(0, room.h - 1)))
			goals = Hides._shuffled(rng, goals).slice(0, 6 if t.quick else 4)
			for goal in goals:
				var from := Move.body_at_cell(p, p.landing)
				var path := Floor.find_path(p, p.landing, goal)
				if path.size() < 2:
					continue
				walks += 1
				var w := Follow.start_path_walk(path)
				var b := from
				var ok := false
				for _i in 3000:
					if Follow.path_done(p, w, b):
						ok = true
						break
					var nb := Follow.step_path_walk(p, w, b, 0.1, R, f.solids)
					if Move.box_clearance(f.solids, nb.level, nb.x, nb.z) < R - EPS:
						break
					b = nb
				var c := Move.cell_of(p, b)
				if ok and c.level == goal.level and c.x == goal.x and c.y == goal.y:
					arrived += 1
				elif walks - arrived <= 5:
					t.check(false, "%s: a walk from the landing to L%d %d,%d stopped at %.2f,%.2f L%d" % [_key(f), goal.level, goal.x, goal.y, b.x, b.z, b.level])
		t.eq(arrived, walks, "%s: walks that arrived" % place)
		t.note("%s: %d walks round the furniture from the landing to room cells and hide fronts, all arrived" % [place, walks])
