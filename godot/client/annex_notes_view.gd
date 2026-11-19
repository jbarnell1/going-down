extends Node3D

const Floor = preload("res://sim/floor.gd")
const Level = preload("res://client/level.gd")
const Move = preload("res://sim/move.gd")
const Sight = preload("res://sim/sight.gd")

const PROMPT := "F  READ STICKY NOTE"
const REACH := 3.0
const HEIGHT := 1.49
const PAPER := Color("#eacf78")
const INK := Color("#342d25")

var sheets: Dictionary = {}

static func wall_face(row: Dictionary) -> Vector3:
	var yaw := float(row["yaw"])
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

static func wall_point(row: Dictionary) -> Vector3:
	return Vector3(float(row["x"]), int(row["level"]) * Move.LEVEL_HEIGHT + HEIGHT, float(row["z"])) \
		+ wall_face(row) * (Level.WALL_T * 0.5 + 0.018)

## Only the actual host notes for the placed floor get paper. The reader never makes up a note.
func show_notes(rows: Array) -> void:
	var seen := {}
	for row: Dictionary in rows:
		var id := int(row["id"])
		seen[id] = true
		if not sheets.has(id):
			var sheet := MeshInstance3D.new()
			var paper := QuadMesh.new()
			paper.size = Vector2(0.37, 0.31)
			sheet.mesh = paper
			sheet.material_override = _paper(str(row["text"]))
			sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var face := wall_face(row)
			sheet.transform = Transform3D(Basis(Vector3.UP.cross(face), Vector3.UP, face), wall_point(row))
			add_child(sheet)
			sheets[id] = {"sheet": sheet, "row": row}
	for id: int in sheets.keys():
		if not seen.has(id):
			(sheets[id]["sheet"] as MeshInstance3D).queue_free()
			sheets.erase(id)

static func _paper(text: String) -> StandardMaterial3D:
	var image := Image.create(140, 116, false, Image.FORMAT_RGB8)
	image.fill(PAPER)
	image.fill_rect(Rect2i(0, 0, 140, 12), Color("#d7b865"))
	var lines := PixelFont.wrap(text.to_upper(), 20)
	for i in lines.size():
		PixelFont.blit(image, lines[i], Vector2i(10, 23 + i * 11), INK)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.emission_enabled = true
	mat.emission = Color.WHITE
	mat.emission_texture = mat.albedo_texture
	mat.emission_energy_multiplier = 0.10
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return mat

## Find the paper under the player's gaze, within one room and the approved reading distance.
func focus(plan: Floor.FloorPlan, eye: Vector3, look: Vector3, level: int) -> Dictionary:
	var best: Dictionary = {}
	var score := -INF
	var from := Sight.Point3.make(eye.x, eye.y, eye.z, level)
	for entry: Dictionary in sheets.values():
		var row: Dictionary = entry["row"]
		if int(row["level"]) != level:
			continue
		var sheet: MeshInstance3D = entry["sheet"]
		var offset := sheet.position - eye
		var distance := offset.length()
		if distance <= 0.1 or distance > REACH or offset.dot(sheet.basis.z) >= -0.04:
			continue
		var aim := look.dot(offset / distance)
		if aim < 0.965 or not Sight.has_line_of_sight(plan, from,
				Sight.Point3.make(sheet.position.x, sheet.position.y, sheet.position.z, level)):
			continue
		var candidate := aim - 0.025 * distance
		if candidate >= score:
			best = row
			score = candidate
	return best
