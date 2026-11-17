# The Annex's two small tools, headless:
#   "$GODOT" --headless --path godot --script res://tools/annex_tool.gd -- maps     text maps of five floors
#                                                                                   to godot/export/annex/
#   "$GODOT" --headless --path godot --script res://tools/annex_tool.gd -- hashes   rewrite the stored plan
#                                                                                   hashes, tests/annex_hashes.json
# Run them under a timeout. Rewrite the hashes only when the Annex is meant to change; the file is
# what prop_annex.gd compares against, here and on the Linux server build.
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
	elif mode == "hashes":
		_hashes()
	else:
		print("usage: -- maps | -- hashes")
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

func _hashes() -> void:
	var out := {}
	var keys: Array[String] = []
	for depth: int in [1, 2, 3, 4]:
		for i in 200:
			var seed := "seed-%d" % i
			var key := "%s/%d" % [seed, depth]
			keys.append(key)
			out[key] = Floor.hash_plan(Annex.generate_annex(seed, depth))
	# One floor per line, in generation order, so a change shows as a readable diff.
	var lines := PackedStringArray()
	for k in keys:
		lines.append("  %s: %s" % [JSON.stringify(k), JSON.stringify(out[k])])
	var f := FileAccess.open("res://tests/annex_hashes.json", FileAccess.WRITE)
	f.store_string("{\n" + ",\n".join(lines) + "\n}\n")
	f.close()
	print("wrote tests/annex_hashes.json: %d floors" % keys.size())
