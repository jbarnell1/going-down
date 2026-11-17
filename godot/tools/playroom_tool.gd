# The Playroom's small tools, headless:
#   "$GODOT" --headless --path godot --script res://tools/playroom_tool.gd -- maps     text maps of five
#                                                                                      floors to godot/export/playroom/
#   "$GODOT" --headless --path godot --script res://tools/playroom_tool.gd -- hashes   rewrite the stored
#                                                                                      hashes, tests/playroom_hashes.json
# Run them under a timeout. Rewrite the hashes only when the Playroom is meant to change; the file is
# what prop_playroom.gd compares against, here and on the Linux server build.
extends SceneTree

@warning_ignore_start("integer_division")

const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")

## The five floors the maps show: one per depth 1 to 3 (four blocks a side), and two at depth 4, the
## Playroom's own floor (five a side).
const MAP_FLOORS: Array = [["seed-0", 1], ["seed-1", 2], ["seed-2", 3], ["seed-3", 4], ["seed-4", 4]]

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

## One floor as text: a header, the legend, each level's map and zone grid, the zones' signs, the seats.
static func describe(floor_seed: String, depth: int) -> String:
	var t0 := Time.get_ticks_usec()
	var p := Playroom.generate_playroom(floor_seed, depth)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var hides := Playroom.hides(p, p.seed)
	var squeak := Playroom.squeakers(p, p.seed)
	var zones := Playroom.zones(p)
	var cap := [0, 0]
	for h in hides:
		cap[h.level] = (cap[h.level] as int) + h.capacity
	var text := "Playroom %s depth %d  (%dx%d, %d rooms, %d doors, %d stairs, %d hides holding %d + %d, %d squeakers, %d zones, hash %s, %.1f ms)\n%s\n" % [
		floor_seed, depth, p.width, p.height, p.rooms.size(), p.doors.size(), p.stairs.size(), hides.size(), cap[0], cap[1],
		squeak.size(), zones.size(), Floor.hash_plan(p), ms, Playroom.ASCII_LEGEND]
	for level in 2:
		text += "\nLevel %d\n%s\n\nZones on level %d (id, kind, the sign's number; north up)\n%s\n" % [
			level, Playroom.render_ascii(p, level), level, Playroom.render_zones(p, level)]
	var room := Playroom.party_room(p)
	text += "\nMinder start: level %d cell %d,%d in party room %d, facing %s\nSeats (cm, facing):" % [
		p.entity_start.level, p.entity_start.x, p.entity_start.y, room.id, Playroom.entity_facing(p)]
	for s in Playroom.seats(p):
		text += " %d,%d %s;" % [s.at.x, s.at.y, s.facing]
	text += "\n"
	return text

func _maps() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://export/playroom"))
	for pair: Array in MAP_FLOORS:
		var floor_seed: String = pair[0]
		var depth: int = pair[1]
		var path := "res://export/playroom/%s-d%d.txt" % [floor_seed, depth]
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(describe(floor_seed, depth))
		f.close()
		print("wrote %s" % path)

func _hashes() -> void:
	var keys: Array[String] = []
	var lines := PackedStringArray()
	for depth: int in [1, 2, 3, 4]:
		for i in 200:
			var floor_seed := "seed-%d" % i
			var key := "%s/%d" % [floor_seed, depth]
			keys.append(key)
			lines.append("  %s: %s" % [JSON.stringify(key), JSON.stringify(Playroom.floor_hashes(Playroom.generate_playroom(floor_seed, depth)))])
	# One floor per line, in generation order: [plan, hides, squeakers, zones, seats].
	var f := FileAccess.open("res://tests/playroom_hashes.json", FileAccess.WRITE)
	f.store_string("{\n" + ",\n".join(lines) + "\n}\n")
	f.close()
	print("wrote tests/playroom_hashes.json: %d floors" % keys.size())
