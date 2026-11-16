# The lift at the landing, drawn where the rules' car is (plan.car from src/sim/run.ts carGeometry):
# a small steel room with its own light, two sliding doors, the floor split into a BANK half (left as
# you walk in) and a DOWN half, a door-hold button inside, and on the landing a call button and the
# indicator above the doors. Built in the car's frame: origin at the middle of the doorway on the wall
# line at floor height, x to the right walking in, z OUT of the car (the car is z = -2 .. 0), y up.
# Like src/render/elevator.ts. It only shows what the rules say (doors open, indicator, votes).
class_name Lift
extends Node3D

const CAR_H := 2.5
const HALF := 1.0
const DEPTH := 2.0
const DOOR_HALF := 0.6
const DOOR_H := 2.25
const FRONT := 0.09
const PANEL_SLIDE := 0.57
const DOOR_SECONDS := 0.9
const HOLD_BUTTON := Vector2(0.84, 1.15)
const CALL_BUTTON := Vector2(-0.9, 1.12)
## The landing's wall face (the wall is drawn Level.WALL_T thick, centred on the wall line).
const LAND := Level.WALL_T * 0.5

var doors := 0.0          # 0 shut .. 1 open, as drawn
var doors_target := 0.0
var indicator_text := ""
var _ind_img: Image
var _ind_tex: ImageTexture
var _ind_key := ""
var _left: Node3D
var _right: Node3D
var _call_mat: ShaderMaterial
var _hold_mat: ShaderMaterial
var _bank_mat: ShaderMaterial
var _down_mat: ShaderMaterial
var _lamp: OmniLight3D
var _lamp_panel: ShaderMaterial
var _t := 0.0
var _vote := ""
var _light := 1.0

