# Search sites share the floor's seed and are physically separate from its hides.
extends RefCounted

const Arboretum = preload("res://sim/arboretum.gd")
const Floor = preload("res://sim/floor.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")

const FIRST_ID := 10000
const STAND_GAP := 0.45
const HIDE_GAP := 1.7
const BODY := 0.30
const DIRECTIONS: Array[StringName] = [&"n", &"e", &"s", &"w"]

static func pieces(plan: Floor.FloorPlan) -> Array[Furniture.Piece]:
	var out: Array[Furniture.Piece] = []
	var garden := Arboretum.garden_of(plan)
	if garden == null:
		return out
	var solids := Furniture.solids_of(plan)
	var hides := Hides.hides_for(plan)
	var distance := Floor.distances_from(plan, plan.landing)
	var rng := Rng.make_rng("garden-storage:%s:%d" % [plan.seed, plan.depth])
	for landmark in garden.landmarks:
		if landmark.id == 0:
			continue
		var cells := Array(landmark.cells())
		var n := 0
		while not cells.is_empty() and n < 2:
			var cell: int = cells.pop_at(rng.int_in(0, cells.size() - 1))
			if distance[cell] <= 3:
				continue
			var x := cell % plan.width
			var z := cell / plan.width
			var at := Move.body_at_cell(plan, Floor.Pos.make(0, x, z))
			var kind := _piece_kind(landmark.kind, n)
			var start := rng.int_in(0, DIRECTIONS.size() - 1)
			for k in DIRECTIONS.size():
				var p := _at(plan, solids, hides, at, kind, DIRECTIONS[(start + k) % DIRECTIONS.size()])
				if p == null:
					continue
				p.id = FIRST_ID + landmark.id * 2 + n
				p.room = Floor.room_id_at(plan, at.level, x, z)
				out.append(p)
				n += 1
				break
	return out

static func _piece_kind(landmark: StringName, slot: int) -> StringName:
	if landmark == &"greenhouse":
		return &"garden_drawer" if slot == 0 else &"garden_bench"
	if landmark in [&"sheds", &"lodge"]:
		return &"garden_chest" if slot == 0 else &"garden_bin"
	return &"garden_bin" if slot == 0 else &"garden_bench"

static func _at(plan: Floor.FloorPlan, solids: Move.Solids, hides: Array, stand: Move.Body, kind: StringName, facing: StringName) -> Furniture.Piece:
	if not Move.clear_at(plan, solids, stand.level, stand.x, stand.z, BODY):
		return null
	for h: Variant in hides:
		if h.level == stand.level and Vector2(h.front.x / 100.0 - stand.x, h.front.y / 100.0 - stand.z).length() < HIDE_GAP:
			return null
	var direction := Vector2(Furniture.dir_vec(facing))
	var width := 62 if kind != &"garden_bin" else 48
	var depth := 38
	var centre := Vector2(stand.x, stand.z) - direction * (STAND_GAP + depth / 200.0)
	if not Move.clear_at(plan, solids, stand.level, centre.x, centre.y, 0.40):
		return null
	var p := Furniture.Piece.new()
	p.kind = kind
	p.facing = facing
	p.x = roundi(centre.x * 100.0)
	p.y = roundi(centre.y * 100.0)
	p.level = stand.level
	p.w = width
	p.d = depth
	p.searchable = true
	p.solid = false
	var size := Vector2i(depth, width) if direction.x != 0 else Vector2i(width, depth)
	p.foot = Rect2i(Vector2i(p.x, p.y) - size / 2, size)
	return p
