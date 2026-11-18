# Things to find (docs/floors/findables-and-day.md section 3, FD8; story.md section 4a, ST4). Pure functions of
# the plan, the seed and the depth, like the hide and furniture lists, so the host and every client hold the
# same answers with nothing new on the plan; and the search itself, a small state machine sim/run.gd steps.
#
# WHICH PIECES (mark_searchable, spots_for). sim/furniture.gd's one list owns every floor-standing piece; this
# file decides which of them can be searched and furniture.gd sets their `searchable` flag from it. A
# searchable piece is a plain piece (never a hide, so F never means two things at one piece) of a kind in
# SEARCHABLE for its room, never in the lobby, never on a cell LANDING_STEPS or fewer steps from the landing,
# and with its footprint at least HIDE_CLEAR from the front spot of every hide in its room (a hide in another room
# or the corridor is behind a wall, and a search is only ever of a piece in the searcher's own room; counting those
# would make same-shaped Annex rooms differ).
#   The Clinic: gurneys (exam rooms, the atrium), low drawers (exam rooms, closets, the nurses' station), the
#   wards' bedside lockers (the side tables). The seed (Rng "find:<seed>:<depth>", fork "spots") picks how many
#   between CLINIC_MIN and CLINIC_MAX, keeping the furthest from the lift (by walking) first.
#   The Annex: filing drawers (one in every office, two in the cubicles, one in every closet), the copier
#   (one a copy room), a box on the shelf (one in every store: the copy suites' stores). By room kind and the
#   list's order only, with no seed: the furniture is already the same in same-shaped rooms, so is this.
#   Choice: the design's "meeting-room closets" and "the break room's closet" become every closet's filing
#   drawer, so a closet's pieces never depend on its neighbours and same-shaped rooms stay alike.
#   Choice: the Annex's desk drawers are not searchable. A desk is a hide, and the rules take F (hide_use)
#   at a desk's kneehole to mean "get under it", so a drawer there would make F mean two things.
#   The Playroom's findables (FD11) wait behind PLAYROOM_ON.
#
# WHAT IS INSIDE (fill_for). One fill per floor (Rng "find:<seed>:<depth>", fork "fill"): NOTES poem notes
# (one among the third of the pieces nearest the lift by walking, two anywhere), CARTONS cartons of juice (at
# least FAR_STEPS from the landing), credits in the place's CREDIT_SHARE of the pieces (rounded), one lore page
# in place of an empty piece at least FAR_STEPS from the landing (story.md 4a: by place and the day's tier,
# never by trait; a piece of the page's own kind when one is free; none repeated in a night while another
# of that place and tier is unused: `lore_used`), and nothing in the rest.
#   Credits come in units: one unit is 1% of the floor's quota as set on arrival (`base`), rounded down,
#   at least 1 credit. A piece holds 1 unit in the nearest third by walking, 2 in the middle, 3 in the
#   furthest, and SIDE_BONUS more in a side branch (a room off the main route, one door in).
#   The three notes are three different poems of the floor's trait (trait_for: the resident's trait in this
#   run, Lonely on the Annex when the run has it), in an order the seed picks.
#   The rules hold ids and numbers only (POEMS, PAGES: the server's export carries no data files); the words
#   are in data/poems.json, which every client has (note_lines, note_text).
#
# THE SEARCH (step). Stand within REACH of a searchable piece's footprint, in its room, facing it (within
# FACE_DEG of its centre), and hold F (PlayerInput.search):
#   careful  SEARCH_SLOW seconds, silent. Letting go, moving more than STILL from where it began, or no
#            longer being able (down, caught, in a hide, in the car, sprinting, gone) stops it ("searchStop"
#            {why}) and opens nothing.
#   rushed   F with sprint held (search_fast): SEARCH_FAST seconds, loud ("searchNoise" as it starts), half the
#            credits rounded down. Letting go or moving does not stop it; not being able does.
# A player must let go of F between two searches. Each piece is opened once, by anyone, for everyone: two
# searching one piece, the first to finish opens it, the other's search stops ("taken") with nothing.
# Events: "searchStart" {playerId, piece, kind, fast, from, done}, "searchStop" {playerId, piece, why},
# "searchNoise" {playerId, piece, at}, "searchDone" {playerId, piece, kind, what, credits, note, fast}; what is
# one of WHAT. sim/run.gd does the rest (the rooted body, the instrument away, not a watcher, the found credits
# on the finder's tape and the day's earned, the carton on the player).
# Whole-number maths for the pieces (centimetres); no engine randomness.
extends RefCounted

