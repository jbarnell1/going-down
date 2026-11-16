# Floors shared between test files (generating one takes a few tens of milliseconds in GDScript).
extends RefCounted

const Clinic = preload("res://sim/clinic.gd")
const Floor = preload("res://sim/floor.gd")

static var _cache := {}

static func plan(seed: String, depth: int) -> Floor.FloorPlan:
	var key := "%s/%d" % [seed, depth]
	if not _cache.has(key):
		_cache[key] = Clinic.generate_clinic(seed, depth)
	return _cache[key]

## The 800 floors the clinic property tests use: seed-0..199 at depths 1 to 4, depth-major.
static func property_plans() -> Array[Floor.FloorPlan]:
	var out: Array[Floor.FloorPlan] = []
	for depth: int in [1, 2, 3, 4]:
		for i in 200:
			out.append(plan("seed-%d" % i, depth))
	return out
