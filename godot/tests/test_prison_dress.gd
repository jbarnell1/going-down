extends RefCounted
## LA3: the Prison cells' dressing (client/prison_dress.gd), looks only. Every bunk has its thin mattress, pillow and
## folded blanket inside its own footprint; the wall pieces stand at most 15 cm off their walls and clear of the cabinet
## and the floor in front of it, the doorway and the bunk's open side; nothing is a light; the cabinet, the bunk, the
## boards and every light are where they were.

const T = preload("res://tests/t.gd")
const PrisonView = preload("res://client/prison_view.gd")
const PrisonDress = preload("res://client/prison_dress.gd")
const PixelFont = preload("res://client/pixel_font.gd")

static func _prison() -> Level:
	var level := Level.new()
	level.build(PrisonView.plain_plan(), "prison")
	return level

static func _dressing(lv: Level) -> RefCounted:
	return lv.get_meta(&"prison_dressing")

func test_every_bunk_is_made(t: T) -> void:
	var lv := _prison()
	var d := _dressing(lv)
	var bunks: Array[Rect2] = d.get("bunks")
	t.eq(bunks.size(), 8, "eight cells dressed")
	for i in bunks.size():
		var got := {}
		for r: Dictionary in d.get("records"):
			if int(r.cell) != i + 1 or not str(r.kind) in ["mattress", "pillow", "blanket"]:
				continue
			var box: AABB = r.aabb
			got[r.kind] = true
			t.check(bunks[i].grow(0.001).encloses(Rect2(box.position.x, box.position.z, box.size.x, box.size.z)) and box.position.y >= 0.459,
				"cell %d: the %s lies on the bunk, inside its footprint (%s)" % [i + 1, r.kind, box])
			t.check(box.end.y <= 0.7, "cell %d: the %s is low on the bunk (top %.3f m)" % [i + 1, r.kind, box.end.y])
		t.eq(got.size(), 3, "cell %d: a mattress, a pillow and a blanket" % (i + 1))
	lv.free()

func test_the_wall_pieces_stay_on_the_walls_and_clear(t: T) -> void:
	var lv := _prison()
	var d := _dressing(lv)
	var bunks: Array[Rect2] = d.get("bunks")
	var cabinets: Array[AABB] = d.get("cabinets")
	var doors: Array[AABB] = []
	for dd: Dictionary in lv.plan.doors:
		var a := lv.cell_center(0, int(dd.ax), int(dd.ay))
		var b := lv.cell_center(0, int(dd.bx), int(dd.by))
		var m := (a + b) * 0.5
		var across := Vector3(absf(b.z - a.z), 0, absf(b.x - a.x)).normalized()
		var thru := (b - a).normalized().abs()
		doors.append(AABB(m - across * (Level.DOOR_W * 0.5) - thru * 0.5, across * Level.DOOR_W + thru + Vector3(0, Level.DOOR_H, 0)))
	var bad := PackedStringArray()
	var kinds := {}
	for r: Dictionary in d.get("records"):
		var n: Vector3 = r.n
		if n == Vector3.ZERO:
			continue
		var box: AABB = r.aabb
		kinds[r.kind] = true
		var face: Vector3 = r.face
		var deep := -INF
		var shallow := INF
		for k in 8:
			var p := box.position + Vector3(box.size.x * float(k & 1), box.size.y * float((k >> 1) & 1), box.size.z * float((k >> 2) & 1))
			deep = maxf(deep, (p - face).dot(n))
			shallow = minf(shallow, (p - face).dot(n))
		if deep > PrisonDress.PROUD_MAX + 0.001 or shallow < -0.002:
			bad.append("%s in cell %d stands %.3f to %.3f m off its wall" % [r.kind, r.cell, shallow, deep])
		if box.position.y < 0.3:
			bad.append("%s in cell %d is down at the floor" % [r.kind, r.cell])
		var c := int(r.cell) - 1
		if box.intersects(cabinets[c]):
			bad.append("%s in cell %d meets the cabinet or the floor in front of it" % [r.kind, r.cell])
		# Over the bunk below 1.3 m only what lies flat on the wall (the scratches).
		var over := AABB(Vector3(bunks[c].position.x, 0.46, bunks[c].position.y), Vector3(bunks[c].size.x, 0.84, bunks[c].size.y))
		if box.intersects(over) and deep > 0.01:
			bad.append("%s in cell %d is over the bunk" % [r.kind, r.cell])
		for o in doors:
			if box.intersects(o):
				bad.append("%s in cell %d meets a doorway" % [r.kind, r.cell])
	t.check(bad.is_empty(), "%d: %s" % [bad.size(), "; ".join(bad.slice(0, 5))])
	for k: String in ["shelf", "mug", "book", "mirror", "notice", "towel", "conduit", "tally"]:
		t.check(kinds.has(k), "the cells have a %s" % k)
	lv.free()

