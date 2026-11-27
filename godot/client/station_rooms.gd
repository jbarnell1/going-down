# LA7 (26 Nov): the Reactor's side rooms dressed so each reads as the room it is (client/station_view.gd calls this
# once the station's own dressing, client/station_dress.gd, is built; this adds itself under that dressing). Looks
# only: nothing here is solid, nothing is a light, nothing glows, nothing makes a sound, and no rule reads it.
#
# The story the rooms tell (the lead's choice; the design says nothing about what is in a side room): they were
# stripped out. The shelves, lockers, desks and pumps were taken; their marks on the walls and floor, their fixings,
# and everything above head height stayed. Each kind of room gets its own look:
#   - stores:  a high rack on wall brackets loaded with crates, drums, cable reels and cartons; an overhead hoist rail
#              with a chain block pulled up; rows of bare shelf uprights with the pale lines where the shelves were,
#              stencilled bay letters, a stock board with tally hooks; worn yellow bay outlines and numbers on the
#              floor, drag marks;
#   - lockers: a high shelf of helmets, kit bags and boots over a hook rail with helmets, satchels and towels; a row
#              of pale plates where the lockers were unbolted; a notice board, a cracked mirror, a boot scraper bar;
#              overhead pipes; a duckboard's outline and a floor drain;
#   - office:  a high shelf of box files and ledgers; a pigeonhole rack, a notice board with rota sheets, a wall chart
#              of the station as a line drawing (room outlines only), a key board, a wall telephone, a calendar with
#              no readable date, a wall clock, a tannoy horn; the clean rectangles where a desk and a cabinet stood,
#              with the desk's castor dents;
#   - pumps:   an overhead duct and pipes with valve wheels and hangers; wall pipes with valve wheels and gauges, a
#              painted flow arrow, a grease gun on a bracket; plinth outlines with cut-off bolts and capped stubs, a
#              drain grate, oil stains;
#   - closet:  a high shelf with tins and a coiled hose, a switch box. The least.
# Every room but a closet has its name stencilled over its door inside, and a switch box with its conduit.
#
# Where things may go (tests/test_station_rooms.gd holds each one):
#   - wholly above HIGH_Y (higher than every point the plan's sight check looks at), anywhere in the room;
#   - on a wall, at most PROUD_MAX out from its face, and DOOR_CLEAR along the wall from a doorway's middle;
#   - flat on the floor, at most FLOOR_MAX high.
# Nothing within KEEP of a fuse spot (every candidate), the cabinet, the cassette's table, the time cards, the
# landing's hooks or a body's place, counted only in the room the thing is in (a wall stops a keep-out). One or two
# walls of a room carry its look; at least one wall is left plain.
#
# Everything is laid out in the plan's canonical frame (before the seed's east-west mirror) from the floor seed with
# this file's own generator, then mirrored with the plan, so a mirrored plan gets the mirrored dressing and the
# station's own dressing draws exactly what it drew before. Lettering is mirrored in place, never reversed.
extends Node3D

const Point = preload("res://client/station_point.gd")
const Dress = preload("res://client/station_dress.gd")
const Glyphs = preload("res://client/pixel_font.gd")

const S := 2.0
const LH := 3.2
const WALL_HALF := 0.07
## Free pieces lie wholly above this: higher than the top of a figure (sim/sight.gd FIGURE_LEVELS ends at 2.6 m).
const HIGH_Y := 2.64
## Below HIGH_Y a piece stands at most this far out from its wall's face.
const PROUD_MAX := 0.15
## How high a mark on the floor may stand.
const FLOOR_MAX := 0.02
## Nothing this near (across the floor) a fuse spot, the cabinet, the cassette's table, the cards, hooks or bodies.
const KEEP := 1.0
## Below HIGH_Y nothing on a wall this near (along the wall) a doorway's middle in that wall.
const DOOR_CLEAR := 1.5
## The rack's deck: its arms under it, its top.
const ARM_Y := 2.665
const DECK_TOP := 2.725
## The goods on a rack keep this far off the wall (the station's main runs under the ceiling within it).
const GOODS_D0 := 0.31
const GOODS_D1 := 0.61
const GOODS_TOP := 3.13
## Mesh groups: the west wing in bands this many cells deep, the north-east store on its own.
const BAND_CELLS := 8
const KINDS: Array[String] = ["stores", "lockers", "office", "pumps", "closet"]
const NAMES := {"stores": "STORES", "lockers": "LOCKERS", "office": "SHIFT OFFICE", "pumps": "PUMP ROOM"}
const BAYS := "ABCDEF"
## Every word this file writes on a wall or a floor (tests read it).
const WORDS: Array[String] = ["STORES", "LOCKERS", "SHIFT OFFICE", "PUMP ROOM", "STOCK", "NOTICES", "ROTA", "FLOW", "KEYS",
	"A", "B", "C", "D", "E", "F", "1", "2", "3", "4", "5", "6"]

## Colours (sRGB, multiplied by the shared materials' maps or drawn flat).
const C_STEEL := Color(0.78, 0.79, 0.78)
const C_DARK := Color(0.2, 0.2, 0.2)
const C_GREY := Color(0.5, 0.51, 0.5)
const C_WOOD := Color(0.47, 0.35, 0.22)
const C_WOOD_DARK := Color(0.33, 0.24, 0.15)
const C_CARD := Color(0.52, 0.41, 0.27)
const C_PAPER := Color(0.82, 0.8, 0.72)
const C_INK := Color(0.16, 0.17, 0.2)
const C_CORK := Color(0.55, 0.42, 0.28)
const C_YELLOW := Color(0.72, 0.6, 0.2)
const C_STENCIL := Color(0.12, 0.12, 0.11)
const C_PALE_PAINT := Color(0.42, 0.58, 0.45)
const C_PALE_CONC := Color(0.66, 0.65, 0.61)
const C_CLEAN_FLOOR := Color(0.66, 0.64, 0.6)
const C_STAIN := Color(0.1, 0.09, 0.08)
const C_DRUMS: Array[Color] = [Color(0.25, 0.36, 0.27), Color(0.45, 0.2, 0.13), Color(0.3, 0.34, 0.4), Color(0.5, 0.46, 0.35)]
const C_FILES: Array[Color] = [Color(0.4, 0.14, 0.13), Color(0.17, 0.22, 0.36), Color(0.33, 0.38, 0.3), Color(0.6, 0.52, 0.36)]
const C_HELMETS: Array[Color] = [Color(0.78, 0.66, 0.18), Color(0.8, 0.79, 0.74), Color(0.72, 0.38, 0.14)]
const C_TOWELS: Array[Color] = [Color(0.78, 0.77, 0.7), Color(0.5, 0.58, 0.66), Color(0.66, 0.6, 0.48)]
const C_BAGS: Array[Color] = [Color(0.28, 0.3, 0.22), Color(0.18, 0.21, 0.28), Color(0.36, 0.3, 0.22)]

## Tests only: the dressing is not drawn at all.
static var off := false
## Tests only: one-line breaks the tests prove themselves with ("keep": no keep-outs; "door": no doorway clearance;
## "high": high pieces drawn 0.5 m lower; "proud": wall pieces 0.3 m farther out; "storey": every piece a storey up;
## "plain": every wall dressed; "seed": a fresh generator each build; "mirror": not mirrored with the plan; "glow":
## the pieces drawn glowing; "word": a banned word on the stock board; "touch": the station's own generator used).
static var test_break := ""

var lv: Level
var view: Node3D
var dresser: Node3D
var anchors := {}
## Every piece drawn: {kind, room, rkind, zone ("high", "wall", "floor", "over_door"), which (canonical wall, -1 for
## none), n (the wall's normal into the room, world; ZERO for none), face (a point on the wall's face, world), aabb
## (world, from the triangles drawn), cell (Vector2i, world)}.
var records: Array[Dictionary] = []
## The rooms dressed: {id, kind, rect (world Rect2), walls: {which: "identity" | "sign" | "plain"}}.
var rooms_done: Array[Dictionary] = []
## The words drawn.
var words: PackedStringArray = PackedStringArray()
var counts := {}

var _mirror := false
var _wm := 0.0
var _W := 0
var _geo := {}           # "mat|group" -> Geo

## The triangles of one mesh being built.
class Geo:
	var p := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
var _mats := {}
var _cur := {}
var _group := ""
var _rng := RandomNumberGenerator.new()
var _keeps: Array[Vector3] = []     # canonical
var _battens: Array[AABB] = []      # canonical

## Draws the side rooms' dressing for `level` under `station_dress`. Returns the node (or null when off).
static func dress(level: Level, station_view: Node3D, station_dress: Node3D, station_anchors: Dictionary) -> Node3D:
	if off:
		return null
	var r: Node3D = new()
	r.name = "StationRooms"
	station_dress.add_child(r)
	r.call(&"build", level, station_view, station_dress, station_anchors)
	return r

static func texts() -> Array[String]:
	var out: Array[String] = WORDS.duplicate()
	if test_break == "word":
		out.append("FUSE STOCK")
	return out

func build(level: Level, station_view: Node3D, station_dress: Node3D, station_anchors: Dictionary) -> void:
	lv = level
	view = station_view
	dresser = station_dress
	anchors = station_anchors
	_W = lv.W
	_wm = float(_W) * S
	_mirror = bool(anchors.get("mirrored", false)) and test_break != "mirror"
	_mats["steel"] = (dresser.get(&"_mats") as Dictionary)["steel"]
	_mats["flat"] = view.get(&"mat_props")
	if test_break == "glow":
		_mats["flat"] = Level.glow_material(Color.WHITE, 1.0)
	for key: String in ["plinth", "cabinet"]:
		var p := Point.v3(anchors.get(key))
		if p != Vector3.INF:
			_keeps.append(_c(p))
	for key: String in ["fuse_spots", "lockers", "time_cards", "bodies"]:
		for a: Variant in anchors.get(key, []):
			var p := Point.v3(a)
			if p != Vector3.INF:
				_keeps.append(_c(p))
	# The battens to keep off, and each one's reflection across its own room (the view sets a batten in a room of even
	# width one cell off its middle, so a mirrored plan's battens are not the mirror of the plain plan's; keeping off
	# both keeps this dressing the mirror of itself).
	for l: Light3D in lv.main_lights:
		var c := _c(l.position + Vector3(0, 0.06, 0))
		_battens.append(AABB(c - Vector3(0.08, 0.04, 0.625), Vector3(0.16, 0.08, 1.25)))
		var cell := Vector2i(floori(l.position.x / S), floori(l.position.z / S))
		var id := int(lv.room_at[0][cell.y * _W + cell.x]) if cell.x >= 0 and cell.y >= 0 and cell.x < _W and cell.y < lv.H else -1
		if id >= 0:
			var r: Dictionary = lv.plan.rooms[id]
			var rx0 := float(_W - int(r.x) - int(r.w) if _mirror else int(r.x)) * S
			var rc := Vector3(2.0 * rx0 + float(r.w) * S - c.x, c.y, c.z)
			_battens.append(AABB(rc - Vector3(0.08, 0.04, 0.625), Vector3(0.16, 0.08, 1.25)))
	var seed_text := "%s:%d" % [lv.plan.get("seed", ""), int(lv.plan.get("depth", 0))]
	var order: Array[Dictionary] = []
	for r: Dictionary in lv.plan.rooms:
		if int(r.get("level", 0)) == 0 and KINDS.has(str(r.kind)):
			order.append(r)
	for r: Dictionary in order:
		if test_break == "seed":
			_rng.randomize()
		else:
			_rng.seed = hash("%s:rooms:%d" % [seed_text, int(r.id)])
		if test_break == "touch":
			var d_rng: RandomNumberGenerator = dresser.get(&"_rng")
			d_rng.randf()
		_room(r)
	_commit()

# --- frames ----------------------------------------------------------------------------------------------

## World <-> canonical (the plan before its mirror): x reflected about the floor's middle when mirrored.
func _c(p: Vector3) -> Vector3:
	return Vector3(_wm - p.x, p.y, p.z) if _mirror else p

