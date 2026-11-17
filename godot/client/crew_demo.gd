# A look at the crewmates (crew_view.gd) in the game's own picture: a real Clinic floor built by
# Level from the rules' plan, the client's lights and materials, the 480x270 view through the tape
# shader, in a window. It stands four crewmates (skins, headwear, numbers, one wearing a test drawing),
# steps through every clip, and saves pictures of the window as drawn, then quits.
# Never captures the mouse. Run from the repository root (see docs/ART-NOTES.md, "Crewmate"):
#   Godot --path godot --resolution 960x540 --position 40,40 res://client/crew_demo.tscn -- [shots=DIR] [hold=1]
# shots defaults to assets_src/renders/crewmate/ beside the godot folder; hold=1 keeps the window open
# (cycling through the clips) instead of taking pictures and quitting.
extends Node

const Session = preload("res://net/session.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const VFOV := 70.0
const EYE := 1.65
const CLIP_ORDER: Array[String] = ["idle", "walk", "run", "sneak", "crouch_idle", "look_behind", "button",
	"taken", "crawl", "pray", "dance_spin", "dance_snake", "wave"]
const MOMENTS: Array[float] = [0.15, 0.5, 0.85]

var sub: SubViewport
var cam: Camera3D
var world: Node3D
var level: Level
var tape_mat: ShaderMaterial
var crew: Array[CrewView] = []
var shots_dir := ""
var hold := false
var room_spot: Dictionary = {}     # centre, across (unit), along (unit, away from the camera)
var hall_spot: Dictionary = {}     # start, along (unit), cells
var log_lines: Array[String] = []

func _ready() -> void:
	shots_dir = ProjectSettings.globalize_path("res://").path_join("../assets_src/renders/crewmate").simplify_path()
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("shots="):
			shots_dir = a.substr(6)
		elif a == "hold=1":
			hold = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_view()
	_build_floor()
	for i in 4:
		var c := CrewView.new()
		c.name = "Crew%d" % i
		world.add_child(c)
		crew.append(c)
	crew[0].set_skin(0)
	crew[0].set_headwear(&"knit")
	crew[0].set_number(7)
	crew[1].set_skin(1)
	crew[1].set_headwear(&"hair")
	crew[1].set_number(23)
	crew[1].set_face(test_face())
	crew[2].set_skin(2)
	crew[2].set_headwear(&"none")
	crew[2].set_number(41)
	crew[3].set_skin(3)
	crew[3].set_headwear(&"hair")
	crew[3].set_number(96)
	_run.call_deferred()

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
	var screen := TextureRect.new()
	screen.texture = sub.get_texture()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tape_mat = ShaderMaterial.new()
	tape_mat.shader = load("res://client/tape.gdshader")
	screen.material = tape_mat
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)

# A real floor: tries seeds until it has a room at least 3 x 4 cells and a straight corridor at least
# 9 cells long, both on the ground level and near the lift (clean light).
func _build_floor() -> void:
	for k in 40:
		var seed_text := "crew-%d" % k
		var fp := Session.plan_for(seed_text, 1)
		var lv := Level.new()
		lv.shadows = true
		lv.props_on = false
		lv.build(PlanDump.dump(fp, Session.car_for(fp)), seed_text)
		var r := _find_room(lv)
		var h := _find_hall(lv)
		if not r.is_empty() and not h.is_empty():
			level = lv
			room_spot = r
			hall_spot = h
			world.add_child(level)
			level.set_light_level(1.0)
			level.set_emergency(0.0)
			print("crew demo: floor '%s', room at %s, corridor %d cells from %s" % [seed_text, r["centre"], h["cells"], h["start"]])
			break
		lv.free()

