# ST1: a stair on the Hanging Ward has a body (the run flag `ward_stairs`, the parameter of net/host_rules.gd _init after
# ward_homes_). Seen in the live build on 25 Nov: a player at floor height walked under a stair from its high end to its
# low end, body and camera through the treads. The rule (sim/ward/house.gd stair_depth, sim/ward/state.gd walk_clear): a
# walker cannot stand where a stair's underside is less than a standing player's eye height above their feet, unless
# they stand on that stair or above it. The North Star: "Furniture is solid" (V33); "A raised shortcut can never strand
# someone" (WD1); "Everything about a floor comes from one seed, identical for every player." Checked here:
#   1. the flag reaches the rules last, off by default, only with the seeded layout; the rooms ask for it; the Ward
#      block's layout options carry it to every screen; the eye height is the game's own;
#   2. flag off nothing changes: the recorded Ward digests, and the same pushes pass under every stair as before;
#   3. flag on, at every stair of every house (homes off and on): a push from the side or from behind into its low end
#      stops; standing under its high end with headroom is allowed; up and down the stair walks as before;
#   4. flag on: every spot reached from the lift walks back to it (prop_ward_reach stranded), every room of every house
#      is still reached from its front door, nothing the game needs stands in the forbidden space (house spots, the
#      station, hang points, winches, the bots' points, the hides), and a walker put inside it can always step out.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Footing = preload("res://sim/ward/footing.gd")
const Bots = preload("res://sim/ward/bots.gd")
const HostRules = preload("res://net/host_rules.gd")
const WardWire = preload("res://net/ward_wire.gd")
const Digest = preload("res://tests/ward_digest.gd")
const Same = preload("res://tests/prop_ward_same.gd")
const Reach = preload("res://tests/prop_ward_reach.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const Bot = preload("res://sim/bot.gd")
const View = preload("res://client/ward/view.gd")

## The layout's options as the game's rooms build them (net/host.gd start_ward_review): the seeded layout with the lift
## kept off the lowest house, the homes when asked, and this rule when `stairs`.
static func options(homes: bool, stairs: bool) -> Dictionary:
	var o := Layout.options(null, true)
	if homes:
		o["homes"] = 1
	if stairs:
		o["stairs"] = 1
	return o

## Seeds: the quick set, then the default run's.
static func seeds(t: T, homes: bool) -> Array[int]:
	var out: Array[int] = []
	out.append(190057 if homes else 441280502)
	if t.size_key() != "quick":
		out.append_array([183025961, 8143] if homes else [183025961, 8143, 1677350247])
		for k in 3:
			out.append(1000 + k * 7919)
	return out

# ------------------------------------------------------------------------------------------------
# 1. The wiring.

func test_the_flag_reaches_the_rules(t: T) -> void:
	var names: Array[String] = []
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if str(m["name"]) == "_init":
			for a: Dictionary in m["args"]:
				names.append(str(a["name"]))
	# DG0 added `dangers_` after it, then RX3 `reactor_seek_` (the tail ..., ward_homes_, ward_stairs_, dangers_, reactor_seek_).
	t.eq(names[-3], "ward_stairs_", "ward_stairs_ is the parameter before DG0's dangers_")
	t.eq(names[-2], "dangers_", "DG0's dangers_ comes right after it")
	t.eq(names[-1], "reactor_seek_", "then RX3's reactor_seek_, the last")
	t.eq(names[-4], "ward_homes_", "right after WH1's ward_homes_")
	var stairs := names.find("ward_stairs_")
	t.check(not HostRules.new(true, 1).ward_stairs, "off by default")
	var args: Array = [true, 1, []]
	while args.size() < names.size():
		args.append(false)
	var late := names.find("late_floors_")
	var lay := names.find("ward_layout_")
	args[late] = true
	args[lay] = true
	args[stairs] = true
	t.check((HostRules.new.callv(args) as HostRules).ward_stairs, "on with the late floors and the seeded layout")
	args[lay] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_stairs, "never without the seeded layout")
	args[lay] = true
	args[late] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_stairs, "never without the late floors")
	args[late] = true
	args[stairs] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_stairs, "off when not asked")
	t.check(HostRules.ward_stairs_by_arg(), "no ward_stairs=0 on this command line: the rooms ask for it")
	var room := FileAccess.get_file_as_string("res://server/room.gd")
	t.check(room.contains("ward_layout and late_floors and not (ward_review or reactor_review or orientation_review) and HostRules.ward_stairs_by_arg(),"), "server/room.gd passes it (before DG0's dangers), with the layout")
	var local := FileAccess.get_file_as_string("res://net/local_room.gd")
	t.check(local.contains("late_floors_on() and not _orientation_playtest and ward_layout and HostRules.ward_stairs_by_arg(),"), "net/local_room.gd passes it (before DG0's dangers), with the layout")
	var host := FileAccess.get_file_as_string("res://net/host.gd")
	t.eq(host.count("if ward_stairs():\n\t\toptions[\"stairs\"] = 1"), 2, "net/host.gd puts it in the options of both of its Wards")

