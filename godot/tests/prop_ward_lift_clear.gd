# RL1: the lift's house is never the lowest house of the generated Ward (sim/ward/layout.gd LIFT_CLEAR, behind the run
# flag `ward_lift_clear`, the parameter of net/host_rules.gd _init after voice_). The owner, 21 Nov: "I'm ok with making the
# lift never the lowest house". The design (docs/floors/hanging-ward.md): the Rigger "lives below the lowest house.
# He climbs only when he senses prey." On about one seed in eleven the lowest was the lift's own, so a crew walking out
# of the car was heard at once. Checked here:
#   1. flag off: the generated Ward is the one recorded from the code before RL1 (500 seeds), and the flag is off by default;
#   2. flag on: over 500 seeds the lift's house is never the lowest, and his lair is never under it;
#   3. flag on: every seed where another house was already lower is the same Ward bit for bit (recorded digest);
#   4. the changed seeds (at least 20, late-2 among them) keep the Ward's properties: every house walks to every other
#      and the lift, bridge up and down; no walkway steeper than SLOPE; his graph joins every house to his lair; from
#      every opening one room is out of the arm's reach; and the flag strands no spot (prop_ward_reach) that the
#      seeded Ward did not already strand without it (every changed seed of 500 in the default run; 273673180 named);
#   5. on late-2 a lone player WALKING out of the car is heard at once with the flag off and not with it on;
#   6. the wire carries it, and the rooms ask for it wherever they ask for the layout.
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const G = preload("res://sim/ward/rigger_graph.gd")
const Roam = preload("res://sim/ward/roam.gd")
const Digest = preload("res://tests/ward_digest.gd")
const WardLayoutProps = preload("res://tests/prop_ward_layout.gd")
const Reach = preload("res://tests/prop_ward_reach.gd")
const WardWire = preload("res://net/ward_wire.gd")
const HostRules = preload("res://net/host_rules.gd")
const House = preload("res://sim/ward/house.gd")

## Recorded from commit 6d03c6b (before RL1, HEAD's sim/ward/layout.gd copied aside) over the seeds "run-<k>".hash() for
## k in 0..499: the sha256 of every generated layout's JSON one after another, and of only those where another house was
## lower than the parlour (435 of the 500). Never re-recorded.
##
## 25 Nov: the text hashed changed once, from full-precision JSON to the rounded text of _text() below, because the
## full-precision text differs between Windows and Linux in the last bits of a float and CI (Linux) failed on it. The
## layouts were not re-recorded: at 1f45ac3 the full-precision digests (4dd33228..., e0bdc0f0..., e8e0f9cb...) still
## matched on Windows, so flag off was still the Ward of 6d03c6b, and these are the rounded digests of those same layouts.
const ALL_BEFORE := "aa6a7be0d4c3468d6161bd0b98b06369b59e310fe99447517b37814689285145"
const KEPT_BEFORE := "41178bc43d8935cf7a39a5d3a0ffc955454ed69b21e1e44076a140a4bc656b1a"
const KEPT_COUNT := 435
const LATE2_BEFORE := "85e4dbc02d3dc4cc039273ecd7832c20afe15edbbc68a836286993c03fcae9c8"

## A layout as text for the recorded digests: floats rounded as tests/ward_digest.gd rounds them, so the same layout gives
## the same text on Windows and on Linux (their maths libraries differ in the last bits of a float; CI is Linux).
static func _text(l: Dictionary) -> String:
	return JSON.stringify(Digest._plain(l))

static func _off() -> Dictionary:
	return Layout.options(null)

static func _on() -> Dictionary:
	return Layout.options(null, true)

static func _seed(k: int) -> int:
	return ("run-%d" % k).hash()

## The lowest of the houses other than the lift's, less the lift's (negative: another house is lower).
static func _gap(l: Dictionary) -> float:
	var lo := INF
	for i: int in range(1, (l.houses as Array).size()):
		lo = minf(lo, float(l.houses[i].z))
	return lo - float(l.houses[0].z)

