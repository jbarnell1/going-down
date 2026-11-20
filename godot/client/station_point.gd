# A point in world metres from any of the shapes the station's anchors and the reactor block use (sim/station.gd,
# net/reactor_review.gd): Vector3, Vector2 (x, z), [x, y, z], [x, z], {x, y, z} / {x, z}, or {at: ...} / {pos: ...}.
# Vector3.INF for none. Shared by client/station_view.gd and client/station_crew_view.gd.
extends RefCounted

static func v3(a: Variant, y := 0.0) -> Vector3:
	if a is Vector3:
		return a
	if a is Vector2:
		return Vector3((a as Vector2).x, y, (a as Vector2).y)
	if a is Vector3i:
		return Vector3(a as Vector3i)
	if a is Array:
		var r: Array = a
		if r.size() >= 3:
			return Vector3(float(r[0]), float(r[1]), float(r[2]))
		if r.size() == 2:
			return Vector3(float(r[0]), y, float(r[1]))
	if a is Dictionary:
		var d: Dictionary = a
		for k: String in ["at", "pos", "position", "p"]:
			if d.has(k):
				return v3(d[k], y)
		if d.has("x") and (d.has("z") or d.has("y")):
			if d.has("z"):
				return Vector3(float(d["x"]), float(d.get("y", y)), float(d["z"]))
			return Vector3(float(d["x"]), y, float(d["y"]))
	return Vector3.INF
