# Pieces per floor by kind (sim/furniture.gd), over seed-0..N at depths 1 to 4:
#   "$GODOT" --headless --path godot --script res://tools/furniture_count.gd [-- N]
extends SceneTree

const Furniture = preload("res://sim/furniture.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seeds := int(args[0]) if args.size() > 0 else 10
	for place: String in ["clinic", "annex"]:
		var kinds := {}
		var n := 0
		var total := 0
		var t0 := Time.get_ticks_msec()
		for i in seeds:
			for d: int in [1, 2, 3, 4]:
				var p: Floor.FloorPlan = Clinic.generate_clinic("seed-%d" % i, d) if place == "clinic" else Annex.generate_annex("seed-%d" % i, d)
				var list := Furniture.pieces_for(p, p.seed, d)
				n += 1
				total += list.size()
				for pc in list:
					kinds[pc.kind] = int(kinds.get(pc.kind, 0)) + 1
		var parts: Array[String] = []
		var ks: Array = kinds.keys()
		ks.sort()
		for k: StringName in ks:
			parts.append("%s %.1f" % [k, int(kinds[k]) / float(n)])
		print("%s: %d floors, %.1f pieces a floor (%d ms): %s" % [place, n, total / float(n), Time.get_ticks_msec() - t0, ", ".join(parts)])
	quit(0)
