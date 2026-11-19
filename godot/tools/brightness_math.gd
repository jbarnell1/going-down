# The numbers behind the brightness card (T27a), shared by tools/brightness_table.gd and
# tests/prop_brightness_curve.gd. Three parts:
#   - the curve as it was before T27a (commit 2391000), kept here only to print the "before" table and to
#     prove the default and the top of the range did not change;
#   - the tape filter's last steps for a flat patch of colour (client/tape.gdshader lines 52 to 74), with
#     the shader's own constants: tape_lines_match() fails if those lines change, so these sums cannot drift
#     from the shader without a red test;
#   - an ESTIMATE of what the near light puts on a surface before the tape (Godot's omni falloff, its filmic
#     tonemapper, sRGB). The albedos and angles are guesses, marked as such; a real frame is the check.
# 8-bit is how the window stores a pixel: round(v * 255).
extends RefCounted

const Brightness = preload("res://client/brightness.gd")

# ---- The curve before T27a (client/brightness.gd at 2391000). ----
const OLD_LIFT_HIGH := 0.028
const OLD_GAMMA_HIGH := 1.3
const OLD_LIFT_LOW := 0.005
const OLD_GAMMA_LOW := 1.15
## The old card: the game's black with a touch of blue as the background, and its three badges.
const OLD_BG := Color(0.065, 0.069, 0.073)
const OLD_LEFT := 0.105
const OLD_RIGHT := 0.072
const OLD_MIDDLE := 0.42

static func old_apply(x: float, lv: int) -> float:
	var t := Brightness.t_of(lv)
	var lift: float
	var gamma: float
	if t >= 0.0:
		lift = OLD_LIFT_HIGH * t
		gamma = pow(OLD_GAMMA_HIGH, -t)
	else:
		lift = OLD_LIFT_LOW * t
		gamma = pow(OLD_GAMMA_LOW, -t)
	return clampf(lift + (1.0 - lift) * pow(clampf(x, 0.0, 1.0), gamma), 0.0, 1.0)

static func new_apply(x: float, lv: int) -> float:
	return Brightness.apply(x, lv)

## 0..1 to the 8-bit value the window holds.
static func q(v: float) -> int:
	return roundi(clampf(v, 0.0, 1.0) * 255.0)

static func q3(c: Color) -> Vector3i:
	return Vector3i(q(c.r), q(c.g), q(c.b))

## The largest channel difference between two 8-bit pixels.
static func diff(a: Vector3i, b: Vector3i) -> int:
	return maxi(absi(a.x - b.x), maxi(absi(a.y - b.y), absi(a.z - b.z)))

# ---- The tape filter's last steps (client/tape.gdshader). ----
const TAPE_PATH := "res://client/tape.gdshader"
## The shader lines these sums copy, word for word.
const TAPE_LINES: Array[String] = [
	"vec3 col = to_rgb(vec3(Y, ch.y * 0.62 + blot * strength, ch.z * 0.55 - blot * strength));",
	"col += (hash(uv * src_size + fract(TIME) * 91.0) - 0.5) * (0.07 + 0.09 * (darkness + shaken)) * strength;",
	"col *= 1.0 - 0.14 * sl * strength;",
	"col = clamp(col, 0.0, 1.0);",
	"col = pow(col, vec3(1.0 + 0.3 * strength)) * (1.0 + 0.14 * strength) + vec3(0.04, 0.05, 0.055) * strength + vec3(0.025, 0.02, 0.02) * darkness;",
	"col *= 1.0 - 0.5 * strength * pow(r, 2.6);",
	"col = clamp(bright_lift + (1.0 - bright_lift) * pow(clamp(col, 0.0, 1.0), vec3(bright_gamma)), 0.0, 1.0);",
]

## The lines of TAPE_LINES missing from the shader (empty when the sums below still match it).
static func tape_lines_missing() -> Array[String]:
	var src := FileAccess.get_file_as_string(TAPE_PATH)
	var missing: Array[String] = []
	for line in TAPE_LINES:
		if not src.contains(line):
			missing.append(line)
	return missing

static func _yiq(c: Vector3) -> Vector3:
	return Vector3(c.dot(Vector3(0.299, 0.587, 0.114)), c.dot(Vector3(0.596, -0.274, -0.322)), c.dot(Vector3(0.211, -0.523, 0.312)))