@warning_ignore_start("integer_division")

const Rng = preload("res://sim/rng.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Hides = preload("res://sim/hides.gd")
const Furniture = preload("res://sim/furniture.gd")
const Entity = preload("res://sim/entity.gd")
const Lonely = preload("res://sim/lonely.gd")
const Seek = preload("res://sim/seek.gd")
const Playroom = preload("res://sim/playroom.gd")
const M = preload("res://sim/jsmath.gd")

const CM := 200
## Searching: the body's centre within this of the piece's footprint (cm), facing it within FACE_DEG.
const REACH := 120
const FACE_DEG := 60.0
## A searchable piece's footprint is at least this far from every hide's front spot (cm).
const HIDE_CLEAR := 120
## No searchable piece on a cell this many steps or fewer from the landing.
const LANDING_STEPS := 3
## The Clinic keeps between these many pieces, the furthest from the lift first.
const CLINIC_MIN := 18
const CLINIC_MAX := 30
## A floor's notes and cartons, the pieces with credits (in every ten, rounded), the side-branch bonus (units).
const NOTES := 3
const CARTONS := 3
const SIDE_BONUS := 2
## The share of a floor's pieces holding credits, by place, rounded (the design's three in ten, cut on 18 Nov so a
## search mostly finds nothing: about 18% of the floor quota hidden on a Clinic, 35% on an Annex).
const CREDIT_SHARE := {&"clinic": 0.22, &"annex": 0.16, &"playroom": 0.2}
## Cartons and the lore page lie at least this many steps from the landing.
const FAR_STEPS := 10
## The careful search and the rushed one (seconds); a careful search stops if its searcher moves this far (m).
const SEARCH_SLOW := 2.5
const SEARCH_FAST := 0.8
const STILL := 0.15
## The Playroom's findables (FD11): off until the owner has played the Playroom as it stands.
const PLAYROOM_ON := false
const EPS := 1e-9

## What a search finds.
const WHAT: Array[String] = ["nothing", "credits", "note", "page", "juice"]
## The item a carton is (sim/run.gd keeps {item: count} per player for the inventory to come).
const JUICE := &"juice"

## Searchable kinds by place and room kind, each with how many of that kind a room keeps (0: every one), the
## first in the list's order (on the Annex the list's order is the room shape's canonical order).
const SEARCHABLE := {
	&"clinic": {
		&"exam": {&"gurney": 0, &"drawers_low": 0}, &"atrium": {&"gurney": 0}, &"closet": {&"drawers_low": 0},
		&"station": {&"drawers_low": 2}, &"ward": {&"side_table": 0},
	},
	&"annex": {
		&"office": {&"filing": 1}, &"cubicles": {&"filing": 2}, &"closet": {&"filing": 1}, &"copy": {&"copier": 1},
		&"store": {&"boxes": 1},
	},
}
## The prompt for each searchable kind (section 3's tables, as the pixel font prints them).
const PROMPTS := {
	&"gurney": "F  CHECK GURNEY",
	&"drawers_low": "F  OPEN DRAWER",
	&"side_table": "F  CHECK LOCKER",
	&"filing": "F  OPEN FILING DRAWER",
	&"copier": "F  LIFT COPIER LID",
	&"boxes": "F  CHECK BOX",
}
## The prompt's second line: the trade a rushed search makes.
const RUSH_PROMPT := "SHIFT+F  RIFLE IT. FAST. LOUD. HALF THE CREDITS."
## On an opened piece holding a note or a page: anyone may read it again there.
const READ_PROMPT := "F  READ NOTE"

## Each trait's three poems (data/poems.json has their lines and pins).
const POEMS := {
	&"stillness": ["stillness-1", "stillness-2", "stillness-3"],
	&"lonely": ["lonely-1", "lonely-2", "lonely-3"],
	&"hearing": ["hearing-1", "hearing-2", "hearing-3"],
}
## The lore pages dealt from drawers (story.md 4a, those marked for Friday): [id, place, tier, kind found in].
## The prison's (J1, J2) are on its walls, never in a drawer; the rest of the table is LATER (in the data, not
## dealt).
const PAGES: Array = [
	["C1", &"clinic", 1, &"side_table"], ["C2", &"clinic", 2, &"gurney"], ["C3", &"clinic", 1, &"drawers_low"],
	["A1", &"annex", 1, &"filing"], ["A2", &"annex", 2, &"filing"], ["A3", &"annex", 3, &"copier"],
	["P1", &"playroom", 1, &"party_bag"], ["P2", &"playroom", 2, &"lunch_box"],
]
const DATA_PATH := "res://data/poems.json"

## The tests' deliberate breaks (tests/prop_findables.gd, tests/prop_search.gd): "from_place" draws the notes
## from the place's own resident, not the run's trait; "pin" reports Lonely's company distance as 9 m, as if
## the constant had been tuned without its poem; "floor_earned" counts found credits on the floor quota;
## "careful_noise" makes the careful search loud.
static var test_break := ""

# ---------------------------------------------------------------------------------------------
# Which pieces.

## Whether the place has findables at all.
static func place_on(place: StringName) -> bool:
	return place == &"clinic" or place == &"annex" or (PLAYROOM_ON and place == &"playroom")

## Sets `searchable` on the pieces of `pieces` (sim/furniture.gd's list for this plan) that can be searched.
## `hides`: the floor's hides (Hides.hides_for), or null to make them.
static func mark_searchable(plan: Floor.FloorPlan, pieces: Array, floor_seed: String, depth: int, hides_given: Variant = null) -> void:
	for p: Furniture.Piece in pieces:
		p.searchable = false
	if not SEARCHABLE.has(plan.place) or not place_on(plan.place):
		return
	var by_room_kind: Dictionary = SEARCHABLE[plan.place]
	var hides: Array = hides_given if hides_given != null else Hides.hides_for(plan, floor_seed)
	var rooms := {}
	for r in plan.rooms:
		rooms[r.id] = r
	var dist := Floor.distances_from(plan, plan.landing)
	var cands: Array = []
	var kept := {}
	for p: Furniture.Piece in pieces:
		if p.hide >= 0:
			continue
		var room: Floor.Room = rooms.get(p.room)
		if room == null or room.kind == &"lobby" or not by_room_kind.has(room.kind) or not (by_room_kind[room.kind] as Dictionary).has(p.kind):
			continue
		var cap: int = by_room_kind[room.kind][p.kind]
		var key := "%d:%s" % [room.id, p.kind]
		var steps := _steps(plan, dist, p)
		if steps <= LANDING_STEPS:
			continue
		var near := false
		for h: Playroom.Hide in hides:
			if h.level == p.level and h.room == p.room and Furniture.gap2(Rect2i(h.front.x, h.front.y, 0, 0), p.foot) < HIDE_CLEAR * HIDE_CLEAR:
				near = true
				break
		if near or (cap > 0 and int(kept.get(key, 0)) >= cap):
			continue
		kept[key] = int(kept.get(key, 0)) + 1
		cands.append([steps, p])
	if plan.place == &"clinic":
		# The furthest from the lift first (ties by id), as many as the seed says.
		cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] or (a[0] == b[0] and (a[1] as Furniture.Piece).id < (b[1] as Furniture.Piece).id))
		var n := Rng.make_rng("find:%s:%d" % [floor_seed, depth]).fork("spots").int_in(CLINIC_MIN, CLINIC_MAX)
		cands = cands.slice(0, mini(n, cands.size()))
	for c: Array in cands:
		(c[1] as Furniture.Piece).searchable = true