func _w(p: Vector3) -> Vector3:
	return Vector3(_wm - p.x, p.y, p.z) if _mirror else p

func _wn(n: Vector3) -> Vector3:
	return Vector3(-n.x, n.y, n.z) if _mirror else n

## The world edge kinds read in the canonical frame: a vertical line at canonical x (cells x - 1 | x) on row y, and a
## horizontal line at canonical row y under cell x.
func _vert(x: int, y: int) -> String:
	var wx := _W - x if _mirror else x
	return lv.edges[0].vertical[y * (_W + 1) + wx]

func _hor(x: int, y: int) -> String:
	var wx := _W - 1 - x if _mirror else x
	return lv.edges[0].horizontal[y * _W + wx]

## The room kind across a canonical cell (or "").
func _kind_at(cx: int, cy: int) -> String:
	var wx := _W - 1 - cx if _mirror else cx
	if wx < 0 or cy < 0 or wx >= _W or cy >= lv.H:
		return ""
	var id := int(lv.room_at[0][cy * _W + wx])
	return str(lv.plan.rooms[id].kind) if id >= 0 else ""

static func at_side(side: Dictionary, s: float, y: float, d: float) -> Vector3:
	return (side["o"] as Vector3) + (side["dir"] as Vector3) * s + Vector3.UP * y + (side["n"] as Vector3) * d

## The four walls of a room in the canonical frame: {which, o, dir, n, len, doors: [s of each doorway's middle],
## out: [the room kind through each doorway]}. 0 north, 1 east, 2 south, 3 west.
func _sides(cr: Rect2i) -> Array[Dictionary]:
	var x0 := float(cr.position.x) * S
	var z0 := float(cr.position.y) * S
	var x1 := float(cr.end.x) * S
	var z1 := float(cr.end.y) * S
	var defs := [[Vector3(x0, 0, z0), Vector3.RIGHT, Vector3.BACK, cr.size.x], [Vector3(x1, 0, z0), Vector3.BACK, Vector3.LEFT, cr.size.y],
		[Vector3(x1, 0, z1), Vector3.LEFT, Vector3.FORWARD, cr.size.x], [Vector3(x0, 0, z1), Vector3.FORWARD, Vector3.RIGHT, cr.size.y]]
	var out: Array[Dictionary] = []
	for which in 4:
		var df: Array = defs[which]
		var cells: int = df[3]
		var doors: Array[float] = []
		var outs: Array[String] = []
		for i in cells:
			var k := ""
			var across := Vector2i.ZERO
			match which:
				0:
					k = _hor(cr.position.x + i, cr.position.y)
					across = Vector2i(cr.position.x + i, cr.position.y - 1)
				1:
					k = _vert(cr.end.x, cr.position.y + i)
					across = Vector2i(cr.end.x, cr.position.y + i)
				2:
					k = _hor(cr.end.x - 1 - i, cr.end.y)
					across = Vector2i(cr.end.x - 1 - i, cr.end.y)
				3:
					k = _vert(cr.position.x, cr.end.y - 1 - i)
					across = Vector2i(cr.position.x - 1, cr.end.y - 1 - i)
			if k != "wall":
				doors.append(i * S + S * 0.5)
				outs.append(_kind_at(across.x, across.y))
		out.append({"which": which, "o": df[0], "dir": df[1], "n": df[2], "len": float(cells) * S, "doors": doors, "out": outs})
	return out

# --- where things may go ----------------------------------------------------------------------------------

## The keep points inside a canonical room rectangle (a wall stops a keep-out: only the room's own count).
func _room_keeps(rect: Rect2) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if test_break == "keep":
		return out
	for p in _keeps:
		if rect.has_point(Vector2(p.x, p.z)):
			out.append(p)
	return out

