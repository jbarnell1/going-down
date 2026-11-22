# WH1c: hiding places and inner doors in the Ward's homes (the run flag ward_homes; sim/ward/state.gd, sim/hides.gd).
# The North Star: "Every floor has places to hide, and a view out of each ... Being found follows the same rules as
# before." The approved rule (21 Nov): the hand can find someone in a hide only if the noise that brought it came from
# that hide (they got in fast, or made a noise in it); a player who got in quietly is safe there. Inner doors players
# can shut stop the arm (the design: "Walls, shut doors and the floor obstruct the limb"), and shutting one fast is a
# noise. Driven on the crawling Rigger, as the game's rooms play him.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const WardWire = preload("res://net/ward_wire.gd")
const DT := 0.05

static func _homes() -> Dictionary:
	var o := Layout.options(null)
	o["homes"] = 1
	return o

static func _ward(seed_value: int) -> Ward:
	var w := Ward.new(seed_value, _homes())
	w.crew_size = 4
	w.enable_roam()
	w.leave(0.0)
	return w

## A hide the arm reaches from an opening he can come to: [house, hide], or [-1, -1].
static func _reachable_hide(w: Ward) -> Array:
	for i in range(1, w.houses.size()):
		var h := w.houses[i]
		if w.roam.g.openings_of(i).is_empty():
			continue
		for k in h.hides.size():
			var hide: Dictionary = h.hides[k]
			for o: Dictionary in h.openings():
				if int(o.get("storey", 0)) != int(hide.level) or not h.reachable_areas(o).has(hide.room):
					continue
				var arm := h.make_arm_at(o)
				if not arm._find_route(w.hide_reach_local(i, k)).is_empty():
					return [i, k]
	return [-1, -1]

## Steps the Ward with one hidden player until `seconds` pass or they are taken: [taken, nearest the hand came to the
## hide's search point].
static func _search(w: Ward, id: String, feet: Vector3, house: int, hide: int, from: float, seconds: float) -> Array:
	var now := from
	var taken := false
	var nearest := INF
	var target := w.houses[house].to_world(w.hide_reach_local(house, hide))
	while now < from + seconds and not taken:
		now += DT
		for e in w.step(now, DT, 30.0, {id: {"position": feet, "creep": true}}):
			if e.kind == &"contact" and str(e.get("id", "")) == id:
				taken = true
		if w.arm != null and w.resident_house == house and w.arm.points.size() > 1:
			nearest = minf(nearest, w.houses[house].to_world(w.arm.points[-1]).distance_to(target))
	return [taken, nearest]

func test_a_quiet_hider_is_safe_and_a_heard_one_is_found(t: T) -> void:
	var quiet_safe := 0
	var quiet_tried := 0
	var fast_found := 0
	var fast_tried := 0
	var notes: Array[String] = []
	for seed_value: int in ([8143, 26] if t.quick else [8143, 26, 0, 31827, 1, 2]):
		var w := _ward(seed_value)
		var pick := _reachable_hide(w)
		if pick[0] < 0:
			notes.append("seed %d: no reachable hide" % seed_value)
			continue
		var house: int = pick[0]
		var hide: int = pick[1]
		var h := w.houses[house]
		var box: AABB = h.hides[hide].box
		# Standing at the hide's search point, the player gets in quietly.
		var feet := h.to_world(w.hide_reach_local(house, hide) - Vector3.UP * House.ARM_HEIGHT)
		var events: Array[Dictionary] = []
		t.check(w.toggle_hide("p1", feet, false, 0.05, events) and w.hidden.has("p1"), "seed %d: in quietly, by the %s" % [seed_value, h.hides[hide].kind])
		# A flare comes down by the hide: the hand is brought to it by a noise that is not the hider's.
		w.hear_at(w.hide_feet("p1"), 0.05)
		var r := _search(w, "p1", feet, house, hide, 0.05, 90.0)
		quiet_tried += 1
		if not r[0]:
			quiet_safe += 1
		notes.append("seed %d house %d %s %s: quiet, hand came within %.2f m, taken %s" % [seed_value, house, h.plan.type, h.hides[hide].kind, r[1], r[0]])
		t.check(r[1] < 0.5, "seed %d: the hand came to the hide (%.2f m)" % [seed_value, r[1]])
		# The same, getting in fast: that noise came from the hide.
		var w2 := _ward(seed_value)
		var events2: Array[Dictionary] = []
		w2.toggle_hide("p1", feet, true, 0.05, events2)
		var r2 := _search(w2, "p1", feet, house, hide, 0.05, 90.0)
		fast_tried += 1
		if r2[0]:
			fast_found += 1
		notes.append("seed %d: fast, taken %s (hand within %.2f m)" % [seed_value, r2[0], r2[1]])
		t.check(box.has_volume(), "the hide is a piece of furniture")
	t.check(quiet_tried > 0 and quiet_safe == quiet_tried, "a player who got in quietly is never touched in the hide (%d of %d)" % [quiet_safe, quiet_tried])
	t.check(fast_tried > 0 and fast_found == fast_tried, "a player heard getting in is found there (%d of %d)" % [fast_found, fast_tried])
	for n in notes:
		t.note(n)

