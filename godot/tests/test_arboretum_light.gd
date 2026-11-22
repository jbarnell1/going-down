extends RefCounted
## LK1: the Arboretum is dark dusk, not black (a friend on another PC "just sees static" on it). Only how it is drawn
## (client/arboretum_view.gd, client/main.gd); what the rules count as light (sim/) is not touched. Guards against
## anyone blacking the floor out again by accident:
##   1. the cool fill: the floor's ambient energy and colour, and client/main.gd reads them (with the lights);
##   2. the painted backdrop glows a little, and the fog lightens towards the dusk (dark again in the blackout);
##   3. the landmarks' warm practical lights, placed from the seed, none reaching a hide, all out in the blackout;
##   4. no mesh meets more lamps than the renderer pairs (tests/test_light_pairs.gd's limit) on these seeds.

const T = preload("res://tests/t.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const ArbView = preload("res://client/arboretum_view.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const LightPairs = preload("res://tests/test_light_pairs.gd")
const Furniture = preload("res://sim/furniture.gd")

const SEEDS: Array[String] = ["lk1", "alpha", "beta", "garden-1", "night"]

static func _built(seed_: String) -> Level:
	var plan := Arboretum.generate_arboretum(seed_, 5)
	var level := Level.new()
	level.build(PlanDump.dump(plan, Run.car_geometry(plan)), plan.seed, plan)
	return level

static func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

func test_the_dusk_fill(t: T) -> void:
	var level := _built("lk1")
	var e := float(level.get_meta(&"ambient_energy", 0.12))
	t.check(e >= 0.6 and e <= 1.4, "the garden's dusk fill energy is %.2f (0.6 to 1.4: dark, not black)" % e)
	var c: Color = level.ambient_lit
	t.check(c.b > c.r and c.b >= c.g, "the fill is cool (blue): %s" % c)
	var fill := _lum(c) * e
	t.check(fill >= 0.4 and fill <= 0.9, "the fill reaches the ground at %.3f (0.4 to 0.9)" % fill)
	var view: Node = level.get_meta(&"arboretum")
	var dusk := view.get_node_or_null("Dusk") as DirectionalLight3D
	if t.check(dusk != null, "the painted sky's faint dusk light is there"):
		t.check(dusk.light_energy >= 0.2 and dusk.light_energy <= 0.7, "the dusk light is faint (%.2f, 0.2 to 0.7)" % dusk.light_energy)
		t.check(dusk.light_color.b > dusk.light_color.r and not dusk.shadow_enabled, "the dusk light is cool and casts no shadow")
		t.check((dusk.transform.basis.z).y > 0.6, "the dusk comes from high above")
		t.check(level.main_lights.has(dusk), "the dusk light goes out with the lamps")
	t.check(_lum(level.ambient_color(1.0)) < _lum(c) * 0.2, "the blackout's ambient stays dark")
	level.free()
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("lerpf(float(level.get_meta(&\"ambient_energy\", 0.12)), 0.05, emergency) * maxf(light, emergency)"),
		"client/main.gd takes a place's fill energy, and it still goes out with the lights")

func test_backdrop_and_fog(t: T) -> void:
	t.check(ArbView.SKY_GLOW >= 0.45 and ArbView.SKY_GLOW <= 0.9, "the painted sky glows at %.2f (0.45 to 0.9)" % ArbView.SKY_GLOW)
	t.check(ArbView.WALL_GLOW >= 0.4 and ArbView.WALL_GLOW <= 0.8, "the painted walls glow at %.2f (0.4 to 0.8): trees stand against them" % ArbView.WALL_GLOW)
	var level := _built("lk1")
	var fog: Color = level.get_meta(&"fog_color")
	var dark: Color = level.get_meta(&"fog_color_dark")
	t.check(_lum(fog) >= 0.06 and _lum(fog) <= 0.15, "the fog lightens towards dusk with distance (%.3f, 0.06 to 0.15)" % _lum(fog))
	t.check(fog.b > fog.r, "the fog is the dusk's blue")
	t.check(_lum(dark) < 0.01, "in the blackout the fog is dark (%.4f)" % _lum(dark))
	var view: Node = level.get_meta(&"arboretum")
	view.call(&"_apply", 0.0)
	var lit_glows := 0
	for gl: Array in view.get(&"_glows"):
		if float((gl[0] as ShaderMaterial).get_shader_parameter("energy")) > float(gl[2]) + 0.001:
			lit_glows += 1
	t.eq(lit_glows, 0, "in the blackout the sky and every lamp's glow go out")
	level.free()
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("(level.get_meta(&\"fog_color_dark\") as Color).lerp(level.get_meta(&\"fog_color\") as Color, clampf(light, 0.0, 1.0))"),
		"client/main.gd darkens the fog with the lights")

func test_practical_lamps_from_the_seed(t: T) -> void:
	var total := 0
	for seed_: String in SEEDS:
		var level := _built(seed_)
		var view: Node = level.get_meta(&"arboretum")
		var placed: Array = view.get(&"practicals")
		total += placed.size()
		var hides: Array[Vector3] = []
		for p in Furniture.pieces_for(Arboretum.generate_arboretum(seed_, 5)):
			if p.kind in ArbView.HIDE_PIECES:
				hides.append(Vector3(p.x / 100.0, 0, p.y / 100.0))
		for pr: Array in placed:
			var o := pr[1] as OmniLight3D
			var tag := "%s %s" % [seed_, pr[0]]
			t.check(o.light_color.r > o.light_color.b * 1.5, "%s: the practical is warm" % tag)
			t.check(o.light_energy >= 0.8 and o.light_energy <= 2.5 and o.omni_range <= 6.0, "%s: a small light (%.2f, %.1f m)" % [tag, o.light_energy, o.omni_range])
			t.check(not o.shadow_enabled, "%s: casts no shadow" % tag)
			t.check(level.main_lights.has(o), "%s: goes with the floor's lights (out in the blackout)" % tag)
			for h in hides:
				t.check(Vector2(h.x - o.position.x, h.z - o.position.z).length() > o.omni_range, "%s: reaches no hide (%s)" % [tag, h])
		# The same seed places the same lights.
		var again := _built(seed_)
		var placed2: Array = (again.get_meta(&"arboretum") as Node).get(&"practicals")
		var same := placed2.size() == placed.size()
		for i in mini(placed.size(), placed2.size()):
			same = same and (placed[i][1] as Node3D).position.is_equal_approx((placed2[i][1] as Node3D).position)
		t.check(same, "%s: one seed, the same practical lights" % seed_)
		view.call(&"_apply", 0.0)
		for pr: Array in placed:
			t.check(not (pr[1] as Light3D).visible, "%s %s: out in the blackout" % [seed_, pr[0]])
		again.free()
		level.free()
	t.check(total >= SEEDS.size(), "the landmarks have practical lights (%d over %d seeds)" % [total, SEEDS.size()])

func test_lamps_per_mesh_stay_inside_the_renderer(t: T) -> void:
	var room := int(ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object")) - LightPairs.HEADROOM
	for seed_: String in SEEDS:
		var level := _built(seed_)
		var r := LightPairs.pair_counts(level)
		t.check(r.worst_omni <= room and r.worst_spot <= room, "%s: every mesh meets at most %d lamps (worst %d omnis on %s)" % [seed_, room, r.worst_omni, r.omni_mesh])
		level.free()
