# WG1: more of the Hanging Ward comes from the floor seed (sim/ward/layout.gd generate_v2, behind the run flag
# `ward_layout`, net/host_rules.gd). The design (docs/floors/hanging-ward.md): "Exactly eight homes are laid out from
# the floor seed. The lift opens into the parlour cottage. Permanent walkways connect all eight homes in both
# directions. A powered drawbridge cuts across one loop. Either end can work the winch." And the rule: "Everything
# about a floor comes from one seed, identical for every player." Checked here:
#   1. flag off: today's Ward for every seed (digests recorded from the code before WG1);
#   2. one seed, one Ward: built twice here and in fresh processes;
#   3. different seeds differ (arrangements, shapes, loops, facings, heights, where the bridge and the lift's house sit);
#   4. eight houses, the parlour the lift's house, the bridge on a loop with a winch at either end;
#   5. every house reachable from every other through the walk model, bridge raised and lowered;
#   6. nothing intersects (houses and galleries, walkways, the lift's car) and every walkway is walkable;
#   7. the route helper (client/ward/route.gd) finds the way from every house to the lift within its search caps;
#   8. the options on the wire and the run flag (off by default, the host's block, a screen's Ward).
extends RefCounted

const T = preload("res://tests/t.gd")
const Ward = preload("res://sim/ward/state.gd")
const Layout = preload("res://sim/ward/layout.gd")
const House = preload("res://sim/ward/house.gd")
const Footing = preload("res://sim/ward/footing.gd")
const Digest = preload("res://tests/ward_digest.gd")
const Reach = preload("res://tests/prop_ward_reach.gd")
const Route = preload("res://client/ward/route.gd")
const WardWire = preload("res://net/ward_wire.gd")
const HostRules = preload("res://net/host_rules.gd")

## Recorded from commit 87bcd82 (before WG1) by `godot --headless --path godot --script res://tests/ward_digest.gd --
## <seeds>`: seeds i * 2654435761 mod 2^32 for i in 0..39. Never re-recorded: with the flag off the Ward is today's.
const TODAY := [
	"WARD 0 4df912f0ef54e384 71f83242 1c202214 65f6099a 909e1415",
	"WARD 2654435761 b742e59863129423 373d9b34 2dc49f89 68b5bf6d 5f319bf1",
	"WARD 1013904226 b787de0a6f9e60d1 05e56599 dd0c6761 6b94cd73 15efc9f8",
	"WARD 3668339987 e5b977438fcb0ce7 fcbd465a decb4a24 2c6debfb a9e6ef96",
	"WARD 2027808452 d383fa701426a3fd 05da9b92 59b616ad 8cbe7825 f9d28df8",
	"WARD 387276917 781c137aa09f9421 fb2593a9 e04937bf e3ed297e 7003c69d",
	"WARD 3041712678 b878a81723ae5202 7acf6bea ab101e15 f9512e59 3f8227c3",
	"WARD 1401181143 2eb2ea66391425ec bb23c13e ebe31467 10b63b02 3dfda38d",
	"WARD 4055616904 d07551453f695146 1b3a59a3 3a381702 074d82a2 edae4525",
	"WARD 2415085369 d6324765230ee13b 18ff6d22 ec6a1ec3 c0df65d5 8e76cd2a",
	"WARD 774553834 b2b7d5b0f475a9ea 7888f94b 99b4e856 3b70979b 64d5e206",
	"WARD 3428989595 0026f76e67c2c3d7 4accabb8 9299f893 10d2e88b 67e4ed82",
	"WARD 1788458060 c43b4b8db1ceb80a 09e4741e 80fc6ce6 41986a32 d27c413c",
	"WARD 147926525 e3bb16d8a4e4d3c7 fabb7416 ad9f2410 dc9a308f 1c6e7109",
	"WARD 2802362286 3717214d3b937151 1c2d8e62 1a444652 d1c06818 b8a958db",
	"WARD 1161830751 5a93b2d33db804bc 2a6f20a5 ebf21021 b3702acc 7f9ecaa9",
	"WARD 3816266512 d2378e796f11be22 2ec979ea 8d693281 6f455987 c52ded7e",
	"WARD 2175734977 d9a42f4d01028c56 2d021b95 a1e30771 3afd9472 5d52ec12",
	"WARD 535203442 78ca2a8e47064032 ef223534 f7b321c4 e9b0cbfb 82326ac1",
	"WARD 3189639203 307a356d51ded5ec 7b24ed20 cf01e3a4 47a3ad52 b18060bd",
	"WARD 1549107668 259d7887a4ae81d2 0805f917 3077e166 2b311bb1 a5d1e4b6",
	"WARD 4203543429 aa4cc5b50cea4c19 c49e97a5 1fa0ef48 e8f887f4 0798bf7c",
	"WARD 2563011894 08b2f9cec31c37d6 47fdffdd 79288d1a f30f2a86 08c377ab",
	"WARD 922480359 13e769ac4a9bffa6 d27281b3 d37e400f 6d155c9e ebc595bb",
	"WARD 3576916120 041cd83ba9720a20 5b3436ac 76e3fc7c 6b27be4d a0d359af",
	"WARD 1936384585 bc3fdce677db40de 817cb22d 2b2dac65 699e6a4f 5ef76ae2",
	"WARD 295853050 93304668012a9218 95701585 e9167005 b3530e36 5a9fa9c4",
	"WARD 2950288811 72deb224876ee073 51ea9787 fa18fe36 8374d907 062e8071",
	"WARD 1309757276 f2696a680c32e535 51afcb03 faa04ad4 99bd7d01 f6740192",
	"WARD 3964193037 fb594570d410cdbd fc1b6272 c038122f d128f51a bbf97429",
	"WARD 2323661502 947e5e3b38a75d82 2659ef25 36fc5a8f 321c26ca 92c53eaa",
	"WARD 683129967 a39d3d03c9587434 c0dd281d ea209136 f9ee771f f5f483d4",
	"WARD 3337565728 aaf232ad16df0be0 e7918d21 9a03c21a 7437d1f4 e96f492c",
	"WARD 1697034193 741b66dbe38798ac 413d5293 2c30f1ab 9b471876 a2819f46",
	"WARD 56502658 7f2a72bfef4f2ad9 fe1bf722 1f8ce387 6426322d dc99f5bc",
	"WARD 2710938419 89fb5bacd27d7857 3e65ee27 e5e8d47d 987d6505 daaee4aa",
	"WARD 1070406884 680792cdf86a8efb 2d535ff2 50f45d5f bf5a80cf c393be56",
	"WARD 3724842645 09da1e6be57c0b2e 915217dd 96c9c721 d8b854b5 cb76bcc5",
	"WARD 2084311110 ce9e14656dfd7424 956fc0bb 60e92203 dd78baf8 7df5e2f5",
	"WARD 443779575 83eaf07b07090bea 338b0ae1 fdc149bb 4e263f94 58fdd16a",
]

