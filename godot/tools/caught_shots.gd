# CS1: pictures of each resident's caught scene (client/caught_scene.gd) at its strongest moment, through the game's own
# tape picture (client/tape.gdshader, as client/main.gd make_screen draws it) and the scene's overlay. Needs a window
# (the renderer): run it beside the mouse guard. It never captures the mouse.
#   "$GODOT" --path godot --resolution 960x540 --position 40,40 --script res://tools/caught_shots.gd -- out=<dir> [soft=1]
#   [sheet=1]: also every 150 ms of each scene without the noise or the overlay (to judge the figure's framing).
extends SceneTree

const CaughtScene = preload("res://client/caught_scene.gd")
const Main = preload("res://client/main.gd")

## The moment (ms into the scene) each picture is taken.
const AT := {"orderly": 520, "temp": 470, "minder": 450, "keeper": 360, "crew": 850}

var out_dir := ""
var soft := false
var sheet := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
		elif kv.size() == 2 and kv[0] == "soft":
			soft = kv[1] == "1"
		elif kv.size() == 2 and kv[0] == "sheet":
			sheet = kv[1] == "1"
	if out_dir == "":
		push_error("out=<dir>")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	var sub := SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.6)
	env.ambient_light_energy = 0.12
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	sub.add_child(we)
	# A floor and a far wall, dim, so the figure is seen in a room.
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mi.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.25, 0.27, 0.26)
	floor_mi.material_override = fm
	sub.add_child(floor_mi)
	var wall := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(20, 4, 0.2)
	wall.mesh = bm
	wall.material_override = fm
	wall.position = Vector3(0, 2, -6)
	sub.add_child(wall)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(1.5, 2.8, -3.0)
	lamp.omni_range = 8.0
	lamp.light_energy = 0.6
	sub.add_child(lamp)
	var cam := Camera3D.new()
	cam.fov = Main.VFOV
	cam.near = 0.05
	cam.far = 60.0
	cam.position = Vector3(0, 1.45, 0)
	sub.add_child(cam)
	cam.current = true
	var scene := CaughtScene.new()
	sub.add_child(scene)
	var screen := Main.make_screen(sub)
	var mat := screen.material as ShaderMaterial
	mat.set_shader_parameter("src_size", Vector2(480, 270))
	root.add_child(screen)
	root.add_child(scene.overlay)
	scene.soft = soft
	for k: String in CaughtScene.KINDS:
		scene.prepare(k, {"seed": "cs1-shots"})
		var t0 := 100000
		scene.start(k, t0, true, {"seat": 2})
		var r: Dictionary = scene.step(t0 + int(AT[k]), cam)
		mat.set_shader_parameter("snow", float(r.get("snow", 0.0)))
		mat.set_shader_parameter("glitch", float(r.get("glitch", 0.0)))
		var sh: Vector2 = r.get("shove", Vector2.ZERO)
		cam.h_offset = sh.x
		cam.v_offset = sh.y
		for i in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		var path := out_dir.path_join("cs1-%s%s.png" % [k, "-soft" if soft else ""])
		img.save_png(path)
		print("shot %s at %d ms: %s (%s)" % [k, int(AT[k]), path, JSON.stringify(scene.describe(t0 + int(AT[k])))])
		scene.stop()
		if sheet:
			for ms in range(0, CaughtScene.LENGTH_MS, 150):
				scene.start(k, t0, true, {"seat": 2})
				scene.step(t0 + ms, cam)
				scene.overlay.clear()
				mat.set_shader_parameter("snow", 0.0)
				mat.set_shader_parameter("glitch", 0.0)
				cam.h_offset = 0.0
				cam.v_offset = 0.0
				for i in 3:
					await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(out_dir.path_join("sheet-%s-%04d.png" % [k, ms]))
				scene.stop()
	quit(0)
