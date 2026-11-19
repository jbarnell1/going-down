extends RefCounted

const DURATION := 1.3

## A slanting patch of shadow crossing the threshold, fixed to the floor.
static func show_at(level: Node3D, event: Dictionary, age: float) -> void:
	var patch := MeshInstance3D.new()
	patch.name = "DoorwayShadow"
	patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.65, 2.1)
	patch.mesh = plane
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, shadows_disabled, depth_draw_never;
uniform float strength;
void fragment() {
	vec2 p = UV - vec2(0.5);
	float width = abs(p.x - 0.42 * p.y);
	float penumbra = 1.0 - smoothstep(0.055, 0.27, width);
	float edge = 1.0 - smoothstep(0.24, 0.50, abs(p.y));
	ALBEDO = vec3(0.014, 0.011, 0.012);
	ALPHA = 0.80 * strength * penumbra * edge;
}"""
	var ink := ShaderMaterial.new()
	ink.shader = shader
	patch.material_override = ink
	level.add_child(patch)
	var middle := Vector3(float(event.x), float(event.y) + 0.025, float(event.z))
	var axis := Vector3.RIGHT if event.alongX else Vector3.BACK
	patch.rotation.y = 0.0 if event.alongX else PI * 0.5
	var move_shadow := func(fraction: float) -> void:
		patch.global_position = middle + axis * lerpf(-1.0, 1.0, fraction)
		ink.set_shader_parameter("strength", minf(1.0, minf(fraction, 1.0 - fraction) * 6.0))
	move_shadow.call(age / DURATION)
	var tween := patch.create_tween()
	tween.tween_method(move_shadow, age / DURATION, 1.0, DURATION - age)
	tween.tween_callback(patch.queue_free)
