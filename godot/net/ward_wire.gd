# Optional Ward snapshot block. The client consumes only validated host facts.
extends RefCounted

const LIFT_PHASES := ["unloading", "away", "boarding", "departed"]
const RIGGER_PHASES := ["idle", "warning", "climbing", "searching"]

static func encode(s: Dictionary) -> Array:
	var out := [s.collectionAt, s.departAt, s.bridgeLowered, LIFT_PHASES.find(s.phase),
		s.house, s.startedAt, RIGGER_PHASES.find(s.encounter), s.armPoints, s.doors, s.boarded, s.leftBehind, s.seed, s.caught]
	# WN1: a fourteenth field only when the main scene plays the Ward (net/host_rules.gd ward_place); off, the
	# block is the thirteen it always was.
	if s.get("native", false) == true:
		out.append(true)
	return out

static func decode(raw: Variant) -> Dictionary:
	if not raw is Array or (raw.size() != 13 and raw.size() != 14):
		return {}
	var s: Array = raw
	if s.size() == 14 and not (s[13] is bool and s[13]):
		return {}
	if not _time(s[0]) or not _time(s[1]) or not _time(s[5]) or not s[2] is bool:
		return {}
	if not _integer(s[3], 0, LIFT_PHASES.size() - 1) or not _integer(s[4], -1, 7) or not _integer(s[6], 0, RIGGER_PHASES.size() - 1):
		return {}
	if not s[7] is Array or s[7].size() > 64 or not s[8] is Array or s[8].size() != 8:
		return {}
	for point: Variant in s[7]:
		if not point is Array or point.size() != 3:
			return {}
		for axis: Variant in point:
			if not _numeric(axis) or absf(float(axis)) > 1024.0:
				return {}
	for door: Variant in s[8]:
		if not door is bool:
			return {}
	if not _ids(s[9]) or not _ids(s[10]) or not _integer(s[11], -4294967295, 4294967295) or not _ids(s[12]):
		return {}
	var out := {"collectionAt": float(s[0]), "departAt": float(s[1]), "bridgeLowered": s[2], "phase": LIFT_PHASES[int(s[3])],
		"house": int(s[4]), "startedAt": float(s[5]), "encounter": RIGGER_PHASES[int(s[6])],
		"armPoints": s[7], "doors": s[8], "boarded": s[9], "leftBehind": s[10], "seed": int(s[11]), "caught": s[12]}
	if s.size() == 14:
		out["native"] = true
	return out

static func _numeric(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func _time(value: Variant) -> bool:
	return _numeric(value) and float(value) >= -1.0 and float(value) <= 1.0e9

static func _integer(value: Variant, low: int, high: int) -> bool:
	return _numeric(value) and float(value) == floorf(float(value)) and float(value) >= low and float(value) <= high

static func _ids(value: Variant) -> bool:
	if not value is Array or value.size() > 8:
		return false
	for id: Variant in value:
		if not id is String or id.length() > 64:
			return false
	return true