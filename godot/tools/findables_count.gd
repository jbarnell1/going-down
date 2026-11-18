# What a typical floor holds (sim/findables.gd), over seed-0..N at depths 1 to 4, for a crew of four:
# searchable pieces, credits, notes, cartons and pages a floor, the share of the floor's quota hidden, and the
# fewest and most pieces seen.
#   "$GODOT" --headless --path godot --script res://tools/findables_count.gd [-- N [crew]]
extends SceneTree

const Findables = preload("res://sim/findables.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Run = preload("res://sim/run.gd")

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seeds := int(args[0]) if args.size() > 0 else 10
	var crew := int(args[1]) if args.size() > 1 else 4
	for place: String in ["clinic", "annex"]:
		var n := 0
		var pieces := 0
		var lo := 1 << 30
		var hi := 0
		var credits := 0
		var share := 0.0
		var notes := 0
		var cartons := 0
		var pages := 0
		var kinds := {}
		for i in seeds:
			for d: int in [1, 2, 3, 4]:
				var p: Floor.FloorPlan = Clinic.generate_clinic("seed-%d" % i, d) if place == "clinic" else Annex.generate_annex("seed-%d" % i, d)
				var base := Run.floor_quota(d, crew)
				var f := Findables.fill_for(p, p.seed, d, base, Findables.trait_for(p.place, true), 3, [])
				n += 1
				pieces += f.pieces.size()
				lo = mini(lo, f.pieces.size())
				hi = maxi(hi, f.pieces.size())
				credits += f.credits
				share += float(f.credits) / base
				notes += f.notes
				cartons += f.cartons
				pages += f.pages
				for sp in Findables.spots_for(p, p.seed, d):
					kinds[sp.kind] = int(kinds.get(sp.kind, 0)) + 1
		var parts: Array[String] = []
		for k: StringName in kinds:
			parts.append("%s %.1f" % [k, int(kinds[k]) / float(n)])
		print("%s: %d floors, %.1f pieces a floor (%d to %d: %s); credits %.0f (%.1f%% of the floor quota), notes %.2f, cartons %.2f, pages %.2f" % [
			place, n, float(pieces) / n, lo, hi, ", ".join(parts), float(credits) / n, 100.0 * share / n, float(notes) / n, float(cartons) / n, float(pages) / n])
	quit(0)
