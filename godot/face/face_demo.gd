# The face editor, then the face on four crewmates in a lit Clinic corridor, in the game's own picture
# (480 x 270 through the tape shader), standing 1, 2, 3 and 6 m from the camera. Never captures the
# mouse. From the repository root:
#   Godot --path godot --resolution 960x540 --position 40,40 res://face/face_demo.tscn -- [auto=1] [shots=DIR]
# By hand: draw, press Done, look; E draws again, Esc quits.
# auto=1 draws a face with mouse events, takes pictures of the editor (the drawn face and each
# starting face) and of the crewmates wearing each face at each distance into shots (default
# godot/face/shots), then quits. It reads and writes no saved face (the editor's `remember` is off).
extends Node

const Codec := preload("res://face/face_codec.gd")
const Paint := preload("res://face/face_paint.gd")
const EditorScene := preload("res://face/face_editor.tscn")
const VFOV := 70.0                  # the client's camera (crew_demo.gd, main.gd)
const EYE := 1.65
const DISTANCES: Array[float] = [1.0, 2.0, 3.0, 6.0]
const SIDE: Array[float] = [-0.5, 0.55, -0.45, 0.4]   # across the corridor, so all four show at once

var sub: SubViewport
var cam: Camera3D
var world: Node3D
var level: Level
var screen: TextureRect
var crew: Array[CrewView] = []
var hall: Dictionary = {}           # start, along (unit), cells
var editor: FaceEditor
var auto := false
var shots_dir := ""
var log_lines: Array[String] = []

func _ready() -> void:
	shots_dir = ProjectSettings.globalize_path("res://face/shots")
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("shots="):
			shots_dir = a.substr(6)
		elif a == "auto=1":
			auto = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_view()
	_build_floor()
	for i in 4:
		var c := CrewView.new()
		world.add_child(c)
		c.set_skin(i)
		c.set_headwear([&"knit", &"hair", &"none", &"hair"][i])
		c.set_number([7, 23, 41, 96][i])
		c.debug_pose("idle", 1.0)
		crew.append(c)
	editor = EditorScene.instantiate()
	editor.remember = false
	editor.done.connect(_on_done)
	editor.cancelled.connect(func() -> void: get_tree().quit(0))
	add_child(editor)
	if auto:
		_run.call_deferred()
	else:
		_open_editor()

func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_DISABLED
	sub.positional_shadow_atlas_size = 2048
	add_child(sub)
	get_viewport().disable_3d = true
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.6)
	env.ambient_light_energy = 0.12
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.06, 0.06)
	env.fog_density = 0.035
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 0.9
	we.environment = env
	sub.add_child(we)
	world = Node3D.new()
	sub.add_child(world)
	cam = Camera3D.new()
	cam.fov = VFOV
	cam.near = 0.05
	cam.far = 60.0
	sub.add_child(cam)
	cam.current = true
	screen = TextureRect.new()
	screen.texture = sub.get_texture()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var tape := ShaderMaterial.new()
	tape.shader = load("res://client/tape.gdshader")
	screen.material = tape
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)

# A real Clinic floor from the rules: the first seed with a clean straight corridor 9+ cells long.
func _build_floor() -> void:
	var bridge := RulesBridge.new()
	add_child(bridge)
	if not bridge.open():
		push_error("face demo: rules not connected: " + bridge.error)
		return
	for k in 40:
		var seed_text := "crew-%d" % k
		bridge.start(seed_text, 1, false)
		var lv := Level.new()
		lv.shadows = true
		lv.props_on = false
		lv.build(bridge.plan, seed_text)
		var h := _find_hall(lv)
		if not h.is_empty():
			level = lv
			hall = h
			world.add_child(level)
			level.set_light_level(1.0)
			level.set_emergency(0.0)
			print("face demo: floor '%s', corridor %d cells" % [seed_text, h["cells"]])
			break
		lv.free()
	bridge.close()

func _find_hall(lv: Level) -> Dictionary:
	var best: Dictionary = {}
	var best_c := 0.6
	for sl: Dictionary in lv.plan["sightlines"]:
		if int(sl["level"]) != 0 or int(sl["length"]) < 9:
			continue
		var a := Vector2i(int(sl["x1"]), int(sl["y1"]))
		var b := Vector2i(int(sl["x2"]), int(sl["y2"]))
		var dv := b - a
		if dv.x != 0 and dv.y != 0:
			continue
		var n := maxi(absi(dv.x), absi(dv.y))
		var step := Vector2i(signi(dv.x), signi(dv.y))
		var cmax := 0.0
		var corridor := true
		for i in n + 1:
			var c := a + step * i
			cmax = maxf(cmax, lv.corruption(0, c.x, c.y))
			if lv.kind(0, c.x, c.y) != "corridor":
				corridor = false
		if corridor and cmax < best_c:
			best_c = cmax
			best = {"start": lv.cell_center(0, a.x, a.y), "along": Vector3(step.x, 0, step.y), "cells": n + 1}
	return best

func _process(delta: float) -> void:
	if level:
		level.update_lights(delta, cam.global_position)

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or editor.visible:
		return
	if k.keycode == KEY_E:
		_open_editor()
	elif k.keycode == KEY_ESCAPE:
		get_tree().quit(0)

