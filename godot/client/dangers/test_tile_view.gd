# Dangers (DG0): the template kind's view (sim/dangers/test_tile.gd). A pale floor tile with a faint glow edge that
# reddens when armed and goes grey when spent; a click (made from arithmetic) on its cue, a thud on its noise.
# Copy this file's shape: build once, follow changed(), play events, dim with the room's light.
extends "res://client/dangers/kind_view.gd"

const SIDE := 1.2

var _mat: StandardMaterial3D
var _click: AudioStreamWAV
var _thud: AudioStreamWAV

func build(rec: Dictionary, _ctx: Dictionary) -> void:
	var mesh := MeshInstance3D.new()
	var quad := PlaneMesh.new()
	quad.size = Vector2(SIDE, SIDE)
	mesh.mesh = quad
	mesh.position.y = 0.01
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.75, 0.75, 0.7)
	_mat.emission_enabled = true
	add_child(mesh)
	mesh.material_override = _mat
	_click = click_stream()
	_thud = thud_stream()
	_show(rec)

func changed(rec: Dictionary, _before: Dictionary, _ht: float) -> void:
	_show(rec)

func frame(_rec: Dictionary, _ht: float, _delta: float) -> void:
	# Follow the room's light: no glow in the dark.
	_mat.emission_energy_multiplier = 0.4 if lit(global_position + Vector3(0, 0.3, 0)) else 0.0

func event(e: Dictionary, _ht: float) -> void:
	var at := Vector3(float(e.get("x", global_position.x)), float(e.get("y", global_position.y)), float(e.get("z", global_position.z)))
	match str(e["type"]):
		"dangerCue":
			play_cue(_click, at, &"item")
		"dangerNoise":
			play_cue(_thud, at, &"effect")

## The click and the thud, made from arithmetic at the effects' level (tests/test_danger_test_tile.gd measures them).
static func click_stream() -> AudioStreamWAV:
	return tone(2400.0, 0.05, 60.0, 22050, -12.0)

static func thud_stream() -> AudioStreamWAV:
	return tone(90.0, 0.4, 9.0, 22050, -12.0)

func _show(rec: Dictionary) -> void:
	match str(rec["state"]):
		"armed":
			_mat.emission = Color(0.9, 0.2, 0.1)
		"spent":
			_mat.emission = Color(0.2, 0.2, 0.2)
		_:
			_mat.emission = Color(0.6, 0.6, 0.5)