func _find_room(lv: Level) -> Dictionary:
	var best: Dictionary = {}
	var best_c := 0.4
	for y in lv.H:
		for x in lv.W:
			for d: Vector2i in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]:
				var across := Vector2i(d.y, d.x)
				var ok := true
				var cmax := 0.0
				for j in 4:
					for i in range(-1, 2):
						var c := Vector2i(x, y) + d * j + across * i
						if lv.kind(0, c.x, c.y) != "room" and lv.kind(0, c.x, c.y) != "landing":
							ok = false
						cmax = maxf(cmax, lv.corruption(0, c.x, c.y))
				if ok and cmax < best_c:
					best_c = cmax
					var c0 := lv.cell_center(0, x, y)
					best = {"cam": c0, "centre": c0 + Vector3(d.x, 0, d.y) * Level.S * 2.0,
						"along": Vector3(d.x, 0, d.y), "across": Vector3(across.x, 0, across.y)}
	return best

func _find_hall(lv: Level) -> Dictionary:
	var best: Dictionary = {}
	var best_c := 0.6
	for sl: Dictionary in lv.plan["sightlines"]:
		if int(sl["level"]) != 0 or int(sl["length"]) < 9:
			continue
		var a := Vector2i(int(sl["x1"]), int(sl["y1"]))
		var b := Vector2i(int(sl["x2"]), int(sl["y2"]))
		var dv := b - a
		var n := maxi(absi(dv.x), absi(dv.y))
		var step := Vector2i(signi(dv.x), signi(dv.y))
		if dv.x != 0 and dv.y != 0:
			continue
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

# --- the pictures -------------------------------------------------------------------------------

func _yaw_facing(dir: Vector3) -> float:
	# CrewView yaw uses the camera convention: forward = (-sin yaw, 0, -cos yaw)
	return atan2(-dir.x, -dir.z)

func _look(from: Vector3, to: Vector3) -> void:
	cam.position = from
	cam.look_at(to, Vector3.UP)

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _shot(shot_name: String) -> void:
	await _frames(3)
	if hold:
		await get_tree().create_timer(0.6).timeout
		return
	var img := get_viewport().get_texture().get_image()
	var path := shots_dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	log_lines.append("%s %s" % [shot_name, "ok" if err == OK else "FAILED"])

func _line_up(spacing: float, facing: Vector3, depth := 0.0) -> void:
	var c: Vector3 = room_spot["centre"]
	var across: Vector3 = room_spot["across"]
	var along: Vector3 = room_spot["along"]
	for i in crew.size():
		var p := c + across * (float(i) - 1.5) * spacing + along * depth
		crew[i].set_body(p, _yaw_facing(facing))
		crew[i].visible = true