func test_the_wire_carries_it(t: T) -> void:
	for homes: bool in [false, true]:
		for lift: bool in [false, true]:
			var o := Layout.options(null, lift)
			if homes:
				o["homes"] = 1
			var before := Layout.to_wire(o)
			o["stairs"] = 1
			var wire := Layout.to_wire(o)
			t.eq(wire.size(), 6, "with the rule the options are six numbers (homes %s, lift_clear %s)" % [homes, lift])
			t.eq(wire.slice(0, 3), before.slice(0, 3), "the first three as they were")
			var back := Layout.from_wire(wire)
			t.eq(Layout.to_wire(back), wire, "and come back as they went (homes %s, lift_clear %s)" % [homes, lift])
			t.check(int(back.get("stairs", 0)) == 1 and back.has("lift_clear") == lift and back.has("homes") == homes, "with the rule, and the other two as they were: %s" % str(back))
			var w := Ward.new(8143, Layout.from_wire(wire))
			t.check(w.stairs_solid and w.houses[1].stairs_solid, "a screen's Ward built from the block has the rule")
			t.eq(w.layout_wire(), wire, "and sends the same options on")
	t.eq(Layout.to_wire(Layout.options(null)), [2, 110, 150], "without it the wire is what it was")
	t.eq(Layout.to_wire(options(true, false)), [2, 110, 150, 1, 1], "with the homes and no rule, WH1's five")
	t.eq(Layout.from_wire([2, 110, 150, 0, 0, 2]), {}, "a sixth number that is not 1 is refused")
	t.eq(Layout.from_wire([2, 110, 150, 0, 2, 1]), {}, "a fifth that is not 0 or 1 is refused with six")
	t.eq(Layout.from_wire([2, 110, 150, 0, 0, 1, 1]), {}, "seven are refused")
	var block := {"collectionAt": 600.0, "departAt": -1.0, "bridgeLowered": false, "phase": "away", "house": -1,
		"startedAt": -1.0, "encounter": "idle", "armPoints": [], "doors": [true, true, true, true, true, true, true, true],
		"boarded": [], "leftBehind": [], "seed": 8143, "caught": [], "native": true, "layout": [2, 110, 150, 1, 0, 1]}
	var back := WardWire.decode(WardWire.encode(block))
	t.eq(back.get("layout"), [2, 110, 150, 1, 0, 1], "the Ward block carries the six")
	block["layout"] = [2, 110, 150, 1, 0, 3]
	t.eq(WardWire.decode(WardWire.encode(block)), {}, "and refuses a bad sixth")

func test_the_eye_height_is_the_games(t: T) -> void:
	t.eq(House.STAND_EYE, EyeHeight.STAND, "the rules' standing eye is client/eye_height.gd STAND")
	t.eq(House.STAND_EYE, Bot.BOT_EYE, "and the bots' standing eye")

# ------------------------------------------------------------------------------------------------
# 2 and 3. Pushes at every stair.

