extends Node3D

const Orientation = preload("res://sim/orientation.gd")
const FaceCodec = preload("res://face/face_codec.gd")
const CrewView = preload("res://client/crew_view.gd")

const BLUE := Color("#233b6a")
const YELLOW := Color("#f0c84b")
const BOARD := Color("#b48957")
const STEEL := Color("#393c38")

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

static func dress(parent: Node3D) -> void:
	var x := (Orientation.CENTRE + 0.5) * Orientation.CELL
	var end := Orientation.LANDING_ROW * Orientation.CELL
	_sign(parent, Vector3(x, 1.86, 2.10), 0.0, "CONTINUANCE PRACTICE", "WALK: W A S D\nLOOK: MOUSE")
	_sign(parent, Vector3(x + 2.91, 1.72, end - 3.0), -PI / 2.0, "TAKE A READING", "E: TAKE OUT THE INSTRUMENT\nHOLD RIGHT MOUSE TO RECORD")
	_sign(parent, Vector3(x - 2.91, 1.72, end - 6.0), PI / 2.0, "WATCH THE NEEDLE", "CHANGE VIEW IF THE NEEDLE STAYS STILL\nGIVE THE CART ROOM IF IT HONKS")
	_sign(parent, Vector3(x + 2.91, 1.72, end - 0.9), -PI / 2.0, "BRING IT BACK", "EARN 1 PRACTICE CREDIT. F: CALL THE LIFT\nSTAND ON BANK TO FINISH")
	for row in range(3, Orientation.LANDING_ROW):
		for side: float in [-1.0, 1.0]:
			_box(parent, Vector3(x + side * 0.95, 0.009, (row + 0.5) * Orientation.CELL), Vector3(0.10, 0.014, 1.25), YELLOW)

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