static func _opts() -> Dictionary:
	return Layout.options(null)

static func _ward(seed_value: int) -> Ward:
	return Ward.new(seed_value, _opts())

static func _seeds(n: int, salt := 0) -> Array[int]:
	var out: Array[int] = []
	for i in n:
		out.append((i * 2246822519 + salt * 97 + 11) % 4294967296)
	return out

# ------------------------------------------------------------------------------------------------
# 1. Flag off.

func test_flag_off_is_todays_ward(t: T) -> void:
	var lines: Array = TODAY
	var n := 6 if t.quick else lines.size()
	for i in n:
		var want: String = lines[i]
		var s := int(want.split(" ")[1])
		t.eq(Digest.line(s), want, "seed %d: today's Ward (layout, houses, fixtures, walk grid)" % s)
		t.eq(Digest.line(s, {}), want, "seed %d: empty options are today's" % s)
	t.check(not HostRules.new(true, 1).ward_layout, "the run flag ward_layout is off by default")
	t.check(not (HostRules.new.callv(rules_args(true, false)) as HostRules).ward_layout, "off with the late floors when not asked")
	t.eq(Ward.new(8143).layout_wire(), [], "today's Ward gives its block no layout field")
	t.note("%d recorded seeds: today's Ward with the flag off" % n)

# ------------------------------------------------------------------------------------------------
# 2. One seed, one Ward.

func test_one_seed_one_ward(t: T) -> void:
	var seeds := _seeds(3 if t.quick else 20)
	var mine := {}
	for s in seeds:
		mine[s] = Digest.line(s, _opts())
		t.eq(Digest.line(s, _opts()), mine[s], "seed %d: built twice here, the same generated Ward" % s)
		t.check(JSON.stringify(Layout.generate(s, _opts())) == JSON.stringify(Layout.generate(s, _opts())), "seed %d: the layout data twice" % s)
	var args: Array[String] = ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/ward_digest.gd", "--", "--layout=2"]
	for s in seeds:
		args.append(str(s))
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	if not t.check(code == 0, "a fresh process ran the digest (exit %d)" % code):
		return
	var lines := {}
	for chunk: String in out:
		for l: String in chunk.split("\n"):
			if l.begins_with("WARD "):
				lines[int(l.split(" ")[1])] = l.strip_edges()
	for s in seeds:
		t.eq(lines.get(s, "missing"), mine[s], "seed %d: a fresh process builds the same generated Ward" % s)