## A stair's frame (local): {along_x, s0, dir, length, lane, rise, base}.
static func _frame(st: House.Stair) -> Dictionary:
	var along_x := st.from.x != st.to.x
	var s0 := st.from.x if along_x else st.from.z
	var s1 := st.to.x if along_x else st.to.z
	return {"along_x": along_x, "s0": s0, "dir": signf(s1 - s0), "length": absf(s1 - s0),
		"lane": st.from.z if along_x else st.from.x, "rise": st.to.y - st.from.y, "base": st.from.y}

## A local point at `a` metres up the run from the low end and `side` metres across it from the lane, feet at `y`.
static func _at(f: Dictionary, a: float, side: float, y: float) -> Vector3:
	var along := float(f.s0) + float(f.dir) * a
	var lane := float(f.lane) + side
	return Vector3(along, y, lane) if f.along_x else Vector3(lane, y, along)

## A flat direction (world) in the house's frame.
static func _flat(h: House, local_dir: Vector3) -> Vector2:
	var d := h.to_world(local_dir) - h.to_world(Vector3.ZERO)
	return Vector2(d.x, d.z)

## Feet on the house's floor at a local point (world), or INF when there is no floor or a walker cannot stand there.
static func _floor_feet(w: Ward, h: House, local: Vector3) -> Vector3:
	var at := h.to_world(local)
	var y := w.footing.walking_height(Vector2(at.x, at.z), at.y, w.bridge_lowered)
	if not is_finite(y) or absf(y - at.y) > 0.05:
		return Vector3.INF
	at.y = y
	return at if w.walk_clear(at, at) else Vector3.INF

## How far up the run (from the low end) the side push aims: where the treads are 0.7 m up (under a home's cupboard).
const SIDE_LINE := 0.7

## The side push at a stair from one side (`sign` 1 or -1 across its lane): from a standing spot 0.35 m clear of its
## side on the house's floor, walked 0.9 m across towards its lane. {"ok": the spot can be stood on, "start", "end",
## "side_end": how far across from the lane the walker ended}.
static func side_push(w: Ward, h: House, st: House.Stair, sign: float) -> Dictionary:
	var f := _frame(st)
	var a := float(f.length) * SIDE_LINE / float(f.rise)
	var gap := sign * (House.STAIR_WIDTH * 0.5 + 0.15 + 0.35)
	var start := _floor_feet(w, h, _at(f, a, gap, float(f.base)))
	if not start.is_finite():
		return {"ok": false}
	var into := Vector3(0, 0, -sign) if f.along_x else Vector3(-sign, 0, 0)
	var end := w.walk(start, _flat(h, into) * 0.9)
	var local := h.to_local(end)
	return {"ok": true, "start": start, "end": end, "side_end": absf((local.z if f.along_x else local.x) - float(f.lane))}

## Where under the run the underside first clears a standing walker's eyes over their whole body (a, metres up the run).
static func _headroom_a(f: Dictionary) -> float:
	return 0.15 + float(f.length) * (House.STAND_EYE + House.STAIR_BODY) / float(f.rise)

## The push from behind: standing under the high end on the lane (headroom), walked 2 m down the run. {"ok", "start",
## "end", "a_end": where along the run it ended}.
static func behind_push(w: Ward, h: House, st: House.Stair) -> Dictionary:
	var f := _frame(st)
	var a := _headroom_a(f) + 0.1
	if a > float(f.length) - 0.05:
		return {"ok": false}
	var start := _floor_feet(w, h, _at(f, a, 0.0, float(f.base)))
	if not start.is_finite():
		return {"ok": false}
	var down := Vector3(-float(f.dir), 0, 0) if f.along_x else Vector3(0, 0, -float(f.dir))
	var end := w.walk(start, _flat(h, down) * 2.0)
	var local := h.to_local(end)
	return {"ok": true, "start": start, "end": end, "a_end": ((local.x if f.along_x else local.z) - float(f.s0)) * float(f.dir)}

