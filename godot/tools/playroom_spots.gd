extends SceneTree
## Prints where the Playroom's look pieces and murals stand for one seed and depth, for picture scripts:
##   godot --headless --path godot --script res://tools/playroom_spots.gd -- seed=alpha depth=4
## One JSON line: {pieces: [{kind, level, cell, pos, facing}], murals: [...], landing}.

func _init() -> void:
	var seed := "alpha"
	var depth := 4
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seed="):
			seed = a.substr(5)
		elif a.begins_with("depth="):
			depth = int(a.substr(6))
	var pr: GDScript = load("res://sim/playroom.gd")
	var plan: RefCounted = pr.call("generate_playroom", seed, depth)
	var level: Level = Level.new()
	level.build(load("res://client/plan_dump.gd").dump(plan, load("res://sim/run.gd").car_geometry(plan)), seed, plan)
	var v: Node = level.get_meta("playroom")
	var out := {"pieces": [], "murals": [], "landing": [level.landing.x, level.landing.y, level.landing.z]}
	for p: Dictionary in v.get("pieces"):
		var pos: Vector3 = p.pos
		var f: Vector3 = p.facing
		out.pieces.append({"kind": p.kind, "level": p.level, "cell": [p.cell.x, p.cell.y], "pos": [pos.x, pos.y, pos.z], "facing": [f.x, f.z]})
	for m: Dictionary in v.get("murals"):
		var pos: Vector3 = m.pos
		var f: Vector3 = m.facing
		out.murals.append({"room": m.room, "level": m.level, "pos": [pos.x, pos.y, pos.z], "facing": [f.x, f.z]})
	print(JSON.stringify(out))
	level.free()
	quit(0)
