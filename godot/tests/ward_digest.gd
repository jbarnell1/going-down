# WN4: the Hanging Ward's model as text, for comparing processes and platforms (tests/prop_ward_same.gd).
# Run on its own (any machine, any platform, the same build):
#   godot --headless --path godot --script res://tests/ward_digest.gd -- 183025965 0 26 8143
# prints one line per seed: "WARD <seed> <digest of everything> <layout> <houses> <fixtures> <clear grid>".
# The same line in every process and on every platform is what "identical for every player" asks of the floor.
extends SceneTree

const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Layout = preload("res://sim/ward/layout.gd")

func _init() -> void:
	var seeds: Array[int] = []
	# WG1: `--layout=2` digests the generated layout (sim/ward/layout.gd options at today's settings) instead.
	var options := {}
	for a in OS.get_cmdline_user_args():
		if a.is_valid_int():
			seeds.append(int(a))
		elif a == "--layout=2":
			options = Layout.options(null)
	for s in seeds:
		print(line(s, options))
	quit()

## The digest line of one seed (`options`: a generated layout's, WG1; {} today's Ward).
static func line(seed_value: int, options: Dictionary = {}) -> String:
	var parts := parts_of(Ward.new(seed_value, options))
	var all := ""
	for p: String in parts:
		all += p
	var out := "WARD %d %s" % [seed_value, all.sha256_text().substr(0, 16)]
	for p: String in parts:
		out += " " + p.sha256_text().substr(0, 8)
	return out

## The model's facts as text in four parts: the layout, the houses' geometry, the fixtures (lift, switches), and a
## grid of walk_clear answers over the floor (standing at the footing's height).
static func parts_of(w: Ward) -> Array[String]:
	var layout := JSON.stringify(_plain(w.layout))
	var houses := ""
	for h: House in w.houses:
		houses += "H%s|%s|%s|%s|" % [_v(h.to_world(Vector3.ZERO)), _v(h.to_world(Vector3(1, 0, 0))), _r(h.floor_bounds), _b(h.door)]
		for b: AABB in h.walls:
			houses += _b(b) + ";"
		for b: AABB in h.upper_envelope:
			houses += "u" + _b(b) + ";"
		houses += "w%s%d;" % [_b(h.search_window), h.window_side]
		for st: House.Storey in h.storeys:
			houses += "h" + _f(st.height) + ";"
			for b: AABB in st.slab:
				houses += "f" + _b(b) + ";"
			for b: AABB in st.partitions:
				houses += "p" + _b(b) + ";"
		for s: House.Stair in h.stairs:
			houses += "s" + _v(s.from) + _v(s.to) + ";"
		for d: Vector3 in h.room_doors:
			houses += "d" + _v(d) + ";"
	var fixtures := _v(w.lift_door())
	for sw: Dictionary in w.switches:
		fixtures += "|%d %s" % [int(sw.house), _v(sw.position)]
	var grid := ""
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for site: Dictionary in w.layout.houses:
		lo = Vector2(minf(lo.x, float(site.x) - 8.0), minf(lo.y, float(site.y) - 8.0))
		hi = Vector2(maxf(hi.x, float(site.x) + 8.0), maxf(hi.y, float(site.y) + 8.0))
	var x := lo.x
	while x <= hi.x:
		var z := lo.y
		while z <= hi.y:
			var y := w.footing.walking_height(Vector2(x, z), 0.0, false)
			if is_finite(y):
				var p := Vector3(x, y, z)
				grid += "1" if w.walk_clear(p, p) else "0"
			else:
				grid += "."
			z += 0.25
		x += 0.25
	return [layout, houses, fixtures, grid]

static func _f(v: float) -> String:
	return "%.4f" % v

static func _v(v: Vector3) -> String:
	return "(%s,%s,%s)" % [_f(v.x), _f(v.y), _f(v.z)]

static func _r(r: Rect2) -> String:
	return "[%s,%s,%s,%s]" % [_f(r.position.x), _f(r.position.y), _f(r.size.x), _f(r.size.y)]

static func _b(b: AABB) -> String:
	return "[%s%s]" % [_v(b.position), _v(b.size)]

static func _plain(v: Variant) -> Variant:
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var out := []
		for k: Variant in keys:
			out.append([str(k), _plain(v[k])])
		return out
	if v is Array:
		return (v as Array).map(func(e: Variant) -> Variant: return _plain(e))
	if v is float:
		return _f(v)
	if v is Vector3:
		return _v(v)
	if v is Vector2:
		return "(%s,%s)" % [_f(v.x), _f(v.y)]
	return str(v)
