# Writes tests/reference/findables_hashes.json: every fill's hash over the 1600 floors tests/prop_findables.gd checks
# (seed-0..199 at depths 1 to 4, Clinic and Annex), as that test computes them. Run once when the fill's rules change
# on purpose (it is also what `npm run godot:golden -- prop_findables` writes):
#   "$GODOT" --headless --path godot --script res://tools/findables_hashes.gd
extends SceneTree

const PropFindables = preload("res://tests/prop_findables.gd")
const Playroom = preload("res://sim/playroom.gd")

func _init() -> void:
	var got := {}
	for place: StringName in [&"clinic", &"annex"]:
		for f in PropFindables.floors(false, place):
			got[PropFindables._key(f)] = Playroom.hash_plain(PropFindables._fill_plain(f))
	var keys: Array = got.keys()
	keys.sort()
	var lines := PackedStringArray()
	for k: String in keys:
		lines.append("  %s: %s" % [JSON.stringify(k), JSON.stringify(got[k])])
	var path := PropFindables.HASHES_PATH
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string("{\n" + ",\n".join(lines) + "\n}\n")
	fa.close()
	print("wrote %d hashes to %s" % [keys.size(), path])
	quit(0)