## Cuts [t - r, t + r] out of spans.
static func _cut(spans: Array[Vector2], a: float, b: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for sp in spans:
		if b <= sp.x or a >= sp.y:
			out.append(sp)
			continue
		if a > sp.x:
			out.append(Vector2(sp.x, a))
		if b < sp.y:
			out.append(Vector2(b, sp.y))
	return out

## The parts of [t0, t1] along a line (origin + dir * t) where a piece reaching lat_lo..lat_hi across it (along
## `lat`) keeps KEEP from every keep point of the room.
func _line_spans(keeps: Array[Vector3], origin: Vector3, dir: Vector3, lat: Vector3, lat_lo: float, lat_hi: float, t0: float, t1: float) -> Array[Vector2]:
	var spans: Array[Vector2] = [Vector2(t0, t1)]
	for p in keeps:
		var rel := Vector3(p.x - origin.x, 0, p.z - origin.z)
		var t := rel.dot(dir)
		var l := rel.dot(lat)
		var dl := maxf(0.0, maxf(lat_lo - l, l - lat_hi))
		if dl < KEEP:
			var r := sqrt(KEEP * KEEP - dl * dl) + 0.03
			spans = _cut(spans, t - r, t + r)
	return spans

## The spans of a wall a piece reaching `dmax` from its line can use: off the corners, off the keep points, and
## for a low piece off the doorways (a high one only off the frame).
func _wall_spans(room: Dictionary, side: Dictionary, dmax: float, low: bool) -> Array[Vector2]:
	var length: float = side["len"]
	var spans := _line_spans(room["keeps"], side["o"], side["dir"], side["n"], 0.0, dmax, 0.14, length - 0.14)
	var clear := DOOR_CLEAR if low else 0.95
	if test_break == "door" and low:
		clear = 0.62
	for c: float in side["doors"]:
		spans = _cut(spans, c - clear, c + clear)
	var out: Array[Vector2] = []
	for sp in spans:
		if sp.y - sp.x >= 0.2:
			out.append(sp)
	return out

static func _span_len(spans: Array[Vector2]) -> float:
	var t := 0.0
	for sp in spans:
		t += sp.y - sp.x
	return t

static func _longest(spans: Array[Vector2]) -> Vector2:
	var best := Vector2.ZERO
	for sp in spans:
		if sp.y - sp.x > best.y - best.x:
			best = sp
	return best

## Whether a floor rectangle (canonical) is inside the room off its walls and KEEP from every keep point.
func _floor_ok(room: Dictionary, r: Rect2) -> bool:
	var rr: Rect2 = room["crect"]
	if not rr.grow(-0.09).encloses(r):
		return false
	for p: Vector3 in room["keeps"]:
		var dx := maxf(0.0, maxf(r.position.x - p.x, p.x - r.end.x))
		var dz := maxf(0.0, maxf(r.position.y - p.z, p.z - r.end.y))
		if dx * dx + dz * dz < (KEEP + 0.02) * (KEEP + 0.02):
			return false
	return true

## Whether an overhead box (canonical) keeps off the battens.
func _clear_of_battens(box: AABB) -> bool:
	for b in _battens:
		if b.grow(0.12).intersects(box):
			return false
	return true

# --- the rooms --------------------------------------------------------------------------------------------

func _room(r: Dictionary) -> void:
	var kind := str(r.kind)
	var cx := _W - int(r.x) - int(r.w) if _mirror else int(r.x)
	var cr := Rect2i(cx, int(r.y), int(r.w), int(r.h))
	var crect := Rect2(Vector2(cr.position) * S, Vector2(cr.size) * S)
	var sides := _sides(cr)
	var room := {"id": int(r.id), "kind": kind, "cr": cr, "crect": crect, "sides": sides, "keeps": _room_keeps(crect)}
	_group = ("e" if cr.position.x >= 8 else "w%d" % (cr.position.y / BAND_CELLS))
	# The entrance: the doorway into the hall (a closet's into its room).
	var entrance := -1
	var entrance_s := 0.0
	for side in sides:
		var outs: Array = side["out"]
		for i in outs.size():
			if entrance < 0 and (outs[i] == "hall" or (kind == "closet" and outs[i] != "")):
				entrance = int(side["which"])
				entrance_s = float(side["doors"][i])
	# Which walls carry the look: the identity wall (most free wall), the high wall (most free for a rack, not the
	# identity wall unless the kind wants the two together), the entrance's wall (its sign), the rest left plain.
	var low_free: Array[float] = []
	var high_free: Array[float] = []
	var tie: Array[float] = []
	for side in sides:
		# A wall with a doorway in it is a poor wall for a look: a line along it from the doorway passes close to it.
		var doored := 0.0 if (side["doors"] as Array).is_empty() else 4.0
		low_free.append(_span_len(_wall_spans(room, side, WALL_HALF + PROUD_MAX, true)) - doored)
		high_free.append(_span_len(_wall_spans(room, side, GOODS_D1 + 0.02, true)) - doored)
		tie.append(_rng.randf() * 0.01)
	var ident := -1
	for i in 4:
		if i != entrance and (ident < 0 or low_free[i] + tie[i] > low_free[ident] + tie[ident]):
			ident = i
	var high := ident
	if kind != "lockers":
		high = -1
		for i in 4:
			if i != ident and i != entrance and (high < 0 or high_free[i] + tie[i] > high_free[high] + tie[high]):
				high = i
	if kind == "closet":
		ident = -1
	var roles := {}
	for i in 4:
		roles[i] = "plain"
	if ident >= 0:
		roles[ident] = "identity"
	if high >= 0:
		roles[high] = "identity"
	if entrance >= 0 and kind != "closet":
		roles[entrance] = "sign"
	if test_break == "plain":
		for i in 4:
			if roles[i] == "plain":
				_wall_items(room, sides[i], "stores")
	var done := {"id": int(r.id), "kind": kind, "rect": Rect2(Vector2(float(r.x), float(r.y)) * S, Vector2(float(r.w), float(r.h)) * S), "walls": roles}
	rooms_done.append(done)
	match kind:
		"stores":
			if high >= 0:
				_rack(room, sides[high], ["crate", "drum", "reel", "carton", "carton", "crate"])
			if ident >= 0:
				_shelf_marks(room, sides[ident])
			_hoist(room, high)
		"lockers":
			if high >= 0:
				_rack(room, sides[high], ["helmet", "bag", "boots", "helmet", "bag"])
				_hook_rail(room, sides[high])
			var other := -1
			for i in 4:
				if roles[i] == "plain" and (other < 0 or low_free[i] > low_free[other]):
					other = i
			if other >= 0 and low_free[other] >= 1.6 and (sides[other]["doors"] as Array).is_empty():
				roles[other] = "identity"
				_locker_plates(room, sides[other])
			_overhead_pipes(room, high, false)
		"office":
			if high >= 0:
				_rack(room, sides[high], ["files", "files", "ledgers", "files"])
			if ident >= 0:
				_office_wall(room, sides[ident])
				_office_floor(room, sides[ident], sides[high] if high >= 0 else {})
		"pumps":
			if ident >= 0:
				_pump_wall(room, sides[ident])
			_pump_floor(room, ident)
			_overhead_pipes(room, high if high >= 0 else ident, true)
		"closet":
			if high >= 0:
				_rack(room, sides[high], ["tins", "hose", "tins"], 1.5)
	if entrance >= 0:
		# The switch box and the kind's own small pieces go on the high wall when that is another wall (no doorway in it).
		var extras: Dictionary = sides[high] if high >= 0 and high != ident and kind != "closet" else sides[entrance]
		_entrance(room, sides[entrance], entrance_s, extras)
	counts[kind] = int(counts.get(kind, 0)) + 1

# --- pieces: recording ---------------------------------------------------------------------------------------

func _begin(kind: String, room: Dictionary, zone: String, side: Dictionary = {}) -> void:
	var n := Vector3.ZERO
	var face := Vector3.ZERO
	if not side.is_empty():
		n = _wn(side["n"])
		face = _w(at_side(side, 0.0, 0.0, WALL_HALF))
	_cur = {"kind": kind, "room": room["id"], "rkind": room["kind"], "zone": zone, "which": int(side.get("which", -1)), "n": n, "face": face,
		"lo": Vector3.INF, "hi": -Vector3.INF, "tris": 0, "keeps": room["keeps"], "sizes": {}, "words": words.size(), "side": side}

func _end() -> void:
	if int(_cur.get("tris", 0)) == 0:
		_cur = {}
		return
	var lo: Vector3 = _cur["lo"]
	var hi: Vector3 = _cur["hi"]
	# The last guard: a piece that came within KEEP of a keep point of its room (across the floor) is taken out again.
	for kp: Vector3 in _cur["keeps"]:
		var p := _w(kp)
		var dx := maxf(0.0, maxf(lo.x - p.x, p.x - hi.x))
		var dz := maxf(0.0, maxf(lo.z - p.z, p.z - hi.z))
		if dx * dx + dz * dz < KEEP * KEEP:
			_drop()
			return
	if _cur["zone"] == "wall" and not _grazing_ok(_cur["side"], lo, hi):
		_drop()
		return
	var c := (lo + hi) * 0.5
	records.append({"kind": _cur["kind"], "room": _cur["room"], "rkind": _cur["rkind"], "zone": _cur["zone"], "which": _cur["which"],
		"n": _cur["n"], "face": _cur["face"], "aabb": AABB(lo, hi - lo), "cell": Vector2i(floori(c.x / S), floori(c.z / S))})
	counts["pieces"] = int(counts.get("pieces", 0)) + 1
	_cur = {}

## Takes the piece being drawn out again.
func _drop() -> void:
	var sizes: Dictionary = _cur["sizes"]
	for key: String in sizes:
		var g: Geo = _geo[key]
		var at: int = sizes[key]
		g.p.resize(at)
		g.n.resize(at)
		g.c.resize(at)
	words.resize(int(_cur["words"]))
	counts["dropped"] = int(counts.get("dropped", 0)) + 1
	_cur = {}

## Whether a wall piece (world box lo..hi) on `side` stays out of every line a body standing in a doorway of that
## wall could see along it: such a line leaves the doorway at the wall's line and reaches a body's width (BODY_D) off
## it only at the far end of the wall, so near a doorway only flat things fit.
const BODY_D := 0.31
func _grazing_ok(side: Dictionary, lo: Vector3, hi: Vector3) -> bool:
	if test_break == "door":
		return true
	var doors: Array = side["doors"]
	if doors.is_empty():
		return true
	var s0 := INF
	var s1 := -INF
	var deep := 0.0
	for k in 8:
		var p := _c(Vector3(hi.x if k & 1 else lo.x, hi.y if k & 2 else lo.y, hi.z if k & 4 else lo.z))
		var rel := p - (side["o"] as Vector3)
		var s := rel.dot(side["dir"])
		s0 = minf(s0, s)
		s1 = maxf(s1, s)
		deep = maxf(deep, rel.dot(side["n"]))
	var length: float = side["len"]
	for c: float in doors:
		var near := s0 - c if s0 > c else c - s1
		var to_end := length - c if s0 > c else c
		if near <= 0.0:
			return false
		var lim := BODY_D * (near - 0.25) / maxf(to_end - 0.25, 0.01) - 0.012
		if deep > lim:
			return false
	return true

# --- pieces: geometry (canonical in, world out) ------------------------------------------------------------

func _tri(mat: String, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	_tri_world(mat, _w(a), _w(b), _w(c), _wn(n), col)

func _tri_world(mat: String, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	if test_break == "storey":
		a.y += LH
		b.y += LH
		c.y += LH
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b
		b = c
		c = t
	var key := "%s|%s" % [mat, _group]
	if not _geo.has(key):
		_geo[key] = Geo.new()
	var g: Geo = _geo[key]
	if not _cur.is_empty() and not (_cur["sizes"] as Dictionary).has(key):
		_cur["sizes"][key] = g.p.size()
	g.p.append(a)
	g.p.append(b)
	g.p.append(c)
	g.n.append(n)
	g.n.append(n)
	g.n.append(n)
	g.c.append(col)
	g.c.append(col)
	g.c.append(col)
	if not _cur.is_empty():
		_cur["lo"] = (_cur["lo"] as Vector3).min(a).min(b).min(c)
		_cur["hi"] = (_cur["hi"] as Vector3).max(a).max(b).max(c)
		_cur["tris"] = int(_cur["tris"]) + 1

func _quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	_tri(mat, a, b, c, n, col)
	_tri(mat, a, c, d, n, col)

## A box: `basis` columns are its x, y, z; `size` along them; centred at `at`. `back` false leaves its -z face out.
func _box(mat: String, basis: Basis, at: Vector3, size: Vector3, col: Color, back := true) -> void:
	var hx := basis.x * size.x * 0.5
	var hy := basis.y * size.y * 0.5
	var hz := basis.z * size.z * 0.5
	var faces := [[hz, hx, hy], [-hz, hx, hy], [hx, hz, hy], [-hx, hz, hy], [hy, hx, hz], [-hy, hx, hz]]
	for i in faces.size():
		if i == 1 and not back:
			continue
		var f: Array = faces[i]
		var o: Vector3 = at + f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var shade := 0.82 if i == 5 else (1.0 if i != 4 else 1.06)
		_quad(mat, o - u - v, o + u - v, o + u + v, o - u + v, (f[0] as Vector3).normalized(), Color(col.r * shade, col.g * shade, col.b * shade))

## A box in a wall's frame: s along it, y up, d out from the wall's line (d0 its back, depth `dd`).
func _wbox(mat: String, side: Dictionary, s: float, y: float, d0: float, ss: float, sy: float, dd: float, col: Color) -> void:
	if test_break == "proud":
		d0 += 0.3
	var basis := Basis(side["dir"], Vector3.UP, side["n"])
	_box(mat, basis, at_side(side, s, y, d0 + dd * 0.5), Vector3(ss, sy, dd), col, false)

## A flat panel on a wall's face (d out from the line), s0..s1, y0..y1.
func _wpanel(mat: String, side: Dictionary, s0: float, s1: float, y0: float, y1: float, d: float, col: Color) -> void:
	_quad(mat, at_side(side, s0, y0, d), at_side(side, s1, y0, d), at_side(side, s1, y1, d), at_side(side, s0, y1, d), side["n"], col)

## A flat mark on the floor in a wall's frame (s0..s1 along, d0..d1 out), at height h.
func _fmark(side: Dictionary, s0: float, s1: float, d0: float, d1: float, h: float, col: Color) -> void:
	_quad("flat", at_side(side, s0, h, d0), at_side(side, s1, h, d0), at_side(side, s1, h, d1), at_side(side, s0, h, d1), Vector3.UP, col)

## A cylinder from a to b (open or capped).
func _cyl(mat: String, a: Vector3, b: Vector3, r: float, col: Color, segs := 8, caps := true, r_b := -1.0) -> void:
	var axis := (b - a).normalized()
	var ref := Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT
	var u := axis.cross(ref).normalized()
	var v := axis.cross(u).normalized()
	var rb := r if r_b < 0.0 else r_b
	for j in segs:
		var a0 := TAU * j / segs
		var a1 := TAU * (j + 1) / segs
		var d0 := u * cos(a0) + v * sin(a0)
		var d1 := u * cos(a1) + v * sin(a1)
		var nm := (d0 + d1).normalized()
		_quad(mat, a + d0 * r, a + d1 * r, b + d1 * rb, b + d0 * rb, nm, col)
		if caps:
			_tri(mat, a, a + d1 * r, a + d0 * r, -axis, col.darkened(0.1))
			_tri(mat, b, b + d0 * rb, b + d1 * rb, axis, col.lightened(0.05))

## A flat many-sided disc on the floor (an oil stain, a dent), radius rx by rz.
func _floor_disc(c: Vector3, rx: float, rz: float, col: Color, segs := 8) -> void:
	for j in segs:
		var a0 := TAU * j / segs
		var a1 := TAU * (j + 1) / segs
		_tri("flat", c, c + Vector3(cos(a0) * rx, 0, sin(a0) * rz), c + Vector3(cos(a1) * rx, 0, sin(a1) * rz), Vector3.UP, col)

## A ring of short tubes (a valve wheel, a coiled hose) round `c`, in the plane normal to `axis`.
func _ring(mat: String, c: Vector3, axis: Vector3, radius: float, r: float, col: Color, segs := 10) -> void:
	var ref := Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT
	var u := axis.cross(ref).normalized()
	var v := axis.cross(u).normalized()
	for j in segs:
		var p0 := c + (u * cos(TAU * j / segs) + v * sin(TAU * j / segs)) * radius
		var p1 := c + (u * cos(TAU * (j + 1) / segs) + v * sin(TAU * (j + 1) / segs)) * radius
		_cyl(mat, p0, p1, r, col, 4, false)

## Stencilled words on a wall, centred at (s, y), standing `d` off the line, `px` metres a font pixel. Laid out in
## the world so a mirrored plan never reverses them.
func _text_wall(side: Dictionary, s: float, y: float, d: float, text: String, px: float, col: Color) -> void:
	var at := _w(at_side(side, s, y, d))
	var n := _wn(side["n"])
	var right := (-n).cross(Vector3.UP).normalized()
	_glyphs(at, right, Vector3.UP, n, text, px, col)
	words.append(text)

## Painted words on the floor in front of a wall, their tops toward it.
func _text_floor(side: Dictionary, s: float, d: float, h: float, text: String, px: float, col: Color) -> void:
	var at := _w(at_side(side, s, h, d))
	var up := -_wn(side["n"])
	var right := up.cross(Vector3.UP).normalized()
	_glyphs(at, right, up, Vector3.UP, text, px, col)
	words.append(text)

func _glyphs(at: Vector3, right: Vector3, up: Vector3, n: Vector3, text: String, px: float, col: Color) -> void:
	var x0 := -float(Glyphs.width(text)) * px * 0.5
	var y0 := 3.5 * px
	for i in text.length():
		var rows: Array = Glyphs.rows(text[i])
		for yy in rows.size():
			var row: String = rows[yy]
			var x := 0
			while x < 5:
				if row[x] != "1":
					x += 1
					continue
				var x1 := x
				while x1 + 1 < 5 and row[x1 + 1] == "1":
					x1 += 1
				var l := x0 + float(i * 6 + x) * px
				var rr := x0 + float(i * 6 + x1 + 1) * px
				var t := y0 - float(yy) * px
				var b := t - px
				var p0 := at + right * l + up * b
				var p1 := at + right * rr + up * b
				var p2 := at + right * rr + up * t
				var p3 := at + right * l + up * t
				_tri_world("flat", p0, p1, p2, n, col)
				_tri_world("flat", p0, p2, p3, n, col)
				x = x1 + 1

# --- the high rack -------------------------------------------------------------------------------------------

## A rack high on a wall: plates on the wall, arms under a deck, a lip; loaded from `goods`. At most `max_len`.
func _rack(room: Dictionary, side: Dictionary, goods: Array, max_len := 4.6) -> void:
	# Off the doorways as far as a wall piece (its plates come down the wall below HIGH_Y).
	var sp := _longest(_wall_spans(room, side, GOODS_D1 + 0.02, true))
	if sp.y - sp.x < 0.9:
		return
	var length := minf(sp.y - sp.x, max_len)
	var s0 := (sp.x + sp.y) * 0.5 - length * 0.5
	var s1 := s0 + length
	var dy := -0.5 if test_break == "high" else 0.0
	_begin("rack", room, "high", side)
	_wbox("steel", side, (s0 + s1) * 0.5, DECK_TOP - 0.015 + dy, 0.075, length, 0.03, GOODS_D1 + 0.01 - 0.075, C_STEEL.darkened(0.15))
	_wbox("steel", side, (s0 + s1) * 0.5, DECK_TOP + 0.015 + dy, GOODS_D1 - 0.01, length, 0.03, 0.02, C_STEEL.darkened(0.25))
	var n := maxi(2, ceili(length / 1.15) + 1)
	for i in n:
		var s := lerpf(s0 + 0.06, s1 - 0.06, float(i) / float(n - 1))
		_wbox("steel", side, s, ARM_Y + 0.015 + dy, 0.072, 0.05, 0.03, GOODS_D1 + 0.01 - 0.072, C_DARK)
	_end()
	for i in n:
		var s := lerpf(s0 + 0.06, s1 - 0.06, float(i) / float(n - 1))
		_begin("rack_plate", room, "wall", side)
		_wbox("steel", side, s, 2.56, 0.07, 0.07, 0.24, 0.018, C_DARK)
		_end()
	# The goods, side by side with gaps; now and then a gap where something was taken.
	var s := s0 + 0.06
	var k := 0
	while s < s1 - 0.2:
		var what: String = goods[(k + _rng.randi_range(0, goods.size() - 1)) % goods.size()]
		k += 1
		var w := _good(room, side, what, s, s1 - 0.05, dy)
		if w <= 0.0:
			break
		s += w + _rng.randf_range(0.03, 0.14)
		if _rng.randf() < 0.12:
			s += _rng.randf_range(0.25, 0.5)

## One thing on a rack starting at s (not past s_max). Returns its width (0 when it does not fit).
func _good(room: Dictionary, side: Dictionary, what: String, s: float, s_max: float, dy: float) -> float:
	var base := DECK_TOP + dy
	var dmid := (GOODS_D0 + GOODS_D1) * 0.5
	var basis := Basis(side["dir"], Vector3.UP, side["n"])
	var w := 0.0
	match what:
		"crate":
			w = _rng.randf_range(0.42, 0.58)
			if s + w > s_max:
				return 0.0
			var h := _rng.randf_range(0.26, 0.36)
			var col := C_WOOD.lerp(C_WOOD_DARK, _rng.randf())
			_begin("crate", room, "high", side)
			_box("flat", basis, at_side(side, s + w * 0.5, base + h * 0.5, dmid), Vector3(w, h, GOODS_D1 - GOODS_D0), col)
			for f: float in [0.25, 0.75]:
				_wpanel("flat", side, s + 0.01, s + w - 0.01, base + h * f - 0.025, base + h * f + 0.025, GOODS_D1 + 0.003, col.darkened(0.35))
			_end()
		"carton":
			w = _rng.randf_range(0.3, 0.42)
			if s + w > s_max:
				return 0.0
			var h := _rng.randf_range(0.18, 0.26)
			_begin("carton", room, "high", side)
			_box("flat", basis, at_side(side, s + w * 0.5, base + h * 0.5, dmid), Vector3(w, h, 0.28), C_CARD.lerp(C_PAPER, _rng.randf() * 0.25))
			if _rng.randf() < 0.6:
				var h2 := _rng.randf_range(0.15, 0.22)
				_box("flat", basis, at_side(side, s + w * 0.5 + _rng.randf_range(-0.03, 0.03), base + h + h2 * 0.5, dmid), Vector3(w - 0.06, h2, 0.24), C_CARD.darkened(0.15))
			_end()
		"drum":
			var r := _rng.randf_range(0.13, 0.15)
			w = r * 2.0
			if s + w > s_max:
				return 0.0
			var h := _rng.randf_range(0.34, 0.38)
			var c := at_side(side, s + r, base, dmid)
			_begin("drum", room, "high", side)
			var col: Color = C_DRUMS[_rng.randi_range(0, C_DRUMS.size() - 1)]
			_cyl("flat", c, c + Vector3.UP * h, r, col, 8)
			_cyl("flat", c + Vector3.UP * (h * 0.33), c + Vector3.UP * (h * 0.36), r + 0.006, col.darkened(0.3), 8, false)
			_end()
		"reel":
			var r := _rng.randf_range(0.15, 0.19)
			var width := _rng.randf_range(0.2, 0.28)
			w = width
			if s + w > s_max:
				return 0.0
			var dirv: Vector3 = side["dir"]
			var a := at_side(side, s, base + r, dmid)
			var b := a + dirv * width
			_begin("reel", room, "high", side)
			_cyl("flat", a, a + dirv * 0.025, r, C_WOOD, 8)
			_cyl("flat", b - dirv * 0.025, b, r, C_WOOD, 8)
			_cyl("flat", a + dirv * 0.025, b - dirv * 0.025, r * 0.82, Color(0.12, 0.12, 0.13), 8, false)
			_end()
		"helmet":
			w = 0.3
			if s + w > s_max:
				return 0.0
			_begin("helmet", room, "high", side)
			_dome(at_side(side, s + 0.15, base, dmid), 0.13, 0.12, C_HELMETS[_rng.randi_range(0, C_HELMETS.size() - 1)])
			_end()
		"bag":
			w = _rng.randf_range(0.42, 0.52)
			if s + w > s_max:
				return 0.0
			var col: Color = C_BAGS[_rng.randi_range(0, C_BAGS.size() - 1)]
			_begin("kit_bag", room, "high", side)
			_box("flat", basis, at_side(side, s + w * 0.5, base + 0.12, dmid), Vector3(w, 0.24, 0.27), col)
			_box("flat", basis, at_side(side, s + w * 0.5, base + 0.245, dmid), Vector3(0.05, 0.012, 0.28), col.darkened(0.4))
			_end()
		"boots":
			w = 0.26
			if s + w > s_max:
				return 0.0
			_begin("boots", room, "high", side)
			for k in 2:
				var ss := s + 0.06 + k * 0.13
				_box("flat", basis, at_side(side, ss, base + 0.04, dmid), Vector3(0.1, 0.08, 0.26), Color(0.16, 0.13, 0.1))
				_box("flat", basis, at_side(side, ss, base + 0.15, dmid - 0.07), Vector3(0.1, 0.16, 0.11), Color(0.18, 0.15, 0.11))
			_end()
		"files":
			var count := _rng.randi_range(4, 9)
			w = count * 0.075
			if s + w > s_max:
				return 0.0
			_begin("box_files", room, "high", side)
			for i in count:
				var col: Color = C_FILES[_rng.randi_range(0, C_FILES.size() - 1)]
				var lean := 0.0 if i < count - 1 or _rng.randf() < 0.5 else 0.12
				var bb := Basis(side["dir"], Vector3.UP, side["n"]).rotated(side["n"], -lean)
				_box("flat", bb, at_side(side, s + 0.0375 + i * 0.075, base + 0.15, dmid), Vector3(0.068, 0.3, 0.26), col)
				_wpanel("flat", side, s + 0.012 + i * 0.075, s + 0.063 + i * 0.075, base + 0.18, base + 0.24, dmid + 0.132, C_PAPER)
			_end()
		"ledgers":
			w = 0.34
			if s + w > s_max:
				return 0.0
			_begin("ledgers", room, "high", side)
			var y := base
			for i in _rng.randi_range(2, 4):
				var th := _rng.randf_range(0.04, 0.06)
				var bb := basis.rotated(Vector3.UP, _rng.randf_range(-0.08, 0.08))
				_box("flat", bb, at_side(side, s + 0.17, y + th * 0.5, dmid), Vector3(0.3, th, 0.23), C_FILES[_rng.randi_range(0, C_FILES.size() - 1)].darkened(0.2))
				y += th
			_end()
		"tins":
			var count := _rng.randi_range(3, 5)
			w = count * 0.15
			if s + w > s_max:
				return 0.0
			_begin("tins", room, "high", side)
			for i in count:
				var r := _rng.randf_range(0.055, 0.07)
				var h := _rng.randf_range(0.1, 0.18)
				var c := at_side(side, s + 0.075 + i * 0.15, base, dmid + _rng.randf_range(-0.06, 0.06))
				_cyl("flat", c, c + Vector3.UP * h, r, C_DRUMS[_rng.randi_range(0, C_DRUMS.size() - 1)].lightened(0.1), 6)
			_end()
		"hose":
			w = 0.42
			if s + w > s_max:
				return 0.0
			_begin("hose", room, "high", side)
			var c := at_side(side, s + 0.21, base + 0.026, dmid)
			_ring("flat", c, Vector3.UP, 0.13, 0.026, Color(0.5, 0.16, 0.12), 10)
			_ring("flat", c + Vector3.UP * 0.05, Vector3.UP, 0.12, 0.026, Color(0.5, 0.16, 0.12), 10)
			_end()
	return w

## A helmet: a dome and its brim, sitting on `c`.
func _dome(c: Vector3, r: float, h: float, col: Color) -> void:
	var rings := 3
	var segs := 8
	for i in rings:
		var la0 := PI * 0.5 * i / rings
		var la1 := PI * 0.5 * (i + 1) / rings
		for j in segs:
			var lo0 := TAU * j / segs
			var lo1 := TAU * (j + 1) / segs
			var p := func(la: float, lo: float) -> Vector3: return c + Vector3(cos(la) * cos(lo) * r, sin(la) * h + 0.02, cos(la) * sin(lo) * r)
			var nm := Vector3(cos((la0 + la1) * 0.5) * cos((lo0 + lo1) * 0.5), sin((la0 + la1) * 0.5), cos((la0 + la1) * 0.5) * sin((lo0 + lo1) * 0.5))
			_quad("flat", p.call(la0, lo0), p.call(la0, lo1), p.call(la1, lo1), p.call(la1, lo0), nm, col)
	_cyl("flat", c, c + Vector3.UP * 0.02, r + 0.03, col.darkened(0.1), 8)

# --- stores ----------------------------------------------------------------------------------------------

## The identity wall of a store: bare shelf uprights with cut-off bracket stubs, the pale lines where the shelves
## were, a stencilled letter over each bay; on the floor in front, worn yellow bay outlines with their numbers and
## drag marks toward the door.
func _shelf_marks(room: Dictionary, side: Dictionary) -> void:
	var sp := _longest(_wall_spans(room, side, WALL_HALF + PROUD_MAX, true))
	if sp.y - sp.x < 1.1:
		return
	var bays := clampi(floori((sp.y - sp.x) / 1.0), 1, 5)
	var bw := (sp.y - sp.x) / bays
	var green_low := true
	for b in bays + 1:
		var s := lerpf(sp.x + 0.03, sp.y - 0.03, float(b) / float(bays))
		_begin("upright", room, "wall", side)
		_wbox("steel", side, s, 1.15, WALL_HALF, 0.045, 1.8, 0.02, C_STEEL.darkened(0.3))
		for y: float in [0.5, 1.1, 1.7]:
			_wbox("steel", side, s, y, WALL_HALF + 0.02, 0.03, 0.05, 0.045, C_DARK)
		_end()
	for b in bays:
		var a := sp.x + b * bw + 0.06
		var e := a + bw - 0.12
		_begin("shelf_ghost", room, "wall", side)
		for y: float in [0.5, 1.1, 1.7]:
			var col := C_PALE_PAINT if y < 1.2 and green_low else C_PALE_CONC
			_wpanel("flat", side, a, e, y - 0.02, y + 0.03, WALL_HALF + 0.0015, col)
		_end()
		_begin("bay_letter", room, "wall", side)
		_text_wall(side, (a + e) * 0.5, 2.05, WALL_HALF + 0.002, BAYS[b], 0.03, C_STENCIL)
		_end()
		# The bay on the floor: a worn yellow outline, dashed where it is worn through, and its number.
		var d0 := 0.16
		var d1 := 0.92
		var cr := Rect2()
		var p0 := at_side(side, a, 0.0, d0)
		var p1 := at_side(side, e, 0.0, d1)
		cr = Rect2(Vector2(minf(p0.x, p1.x), minf(p0.z, p1.z)), Vector2(absf(p1.x - p0.x), absf(p1.z - p0.z)))
		if not _floor_ok(room, cr.grow(0.03)):
			continue
		_begin("bay_outline", room, "floor")
		var lw := 0.05
		for edge: Array in [[a, e, d0, d0 + lw], [a, e, d1 - lw, d1], [a, a + lw, d0, d1], [e - lw, e, d0, d1]]:
			var ea: float = edge[0]
			var eb: float = edge[1]
			var long_s := eb - ea > lw * 2.0
			var cuts := [0.0, 1.0]
			if _rng.randf() < 0.7:
				var m := _rng.randf_range(0.3, 0.7)
				cuts = [0.0, m - 0.08, m + _rng.randf_range(0.0, 0.12), 1.0]
			for k in range(0, cuts.size(), 2):
				var t0: float = cuts[k]
				var t1: float = cuts[k + 1]
				if long_s:
					_fmark(side, lerpf(ea, eb, t0), lerpf(ea, eb, t1), edge[2], edge[3], 0.005, C_YELLOW.lerp(C_CLEAN_FLOOR, _rng.randf() * 0.35))
				else:
					_fmark(side, ea, eb, lerpf(float(edge[2]), float(edge[3]), t0), lerpf(float(edge[2]), float(edge[3]), t1), 0.005, C_YELLOW.lerp(C_CLEAN_FLOOR, _rng.randf() * 0.35))
		_end()
		_begin("bay_number", room, "floor")
		_text_floor(side, (a + e) * 0.5, d1 + 0.16, 0.006, str(b + 1), 0.035, C_YELLOW.darkened(0.1))
		_end()
	# Drag marks from the bays out across the floor.
	for i in _rng.randi_range(2, 3):
		var s := _rng.randf_range(sp.x + 0.3, sp.y - 0.3)
		var dir := (side["n"] as Vector3).rotated(Vector3.UP, _rng.randf_range(-0.5, 0.5))
		var start := at_side(side, s, 0.0, 1.0)
		var length := _rng.randf_range(1.0, 2.2)
		var end := start + dir * length
		var r := Rect2(Vector2(minf(start.x, end.x), minf(start.z, end.z)), Vector2(absf(end.x - start.x), absf(end.z - start.z))).grow(0.06)
		if not _floor_ok(room, r):
			continue
		var across := dir.cross(Vector3.UP).normalized()
		_begin("drag_mark", room, "floor")
		for k in 2:
			var off := across * (k * 0.32 - 0.16)
			var w := _rng.randf_range(0.015, 0.035)
			var y := Vector3.UP * (0.003 + k * 0.0005)
			_quad("flat", start + off - across * w + y, end + off - across * w + y, end + off + across * w + y, start + off + across * w + y, Vector3.UP, Color(0.36, 0.35, 0.33))
		_end()

## An overhead hoist rail down the room's long axis, a trolley and chain block pulled right up, its hook high.
func _hoist(room: Dictionary, high: int) -> void:
	var rr: Rect2 = room["crect"]
	var along_z := rr.size.y >= rr.size.x
	if maxf(rr.size.x, rr.size.y) < 3.9:
		return
	var dir := Vector3.BACK if along_z else Vector3.RIGHT
	var lat := Vector3.RIGHT if along_z else Vector3.BACK
	var centre := Vector3(rr.get_center().x, 0, rr.get_center().y)
	var start := centre - dir * (maxf(rr.size.x, rr.size.y) * 0.5)
	var length := maxf(rr.size.x, rr.size.y)
	var width := minf(rr.size.x, rr.size.y)
	var offs: Array[float] = [0.75, -0.75, 1.1, -1.1, 0.45, -0.45]
	if high >= 0:
		# Toward the rack's wall first.
		var hn: Vector3 = (room["sides"] as Array)[high]["n"]
		if hn.dot(lat) > 0.5:
			offs = [-0.75, 0.75, -1.1, 1.1, -0.45, 0.45]
	for off in offs:
		if absf(off) > width * 0.5 - 0.5:
			continue
		var o := start + lat * off
		var sp := _longest(_line_spans(room["keeps"], o, dir, lat, -0.08, 0.08, 0.3, length - 0.3))
		if sp.y - sp.x < 2.5:
			continue
		var a := o + dir * sp.x
		var b := o + dir * sp.y
		var box := AABB(Vector3(minf(a.x, b.x) - 0.08, 2.95, minf(a.z, b.z) - 0.08), Vector3(absf(b.x - a.x) + 0.16, 0.25, absf(b.z - a.z) + 0.16))
		if not _clear_of_battens(box):
			continue
		var basis := Basis(dir, Vector3.UP, lat) if along_z else Basis(dir, Vector3.UP, -lat)
		var mid := (a + b) * 0.5
		var dyl := -0.5 if test_break == "high" else 0.0
		_begin("hoist_rail", room, "high")
		_box("steel", basis, mid + Vector3.UP * (3.1 + dyl), Vector3(sp.y - sp.x, 0.16, 0.018), C_STEEL.darkened(0.2))
		_box("steel", basis, mid + Vector3.UP * (3.012 + dyl), Vector3(sp.y - sp.x, 0.018, 0.12), C_STEEL.darkened(0.2))
		_box("steel", basis, mid + Vector3.UP * (3.19 + dyl), Vector3(sp.y - sp.x, 0.018, 0.12), C_STEEL.darkened(0.2))
		var t := 0.3
		while t < sp.y - sp.x - 0.1:
			_box("steel", basis, a + dir * t + Vector3.UP * (3.17 + dyl), Vector3(0.06, 0.06, 0.2), C_DARK)
			t += 1.8
		_end()
		# The trolley and chain block, pulled up, its hook at 2.68 m.
		var at := a + dir * _rng.randf_range(0.6, maxf(0.7, sp.y - sp.x - 0.6))
		_begin("chain_block", room, "high")
		_box("steel", basis, at + Vector3.UP * (2.97 + dyl), Vector3(0.22, 0.07, 0.17), C_DARK)
		_box("flat", basis, at + Vector3.UP * (2.84 + dyl), Vector3(0.2, 0.2, 0.16), Color(0.55, 0.45, 0.18))
		_box("steel", basis, at + Vector3.UP * (2.75 + dyl), Vector3(0.03, 0.06, 0.03), C_DARK)
		_box("steel", basis, at + Vector3.UP * (2.705 + dyl) + dir * 0.02, Vector3(0.07, 0.025, 0.025), C_DARK)
		_box("steel", basis, at + Vector3.UP * (2.69 + dyl) + dir * 0.05, Vector3(0.022, 0.05, 0.025), C_DARK)
		for side_off: float in [-0.12, 0.12]:
			_box("steel", basis, at + Vector3.UP * (2.78 + dyl) + dir * side_off, Vector3(0.012, 0.22, 0.012), C_DARK)
		_end()
		return

# --- lockers ---------------------------------------------------------------------------------------------

## A hook rail under the high shelf, with helmets, satchels and towels on some of its hooks.
func _hook_rail(room: Dictionary, side: Dictionary) -> void:
	var sp := _longest(_wall_spans(room, side, WALL_HALF + PROUD_MAX, true))
	if sp.y - sp.x < 1.0:
		return
	var s0 := sp.x + 0.05
	var s1 := minf(sp.y - 0.05, s0 + 4.2)
	_begin("hook_rail", room, "wall", side)
	_wbox("flat", side, (s0 + s1) * 0.5, 1.73, WALL_HALF, s1 - s0, 0.09, 0.022, C_WOOD)
	var hooks: Array[float] = []
	var s := s0 + 0.15
	while s < s1 - 0.1:
		hooks.append(s)
		_wbox("steel", side, s, 1.71, WALL_HALF + 0.022, 0.018, 0.018, 0.06, C_DARK)
		_wbox("steel", side, s, 1.735, WALL_HALF + 0.07, 0.018, 0.04, 0.014, C_DARK)
		s += 0.32
	_end()
	for hs in hooks:
		var roll := _rng.randf()
		if roll < 0.35:
			continue
		if roll < 0.6:
			_begin("helmet_on_hook", room, "wall", side)
			var col: Color = C_HELMETS[_rng.randi_range(0, C_HELMETS.size() - 1)]
			# A helmet hung by its brim, its crown toward the room, no deeper than the rail allows.
			var c := at_side(side, hs, 1.6, WALL_HALF + 0.012)
			_box("flat", Basis(side["dir"], Vector3.UP, side["n"]), c + (side["n"] as Vector3) * 0.006, Vector3(0.27, 0.22, 0.012), col.darkened(0.1))
			_flat_dome(side, hs, 1.6, WALL_HALF + 0.018, 0.12, 0.1, 0.1, col)
			_end()
		elif roll < 0.82:
			_begin("satchel", room, "wall", side)
			var col: Color = C_BAGS[_rng.randi_range(0, C_BAGS.size() - 1)]
			_wbox("flat", side, hs, 1.45, WALL_HALF + 0.005, 0.28, 0.24, 0.065, col)
			_wbox("flat", side, hs, 1.585, WALL_HALF + 0.07, 0.29, 0.06, 0.008, col.darkened(0.2))
			_wbox("flat", side, hs - 0.1, 1.64, WALL_HALF + 0.03, 0.02, 0.12, 0.01, col.darkened(0.35))
			_wbox("flat", side, hs + 0.1, 1.64, WALL_HALF + 0.03, 0.02, 0.12, 0.01, col.darkened(0.35))
			_end()
		else:
			_begin("towel", room, "wall", side)
			var col: Color = C_TOWELS[_rng.randi_range(0, C_TOWELS.size() - 1)]
			_wbox("flat", side, hs, 1.43, WALL_HALF + 0.075, 0.26, 0.5, 0.014, col)
			_wpanel("flat", side, hs - 0.13, hs + 0.13, 1.25, 1.28, WALL_HALF + 0.09, col.darkened(0.3))
			_end()

## A shallow dome flat against a wall (a hung helmet's crown): radii along the wall, up, and out.
func _flat_dome(side: Dictionary, s: float, y: float, d: float, rs: float, ry: float, rd: float, col: Color) -> void:
	var rings := 3
	var segs := 8
	var c := at_side(side, s, y, d)
	var dirv: Vector3 = side["dir"]
	var nv: Vector3 = side["n"]
	for i in rings:
		var la0 := PI * 0.5 * i / rings
		var la1 := PI * 0.5 * (i + 1) / rings
		for j in segs:
			var lo0 := TAU * j / segs
			var lo1 := TAU * (j + 1) / segs
			var p := func(la: float, lo: float) -> Vector3: return c + dirv * (cos(la) * cos(lo) * rs) + Vector3.UP * (cos(la) * sin(lo) * ry) + nv * (sin(la) * rd)
			var nm := (dirv * cos((la0 + la1) * 0.5) * cos((lo0 + lo1) * 0.5) + Vector3.UP * cos((la0 + la1) * 0.5) * sin((lo0 + lo1) * 0.5) + nv * sin((la0 + la1) * 0.5)).normalized()
			_quad("flat", p.call(la0, lo0), p.call(la0, lo1), p.call(la1, lo1), p.call(la1, lo0), nm, col)

## Where the lockers were unbolted: a row of pale plates with their bolt plates and a top rail, rust run down from
## the bolts; on the floor in front, the plinth's line and a floor drain; a duckboard's outline beyond.
func _locker_plates(room: Dictionary, side: Dictionary) -> void:
	var sp := _longest(_wall_spans(room, side, WALL_HALF + PROUD_MAX, true))
	var n := floori((sp.y - sp.x - 0.1) / 0.62)
	if n < 2:
		return
	n = mini(n, 6)
	var s0 := (sp.x + sp.y) * 0.5 - n * 0.31
	_begin("locker_rail", room, "wall", side)
	_wbox("steel", side, s0 + n * 0.31, 1.96, WALL_HALF, n * 0.62, 0.05, 0.014, C_STEEL.darkened(0.35))
	_end()
	for i in n:
		var a := s0 + i * 0.62 + 0.02
		var e := a + 0.58
		_begin("locker_ghost", room, "wall", side)
		_wpanel("flat", side, a, e, 0.16, 1.2, WALL_HALF + 0.0015, C_PALE_PAINT)
		_wpanel("flat", side, a, e, 1.2, 1.93, WALL_HALF + 0.0015, C_PALE_CONC)
		for c: Vector2 in [Vector2(a + 0.06, 0.3), Vector2(e - 0.06, 0.3), Vector2(a + 0.06, 1.8), Vector2(e - 0.06, 1.8)]:
			_wbox("steel", side, c.x, c.y, WALL_HALF + 0.002, 0.06, 0.06, 0.01, C_DARK)
			if _rng.randf() < 0.5:
				_wpanel("flat", side, c.x - 0.006, c.x + 0.006, c.y - _rng.randf_range(0.12, 0.3), c.y - 0.03, WALL_HALF + 0.003, Color(0.32, 0.2, 0.12))
		_end()
	# The plinth's front line on the floor and a drain.
	var p0 := at_side(side, s0, 0.0, 0.1)
	var p1 := at_side(side, s0 + n * 0.62, 0.0, 0.55)
	var r := Rect2(Vector2(minf(p0.x, p1.x), minf(p0.z, p1.z)), Vector2(absf(p1.x - p0.x), absf(p1.z - p0.z)))
	if _floor_ok(room, r):
		_begin("plinth_mark", room, "floor")
		_fmark(side, s0, s0 + n * 0.62, 0.1, 0.5, 0.003, C_CLEAN_FLOOR)
		_fmark(side, s0, s0 + n * 0.62, 0.5, 0.53, 0.004, Color(0.34, 0.33, 0.31))
		_end()
	var dc := at_side(side, (sp.x + sp.y) * 0.5 + _rng.randf_range(-0.6, 0.6), 0.0, 1.25)
	if _floor_ok(room, Rect2(dc.x - 0.2, dc.z - 0.2, 0.4, 0.4)):
		_begin("floor_drain", room, "floor")
		_drain(side, dc)
		_end()
	# A duckboard's outline: slats worn pale into the floor.
	var ds := (sp.x + sp.y) * 0.5 + _rng.randf_range(-0.3, 0.3)
	var q0 := at_side(side, ds - 0.85, 0.0, 1.7)
	var q1 := at_side(side, ds + 0.85, 0.0, 2.4)
	var qr := Rect2(Vector2(minf(q0.x, q1.x), minf(q0.z, q1.z)), Vector2(absf(q1.x - q0.x), absf(q1.z - q0.z)))
	if _floor_ok(room, qr):
		_begin("duckboard_outline", room, "floor")
		var k := 0.0
		while k < 1.7:
			_fmark(side, ds - 0.85 + k, ds - 0.85 + k + 0.09, 1.7, 2.4, 0.003, C_CLEAN_FLOOR.lerp(Color(0.5, 0.48, 0.44), _rng.randf() * 0.5))
			k += 0.14
		_end()

## A square drain grate centred at c (canonical, on the floor), aligned with the wall.
func _drain(side: Dictionary, c: Vector3) -> void:
	var dirv: Vector3 = side["dir"]
	var nv: Vector3 = side["n"]
	var q := func(s0: float, s1: float, d0: float, d1: float, h: float, col: Color) -> void:
		_quad("flat", c + dirv * s0 + nv * d0 + Vector3.UP * h, c + dirv * s1 + nv * d0 + Vector3.UP * h, c + dirv * s1 + nv * d1 + Vector3.UP * h, c + dirv * s0 + nv * d1 + Vector3.UP * h, Vector3.UP, col)
	q.call(-0.17, 0.17, -0.17, 0.17, 0.004, Color(0.06, 0.06, 0.06))
	for i in 5:
		var s := -0.13 + i * 0.065
		q.call(s - 0.012, s + 0.012, -0.15, 0.15, 0.006, Color(0.3, 0.3, 0.29))

# --- office ------------------------------------------------------------------------------------------------

## The office's identity wall: a pigeonhole rack, a notice board with rota sheets, a wall chart of the station as a
## line drawing, and a clock high on the wall.
func _office_wall(room: Dictionary, side: Dictionary) -> void:
	var spans := _wall_spans(room, side, WALL_HALF + PROUD_MAX, true)
	var items: Array[String] = ["pigeonholes", "chart", "rota"]
	var widths := {"pigeonholes": 0.9, "chart": 1.05, "rota": 0.85}
	var placed := 0
	for sp in spans:
		var s := sp.x + 0.08
		while placed < items.size() and s + float(widths[items[placed]]) <= sp.y - 0.05:
			var what := items[placed]
			var w: float = widths[what]
			match what:
				"pigeonholes":
					_pigeonholes(room, side, s, w)
				"chart":
					_chart(room, side, s, w)
				"rota":
					_board(room, side, s, w, "ROTA", true)
			s += w + 0.22
			placed += 1
	# The clock, high and central on the wall.
	var best := _longest(spans)
	if best.y - best.x > 0.4:
		var cs := (best.x + best.y) * 0.5
		_begin("clock", room, "wall", side)
		var c := at_side(side, cs, 2.32, WALL_HALF)
		var nv: Vector3 = side["n"]
		_cyl("flat", c, c + nv * 0.045, 0.16, C_DARK, 12)
		_cyl("flat", c + nv * 0.045, c + nv * 0.05, 0.14, C_PAPER, 12, false)
		for k in 12:
			var ang := TAU * k / 12.0
			var p := c + nv * 0.052 + ((side["dir"] as Vector3) * cos(ang) + Vector3.UP * sin(ang)) * 0.12
			_box("flat", Basis(side["dir"], Vector3.UP, side["n"]), p, Vector3(0.012, 0.012, 0.004), C_INK)
		var h_ang := _rng.randf() * TAU
		var m_ang := _rng.randf() * TAU
		for hand: Array in [[h_ang, 0.07, 0.012], [m_ang, 0.11, 0.008]]:
			var ang: float = hand[0]
			var len_h: float = hand[1]
			var dirh := (side["dir"] as Vector3) * cos(ang) + Vector3.UP * sin(ang)
			var bb := Basis(dirh, dirh.cross(nv).normalized(), nv)
			_box("flat", bb, c + nv * 0.056 + dirh * (len_h * 0.5), Vector3(len_h, float(hand[2]), 0.004), C_INK)
		_end()

## Where the desk and a cabinet stood: clean rectangles in the floor's grime, the desk's four castor dents.
func _office_floor(room: Dictionary, side: Dictionary, high_side: Dictionary) -> void:
	var sp := _longest(_wall_spans(room, side, 1.7, true))
	if sp.y - sp.x >= 1.5:
		var s := (sp.x + sp.y) * 0.5 + _rng.randf_range(-0.2, 0.2)
		var p0 := at_side(side, s - 0.7, 0.0, 0.9)
		var p1 := at_side(side, s + 0.7, 0.0, 1.6)
		var r := Rect2(Vector2(minf(p0.x, p1.x), minf(p0.z, p1.z)), Vector2(absf(p1.x - p0.x), absf(p1.z - p0.z)))
		if _floor_ok(room, r):
			_begin("desk_mark", room, "floor")
			_fmark(side, s - 0.7, s + 0.7, 0.9, 1.6, 0.003, C_CLEAN_FLOOR)
			for c: Vector2 in [Vector2(s - 0.64, 0.96), Vector2(s + 0.64, 0.96), Vector2(s - 0.64, 1.54), Vector2(s + 0.64, 1.54)]:
				_floor_disc(at_side(side, c.x, 0.004, c.y), 0.025, 0.025, Color(0.22, 0.21, 0.2), 6)
			_end()
	var cab := high_side if not high_side.is_empty() else side
	var csp := _longest(_wall_spans(room, cab, 0.75, true))
	if csp.y - csp.x >= 0.7:
		var s2 := csp.x + 0.05 if _rng.randf() < 0.5 else csp.y - 0.55
		var q0 := at_side(cab, s2, 0.0, 0.1)
		var q1 := at_side(cab, s2 + 0.5, 0.0, 0.68)
		var qr := Rect2(Vector2(minf(q0.x, q1.x), minf(q0.z, q1.z)), Vector2(absf(q1.x - q0.x), absf(q1.z - q0.z)))
		if _floor_ok(room, qr):
			_begin("filing_mark", room, "floor")
			_fmark(cab, s2, s2 + 0.5, 0.1, 0.68, 0.003, C_CLEAN_FLOOR.darkened(0.04))
			_end()

## Pigeonholes: a shallow rack of small compartments, a few with papers in them.
func _pigeonholes(room: Dictionary, side: Dictionary, s: float, w: float) -> void:
	_begin("pigeonholes", room, "wall", side)
	var y0 := 1.3
	var h := 0.62
	var d0 := WALL_HALF
	var depth := 0.13
	_wpanel("flat", side, s, s + w, y0, y0 + h, d0 + 0.002, C_WOOD_DARK)
	var cols := 5
	var rows := 3
	for i in cols + 1:
		_wbox("flat", side, s + w * i / cols, y0 + h * 0.5, d0, 0.018, h, depth, C_WOOD)
	for j in rows + 1:
		_wbox("flat", side, s + w * 0.5, y0 + h * j / rows, d0, w + 0.018, 0.018, depth, C_WOOD)
	for i in cols:
		for j in rows:
			if _rng.randf() < 0.4:
				var cs := s + w * (i + 0.5) / cols
				var cy := y0 + h * j / rows + 0.04
				_wbox("flat", side, cs, cy, d0 + 0.01, w / cols - 0.05, 0.06, depth - 0.03, C_PAPER.darkened(_rng.randf() * 0.2))
	_end()

## A board with sheets pinned to it (a notice board, a rota board: the rota's sheets ruled in a grid).
func _board(room: Dictionary, side: Dictionary, s: float, w: float, title: String, ruled: bool) -> void:
	_begin("rota_board" if ruled else "notice_board", room, "wall", side)
	var y0 := 1.25
	var h := 0.62
	_wbox("flat", side, s + w * 0.5, y0 + h * 0.5, WALL_HALF, w, h, 0.018, C_CORK)
	_wbox("flat", side, s + w * 0.5, y0 + h + 0.01, WALL_HALF, w + 0.03, 0.025, 0.024, C_WOOD_DARK)
	_text_wall(side, s + w * 0.5, y0 + h + 0.09, WALL_HALF + 0.002, title, 0.018, C_STENCIL)
	var sheets := _rng.randi_range(2, 3)
	for k in sheets:
		var sw := 0.2 + _rng.randf() * 0.04
		var ss := s + 0.06 + k * (w - 0.12) / sheets
		var sy := y0 + 0.08 + _rng.randf() * 0.12
		_wpanel("flat", side, ss, ss + sw, sy, sy + 0.29, WALL_HALF + 0.02, C_PAPER.darkened(_rng.randf() * 0.15))
		if ruled:
			for r in 6:
				_wpanel("flat", side, ss + 0.015, ss + sw - 0.015, sy + 0.03 + r * 0.04, sy + 0.034 + r * 0.04, WALL_HALF + 0.021, C_INK)
			for c in 3:
				_wpanel("flat", side, ss + 0.05 + c * 0.06, ss + 0.054 + c * 0.06, sy + 0.03, sy + 0.234, WALL_HALF + 0.021, C_INK)
		else:
			for r in 5:
				var lw := sw * _rng.randf_range(0.4, 0.85)
				_wpanel("flat", side, ss + 0.02, ss + 0.02 + lw, sy + 0.05 + r * 0.045, sy + 0.058 + r * 0.045, WALL_HALF + 0.021, C_INK.lightened(0.3))
	_end()

## A wall chart of the station: a sheet with every room's outline drawn as lines, nothing marked on it.
func _chart(room: Dictionary, side: Dictionary, s: float, w: float) -> void:
	_begin("wall_chart", room, "wall", side)
	var y0 := 1.18
	var h := 0.74
	_wpanel("flat", side, s, s + w, y0, y0 + h, WALL_HALF + 0.003, C_PAPER)
	var pw := float(_W) * S
	var ph := float(lv.H) * S
	var k := minf((w - 0.08) / pw, (h - 0.08) / ph)
	var ox := s + w * 0.5 - pw * k * 0.5
	var oy := y0 + h * 0.5 + ph * k * 0.5
	var lw := 0.004
	for r: Dictionary in lv.plan.rooms:
		if int(r.get("level", 0)) != 0:
			continue
		var cx := float(_W - int(r.x) - int(r.w) if _mirror else int(r.x)) * S
		var x0 := ox + cx * k
		var x1 := ox + (cx + float(r.w) * S) * k
		var z0 := oy - float(r.y) * S * k
		var z1 := oy - float(int(r.y) + int(r.h)) * S * k
		for e: Array in [[x0, x1, z0 - lw, z0], [x0, x1, z1, z1 + lw], [x0, x0 + lw, z1, z0], [x1 - lw, x1, z1, z0]]:
			_wpanel("flat", side, e[0], e[1], e[2], e[3], WALL_HALF + 0.004, Color(0.2, 0.26, 0.4))
	_end()

# --- pumps --------------------------------------------------------------------------------------------------

## The heights a pump room's own pipe runs take on a wall (client/station_dress.gd RUNS): kept clear.
func _run_bands(room: Dictionary, side: Dictionary) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var longest := 0.0
	for sd: Dictionary in room["sides"]:
		longest = maxf(longest, float(sd["len"]))
	for run: Dictionary in Dress.RUNS:
		if not (run["rooms"] as Array).has(room["kind"]):
			continue
		if bool(run.get("long_only", false)) and float(side["len"]) < longest - 0.01:
			continue
		var ro := maxf(float(run["r"]), float(run["lag"]))
		var h: float = run["h"]
		if run["mat"] == "tray":
			out.append(Vector2(h - 0.06, h + 0.06))
		else:
			out.append(Vector2(h - ro - 0.17, h + ro + 0.04))
	return out

static func _band_free(bands: Array[Vector2], y0: float, y1: float) -> bool:
	for b in bands:
		if y1 > b.x and y0 < b.y:
			return false
	return true

## The pump room's identity wall: two wall pipes from the floor with a valve wheel each and a gauge, a painted
## flow arrow along them.
func _pump_wall(room: Dictionary, side: Dictionary) -> void:
	var sp := _longest(_wall_spans(room, side, WALL_HALF + PROUD_MAX, true))
	if sp.y - sp.x < 1.0:
		return
	var bands := _run_bands(room, side)
	var top := 2.0
	while top > 1.0 and not _band_free(bands, 0.1, top + 0.08):
		top -= 0.05
	var mid := (sp.x + sp.y) * 0.5
	var nv: Vector3 = side["n"]
	for k in 2:
		var s := mid + (k - 0.5) * minf(0.9, sp.y - sp.x - 0.3)
		_begin("wall_pipe", room, "wall", side)
		var r := 0.048
		var pd := WALL_HALF + 0.015 + r
		var a := at_side(side, s, 0.13, pd)
		var b := at_side(side, s, top, pd)
		_cyl("steel", a, b, r, C_STEEL.darkened(0.2), 8, false)
		_cyl("steel", a, a + Vector3.UP * 0.03, r * 1.3, C_DARK, 8)
		_cyl("steel", b - Vector3.UP * 0.03, b, r * 1.3, C_DARK, 8)
		_cyl("steel", b, at_side(side, s, top, WALL_HALF), r, C_STEEL.darkened(0.3), 8, false)
		# The valve: a body on the pipe, its wheel facing the room.
		var vy := minf(1.15, top - 0.3)
		_cyl("steel", at_side(side, s, vy - 0.07, pd), at_side(side, s, vy + 0.07, pd), r * 1.3, C_DARK, 8)
		_ring("flat", at_side(side, s, vy, WALL_HALF + 0.135), nv, 0.11, 0.011, Color(0.55, 0.16, 0.1), 10)
		_cyl("flat", at_side(side, s, vy, WALL_HALF + 0.11), at_side(side, s, vy, WALL_HALF + 0.14), 0.02, C_DARK, 6)
		_end()
		# The gauge on a stub beside it.
		var gy := minf(1.55, top - 0.15)
		if _band_free(bands, gy - 0.09, gy + 0.09) and gy > vy + 0.2:
			_begin("gauge", room, "wall", side)
			var gs := s + 0.16
			var c := at_side(side, gs, gy, WALL_HALF)
			_cyl("steel", at_side(side, s, gy, pd), at_side(side, gs, gy, pd), 0.012, C_DARK, 5, false)
			_cyl("flat", c + nv * 0.02, c + nv * 0.06, 0.07, C_DARK, 10)
			_cyl("flat", c + nv * 0.06, c + nv * 0.064, 0.06, C_PAPER, 10, false)
			var ang := _rng.randf_range(0.3, 2.6)
			var dirn := (side["dir"] as Vector3) * cos(ang) + Vector3.UP * sin(ang)
			_box("flat", Basis(dirn, dirn.cross(nv).normalized(), nv), c + nv * 0.067 + dirn * 0.025, Vector3(0.05, 0.006, 0.003), Color(0.5, 0.08, 0.06))
			_end()
	# The painted flow arrow along the pipes, and its word.
	var ay := 0.72
	_begin("flow_arrow", room, "wall", side)
	var a0 := mid - 0.55
	var a1 := mid + 0.35
	_wpanel("flat", side, a0, a1, ay - 0.035, ay + 0.035, WALL_HALF + 0.002, C_YELLOW)
	var dirv: Vector3 = side["dir"]
	var p := at_side(side, a1, ay, WALL_HALF + 0.002)
	_tri("flat", p + Vector3.UP * 0.09, p - Vector3.UP * 0.09, p + dirv * 0.16, nv, C_YELLOW)
	_text_wall(side, mid - 0.1, ay + 0.13, WALL_HALF + 0.002, "FLOW", 0.022, C_STENCIL)
	_end()

## The pump room's floor: where the pumps stood, each a plinth's outline with its cut-off bolts and capped pipe stubs;
## a drain grate; oil stains.
func _pump_floor(room: Dictionary, ident: int) -> void:
	var rr: Rect2 = room["crect"]
	var sides: Array = room["sides"]
	var side: Dictionary = sides[ident] if ident >= 0 else sides[0]
	var length: float = side["len"]
	var made := 0
	for k in 2:
		var s := length * (0.3 + 0.4 * k) + _rng.randf_range(-0.2, 0.2)
		var dmid := minf(2.0, (rr.size.x if absf((side["n"] as Vector3).x) > 0.5 else rr.size.y) * 0.5)
		var sw := 1.3
		var sd := 0.8
		var p0 := at_side(side, s - sw * 0.5, 0.0, dmid - sd * 0.5)
		var p1 := at_side(side, s + sw * 0.5, 0.0, dmid + sd * 0.5)
		var r := Rect2(Vector2(minf(p0.x, p1.x), minf(p0.z, p1.z)), Vector2(absf(p1.x - p0.x), absf(p1.z - p0.z)))
		if not _floor_ok(room, r.grow(0.1)):
			continue
		made += 1
		_begin("pump_plinth", room, "floor")
		var a := s - sw * 0.5
		var e := s + sw * 0.5
		var d0 := dmid - sd * 0.5
		var d1 := dmid + sd * 0.5
		_fmark(side, a, e, d0, d1, 0.003, Color(0.5, 0.49, 0.46))
		var lw := 0.05
		for edge: Array in [[a, e, d0, d0 + lw], [a, e, d1 - lw, d1], [a, a + lw, d0, d1], [e - lw, e, d0, d1]]:
			_fmark(side, edge[0], edge[1], edge[2], edge[3], 0.005, Color(0.3, 0.29, 0.27))
		var basis := Basis(side["dir"], Vector3.UP, side["n"])
		for c: Vector2 in [Vector2(a + 0.12, d0 + 0.12), Vector2(e - 0.12, d0 + 0.12), Vector2(a + 0.12, d1 - 0.12), Vector2(e - 0.12, d1 - 0.12)]:
			_box("steel", basis, at_side(side, c.x, 0.007, c.y), Vector3(0.035, 0.012, 0.035), C_STEEL.darkened(0.35))
		for st: float in [-0.25, 0.25]:
			var c2 := at_side(side, s + st, 0.0, d1 + 0.22)
			_cyl("steel", c2, c2 + Vector3.UP * 0.012, 0.065, C_STEEL.darkened(0.25), 8)
		# Oil where it stood.
		for i in _rng.randi_range(1, 3):
			var oc := at_side(side, s + _rng.randf_range(-0.5, 0.5), 0.002 + i * 0.0004, dmid + _rng.randf_range(-0.25, 0.25))
			_floor_disc(oc, _rng.randf_range(0.12, 0.3), _rng.randf_range(0.1, 0.22), C_STAIN, 8)
		_end()
	var dc := at_side(side, length * 0.5 + _rng.randf_range(-0.4, 0.4), 0.0, 0.9)
	if _floor_ok(room, Rect2(dc.x - 0.2, dc.z - 0.2, 0.4, 0.4)):
		_begin("drain_grate", room, "floor")
		_drain(side, dc)
		_end()
	counts["plinths"] = int(counts.get("plinths", 0)) + made

## Overhead: a duct and two pipes across the ceiling with valve wheels hanging under them (pumps), or two thin pipes
## (lockers); clear of the battens and the keep points, each on hangers to the ceiling.
func _overhead_pipes(room: Dictionary, wall: int, pumps: bool) -> void:
	var rr: Rect2 = room["crect"]
	var along_z := rr.size.y >= rr.size.x
	var dir := Vector3.BACK if along_z else Vector3.RIGHT
	var lat := Vector3.RIGHT if along_z else Vector3.BACK
	var length := maxf(rr.size.x, rr.size.y)
	var width := minf(rr.size.x, rr.size.y)
	var start := Vector3(rr.get_center().x, 0, rr.get_center().y) - dir * length * 0.5
	var dyl := -0.5 if test_break == "high" else 0.0
	var offs: Array[float] = [-1.0, 1.0, -1.35, 1.35, -0.7, 0.7]
	if wall >= 0:
		var hn: Vector3 = (room["sides"] as Array)[wall]["n"]
		if hn.dot(lat) < -0.5:
			offs = [1.0, -1.0, 1.35, -1.35, 0.7, -0.7]
	var made := 0
	for off in offs:
		if made >= (2 if pumps else 1) or absf(off) > width * 0.5 - 0.45:
			continue
		var o := start + lat * off
		var half := 0.28 if pumps and made == 0 else 0.12
		var sp := _longest(_line_spans(room["keeps"], o, dir, lat, -half, half, 0.12, length - 0.12))
		if sp.y - sp.x < 2.0:
			continue
		var a := o + dir * sp.x
		var b := o + dir * sp.y
		var box := AABB(Vector3(minf(a.x, b.x) - half, 2.8, minf(a.z, b.z) - half), Vector3(absf(b.x - a.x) + half * 2.0, 0.4, absf(b.z - a.z) + half * 2.0))
		if not _clear_of_battens(box):
			continue
		var basis := Basis(dir, Vector3.UP, lat) if along_z else Basis(dir, Vector3.UP, -lat)
		if pumps and made == 0:
			_begin("duct", room, "high")
			var mid := (a + b) * 0.5
			_box("steel", basis, mid + Vector3.UP * (3.02 + dyl), Vector3(sp.y - sp.x, 0.3, 0.5), C_STEEL.darkened(0.1))
			var t := 0.4
			while t < sp.y - sp.x - 0.2:
				_box("steel", basis, a + dir * t + Vector3.UP * (3.02 + dyl), Vector3(0.05, 0.34, 0.54), C_STEEL.darkened(0.35))
				t += 1.2
			_end()
		else:
			_begin("overhead_pipes", room, "high")
			for k in 2:
				var po := lat * ((k - 0.5) * 0.16)
				var y := 2.98 + k * 0.02 + dyl
				_cyl("steel", a + po + Vector3.UP * y, b + po + Vector3.UP * y, 0.045 if pumps else 0.032, C_STEEL.darkened(0.15 + 0.1 * k), 8, false)
			var t := 0.4
			while t < sp.y - sp.x - 0.2:
				var hp := a + dir * t
				_box("steel", basis, hp + Vector3.UP * (3.11 + dyl), Vector3(0.02, 0.18, 0.02), C_DARK)
				_box("steel", basis, hp + Vector3.UP * (2.93 + dyl), Vector3(0.025, 0.02, 0.26), C_DARK)
				t += 1.6
			_end()
			if pumps:
				for i in _rng.randi_range(1, 2):
					var vt := _rng.randf_range(0.6, maxf(0.7, sp.y - sp.x - 0.6))
					var vp := a + dir * vt + lat * 0.08 + Vector3.UP * (3.0 + dyl)
					_begin("valve_wheel", room, "high")
					_cyl("steel", vp, vp - Vector3.UP * 0.2, 0.014, C_DARK, 5, false)
					_cyl("steel", vp - Vector3.UP * 0.04, vp + Vector3.UP * 0.04, 0.07, C_DARK, 8)
					_ring("flat", vp - Vector3.UP * 0.2, Vector3.UP, 0.12, 0.012, Color(0.55, 0.16, 0.1), 10)
					_end()
		made += 1

# --- every room ------------------------------------------------------------------------------------------------

## The entrance's wall: the room's name stencilled over the doorway inside, a switch box with its conduit; and by
## kind, a stock board (stores), a notice board, a mirror and a boot scraper (lockers), a key board, a telephone, a
## calendar and the tannoy horn (office), a grease gun (pumps).
func _entrance(room: Dictionary, side: Dictionary, door_s: float, extras: Dictionary) -> void:
	var kind: String = room["kind"]
	var bands: Array[Vector2] = []
	if kind != "closet":
		bands = _run_bands(room, side)
	if NAMES.has(kind):
		var y := 2.36
		if not _band_free(bands, y - 0.11, y + 0.11):
			y = 2.63
		# Over the doorway, kept on its own wall: smaller lettering when the wall is short.
		var text: String = NAMES[kind]
		var length: float = side["len"]
		var px := minf(0.026, (length - 0.3) / float(Glyphs.width(text)))
		var hw := float(Glyphs.width(text)) * px * 0.5
		var cs := clampf(door_s, 0.15 + hw, length - 0.15 - hw)
		_begin("room_name", room, "over_door", side)
		_text_wall(side, cs, y, WALL_HALF + 0.002, text, px, C_STENCIL)
		_end()
	var under_rack := extras != side
	if under_rack:
		side = extras
		door_s = 0.0
	var spans := _wall_spans(room, side, WALL_HALF + PROUD_MAX, true)
	# Nearest the door first: the switch box and its conduit, then the kind's own pieces.
	var slots: Array[Vector2] = []
	for sp in spans:
		if absf(sp.x - door_s) < absf(sp.y - door_s):
			slots.append(Vector2(sp.x, 1.0))
		else:
			slots.append(Vector2(sp.y, -1.0))
	slots.sort_custom(func(p: Vector2, q: Vector2) -> bool: return absf(p.x - door_s) < absf(q.x - door_s))
	if slots.is_empty():
		return
	var start: Vector2 = slots[0]
	var s := start.x + start.y * 0.12
	var step := start.y
	var sp0: Vector2 = Vector2.ZERO
	for sp in spans:
		if s >= sp.x - 0.01 and s <= sp.y + 0.01:
			sp0 = sp
	var room_left := (sp0.y - s) if step > 0.0 else (s - sp0.x)
	_begin("switch_box", room, "wall", side)
	_wbox("steel", side, s, 1.45, WALL_HALF, 0.11, 0.16, 0.055, C_GREY)
	_wbox("steel", side, s, 1.46, WALL_HALF + 0.055, 0.02, 0.045, 0.02, C_DARK)
	_end()
	_begin("conduit", room, "wall", side)
	_cyl("steel", at_side(side, s, 1.53, WALL_HALF + 0.028), at_side(side, s, LH - 0.04, WALL_HALF + 0.028), 0.014, C_GREY.darkened(0.2), 5, false)
	_end()
	s += step * 0.3
	room_left -= 0.3
	var pieces: Array = []
	match kind:
		"stores": pieces = [["stock", 0.95]]
		"lockers": pieces = [["notices", 0.8], ["mirror", 0.4], ["scraper", 0.55]]
		"office": pieces = [["keys", 0.32], ["phone", 0.24], ["calendar", 0.32], ["tannoy", 0.4]]
		"pumps": pieces = [["grease", 0.4]]
	for pc: Array in pieces:
		var w: float = pc[1]
		if room_left < w + 0.05:
			break
		var a := s if step > 0.0 else s - w
		if under_rack and str(pc[0]) == "tannoy":
			continue
		match str(pc[0]):
			"stock":
				_stock_board(room, side, a, w)
			"notices":
				_board(room, side, a, w, "NOTICES", false)
			"mirror":
				_begin("mirror", room, "wall", side)
				_wbox("flat", side, a + w * 0.5, 1.55, WALL_HALF, w, 0.5, 0.012, C_DARK)
				_wpanel("flat", side, a + 0.02, a + w - 0.02, 1.32, 1.78, WALL_HALF + 0.013, Color(0.52, 0.57, 0.6))
				var c0 := at_side(side, a + w * 0.3, 1.74, WALL_HALF + 0.014)
				var c1 := at_side(side, a + w * 0.62, 1.48, WALL_HALF + 0.014)
				var c2 := at_side(side, a + w * 0.75, 1.36, WALL_HALF + 0.014)
				var nv: Vector3 = side["n"]
				for seg: Array in [[c0, c1], [c1, c2]]:
					var p0: Vector3 = seg[0]
					var p1: Vector3 = seg[1]
					var acr := (p1 - p0).cross(nv).normalized() * 0.0035
					_quad("flat", p0 - acr, p1 - acr, p1 + acr, p0 + acr, nv, Color(0.18, 0.2, 0.22))
				_end()
			"scraper":
				_begin("boot_scraper", room, "wall", side)
				_wbox("steel", side, a + w * 0.5, 0.2, WALL_HALF + 0.06, w, 0.02, 0.05, C_DARK)
				for e: float in [a + 0.03, a + w - 0.03]:
					_wbox("steel", side, e, 0.2, WALL_HALF, 0.03, 0.06, 0.11, C_DARK)
				_end()
			"keys":
				_begin("key_board", room, "wall", side)
				_wbox("flat", side, a + w * 0.5, 1.6, WALL_HALF, w, 0.38, 0.015, C_WOOD)
				_text_wall(side, a + w * 0.5, 1.84, WALL_HALF + 0.002, "KEYS", 0.014, C_STENCIL)
				for j in 3:
					for i in 3:
						var ks := a + 0.07 + i * (w - 0.14) / 2.0
						var ky := 1.72 - j * 0.12
						_wbox("steel", side, ks, ky, WALL_HALF + 0.015, 0.012, 0.012, 0.03, C_DARK)
						if _rng.randf() < 0.45:
							_wbox("steel", side, ks, ky - 0.04, WALL_HALF + 0.03, 0.022, 0.05, 0.004, Color(0.62, 0.55, 0.32))
				_end()
			"phone":
				_begin("telephone", room, "wall", side)
				_wbox("flat", side, a + w * 0.5, 1.45, WALL_HALF, 0.17, 0.24, 0.08, Color(0.22, 0.22, 0.2))
				_wbox("flat", side, a + w * 0.5 - 0.035, 1.47, WALL_HALF + 0.08, 0.05, 0.2, 0.045, Color(0.15, 0.15, 0.14))
				_wbox("flat", side, a + w * 0.5 + 0.045, 1.39, WALL_HALF + 0.08, 0.05, 0.06, 0.01, C_GREY)
				_wbox("flat", side, a + w * 0.5 - 0.035, 1.22, WALL_HALF + 0.03, 0.012, 0.25, 0.012, Color(0.15, 0.15, 0.14))
				_end()
			"calendar":
				_begin("calendar", room, "wall", side)
				_wpanel("flat", side, a, a + w, 1.3, 1.74, WALL_HALF + 0.003, C_PAPER)
				_wpanel("flat", side, a, a + w, 1.64, 1.74, WALL_HALF + 0.004, Color(0.45, 0.14, 0.12))
				for j in 4:
					for i in 5:
						var cs := a + 0.03 + i * (w - 0.06) / 5.0
						var cy := 1.34 + j * 0.07
						_wpanel("flat", side, cs + 0.005, cs + (w - 0.06) / 5.0 - 0.005, cy, cy + 0.055, WALL_HALF + 0.004, C_PAPER.darkened(0.12 + _rng.randf() * 0.08))
				_end()
			"tannoy":
				# High on the wall: a bracket and a horn tipped down into the room, wholly over HIGH_Y.
				_begin("tannoy", room, "high", side)
				var hs := a + w * 0.5
				var nv: Vector3 = side["n"]
				_wbox("steel", side, hs, 2.98, WALL_HALF, 0.1, 0.14, 0.03, C_DARK)
				_wbox("steel", side, hs, 2.96, WALL_HALF + 0.03, 0.03, 0.03, 0.12, C_DARK)
				var root := at_side(side, hs, 2.95, WALL_HALF + 0.15)
				var tip := root + (nv * 0.9 - Vector3.UP * 0.42).normalized() * 0.3
				_cyl("steel", root, tip, 0.04, C_GREY.darkened(0.1), 8, true, 0.12)
				_end()
			"grease":
				_begin("grease_gun", room, "wall", side)
				_wbox("steel", side, a + w * 0.5, 1.2, WALL_HALF, 0.3, 0.05, 0.05, C_DARK)
				var g0 := at_side(side, a + 0.06, 1.27, WALL_HALF + 0.08)
				var g1 := at_side(side, a + 0.32, 1.27, WALL_HALF + 0.08)
				_cyl("steel", g0, g1, 0.036, Color(0.45, 0.4, 0.2), 8)
				_cyl("steel", g1, g1 + (side["dir"] as Vector3) * 0.07, 0.008, C_DARK, 5, false)
				_wbox("steel", side, a + 0.1, 1.33, WALL_HALF + 0.05, 0.03, 0.12, 0.03, C_DARK)
				_end()
		s += step * (w + 0.18)
		room_left -= w + 0.18

## The stores' stock board: a plywood board with its word, rows of tally hooks with a few tags left on them.
func _stock_board(room: Dictionary, side: Dictionary, a: float, w: float) -> void:
	_begin("stock_board", room, "wall", side)
	_wbox("flat", side, a + w * 0.5, 1.6, WALL_HALF, w, 0.62, 0.018, C_WOOD.lightened(0.15))
	var word: String = "FUSE STOCK" if test_break == "word" else "STOCK"
	_text_wall(side, a + w * 0.5, 1.83, WALL_HALF + 0.02, word, 0.02, C_STENCIL)
	for j in 3:
		for i in 6:
			var ks := a + 0.1 + i * (w - 0.2) / 5.0
			var ky := 1.68 - j * 0.15
			_wbox("steel", side, ks, ky, WALL_HALF + 0.018, 0.012, 0.012, 0.035, C_DARK)
			if _rng.randf() < 0.3:
				_wpanel("flat", side, ks - 0.025, ks + 0.025, ky - 0.1, ky - 0.015, WALL_HALF + 0.032, C_PAPER.darkened(_rng.randf() * 0.25))
	_end()

## Wall items for the test break that dresses every wall.
func _wall_items(room: Dictionary, side: Dictionary, _kind: String) -> void:
	var sp := _longest(_wall_spans(room, side, WALL_HALF + PROUD_MAX, true))
	if sp.y - sp.x < 0.5:
		return
	_begin("upright", room, "wall", side)
	_wbox("steel", side, (sp.x + sp.y) * 0.5, 1.2, WALL_HALF, sp.y - sp.x, 1.6, 0.02, C_DARK)
	_end()

# --- meshes ------------------------------------------------------------------------------------------------

## One mesh per material and group (the west wing in bands, the north-east store), drawing only: no collision, no
## shadow, the station's own materials (lit by its lights like the landing's props, so they follow the power).
func _commit() -> void:
	var keys := _geo.keys()
	keys.sort()
	for key: String in keys:
		var g: Geo = _geo[key]
		if g.p.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = g.p
		arr[Mesh.ARRAY_NORMAL] = g.n
		arr[Mesh.ARRAY_COLOR] = g.c
		var uv := PackedVector2Array()
		uv.resize(g.p.size())
		arr[Mesh.ARRAY_TEX_UV] = uv
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mi := MeshInstance3D.new()
		mi.name = "Rooms_" + key.replace("|", "_")
		mi.mesh = mesh
		mi.material_override = _mats[key.get_slice("|", 0)]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	_geo.clear()

## What a check reads.
func check() -> Dictionary:
	var tris := 0
	for c in get_children():
		if c is MeshInstance3D:
			tris += ((c as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return {"pieces": records.size(), "meshes": get_child_count(), "tris": tris, "counts": counts.duplicate()}