func _run() -> void:
	if level == null:
		push_error("crew demo: no floor with a room and a long corridor")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(shots_dir)
	await _frames(10)
	var c: Vector3 = room_spot["centre"]
	var along: Vector3 = room_spot["along"]
	var across: Vector3 = room_spot["across"]
	var to_cam := -along
	# 1. the four variants side by side
	_line_up(0.8, to_cam)
	for cv: CrewView in crew:
		cv.debug_pose("idle", 1.0)
	_look(c - along * 3.4 + Vector3(0, EYE, 0), c + Vector3(0, 1.0, 0))
	await _shot("variants")
	# 2. the face screen close up (crewmate 1 wears the test drawing; 0 the default face)
	var head := crew[1].position + Vector3(0, 1.63, 0)
	_look(head - along * 0.75 + Vector3(0, 0.02, 0), head)
	await _shot("face_closeup_test")
	head = crew[0].position + Vector3(0, 1.63, 0)
	_look(head - along * 0.75 + Vector3(0, 0.02, 0), head)
	await _shot("face_closeup_default")
	_look(c - along * 1.6 + across * 0.3 + Vector3(0, EYE, 0), crew[1].position + Vector3(0, 1.3, 0))
	await _shot("face_test_2m")
	# 3. every clip at three moments: three figures, front three-quarter and side
	crew[3].visible = false
	for clip_name: String in CLIP_ORDER:
		for view: String in ["front", "side"]:
			var facing := to_cam if view == "front" else -across
			for i in 3:
				var p := c + across * (float(i) - 1.0) * 1.15
				crew[i].set_body(p, _yaw_facing(facing))
				var dur := crew[i].ap.get_animation(clip_name).length
				crew[i].debug_pose(clip_name, MOMENTS[i] * dur)
			var eye := Vector3(0, EYE, 0)
			if view == "front":
				_look(c - along * 3.6 + across * 1.2 + eye, c + Vector3(0, 0.8, 0))
			else:
				_look(c - along * 3.8 + eye, c + Vector3(0, 0.8, 0))
			await _shot("clip_%s_%s" % [clip_name, view])
	# 4. the instrument raised over idle and walk, and the wave
	crew[0].debug_pose("idle", 1.0)
	crew[1].debug_pose("walk", 0.3)
	crew[2].debug_pose("sneak", 0.5)
	for i in 3:
		crew[i].set_body(c + across * (float(i) - 1.0) * 1.15, _yaw_facing(to_cam + across * 0.5))
		crew[i].set_raised(true)
	await _frames(20)
	_look(c - along * 2.6 + across * 0.8 + Vector3(0, EYE, 0), c + Vector3(0, 1.0, 0))
	await _shot("raised")
	for i in 3:
		crew[i].set_raised(false)
	# 5. a walking figure 3, 8 and 15 m down the corridor, seen from eye height
	for cv: CrewView in crew:
		cv.visible = false
	var s: Vector3 = hall_spot["start"]
	var dir: Vector3 = hall_spot["along"]
	var w := crew[1]
	w.visible = true
	for d: float in [3.0, 8.0, 15.0]:
		w.set_body(s + dir * d, _yaw_facing(-dir))
		w.debug_pose("walk", 0.25)
		_look(s + Vector3(0, EYE, 0), s + dir * 10.0 + Vector3(0, EYE - 0.3, 0))
		await _shot("corridor_walk_%02dm" % int(d))
	# 6. the API driven as the network would: walk off, emote, go down (a few frames each)
	w.debug_pose("", 0.0)
	w.set_body(s + dir * 4.0, _yaw_facing(-dir))
	w.set_gait(&"walk", 3.0)
	await _frames(30)
	w.set_gait(&"still", 0.0)
	w.play_emote(&"wave")
	await get_tree().create_timer(1.2).timeout
	await _shot("api_wave")
	w.set_downed(true)
	await get_tree().create_timer(4.0).timeout
	w.set_gait(&"creep", 0.5)
	await get_tree().create_timer(0.6).timeout
	await _shot("api_downed_crawl")
	print("crew demo: %d pictures in %s" % [log_lines.size(), shots_dir])
	for l in log_lines:
		print("  ", l)
	if hold:
		_run.call_deferred()
		return
	get_tree().quit(0)

## A test drawing that shows at a glance if the screen is mirrored or upside down: "AB" across the
## forehead, an open eye on the wearer's right (the viewer's left), a wink on the other, a lopsided grin.
static func test_face() -> Texture2D:
	var img := Image.create(128, 128, false, Image.FORMAT_RGB8)
	img.fill(Color(0.93, 0.92, 0.86))
	var ink := Color(0.05, 0.05, 0.08)
	PixelFont.blit(img, "AB", Vector2i(31, 8), Color(0.75, 0.1, 0.1), Vector2i(6, 4))
	for y in range(-12, 13):
		for x in range(-12, 13):
			var r := x * x + y * y
			if r <= 144 and r >= 70:
				img.set_pixel(38 + x, 62 + y, ink)
			if r <= 20:
				img.set_pixel(38 + x, 62 + y, ink)
	img.fill_rect(Rect2i(78, 60, 24, 5), ink)
	for x in range(24, 106):
		var y := 108 - int(0.012 * pow(float(x - 65), 2.0)) - int((x - 24) * 0.06)
		img.fill_rect(Rect2i(x, y, 2, 4), ink)
	return ImageTexture.create_from_image(img)