## Steps by walking from the landing to the cell under the piece's centre (-1: unreachable).
static func _steps(plan: Floor.FloorPlan, dist: PackedInt32Array, p: Furniture.Piece) -> int:
	var cx := p.x / CM
	var cy := p.y / CM
	if cx < 0 or cy < 0 or cx >= plan.width or cy >= plan.height:
		return -1
	return dist[Floor.pos_index(plan, Floor.Pos.make(p.level, cx, cy))]

## The floor's searchable pieces, in id order. `floor_seed` "" means plan.seed; `depth` -1 means plan.depth.
## Kept for the last 16 plans (a plan is never edited once made).
static func spots_for(plan: Floor.FloorPlan, floor_seed: String = "", depth: int = -1) -> Array[Furniture.Piece]:
	var key := "%s/%d" % [floor_seed if floor_seed != "" else plan.seed, depth if depth >= 0 else plan.depth]
	var kept: Variant = _spots.get(plan)
	if kept != null and kept[0] == key:
		return kept[1]
	var out: Array[Furniture.Piece] = []
	for p in Furniture.pieces_for(plan, floor_seed, depth):
		if p.searchable:
			out.append(p)
	if not _spots.has(plan):
		_spot_order.append(plan)
		if _spot_order.size() > 16:
			_spots.erase(_spot_order.pop_front())
	_spots[plan] = [key, out]
	return out