## Up the stair from 0.3 m before its foot to 0.4 m past its top, in 0.25 m pushes, then back down. {"top": feet at the
## top, "bottom": feet back at the foot}.
static func climb(w: Ward, h: House, st: House.Stair) -> Dictionary:
	var f := _frame(st)
	# From 0.3 m before the foot (a home's), else the foot itself (today's houses start at their side wall).
	var start := Vector3.INF
	for a: float in [-0.3, 0.0]:
		var p := h.to_world(_at(f, a, 0.0, float(f.base)))
		p.y = w.footing.walking_height(Vector2(p.x, p.z), p.y, w.bridge_lowered)
		if is_finite(p.y) and w.walk_clear(p, p):
			start = p
			break
	if not start.is_finite():
		return {"ok": false}
	var up := Vector3(float(f.dir), 0, 0) if f.along_x else Vector3(0, 0, float(f.dir))
	var at := start
	var n := ceili((float(f.length) + 0.7) / 0.25)
	for i in n:
		at = w.walk(at, _flat(h, up) * 0.25)
	var top := at
	for i in n:
		at = w.walk(at, _flat(h, -up) * 0.25)
	return {"ok": true, "start": start, "top": top, "bottom": at}

func test_pushes_at_every_stair(t: T) -> void:
	var stats := {"side": 0, "behind": 0, "climb": 0, "stairs": 0}
	for homes: bool in [false, true]:
		for seed_value: int in seeds(t, homes):
			var off := Ward.new(seed_value, options(homes, false))
			var on := Ward.new(seed_value, options(homes, true))
			for i in on.houses.size():
				for k in on.houses[i].stairs.size():
					stats.stairs += 1
					var name := "seed %d homes %s house %d stair %d" % [seed_value, homes, i, k]
					var st_off: House.Stair = off.houses[i].stairs[k]
					var st_on: House.Stair = on.houses[i].stairs[k]
					# A side where, without the rule, the push walks in under the treads (a wall or a piece of furniture may
					# stand beside a stair, so not every side is a test of the rule).
					for sign: float in [1.0, -1.0]:
						var s0 := side_push(off, off.houses[i], st_off, sign)
						if not s0.ok or float(s0.side_end) >= House.STAIR_WIDTH * 0.5:
							continue
						stats.side += 1
						var s1 := side_push(on, on.houses[i], st_on, sign)
						t.check(s1.ok and (s1.start as Vector3).is_equal_approx(s0.start), "%s: flag on, the same spot beside it" % name)
						if s1.ok:
							t.check(float(s1.side_end) >= House.STAIR_WIDTH * 0.5 + 0.14, "%s: flag off a push from the side walks in under the treads (%.2f m from the lane); flag on it stops at the stair's side (%.2f m)" % [name, s0.side_end, s1.side_end])
							t.check(on.stair_depth(s1.end) == 0.0, "%s: and ends outside the forbidden space" % name)
						break
					var b0 := behind_push(off, off.houses[i], st_off)
					var b1 := behind_push(on, on.houses[i], st_on)
					if b0.ok:
						stats.behind += 1
						var limit := _headroom_a(_frame(st_on))
						t.check(b1.ok, "%s: flag on, standing under the high end with headroom is allowed" % name)
						t.check(float(b0.a_end) < limit - 0.3, "%s: flag off, a push from behind walks on under the low end (to %.2f m up the run)" % [name, b0.a_end])
						if b1.ok:
							t.check(float(b1.a_end) >= limit - 0.02, "%s: flag on, it stops where the headroom ends (%.2f m up the run, headroom from %.2f)" % [name, b1.a_end, limit])
					var c0 := climb(off, off.houses[i], st_off)
					var c1 := climb(on, on.houses[i], st_on)
					var top_y := on.houses[i].to_world(st_on.to).y
					var foot_y := on.houses[i].to_world(st_on.from).y
					if c0.ok and absf((c0.top as Vector3).y - top_y) < 0.25:
						stats.climb += 1
						t.check(c1.ok and absf((c1.top as Vector3).y - top_y) < 0.25, "%s: flag on, up the stair to its top (%.2f, top %.2f)" % [name, (c1.top as Vector3).y, top_y])
						t.check(absf((c1.bottom as Vector3).y - foot_y) < 0.25, "%s: and back down to its foot (%.2f, foot %.2f)" % [name, (c1.bottom as Vector3).y, foot_y])
						t.check((c1.top as Vector3).distance_to(c0.top) < 0.15 and (c1.bottom as Vector3).distance_to(c0.bottom) < 0.15, "%s: the same walk up and down as with the flag off" % name)
	t.check(stats.side >= stats.stairs / 2 and stats.behind > 0 and stats.climb >= stats.stairs / 2, "the pushes were made (%s)" % str(stats))
	t.note("stairs %d: side pushes %d, from behind %d, up and down %d" % [stats.stairs, stats.side, stats.behind, stats.climb])

