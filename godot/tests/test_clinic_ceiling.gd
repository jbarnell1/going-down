extends RefCounted
## LA1: the Clinic's ceiling reads white near the lift ("Near the lift it is the clean, bright hospital above") and
## stays dim, yellowed and stained far from it, with no light added. The Clinic's lamps point down and never reach the
## ceiling, so what it shows is its own light (surface.gdshader self_light) and the ambient: this mirrors the shader.

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")

## The game's ambient with the lights on (client/main.gd): energy and colour.
const AMBIENT_ENERGY := 0.12
const AMBIENT := Color(0.55, 0.6, 0.6)
## How bright (linear) the ceiling must read next to the lift, and at most at the far end.
const NEAR_AT_LEAST := 0.4
const FAR_AT_MOST := 0.09

static func _lum(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722

## The ceiling's linear brightness at corruption `t`, as surface.gdshader draws it (stains and the grid lines aside).
static func ceiling_seen(m: ShaderMaterial, t: float) -> float:
	var img := (m.get_shader_parameter("albedo_tex") as Texture2D).get_image()
	if img.is_compressed():
		img.decompress()
	var whiten: float = m.get_shader_parameter("whiten") if m.get_shader_parameter("whiten") != null else 0.0
	var self_dirt: float = m.get_shader_parameter("self_dirt") if m.get_shader_parameter("self_dirt") != null else 0.85
	var self_light: float = m.get_shader_parameter("self_light")
	var dirt := smoothstep(0.2, 0.85, t)
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var p := img.get_pixel(x, y).srgb_to_linear()
			var base := Vector3(p.r, p.g, p.b)
			if whiten > 0.0:
				var l := _lum(p)
				var clean := Vector3(0.9, 0.92, 0.93) * (0.82 + 0.18 * l / 0.6)
				base = base.lerp(clean, whiten * (1.0 - smoothstep(0.1, 0.7, t)))
			var c := base.lerp(base * Vector3(0.74, 0.7, 0.52), dirt)
			var lum := c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
			sum += lum * (self_light * (1.0 - dirt * self_dirt) + AMBIENT_ENERGY * _lum(AMBIENT))
			n += 1
	return sum / n

static func _clinic() -> Level:
	var fp := Clinic.generate_clinic("la1-ceiling", 1)
	var level := Level.new()
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

func test_the_ceiling_is_white_by_the_lift_and_dim_far_off(t: T) -> void:
	var level := _clinic()
	level.set_light_level(1.0)
	level.set_emergency(0.0)
	level.update_lights(0.1, Vector3.ZERO)
	var m := level.mat_ceiling
	var near := ceiling_seen(m, 0.0)
	var far := ceiling_seen(m, 1.0)
	t.check(near >= NEAR_AT_LEAST, "by the lift the ceiling reads %.3f (linear), at least %.2f" % [near, NEAR_AT_LEAST])
	t.check(far <= FAR_AT_MOST, "at the far end it reads %.3f, at most %.2f: still dim" % [far, FAR_AT_MOST])
	t.check(ceiling_seen(m, 0.5) < near * 0.8, "it dims with the walk from the lift (%.3f half way)" % ceiling_seen(m, 0.5))
	t.check(float(m.get_shader_parameter("grid_m")) > 0.0, "the tiles sit in a suspended ceiling's grid")
	t.note("ceiling near the lift %.3f, half way %.3f, far %.3f (linear)" % [near, ceiling_seen(m, 0.5), far])
	level.free()

## The ceiling's own light goes with the lamps: in the dark and in the emergency light it is what it always was.
func test_the_ceiling_goes_dark_with_the_lamps(t: T) -> void:
	var level := _clinic()
	var lit := 0
	for k: Array in [[1.0, 0.0, Level.CEILING_LIT], [0.0, 0.0, Level.CEILING_DARK], [0.0, 1.0, Level.CEILING_DARK], [1.0, 1.0, Level.CEILING_DARK]]:
		level.set_light_level(k[0])
		level.set_emergency(k[1])
		level.update_lights(0.1, Vector3.ZERO)
		var got := float(level.mat_ceiling.get_shader_parameter("self_light"))
		t.check(is_equal_approx(got, float(k[2])), "lights %.1f, emergency %.1f: the ceiling's own light is %.2f (want %.2f)" % [k[0], k[1], got, k[2]])
		lit += 1
	t.eq(lit, 4, "four light states checked")
	level.free()

## Only the Clinic's ceiling changes: the other surfaces keep the shader's defaults, and no lamp is added.
func test_nothing_else_changes(t: T) -> void:
	var level := _clinic()
	for m: ShaderMaterial in [level.mat_wall, level.mat_floor]:
		t.eq(m.get_shader_parameter("whiten"), null, "walls and floors are not whitened")
		t.eq(m.get_shader_parameter("grid_m"), null, "walls and floors have no grid")
	var lamps := 0
	for c in level.get_children():
		if c is Light3D:
			lamps += 1
	t.eq(lamps, level.main_lights.size() + level.emergency_lights.size(), "every light is a ceiling lamp or an emergency light (%d)" % lamps)
	level.free()