static var _spots := {}
static var _spot_order: Array = []

## What F says at a piece of this kind.
static func prompt_for(kind: StringName) -> String:
	return PROMPTS.get(kind, "F  SEARCH")

# ---------------------------------------------------------------------------------------------
# What is inside.

## The trait the floor's notes are drawn from: its resident's trait in this run (Places.resident_in, so the
## Annex is Lonely when the run has Lonely on). Traits that re-roll (traits-and-hiding.md section 3) will
## change this one function.
static func trait_for(place: StringName, lonely: bool) -> StringName:
	if test_break == "from_place":
		# The deliberate break: the place's own resident, whatever the run's trait.
		return Places.resident(place).trait_name
	return Places.resident_in(place, lonely).trait_name

## trait_for at a depth of a run's deck.
static func trait_at(seed: String, depth: int, deck: Array, lonely: bool) -> StringName:
	return trait_for(Places.place_at(seed, depth, deck), lonely)

class Fill:
	var place: StringName
	var trait_name: StringName
	## The floor's quota as set on arrival, and one unit of credits (1% of it, at least 1).
	var base := 0
	var unit := 1
	## The searchable pieces' ids, in id order.
	var pieces: Array[int] = []
	## piece id -> {"what": one of WHAT, "credits": int, "note": the note's or page's id or "", "units": int,
	## "steps": int}.
	var contents := {}
	## How many of each (the sheet's numbers).
	var notes := 0
	var cartons := 0
	var credit_pieces := 0
	var credits := 0
	var pages := 0
	## The page dealt ("" for none).
	var page := ""