## No light added and nothing else moved: built without the cells' dressing, the lights, the cabinets, the bunks'
## middles, the boards and every mesh but the cells' own are the same.
func test_no_light_and_nothing_else_moves(t: T) -> void:
	var on := _prison()
	PrisonDress.off = true
	var bare := _prison()
	PrisonDress.off = false
	var sums: Array[String] = []
	for lv: Level in [on, bare]:
		var view: Variant = lv.get_meta(&"prison")
		# The bedding is the dressing's own (drawn in the prison's cloth materials).
		var bedding: Array = [view.get("_mattress"), view.get("_pillow"), view.get("_blanket")]
		var parts := PackedStringArray([str(view.get("cabinet_centres")), str(view.get("bunk_centres")), str(view.get("window_centres"))])
		for c in lv.get_children():
			if c is Light3D:
				parts.append("%s %s %s %.3f %.3f" % ["light" if String(c.name).begins_with("@") else String(c.name), c.get_class(), (c as Light3D).position, (c as Light3D).light_energy, (c as Light3D).get("omni_range") if c is OmniLight3D else 0.0])
			elif c is MeshInstance3D and not String(c.name).begins_with("Prison_") and not (c as MeshInstance3D).material_override in bedding:
				parts.append("%s %s %s" % ["mesh" if String(c.name).begins_with("@") else String(c.name), (c as MeshInstance3D).position, (c as MeshInstance3D).get_aabb()])
		sums.append("\n".join(parts))
	var a := sums[0].split("
")
	var b := sums[1].split("
")
	var diff := PackedStringArray()
	for i in maxi(a.size(), b.size()):
		if i >= a.size() or i >= b.size() or a[i] != b[i]:
			diff.append("%s / %s" % [a[i] if i < a.size() else "-", b[i] if i < b.size() else "-"])
	t.check(diff.is_empty(), "%s; the lights, the cabinets, the bunks and the other meshes are the same with and without the cells' dressing" % "; ".join(diff.slice(0, 3)))
	var extra := 0
	for c in on.get_children():
		if String(c.name).begins_with("Prison_cell_"):
			extra += 1
			t.check((c as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and c.get_child_count() == 0, "%s draws only" % c.name)
	t.check(extra > 0 and extra <= 2, "the cells' dressing is %d meshes" % extra)
	on.free()
	bare.free()

func test_the_same_prison_twice_and_a_plain_notice(t: T) -> void:
	var a := _prison()
	var b := _prison()
	t.check(str(_dressing(a).get("records")) == str(_dressing(b).get("records")), "the cells are dressed the same every time")
	a.free()
	b.free()
	var bad := PackedStringArray()
	for s: String in PrisonDress.RULES:
		for w in s.replace(".", " ").split(" ", false):
			if w in ["LOOK", "WATCH", "SEE", "EYE", "EYES", "STARE", "BLINK", "MOVE", "STILL", "SIGHT", "TENANT"]:
				bad.append(s)
		for i in s.length():
			if not PixelFont.known(s[i]):
				bad.append(s)
	t.check(bad.is_empty(), "the notice: %s" % ", ".join(bad))
