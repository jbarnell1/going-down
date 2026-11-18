# Noise: the Arboretum's one rule change, "the floor is listening" (North Star A2 and B1, the Hearing trait:
# "it comes to footsteps, noise and your real voice"). Pure and deterministic; the host decides every noise and
# it is the same on every screen. sim/hearing.gd listens; sim/run.gd makes the tick's noises from what each
# player did.
#
# Ground has a voice. Every walkable cell of a floor with a Ground has one surface:
#   MOSS    moss and worn path: quiet
#   LITTER  leaf litter: loud
#   GRAVEL  aprons and the main walk: loud, and the only ground that shows in the dark
#   TWIG    a twig fall: litter with pale sticks on it, always under a dead tree. It is litter underfoot, and it
#           cracks once per crossing when walked or sprinted over (never under a creep).
#
# A noise is a place and a radius: anything that listens hears it when it is inside the radius (straight
# distance on the same level; nothing muffles it). One noise per player per tick, the loudest thing they did:
#   stands still, looks around, raises or lowers the instrument      silent
#   creeps on moss                                                   silent
#   creeps on litter, gravel or a twig fall                          CREEP_LOUD   2.5 m
#   walks on moss                                                    WALK_MOSS    3 m
#   walks on litter (a twig fall is litter)                          WALK_LITTER  8 m
#   walks on gravel                                                  WALK_GRAVEL  10 m
#   walks or sprints onto a twig fall                                TWIG         12 m, once per crossing
#   sprints, on anything                                             SPRINT       14 m
#   crawls while down                                                CRAWL        2 m
#   gets into or out of a hide (opens something to search it)        HIDE         4 m
#   drops a tape, is healed back up                                  DROP         6 m
#   a thrown pinecone lands (AR5: not thrown by anything yet)        CONE         12 m, where it lands
#   a sound emote (whistle, clap, shout)                             EMOTE        18 m
# Choices made where the design is silent:
#  - "moves" means the body covered more than MOVING metres a second this tick: a player pressing into a trunk
#    or turning on the spot is standing still.
#  - a gait on ground with no surface (a floor's cell outside its Ground, the lift pavilion's doorway) is
#    gravel: the loud way.
#  - "once per crossing": a fall cracks under a player the first tick they walk or sprint on any of its cells,
#    and not again until they have stood on ground that is not that fall. A creep never cracks it, and creeping
#    onto it and then walking does.
#  - a player in the car makes no noise (the car is the only safe place), nor does one who is out.
# No randomness anywhere: a radius is a fixed number, and a twig fall is drawn where it is.
extends RefCounted

const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")

## Surfaces (Ground.cells). NONE: not ground (thicket, the void, a floor with no Ground).
const NONE := 0
const MOSS := 1
const LITTER := 2
const GRAVEL := 3
const TWIG := 4
const SURFACE_NAMES: Array[String] = ["none", "moss", "litter", "gravel", "twig"]

## The radii, metres (the settings registry lists them: sim/settings.gd "noise.*").
const CREEP_LOUD := 2.5
const WALK_MOSS := 3.0
const WALK_LITTER := 8.0
const WALK_GRAVEL := 10.0
const TWIG_CRACK := 12.0
const SPRINT := 14.0
const CRAWL := 2.0
const HIDE := 4.0
const DROP := 6.0
const CONE := 12.0
const EMOTE := 18.0
## A body is moving when it covers more than this, metres a second.
const MOVING := 0.2

const EPS := 1e-9

## The tests' deliberate break (tests/prop_hearing.gd): "moss_creep" makes a creep on moss as loud as a creep
## on litter.
static var test_break := ""

## A floor's ground: one surface per cell of level 0, and which twig fall (if any) each cell belongs to.
## Made by the place's generator (sim/arboretum.gd) and carried on the plan (FloorPlan.ground). Never edited.
class Ground extends RefCounted:
	var width: int
	var height: int
	var cell_size: float = 2.0
	## Row-major, width * height: a surface code.
	var cells: PackedByteArray = PackedByteArray()
	## Row-major: the id of the twig fall a TWIG cell belongs to (its dead tree's number), else -1.
	var falls: PackedInt32Array = PackedInt32Array()

	static func make(width_: int, height_: int, cell_size_: float = 2.0) -> Ground:
		var g := Ground.new()
		g.width = width_
		g.height = height_
		g.cell_size = cell_size_
		g.cells.resize(width_ * height_)
		g.falls.resize(width_ * height_)
		g.falls.fill(-1)
		return g

	func surface(cx: int, cy: int) -> int:
		if cx < 0 or cy < 0 or cx >= width or cy >= height:
			return NONE
		return cells[cy * width + cx]

	func fall(cx: int, cy: int) -> int:
		if cx < 0 or cy < 0 or cx >= width or cy >= height:
			return -1
		return falls[cy * width + cx]

	func put(cx: int, cy: int, s: int, fall_id: int = -1) -> void:
		cells[cy * width + cx] = s
		falls[cy * width + cx] = fall_id

	## The surface under a point (metres).
	func surface_at(x: float, z: float) -> int:
		return surface(int(floor(x / cell_size)), int(floor(z / cell_size)))

	func fall_at(x: float, z: float) -> int:
		return fall(int(floor(x / cell_size)), int(floor(z / cell_size)))

