# Optional Ward snapshot block. The client consumes only validated host facts.
extends RefCounted

const LIFT_PHASES := ["unloading", "away", "boarding", "departed"]
const RIGGER_PHASES := ["idle", "warning", "climbing", "searching", "lingering", "returning", "chasing", "rearing"]
## RR1: what the crawling Rigger is on (sim/ward/rigger_graph.gd KIND_NAMES).
const ON := ["lair", "line", "wall", "roof", "under", "deck", "reach"]

static func encode(s: Dictionary) -> Array:
	var out := [s.collectionAt, s.departAt, s.bridgeLowered, LIFT_PHASES.find(s.phase),
		s.house, s.startedAt, RIGGER_PHASES.find(s.encounter), s.armPoints, s.doors, s.boarded, s.leftBehind, s.seed, s.caught]
	# WN1: a fourteenth field only when the main scene plays the Ward (net/host_rules.gd ward_place); off, the
	# block is the thirteen it always was.
	# WG1: a fifteenth field only for a generated layout (net/host_rules.gd ward_layout): its options
	# (sim/ward/layout.gd to_wire); the fourteenth is then native, true or false.
	if s.has("layout"):
		out.append(s.get("native", false) == true)
		out.append(s.layout)
	elif s.get("native", false) == true:
		out.append(true)
	# WC1: one more field after those, the call's station and the web (sim/ward/state.gd extras), only with either flag
	# on: the fifteenth, or the sixteenth after WG1's layout.
	# RR1: the crawling Rigger's pose rides in the extras (with the run flag rigger_roam only), as "rigger".
	var extras: Variant = s.get("extras")
	if s.has("rigger"):
		var r: Dictionary = s.rigger
		extras = (extras as Dictionary).duplicate() if extras is Dictionary else {}
		extras["rigger"] = [r.at, r.rot, ON.find(r.on), r.out, r.opening, r.chase, r.reachAt, r.rearAt]
	if extras != null:
		if out.size() == 13:
			out.append(false)
		out.append(extras)
	return out

static func decode(raw: Variant) -> Dictionary:
	# WC1 and WG1 merged: 13 fields; 14 with native; 15 with native and either the layout (an Array, WG1) or the
	# extras (a Dictionary, WC1); 16 with native, the layout, then the extras.
	if not raw is Array or raw.size() < 13 or raw.size() > 16:
		return {}
	var s: Array = raw
	if s.size() == 14 and not (s[13] is bool and s[13]):
		return {}
	var layout_at := -1
	var extras_at := -1
	if s.size() >= 15:
		if not s[13] is bool:
			return {}
		if s[14] is Array:
			layout_at = 14
			if s.size() == 16:
				extras_at = 15
		elif s.size() == 15:
			extras_at = 14
		else:
			return {}
	if layout_at >= 0:
		var lay: Variant = s[layout_at]
		# RL1: a fourth element, 1, only with the run flag ward_lift_clear (sim/ward/layout.gd to_wire). WH1: a fifth
		# element, 1, only with the run flag ward_homes, and then the fourth is always there (0 or 1).
		if lay.size() < 3 or lay.size() > 5:
			return {}
		if not _integer(lay[0], 2, 2) or not _integer(lay[1], 50, 300) or not _integer(lay[2], 0, 500):
			return {}
		if lay.size() == 4 and not _integer(lay[3], 1, 1):
			return {}
		if lay.size() == 5 and (not _integer(lay[3], 0, 1) or not _integer(lay[4], 1, 1)):
			return {}
	if extras_at >= 0 and not _extras_ok(s[extras_at]):
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
	if s.size() >= 14 and s[13] == true:
		out["native"] = true
	if layout_at >= 0:
		out["layout"] = [int(s[layout_at][0]), int(s[layout_at][1]), int(s[layout_at][2])]
		for extra in range(3, (s[layout_at] as Array).size()):
			(out["layout"] as Array).append(int(s[layout_at][extra]))
	if extras_at >= 0:
		var extras: Dictionary = (s[extras_at] as Dictionary).duplicate()
		if extras.has("rigger"):
			out["rigger"] = _rigger(extras["rigger"])
			extras.erase("rigger")
		if not extras.is_empty():
			out["extras"] = extras
	return out

## WC1: the extras as sim/ward/state.gd extras writes them, and nothing else.
static func _extras_ok(e: Variant) -> bool:
	if not e is Dictionary:
		return false
	for key: Variant in e:
		if not key in ["called", "station", "stationHouse", "hangPoints", "web", "cuts", "rigger", "inner", "hidden"]:
			return false
	if e.has("rigger") and _rigger(e["rigger"]).is_empty():
		return false
	# WH1c: the homes' shut inner doors (a mask a house) and who is hidden in which hide.
	if e.has("inner"):
		if not e["inner"] is Array or e["inner"].size() > 8:
			return false
		for mask: Variant in e["inner"]:
			if not _integer(mask, 0, 65535):
				return false
	if e.has("hidden"):
		if not e["hidden"] is Dictionary or e["hidden"].size() > 8:
			return false
		for id: Variant in e["hidden"]:
			var row: Variant = e["hidden"][id]
			if not id is String or id.length() > 64 or not row is Array or row.size() != 2 or not _integer(row[0], 0, 7) or not _integer(row[1], 0, 63):
				return false
	if e.has("called") and not e["called"] is bool:
		return false
	if e.has("station") and not _point(e["station"]):
		return false
	if e.has("stationHouse") and not _integer(e["stationHouse"], 0, 7):
		return false
	if e.has("hangPoints"):
		if not e["hangPoints"] is Array or e["hangPoints"].size() > 8:
			return false
		for p: Variant in e["hangPoints"]:
			if not _point(p):
				return false
	for key: String in ["web", "cuts"]:
		if not e.has(key):
			continue
		if not e[key] is Dictionary or e[key].size() > 8:
			return false
		for id: Variant in e[key]:
			var row: Variant = e[key][id]
			if not id is String or id.length() > 64 or not row is Dictionary:
				return false
			if key == "web" and not (_integer(row.get("point"), 0, 7) and _time(row.get("caughtAt")) and _time(row.get("hangAt"))):
				return false
			if key == "cuts" and not (row.get("id") is String and _time(row.get("from")) and _time(row.get("done"))):
				return false
	return true

static func _point(p: Variant) -> bool:
	if not p is Array or p.size() != 3:
		return false
	for axis: Variant in p:
		if not _numeric(axis) or absf(float(axis)) > 1024.0:
			return false
	return true

static func _rigger(raw: Variant) -> Dictionary:
	if not raw is Array or raw.size() != 8:
		return {}
	var r: Array = raw
	if not r[0] is Array or r[0].size() != 3 or not r[1] is Array or r[1].size() != 4:
		return {}
	for axis: Variant in r[0]:
		if not _numeric(axis) or absf(float(axis)) > 1024.0:
			return {}
	for part: Variant in r[1]:
		if not _numeric(part) or absf(float(part)) > 1.01:
			return {}
	if not _integer(r[2], 0, ON.size() - 1) or not r[3] is bool or not _integer(r[4], -1, 7) or not r[5] is String or r[5].length() > 64:
		return {}
	if not _time(r[6]) or not _time(r[7]):
		return {}
	return {"at": r[0], "rot": r[1], "on": ON[int(r[2])], "out": r[3], "opening": int(r[4]), "chase": r[5], "reachAt": float(r[6]), "rearAt": float(r[7])}

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