## The first `n` seeds "run-<k>" whose Ward the flag changes (late-2 first).
static func changed_seeds(n: int) -> Array[int]:
	var out: Array[int] = ["late-2".hash()]
	var k := 0
	while out.size() < n and k < 2000:
		var s := _seed(k)
		k += 1
		if _gap(Layout.generate(s, _off())) >= 0.0 and not out.has(s):
			out.append(s)
	return out

# ------------------------------------------------------------------------------------------------
# 1. Flag off.

func test_flag_off_is_the_recorded_ward(t: T) -> void:
	var all := ""
	for k in 500:
		all += _text(Layout.generate(_seed(k), _off()))
	t.eq(all.sha256_text(), ALL_BEFORE, "500 seeds, flag off: every generated layout as recorded before RL1")
	t.eq(_text(Layout.generate("late-2".hash(), _off())).sha256_text(), LATE2_BEFORE, "late-2, flag off: as recorded")
	t.eq(Layout.options(null, false), _off(), "options without the flag are the options they were")
	t.check(not _off().has("lift_clear"), "no lift_clear key without the flag")
	t.eq(Layout.to_wire(_off()), [2, 110, 150], "the wire without the flag: the three fields it always was")
	t.check(not HostRules.new(true, 1).ward_lift_clear, "the run flag is off by default")

# ------------------------------------------------------------------------------------------------
# 2. Never the lowest.

func test_the_lift_is_never_the_lowest_house(t: T) -> void:
	var lowest: Array[String] = []
	var changed := 0
	var changed_200 := 0
	var biggest := 0.0
	var smallest := INF
	for k in 500:
		var s := _seed(k)
		var off := Layout.generate(s, _off())
		var on := Layout.generate(s, _on())
		if _gap(on) >= 0.0:
			lowest.append("run-%d" % k)
		if JSON.stringify(on) != JSON.stringify(off):
			changed += 1
			changed_200 += 1 if k < 200 else 0
			smallest = minf(smallest, -_gap(on))
			for i: int in (on.houses as Array).size():
				biggest = maxf(biggest, absf(float(on.houses[i].z) - float(off.houses[i].z)))
	t.check(lowest.is_empty(), "500 seeds, flag on: another house is always lower than the lift's: %s" % str(lowest.slice(0, 8)))
	t.check(changed >= 20, "the flag changes at least 20 of 500 seeds (%d)" % changed)
	t.check(smallest > 0.1, "on every changed seed the lowest house is more than 0.1 m below the lift's (%.3f m)" % smallest)
	t.note("flag on: %d of 200 and %d of 500 seeds change; the largest height change %.3f m; the smallest gap below the lift's house on a changed seed %.3f m" % [changed_200, changed, biggest, smallest])
	# His lair, as the Ward and his graph each work it out, is under another house.
	var under: Array[String] = []
	for s: int in changed_seeds(6 if t.quick else 20):
		var w := Ward.new(s, _on())
		if w.lair == 0:
			under.append("%d" % s)
	t.check(under.is_empty(), "the changed seeds: the Ward's lair is never under the lift's house: %s" % str(under))

# ------------------------------------------------------------------------------------------------
# 3. Unchanged seeds.

func test_seeds_with_a_lower_house_are_unchanged(t: T) -> void:
	var kept := ""
	var n := 0
	var differ: Array[String] = []
	for k in 500:
		var s := _seed(k)
		var off := Layout.generate(s, _off())
		if _gap(off) >= 0.0:
			continue
		var text := _text(Layout.generate(s, _on()))
		kept += text
		n += 1
		if text != _text(off):
			differ.append("run-%d" % k)
	t.eq(n, KEPT_COUNT, "435 of the 500 seeds already have a house lower than the lift's")
	t.check(differ.is_empty(), "flag on, each of them: the same layout as with it off: %s" % str(differ.slice(0, 8)))
	t.eq(kept.sha256_text(), KEPT_BEFORE, "flag on, all of them together: as recorded before RL1")
	# The whole Ward (houses, fixtures, walk grid), not only the layout, for a few of them.
	var whole := 0
	for k in 40:
		if whole >= (3 if t.quick else 12):
			break
		var s := _seed(k)
		if _gap(Layout.generate(s, _off())) >= 0.0:
			continue
		whole += 1
		t.eq(Digest.line(s, _on()), Digest.line(s, _off()), "run-%d: the whole Ward the same with the flag on" % k)

