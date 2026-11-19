extends Node3D

const Floor = preload("res://sim/floor.gd")
const Marks = preload("res://sim/marks.gd")
const Move = preload("res://sim/move.gd")
const PixelFont = preload("res://client/pixel_font.gd")

const INKS := [Color("#72ded6"), Color("#ffd176"), Color("#c6a8ff"), Color("#ade47f"),
	Color("#ff9e9d"), Color("#94c3ff"), Color("#f4eba8"), Color("#edadd5")]
const EDGE := Color("#242e31")

var arrows: Dictionary = {}

## Draw only marks approved by the host. Their position and direction never follow the camera.
func show_marks(rows: Array, plan: Floor.FloorPlan, names: Dictionary) -> void:
	var seen := {}
	for row: Dictionary in rows:
		var id := int(row["id"])
		seen[id] = true
		if not arrows.has(id):
			var player := str(row["player"])
			var initial := Marks.initial_of(str(names.get(player, player)))
			var mark := MeshInstance3D.new()
			var paper := QuadMesh.new()
			paper.size = Vector2(0.76, 0.76)
			mark.mesh = paper
			mark.material_override = _paper(_ink(player), initial)
			mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mark.transform = _placement(plan, row)
			add_child(mark)
			arrows[id] = mark
	for id: int in arrows.keys():
		if not seen.has(id):
			(arrows[id] as MeshInstance3D).queue_free()
			arrows.erase(id)

static func _ink(player: String) -> Color:
	var seat := player.substr(1)
	var index := int(seat) - 1 if player.begins_with("c") and seat.is_valid_int() else int(player.hash())
	return INKS[posmod(index, INKS.size())]

static func _paper(ink: Color, initial: String) -> StandardMaterial3D:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for y in range(6, 58):
		var half := mini(y - 6, 23) if y < 33 else 9
		image.fill_rect(Rect2i(32 - half, y, 2 * half + 1, 1), EDGE)
		if half > 2 and y > 8 and y < 55:
			image.fill_rect(Rect2i(34 - half, y, 2 * half - 3, 1), ink)
	var width := PixelFont.width(initial) * 2
	PixelFont.blit(image, initial, Vector2i(32 - floori(width * 0.5), 37), EDGE, Vector2i(2, 2))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.albedo_color = Color(0.82, 0.82, 0.82)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	return mat

static func _placement(plan: Floor.FloorPlan, row: Dictionary) -> Transform3D:
	var x := float(row["x"])
	var z := float(row["z"])
	var level := int(row["level"])
	var normal := Vector3.UP
	var cell := Move.cell_of(plan, Move.Body.make(x, z, level, 0.0))
	if level == 0 and Floor.cell_at(plan, 0, cell.x, cell.y) == Floor.STAIR:
		var stair := Move._stair_under(plan, cell.x, cell.y)
		if stair != null:
			var slope := Move.LEVEL_HEIGHT / (stair.length * float(plan.cell_size))
			normal = Vector3(-Floor.dir_dx(stair.dir) * slope, 1.0, -Floor.dir_dy(stair.dir) * slope).normalized()
	var dir := Marks.dir_vector(int(row["dir"]))
	var tip := Vector3(dir.x, 0.0, dir.y).slide(normal).normalized()
	var surface := Vector3(x, Move.feet_height(plan, level, x, z), z)
	return Transform3D(Basis(tip.cross(normal), tip, normal), surface + normal * 0.025)
