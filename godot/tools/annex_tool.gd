# The Annex's text maps, headless:
#   "$GODOT" --headless --path godot --script res://tools/annex_tool.gd -- maps     text maps of five floors
#                                                                                   to godot/export/annex/
# Run it under a timeout. The plan hashes prop_annex.gd compares against are a golden now
# (tests/golden/annex.json): `npm run godot:golden -- prop_annex` records them.
extends SceneTree

const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")

## The five floors the maps show: one per depth, and a fifth with five blocks a side.
const MAP_FLOORS: Array = [["seed-0", 1], ["seed-1", 2], ["seed-2", 3], ["seed-3", 4], ["seed-4", 5]]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := "maps" if args.is_empty() else args[0]
	if mode == "maps":
		_maps()
	else:
		print("usage: -- maps")
		quit(2)
		return
	quit(0)

func _maps() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://export/annex"))
	for pair: Array in MAP_FLOORS:
		var seed: String = pair[0]
		var depth: int = pair[1]
		var t0 := Time.get_ticks_usec()
		var p := Annex.generate_annex(seed, depth)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var text := "Annex %s depth %d  (%dx%d, %d rooms, %d doors, %d stairs, hash %s, %.1f ms)\n%s\n\nLevel 0\n%s\n\nLevel 1\n%s\n" % [
			seed, depth, p.width, p.height, p.rooms.size(), p.doors.size(), p.stairs.size(), Floor.hash_plan(p), ms,
			Annex.ASCII_LEGEND, Annex.render_ascii(p, 0), Annex.render_ascii(p, 1)]
		var path := "res://export/annex/%s-d%d.txt" % [seed, depth]
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(text)
		f.close()
		print("wrote %s" % path)