func build(car: Dictionary) -> void:
	position = Vector3(float(car.doorX), float(car.floorY), float(car.doorZ))
	var right := Vector3(float(car.rightX), 0, float(car.rightZ))
	var inv := Vector3(float(car.inX), 0, float(car.inZ))
	basis = Basis(right, Vector3.UP, -inv)
	var steel := Level.prop_material(Color(0.58, 0.62, 0.64))
	var dark := Level.prop_material(Color(0.19, 0.21, 0.23))
	var door_mat := Level.prop_material(Color(0.66, 0.71, 0.73))
	var ceil := Level.prop_material(Color(0.17, 0.2, 0.21))
	# Walls, ceiling.
	_box(Vector3(0, CAR_H * 0.5, -DEPTH - 0.02), Vector3(HALF * 2, CAR_H, 0.04), steel)
	_box(Vector3(-HALF - 0.02, CAR_H * 0.5, -DEPTH * 0.5), Vector3(0.04, CAR_H, DEPTH), steel)
	_box(Vector3(HALF + 0.02, CAR_H * 0.5, -DEPTH * 0.5), Vector3(0.04, CAR_H, DEPTH), steel)
	_box(Vector3(0, CAR_H + 0.02, -DEPTH * 0.5), Vector3(HALF * 2, 0.04, DEPTH), ceil)
	# Handrail at the back.
	_box(Vector3(0, 0.95, -DEPTH + 0.06), Vector3(HALF * 1.8, 0.05, 0.05), dark)
	# Front wall inside face, around the door opening.
	var fw := HALF - DOOR_HALF
	_box(Vector3(-DOOR_HALF - fw * 0.5, CAR_H * 0.5, -FRONT - 0.01), Vector3(fw, CAR_H, 0.02), steel)
	_box(Vector3(DOOR_HALF + fw * 0.5, CAR_H * 0.5, -FRONT - 0.01), Vector3(fw, CAR_H, 0.02), steel)
	_box(Vector3(0, (DOOR_H + CAR_H) * 0.5, -FRONT - 0.01), Vector3(DOOR_HALF * 2, CAR_H - DOOR_H, 0.02), steel)
	# A dark frame around the doors on the landing side.
	_box(Vector3(-DOOR_HALF - 0.06, DOOR_H * 0.5, LAND + 0.02), Vector3(0.12, DOOR_H + 0.12, 0.04), dark)
	_box(Vector3(DOOR_HALF + 0.06, DOOR_H * 0.5, LAND + 0.02), Vector3(0.12, DOOR_H + 0.12, 0.04), dark)
	_box(Vector3(0, DOOR_H + 0.06, LAND + 0.02), Vector3(DOOR_HALF * 2 + 0.24, 0.12, 0.04), dark)
	# Doors.
	_left = Node3D.new()
	_right = Node3D.new()
	add_child(_left)
	add_child(_right)
	_box(Vector3(-DOOR_HALF * 0.5, DOOR_H * 0.5, -0.0475), Vector3(DOOR_HALF, DOOR_H, 0.035), door_mat, _left)
	_box(Vector3(DOOR_HALF * 0.5, DOOR_H * 0.5, -0.0475), Vector3(DOOR_HALF, DOOR_H, 0.035), door_mat, _right)
	# Floor: BANK on the left walking in (x < 0), DOWN on the right.
	_bank_mat = Level.prop_material(Color.WHITE, _paint("BANK", Color("#e8a21c"), Color("#2a1a05"), false))
	_down_mat = Level.prop_material(Color.WHITE, _paint("DOWN", Color("#b8231c"), Color("#f6efe6"), true))
	_floor_half(-0.5, _bank_mat)
	_floor_half(0.5, _down_mat)
	# The car's light.
	_lamp_panel = Level.glow_material(Color(0.9, 0.95, 1.0), 1.0)
	_box(Vector3(0, CAR_H - 0.01, -DEPTH * 0.5), Vector3(0.9, 0.02, 0.9), _lamp_panel)
	_lamp = OmniLight3D.new()
	_lamp.position = Vector3(0, CAR_H - 0.25, -DEPTH * 0.5)
	_lamp.light_color = Color(0.9, 0.95, 1.0)
	_lamp.light_energy = 0.55
	_lamp.omni_range = 3.2
	_lamp.omni_attenuation = 1.6
	add_child(_lamp)
	# Indicator above the doors, landing side.
	_ind_img = Image.create(26, 11, false, Image.FORMAT_RGBA8)
	_ind_tex = ImageTexture.create_from_image(_ind_img)
	var q := QuadMesh.new()
	q.size = Vector2(0.52, 0.22)
	var ind := MeshInstance3D.new()
	ind.mesh = q
	ind.material_override = Level.glow_material(Color.WHITE, 1.0, _ind_tex)
	ind.position = Vector3(0, DOOR_H + 0.38, LAND + 0.045)
	add_child(ind)
	_box(Vector3(0, DOOR_H + 0.38, LAND + 0.03), Vector3(0.62, 0.3, 0.02), dark)
	# The same indicator inside, over the doors, for the ride.
	var ind_in := MeshInstance3D.new()
	ind_in.mesh = q
	ind_in.material_override = ind.material_override
	ind_in.position = Vector3(0, DOOR_H + 0.12, -FRONT - 0.03)
	ind_in.rotation = Vector3(0, PI, 0)
	ind_in.scale = Vector3(0.8, 0.8, 0.8)
	add_child(ind_in)
	show_indicator("", false, 0)
	# Call button on the landing wall, hold button inside.
	_box(Vector3(CALL_BUTTON.x, CALL_BUTTON.y, LAND + 0.02), Vector3(0.14, 0.26, 0.03), dark)
	_call_mat = Level.glow_material(Color(1.0, 0.55, 0.15), 0.25)
	_box(Vector3(CALL_BUTTON.x, CALL_BUTTON.y, LAND + 0.04), Vector3(0.06, 0.06, 0.02), _call_mat)
	_box(Vector3(HOLD_BUTTON.x, HOLD_BUTTON.y, -FRONT - 0.03), Vector3(0.14, 0.2, 0.03), dark)
	_hold_mat = Level.glow_material(Color(0.4, 1.0, 0.5), 0.25)
	_box(Vector3(HOLD_BUTTON.x, HOLD_BUTTON.y, -FRONT - 0.05), Vector3(0.06, 0.06, 0.02), _hold_mat)

