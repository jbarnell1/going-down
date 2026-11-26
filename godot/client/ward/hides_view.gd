# WH1d: the Ward homes' hiding places on a screen (the run flag ward_homes; the rules are sim/ward/state.gd's hides and
# sim/hides.gd WARD_SPEC). Pure functions of the Ward's walk model and the snapshot's Ward block, so every screen
# agrees and nothing here decides a rule:
#   - which hide F would get this player into (the rules' own pick, state.gd hide_in_reach), offered only where the
#     rules would keep them in it (within HIDE_LEAVE of the hide);
#   - the camera in a hide: at the hide's eye height (WARD_SPEC), inside the furniture near its open side, looking out
#     of it and turned only within VIEW_HALF. Nothing is drawn over the picture: the furniture's own hollow shape
#     (client/ward/view.gd _hide_piece) frames the view, as on every floor since the owner's word on 21 Nov;
#   - a crewmate in a hide drawn in it, as other floors draw theirs (client/play_link.gd _seek_figure).
# The open side is the side of the furniture that faces its room, worked out as the rules place the hand's search point
# (state.gd hide_reach_local).
extends RefCounted

const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Hides = preload("res://sim/hides.gd")

## How far the view may turn from straight out of the hide, degrees each side: the bed's and the table's are the
## Clinic's and the Annex's (sim/hides.gd SPEC), the wardrobe's crack the cabinet's; over a bath's rim, wide.
const VIEW_HALF := {&"bed": 70.0, &"table": 60.0, &"wardrobe": 20.0, &"bath": 80.0}
## How far up or down the view may turn in a hide (radians; play_link.gd PEEK_PITCH, every floor's).
const PITCH := 0.35
## How far in from the open side the eyes are (metres): the wardrobe's just behind its doors' crack.
const INSET := {&"bed": 0.3, &"table": 0.3, &"wardrobe": 0.14, &"bath": 0.3}
## The crack between a wardrobe's two doors (metres): with the eyes INSET behind it, about VIEW_HALF each side.
const CRACK := 0.1
## The prompt is offered a little inside the rules' HIDE_LEAVE, so the host keeps the player in.
const LEAVE_MARGIN := 0.05
## Seen from outside, crewmates in one hide sit this far apart (play_link.gd SLOT_GAP).
const SLOT_GAP := 0.55

## Whether the snapshot's Ward block has the homes' hides (its extras carry "hidden" only in a Ward of homes).
static func on(latest: Variant) -> bool:
	return _extras(latest).has("hidden")

static func _extras(latest: Variant) -> Dictionary:
	if not latest is Dictionary or not (latest as Dictionary).get("ward") is Dictionary:
		return {}
	var e: Variant = (latest["ward"] as Dictionary).get("extras")
	return e if e is Dictionary else {}

static func _hidden_rows(latest: Variant) -> Dictionary:
	var rows: Variant = _extras(latest).get("hidden")
	return rows if rows is Dictionary else {}

## The hide a player is in, [house, hide], or [] when they are in none.
static func hidden_of(latest: Variant, id: String) -> Array:
	var row: Variant = _hidden_rows(latest).get(id)
	if row is Array and (row as Array).size() == 2:
		return [int(row[0]), int(row[1])]
	return []

## The hide F gets a player standing at `feet` (world) into: the rules' pick, offered only where the rules keep them in
## it. [house, hide], or [-1, -1].
static func near(model: Ward, feet: Vector3, latest: Variant) -> Array:
	model.set_hidden_wire(_hidden_rows(latest))
	var pick: Array = model.hide_in_reach(feet)
	if int(pick[0]) < 0:
		return [-1, -1]
	var spot := model.hide_feet_at(int(pick[0]), int(pick[1]))
	if Vector2(feet.x - spot.x, feet.z - spot.z).length() > Ward.HIDE_LEAVE - LEAVE_MARGIN:
		return [-1, -1]
	return pick

## A place to stand by a hide (world feet) where F gets a player into exactly that hide and the rules keep them in it,
## the nearest such to where the rules hold them; Vector3.INF when there is none (tests and the look script).
static func stand_spot(model: Ward, house: int, hide: int, latest: Variant = null) -> Vector3:
	var fixture: House = model.houses[house]
	var box: AABB = fixture.hides[hide].box
	var spot := model.hide_feet_at(house, hide)
	var best := Vector3.INF
	var best_d := INF
	for ix in range(-14, 15):
		for iz in range(-14, 15):
			var w := fixture.to_world(Vector3(box.get_center().x + ix * 0.1, box.position.y, box.get_center().z + iz * 0.1))
			var y := model.footing.walking_height(Vector2(w.x, w.z), w.y, model.bridge_lowered)
			if not is_finite(y) or absf(y - w.y) > 0.3:
				continue
			w.y = y
			var d := Vector2(w.x - spot.x, w.z - spot.z).length()
			if d >= best_d or not model.walk_clear(w, w):
				continue
			var pick := near(model, w, latest)
			if int(pick[0]) == house and int(pick[1]) == hide:
				best = w
				best_d = d
	return best