## The fill of a floor (see the header). `base`: the floor's quota as set on arrival; `trait_name`: trait_for's;
## `day`: the day number (the pages' tier); `lore_used`: page ids already dealt tonight.
static func fill_for(plan: Floor.FloorPlan, floor_seed: String, depth: int, base: int, trait_name: StringName, day: int = 1, lore_used: Array = []) -> Fill:
	var f := Fill.new()
	f.place = plan.place
	f.trait_name = trait_name
	f.base = base
	f.unit = maxi(1, base / 100)
	var spots := spots_for(plan, floor_seed, depth)
	var n := spots.size()
	if n == 0:
		return f
	var rooms := {}
	for r in plan.rooms:
		rooms[r.id] = r
	var dist := Floor.distances_from(plan, plan.landing)
	var steps := {}
	var by_walk: Array = []
	for p in spots:
		f.pieces.append(p.id)
		steps[p.id] = _steps(plan, dist, p)
		by_walk.append(p)
	by_walk.sort_custom(func(a: Furniture.Piece, b: Furniture.Piece) -> bool: return steps[a.id] < steps[b.id] or (steps[a.id] == steps[b.id] and a.id < b.id))
	var third := {}
	var kind_of := {}
	for i in n:
		var p: Furniture.Piece = by_walk[i]
		third[p.id] = i * 3 / n
		kind_of[p.id] = p.kind
		var room: Floor.Room = rooms.get(p.room)
		var units: int = int(third[p.id]) + 1 + (SIDE_BONUS if room != null and room.branch == &"side" else 0)
		f.contents[p.id] = {"what": "nothing", "credits": 0, "note": "", "units": units, "steps": steps[p.id]}
	var rng := Rng.make_rng("find:%s:%d" % [floor_seed, depth]).fork("fill")
	var free: Array = f.pieces.duplicate()
	# Notes: one in the nearest third, two anywhere.
	var poems: Array = POEMS.get(trait_name, []).duplicate()
	var order: Array = []
	while not poems.is_empty():
		order.append(poems.pop_at(rng.int_in(0, poems.size() - 1)))
	var note_pieces: Array = []
	var near: Array = free.filter(func(id: int) -> bool: return int(third[id]) == 0)
	if not order.is_empty():
		for k in NOTES:
			var pool: Array = near if k == 0 else free
			if pool.is_empty():
				pool = free
			if pool.is_empty():
				break
			var id: int = pool[rng.int_in(0, pool.size() - 1)]
			free.erase(id)
			near.erase(id)
			note_pieces.append(id)
	for k in note_pieces.size():
		var c: Dictionary = f.contents[note_pieces[k]]
		c["what"] = "note"
		c["note"] = order[k % order.size()]
		f.notes += 1
	# Cartons: at least FAR_STEPS from the landing (the furthest free pieces if too few are).
	for k in CARTONS:
		var far: Array = free.filter(func(id: int) -> bool: return int(steps[id]) >= FAR_STEPS)
		if far.is_empty():
			far = free.duplicate()
			far.sort_custom(func(a: int, b: int) -> bool: return steps[a] > steps[b] or (steps[a] == steps[b] and a < b))
			far = far.slice(0, 1)
		if far.is_empty():
			break
		var id: int = far[rng.int_in(0, far.size() - 1)]
		free.erase(id)
		f.contents[id]["what"] = "juice"
		f.cartons += 1
	# Credits: the place's share of the pieces, rounded.
	var want := mini(credit_pieces(plan.place, n), free.size())
	for k in want:
		var id: int = free[rng.int_in(0, free.size() - 1)]
		free.erase(id)
		var c: Dictionary = f.contents[id]
		c["what"] = "credits"
		c["credits"] = int(c["units"]) * f.unit
		f.credit_pieces += 1
		f.credits += int(c["credits"])
	# One lore page, in place of an empty piece: by place and the day's tier, never by trait.
	var eligible: Array = []
	for pg: Array in PAGES:
		if pg[1] == plan.place and int(pg[2]) <= maxi(1, day):
			eligible.append(pg)
	var unused: Array = eligible.filter(func(pg: Array) -> bool: return not lore_used.has(pg[0]))
	if unused.is_empty():
		unused = eligible
	var spots_far: Array = free.filter(func(id: int) -> bool: return int(steps[id]) >= FAR_STEPS)
	if not unused.is_empty() and not spots_far.is_empty():
		var pg: Array = unused[rng.int_in(0, unused.size() - 1)]
		var own: Array = spots_far.filter(func(id: int) -> bool: return kind_of[id] == pg[3])
		var pool: Array = own if not own.is_empty() else spots_far
		var id: int = pool[rng.int_in(0, pool.size() - 1)]
		free.erase(id)
		f.contents[id]["what"] = "page"
		f.contents[id]["note"] = pg[0]
		f.pages = 1
		f.page = pg[0]
	return f

## How many of a floor's `n` searchable pieces hold credits (CREDIT_SHARE, rounded).
static func credit_pieces(place: StringName, n: int) -> int:
	return roundi(n * float(CREDIT_SHARE.get(place, 0.2)))

## The laminated sheet by the lobby doors (and the monitor's fourth row on the ride down): the fill's numbers.
static func sheet_text(f: Fill) -> String:
	return "PLACES TO LOOK: %d. CREDITS IN %d. A DRINK IN %d. A NOTE IN %d.%s CREDITS HIDDEN: %d." % [
		f.pieces.size(), f.credit_pieces, f.cartons, f.notes, " A PAGE IN 1." if f.pages > 0 else "", f.credits]

## The line shown for 2 s when a search ends (section 3): its result as the screen words it.
static func result_line(what: String, credits: int) -> String:
	match what:
		"credits":
			return "CREDITS +%d" % credits
		"juice":
			return "A CARTON OF JUICE"
		"page":
			return "SOMEBODY'S PAGE"
		"note":
			return "A NOTE"
	return "NOTHING"

# ---------------------------------------------------------------------------------------------
# The words (data/poems.json), for the screens.

static var _data: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if parsed is Dictionary:
			_data = parsed
		else:
			push_error("poems.json did not parse")
	return _data

static func _entry(id: String) -> Dictionary:
	for k: String in ["poems", "pages"]:
		for e: Dictionary in data().get(k, []):
			if str(e.get("id", "")) == id:
				return e
	return {}

## Whether a note id is a poem (a torn page) rather than a lore page (somebody's own paper).
static func is_poem(id: String) -> bool:
	return _entry(id).has("lines")