func test_flag_off_the_ward_is_as_recorded(t: T) -> void:
	for s: int in Same.SEEDS:
		t.eq(Digest.line(s), Same.GOLDEN[s], "seed %d: without the rule the Ward is the one recorded" % s)
		var w := Ward.new(s)
		t.check(not w.stairs_solid and not w.houses[1].stairs_solid, "seed %d: no rule unless asked" % s)
	# The rule changes walking only: the layout, the houses and the fixtures are the same Ward with it on.
	for homes: bool in [false, true]:
		var a := Digest.parts_of(Ward.new(8143, options(homes, false)))
		var b := Digest.parts_of(Ward.new(8143, options(homes, true)))
		t.eq(b.slice(0, 2), a.slice(0, 2), "homes %s: with the rule, the same layout and houses" % homes)
		t.check(a[3] != b[3], "homes %s: and some spots of the floor are no longer stood on" % homes)
	# Flag off, every spot the rule would move is where it was.
	var off := Ward.new(8143, options(false, false))
	for h: House in off.houses:
		var p: Vector3 = h.areas[&"rear"]
		t.eq(h.clear_of_stairs(Vector3(p.x, 0, p.z)), Vector3(p.x, 0, p.z), "flag off a spot is never moved")

# ------------------------------------------------------------------------------------------------
# 4. Nobody stranded, every room reached, nothing needed inside a stair, and a body put inside walks out.

func test_nobody_is_stranded(t: T) -> void:
	var lines: Array[String] = []
	var total := 0
	var runs := 0
	for homes: bool in [false, true]:
		for seed_value: int in seeds(t, homes):
			for lowered: bool in [true, false]:
				var bad := Reach.stranded(seed_value, lowered, true, false, options(homes, true))
				runs += 1
				total += bad.size()
				if not bad.is_empty():
					lines.append("seed %d homes %s bridge %s: %d, first %s" % [seed_value, homes, "down" if lowered else "up", bad.size(), str(bad[0].snappedf(0.01))])
	t.check(total == 0, "with the rule, every spot reached from the lift walks back to it: %s" % "; ".join(lines))
	t.note("%d Wards with the rule: %d stranded spots" % [runs, total])

## Every room of a house (each storey's), by the names area_at_any gives.
static func all_rooms(h: House) -> Array[String]:
	var out: Array[String] = []
	if h.homes():
		for level in h.rooms_by_level.size():
			for room: Dictionary in h.rooms_by_level[level]:
				out.append(String(room.name))
		return out
	out.append_array(["entry", "middle", "rear"])
	for level in range(1, h.storeys.size() - 1):
		out.append("up%d_front" % level)
		out.append("up%d_back" % level)
	return out

