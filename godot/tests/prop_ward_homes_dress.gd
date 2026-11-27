# WH3: the Hanging Ward's homes dressed with real furniture (client/ward/homes_dress.gd; the run flag ward_homes, off in
# every build). The North Star: "Everything about a floor comes from one seed, identical for every player"; "Every
# floor has places to hide, and a view out of each"; "Furniture is solid" (the rules' boxes, sim/ward/house.gd, are
# unchanged: the dressing is drawn inside them, and what is not furniture is not solid). Checked here:
#   1. with the homes off nothing is dressed: no plan, no node;
#   2. one seed, one dressing: planned twice the same, the same as recorded, and its own stream (two houses differ);
#   3. every piece of furniture of every house type is drawn inside its own rules box (only the listed rails and flues
#      above it), every room gets something, on hundreds of Wards; the models' recorded sizes are the files';
#   4. nothing extra stands in a doorway's clear approach (tests/ward_home_clear.gd), in the front door's open leaf, in a
#      stair's shaft, in a piece of furniture, in a hide, or across a hide's view; and a hide's own model leaves the
#      camera inside it a clear view out;
#   5. nothing the dressing adds (and no model's top above its rules box) crosses the Rigger's arm on its routes from
#      each opening to each room and each hide.
extends RefCounted

const T = preload("res://tests/t.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Homes = preload("res://sim/ward/homes.gd")
const Hides = preload("res://sim/hides.gd")
const ArmSearch = preload("res://sim/ward/arm.gd")
const Clear = preload("res://tests/ward_home_clear.gd")
const Dress = preload("res://client/ward/homes_dress.gd")
const HidesView = preload("res://client/ward/hides_view.gd")
const View = preload("res://client/ward/view.gd")

## Recorded with WH3 by this file (test_the_same_seed_dresses_the_same prints each line while recording is asked for by
## RECORD): a digest of every house's dressing, numbers rounded to the centimetre.
const RECORD := false
const DRESS_GOLDEN := {
	8143: "8c73861e",
	26: "7d193a56",
	31827: "16fc2c29",
}
## Kinds whose model may stand above its rules box (the bed's head and foot rails, the range's flue, the copper's lid,
## the mangle's wheel), by at most this much.
const ABOVE := {&"bed": 0.45, &"range": 0.25, &"stove": 0.15, &"copper": 0.2, &"mangle": 0.15}

static func _seeds(t: T, quick: int, full: int) -> Array[int]:
	var out: Array[int] = []
	for k in (quick if t.quick else full):
		out.append(1 + k * 7919)
	return out

static func _houses(seed_value: int, homes := true) -> Array[House]:
	var o := Layout.options(null)
	if homes:
		o["homes"] = 1
	var out: Array[House] = []
	for site: Dictionary in Layout.generate(seed_value, o).houses:
		out.append(House.new(site, seed_value))
	return out

static func _r(v: float) -> String:
	return "%d" % roundi(v * 100.0)

static func _digest(rows: Array[Dictionary]) -> String:
	var parts := PackedStringArray()
	for row in rows:
		var b: AABB = row.box
		parts.append("%s %s %s %s %s %s %s %s" % [row.kind, row.what, row.level, _r(b.position.x), _r(b.position.y), _r(b.position.z), _r(b.size.x + b.size.y + b.size.z), _r(float(row.get("yaw", 0.0)))])
	return "|".join(parts)

## The extras of a plan (not furniture): pictures, shelves, rugs and the pram.
static func _extras(rows: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row in rows:
		if int(row.piece) < 0:
			out.append(row)
	return out

## The dressing's nodes under one view (other tests' views may still be in the tree).
static func _dressed(view: Node) -> int:
	var n := 0
	for node: Node in view.get_tree().get_nodes_in_group(Dress.GROUP):
		if view.is_ancestor_of(node):
			n += 1
	return n

func test_with_the_homes_off_nothing_is_dressed(t: T) -> void:
	for s: int in [8143, 26]:
		for h in _houses(s, false):
			t.check(not h.homes() and Dress.plan(h, s, 0).is_empty(), "seed %d: a house without the homes has no dressing" % s)
	var view := View.new(8143, Vector3.ZERO, Layout.to_wire(Layout.options(null)))
	view.own_hud = false
	view.own_camera = false
	view.own_environment = false
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	t.eq(_dressed(view), 0, "the Ward drawn without the homes has no dressing")
	view.queue_free()
	# And with them, it has (so the check above is not vacuous).
	var opts := Layout.options(null)
	opts["homes"] = 1
	var on := View.new(8143, Vector3.ZERO, Layout.to_wire(opts))
	on.own_hud = false
	on.own_camera = false
	on.own_environment = false
	(Engine.get_main_loop() as SceneTree).root.add_child(on)
	t.check(_dressed(on) > 100, "the Ward of homes is dressed (%d nodes)" % _dressed(on))
	on.queue_free()

func test_the_same_seed_dresses_the_same(t: T) -> void:
	for s: int in DRESS_GOLDEN:
		var a := _houses(s)
		var b := _houses(s)
		var lines := PackedStringArray()
		for i in a.size():
			var one := _digest(Dress.plan(a[i], s, i))
			t.eq(_digest(Dress.plan(b[i], s, i)), one, "seed %d house %d: dressed twice the same" % [s, i])
			lines.append(one)
		var got := "%08x" % ("\n".join(lines)).hash()
		if RECORD:
			print("DRESS %d: \"%s\"," % [s, got])
		else:
			t.eq(got, str(DRESS_GOLDEN[s]), "seed %d: the dressing as recorded" % s)
	# The dressing's own stream: the same house under another id is dressed otherwise (the stream is the house's).
	var h := _houses(8143)[3]
	t.check(_digest(Dress.plan(h, 8143, 3)) != _digest(Dress.plan(h, 8143, 4)), "the dressing draws from its own stream for each house")

func test_every_piece_is_drawn_in_its_box_and_every_room_furnished(t: T) -> void:
	# The models' sizes as recorded are the files'.
	for model: StringName in Dress.MODELS:
		var mesh: Mesh = Dress.model_mesh(model)[0]
		var want: Vector3 = (Dress.MODELS[model] as Array)[1]
		if t.check(mesh != null, "%s: its model loads" % model):
			var aabb := mesh.get_aabb()
			t.check((aabb.size - want).length() < 0.02, "%s: built %s, recorded %s" % [model, str(aabb.size), str(want)])
			t.check(absf(aabb.position.y) < 0.01 and absf(aabb.get_center().x) < 0.01 and absf(aabb.get_center().z) < 0.01, "%s: stands on 0, centred" % model)
	var outside: Array[String] = []
	var bare: Array[String] = []
	var undressed: Array[String] = []
	var types := {}
	var rooms := 0
	var models := 0
	for s in _seeds(t, 40, 300):
		var houses := _houses(s)
		for i in houses.size():
			var h := houses[i]
			if not t.check(h.homes(), "seed %d house %d is a home" % [s, i]):
				continue
			types[h.plan.type] = true
			var rows := Dress.plan(h, s, i)
			var dressed := {}
			for row in rows:
				dressed["%d %s" % [row.level, row.room]] = true
			for k in h.furniture.size():
				var piece: Dictionary = h.furniture[k]
				var row: Dictionary = rows[k] if k < rows.size() else {}
				if row.is_empty() or int(row.piece) != k or not [&"model", &"built"].has(row.what):
					undressed.append("seed %d house %d %s" % [s, i, piece.kind])
					continue
				if row.what == &"model":
					models += 1
				var box: AABB = piece.box
				var drawn: AABB = row.box
				var room := box.grow(0.005)
				room.size.y += float(ABOVE.get(piece.kind, 0.0))
				if not room.encloses(drawn) or drawn.size.x < box.size.x * 0.5 and drawn.size.z < box.size.z * 0.5 or drawn.size.y < box.size.y * 0.5:
					outside.append("seed %d house %d %s: drawn %s, its box %s" % [s, i, piece.kind, str(drawn), str(box)])
			for level in h.rooms_by_level.size():
				for room: Dictionary in h.rooms_by_level[level]:
					rooms += 1
					if not dressed.has("%d %s" % [level, room.name]):
						bare.append("seed %d house %d (%s) %s" % [s, i, h.plan.type, room.name])
	t.eq(types.size(), 6, "all six house types were dressed")
	t.check(undressed.is_empty(), "every piece of furniture is dressed: %s" % str(undressed.slice(0, 6)))
	t.check(outside.is_empty(), "every piece is drawn inside its rules box, filling most of it: %s" % str(outside.slice(0, 6)))
	t.check(bare.is_empty(), "every room of every house gets something (%d rooms): %s" % [rooms, str(bare.slice(0, 6))])
	t.note("%d rooms, %d modelled pieces" % [rooms, models])

func test_nothing_extra_stands_in_a_doorway_a_hide_or_its_view(t: T) -> void:
	var in_door: Array[String] = []
	var in_thing: Array[String] = []
	var in_view: Array[String] = []
	var counts := {}
	for s in _seeds(t, 40, 300):
		var houses := _houses(s)
		for i in houses.size():
			var h := houses[i]
			var rows := Dress.plan(h, s, i)
			var extras := _extras(rows)
			for e in extras:
				counts[e.kind] = int(counts.get(e.kind, 0)) + 1
			var approaches := Clear.approaches(h, Homes.APPROACH)
			var leaf: Dictionary = Clear.front_leaf(h)
			for e in extras:
				var b: AABB = e.box
				var flat := Rect2(b.position.x, b.position.z, b.size.x, b.size.z).grow(-0.002)
				for a: Dictionary in approaches:
					if int(a.level) == int(e.level) and flat.intersects(a.rect):
						in_door.append("seed %d house %d %s by the %s %s" % [s, i, e.kind, a.kind, a.name])
				if int(e.level) == 0 and not leaf.is_empty() and flat.intersects(leaf.rest):
					in_door.append("seed %d house %d %s in the front door's leaf" % [s, i, e.kind])
				for st: House.Stair in h.stairs:
					var lo := minf(st.from.y, st.to.y)
					if b.position.y < st.to.y and b.end.y > lo and flat.intersects(st.shaft):
						in_thing.append("seed %d house %d %s on a stair" % [s, i, e.kind])
				for piece: Dictionary in h.furniture:
					if (piece.box as AABB).intersects(b.grow(-0.002)):
						in_thing.append("seed %d house %d %s in the %s" % [s, i, e.kind, piece.kind])
				# A hide's view: rays from its eyes out of its open side, every 10 degrees within its limits, 2 m long.
				for k in h.hides.size():
					var row: Dictionary = h.hides[k]
					if int(row.level) != int(e.level):
						continue
					var eye := HidesView.eye_local(h, k)
					var d := HidesView.out_local(h, k)
					var half := float(HidesView.VIEW_HALF[StringName(row.kind)])
					var a := -half
					while a <= half + 0.01:
						var ray := d.rotated(Vector3.UP, deg_to_rad(a))
						for pitch: float in [-HidesView.PITCH, 0.0, HidesView.PITCH]:
							var dir := (ray * cos(pitch) + Vector3.UP * sin(pitch)).normalized()
							if b.intersects_segment(eye, eye + dir * 2.0) != null:
								in_view.append("seed %d house %d %s in the view of the %s hide" % [s, i, e.kind, row.kind])
						a += 10.0
	t.check(in_door.is_empty(), "nothing extra in a doorway's clear approach or the front door's leaf: %s" % str(in_door.slice(0, 6)))
	t.check(in_thing.is_empty(), "nothing extra on a stair or in a piece of furniture: %s" % str(in_thing.slice(0, 6)))
	t.check(in_view.is_empty(), "nothing extra across a hide's view: %s" % str(in_view.slice(0, 6)))
	for kind: StringName in [&"picture", &"rug", &"crockery", &"pram"]:
		t.check(int(counts.get(kind, 0)) > 0, "some %s placed (%d)" % [kind, int(counts.get(kind, 0))])
	t.note("extras: %s" % str(counts))

func test_a_hides_model_leaves_its_camera_a_view_out(t: T) -> void:
	var blocked: Array[String] = []
	var tried := {}
	for s in _seeds(t, 6, 40):
		var houses := _houses(s)
		for i in houses.size():
			var h := houses[i]
			var rows := Dress.plan(h, s, i)
			var k := -1
			for p in h.furniture.size():
				var row: Dictionary = rows[p]
				if not Hides.WARD_SPEC.has(StringName(row.get("hide", ""))):
					continue
				k += 1
				if row.what != &"model":
					continue
				var kind := StringName(h.hides[k].kind)
				tried[kind] = int(tried.get(kind, 0)) + 1
				var faces := _faces(row)
				var eye := HidesView.eye_local(h, k)
				var d := HidesView.out_local(h, k)
				var half := float(HidesView.VIEW_HALF[kind])
				var far := float(HidesView.INSET[kind]) + 0.25
				# Out of the open side: straight, and half way to each limit; nothing of the piece round the eyes.
				for a: float in [-half * 0.5, 0.0, half * 0.5]:
					var dir := d.rotated(Vector3.UP, deg_to_rad(a))
					var reach := far / maxf(0.2, cos(deg_to_rad(a)))
					if _hits(faces, eye, eye + dir * reach):
						blocked.append("seed %d house %d %s hide %d (%s) at %d degrees" % [s, i, kind, k, h.plan.type, int(a)])
	for kind: StringName in [&"bed", &"table", &"bath"]:
		t.check(int(tried.get(kind, 0)) > 0, "some %s hide drawn by its model (%d)" % [kind, int(tried.get(kind, 0))])
	var total := 0
	for kind: StringName in tried:
		total += int(tried[kind])
	t.check(blocked.is_empty(), "every modelled hide leaves its camera a clear view out (%d tried): %s" % [total, str(blocked.slice(0, 6))])

## A model's triangles where its row puts them (local to its house).
static func _faces(row: Dictionary) -> PackedVector3Array:
	var mesh: Mesh = Dress.model_mesh(StringName(row.model))[0]
	var xf := Transform3D(Basis(Vector3.UP, float(row.yaw)).scaled_local(row.scale), row.at)
	var out := mesh.get_faces()
	for n in out.size():
		out[n] = xf * out[n]
	return out

static func _hits(faces: PackedVector3Array, a: Vector3, b: Vector3) -> bool:
	var seg := AABB(a, Vector3.ZERO).expand(b).grow(0.01)
	for n in range(0, faces.size(), 3):
		var tri := AABB(faces[n], Vector3.ZERO).expand(faces[n + 1]).expand(faces[n + 2])
		if not tri.intersects(seg):
			continue
		if Geometry3D.segment_intersects_triangle(a, b, faces[n], faces[n + 1], faces[n + 2]) != null:
			return true
	return false

func test_nothing_added_crosses_the_arms_routes(t: T) -> void:
	var crossed: Array[String] = []
	var routes := 0
	for s in _seeds(t, 2, 12):
		var houses := _houses(s)
		for i in houses.size():
			var h := houses[i]
			var rows := Dress.plan(h, s, i)
			# What the dressing adds that the rules do not know: the extras, and each model's part above its rules box.
			var added: Array[Dictionary] = []
			for row in rows:
				var b: AABB = row.box
				if int(row.piece) < 0:
					added.append({"kind": row.kind, "box": b})
				else:
					var rules: AABB = (h.furniture[int(row.piece)] as Dictionary).box
					if b.end.y > rules.end.y + 0.005:
						added.append({"kind": "%s top" % row.kind, "box": AABB(Vector3(b.position.x, rules.end.y, b.position.z), Vector3(b.size.x, b.end.y - rules.end.y, b.size.z))})
			for o: Dictionary in h.openings():
				var arm := h.make_arm_at(o)
				var level := int(o.get("storey", 0))
				var targets: Array[Vector3] = []
				for p: Vector3 in h.probes_for(o).values():
					targets.append(p)
				for k in h.hides.size():
					if int(h.hides[k].level) == level:
						targets.append(HidesView.eye_local(h, k))
				for target in targets:
					var route := arm._find_route(target)
					if route.is_empty():
						continue
					routes += 1
					for n in range(1, route.size()):
						for a: Dictionary in added:
							if ArmSearch._hits_box(route[n - 1], route[n], a.box, ArmSearch.PALM_RADIUS):
								crossed.append("seed %d house %d (%s) opening %d: the %s" % [s, i, h.plan.type, int(o.index), a.kind])
	t.check(routes > 50, "the arm's routes were walked (%d)" % routes)
	t.check(crossed.is_empty(), "nothing the dressing adds crosses the arm's routes: %s" % str(crossed.slice(0, 6)))