# ------------------------------------------------------------------------------------------------
# 4. The changed seeds keep the Ward's properties.

func test_changed_seeds_keep_the_wards_properties(t: T) -> void:
	var seeds := changed_seeds(20)
	t.eq(seeds.size(), 20, "20 changed seeds, late-2 the first")
	t.eq(seeds[0], 183025962, "late-2 hashes to 183025962")
	var bad: Array[String] = []
	var steep: Array[String] = []
	var lair_bad: Array[String] = []
	var unjoined: Array[String] = []
	var unsafe: Array[String] = []
	for s: int in seeds:
		var w := Ward.new(s, _on())
		for lowered: bool in [false, true]:
			w.bridge_lowered = lowered
			w.phase = &"boarding"
			var g: Dictionary = WardLayoutProps.walk_graph(w)
			if not g.faults.is_empty() or not WardLayoutProps._joined(8, g.edges):
				bad.append("%d bridge %s: %s" % [s, "down" if lowered else "up", ", ".join(g.faults)])
		for e: Dictionary in w.layout.bridges:
			for k: int in range(1, (e.path as Array).size()):
				var p: Array = e.path[k - 1]
				var q: Array = e.path[k]
				var run := Vector2(p[0], p[1]).distance_to(Vector2(q[0], q[1]))
				if absf(float(p[2]) - float(q[2])) > Layout.SLOPE * run + 1e-4:
					steep.append("%d walkway %d-%d" % [s, e.a, e.b])
		var graph := Roam.graph_for(w)
		if graph.lair < 0 or graph.house_of[graph.lair] == 0 or w.lair == 0:
			lair_bad.append("%d (graph lair house %d, Ward lair %d)" % [s, graph.house_of[graph.lair] if graph.lair >= 0 else -1, w.lair])
		for h in w.houses.size():
			if graph.openings_of(h).is_empty():
				unjoined.append("%d house %d" % [s, h])
			var fixture := w.houses[h]
			for o: Dictionary in fixture.openings():
				if fixture.reachable_areas(o).size() >= fixture.probes_for(o).size():
					unsafe.append("%d house %d %s %d" % [s, h, o.kind, int(o.side)])
	t.check(bad.is_empty(), "20 changed seeds, bridge up and down: every house walks to every other and the lift: %s" % "; ".join(bad.slice(0, 4)))
	t.check(steep.is_empty(), "20 changed seeds: no walkway steeper than %.2f: %s" % [Layout.SLOPE, str(steep.slice(0, 4))])
	t.check(lair_bad.is_empty(), "20 changed seeds: his lair (the Ward's and his graph's) is under a house that is not the lift's: %s" % str(lair_bad))
	t.check(unjoined.is_empty(), "20 changed seeds: every house has an opening he can reach from his lair: %s" % str(unjoined.slice(0, 6)))
	t.check(unsafe.is_empty(), "20 changed seeds: from every opening at least one room is out of the arm's reach: %s" % str(unsafe.slice(0, 6)))

## The flag must strand no spot: for each changed seed, bridge up and down, prop_ward_reach's stranded spots with the
## flag on are no more than with it off. The quick set: late-2 and 273673180; the default run: every changed seed of
## the 500.
## 25 Nov (WH1): this test used to expect spots already stranded with the flag off on 273673180 ("run-5", bridge up)
## and noted 1677347106 ("run-173", bridge down). Those were prop_ward_reach's own fault (its half-metre grid missed
## a 0.3 m way out beside a stair; the game's way-finder walks home from them), so the named seed now expects none,
## with the flag and without.
const STRANDED_BEFORE := 273673180