## The rooms of house i reached from just inside its front door by `step`-metre walks of the model, eight ways (until
## every room is reached or `budget` spots are searched).
static func flood_rooms(w: Ward, i: int, step := 0.15, budget := 20000) -> Dictionary:
	var h := w.houses[i]
	var want := all_rooms(h)
	var start := h.to_world(Vector3(h.door.get_center().x, 0.0, 0.35))
	start.y = w.footing.walking_height(Vector2(start.x, start.z), start.y, w.bridge_lowered)
	var seen := {Vector3i(roundi(start.x / step), roundi(start.z / step), roundi(start.y / 0.25)): true}
	var todo: Array[Vector3] = [start]
	var head := 0
	var found := {}
	var bounds := h.floor_bounds.grow(0.2)
	while head < todo.size() and head < budget and found.size() < want.size():
		var at := todo[head]
		head += 1
		var room := String(h.area_at_any(h.to_local(at + Vector3.UP * 1.25)))
		if room != "":
			found[room] = true
		for d in 8:
			var to := w.walk(at, Vector2.from_angle(d * PI / 4.0) * step)
			if Vector2(to.x - at.x, to.z - at.z).length() < step * 0.3:
				continue
			var local := h.to_local(to)
			if not bounds.has_point(Vector2(local.x, local.z)):
				continue
			var k := Vector3i(roundi(to.x / step), roundi(to.z / step), roundi(to.y / 0.25))
			if not seen.has(k):
				seen[k] = true
				todo.append(to)
	return found

func test_every_room_is_still_reached(t: T) -> void:
	var lost: Array[String] = []
	var houses := 0
	for homes: bool in [false, true]:
		var list := seeds(t, homes)
		for seed_value: int in list.slice(0, 1 if t.size_key() == "quick" else 3):
			var on := Ward.new(seed_value, options(homes, true))
			on.phase = &"boarding"
			for i in on.houses.size():
				houses += 1
				var found := flood_rooms(on, i)
				var want := all_rooms(on.houses[i])
				if found.size() == want.size():
					continue
				# Only a room the flag took away is a failure: ask the Ward without the rule.
				var off := Ward.new(seed_value, options(homes, false))
				off.phase = &"boarding"
				var before := flood_rooms(off, i)
				for room: String in before:
					if not found.has(room):
						lost.append("seed %d homes %s house %d: %s" % [seed_value, homes, i, room])
	t.check(lost.is_empty(), "every room reached from its front door without the rule is reached with it: %s" % "; ".join(lost))
	t.note("%d houses walked room to room with the rule" % houses)

## Everything the game or its tools need a walker to stand on, as [name, feet].
static func needed_spots(w: Ward) -> Array:
	var out: Array = []
	for i in w.houses.size():
		var h := w.houses[i]
		for spot: String in ["corner", "entry", "middle", "rear"]:
			var at := View.house_spot(h, spot)
			if at.is_finite():
				out.append(["house %d %s" % [i, spot], at])
		for k in h.hides.size():
			out.append(["house %d hide %d (inside)" % [i, k], w.hide_feet_at(i, k)])
	out.append(["the station", w.station])
	for p: Dictionary in w.hang_points:
		out.append(["hang point at house %d" % int(p.house), p.at])
	for s: Dictionary in w.switches:
		out.append(["winch at house %d" % int(s.house), s.position])
	var g := Bots.build_graph(w)
	for n in g.pts.size():
		out.append(["bots' point %d" % n, g.pts[n]])
	return out

## A spot a walker can stand on within `reach` (flat) of a hide's furniture, at its floor: the standing spot.
static func _hide_stand(w: Ward, h: House, hide: Dictionary, reach: float) -> bool:
	var box: AABB = hide.box
	var c := box.get_center()
	for r: float in [0.3, 0.5, 0.7]:
		for d in 16:
			var dir := Vector2.from_angle(d * PI / 8.0)
			var p := Vector3(c.x + dir.x * (box.size.x * 0.5 + r), box.position.y, c.z + dir.y * (box.size.z * 0.5 + r))
			var flat := Rect2(box.position.x, box.position.z, box.size.x, box.size.z)
			if (Vector2(p.x, p.z) - Vector2(p.x, p.z).clamp(flat.position, flat.end)).length() > reach:
				continue
			var at := h.to_world(p)
			var y := w.footing.walking_height(Vector2(at.x, at.z), at.y, w.bridge_lowered)
			if is_finite(y) and absf(y - at.y) < 0.05:
				at.y = y
				if w.walk_clear(at, at):
					return true
	return false

