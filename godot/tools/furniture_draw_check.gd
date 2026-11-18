# Builds a Clinic and an Annex as the client draws them and prints each piece whose mesh is off its footprint
# (sim/furniture.gd; tests/prop_furniture.gd checks the same):
#   "$GODOT" --headless --path godot --script res://tools/furniture_draw_check.gd
extends SceneTree

const Furniture = preload("res://sim/furniture.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Run = preload("res://sim/run.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const LevelScript = preload("res://client/level.gd")

func _init() -> void:
	var plans: Array[Floor.FloorPlan] = [Clinic.generate_clinic("seed-0", 1), Annex.generate_annex("seed-0", 3)]
	for p in plans:
		var list := Furniture.pieces_for(p, p.seed, p.depth)
		var lv: Node3D = LevelScript.new()
		lv.call("build", PlanDump.dump(p, Run.car_geometry(p)), "draw-check")
		var drawn: Array = lv.get("furniture_drawn")
		var worst := {}
		for d: Dictionary in drawn:
			var pc: Furniture.Piece = list[int(d["piece"])]
			var r: Rect2 = d["rect"]
			var f := Rect2(pc.foot.position.x / 100.0, pc.foot.position.y / 100.0, pc.foot.size.x / 100.0, pc.foot.size.y / 100.0)
			var off := maxf(maxf(absf(r.position.x - f.position.x), absf(r.position.y - f.position.y)), maxf(absf(r.end.x - f.end.x), absf(r.end.y - f.end.y)))
			var k := String(pc.kind)
			if off > float(worst.get(k, [-1.0])[0]):
				worst[k] = [off, "mesh %s foot %s facing %s" % [r, f, pc.facing]]
		print("%s: %d pieces, %d drawn" % [p.place, list.size(), drawn.size()])
		for k: String in worst:
			print("  %s %.3f %s" % [k, float(worst[k][0]), worst[k][1]])
		lv.free()
	quit(0)
