extends Control

const Lamp = preload("res://sim/lamp.gd")
const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
## LK1: the beam drawn as a torch, not a sticker: a bright centre falling off smoothly to nothing at the cone's edge
## (SpotLight3D.spot_angle_attenuation: measured on this renderer, values above 1 soften the rim and below 1 harden it
## into a flat disc; 3 gave the torch's falloff in the prison practice room), a gentle fall with distance so
## a wall an arm's length away does not clip to white (spot_attenuation, the inverse-power exponent: below 1 is
## gentler than the physical square), a warm-white tint, and an energy that is plainly useful in the Arboretum's dark
## and only a warm pool in a lit room. Its reach and width are the rules' lamp (sim/lamp.gd), and it casts no shadow
## (LT1). The faint wider spill is the soft outer part of the same cone: a second light per carried lamp would cost
## a light slot on every mesh it meets (tests/test_light_pairs.gd keeps four for carried lamps) and frame time.
const BEAM_COLOR := Color(1.0, 0.87, 0.68)
const BEAM_ENERGY := 2.0
const BEAM_DECAY := 0.4
const BEAM_SOFT := 3.0
const BEAM_SPECULAR := 0.35

var beams := {}
var own := {}
var _level: Node3D

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func update(level: Node3D, rows: Variant, my_id: String) -> void:
	if _level != level:
		beams.clear()
		_level = level
	own = {}
	var lit := {}
	if rows is Array:
		for row: Dictionary in rows:
			var id := str(row.playerId)
			if id == my_id:
				own = row
			if not row.on:
				continue
			lit[id] = true
			var beam: SpotLight3D = beams.get(id)
			if not is_instance_valid(beam):
				beam = SpotLight3D.new()
				beam.name = "CarriedLamp"
				beam.spot_angle = Lamp.HALF_DEG
				beam.light_color = BEAM_COLOR
				beam.light_energy = BEAM_ENERGY
				beam.spot_attenuation = BEAM_DECAY
				beam.spot_angle_attenuation = BEAM_SOFT
				beam.light_specular = BEAM_SPECULAR
				# LT1: no shadow. The beam moves every frame, so a shadowed one drew its shadow map
				# again every frame, and its texels crawled over the walls (the shimmer the owner saw).
				beam.shadow_enabled = false
				level.add_child(beam)
				beams[id] = beam
			beam.position = Vector3(float(row.x), float(row.y), float(row.z))
			beam.rotation = Vector3(float(row.pitch), float(row.yaw), 0.0)
			beam.spot_range = float(row.range)
	for id: String in beams.keys():
		if not lit.has(id):
			if is_instance_valid(beams[id]):
				beams[id].queue_free()
			beams.erase(id)
	queue_redraw()

func _draw() -> void:
	if own.is_empty():
		return
	var px := maxf(1.0, floorf(size.y / 300.0))
	var time := ceili(float(own.charge))
	var word := "ON" if own.on else "OFF"
	var line := "L  LAMP %s  %d SEC" % [word, time] if time > 0 else "LAMP EMPTY"
	PixelFont.draw_shadowed(self, line, Vector2(10, size.y - 16.0 * px), px, AMBER if own.on else PALE)