func test_nothing_needed_is_inside_a_stair(t: T) -> void:
	var bad: Array[String] = []
	var moved: Array[String] = []
	var count := 0
	var all: Array[int] = []
	for k in (4 if t.size_key() == "quick" else 40):
		all.append(1000 + k * 7919)
	for homes: bool in [false, true]:
		for seed_value: int in all + seeds(t, homes):
			var off := Ward.new(seed_value, options(homes, false))
			var on := Ward.new(seed_value, options(homes, true))
			var before := needed_spots(off)
			var after := needed_spots(on)
			for j in after.size():
				count += 1
				var at: Vector3 = after[j][1]
				if on.stair_depth(at) > 0.0:
					bad.append("seed %d homes %s %s at %s" % [seed_value, homes, after[j][0], str(at.snappedf(0.01))])
				elif j < before.size() and off.walk_clear(before[j][1], before[j][1]) and not on.walk_clear(at, at) and not String(after[j][0]).contains("inside"):
					bad.append("seed %d homes %s %s at %s: no longer stood on" % [seed_value, homes, after[j][0], str(at.snappedf(0.01))])
				if j < before.size() and not (before[j][1] as Vector3).is_equal_approx(at) and moved.size() < 6:
					moved.append("%s %s" % [seed_value, after[j][0]])
			for i in on.houses.size():
				var h := on.houses[i]
				for k in h.hides.size():
					if _hide_stand(off, off.houses[i], off.houses[i].hides[k], Ward.HIDE_REACH) and not _hide_stand(on, h, h.hides[k], Ward.HIDE_REACH):
						bad.append("seed %d house %d hide %d: nowhere to stand to get in" % [seed_value, i, k])
	t.check(bad.is_empty(), "nothing the game needs stands under a stair's low end with the rule: %s" % "; ".join(bad))
	t.note("%d spots looked at; moved out along a stair's side, for example: %s" % [count, ", ".join(moved)])

## A search of 0.1 m walks of the model, sixteen ways, from a spot inside the forbidden space: true when one walk lands
## outside it (within `budget` spots).
static func walks_out(w: Ward, from: Vector3, budget := 3000) -> bool:
	var seen := {Vector3i(roundi(from.x / 0.1), roundi(from.z / 0.1), roundi(from.y / 0.25)): true}
	var todo: Array[Vector3] = [from]
	var head := 0
	while head < todo.size() and head < budget:
		var at := todo[head]
		head += 1
		for d in 16:
			var to := w.walk(at, Vector2.from_angle(d * PI / 8.0) * 0.1)
			if to == at:
				continue
			if w.stair_depth(to) <= 0.0:
				return true
			var k := Vector3i(roundi(to.x / 0.1), roundi(to.z / 0.1), roundi(to.y / 0.25))
			if not seen.has(k):
				seen[k] = true
				todo.append(to)
	return false

func test_a_body_put_inside_walks_out(t: T) -> void:
	var tried := 0
	var stuck: Array[String] = []
	for homes: bool in [false, true]:
		for seed_value: int in seeds(t, homes).slice(0, 2):
			var w := Ward.new(seed_value, options(homes, true))
			for i in w.houses.size():
				var h := w.houses[i]
				for k in h.stairs.size():
					var f := _frame(h.stairs[k])
					for a_frac: float in [0.15, 0.3]:
						for side: float in [0.0, 0.3, -0.3]:
							var at := h.to_world(_at(f, float(f.length) * a_frac, side, float(f.base)))
							at.y = w.footing.walking_height(Vector2(at.x, at.z), at.y, false)
							if not is_finite(at.y) or w.stair_depth(at) <= 0.0:
								continue
							tried += 1
							t.check(not w.walk_clear(at, at), "seed %d house %d stair %d: a spot inside is not one to stand on" % [seed_value, i, k])
							if not walks_out(w, at):
								stuck.append("seed %d homes %s house %d stair %d at %s" % [seed_value, homes, i, k, str(at.snappedf(0.01))])
	t.check(tried > 10, "bodies were put inside (%d)" % tried)
	t.check(stuck.is_empty(), "a body put inside always steps out: %s" % "; ".join(stuck))
	t.note("%d bodies put under a stair's low end; every one walked out" % tried)