# ------------------------------------------------------------------------------------------------
# 3. Seeds differ.

## The shape of a set of cells, moved to start at (0, 0).
static func _shape(cells: Array) -> String:
	var lo := Vector2i(99, 99)
	for c: Array in cells:
		lo = Vector2i(mini(lo.x, int(c[0])), mini(lo.y, int(c[1])))
	var keys: Array[String] = []
	for c: Array in cells:
		keys.append("%d,%d" % [int(c[0]) - lo.x, int(c[1]) - lo.y])
	keys.sort()
	return ";".join(keys)

func test_seeds_differ(t: T) -> void:
	var seeds := _seeds(100)
	var arrangements := {}
	var shapes := {}
	var loops := {}
	var loop_sizes := {}
	var parlour_spots := {}
	var bridge_spots := {}
	var facings := {}
	var styled := {}
	var spreads: Array[float] = []
	var sloped := 0
	for s in seeds:
		var l := Layout.generate(s, _opts())
		var cells: Array = []
		var arrangement := ""
		for h: Dictionary in l.houses:
			cells.append(h.cell)
			arrangement += "%s@%d,%d/%d " % [h.style, int(h.cell[0]) - int(l.houses[0].cell[0]), int(h.cell[1]) - int(l.houses[0].cell[1]), int(h.facing)]
			facings[int(h.facing)] = true
			styled["%s %d %s" % [h.style, int(h.facing), str(h.mirror)]] = true
		arrangements[arrangement] = true
		shapes[_shape(cells)] = true
		var ring: Array = []
		for id: int in l.loop:
			ring.append(l.houses[id].cell)
		loops[_shape(ring)] = true
		loop_sizes[l.loop.size()] = true
		# Where the parlour sits in the shape: its neighbours on the lattice, by side.
		var p: Array = l.houses[0].cell
		var around := ""
		for d: Vector2i in Layout.DIRS:
			var has := false
			for c: Array in cells:
				has = has or (int(c[0]) == int(p[0]) + d.x and int(c[1]) == int(p[1]) + d.y)
			around += "1" if has else "0"
		parlour_spots[around] = true
		for e: Dictionary in l.bridges:
			if e.kind == "winch":
				bridge_spots["%s-%s" % [l.houses[e.a].style, l.houses[e.b].style]] = true
		var lo := INF
		var hi := -INF
		for h: Dictionary in l.houses:
			lo = minf(lo, float(h.z))
			hi = maxf(hi, float(h.z))
		spreads.append(hi - lo)
		for e: Dictionary in l.bridges:
			if absf(float(e.path[0][2]) - float(e.path[-1][2])) >= 0.5:
				sloped += 1
				break
	spreads.sort()
	var median := spreads[spreads.size() / 2]
	t.check(arrangements.size() >= 95, "at least 95 different arrangements of styles, cells and facings in 100 seeds (%d)" % arrangements.size())
	t.check(shapes.size() >= 30, "at least 30 different shapes of the eight cells (%d)" % shapes.size())
	t.check(loops.size() >= 3 and loop_sizes.size() >= 2, "the bridge's loop: at least 3 shapes and 2 sizes (%d shapes, sizes %s)" % [loops.size(), str(loop_sizes.keys())])
	t.check(parlour_spots.size() >= 5, "the lift's cottage sits in at least 5 different places in the shape (%d)" % parlour_spots.size())
	t.check(bridge_spots.size() >= 20, "the bridge between at least 20 different pairs of houses (%d)" % bridge_spots.size())
	t.check(facings.size() == 4, "all four facings used (%s)" % str(facings.keys()))
	var every := true
	for st: Array in Layout.STYLES:
		var turned := 0
		var mirrored := false
		var plain := false
		for f in 4:
			for m: bool in [false, true]:
				if styled.has("%s %d %s" % [st[0], f, str(m)]):
					turned += 1 if not m else 0
					mirrored = mirrored or m
					plain = plain or not m
		every = every and turned >= 2 and mirrored and plain
	t.check(every, "every style is seen turned at least two ways, and mirrored and not")
	t.check(median >= 1.0, "real height differences: the median gap from the lowest house to the highest is %.2f m (at least 1)" % median)
	t.check(sloped >= 70, "in at least 70 of 100 seeds a walkway climbs half a metre or more (%d)" % sloped)
	t.note("100 seeds: %d arrangements, %d shapes, %d loop shapes (sizes %s), %d parlour places, %d bridge pairs, median height range %.2f m, %d with a 0.5 m climb" % [
		arrangements.size(), shapes.size(), loops.size(), str(loop_sizes.keys()), parlour_spots.size(), bridge_spots.size(), median, sloped])

