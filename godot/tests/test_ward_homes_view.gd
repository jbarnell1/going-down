# WH1: a Ward of homes (the run flag ward_homes) can be walked on a screen: client/ward/view.gd draws each home from
# its rules (sim/ward/house.gd): the walls with their windows cut, the stairs, the inner doorways and every piece of
# furniture as a plain box where the rules have it. Dressing with real props is stage 2. Checked on the view as built.
extends RefCounted

const T = preload("res://tests/t.gd")
const View = preload("res://client/ward/view.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")

static func _view(seed_value: int, layout: Array) -> View:
	var view := View.new(seed_value, Vector3.ZERO, layout)
	view.own_hud = false
	view.own_camera = false
	view.own_environment = false
	(Engine.get_main_loop() as SceneTree).root.add_child(view)
	return view

## Every solid box drawn under a house's root, in the root's frame.
static func _solids(root: Node3D) -> Array[AABB]:
	var out: Array[AABB] = []
	for child: Node in root.get_children():
		if child is StaticBody3D:
			var shape := (child.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
			var at := (child as Node3D).position
			out.append(AABB(at - shape.size * 0.5, shape.size))
	return out

func test_the_homes_are_drawn_where_the_rules_have_them(t: T) -> void:
	var opts := Layout.options(null)
	opts["homes"] = 1
	for seed_value: int in [8143, 26]:
		var view := _view(seed_value, Layout.to_wire(opts))
		t.eq(view.houses.size(), 8, "seed %d: eight houses drawn" % seed_value)
		var missing: Array[String] = []
		var through: Array[String] = []
		for house: Dictionary in view.houses:
			var fixture: House = house.fixture
			if not t.check(fixture.homes(), "seed %d: the view's house is a home" % seed_value):
				continue
			var solids := _solids(house.root)
			for piece: Dictionary in fixture.furniture:
				var box: AABB = piece.box
				var found := false
				for s in solids:
					if s.position.is_equal_approx(box.position) and s.size.is_equal_approx(box.size):
						found = true
						break
				if not found:
					missing.append("%s %s" % [piece.kind, str(box)])
			# A window is a hole on the screen: nothing drawn solid fills its middle.
			for o: Dictionary in fixture.openings():
				var hole: AABB = o.hole
				if not hole.has_volume():
					continue
				for s in solids:
					if s.has_point(hole.get_center()):
						through.append("%s window %s" % [fixture.plan.type, o.wall])
		t.check(missing.is_empty(), "seed %d: every piece of furniture is drawn as a box where the rules have it: %s" % [seed_value, str(missing.slice(0, 6))])
		t.check(through.is_empty(), "seed %d: every window the hand comes in by is open on the screen: %s" % [seed_value, str(through.slice(0, 6))])
		view.queue_free()
