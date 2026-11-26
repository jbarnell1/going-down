# WH2: in the Hanging Ward's homes (the run flag ward_homes, off in every build) no furniture stands in a doorway. The
# North Star: "Furniture is solid. Chairs, cabinets and beds block movement"; "Every house must be reachable from the
# floor seed"; "Everything about a floor comes from one seed, identical for every player". Every opening a walker uses
# keeps a clear approach on each side (sim/ward/homes.gd APPROACH; the measure is tests/ward_home_clear.gd, worked out
# again from the built house). Checked here:
#   1. the numbers the homes copy from the walk model, the house and the screen agree with them;
#   2. over the homes tests' seeds no opening (inner doorway, front door, the lift's doorway, a stair's foot or head) has
#      a piece of furniture, a hide, a cupboard under a stair or the front door's open leaf in its clear approach, and no
#      piece stands where that leaf stands open or swings;
#   3. a moved piece stays in its own room, at another of its listed places or against a wall, off every other piece
#      and stair; nothing is dropped,
#      so every home keeps its kitchen, bed, bathroom pieces and its hides;
#   4. a home whose pieces were all clear as drawn is built as drawn (the seed's stream is not moved);
#   5. nobody is stranded with the homes and the stairs' rule on, the bridge down and up, on seeds where pieces moved;
#   6. with the homes off nothing changed (the recorded digests).
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Homes = preload("res://sim/ward/homes.gd")
const Clear = preload("res://tests/ward_home_clear.gd")
const Digest = preload("res://tests/ward_digest.gd")
const HomesProps = preload("res://tests/prop_ward_homes.gd")
const Reach = preload("res://tests/prop_ward_reach.gd")
const Dress = preload("res://client/ward/dress.gd")

static func _seeds(t: T, quick: int, full: int) -> Array[int]:
	var out: Array[int] = []
	for k in (quick if t.quick else full):
		out.append(1 + k * 7919)
	return out

func test_the_copied_numbers_agree(t: T) -> void:
	t.eq(Homes.WALKER, Ward.WALK_CLEARANCE, "a walker's body is the walk model's (sim/ward/state.gd WALK_CLEARANCE)")
	t.check(Homes.APPROACH >= Homes.WALKER * 2.0, "a clear approach is at least one walker's depth (%.2f m)" % Homes.APPROACH)
	t.eq(Homes.WALL, House.WALL_THICKNESS, "the wall's thickness is the house's")
	t.eq(Homes.STAIR, House.STAIR_WIDTH, "a stair's width is the house's")
	t.check(is_equal_approx(Homes.LIFT_GATE, Ward.GATE.x), "the lift's doorway is the walk model's gate (%.3f, %.3f)" % [Homes.LIFT_GATE, Ward.GATE.x])
	t.eq(Homes.front_leaf(0.0, 1.0, -1).hinge, Vector2(-0.49, 0.0), "the leaf hangs a centimetre in from its jamb, as drawn (client/ward/dress.gd door_leaf)")
	t.eq(Dress.door_open(-1), Dress.DOOR_SWING, "a leaf on the left jamb opens as every house's door did")
	t.eq(Dress.door_open(1), -Dress.DOOR_SWING, "and on the right jamb the other way, also into the house")

func test_no_opening_has_anything_in_its_way(t: T) -> void:
	var blocked: Array[String] = []
	var in_leaf: Array[String] = []
	var openings := 0
	var kinds := {}
	for s in _seeds(t, 40, 500):
		var w := Ward.new(s, Clear.options())
		for i in w.houses.size():
			var h := w.houses[i]
			for a: Dictionary in Clear.approaches(h, Homes.APPROACH):
				openings += 1
				kinds[a.kind] = true
			for b: Dictionary in Clear.blocked(h):
				blocked.append("seed %d house %d (%s) %s %s storey %d: %s" % [s, i, h.plan.type, b.opening, b.name, b.level, b.piece])
			for k: StringName in Clear.in_leaf(h):
				in_leaf.append("seed %d house %d (%s): %s" % [s, i, h.plan.type, k])
	t.check(blocked.is_empty(), "no piece or open leaf in any of %d openings' clear approaches: %s" % [openings, str(blocked.slice(0, 8))])
	t.check(in_leaf.is_empty(), "no piece where a front door's leaf stands open or swings: %s" % str(in_leaf.slice(0, 8)))
	for k: StringName in [&"inner", &"front", &"lift", &"stair_foot", &"stair_head"]:
		t.check(kinds.has(k), "openings of the kind %s were checked" % k)

