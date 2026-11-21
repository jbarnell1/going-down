# WC1: being caught in the web, as the caught player sees it (net/host_rules.gd ward_web). The owner, 20 Nov: "the hand
# just wraps just under the camera like he's grabbing your neck, and then the camera follows his hand out and then goes
# to gray as if it were being wrapped in webbing and upside down. And then your view would cut to your teammates until
# they rescued you out of the web."
#
# Everything runs on the host's times for this player's web row (sim/ward/state.gd webbed: caughtAt, hangAt), so every
# screen is at the same moment of it:
#   grab   caughtAt to +GRAB: the search hand closes just under the camera;
#   pull   then PULL seconds: the camera is drawn out along the arm's path (the host's posed limb, hand to shoulder), the
#          picture goes grey with strands closing in from the edges, and the view rolls upside down over its last ROLL;
#   held   then: the main scene's watch view shows a living crewmate (DV1's watch_crewmate(), when the scene has it), or,
#          without it, this screen holds the grey upside-down view from the hang point with a slow sway;
#   free   when the row is gone (cut down): the watch stops (stop_watching()), the grey peels away over PEEL and the view
#          rights itself; the player stands where the host put them.
# DV1's watch view (client/main.gd, merged separately) is called only through has_method, so this works with or without
# it: defer_watching() as the sequence starts, watch_crewmate() as it ends, stop_watching() when cut free.
extends Node

const GRAB := 0.35
const PULL := 1.5
const ROLL := 1.0
const PEEL := 0.8
## The held view: this far below the ceiling at the hang point, looking down and out.
const HELD_EYE := 1.6
## A room's ceiling above its floor (sim/ward/house.gd HEIGHT).
const CEILING := 3.05

const SHADER := """
shader_type canvas_item;
uniform sampler2D screen: hint_screen_texture, filter_linear_mipmap;
uniform float grey = 0.0;
uniform float web = 0.0;
void fragment() {
	vec3 col = texture(screen, SCREEN_UV).rgb;
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(l * 0.92 + 0.04), grey);
	vec2 p = (SCREEN_UV - 0.5) * vec2(1.78, 1.0);
	float r = length(p);
	float a = atan(p.y, p.x);
	float spokes = smoothstep(0.992, 1.0, cos(a * 7.0 + sin(r * 6.0) * 0.5));
	float rings = smoothstep(0.94, 1.0, cos(r * 40.0 + a * 1.7));
	float reach = 1.08 - web * 1.08;
	float inside = smoothstep(reach, reach + 0.12, r);
	float w = max(spokes, rings * 0.7) * inside;
	col = mix(col, vec3(0.86, 0.85, 0.80), clamp(w * 0.9 + web * inside * 0.35, 0.0, 1.0));
	COLOR = vec4(col, 1.0);
}
"""

## The main scene (DV1's hooks), or any object with them; null in tests that only read the camera.
var scene: Object = null
var phase := ""
var grey := 0.0
var web := 0.0
var roll := 0.0
## The hooks called, in order (tests).
var calls: Array[String] = []
var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial
var _eye := Transform3D.IDENTITY
var _camera: Variant = null
var _freed_at := -1.0
var _watching := false

func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	_mat.shader = shader
	_rect.material = _mat
	_rect.visible = false
	_layer.add_child(_rect)

## One frame. `row`: this player's web row from the host (null when not webbed), `host_now` host time, `eye` the main
## camera's transform as the player last saw (taken when the sequence starts), `limb` the host's posed arm (world
## points, shoulder first), `hang` this player's hang point's floor spot (INF unknown).
func update(row: Variant, host_now: float, eye: Transform3D, limb: Array, hang: Vector3) -> void:
	if row is Dictionary:
		var caught_at := float(row.get("caughtAt", host_now))
		if phase == "" or phase == "free":
			phase = "grab"
			_eye = eye
			_freed_at = -1.0
			_hook("defer_watching")
		var since := host_now - caught_at
		if since < GRAB:
			phase = "grab"
			grey = 0.0
			web = 0.0
			roll = 0.0
			_camera = _eye
		elif since < GRAB + PULL:
			phase = "pull"
			var f := clampf((since - GRAB) / PULL, 0.0, 1.0)
			grey = f
			web = f
			roll = PI * clampf((since - GRAB - (PULL - ROLL)) / ROLL, 0.0, 1.0)
			var along := _eye.origin
			if limb.size() >= 2:
				along = _along(limb, smoothstep(0.0, 1.0, f))
			var xf := Transform3D(_eye.basis, along)
			_camera = xf.rotated_local(Vector3.FORWARD, roll)
		else:
			grey = 1.0
			web = 1.0
			roll = PI
			if phase != "held":
				phase = "held"
				_watching = _hook("watch_crewmate")
			if _watching:
				_camera = null
			else:
				var at := hang if hang.is_finite() else _eye.origin
				var sway := sin(host_now * 0.6) * 0.06
				var held := Transform3D(Basis.from_euler(Vector3(-0.5, host_now * 0.04, 0.0)), at + Vector3(sway, CEILING - HELD_EYE, 0.0))
				_camera = held.rotated_local(Vector3.FORWARD, PI + sway)
	elif phase != "" and phase != "free":
		phase = "free"
		_freed_at = host_now
		if _watching:
			_hook("stop_watching")
		_watching = false
		_camera = null
	if phase == "free":
		var f := clampf((host_now - _freed_at) / PEEL, 0.0, 1.0)
		grey = 1.0 - f
		web = 1.0 - f
		roll = 0.0
		if f >= 1.0:
			phase = ""
	if _rect != null:
		_rect.visible = grey > 0.001 or web > 0.001
		_mat.set_shader_parameter("grey", grey)
		_mat.set_shader_parameter("web", web)

## The camera this screen should use now, or null (the player's own, or DV1's watch view).
func camera() -> Variant:
	return _camera

## Where the hand closes in the grab: just under the camera, a little ahead (the throat).
func grab_point() -> Vector3:
	return _eye.origin - _eye.basis.y * 0.22 - _eye.basis.z * 0.22

## A point a fraction of the way back along the arm, from the hand (its last point) to the shoulder (its first).
static func _along(limb: Array, f: float) -> Vector3:
	var pts: Array[Vector3] = []
	for i in range(limb.size() - 1, -1, -1):
		var p: Variant = limb[i]
		pts.append(p if p is Vector3 else Vector3(float(p[0]), float(p[1]), float(p[2])))
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	var want := total * f
	for i in range(1, pts.size()):
		var d := pts[i - 1].distance_to(pts[i])
		if want <= d or i == pts.size() - 1:
			return pts[i - 1].lerp(pts[i], clampf(want / maxf(d, 1e-6), 0.0, 1.0))
		want -= d
	return pts[-1]

func _hook(name: String) -> bool:
	calls.append(name)
	if scene != null and is_instance_valid(scene) and scene.has_method(name):
		var out: Variant = scene.call(name)
		return out != false
	return false
