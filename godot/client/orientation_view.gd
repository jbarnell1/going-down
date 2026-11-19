extends Node3D

const Orientation = preload("res://sim/orientation.gd")
const FaceCodec = preload("res://face/face_codec.gd")
const CrewView = preload("res://client/crew_view.gd")

const BLUE := Color("#233b6a")
const YELLOW := Color("#f0c84b")
const BOARD := Color("#b48957")
const STEEL := Color("#393c38")
const STANDEE_CLICK = preload("res://assets/sfx/annex/staple_soft.ogg")
const POP_LEAD := 0.16
const POP_TIME := 0.29
const FALL_BEGINS := 0.76
const FALL_TIME := 0.36

var _face: MeshInstance3D
var _face_code := " "
var _honk: AudioStreamPlayer3D

static func _box(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	node.mesh = shape
	var ink := StandardMaterial3D.new()
	ink.albedo_color = color
	node.material_override = ink
	node.position = at
	parent.add_child(node)
	return node

static func _sign(parent: Node3D, at: Vector3, yaw: float, title: String, instructions: String) -> void:
	var panel := Node3D.new()
	parent.add_child(panel)
	panel.position = at
	panel.rotation.y = yaw
	var backing := _box(panel, Vector3.ZERO, Vector3(2.30, 0.78, 0.035), BLUE)
	(backing.material_override as StandardMaterial3D).shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var header := Label3D.new()
	header.text = title
	header.font_size = 32
	header.pixel_size = 0.005
	header.modulate = YELLOW
	header.outline_size = 0
	header.position = Vector3(0, 0.23, 0.023)
	panel.add_child(header)
	var body := Label3D.new()
	body.text = instructions
	body.font_size = 24
	body.pixel_size = 0.0045
	body.outline_size = 0
	body.position = Vector3(0, -0.10, 0.023)
	panel.add_child(body)

static func dress(parent: Node3D, prelude := false) -> void:
	var x := (Orientation.CENTRE + 0.5) * Orientation.CELL
	var end := Orientation.LANDING_ROW * Orientation.CELL
	var cue_z := end - 1.6
	# Face the lift from the first open part of the corridor, above the taped path.
	_sign(parent, Vector3(x, 2.68, cue_z), 0.0, "CONTINUANCE PRACTICE", "FOLLOW THE YELLOW TAPE\nW A S D: WALK   MOUSE: LOOK")
	for side: float in [-1.0, 1.0]:
		_box(parent, Vector3(x + side * 0.80, 3.13, cue_z), Vector3(0.045, 0.15, 0.045), STEEL)
	_sign(parent, Vector3(x + 2.91, 1.72, end - 3.0), -PI / 2.0, "TAKE A READING", "E: TAKE OUT THE INSTRUMENT\nHOLD RIGHT MOUSE TO RECORD")
	_sign(parent, Vector3(x - 2.91, 1.72, end - 6.0), PI / 2.0, "WATCH THE NEEDLE", "CHANGE VIEW IF THE NEEDLE STAYS STILL\nGIVE THE CART ROOM IF IT HONKS")
	var bank := "BANK PRACTICE PAY TO ENTER THE CLINIC" if prelude else "STAND ON BANK TO FINISH"
	_sign(parent, Vector3(x + 2.91, 1.72, end - 0.9), -PI / 2.0, "BRING IT BACK", "EARN 1 PRACTICE CREDIT. F: CALL THE LIFT\n" + bank)
	for row in range(3, Orientation.LANDING_ROW):
		for side: float in [-1.0, 1.0]:
			_box(parent, Vector3(x + side * 0.95, 0.009, (row + 0.5) * Orientation.CELL), Vector3(0.10, 0.014, 1.25), YELLOW)
	_add_standees(parent)

static func _add_standees(parent: Node3D) -> void:
	var props: Array[Dictionary] = []
	for id in Orientation.STANDEE_BAYS.size():
		var bay: Vector2 = Orientation.STANDEE_BAYS[id]
		var side := -1.0 if id == 0 else 1.0
		var base := Node3D.new()
		base.position = Vector3(bay.x, 0.0, bay.y)
		parent.add_child(base)
		_box(base, Vector3(0.0, 0.10, 0.0), Vector3(0.62, 0.20, 0.40), STEEL)
		_box(base, Vector3(0.0, 0.13, 0.206), Vector3(0.50, 0.04, 0.016), YELLOW)
		var card := Node3D.new()
		card.visible = false
		base.add_child(card)
		_box(card, Vector3(0.0, 0.60, 0.0), Vector3(0.57, 1.05, 0.036), BOARD)
		_box(card, Vector3(0.0, 1.25, 0.0), Vector3(0.38, 0.39, 0.036), BOARD)
		_box(card, Vector3(0.0, 1.43, 0.0), Vector3(0.43, 0.13, 0.052), YELLOW)
		_box(card, Vector3(0.0, 0.80, 0.023), Vector3(0.53, 0.26, 0.013), BLUE)
		var arm := _box(card, Vector3(side * 0.27, 1.11, 0.0), Vector3(0.14, 0.64, 0.036), BOARD)
		arm.rotation.z = -side * 0.62
		for eye: float in [-0.075, 0.075]:
			_box(card, Vector3(eye, 1.27, 0.025), Vector3(0.045, 0.058, 0.012), STEEL)
		var latch := AudioStreamPlayer3D.new()
		latch.stream = STANDEE_CLICK
		latch.volume_db = -10.0
		latch.bus = &"Effects"
		latch.max_distance = 9.0
		base.add_child(latch)
		props.append({"card": card, "latch": latch, "played": false})
	parent.set_meta(&"orientation_standees", props)

## Shared host times animate the boards. A late visitor sees the settled pose without replaying the sound.
static func show_standees(parent: Node3D, stamps: Variant, now: float) -> void:
	if not stamps is Array:
		return
	var props: Array = parent.get_meta(&"orientation_standees", [])
	for id in props.size():
		var at := float(stamps[id])
		if at < 0.0 or now < at:
			continue
		var age := now - at
		var prop: Dictionary = props[id]
		var card: Node3D = prop["card"]
		if not prop["played"]:
			prop["played"] = true
			if age < POP_LEAD:
				(prop["latch"] as AudioStreamPlayer3D).play()
		card.visible = age >= POP_LEAD
		var rise := clampf((age - POP_LEAD) / POP_TIME, 0.0, 1.0)
		var lift := 1.0 - (1.0 - rise) * (1.0 - rise)
		card.position = Vector3((0.39 if id == 0 else -0.39) * lift, lerpf(-1.3, 0.13, lift), 0.0)
		if id == 1:
			var fall := clampf((age - FALL_BEGINS) / FALL_TIME, 0.0, 1.0)
			card.rotation.x = -PI * 0.5 * fall * fall
			card.position.y -= 0.08 * fall

func _ready() -> void:
	_box(self, Vector3(0, 0.21, 0), Vector3(0.64, 0.14, 0.5), BLUE)
	_box(self, Vector3(0, 0.68, 0), Vector3(0.20, 0.90, 0.25), STEEL)
	_box(self, Vector3(0, 1.02, 0.05), Vector3(0.58, 0.78, 0.105), BOARD)
	_box(self, Vector3(0, 1.54, 0.05), Vector3(0.43, 0.43, 0.105), BOARD)
	for side: float in [-1.0, 1.0]:
		_box(self, Vector3(side * 0.36, 1.03, 0.05), Vector3(0.15, 0.66, 0.095), BOARD)
		for axle: float in [-1.0, 1.0]:
			var wheel := MeshInstance3D.new()
			var tyre := CylinderMesh.new()
			tyre.top_radius = 0.115
			tyre.bottom_radius = 0.115
			tyre.height = 0.09
			wheel.mesh = tyre
			var rubber := StandardMaterial3D.new()
			rubber.albedo_color = STEEL
			wheel.material_override = rubber
			wheel.position = Vector3(side * 0.29, 0.11, axle * 0.17)
			wheel.rotation.z = PI / 2.0
			add_child(wheel)
	_face = MeshInstance3D.new()
	var sticker := QuadMesh.new()
	sticker.size = Vector2(0.34, 0.34)
	_face.mesh = sticker
	_face.position = Vector3(0, 1.54, 0.105)
	add_child(_face)
	set_crew([])
	_honk = AudioStreamPlayer3D.new()
	_honk.stream = _make_honk()
	_honk.bus = &"Effects"
	_honk.unit_size = 4.0
	_honk.max_distance = 16.0
	add_child(_honk)
	reset()

func reset() -> void:
	visible = false

func set_crew(codes: Array[String]) -> void:
	var face := "" if codes.is_empty() else str(codes.back())
	if face == _face_code:
		return
	_face_code = face
	var texture := FaceCodec.decode(face)
	var ink := StandardMaterial3D.new()
	ink.albedo_texture = texture if texture != null else CrewView.default_face()
	ink.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_face.material_override = ink

func show_pose(pose: Variant, show: bool) -> void:
	visible = pose != null and show
	if pose != null:
		position = Vector3(float(pose.x), float(pose.y), float(pose.z))
		rotation.y = float(pose.yaw) + PI

func honk() -> void:
	_honk.play()

static func _make_honk() -> AudioStreamWAV:
	const RATE := 22050
	const LENGTH := 0.21
	var bytes := PackedByteArray()
	bytes.resize(int(RATE * LENGTH) * 2)
	for i in int(RATE * LENGTH):
		var t := float(i) / RATE
		var shape := minf(1.0, t / 0.025) * minf(1.0, (LENGTH - t) / 0.075)
		var tone := 0.65 * sin(TAU * 253.0 * t) + 0.23 * sin(TAU * 505.0 * t) + 0.12 * sin(TAU * 761.0 * t)
		bytes.encode_s16(i * 2, int(11000.0 * shape * tone))
	var sound := AudioStreamWAV.new()
	sound.format = AudioStreamWAV.FORMAT_16_BITS
	sound.mix_rate = RATE
	sound.data = bytes
	return sound
