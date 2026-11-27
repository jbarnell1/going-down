extends RefCounted
## LA8: while the Reactor's station has power, its side rooms (stores, lockers, office, pumps, closets) read from skirting
## to ceiling. The battens point straight down, so a wall was lit only low down and the ceiling not at all, and the walk
## from the lift takes most of the surfaces' own light away by the west wing: under bright battens the upper walls and
## ceilings fell to near black. Each side room's walls (from 0.6 m up), ceiling and dressing now have their own light
## topped up to what a lit room's reads as (client/station_view.gd _side_fill), and none of it in the cut. Held here from the
## lights the view built and the shaders' own terms (tests/station_light.gd), headless:
##   - with the power on, in every side room: the walls at 1.5, 2.5 and 3.0 m and the ceiling are lit to levels that read
##     on screen (see HOLD), no brighter than the switch room's, a wall at 2.5 m is not far below the same wall at 1.5 m,
##     the light at 2.5 m is not below the light at 1.0 m, an end wall is not far below a side wall, and the darkest wall
##     cell and ceiling cell are not black either; and the same measures on the station as it was fail (the fault);
##   - with the power cut, every side room is exactly as dark as it was (today's numbers recorded below), and the fuse
##     spots, the floor and the skirting are untouched with the power on as well;
##   - the fill follows the power and the level's blink on the battens' own path: it is never on when they are dark;
##   - no light is added and the lamps per mesh stay within the cap; only the side rooms' cells carry any fill (the hall,
##     gallery, landing, crawl and switch room are as they were), and no other floor's materials carry any;
##   - the side rooms' dressing lights up with the room, and goes with the power.

