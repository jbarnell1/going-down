extends RefCounted
## LA5: near the lift the Clinic's walls are bright from skirting to ceiling ("Near the lift it is the clean, bright
## hospital above"), the wall facing the lift doors included, and far from it they stay as dim as they were, with no
## light added and no other floor touched. The lamps point down and light a wall only low down and only beside a lamp,
## so the walls carry their own light near the lift (level.gd WALL_LIT), which the corruption takes away. The numbers
## come from the lights the level built and the shader's terms (tests/clinic_light.gd).

const T = preload("res://tests/t.gd")
const L = preload("res://tests/clinic_light.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const AnnexPlan = preload("res://sim/annex.gd")
const Playroom = preload("res://sim/playroom.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const Station = preload("res://sim/station.gd")
const Orientation = preload("res://sim/orientation.gd")
const PrisonView = preload("res://client/prison_view.gd")
const PlanDump = preload("res://client/plan_dump.gd")

## Near the lift: a wall at 2.5 m is at least this share of the same wall at 1.0 m, and at 3.0 m (just under the
## ceiling) at least TOP_AT_LEAST.
const UPPER_AT_LEAST := 0.85
const TOP_AT_LEAST := 0.75
## Near the lift: a wall the way runs into (and the one facing the lift doors) is at least this share of a side wall.
const END_AT_LEAST := 0.75
## Near the lift: a wall at 1.5 m is at least this share of the floor beside it, and at most the ceiling beside it.
const FLOOR_SHARE := 0.8
## Far from the lift a wall at 1.5 m is at most this share of the same kind of wall near it.
const FAR_SHARE := 0.35

func _seeds(t: T) -> Array:
	return [["alpha", 1], ["alpha", 2]] if t.quick else [["alpha", 1], ["alpha", 2], ["beta", 1], ["night-1", 2], ["lt1-4", 1]]

static func _built(fp: Variant) -> Level:
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

static func _lit(level: Level) -> Level:
	level.set_light_level(1.0)
	level.set_emergency(0.0)
	level.update_lights(0.1, Vector3.ZERO)
	return level

func test_walls_near_the_lift_are_bright_to_the_ceiling(t: T) -> void:
	for sd: Array in _seeds(t):
		var level := _lit(_built(Clinic.generate_clinic(sd[0], sd[1])))
		var tag := "%s/%d" % sd
		var ws := L.walls(level, true)
		var side := L.summary(level, ws, "side")
		t.check(side.n > 0, "%s: there are corridor walls near the lift (%d)" % [tag, side.n])
		for what: String in ["side", "end", "lift"]:
			var r := L.summary(level, ws, what)
			if r.n == 0:
				continue
			t.check(r.h25 >= r.h10 * UPPER_AT_LEAST, "%s %s walls: at 2.5 m %.3f, at 1.0 m %.3f (at least %.2f of it)" % [tag, what, r.h25, r.h10, UPPER_AT_LEAST])
			t.check(r.h30 >= r.h10 * TOP_AT_LEAST, "%s %s walls: at 3.0 m %.3f, at 1.0 m %.3f (at least %.2f of it)" % [tag, what, r.h30, r.h10, TOP_AT_LEAST])
			t.check(r.h15 >= r.floor * FLOOR_SHARE, "%s %s walls: at 1.5 m %.3f, the floor beside %.3f (at least %.2f of it)" % [tag, what, r.h15, r.floor, FLOOR_SHARE])
			t.check(r.h15 <= r.ceiling, "%s %s walls: at 1.5 m %.3f, no brighter than the ceiling beside %.3f (not washed out)" % [tag, what, r.h15, r.ceiling])
			if what != "side":
				t.check(r.h10 >= side.h10 * END_AT_LEAST, "%s %s walls: %.3f at 1.0 m, a side wall %.3f (at least %.2f of it)" % [tag, what, r.h10, side.h10, END_AT_LEAST])
			t.note("%s near %s n=%d: wall 0.5 %.3f, 1.5 %.3f, 2.5 %.3f, 3.0 %.3f; floor %.3f, ceiling %.3f" % [tag, what, r.n, r.h05, r.h15, r.h25, r.h30, r.floor, r.ceiling])
		t.check(L.summary(level, ws, "lift").n == 1, "%s: the wall facing the lift doors was found" % tag)
		level.free()

func test_walls_far_from_the_lift_stay_dim(t: T) -> void:
	for sd: Array in _seeds(t):
		var level := _lit(_built(Clinic.generate_clinic(sd[0], sd[1])))
		var tag := "%s/%d" % sd
		var near := L.walls(level, true)
		var far := L.walls(level, false)
		for what: String in ["side", "end"]:
			var a := L.summary(level, near, what)
			var b := L.summary(level, far, what)
			if a.n == 0 or b.n == 0:
				continue
			t.check(b.h15 <= a.h15 * FAR_SHARE, "%s %s walls: far %.3f, near %.3f (at most %.2f of it)" % [tag, what, b.h15, a.h15, FAR_SHARE])
			t.note("%s far %s n=%d: wall 0.5 %.3f, 1.5 %.3f, 2.5 %.3f; floor %.3f, ceiling %.3f" % [tag, what, b.n, b.h05, b.h15, b.h25, b.floor, b.ceiling])
		# The far end gets none of the walls' own light: there they are exactly what they were.
		t.check(is_zero_approx(L.own_light(level.mat_wall, 0.85)) and is_zero_approx(L.own_light(level.mat_wall, 1.0)), "%s: the walls' own light is gone by the far side" % tag)
		t.check(L.own_light(level.mat_wall, 0.5) < L.own_light(level.mat_wall, 0.0) * 0.8, "%s: it fades with the walk from the lift" % tag)
		level.free()

## The walls' own light goes with the lamps: in the dark and in the emergency light it is none, as it always was.
func test_the_walls_go_dark_with_the_lamps(t: T) -> void:
	var level := _built(Clinic.generate_clinic("alpha", 1))
	for k: Array in [[1.0, 0.0, Level.WALL_LIT], [0.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 1.0, 0.0], [0.5, 0.0, Level.WALL_LIT * 0.25]]:
		level.set_light_level(k[0])
		level.set_emergency(k[1])
		level.update_lights(0.1, Vector3.ZERO)
		var got := float(level.mat_wall.get_shader_parameter("self_light"))
		t.check(is_equal_approx(got, float(k[2])), "lights %.1f, emergency %.1f: the walls' own light is %.3f (want %.3f)" % [k[0], k[1], got, k[2]])
	level.free()

## No light is added: every light on the Clinic is a ceiling lamp or an emergency light, as many as the plan's panels
## give (the pair counts are test_light_pairs').
func test_no_light_is_added(t: T) -> void:
	var level := _built(Clinic.generate_clinic("alpha", 1))
	var lamps := 0
	for c in level.get_children():
		if c is Light3D:
			lamps += 1
	t.eq(lamps, level.main_lights.size() + level.emergency_lights.size(), "every light is a ceiling lamp or an emergency light (%d)" % lamps)
	var live := 0
	for p: Dictionary in level.panels:
		if not p.dead:
			live += 1
	t.eq(level.main_lights.size(), live, "one lamp per live panel")
	level.free()

## Only the Clinic's walls carry their own light: every other floor's walls are as they were.
func test_other_floors_walls_are_unchanged(t: T) -> void:
	var others: Array = [
		["the Annex", _built(AnnexPlan.generate_annex("alpha", 3))],
		["the Playroom", _built(Playroom.generate_playroom("alpha", 4))],
		["the Arboretum", _built(Arboretum.generate_arboretum("alpha", 5))],
		["the Reactor", _built(Station.generate_station("alpha", 7))],
		["the orientation floor", _built(Orientation.generate("alpha", 0))],
	]
	var prison := Level.new()
	prison.build(PrisonView.plain_plan(), "prison")
	others.append(["the Prison", prison])
	for o: Array in others:
		var level: Level = o[1]
		var before := _wall_params(level)
		_lit(level)
		t.eq(level.wall_lit, 0.0, "%s: no walls' own light" % o[0])
		t.eq(_wall_params(level), before, "%s: the lamps leave the wall material alone" % o[0])
		level.free()
	var orient := _built(Orientation.generate("alpha", 0))
	t.eq(orient.mat_wall.get_shader_parameter("self_light"), null, "the orientation floor's wall paint keeps the shader's default")
	t.eq(orient.mat_wall.get_shader_parameter("self_dirt"), null, "and its default corruption")
	orient.free()

static func _wall_params(level: Level) -> Array:
	if level.mat_wall == null:
		return []
	return [level.mat_wall.get_shader_parameter("self_light"), level.mat_wall.get_shader_parameter("self_dirt")]
