extends RefCounted
## LT1b: the carried lamp's beam is cheap and steady. Only how it is drawn; the rules' lamp (sim/lamp.gd,
## what counts as light on a resident) is not touched.

const T = preload("res://tests/t.gd")
const LampView = preload("res://client/lamp_view.gd")

func test_carried_lamp_casts_no_shadow(t: T) -> void:
	var level := Node3D.new()
	var view := LampView.new()
	view.update(level, [{"playerId": "a", "on": true, "x": 1.0, "y": 1.6, "z": 2.0, "pitch": 0.0, "yaw": 0.5, "range": 12.0, "charge": 30.0}], "a")
	var beam := level.get_node_or_null("CarriedLamp") as SpotLight3D
	if t.check(beam != null, "a lit lamp draws a beam"):
		t.check(not beam.shadow_enabled, "the carried lamp's beam casts no shadow (a moving shadow map shimmered on the walls)")
		t.eq(beam.spot_range, 12.0, "the beam reaches as far as the rules' lamp")
		t.eq(beam.spot_angle, 24.0, "the beam is as wide as the rules' lamp")
	view.update(level, [{"playerId": "a", "on": false, "x": 1.0, "y": 1.6, "z": 2.0, "pitch": 0.0, "yaw": 0.5, "range": 12.0, "charge": 30.0}], "a")
	t.check(view.beams.is_empty(), "a lamp switched off leaves no beam")
	view.free()
	level.free()