func test_the_flag_adds_no_stranded_spot(t: T) -> void:
	var seeds: Array[int] = [183025962, STRANDED_BEFORE]
	if not t.quick:
		for k in 500:
			var s := _seed(k)
			if _gap(Layout.generate(s, _off())) >= 0.0 and not seeds.has(s):
				seeds.append(s)
	var added: Array[String] = []
	var already: Array[String] = []
	var named_off := 0
	var named_on := 0
	for s: int in seeds:
		for lowered: bool in [true, false]:
			var on := Reach.stranded(s, lowered, true, false, _on()).size()
			var off := Reach.stranded(s, lowered, true, false, _off()).size() if on > 0 or s == STRANDED_BEFORE else 0
			if on > off:
				added.append("%d bridge %s: %d with the flag, %d without" % [s, "down" if lowered else "up", on, off])
			if off > 0:
				already.append("%d bridge %s: %d" % [s, "down" if lowered else "up", off])
			if s == STRANDED_BEFORE and not lowered:
				named_off = off
				named_on = on
	t.check(added.is_empty(), "%d changed seeds, bridge up and down: the flag strands no spot that was not stranded without it: %s" % [seeds.size(), "; ".join(added)])
	t.check(named_off == 0 and named_on == 0, "273673180, bridge up: no spot is stranded, with the flag or without (%d off, %d on)" % [named_off, named_on])
	t.check(already.is_empty(), "no spot is stranded with the flag off: %s" % "; ".join(already))

# ------------------------------------------------------------------------------------------------
# 5. Walking out of the car on late-2.

## A lone player walks (not creeps) out of the car 2.6 m into the lift's house and stands still. The events of the
## first `seconds` after the car leaves, and whether he started towards the lift's house.
static func walk_out(options: Dictionary, seconds: float) -> Dictionary:
	var w := Ward.new("late-2".hash(), options)
	w.crew_size = 1
	w.enable_roam()
	w.called = true
	w.web = true
	var door := w.lift_door()
	var feet := door + Vector3(-0.28, 0.02, -0.55)
	var goal := door + Vector3(-0.6, 0.0, 2.6)
	var now := 0.0
	var dt := 0.05
	var left_at := -1.0
	var heard: Array[String] = []
	var toward_lift := false
	while now < 60.0:
		now += dt
		var to := Vector2(goal.x - feet.x, goal.z - feet.z)
		if to.length() > 0.02:
			feet = w.walk(feet, to.limit_length(3.0 * dt))
		var row := {"position": feet, "aboard": w.in_lift(feet), "active": not w.caught.has("p0"), "sprint": false, "creep": false}
		if w.phase == &"unloading" and not row.aboard and w.clear_of_lift(feet):
			w.phase = &"away"
			left_at = now
		var events := w.step(now, dt, 30.0, {"p0": row})
		for e: Dictionary in events:
			if e.kind == "line_loaded" or e.kind == "weight":
				heard.append("%s house %d at +%.2f" % [e.kind, int(e.get("house", -1)), now - left_at])
				toward_lift = toward_lift or int(e.get("house", -1)) == 0
		if left_at >= 0.0 and now - left_at >= seconds:
			break
	return {"heard": heard, "toward_lift": toward_lift, "encounter": str(w.encounter), "left": left_at >= 0.0, "caught": w.caught.has("p0")}

func test_walking_out_of_the_car_on_late_2(t: T) -> void:
	var off := walk_out(_off(), 3.0)
	t.check(off.left, "flag off: the car leaves once the player is out")
	t.check(not (off.heard as Array).is_empty() and off.toward_lift, "flag off: walking out is heard at once, his line loads for the lift's house (%s)" % str(off.heard))
	var on := walk_out(_on(), 15.0)
	t.check(on.left, "flag on: the car leaves once the player is out")
	t.check((on.heard as Array).is_empty(), "flag on: 15 s standing where the walk out ended, nothing loads a line (%s)" % str(on.heard))
	t.check(not on.caught and on.encounter == "idle", "flag on: not caught, the Rigger still idle (%s)" % on.encounter)