static func _rgb(y: Vector3) -> Vector3:
	return Vector3(y.x + 0.956 * y.y + 0.621 * y.z, y.x - 0.272 * y.y - 0.647 * y.z, y.x - 1.106 * y.y + 1.703 * y.z)

## A flat patch of scene colour (sRGB 0..1, as the 480x270 picture holds it) through the tape and then the
## player's setting. grain: the grain hash minus a half (-0.5 .. 0.5; 0 is its mean). sl: the scanline
## (0 between lines .. 1 on a line; 0.5 is its mean). r: distance from the centre as the shader measures
## it (0 at the centre). strength 1 is the tape on; darkness 1 is the lights out. apply_fn takes (x, level).
static func tape(scene: Color, darkness: float, lv: int, grain := 0.0, sl := 0.5, r := 0.0, strength := 1.0, apply_fn := Callable()) -> Color:
	var fn: Callable = apply_fn if apply_fn.is_valid() else Brightness.apply
	var yiq := _yiq(Vector3(scene.r, scene.g, scene.b))   # flat patch: no ringing, the smear is the same colour
	var col := _rgb(Vector3(yiq.x, yiq.y * 0.62, yiq.z * 0.55))
	col += Vector3.ONE * grain * (0.07 + 0.09 * darkness) * strength
	col *= 1.0 - 0.14 * sl * strength
	col = col.clamp(Vector3.ZERO, Vector3.ONE)
	var e := 1.0 + 0.3 * strength
	col = Vector3(pow(col.x, e), pow(col.y, e), pow(col.z, e)) * (1.0 + 0.14 * strength) + Vector3(0.04, 0.05, 0.055) * strength + Vector3(0.025, 0.02, 0.02) * darkness
	col *= 1.0 - 0.5 * strength * pow(r, 2.6)
	return Color(fn.call(col.x, lv), fn.call(col.y, lv), fn.call(col.z, lv))

# ---- ESTIMATE: the near light on a surface (client/main.gd NearLight, Godot 4 forward lighting). ----
const NEAR_COLOR := Color(0.62, 0.72, 1.0)   # main.gd near_light.light_color
const NEAR_ENERGY := 1.1                     # main.gd NEAR_LIGHT_ENERGY
const NEAR_REACH := 4.0                      # main.gd NEAR_LIGHT_REACH
const NEAR_DECAY := 1.6                      # main.gd near_light.omni_attenuation
const ARBORETUM_GAIN := 1.7                  # arboretum_view.gd near_light_gain

static func _s2l(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

static func _l2s(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	return v * 12.92 if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055

## Godot 4's omni falloff (scene_forward_lights get_omni_attenuation).
static func omni_atten(d: float) -> float:
	var nd := d / NEAR_REACH
	nd = nd * nd
	nd = nd * nd
	nd = maxf(1.0 - nd, 0.0)
	return nd * nd * pow(maxf(d, 0.0001), -NEAR_DECAY)

## Godot 4's filmic tonemapper, white 1.0 (main.gd sets TONE_MAPPER_FILMIC, the default white).
static func filmic(x: float) -> float:
	const A := 0.22 * 4.0
	const B := 0.30 * 2.0
	const C := 0.10
	const D := 0.20
	const E := 0.01
	const F := 0.30
	var f := func(v: float) -> float: return ((v * (A * v + C * B) + D * E) / (v * (A * v + B) + D * F)) - E / F
	return f.call(x) / f.call(1.0)

## The scene colour (sRGB, before the tape) of a surface of this albedo, d metres from the camera, at this
## angle to it, lit only by the near light at full strength times gain. Diffuse only; Godot's light energy
## carries the pi that the Lambert term divides by.
static func near_lit(albedo: float, d: float, n_dot_l: float, gain: float) -> Color:
	var k := albedo * NEAR_ENERGY * gain * omni_atten(d) * n_dot_l
	return Color(_l2s(filmic(_s2l(NEAR_COLOR.r) * k)), _l2s(filmic(_s2l(NEAR_COLOR.g) * k)), _l2s(filmic(_s2l(NEAR_COLOR.b) * k)))