# ------------------------------------------------------------------------------------------------
# 4. The design's fixed points.

func test_eight_houses_the_parlour_and_one_bridge_on_a_loop(t: T) -> void:
	var bad: Array[String] = []
	for s in _seeds(100):
		var w := _ward(s)
		var l := w.layout
		if l.houses.size() != 8:
			bad.append("%d: %d houses" % [s, l.houses.size()])
		var styles := {}
		for h: Dictionary in l.houses:
			styles[h.style] = true
		if styles.size() != 8 or l.houses[0].style != "parlour_cottage":
			bad.append("%d: styles %s" % [s, str(styles.keys())])
		# The lift opens into the parlour: the car's mouth is in its entry room's walls, the car outside them.
		var door := w.lift_door()
		var parlour := w.houses[0]
		if parlour.area_at(parlour.to_local(door + Vector3(0, 1.25, 0.5))) == &"" or not w.in_lift(door + Vector3(0, 0, -1.0)):
			bad.append("%d: the lift does not open into the parlour" % s)
		var winches := 0
		var fixed: Array[Dictionary] = []
		for e: Dictionary in l.bridges:
			if e.kind == "winch":
				winches += 1
			else:
				fixed.append(e)
		if winches != 1 or w.switches.size() != 2:
			bad.append("%d: %d winch bridges, %d switches" % [s, winches, w.switches.size()])
			continue
		var winch: Dictionary = l.bridges.filter(func(e: Dictionary) -> bool: return e.kind == "winch")[0]
		if not (w.switches[0].house == winch.a and w.switches[1].house == winch.b):
			bad.append("%d: the switches are not at the bridge's two ends" % s)
		# Fixed walkways alone join all eight (raising the bridge strands nobody), and the bridge is on a loop: its
		# two ends are joined without it.
		if not _joined(8, fixed):
			bad.append("%d: the fixed walkways do not join every house" % s)
		if (l.loop as Array).size() < 4 or int(l.loop[0]) != int(winch.a) or int(l.loop[-1]) != int(winch.b):
			bad.append("%d: loop %s" % [s, str(l.loop)])
	t.check(bad.is_empty(), "100 seeds: eight houses, all styles once, the lift into the parlour, one bridge with a winch at each end on a loop: %s" % "; ".join(bad.slice(0, 5)))

static func _joined(count: int, edges: Array[Dictionary]) -> bool:
	var seen := {0: true}
	var todo: Array[int] = [0]
	while not todo.is_empty():
		var at: int = todo.pop_back()
		for e: Dictionary in edges:
			for pair: Array in [[e.a, e.b], [e.b, e.a]]:
				if int(pair[0]) == at and not seen.has(int(pair[1])):
					seen[int(pair[1])] = true
					todo.append(int(pair[1]))
	return seen.size() == count

# ------------------------------------------------------------------------------------------------
# 5. Reachable through the walk model.

## Walk from `from` towards `to` (flat) by the Ward's own walk model in short pushes; the feet reached.
static func walk_to(w: Ward, from: Vector3, to: Vector3) -> Vector3:
	var at := from
	for i in 400:
		var left := Vector2(to.x - at.x, to.z - at.z)
		if left.length() < 0.03:
			break
		var next := w.walk(at, left.limit_length(0.25))
		if next.is_equal_approx(at):
			break
		at = next
	return at

static func _reached(at: Vector3, to: Vector3) -> bool:
	return Vector2(at.x - to.x, at.z - to.z).length() < 0.08

## The middle of a house's gallery on one side (where bots.gd's ring stands) and its dock (the walkway's end).
static func _gallery_mid(site: Dictionary, side: String, out := 0.8) -> Vector3:
	var x := float(site.x)
	var z := float(site.y)
	match side:
		"east": x += float(site.w) * 0.5 + out
		"west": x -= float(site.w) * 0.5 + out
		"north": z += float(site.d) * 0.5 + out
		"south": z -= float(site.d) * 0.5 + out
	return Vector3(x, float(site.z) + 0.15, z)

## The gallery's corners and side middles in order round the house.
static func _ring(site: Dictionary) -> Array[Vector3]:
	var hw := float(site.w) * 0.5 + 0.8
	var hd := float(site.d) * 0.5 + 0.8
	var out: Array[Vector3] = []
	for k: Vector2 in [Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Vector2(-1, 1), Vector2(-1, 0)]:
		out.append(Vector3(float(site.x) + k.x * hw, float(site.z) + 0.15, float(site.y) + k.y * hd))
	return out