func _box(pos: Vector3, size: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	(parent if parent else self).add_child(mi)
	return mi

func _floor_half(x: float, mat: ShaderMaterial) -> void:
	var q := PlaneMesh.new()
	q.size = Vector2(1.0, 1.9)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = mat
	mi.position = Vector3(x, 0.006, -DEPTH * 0.5)
	add_child(mi)

# The floor paint (src/render/elevator.ts paintHalf): the word twice, stretched along the car, against
# the dividing line, with a hazard edge along it.
func _paint(word: String, fill: Color, ink: Color, edge_left: bool) -> ImageTexture:
	var w := 48
	var h := 92
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	var ex := 0 if edge_left else w - 3
	for y in range(0, h, 6):
		var c := Color("#f2d43a") if (y / 6) % 2 == 0 else Color("#151515")
		img.fill_rect(Rect2i(ex, y, 3, 6), c)
	img.fill_rect(Rect2i(w - 2 if edge_left else 0, 0, 2, h), Color("#1b1b18"))
	var tw := PixelFont.width(word)
	var sx := 6 if edge_left else w - 6 - tw
	# Image top is the back of the car: upright there for someone walking in, turned round by the doors.
	PixelFont.blit(img, word, Vector2i(sx, 10), ink, Vector2i(1, 2))
	PixelFont.blit(img, word, Vector2i(sx, 68), ink, Vector2i(1, 2), true)
	var t := ImageTexture.create_from_image(img)
	return t

## `label` up to two characters; `arrow` -1 down, 1 up, 0 none; `lit` bright, else a faint glow.
func show_indicator(label: String, lit: bool, arrow: int) -> void:
	var key := "%s|%s|%d" % [label, lit, arrow]
	if key == _ind_key:
		return
	_ind_key = key
	indicator_text = label
	_ind_img.fill(Color("#0b0605"))
	var faint := Color("#2a0f06")
	PixelFont.blit(_ind_img, "▼", Vector2i(2, 2), faint)
	PixelFont.blit(_ind_img, "88", Vector2i(12, 2), faint)
	var on := Color("#ffb02a") if lit else Color("#7a3a12")
	if arrow != 0:
		PixelFont.blit(_ind_img, "▼" if arrow < 0 else "▲", Vector2i(2, 2), on)
	var lw := PixelFont.width(label)
	PixelFont.blit(_ind_img, label, Vector2i(24 - lw, 2), on)
	_ind_tex.update(_ind_img)

func set_doors(open: bool, instant := false) -> void:
	doors_target = 1.0 if open else 0.0
	if instant:
		doors = doors_target

func set_call_lit(on: bool) -> void:
	_call_mat.set_shader_parameter("energy", 1.6 if on else 0.25)

func set_hold_lit(on: bool) -> void:
	_hold_mat.set_shader_parameter("energy", 1.6 if on else 0.25)

## The half the player stands on ("bank", "down" or "").
func set_vote(side: String) -> void:
	_vote = side

func set_light(k: float) -> void:
	_light = k

func update(delta: float) -> void:
	_t += delta
	doors = move_toward(doors, doors_target, delta / DOOR_SECONDS)
	var e := doors * doors * (3.0 - 2.0 * doors)
	_left.position.x = -PANEL_SLIDE * e
	_right.position.x = PANEL_SLIDE * e
	var pulse := 0.42 + (0.68 - 0.42) * (0.5 + 0.5 * sin(_t * 5.0))
	_bank_mat.set_shader_parameter("emit", pulse if _vote == "bank" else 0.16)
	_down_mat.set_shader_parameter("emit", pulse if _vote == "down" else 0.16)
	_bank_mat.set_shader_parameter("albedo", Color.WHITE * (1.0 if _vote == "bank" else (0.5 if _vote != "" else 0.85)))
	_down_mat.set_shader_parameter("albedo", Color.WHITE * (1.0 if _vote == "down" else (0.5 if _vote != "" else 0.85)))
	_lamp.light_energy = 0.55 * _light
	_lamp_panel.set_shader_parameter("energy", _light)