const T = preload("res://tests/t.gd")
const L = preload("res://tests/station_light.gd")
const Station = preload("res://sim/station.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const View = preload("res://client/station_view.gd")
const Rooms = preload("res://client/station_rooms.gd")
const Pairs = preload("res://tests/test_light_pairs.gd")
const Clinic = preload("res://sim/clinic.gd")
const AnnexPlan = preload("res://sim/annex.gd")
const Playroom = preload("res://sim/playroom.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Orientation = preload("res://sim/orientation.gd")
const PrisonView = preload("res://client/prison_view.gd")

const SIDE: Array[String] = ["stores", "lockers", "office", "pumps", "closet"]
## What is held with the power on, in every side room: [measure, least, most]. Linear brightness as tests/station_light.gd
## works it out (the lamps' light with the renderer's pi). Not the design's numbers (it gives none): LA8's, set from real-
## window pictures of every side room, where these levels read on screen at 40 or more (of 255) in the top third of the
## frame and 50 or more in the middle third, as the switch room (judged fair) does; its walls are about 0.27 here and its
## ceiling 0.15, the caps below, so no side room is lit brighter than it. Before LA8 the side rooms' walls at 2.5 m were
## 0.02 to 0.11 and their ceilings 0.01 to 0.09.
const HOLD: Array = [
	["wall15", 0.14, 0.27],        # every wall at 1.5 m
	["wall25", 0.15, 0.27],        # every wall at 2.5 m
	["wall30", 0.13, 0.27],        # every wall at 3.0 m, just under the ceiling
	["ceiling", 0.12, 0.17],       # the ceiling: reads as one, no brighter than the switch room's
	["worst25", 0.11, 0.27],       # the darkest wall cell at 2.5 m: no far corner vanishes
	["worst_ceiling", 0.075, 0.17],  # the darkest ceiling cell
	["up", 0.85, 1.4],             # every wall at 2.5 m over 1.5 m (both bare concrete): no dark top half
	["light_up", 1.0, 4.0],        # the light on the walls at 2.5 m over 1.0 m
	["end_side", 0.7, 3.0],        # an end wall over a side wall at 2.5 m: no dark end wall
]
## Today's numbers with the power cut, before LA8 (the station with no fill, .local/tmp/la8_record.gd): per seed and
## kind, the mean over its rooms of every wall at 0.5, 1.0, 1.5, 2.5 and 3.0 m, the floor and the ceiling.
const CUT_BEFORE := {
	"alpha/stores": [0.000474, 0.000620, 0.001696, 0.001985, 0.001898, 0.004126, 0.003642],
	"alpha/office": [0.000922, 0.001349, 0.004439, 0.007217, 0.006091, 0.005318, 0.005077],
	"alpha/closet": [0.000062, 0.000062, 0.000140, 0.000140, 0.000140, 0.000119, 0.000092],
	"alpha/lockers": [0.000080, 0.000094, 0.000253, 0.000300, 0.000286, 0.005789, 0.005059],
	"beta/lockers": [0.000780, 0.001136, 0.003725, 0.006041, 0.005102, 0.004308, 0.004080],
	"beta/closet": [0.000060, 0.000060, 0.000135, 0.000135, 0.000135, 0.000115, 0.000089],
	"beta/stores": [0.000749, 0.000978, 0.002657, 0.003089, 0.002960, 0.006512, 0.005731],
	"beta/pumps": [0.001369, 0.002031, 0.006728, 0.010961, 0.009252, 0.008809, 0.008417],
}
## A recorded number is matched to within this (the record's own rounding).
const CUT_HAIR := 0.0000006

func _seeds(t: T) -> Array[String]:
	if t.quick:
		return ["alpha", "beta"]
	return ["alpha", "beta", "night-1", "la8-0", "la8-1", "la8-3", "la8-5"]

static func _level(sd: String) -> Level:
	var fp := Station.generate_station(sd, 7)
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _view(level: Level) -> Node3D:
	return level.get_meta(&"station")

static func _power(level: Level, p: int) -> void:
	_view(level).call(&"set_power", p)
	_view(level).call(&"_apply")

## Every side room's shares on this level now: [{kind, id, shares}].
static func _side_shares(level: Level) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for room in L.rooms(level, SIDE):
		out.append({"kind": room.kind, "id": room.id, "m": L.measure(level, room)})
	for o: Dictionary in out:
		o["shares"] = L.shares(o.m)
	return out

## The checks failed by one room's shares: "share value" strings.
static func _failed(sh: Dictionary) -> PackedStringArray:
	var bad := PackedStringArray()
	for h: Array in HOLD:
		var v: float = sh[h[0]]
		if v < float(h[1]) or v > float(h[2]):
			bad.append("%s %.2f (want %.2f to %.2f)" % [h[0], v, h[1], h[2]])
	return bad

# --- 1. power on --------------------------------------------------------------------------------------------------

func test_side_rooms_read_from_skirting_to_ceiling_with_the_power_on(t: T) -> void:
	var kinds := {}
	for sd in _seeds(t):
		var level := _level(sd)
		_power(level, 0)
		for o in _side_shares(level):
			kinds[o.kind] = true
			var bad := _failed(o.shares)
			t.check(bad.is_empty(), "%s %s room %d: %s" % [sd, o.kind, o.id, "; ".join(bad) if not bad.is_empty() else "every share held"])
			var sh: Dictionary = o.shares
			t.note("%s %s %d: wall 1.5 %.3f, 2.5 %.3f, 3.0 %.3f, ceiling %.3f, darkest wall at 2.5 %.3f, darkest ceiling %.3f, floor %.3f; 2.5/1.5 %.2f, light 2.5/1.0 %.2f, end/side %.2f" % [
				sd, o.kind, o.id, sh.wall15, sh.wall25, sh.wall30, sh.ceiling, sh.worst25, sh.worst_ceiling, sh.floor, sh.up, sh.light_up, sh.end_side])
		level.free()
	for k in SIDE:
		t.check(kinds.has(k), "a %s room was measured" % k)

## The same measures on the station as it was (no fill) fail: the fault the checks above hold against is real.
func test_without_the_fill_the_side_rooms_fall_dark(t: T) -> void:
	View.test_break = "fill"
	var rooms := 0
	var failing := 0
	var why := {}
	for sd in _seeds(t):
		var level := _level(sd)
		_power(level, 0)
		for o in _side_shares(level):
			rooms += 1
			var bad := _failed(o.shares)
			failing += int(not bad.is_empty())
			for b in bad:
				why[b.get_slice(" ", 0)] = int(why.get(b.get_slice(" ", 0), 0)) + 1
		level.free()
	View.test_break = ""
	t.note("without the fill %d of %d side rooms fail: %s" % [failing, rooms, why])
	t.check(failing * 2 > rooms, "without the fill most side rooms fall dark (%d of %d)" % [failing, rooms])
	for k: String in ["wall25", "ceiling", "worst25", "light_up"]:
		t.check(why.has(k), "without the fill some room fails %s" % k)

# --- 2. power cut -----------------------------------------------------------------------------------------------

func test_the_cut_is_exactly_as_dark_as_before(t: T) -> void:
	for sd: String in ["alpha", "beta"]:
		var level := _level(sd)
		_power(level, 1)
		var acc := {}
		for room in L.rooms(level, SIDE):
			if not acc.has(room.kind):
				acc[room.kind] = []
			(acc[room.kind] as Array).append(L.measure(level, room))
		for k: String in acc:
			var key := "%s/%s" % [sd, k]
			t.check(CUT_BEFORE.has(key), "%s is recorded" % key)
			if not CUT_BEFORE.has(key):
				continue
			var m := L.mean_of(acc[k])
			var a: Dictionary = m.all
			var got: Array = [a.h05, a.h10, a.h15, a.h25, a.h30, m.floor, m.ceiling]
			var want: Array = CUT_BEFORE[key]
			var worst := 0.0
			for i in got.size():
				worst = maxf(worst, absf(float(got[i]) - float(want[i])))
			t.check(worst <= CUT_HAIR, "%s in the cut: within %.7f of today's numbers (worst %.7f)" % [key, CUT_HAIR, worst])
		# Exactly what the station without the fill gives, spot by spot, and no fill anywhere.
		var view := _view(level)
		t.eq(float(view.get(&"fill_k")), 0.0, "%s: no fill in the cut" % sd)
		for e: Array in view.get(&"_fill_mats"):
			t.eq(float((e[0] as ShaderMaterial).get_shader_parameter(e[1])), 0.0, "%s: %s is 0 on its material in the cut" % [sd, e[1]])
		level.free()
	# Restored: the power-on look again.
	var lv := _level("alpha")
	_power(lv, 1)
	_power(lv, 2)
	var view2 := _view(lv)
	t.eq(float(view2.get(&"fill_k")), 1.0, "restored: the fill is back")
	lv.free()

## With the power on too, the fuse spots' floor and the skirting behind them (below 0.6 m) carry no fill: the fuse is
## drawn and lit as before, against the same floor and skirting.
func test_the_fuse_spots_floor_and_skirting_are_untouched(t: T) -> void:
	for sd in _seeds(t):
		var level := _level(sd)
		_power(level, 0)
		var view := _view(level)
		var spots: Array = (level.plan.get("station", {}) as Dictionary).get("fuse_spots", [])
		if spots.is_empty():
			spots = (Station.generate_station(sd, 7).station as Dictionary)["fuse_spots"]
		var touched := PackedStringArray()
		var walls: Array[ShaderMaterial] = [view.get(&"mat_wall_g"), view.get(&"mat_wall_c")]
		for a: Variant in spots:
			var p: Vector3 = a
			for d: Vector3 in [Vector3.ZERO, Vector3(0.3, 0, 0), Vector3(-0.3, 0, 0), Vector3(0, 0, 0.3), Vector3(0, 0, -0.3)]:
				if float(view.call(&"fill_at", view.get(&"mat_floor"), Vector3.UP, Vector3(p.x, 0.0, p.z) + d)) != 0.0:
					touched.append("floor at %s" % (p + d))
			for n: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
				for h: float in [0.05, 0.3, 0.55]:
					for m in walls:
						if float(view.call(&"fill_at", m, n, Vector3(p.x, h, p.z))) != 0.0:
							touched.append("wall at %.2f m by %s" % [h, p])
		t.check(touched.is_empty(), "%s: no fill on a fuse spot's floor or skirting (%s)" % [sd, ", ".join(touched.slice(0, 3))])
		# And the fuse's own material is its own: no fill on it.
		var fuse: Node3D = view.get(&"fuse_node")
		var own := true
		for c in fuse.get_children():
			var m := (c as MeshInstance3D).material_override as ShaderMaterial
			own = own and m != view.get(&"mat_props") and (m.get_shader_parameter("rise") == null or float(m.get_shader_parameter("rise")) == 0.0)
		t.check(own, "%s: the fuse's materials carry no fill" % sd)
		level.free()

# --- 3. it follows the power and the blink --------------------------------------------------------------------------

func test_the_fill_follows_the_power_and_the_blink(t: T) -> void:
	var level := _level("alpha")
	var view := _view(level)
	var mats: Array = view.get(&"_fill_mats")
	t.check(mats.size() == 5, "the fill drives the two wall materials, the ceiling and the dressing's two (%d)" % mats.size())
	for power: int in [0, 1, 2]:
		for k: float in [1.0, 0.6, 0.28, 0.1, 0.03, 0.01, 0.0]:
			level.set_light_level(k)
			level.update_lights(0.016, Vector3.ZERO)
			view.call(&"set_power", power)
			view.call(&"_apply")
			var battens_lit := false
			for l in level.main_lights:
				battens_lit = battens_lit or (l.visible and l.light_energy > 0.0)
			var want := k if power != 1 and k > 0.02 else 0.0
			t.check(is_equal_approx(float(view.get(&"fill_k")), want), "power %d, lights %.2f: the fill's share %.3f (want %.3f)" % [power, k, view.get(&"fill_k"), want])
			t.check(battens_lit == (float(view.get(&"fill_k")) > 0.0), "power %d, lights %.2f: the fill is on exactly when the battens are lit" % [power, k])
			for e: Array in mats:
				var got := float((e[0] as ShaderMaterial).get_shader_parameter(e[1]))
				t.check(is_equal_approx(got, float(e[2]) * want), "power %d, lights %.2f: %s %.4f (want %.4f)" % [power, k, e[1], got, float(e[2]) * want])
	level.free()

# --- 4. no light, only the side rooms, no other floor ------------------------------------------------------------

func test_no_light_is_added_and_the_pairs_hold(t: T) -> void:
	for sd: String in ["alpha", "beta"]:
		var level := _level(sd)
		var view := _view(level)
		var lights := 0
		var stack: Array[Node] = [level]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			stack.append_array(n.get_children())
			lights += int(n is Light3D)
		var lamps: Array = view.get(&"lamps")
		t.eq(lights, level.main_lights.size() + lamps.size() + 1, "%s: the lights are the battens, the amber lamps and the cassette's (%d)" % [sd, lights])
		var r := Pairs.pair_counts(level)
		var cap := int(ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object")) - Pairs.HEADROOM
		t.check(r.worst_spot <= cap and r.worst_omni <= cap, "%s: every mesh meets at most %d lamps of a kind (%d spots, %d omnis)" % [sd, cap, r.worst_spot, r.worst_omni])
		level.free()

func test_only_the_side_rooms_carry_fill(t: T) -> void:
	for sd in _seeds(t):
		var level := _level(sd)
		var view := _view(level)
		var cells: Dictionary = view.get(&"fill_cells")
		var side := {}
		for r: Dictionary in level.plan.rooms:
			if int(r.get("level", 0)) == 0 and SIDE.has(str(r.kind)):
				for y in range(int(r.y), int(r.y) + int(r.h)):
					for x in range(int(r.x), int(r.x) + int(r.w)):
						side[Vector2i(x, y)] = true
		var stray := PackedStringArray()
		var dark := PackedStringArray()
		for y in level.H:
			for x in level.W:
				var v: Vector2 = cells.get(Vector2i(x, y), Vector2.ZERO)
				if side.has(Vector2i(x, y)):
					if v.x <= 0.0 or v.y <= 0.0:
						dark.append(str(Vector2i(x, y)))
				elif v != Vector2.ZERO:
					stray.append("%s (%s)" % [Vector2i(x, y), level.kind(0, x, y)])
		t.check(stray.is_empty(), "%s: no fill outside the side rooms (%s)" % [sd, ", ".join(stray.slice(0, 4))])
		# Every side-room cell is darker than the targets before its fill, so every one takes some on its walls and ceiling.
		t.check(dark.is_empty() and not side.is_empty(), "%s: every side-room cell has its fill (%s)" % [sd, ", ".join(dark.slice(0, 4))])
		# The upper storey and the floors never take any.
		_power(level, 0)
		var c := level.cell_center(0, 1, 1)
		t.eq(float(view.call(&"fill_at", view.get(&"mat_ceil"), Vector3.DOWN, c + Vector3(0, View.LH + 3.0, 0))), 0.0, "%s: nothing on the upper storey" % sd)
		var any_floor := 0.0
		for k: Vector2i in side:
			any_floor += float(view.call(&"fill_at", view.get(&"mat_floor"), Vector3.UP, level.cell_center(0, k.x, k.y)))
		t.eq(any_floor, 0.0, "%s: no fill on any floor" % sd)
		level.free()

static func _shader_has(path: String, line: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	return f != null and f.get_as_text().contains(line)

func test_other_floors_are_unchanged(t: T) -> void:
	# The shaders' new terms are off unless a floor sets them: the station's surface shader and the shared props' shader.
	t.check(_shader_has("res://client/prop.gdshader", "uniform float rise = 0.0;"), "the props' shader adds nothing unless asked")
	t.check(_shader_has("res://client/station_surface.gdshader", "uniform float fill = 0.0;"), "the station's surface shader adds nothing unless asked")
	var others: Array = [
		["the Clinic", Clinic.generate_clinic("alpha", 1)],
		["the Annex", AnnexPlan.generate_annex("alpha", 3)],
		["the Playroom", Playroom.generate_playroom("alpha", 4)],
		["the Arboretum", Arboretum.generate_arboretum("alpha", 5)],
		["the orientation floor", Orientation.generate("alpha", 0)],
	]
	for o: Array in others:
		var level := Level.new()
		level.build(PlanDump.dump(o[1], Run.car_geometry(o[1])), o[1].seed, o[1])
		_no_fill(t, o[0], level)
		level.free()
	var prison := Level.new()
	prison.build(PrisonView.plain_plan(), "prison")
	_no_fill(t, "the Prison", prison)
	prison.free()

static func _no_fill(t: T, what: String, level: Level) -> void:
	var bad := PackedStringArray()
	var stack: Array[Node] = [level]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var gi := n as GeometryInstance3D
		if gi == null or not (gi.material_override is ShaderMaterial):
			continue
		var m := gi.material_override as ShaderMaterial
		for p: String in ["rise", "rise_tex", "fill", "fill_tex"]:
			if m.get_shader_parameter(p) != null:
				bad.append("%s has %s" % [n.name, p])
	t.check(bad.is_empty(), "%s: no material carries the side rooms' fill (%s)" % [what, ", ".join(bad.slice(0, 3))])

# --- 5. the dressing ---------------------------------------------------------------------------------------------

func test_the_dressing_lights_up_with_the_room(t: T) -> void:
	for sd in _seeds(t):
		var level := _level(sd)
		var view := _view(level)
		var rooms_node: Node3D = (view.get(&"dresser") as Node3D).get_node_or_null("StationRooms")
		t.check(rooms_node != null, "%s: the side rooms are dressed" % sd)
		if rooms_node == null:
			level.free()
			continue
		var by_mat := {}
		for c in rooms_node.get_children():
			if c is MeshInstance3D:
				by_mat[(c as MeshInstance3D).material_override] = true
		var mats: Array = by_mat.keys()
		var unlit := 0
		var high := 0
		_power(level, 0)
		for r: Dictionary in rooms_node.get(&"records"):
			if str(r.zone) != "high":
				continue
			high += 1
			var at: Vector3 = (r.aabb as AABB).get_center()
			var most := 0.0
			for m: Material in mats:
				most = maxf(most, float(view.call(&"fill_at", m, Vector3.UP, at)))
			unlit += int(most <= 0.05)
		t.check(high > 0 and unlit == 0, "%s: every high piece takes its room's light with the power on (%d of %d without)" % [sd, unlit, high])
		_power(level, 1)
		var cut := 0.0
		for r: Dictionary in rooms_node.get(&"records"):
			for m: Material in mats:
				cut = maxf(cut, float(view.call(&"fill_at", m, Vector3.UP, (r.aabb as AABB).get_center())))
		t.eq(cut, 0.0, "%s: and none in the cut" % sd)
		# The landing's props share the material and take none.
		_power(level, 0)
		var land := level.cell_center(level.landing.x, level.landing.y, level.landing.z) + Vector3(0, 2.5, 0)
		t.eq(float(view.call(&"fill_at", view.get(&"mat_props"), Vector3.UP, land)), 0.0, "%s: the landing's props take none" % sd)
		level.free()