static func kind_of(model: Ward, house: int, hide: int) -> StringName:
	return StringName((model.houses[house].hides[hide] as Dictionary).kind)

## The open side of a hide (local to its house): a unit vector along x or z, out of the furniture into its room.
static func out_local(fixture: House, hide: int) -> Vector3:
	var row: Dictionary = fixture.hides[hide]
	var box: AABB = row.box
	var centre := box.get_center()
	var probes: Dictionary = fixture.areas if int(row.level) == 0 else fixture.upper_areas(int(row.level))
	var room: Vector3 = probes.get(row.room, centre)
	var out := Vector3(room.x - centre.x, 0.0, room.z - centre.z)
	if out.length() < 0.05:
		# The room's probe over the piece (a table in the middle of its room): towards the middle of the room's floor.
		for r: Dictionary in fixture.rooms_by_level[int(row.level)]:
			if r.name == row.room:
				var c: Vector2 = (r.rect as Rect2).get_center()
				out = Vector3(c.x - centre.x, 0.0, c.y - centre.z)
	if out.length() < 0.05:
		return Vector3.BACK
	if absf(out.x) * box.size.z > absf(out.z) * box.size.x:
		return Vector3(signf(out.x), 0.0, 0.0)
	return Vector3(0.0, 0.0, signf(out.z) if out.z != 0.0 else 1.0)

## The eyes in a hide (local to its house): the hide's eye height above its floor, INSET in from its open side.
static func eye_local(fixture: House, hide: int) -> Vector3:
	var row: Dictionary = fixture.hides[hide]
	var box: AABB = row.box
	var kind := StringName(row.kind)
	var d := out_local(fixture, hide)
	var half := absf(d.x) * box.size.x * 0.5 + absf(d.z) * box.size.z * 0.5
	var centre := box.get_center()
	return Vector3(centre.x, box.position.y + float(row.eye), centre.z) + d * maxf(0.0, half - float(INSET.get(kind, 0.3)))

## The way out of a hide as a yaw (the camera's: looking along -z turned by yaw).
static func out_yaw(fixture: House, hide: int) -> float:
	var at := eye_local(fixture, hide)
	var w := fixture.to_world(at + out_local(fixture, hide)) - fixture.to_world(at)
	return atan2(-w.x, -w.z)

## The camera in a hide: {x, y, z (world), yaw, pitch (clamped to the hide's view), peek (false: no leaning out here),
## hide, house, kind, gapYaw, gapHalf, ward (true)}. `want_yaw` and `want_pitch` are where the player is turning to.
static func camera(model: Ward, house: int, hide: int, want_yaw: float, want_pitch: float) -> Dictionary:
	if house < 0 or house >= model.houses.size() or hide < 0 or hide >= model.houses[house].hides.size():
		return {}
	var fixture: House = model.houses[house]
	var kind := kind_of(model, house, hide)
	var at := fixture.to_world(eye_local(fixture, hide))
	var gy := out_yaw(fixture, hide)
	var half := deg_to_rad(float(VIEW_HALF.get(kind, 60.0)))
	var yaw := gy + clampf(wrapf(want_yaw - gy, -PI, PI), -half, half)
	var pitch := clampf(want_pitch, -PITCH, PITCH)
	return {"x": at.x, "y": at.y, "z": at.z, "yaw": yaw, "pitch": pitch, "peek": false, "hide": hide, "house": house,
		"kind": String(kind), "gapYaw": gy, "gapHalf": half, "ward": true}

## How a crewmate in a hide is drawn (their row of the snapshot's others, changed in place): in the hide, facing out
## of it; lying under a bed or a table and in a bath, standing in a wardrobe; side by side with the others in it.
static func place_figure(model: Ward, latest: Variant, o: Dictionary) -> void:
	var id := str(o.get("id", ""))
	var at := hidden_of(latest, id)
	if at.is_empty() or int(at[0]) >= model.houses.size() or int(at[1]) >= model.houses[int(at[0])].hides.size():
		return
	var fixture: House = model.houses[int(at[0])]
	var row: Dictionary = fixture.hides[int(at[1])]
	var box: AABB = row.box
	var d := out_local(fixture, int(at[1]))
	var across := Vector3(-d.z, 0.0, d.x)
	var ids: Array[String] = []
	var rows := _hidden_rows(latest)
	for other: Variant in rows:
		var r: Variant = rows[other]
		if r is Array and int(r[0]) == int(at[0]) and int(r[1]) == int(at[1]):
			ids.append(str(other))
	ids.sort()
	var slot := (float(maxi(0, ids.find(id))) - float(ids.size() - 1) * 0.5) * SLOT_GAP
	var centre := box.get_center()
	var feet := fixture.to_world(Vector3(centre.x, box.position.y, centre.z) + across * slot)
	o["x"] = feet.x
	o["y"] = feet.y
	o["z"] = feet.z
	o["yaw"] = out_yaw(fixture, int(at[1]))
	o["wardHide"] = String(row.kind)
	if StringName(row.kind) == &"wardrobe":
		o["gait"] = "walk"
	else:
		o["gait"] = "creep"
		o["crewPose"] = "prone"