func _open_editor() -> void:
	editor.visible = true
	editor.begin(editor.get_code())

func _on_done(code: String, tex: ImageTexture) -> void:
	editor.visible = false
	print("face demo: face is %d characters: %s" % [code.length(), code])
	_wear(tex)
	_place(-1)

func _wear(tex: Texture2D) -> void:
	for c: CrewView in crew:
		c.set_face(tex)

## Puts the crew down the corridor facing the camera: all four (which = -1) or one, centred.
func _place(which: int) -> void:
	if hall.is_empty():
		return
	var s: Vector3 = hall["start"]
	var dir: Vector3 = hall["along"]
	var across := Vector3(-dir.z, 0, dir.x)
	for i in crew.size():
		var off := SIDE[i] if which < 0 else 0.0
		crew[i].set_body(s + dir * DISTANCES[i] + across * off, atan2(dir.x, dir.z))
		crew[i].visible = which < 0 or which == i
	cam.position = s + Vector3(0, EYE, 0)
	cam.look_at(s + dir * 10.0 + Vector3(0, EYE, 0), Vector3.UP)

# --- the pictures (auto=1) -----------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _shot(shot_name: String) -> void:
	await _frames(4)
	var img := get_viewport().get_texture().get_image()
	var path := shots_dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	log_lines.append("%s %s" % [shot_name, "ok" if err == OK else "FAILED"])

func _run() -> void:
	if level == null or hall.is_empty():
		push_error("face demo: no floor with a long corridor")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(shots_dir)
	editor.visible = true
	editor.begin("")
	await _frames(10)
	# 1. A face drawn with the mouse, as a player would: strokes, dabs, the eraser.
	await _draw_by_hand()
	var drawn := editor.get_code()
	await _shot("editor_drawn")
	# 2. Each starting face, in the editor.
	var faces := {"drawn": drawn}
	for s: String in Paint.STARTERS:
		editor.press("starter:" + s)
		faces[s] = editor.get_code()
		await _shot("editor_starter_" + s)
	# 3. Each face worn by the crew, all four together and one at a time at each distance.
	editor.load_code(drawn)
	editor.press("done")
	for f: String in faces:
		_wear(Codec.decode(faces[f]))
		_place(-1)
		await _frames(20)
		await _shot("crew_%s_all" % f)
		for i in DISTANCES.size():
			_place(i)
			await _shot("crew_%s_%dm" % [f, int(DISTANCES[i])])
	print("face demo: %d pictures in %s" % [log_lines.size(), shots_dir])
	for f: String in faces:
		print("  %s: %d characters" % [f, (faces[f] as String).length()])
	for l in log_lines:
		print("  ", l)
	get_tree().quit(0)

func _click(at: Vector2, down: bool, button := MOUSE_BUTTON_LEFT) -> void:
	var e := InputEventMouseButton.new()
	e.position = at
	e.global_position = at
	e.button_index = button
	e.pressed = down
	editor._gui_input(e)

func _drag(cells: Array, button := MOUSE_BUTTON_LEFT) -> void:
	var mask := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	_click(editor.cell_to_screen(cells[0]), true, button)
	for i in range(1, cells.size()):
		var e := InputEventMouseMotion.new()
		e.position = editor.cell_to_screen(cells[i])
		e.button_mask = mask
		editor._gui_input(e)
	_click(editor.cell_to_screen(cells[-1]), false, button)
	await _frames(1)

## A cheeky face with things that show if the screen is mirrored or upside down: "OK" across the
## forehead, an open eye on the viewer's left, a wink on the right, the tongue out to the right.
func _draw_by_hand() -> void:
	editor.press("clear")
	editor.press("brush:0")             # small brush on cell edges: strokes two cells wide
	editor.press("colour:4")            # green "OK" on the forehead
	await _drag([Vector2(9, 2), Vector2(9, 9), Vector2(14, 9), Vector2(14, 2), Vector2(9, 2)])
	await _drag([Vector2(18, 2), Vector2(18, 9)])
	await _drag([Vector2(23, 2), Vector2(19, 5.5), Vector2(23, 9)])
	editor.press("colour:1")            # ink open eye with a lit glint (the eraser), viewer's left
	editor.press("brush:2")
	await _drag([Vector2(9.5, 15.5), Vector2(9.6, 15.5)])
	editor.press("brush:0")
	await _drag([Vector2(9.5, 15.5), Vector2(9.6, 15.5)], MOUSE_BUTTON_RIGHT)
	editor.press("colour:3")            # blue wink, viewer's right
	editor.press("brush:1")
	await _drag([Vector2(19.0, 16.0), Vector2(22.0, 14.0), Vector2(25.0, 16.0)])
	editor.press("colour:1")            # ink grin
	await _drag([Vector2(6.5, 22.0), Vector2(10.0, 25.5), Vector2(16.0, 26.5), Vector2(22.0, 25.5), Vector2(25.5, 22.0)])
	editor.press("colour:2")            # red tongue out to the right
	editor.press("brush:2")
	await _drag([Vector2(20.0, 27.5), Vector2(21.0, 29.0)])
	# The mouse resting over the canvas, so the brush ring shows in the picture.
	var e := InputEventMouseMotion.new()
	e.position = editor.cell_to_screen(Vector2(27.5, 9.5))
	editor._gui_input(e)
