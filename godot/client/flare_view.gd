extends Node

var lights := {}
var blind := 0.0
var _level: Node3D

func update(level: Node3D, bursts: Variant, my_id: String, time: float) -> void:
	if _level != level:
		lights.clear()
		_level = level
	blind = 0.0
	var live := {}
	if bursts is Array:
		for b: Dictionary in bursts:
			if str(b.blind) == my_id:
				blind = maxf(blind, clampf((float(b.blindUntil) - time) * 4.0, 0.0, 1.0))
			if float(b.until) <= time:
				continue
			var id := int(b.id)
			live[id] = true
			var light: OmniLight3D = lights.get(id)
			if not is_instance_valid(light):
				light = _make_light()
				level.add_child(light)
				light.position = Vector3(float(b.x), float(b.y) + 0.6, float(b.z))
				lights[id] = light
			light.light_energy = 5.0 * clampf((float(b.until) - time) * 2.0, 0.0, 1.0)
	for id: int in lights.keys():
		if not live.has(id):
			if is_instance_valid(lights[id]):
				lights[id].queue_free()
			lights.erase(id)

static func _make_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "FlareBurst"
	light.light_color = Color(1.0, 0.40, 0.16)
	light.omni_range = 9.0
	var ember := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.13
	mesh.height = 0.26
	ember.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.66, 0.28)
	ember.material_override = material
	light.add_child(ember)
	return light
