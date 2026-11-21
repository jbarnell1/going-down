# LS1, the standee (North Star B7: "Later, the lobby gains a standee with the face of the last player caught"; H4's
# cardboard figures). A life-size cardboard cut-out of a convict crewmate, printed flat in the suit's orange with the
# mask's screen for a head, and on the screen the face that player drew (face/face_codec.gd; the plain default face if
# they drew none). A strut behind holds it up and a plate on its base names them. Drawn only: no rule sees it.
# client/prison_view.gd show_standee puts it in the lift lobby; the host says whose it is (sim/last_stand.gd `standee`),
# so every screen shows the same one, and the night's next wipe replaces it.
extends Node3D

const BOARD := Color(0.72, 0.6, 0.42)
const SUIT := Color(0.86, 0.46, 0.16)
const SUIT_DARK := Color(0.6, 0.3, 0.1)
const SKIN := Color(0.78, 0.62, 0.5)
const BEZEL := Color(0.08, 0.09, 0.09)
## The card's thickness (m).
const CARD := 0.02

## The face shown (FaceCodec text, "" for the default), the name on the plate, and the screen.
var face_code := ""
var player_name := ""
var screen: MeshInstance3D
var _tex: Texture2D

## Builds the cut-out for `code` and `who` (the player's name). Facing +z.
func build(code: String, who: String) -> void:
	face_code = code
	player_name = who
	var board := Level.prop_material(BOARD)
	var suit := Level.prop_material(SUIT)
	var suit_dark := Level.prop_material(SUIT_DARK)
	var skin := Level.prop_material(SKIN)
	var bezel := Level.prop_material(BEZEL)
	# The base and the strut behind.
	_box(Vector3(0, 0.02, -0.04), Vector3(0.5, 0.04, 0.3), board)
	var strut := _box(Vector3(0, 0.55, -0.2), Vector3(0.08, 1.15, CARD), board)
	strut.rotation.x = -0.32
	# Legs, the suit, the arms hanging, the hands.
	for side: float in [-1.0, 1.0]:
		_box(Vector3(side * 0.11, 0.45, 0), Vector3(0.18, 0.86, CARD), suit_dark)
		_box(Vector3(side * 0.33, 1.08, 0), Vector3(0.12, 0.6, CARD), suit)
		_box(Vector3(side * 0.33, 0.74, 0), Vector3(0.1, 0.1, CARD), skin)
	_box(Vector3(0, 1.17, 0), Vector3(0.5, 0.66, CARD), suit)
	# The neck and the mask's screen for a head.
	_box(Vector3(0, 1.53, 0), Vector3(0.12, 0.08, CARD), skin)
	_box(Vector3(0, 1.74, 0), Vector3(0.36, 0.36, CARD), bezel)
	var tex: Texture2D = FaceCodec.decode(code)
	_tex = tex if tex != null else CrewView.default_face()
	var q := QuadMesh.new()
	q.size = Vector2(0.3, 0.3)
	screen = MeshInstance3D.new()
	screen.name = "StandeeFace"
	screen.mesh = q
	screen.material_override = Level.glow_material(Color.WHITE, 0.85, _tex)
	screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	screen.position = Vector3(0, 1.74, CARD * 0.5 + 0.003)
	add_child(screen)

## The face on the screen, as an image hash (tests compare it with the face the player drew).
func face_hash() -> String:
	return CrewView.texture_hash(_tex)

func _box(at: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	add_child(mi)
	return mi