## A walk through waypoints; true when every one is reached.
static func _walk_path(w: Ward, points: Array[Vector3]) -> bool:
	var at := points[0]
	for i in range(1, points.size()):
		at = walk_to(w, at, points[i])
		if not _reached(at, points[i]):
			return false
	return true

## From a house's entry room out of its front door to the gallery's ring (index of the ring point nearest the door).
static func _out_of_door(w: Ward, id: int) -> Array:
	var h := w.houses[id]
	var a: Vector3 = h.areas[&"entry"]
	var room := h.to_world(Vector3(a.x, 0, a.z))
	var inside := h.to_world(Vector3(0, 0, 0.35))
	var outside := h.to_world(Vector3(0, 0, -0.75))
	outside.y = float(w.layout.houses[id].z) + 0.15
	var ring := _ring(w.layout.houses[id])
	var best := 0
	for k in ring.size():
		if ring[k].distance_to(outside) < ring[best].distance_to(outside):
			best = k
	return [[room, inside, outside, ring[best]] as Array[Vector3], best]

## From the door's ring point round the gallery (either way) to a side's middle; true if a way walks.
static func _round_gallery(w: Ward, id: int, from_k: int, side: String) -> bool:
	var ring := _ring(w.layout.houses[id])
	var to_k: int = {"south": 1, "east": 3, "north": 5, "west": 7}[side]
	for step: int in [1, -1]:
		var points: Array[Vector3] = [ring[from_k]]
		var k := from_k
		while k != to_k:
			k = posmod(k + step, 8)
			points.append(ring[k])
		if _walk_path(w, points):
			return true
	return false

## Which houses the walk model joins: the lift to the parlour's entry, every walkway end to end, and each house's
## door round its gallery to each walkway's end; walked both ways.
static func walk_graph(w: Ward) -> Dictionary:
	var faults: Array[String] = []
	var doors := []
	for id in w.houses.size():
		var out: Array = _out_of_door(w, id)
		var points: Array[Vector3] = out[0]
		var back := points.duplicate()
		back.reverse()
		if not _walk_path(w, points) or not _walk_path(w, back):
			faults.append("house %d: not out of its door and back" % id)
		doors.append(out[1])
	var car := w.lift_door() + Vector3(0, 0, -1.0)
	car.y = w.footing.walking_height(Vector2(car.x, car.z), w.lift_door().y, w.bridge_lowered)
	# Out of the car into the parlour's room it opens on, then room by room to the entry room.
	var p := w.houses[0]
	var mouth := w.lift_door() + Vector3(0, 0, 0.6)
	var room := p.area_at(p.to_local(mouth + Vector3.UP * 1.25))
	var inward: Array[Vector3] = [car, mouth]
	var order := [&"rear", &"middle", &"entry"]
	for k in range(order.find(room), order.size()):
		var at: Vector3 = p.areas[order[k]]
		inward.append(p.to_world(Vector3(at.x, 0, at.z)))
		if k < 2:
			var opening: Vector3 = p.room_doors[1 - k]
			inward.append(p.to_world(Vector3(opening.x, 0, opening.z)))
	var outward := inward.duplicate()
	outward.reverse()
	var lift_ok := room != &"" and _walk_path(w, inward) and _walk_path(w, outward)
	if not lift_ok:
		faults.append("the lift and the parlour")
	var edges: Array[Dictionary] = []
	for e: Dictionary in w.layout.bridges:
		if e.kind == "winch" and not w.bridge_lowered:
			continue
		var sa: Dictionary = w.layout.houses[e.a]
		var sb: Dictionary = w.layout.houses[e.b]
		var points: Array[Vector3] = [_gallery_mid(sa, e.a_side)]
		for raw: Array in e.path:
			points.append(Footing.path_point(raw))
		points.append(_gallery_mid(sb, e.b_side))
		var back := points.duplicate()
		back.reverse()
		var ok := _walk_path(w, points) and _walk_path(w, back) \
			and _round_gallery(w, e.a, doors[e.a], e.a_side) and _round_gallery(w, e.b, doors[e.b], e.b_side)
		if ok:
			edges.append(e)
		else:
			faults.append("walkway %d-%d (%s)" % [e.a, e.b, e.kind])
	return {"edges": edges, "faults": faults, "lift": lift_ok}