# ------------------------------------------------------------------------------------------------
# 6. The wire and the rooms.

func test_the_wire_and_the_rooms(t: T) -> void:
	var w := Ward.new(183025962, _on())
	var block := w.snapshot()
	block["layout"] = w.layout_wire()
	t.eq(block.layout, [2, 110, 150, 1], "flag on: the block carries a fourth option, 1")
	var back := WardWire.decode(JSON.parse_string(JSON.stringify(WardWire.encode(block))))
	t.eq(back.get("layout"), [2, 110, 150, 1], "it comes back through JSON")
	t.eq(Layout.from_wire(back.layout), _on(), "and is the host's options")
	t.eq(Digest.line(183025962, Layout.from_wire(back.layout)), Digest.line(183025962, _on()), "a screen builds the host's Ward")
	t.check(Digest.line(183025962, _on()) != Digest.line(183025962, _off()), "late-2's Ward differs with the flag")
	# WH1 (merged after RL1) put its homes in a fifth option, so a fifth is refused unless it is 1 and the fourth 0 or 1.
	for wrong: Array in [[2, 110, 150, 0], [2, 110, 150, 2], [2, 110, 150, 1, 0], [2, 110, 150, 2, 1], [2, 110, 150, 1, 1, 1]]:
		var raw := WardWire.encode(block)
		raw[14] = wrong
		t.eq(WardWire.decode(raw), {}, "a block with options %s is refused" % str(wrong))
	t.eq(Layout.from_wire([2, 110, 150, 0]), {}, "from_wire refuses a fourth option that is not 1")
	# The flag by position: after voice_, followed only by WH1's ward_homes_ (the agreed tail); only with ward_layout
	# and the late floors.
	var names: Array[String] = []
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if m["name"] == "_init":
			for a: Dictionary in m["args"]:
				names.append(str(a["name"]))
	t.eq(names.slice(names.size() - 3), ["voice_", "ward_lift_clear_", "ward_homes_"] as Array[String], "ward_lift_clear_ comes after voice_, then only WH1's ward_homes_")
	var args: Array = WardLayoutProps.rules_args(true, true)
	t.eq(names[args.size() - 1], "ward_layout_", "rules_args gives every parameter up to ward_layout_")
	while args.size() < names.size():
		args.append(false)
	args[names.find("ward_lift_clear_")] = true
	t.check((HostRules.new.callv(args) as HostRules).ward_lift_clear, "on with the late floors and the layout")
	args[49] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_lift_clear, "never without the layout")
	args[49] = true
	args[38] = false
	t.check(not (HostRules.new.callv(args) as HostRules).ward_lift_clear, "never without the late floors")
	t.check(HostRules.ward_lift_clear_by_arg(), "no ward_lift_clear=0 on this command line: the rooms ask for it")
	var room := FileAccess.get_file_as_string("res://server/room.gd")
	t.check(room.contains("ward_layout and late_floors and not (ward_review or reactor_review or orientation_review) and HostRules.ward_lift_clear_by_arg(),"), "server/room.gd passes it, with the layout (WH1's ward_homes_ follows it)")
	var local := FileAccess.get_file_as_string("res://net/local_room.gd")
	t.check(local.contains("late_floors_on() and not _orientation_playtest and ward_layout and HostRules.ward_lift_clear_by_arg(),"), "net/local_room.gd passes it, with the layout (WH1's ward_homes_ follows it)")
	var host := FileAccess.get_file_as_string("res://net/host.gd")
	t.check(host.contains("WardLayout.options(state.tuning, ward_lift_clear())") and host.contains("WardLayout.options(state.tuning if state != null else null, ward_lift_clear())"), "net/host.gd builds both of its Wards with it")