## The lift's house: its front door's leaf, on the left jamb, would stand open across the parlour's doorway in every
## seed (the fault seen on 26 Nov); the measure sees that, and the plan hangs it on the right jamb.
func test_the_lift_houses_leaf_is_out_of_the_parlours_doorway(t: T) -> void:
	for s in _seeds(t, 4, 40):
		var h := Ward.new(s, Clear.options()).houses[0]
		t.eq(int(h.plan.door.hinge), 1, "seed %d: the lift's house hangs its front door on the right jamb" % s)
		var left := Homes.front_leaf(h.door.get_center().x, h.door.size.x, -1)
		var across := false
		for a: Dictionary in Clear.approaches(h, Homes.APPROACH):
			if a.kind == &"inner" and Clear._meets(a.rect, left.rest):
				across = true
		t.check(across, "seed %d: on the left jamb it would stand in a doorway's way (the measure sees the fault)" % s)

func test_moved_pieces_stay_in_their_rooms_and_nothing_is_dropped(t: T) -> void:
	var bad: Array[String] = []
	var moved := 0
	var houses_moved := 0
	for s in _seeds(t, 40, 500):
		var w := Ward.new(s, Clear.options())
		for i in w.houses.size():
			var h := w.houses[i]
			if not (h.plan.dropped as Array).is_empty():
				bad.append("seed %d house %d (%s): dropped %s" % [s, i, h.plan.type, str(h.plan.dropped)])
			houses_moved += 0 if (h.plan.moved as Array).is_empty() else 1
			for m: Dictionary in h.plan.moved:
				moved += 1
				var r: Rect2 = m.to
				var level := int(m.level)
				var room := Rect2()
				for row: Dictionary in h.rooms_by_level[level]:
					if row.name == m.room:
						room = row.rect
				if not room.grow(-House.WALL_THICKNESS * 0.5).encloses(r):
					bad.append("seed %d house %d: %s left its room %s" % [s, i, m.kind, m.room])
				var inner := room.grow(-Homes.WALL_GAP - 0.001)
				var on_wall := r.position.x <= inner.position.x + 0.001 or r.end.x >= inner.end.x - 0.001 \
					or r.position.y <= inner.position.y + 0.001 or r.end.y >= inner.end.y - 0.001
				var listed := false
				for f: Dictionary in h.furniture:
					var b: AABB = f.box
					var fr := Rect2(b.position.x, b.position.z, b.size.x, b.size.z)
					if int(f.level) == level and f.kind == m.kind and fr.is_equal_approx(r):
						listed = true
					elif int(f.level) == level and Clear._meets(fr, r):
						bad.append("seed %d house %d: %s moved onto %s" % [s, i, m.kind, f.kind])
				if not listed:
					bad.append("seed %d house %d: %s is not where it was moved to" % [s, i, m.kind])
				# Moved to another of its listed places, or else against a wall of its room.
				if not on_wall and not bool(m.listed):
					bad.append("seed %d house %d: %s moved off the walls" % [s, i, m.kind])
				for st: House.Stair in h.stairs:
					var foot := int(roundf(st.from.y / House.HEIGHT))
					if (level == foot or level == foot + 1) and Clear._meets(st.shaft, r):
						bad.append("seed %d house %d: %s moved onto a stair" % [s, i, m.kind])
			# Every piece the data lists is there: the kitchen's, the beds, the bathroom's and every hide.
			var listed_count := 0
			for storey: Dictionary in h.plan.storeys:
				listed_count += (storey.furniture as Array).size()
			var data_count := 0
			for f: Dictionary in h.furniture:
				data_count += 0 if f.kind == &"under_stair" else 1
			if listed_count != data_count:
				bad.append("seed %d house %d: %d pieces planned, %d built" % [s, i, listed_count, data_count])
	t.check(bad.is_empty(), "every moved piece stays against a wall of its own room, on nothing, and nothing is dropped: %s" % str(bad.slice(0, 8)))
	t.check(moved > 0, "some pieces were moved (%d in %d houses)" % [moved, houses_moved])
	t.note("%d pieces moved in %d houses" % [moved, houses_moved])