func test_every_house_reachable_raised_and_lowered(t: T) -> void:
	var n := 8 if t.quick else 100
	var bad: Array[String] = []
	for s in _seeds(n, 1):
		var w := _ward(s)
		w.phase = &"boarding"
		for lowered: bool in [false, true]:
			w.bridge_lowered = lowered
			var g := walk_graph(w)
			if not g.faults.is_empty() or not _joined(8, g.edges):
				bad.append("%d bridge %s: %s" % [s, "down" if lowered else "up", ", ".join(g.faults)])
	t.check(bad.is_empty(), "%d seeds, bridge raised and lowered: every house walks to every other and the lift: %s" % [n, "; ".join(bad.slice(0, 4))])

func test_no_spot_is_stranded(t: T) -> void:
	# The full grid of prop_ward_reach on generated Wards (every reachable spot walks back to the lift), a few seeds.
	var seeds := _seeds(1 if t.quick else 3, 2)
	var lines: Array[String] = []
	for s in seeds:
		for lowered: bool in [true, false]:
			var bad := Reach.stranded(s, lowered, true, false, _opts())
			if not bad.is_empty():
				lines.append("seed %d bridge %s: %d spots, first %s" % [s, "down" if lowered else "up", bad.size(), str(bad[0].snappedf(0.01))])
		var raised := Reach.stranded(s, true, true, true, _opts())
		if not raised.is_empty():
			lines.append("seed %d lowered then raised: %d spots" % [s, raised.size()])
	t.check(lines.is_empty(), "%d generated Wards: no reachable spot is cut off from the lift: %s" % [seeds.size(), "; ".join(lines)])

# ------------------------------------------------------------------------------------------------
# 6. Nothing intersects; every walkway walkable.

## The flat footprint of a house with its gallery.
static func _deck(site: Dictionary) -> Rect2:
	var half := Vector2(float(site.w), float(site.d)) * 0.5 + Vector2.ONE * Layout.GALLERY
	return Rect2(Vector2(float(site.x), float(site.y)) - half, half * 2.0)

## Distance from a segment to a rectangle (0 when they touch).
static func _segment_rect(p: Vector2, q: Vector2, r: Rect2) -> float:
	var best := INF
	for i in 21:
		var at := p.lerp(q, i / 20.0)
		var c := at.clamp(r.position, r.end)
		best = minf(best, at.distance_to(c))
	return best