## A poem's lines, or a page's text as one line; empty for an unknown id.
static func note_lines(id: String) -> PackedStringArray:
	var e := _entry(id)
	if e.has("lines"):
		return PackedStringArray(e["lines"])
	if e.has("text"):
		return PackedStringArray([str(e["text"])])
	return PackedStringArray()

static func note_text(id: String) -> String:
	return "\n".join(note_lines(id))

## The rule numbers today, by pin name (data/poems.json pins): a poem's pin must equal its number here.
static func rule_values() -> Dictionary:
	return {
		"watch_need": [Entity.watch_need(1), Entity.watch_need(2), Entity.watch_need(3)],
		"watch_crew": Entity.WATCH_CREW,
		"company_near": 9.0 if test_break == "pin" else Lonely.COMPANY_NEAR,
		"company_line": Lonely.COMPANY_LINE,
		"chase_speed": Lonely.CHASE_SPEED,
		"hide_time": Seek.HIDE_TIME,
		"walk_drain": Seek.WALK_DRAIN,
		"rest_gain": Seek.REST_GAIN,
	}

# ---------------------------------------------------------------------------------------------
# The search.

class Search:
	var id: String
	var piece: int
	var fast := false
	## Host times it began and ends.
	var from := 0.0
	var done := 0.0
	## Where the searcher stands: rooted here.
	var spot: Move.Body

## One floor's findables in a run. Replaced, never edited, once in a RunState (copy() first).
class FindFloor:
	var plan: Floor.FloorPlan
	var depth := 0
	## The searchable pieces (Furniture pieces), by id, and in id order.
	var by_id := {}
	var pieces: Array[Furniture.Piece] = []
	var fill: Fill
	## piece id -> what was found there {piece, by, kind, what, credits, note, fast, t}. Never edited once put.
	var opened := {}
	## player id -> their Search under way.
	var searches := {}
	## Players who must let go of F before they search again.
	var wait_release := {}

	func copy() -> FindFloor:
		var f := FindFloor.new()
		f.plan = plan
		f.depth = depth
		f.by_id = by_id
		f.pieces = pieces
		f.fill = fill
		f.opened = opened.duplicate()
		f.searches = searches.duplicate()
		f.wait_release = wait_release.duplicate()
		return f

static func start_floor(plan: Floor.FloorPlan, floor_seed: String, depth: int, base: int, trait_name: StringName, day: int, lore_used: Array) -> FindFloor:
	var f := FindFloor.new()
	f.plan = plan
	f.depth = depth
	f.pieces = spots_for(plan, floor_seed, depth)
	for p in f.pieces:
		f.by_id[p.id] = p
	f.fill = fill_for(plan, floor_seed, depth, base, trait_name, day, lore_used)
	return f

class SearchInput:
	var id: String
	var body: Move.Body
	var yaw := 0.0
	## F held for a search, and sprint held with it (the rushed search).
	var held := false
	var fast := false
	## On their feet, active, out of the car and out of any hide, not sprinting.
	var able := false

	static func make(id_: String, body_: Move.Body, yaw_: float, held_: bool, fast_: bool, able_: bool) -> SearchInput:
		var i := SearchInput.new()
		i.id = id_
		i.body = body_
		i.yaw = yaw_
		i.held = held_
		i.fast = fast_
		i.able = able_
		return i

class SearchStep:
	var floor: FindFloor
	var events: Array[Dictionary] = []
	## What this tick's finished searches found (the opened rows).
	var found: Array[Dictionary] = []
	## Who started a rushed search this tick (its noise).
	var noisy: Array[String] = []

## The unopened searchable piece a body at `body` facing `yaw` would search, or null: in its room, its
## footprint within REACH of the body's centre, its centre within FACE_DEG of the facing; the nearest first.
static func piece_in_reach(f: FindFloor, body: Move.Body, yaw: float) -> Furniture.Piece:
	if body == null:
		return null
	var plan := f.plan
	var cx := floori(body.x / plan.cell_size)
	var cy := floori(body.z / plan.cell_size)
	if cx < 0 or cy < 0 or cx >= plan.width or cy >= plan.height:
		return null
	var room := Floor.room_id_at(plan, body.level, cx, cy)
	if room < 0:
		return null
	var bx := roundi(body.x * 100.0)
	var bz := roundi(body.z * 100.0)
	var fx := -M.sin_js(yaw)
	var fz := -M.cos_js(yaw)
	var cos_max := M.cos_js(deg_to_rad(FACE_DEG))
	var best: Furniture.Piece = null
	var best_g := 0
	for p in f.pieces:
		if p.level != body.level or p.room != room or f.opened.has(p.id):
			continue
		var g := Furniture.gap2(Rect2i(bx, bz, 0, 0), p.foot)
		if g > REACH * REACH:
			continue
		var dx := p.x / 100.0 - body.x
		var dz := p.y / 100.0 - body.z
		var d := M.hypot2(dx, dz)
		if d > EPS and (dx * fx + dz * fz) / d < cos_max:
			continue
		if best == null or g < best_g:
			best = p
			best_g = g
	return best

