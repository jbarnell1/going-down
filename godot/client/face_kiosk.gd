# The prison's face kiosk on screen (owner, 17 November: "a kiosk in the prison that can enable players
# to change their faces, separate from the shop and skill tree"): the same face editor as the start
# screen (face/face_editor.tscn), over the game, opening on the player's current face. Done sends
# `changed` with the new face; Cancel (or Esc) keeps the old one. Either way `closed` follows. It decides
# nothing about the network: the game sends the face (net/room_client.gd set_face). The mouse is never
# captured while it is open.
extends Control

signal changed(code: String)
signal closed

## Save the new face as this computer's last face (the start screen's next opening). The game turns it
## on (under automation the save goes to the test file); the prison demo leaves it off.
var remember := false
var editor: FaceEditor = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _process(_delta: float) -> void:
	# Parented to a plain Node, so it follows the window itself.
	var want := get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want

func is_open() -> bool:
	return visible and editor != null and not editor.finished

## Opens the editor on `code` (the player's current face; "" opens on the last saved face, else the smile).
func open(code: String) -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	if editor == null:
		editor = (load("res://face/face_editor.tscn") as PackedScene).instantiate() as FaceEditor
		editor.name = "KioskEditor"
		editor.title = "CHANGE YOUR FACE"
		editor.remember = remember
		editor.start_code = code
		editor.set_anchors_preset(Control.PRESET_FULL_RECT)
		editor.done.connect(_on_done)
		editor.cancelled.connect(_on_cancelled)
		add_child(editor)
	else:
		editor.remember = remember
		editor.begin(code)
	visible = true
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## Closes it as Cancel does (the run ended, the player left).
func close() -> void:
	if is_open():
		editor.press("cancel")
	visible = false

## A key for the editor (the game routes keys here while it is open).
func key(k: InputEventKey) -> void:
	if is_open():
		editor.key(k)

func _on_done(code: String, _texture: ImageTexture) -> void:
	visible = false
	changed.emit(code)
	closed.emit()

func _on_cancelled() -> void:
	visible = false
	closed.emit()