static func _segment_segment(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	var best := INF
	for i in 41:
		best = minf(best, Geometry2D.get_closest_point_to_segment(a.lerp(b, i / 40.0), c, d).distance_to(a.lerp(b, i / 40.0)))
		best = minf(best, Geometry2D.get_closest_point_to_segment(c.lerp(d, i / 40.0), a, b).distance_to(c.lerp(d, i / 40.0)))
	return best

func test_nothing_intersects_and_walkways_are_walkable(t: T) -> void:
	var bad: Array[String] = []
	var steepest := 0.0
	var tallest := 0.0
	for s in _seeds(100, 3):
		var w := _ward(s)
		var l := w.layout
		var decks: Array[Rect2] = []
		for h: Dictionary in l.houses:
			decks.append(_deck(h))
			tallest = maxf(tallest, absf(float(h.z)))
		for i in decks.size():
			for j in range(i + 1, decks.size()):
				if decks[i].grow(0.5).intersects(decks[j]):
					bad.append("%d: houses %d and %d (with galleries) closer than 0.5 m" % [s, i, j])
		# The lift's car (its walls) clear of every other house's deck and of every walkway.
		var door := w.lift_door()
		var car := Rect2(Vector2(door.x - 0.78, door.z - 3.12), Vector2(1.56, 3.12))
		for i in range(1, decks.size()):
			if car.grow(0.3).intersects(decks[i]):
				bad.append("%d: the lift's car meets house %d" % [s, i])
		var spans: Array = []
		for e: Dictionary in l.bridges:
			for k in range(1, e.path.size()):
				var p := Footing.path_point(e.path[k - 1])
				var q := Footing.path_point(e.path[k])
				var run := Vector2(p.x, p.z).distance_to(Vector2(q.x, q.z))
				steepest = maxf(steepest, absf(q.y - p.y) / run)
				if absf(q.y - p.y) > Layout.SLOPE * run + 1e-4 or run < 0.8:
					bad.append("%d: walkway %d-%d rises %.2f m in %.2f m" % [s, e.a, e.b, absf(q.y - p.y), run])
				spans.append([Vector2(p.x, p.z), Vector2(q.x, q.z), e])
		for i in spans.size():
			var si: Array = spans[i]
			var ei: Dictionary = si[2]
			if _segment_rect(si[0], si[1], car) < Footing.DECK_WIDTH * 0.5 + 0.2:
				bad.append("%d: walkway %d-%d meets the lift's car" % [s, ei.a, ei.b])
			for h in decks.size():
				if h == int(ei.a) or h == int(ei.b):
					continue
				if _segment_rect(si[0], si[1], decks[h]) < Footing.DECK_WIDTH * 0.5 + 0.3:
					bad.append("%d: walkway %d-%d meets house %d" % [s, ei.a, ei.b, h])
			for j in range(i + 1, spans.size()):
				var sj: Array = spans[j]
				if sj[2] == ei:
					continue
				if _segment_segment(si[0], si[1], sj[0], sj[1]) < Footing.DECK_WIDTH + 0.4:
					bad.append("%d: walkways %d-%d and %d-%d meet" % [s, ei.a, ei.b, sj[2].a, sj[2].b])
		# A walkway reaches past its own house's gallery only at its dock.
		for e: Dictionary in l.bridges:
			var p := Footing.path_point(e.path[0])
			var q := Footing.path_point(e.path[-1])
			for end: Array in [[int(e.a), Vector2(p.x, p.z), Vector2(q.x, q.z)], [int(e.b), Vector2(q.x, q.z), Vector2(p.x, p.z)]]:
				var from: Vector2 = end[1]
				# From 1.2 m out the deck's edge (half its width, less the footing's edge clearance) is off the gallery.
				var away: Vector2 = from + (end[2] - from).normalized() * 1.2
				if _segment_rect(away, end[2], decks[end[0]]) < Footing.DECK_WIDTH * 0.5 - Footing.EDGE_CLEARANCE:
					bad.append("%d: walkway %d-%d runs back across house %d" % [s, e.a, e.b, end[0]])
	t.check(bad.is_empty(), "100 seeds: no two houses, walkways or the lift's car meet, and no walkway rises more than %.2f of its run: %s" % [Layout.SLOPE, "; ".join(bad.slice(0, 5))])
	t.note("steepest walkway %.3f (rise over run), highest house %.2f m from the parlour" % [steepest, tallest])

## Each house's door is in the wall that faces the way its `facing` says, opening onto its own gallery.
func test_turned_houses_keep_their_doors_and_windows_in_their_walls(t: T) -> void:
	var bad: Array[String] = []
	for s in _seeds(40, 4):
		var w := _ward(s)
		for id in w.houses.size():
			var h := w.houses[id]
			var site: Dictionary = w.layout.houses[id]
			var door := h.to_world(h.door.get_center())
			var face: Vector2 = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][int(site.facing)]
			var off := Vector2(door.x - float(site.x), door.z - float(site.y))
			var half := float(site.w) * 0.5 if face.x != 0.0 else float(site.d) * 0.5
			if absf(off.dot(face) - half) > 0.1 or absf(off.dot(Vector2(face.y, -face.x))) > 0.05:
				bad.append("%d house %d facing %d: door at %s" % [s, id, int(site.facing), str(off.snappedf(0.01))])
			# The local footprint is the site's, turned: the walls' corners land on the site's footprint.
			var corner := h.to_world(Vector3(h.floor_bounds.end.x, 0, h.floor_bounds.end.y))
			var rel := Vector2(absf(corner.x - float(site.x)), absf(corner.z - float(site.y)))
			if not rel.is_equal_approx(Vector2(float(site.w), float(site.d)) * 0.5):
				bad.append("%d house %d: footprint %s against %s" % [s, id, str(rel), str(Vector2(float(site.w), float(site.d)) * 0.5)])
			# The search window (the laundry's) is in a side wall: its outside face is half the width from the middle.
			if h.search_window.has_volume():
				var sill := h.to_world(h.search_window.get_center())
				var flat := Vector2(sill.x - float(site.x), sill.z - float(site.y)).length()
				if absf(flat - h.floor_bounds.size.x * 0.5 - House.WALL_THICKNESS * 0.5) > 0.6:
					bad.append("%d house %d: window %.2f m from the middle" % [s, id, flat])
			# The climb's corner is a corner of this house's deck, on the door's side.
			var anchor := h.support_corner(site)
			var to_anchor := Vector2(anchor.x - float(site.x), anchor.z - float(site.y))
			if to_anchor.dot(face) <= 0.0 or not _deck(site).has_point(Vector2(anchor.x, anchor.z)):
				bad.append("%d house %d: his line's corner %s is not at the front of its deck" % [s, id, str(to_anchor.snappedf(0.01))])
	t.check(bad.is_empty(), "40 seeds: every turned house's door, walls, window and loaded line are where its facing puts them: %s" % "; ".join(bad.slice(0, 5)))

# ------------------------------------------------------------------------------------------------
# 7. The route helper.