func test_out_of_a_hide_by_the_key_or_by_walking_away(t: T) -> void:
	var w := _ward(8143)
	var pick := _reachable_hide(w)
	var h := w.houses[pick[0]]
	var feet := h.to_world(w.hide_reach_local(pick[0], pick[1]) - Vector3.UP * House.ARM_HEIGHT)
	var events: Array[Dictionary] = []
	w.toggle_hide("p1", feet, false, 0.05, events)
	w.toggle_hide("p1", feet, false, 0.1, events)
	t.check(not w.hidden.has("p1"), "the key again gets them out")
	w.toggle_hide("p1", feet, false, 0.15, events)
	w.step(0.2, DT, 30.0, {"p1": {"position": feet + Vector3(2.0, 0, 0), "creep": true}})
	t.check(not w.hidden.has("p1"), "walking away gets them out")
	var far := feet + Vector3(0, 0, 30.0)
	t.check(not w.toggle_hide("p2", far, false, 0.3, events), "no hide far from every home")
	# A hide holds its capacity.
	var cap := int(h.hides[pick[1]].capacity)
	var got := 0
	for n in cap + 1:
		if w.toggle_hide("q%d" % n, feet, false, 0.4, events) and w.hidden.has("q%d" % n) and int(w.hidden["q%d" % n].hide) == pick[1] and int(w.hidden["q%d" % n].house) == pick[0]:
			got += 1
	t.eq(got, cap, "the %s holds %d" % [h.hides[pick[1]].kind, cap])

func test_an_inner_door_shut_stops_walkers_and_shutting_it_fast_is_heard(t: T) -> void:
	var w := _ward(8143)
	var house := -1
	for i in range(1, w.houses.size()):
		if not w.houses[i].inner_doors.is_empty():
			house = i
			break
	var h := w.houses[house]
	var door: Dictionary = h.inner_doors[0]
	var leaf: AABB = door.leaf
	var across := Vector3(0, 0, 0.6) if leaf.size.x > leaf.size.z else Vector3(0.6, 0, 0)
	var a := h.to_world((door.at as Vector3) - across)
	var b := h.to_world((door.at as Vector3) + across)
	a.y = w.footing.walking_height(Vector2(a.x, a.z), a.y, false)
	b.y = a.y
	t.check(w.walk_clear(a, b), "through the open doorway")
	var events: Array[Dictionary] = []
	t.check(w.use_inner_door(house, 0, false, 1.0, events), "shut quietly")
	t.check(not w.walk_clear(a, b), "a shut inner door stops a walker")
	var quiet := events.size()
	t.check(w.use_inner_door(house, 0, false, 1.1, events) and w.walk_clear(a, b), "opened again")
	var loud: Array[Dictionary] = []
	w.use_inner_door(house, 0, true, 1.2, loud)
	t.check(quiet == 1 and loud.size() > 1, "shut quietly it is only the door (%d event); shut fast he hears it (%d)" % [quiet, loud.size()])
	w.use_inner_door(house, 0, false, 1.3, events)
	# Not on a player in the doorway.
	var middle := h.to_world(door.at)
	middle.y = a.y
	t.check(not w.use_inner_door(house, 0, false, 1.4, events, {"p1": {"position": middle}}), "a door does not shut on a player in the doorway")
	# The use key by the door works it.
	var by := h.to_world((door.at as Vector3) - across * 0.8)
	by.y = a.y
	var before := h.inner_open[0]
	w.step(2.0, DT, 30.0, {"p1": {"position": by, "use": true}})
	t.check(h.inner_open[0] != before, "the use key by an inner door works it")

func test_the_block_carries_doors_and_hides_and_a_screen_takes_them(t: T) -> void:
	var w := _ward(8143)
	var house := 1
	while w.houses[house].inner_doors.is_empty():
		house += 1
	var events: Array[Dictionary] = []
	w.use_inner_door(house, 0, false, 1.0, events)
	var pick := _reachable_hide(w)
	var feet := w.houses[pick[0]].to_world(w.hide_reach_local(pick[0], pick[1]) - Vector3.UP * House.ARM_HEIGHT)
	w.toggle_hide("p1", feet, false, 1.0, events)
	var extras := w.extras()
	t.eq(int((extras.inner as Array)[house]), 1, "the shut door is in the block")
	t.eq(extras.hidden, {"p1": [pick[0], pick[1]]}, "and who is hidden where")
	var block := {"collectionAt": 1.0, "departAt": 2.0, "bridgeLowered": false, "phase": "away", "house": -1, "startedAt": 0.0,
		"encounter": "idle", "armPoints": [], "doors": [true, true, true, true, true, true, true, true], "boarded": [], "leftBehind": [],
		"seed": 8143, "caught": [], "native": true, "layout": Layout.to_wire(_homes()), "extras": extras}
	var back := WardWire.decode(WardWire.encode(block))
	t.check(not back.is_empty() and back.has("extras"), "the Ward block with them decodes")
	var screen := Ward.new(8143, Layout.from_wire(back.layout))
	screen.set_inner_doors_wire(back.extras.inner)
	t.eq(screen.houses[house].inner_open[0], 0, "a screen's walk model has the door shut")

func test_flag_off_no_hides_no_inner_doors(t: T) -> void:
	for options: Dictionary in [{}, Layout.options(null)]:
		var w := Ward.new(8143, options)
		w.leave(0.0)
		var events: Array[Dictionary] = []
		var feet := w.houses[1].to_world(Vector3(0, 0, 1.0))
		t.check(not w.toggle_hide("p1", feet, false, 0.1, events) and w.hidden.is_empty() and events.is_empty(), "no hide in today's houses")
		t.check(not w.extras().has("inner") and not w.extras().has("hidden"), "the block is today's")
		var member := {"position": feet}
		t.eq(w.arm_contact("p1", member, 1), w.houses[1].to_local(feet + Vector3.UP * 1.25), "the hand touches a player where it always did")
		for h in w.houses:
			t.check(h.inner_doors.is_empty() and h.hides.is_empty(), "no inner doors or hides")