## A home whose pieces all stood clear where the seed drew them is built exactly as drawn: the same draws, in the same
## order, so every home without a fault is what it was before WH2.
func test_a_home_without_a_fault_is_as_drawn(t: T) -> void:
	var differ: Array[String] = []
	var unmoved := 0
	for s in _seeds(t, 20, 200):
		var layout := Layout.generate(s, Clear.options())
		for site: Dictionary in layout.houses:
			var plan := Homes.resolve(site, s)
			if not (plan.moved as Array).is_empty():
				continue
			unmoved += 1
			var drawn := _drawn(site, s)
			var built: Array = []
			for storey: Dictionary in plan.storeys:
				for f: Dictionary in storey.furniture:
					built.append(f.rect)
			if str(built) != str(drawn):
				differ.append("seed %d house %d" % [s, int(site.id)])
	t.check(unmoved > 0 and differ.is_empty(), "%d homes with nothing moved are built as drawn: %s" % [unmoved, str(differ.slice(0, 8))])

## The places the seed draws for a house's furniture, by the draws resolve makes (the variant, the front door, each
## storey's doors, then each piece), with nothing moved.
static func _drawn(site: Dictionary, ward_seed: int) -> Array:
	var t := Homes.type_for_style(str(site.style))
	var rng := RandomNumberGenerator.new()
	rng.seed = ("ward_homes:%d:%d" % [ward_seed, int(site.id)]).hash()
	var allowed := Homes._variants_for(t, str(site.style))
	var v: Dictionary = allowed[rng.randi_range(0, allowed.size() - 1)]
	var w := float(t.w)
	var mirror := bool(site.get("mirror", false)) and int(site.id) != 0
	var mx := func(x: float) -> float: return (w * 0.5 - x) if mirror else (x - w * 0.5)
	var door_spec: Dictionary = v.door if v.has("door") else Homes._base_of(t, v).door
	rng.randf_range(float(door_spec.at[0]), float(door_spec.at[1]))
	var out: Array = []
	for raw: Dictionary in Homes._variant_storeys(t, v):
		for door: Dictionary in raw.get("doors", []):
			rng.randf_range(float(door.at[0]), float(door.at[1]))
		for piece: Dictionary in raw.get("furniture", []):
			var spots: Array = piece.at
			out.append(Homes._spot(spots[rng.randi_range(0, spots.size() - 1)], mx))
	return out

## Nobody is stranded (tests/prop_ward_reach.gd stranded) with the homes and the stairs' rule on, the bridge down and
## up, on the first seeds where a piece was moved.
func test_nobody_is_stranded_where_pieces_moved(t: T) -> void:
	var want := 2 if t.quick else 8
	var seeds: Array[int] = []
	var k := 0
	while seeds.size() < want and k < 400:
		var s := 1 + k * 7919
		k += 1
		for site: Dictionary in Layout.generate(s, Clear.options()).houses:
			if not (Homes.resolve(site, s).moved as Array).is_empty():
				seeds.append(s)
				break
	t.eq(seeds.size(), want, "enough seeds where a piece moved")
	var opts := Clear.options()
	opts["stairs"] = 1
	for s in seeds:
		for lowered: bool in [true, false]:
			var bad := Reach.stranded(s, lowered, true, false, opts)
			t.check(bad.is_empty(), "seed %d bridge %s: no reachable spot is cut off from the lift (%d)" % [s, "down" if lowered else "up", bad.size()])
	t.note("seeds %s" % str(seeds))

func test_with_the_homes_off_nothing_changed(t: T) -> void:
	for s: int in HomesProps.SEEDS:
		t.eq(Digest.line(s), HomesProps.BEFORE_FIXED[s], "seed %d: today's fixed Ward as recorded" % s)
		t.eq(Digest.line(s, Layout.options(null)), HomesProps.BEFORE_GENERATED[s], "seed %d: the seeded layout without the homes as recorded" % s)
		for h in Ward.new(s, Layout.options(null)).houses:
			t.check(not h.homes() and h.plan.is_empty(), "seed %d: no house has a plan without the homes" % s)
