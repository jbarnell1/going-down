# Pictures of furnished rooms (sim/furniture.gd, as client/level.gd and client/annex_view.gd draw it), in a
# small window: the two rooms with the most plain pieces on a Clinic and on an Annex, each from its doorway
# at eye height. Never captures the mouse. Writes PNGs to the directory given (default user://furniture_shots).
#   "$GODOT" --path godot --script res://tools/furniture_shots.gd -- shots=DIR
extends SceneTree

const Furniture = preload("res://sim/furniture.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Run = preload("res://sim/run.gd")
const Playroom = preload("res://sim/playroom.gd")
const PlanDump = preload("res://client/plan_dump.gd")

var shots := "user://furniture_shots"

func _initialize() -> void:
	for raw in OS.get_cmdline_user_args():
		if raw.begins_with("shots="):
			shots = raw.substr(6)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots) if shots.begins_with("user://") else shots)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	root.size = Vector2i(1280, 720)
	_main.call_deferred()

func _main() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.6)
	env.ambient_light_energy = 0.25
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	root.add_child(we)
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.05
	cam.far = 60.0
	root.add_child(cam)
	cam.current = true
	var n := 0
	for place: StringName in [&"clinic", &"annex"]:
		var fp: Floor.FloorPlan = Clinic.generate_clinic("seed-1", 2) if place == &"clinic" else Annex.generate_annex("seed-1", 3)
		var level := Level.new()
		root.add_child(level)
		level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed)
		level.set_light_level(1.0)
		level.set_emergency(0.0)
		var pieces := Furniture.pieces_for(fp)
		var counts := {}
		for pc in pieces:
			if pc.room >= 0:
				counts[pc.room] = int(counts.get(pc.room, 0)) + 1
		var rooms: Array = counts.keys()
		rooms.sort_custom(func(a: int, b: int) -> bool: return int(counts[a]) > int(counts[b]) or (int(counts[a]) == int(counts[b]) and a < b))
		var doors := Playroom._door_cells(fp)
		for rid: int in rooms.slice(0, 2):
			var room: Floor.Room = null
			for r in fp.rooms:
				if r.id == rid:
					room = r
			var from := Vector2((room.x + 0.5) * 2.0, (room.y + 0.5) * 2.0)
			for y in range(room.y, room.y + room.h):
				for x in range(room.x, room.x + room.w):
					if doors.has(Floor.pos_index(fp, Floor.Pos.make(room.level, x, y))):
						from = Vector2((x + 0.5) * 2.0, (y + 0.5) * 2.0)
			var mid := Vector2((room.x + room.w * 0.5) * 2.0, (room.y + room.h * 0.5) * 2.0)
			var y0 := room.level * 3.2
			cam.position = Vector3(from.x, y0 + 1.65, from.y) + Vector3(from.x - mid.x, 0, from.y - mid.y).normalized() * -0.2
			cam.look_at(Vector3(mid.x, y0 + 0.4, mid.y), Vector3.UP)
			for _i in 12:
				level.update_lights(1.0 / 30.0, cam.global_position)
				env.ambient_light_color = level.ambient_color(0.0)
				await process_frame
			var img := root.get_texture().get_image()
			n += 1
			var path := shots.path_join("furniture_%d_%s_%s.png" % [n, place, room.kind])
			img.save_png(path)
			print("wrote %s (%s room %d, %d pieces)" % [ProjectSettings.globalize_path(path) if path.begins_with("user://") else path, room.kind, rid, int(counts[rid])])
		level.free()
	quit(0)
