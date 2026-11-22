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
		# LK1: a torch, not a flat hard disc: a hot centre falling smoothly to nothing at the rim, a gentle fall with
		# distance so a near wall does not clip to white, warm white, and not the old blow-out energy.
		t.check(beam.spot_angle_attenuation >= 2.0 and beam.spot_angle_attenuation <= 5.0, "the beam's centre is bright and its edge soft (angle attenuation %.2f, 2 to 5; 1 and below drew the flat hard disc)" % beam.spot_angle_attenuation)
		t.check(beam.spot_attenuation > 0.3 and beam.spot_attenuation < 1.0, "the beam falls off gently with distance (%.2f, 0.3 to 1.0)" % beam.spot_attenuation)
		t.check(beam.light_energy >= 1.0 and beam.light_energy <= 2.5, "the beam's energy is useful without blowing out (%.2f, 1 to 2.5)" % beam.light_energy)
		t.check(beam.light_color.r >= beam.light_color.g and beam.light_color.g > beam.light_color.b and beam.light_color.b > 0.5, "the beam is warm white (%s)" % beam.light_color)
	var src := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(src.contains("beam.light_energy = LampViewScript.BEAM_ENERGY * (") and not src.contains("beam.light_energy = 4.0"), "the game keeps the beam at the lamp's energy every frame")
	view.update(level, [{"playerId": "a", "on": false, "x": 1.0, "y": 1.6, "z": 2.0, "pitch": 0.0, "yaw": 0.5, "range": 12.0, "charge": 30.0}], "a")
	t.check(view.beams.is_empty(), "a lamp switched off leaves no beam")
	view.free()
	level.free()