func test_the_route_helper_finds_the_lift_from_every_house(t: T) -> void:
	var n := 4 if t.quick else 40
	var bad: Array[String] = []
	var most := 0
	var slowest := 0
	for s in _seeds(n, 5):
		var w := _ward(s)
		w.phase = &"away"
		var door := w.lift_door()
		var goal := Vector2(door.x - 0.3, door.z + 2.2)
		for id in range(1, w.houses.size()):
			var h := w.houses[id]
			var a: Vector3 = h.areas[&"entry"]
			var from := h.to_world(Vector3(a.x, 0, a.z))
			var stats := {}
			var began := Time.get_ticks_msec()
			# main.gd `wardroute`: 40000 spots, 12 s.
			var route := Route.find(w, from, goal, 0.45, 40000, began + 12000, stats)
			var took := Time.get_ticks_msec() - began
			most = maxi(most, int(stats.get("expanded", 0)))
			slowest = maxi(slowest, took)
			if route.is_empty():
				bad.append("seed %d house %d (%d spots, %d ms)" % [s, id, int(stats.get("expanded", 0)), took])
	t.check(bad.is_empty(), "%d seeds: a route from every house's entry room to the lift within 40000 spots and 12 s: %s" % [n, "; ".join(bad.slice(0, 5))])
	t.note("most spots searched %d, slowest %d ms" % [most, slowest])

# ------------------------------------------------------------------------------------------------
# 8. The wire and the flag.

func test_the_options_on_the_wire(t: T) -> void:
	var w := _ward(8143)
	# The host's block (net/host.gd world adds the options to the Ward's snapshot).
	var block := w.snapshot()
	block["layout"] = w.layout_wire()
	t.eq(block.get("layout"), [2, 110, 150], "the block carries the options (version, spread in hundredths, rise in cm)")
	for native: bool in [false, true]:
		var sent := block.duplicate()
		if native:
			sent["native"] = true
		var raw := WardWire.encode(sent)
		t.eq(raw.size(), 15, "native %s: fifteen fields" % native)
		var back := WardWire.decode(JSON.parse_string(JSON.stringify(raw)))
		t.eq(back.get("layout"), [2, 110, 150], "native %s: the options come back through JSON" % native)
		t.eq(back.get("native", false), native, "native %s: native as sent" % native)
		var screen := Ward.new(int(back.seed), Layout.from_wire(back.layout))
		t.eq(Digest.line(int(back.seed), Layout.from_wire(back.layout)), Digest.line(8143, _opts()), "native %s: the screen's Ward is the host's" % native)
		t.eq(JSON.stringify(screen.layout), JSON.stringify(w.layout), "native %s: the same layout data" % native)
	var plain := Ward.new(8143).snapshot()
	t.eq(WardWire.encode(plain).size(), 13, "today's block: thirteen fields, as before")
	for wrong: Array in [[3, 110, 150], [2, 10, 150], [2, 110, -1], [2, 110], [2, 1.5, 150]]:
		var raw := WardWire.encode(block)
		raw[14] = wrong
		t.eq(WardWire.decode(raw), {}, "a block with options %s is refused" % str(wrong))
	# WC1 merged with WG1: the call and web extras come after the options, a sixteenth field; both arrive.
	var both := block.duplicate()
	both["native"] = true
	both["extras"] = {"called": true, "stationHouse": 3}
	var raw16 := WardWire.encode(both)
	t.eq(raw16.size(), 16, "with the options and the extras: sixteen fields")
	var back16 := WardWire.decode(JSON.parse_string(JSON.stringify(raw16)))
	t.eq(back16.get("layout"), [2, 110, 150], "the options come back beside the extras")
	t.check(back16.get("extras", {}).get("called", false) == true and int(back16.extras.stationHouse) == 3, "the extras come back beside the options")
	var bad16 := raw16.duplicate(true)
	bad16[15] = {"nonsense": 1}
	t.eq(WardWire.decode(bad16), {}, "a sixteenth field that is not the extras is refused")

## HostRules.new's arguments by position: every flag off but `late_floors` (the 39th) and `ward_layout` (no longer the last:
## the 49th, after WC1's ward_call_ and ward_web_) as given.
static func rules_args(late: bool, layout: bool) -> Array:
	var args: Array = [true, 1, []]
	for i in 46:
		args.append(false)
	args[38] = late
	args[48] = layout
	return args

func test_the_flag_reaches_the_rules(t: T) -> void:
	var rules: HostRules = HostRules.new.callv(rules_args(true, true))
	t.check(rules.late_floors and rules.ward_layout, "on with the late floors")
	t.check(not (HostRules.new.callv(rules_args(true, false)) as HostRules).ward_layout, "off when not asked")
	t.check(not (HostRules.new.callv(rules_args(false, true)) as HostRules).ward_layout, "never without the late floors")