static func _moved(a: Move.Body, b: Move.Body) -> bool:
	return a.level != b.level or M.hypot2(a.x - b.x, a.z - b.z) > STILL + EPS

## One tick of searching at host time `t`, for every player the run has (those without a search and not
## holding F do nothing). Never mutates `prev`.
static func step(prev: FindFloor, inputs: Array[SearchInput], t: float) -> SearchStep:
	var f := prev.copy()
	var res := SearchStep.new()
	res.floor = f
	for inp in inputs:
		if not inp.held:
			f.wait_release.erase(inp.id)
		var s: Search = f.searches.get(inp.id)
		if s != null:
			var why := ""
			if not inp.able:
				why = "interrupted"
			elif f.opened.has(s.piece):
				why = "taken"
			elif not s.fast and not inp.held:
				why = "let_go"
			elif not s.fast and inp.body != null and _moved(inp.body, s.spot):
				why = "moved"
			if why != "":
				f.searches.erase(inp.id)
				if inp.held:
					f.wait_release[inp.id] = true
				res.events.append({"type": "searchStop", "t": t, "playerId": inp.id, "piece": s.piece, "why": why})
				continue
			if t >= s.done - EPS:
				var row := _open(f, s, t)
				f.searches.erase(inp.id)
				if inp.held:
					f.wait_release[inp.id] = true
				res.found.append(row)
				res.events.append({"type": "searchDone", "t": t, "playerId": inp.id, "piece": s.piece, "kind": row["kind"], "what": row["what"],
					"credits": row["credits"], "note": row["note"], "fast": s.fast})
			continue
		if not inp.held or not inp.able or f.wait_release.has(inp.id):
			continue
		var p := piece_in_reach(f, inp.body, inp.yaw)
		if p == null:
			continue
		var ns := Search.new()
		ns.id = inp.id
		ns.piece = p.id
		ns.fast = inp.fast
		ns.from = t
		ns.done = t + (SEARCH_FAST if inp.fast else SEARCH_SLOW)
		ns.spot = inp.body
		f.searches[inp.id] = ns
		res.events.append({"type": "searchStart", "t": t, "playerId": inp.id, "piece": p.id, "kind": String(p.kind), "fast": ns.fast, "from": ns.from, "done": ns.done})
		if ns.fast or test_break == "careful_noise":
			res.noisy.append(inp.id)
			res.events.append({"type": "searchNoise", "t": t, "playerId": inp.id, "piece": p.id, "at": inp.body})
	return res

## Opens the piece of a finished search: what the fill put there (half the credits, rounded down, rushed).
static func _open(f: FindFloor, s: Search, t: float) -> Dictionary:
	var c: Dictionary = f.fill.contents.get(s.piece, {"what": "nothing", "credits": 0, "note": ""})
	var what := str(c["what"])
	var credits := int(c["credits"])
	if s.fast:
		credits = credits / 2
	if what == "credits" and credits <= 0:
		what = "nothing"
	if what != "credits":
		credits = 0
	var p: Furniture.Piece = f.by_id.get(s.piece)
	var row := {"piece": s.piece, "by": s.id, "kind": String(p.kind) if p != null else "", "what": what, "credits": credits,
		"note": str(c["note"]) if (what == "note" or what == "page") else "", "fast": s.fast, "t": t}
	f.opened[s.piece] = row
	return row

## Whether a player is searching on this floor.
static func searching(f: FindFloor, id: String) -> bool:
	return f != null and f.searches.has(id)

## The rows of what has been opened, in piece order (the snapshot's list).
static func opened_rows(f: FindFloor) -> Array:
	var out: Array = []
	if f == null:
		return out
	var ids: Array = f.opened.keys()
	ids.sort()
	for id: int in ids:
		out.append(f.opened[id])
	return out