## One noise.
class Sound extends RefCounted:
	## Who made it (a player id; "" for a thing: a cone).
	var by: String = ""
	var x: float = 0.0
	var z: float = 0.0
	var level: int = 0
	## How far it carries, metres.
	var r: float = 0.0
	## &"creep" | &"walk" | &"twig" | &"sprint" | &"crawl" | &"hide" | &"drop" | &"heal" | &"cone" | &"emote"
	var kind: StringName = &""
	## The hide a &"hide" noise came from, else -1.
	var hide: int = -1
	## Host time it was made.
	var t: float = 0.0

	static func make(by_: String, x_: float, z_: float, level_: int, r_: float, kind_: StringName) -> Sound:
		var s := Sound.new()
		s.by = by_
		s.x = x_
		s.z = z_
		s.level = level_
		s.r = r_
		s.kind = kind_
		return s

	func plain() -> Dictionary:
		return {"by": by, "x": x, "z": z, "level": level, "r": r, "kind": String(kind), "hide": hide}

## What one player did this tick, as the noise table needs it.
class Act extends RefCounted:
	var id: String
	## Where they are now, and where they were on the tick before (null: unknown, so standing).
	var body: Move.Body
	var from: Move.Body = null
	## &"creep" | &"walk" | &"sprint" (the gait the host allowed).
	var gait: StringName = &"walk"
	## Down and crawling.
	var down: bool = false
	## A sound emote this tick.
	var emote: bool = false
	## Got into or out of a hide this tick: its id, else -1.
	var hide: int = -1
	## Healed back onto their feet this tick.
	var healed: bool = false

	static func make(id_: String, body_: Move.Body, from_: Move.Body, gait_: StringName) -> Act:
		var a := Act.new()
		a.id = id_
		a.body = body_
		a.from = from_
		a.gait = gait_
		return a

## The radius of a gait on a surface (0: silent). `s` NONE reads as gravel.
static func gait_radius(gait: StringName, s: int) -> float:
	if gait == &"sprint":
		return SPRINT
	var moss := s == MOSS
	if gait == &"creep":
		return CREEP_LOUD if (not moss or test_break == "moss_creep") else 0.0
	if moss:
		return WALK_MOSS
	return WALK_GRAVEL if (s == GRAVEL or s == NONE) else WALK_LITTER

## How fast `a` covered ground this tick, metres a second.
static func ground_speed(a: Act, dt: float) -> float:
	if a.from == null or a.from.level != a.body.level or dt <= 0.0:
		return 0.0
	return M.hypot2(a.body.x - a.from.x, a.body.z - a.from.z) / dt

## The one noise player `a` makes this tick (the loudest thing they did), or null for silence. `cracked` is
## the caller's memory of twig falls, {player id: the fall that has cracked under them this crossing}; it is
## updated here (pass the copy you keep).
static func of(ground: Ground, a: Act, dt: float, cracked: Dictionary) -> Sound:
	var s := ground.surface_at(a.body.x, a.body.z) if ground != null else NONE
	var moving := ground_speed(a, dt) > MOVING
	var r := 0.0
	var kind := &""
	if a.down:
		if moving:
			r = CRAWL
			kind = &"crawl"
	elif moving:
		r = gait_radius(a.gait, s)
		kind = a.gait
	# The twig fall under them: a crack, once per crossing, under a walk or a sprint.
	var fall := ground.fall_at(a.body.x, a.body.z) if ground != null else -1
	if fall < 0:
		cracked.erase(a.id)
	elif moving and not a.down and a.gait != &"creep" and int(cracked.get(a.id, -1)) != fall:
		cracked[a.id] = fall
		if TWIG_CRACK > r:
			r = TWIG_CRACK
			kind = &"twig"
	var hide := -1
	if a.hide >= 0 and HIDE > r:
		r = HIDE
		kind = &"hide"
		hide = a.hide
	if a.healed and DROP > r:
		r = DROP
		kind = &"heal"
		hide = -1
	if a.emote and EMOTE > r:
		r = EMOTE
		kind = &"emote"
		hide = -1
	if r <= 0.0:
		return null
	var out := Sound.make(a.id, a.body.x, a.body.z, a.body.level, r, kind)
	out.hide = hide
	return out

## A tape hitting the floor at `at`, dropped by `by`.
static func drop(by: String, at: Move.Body) -> Sound:
	return Sound.make(by, at.x, at.z, at.level, DROP, &"drop")

## A pinecone landing (AR5 throws them).
static func cone(x: float, z: float, level: int) -> Sound:
	return Sound.make("", x, z, level, CONE, &"cone")

## Whether a listener at (x, z) on `level` hears `n`.
static func heard_at(n: Sound, x: float, z: float, level: int) -> bool:
	return n.level == level and M.hypot2(n.x - x, n.z - z) <= n.r + EPS

## Of several noises, the one a listener at (x, z) goes for: the louder; equal, the nearer; equal, the lower
## maker id. Null for none.
static func pick(list: Array[Sound], x: float, z: float) -> Sound:
	var best: Sound = null
	var best_d := 0.0
	for n in list:
		var d := M.hypot2(n.x - x, n.z - z)
		if best == null or n.r > best.r + EPS or (absf(n.r - best.r) <= EPS and (d < best_d - EPS or (absf(d - best_d) <= EPS and n.by < best.by))):
			best = n
			best_d = d
	return best
