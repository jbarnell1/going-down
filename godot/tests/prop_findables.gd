# Things to find: which pieces, what is inside, the poems and pages (docs/floors/findables-and-day.md section 3
# and FD8; story.md 4a; sim/findables.gd, data/poems.json). Over 800 Clinics and 800 Annexes (seed-0..199 at
# depths 1 to 4; the quick set seed-0..9, 40 of each):
#   1. where: 18 to 30 searchable pieces in a Clinic; on both, every one a plain piece of a searchable kind for
#      its room, never a hide, never within 1.2 m of the front spot of a hide in its room, never in the lobby, never within 3
#      steps of the landing; sim/furniture.gd's list carries the same flags;
#   2. inside: exactly 3 notes (one in the nearest third by walking), 3 cartons (10 steps or more from the
#      landing), credits in the place's share of the pieces (Findables.CREDIT_SHARE, rounded), one lore page (10 steps or more, of the floor's
#      place and the day's tier, no repeat while another is unused), the rest nothing; credits are the piece's
#      units of 1% of the floor's quota; the sheet's numbers are the fill's;
#   3. the same for everyone: generated twice alike, and every floor's hash as stored in
#      tests/reference/findables_hashes.json (written by `npm run godot:golden -- prop_findables`), so Windows
#      and Linux deal the same; same-shaped Annex rooms have identical searchable pieces while their contents
#      differ somewhere on the floor;
#   4. the notes: three different poems of the floor's trait (Findables.trait_at: Lonely on the Annex in a run
#      with Lonely), for every depth to 12 on the game's deck and every crew size, with Lonely on and off;
#   5. the words: every poem 4 to 8 lines of at most 40 capitals, no word from the body list, no trait name, no
#      place name; every page 20 to 80 words with no trait name and none of ST4's words; the rules' ids and the
#      data's agree;
#   6. the pins: every poem's pin equals its rule's number today.
# Breaks (the design's): Findables.test_break "from_place" (the notes drawn from the place's own resident, not
# the run's trait: check 4 goes red on the Annex with Lonely on), "pin" (Lonely's 8 m reported as 9, the pin
# untouched: check 6 goes red). PROP_FINDABLES_BREAK=from_place|pin.
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Findables = preload("res://sim/findables.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Playroom = preload("res://sim/playroom.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")

const QUICK_SEEDS := 10
const SEEDS := 200
const HASHES_PATH := "res://tests/reference/findables_hashes.json"
## The words a poem may never use (a body, its tools, its clothes; findables-and-day.md FD8 "and the rest").
const BODY_WORDS: Array[String] = ["orderly", "orderlies", "temp", "temps", "minder", "minders", "trolley", "stapler", "staple", "mask", "masks",
	"gown", "lanyard", "badge", "photocopy", "copier", "smiley", "nurse", "doctor", "clerk", "uniform", "face", "faces", "paper", "crayon",
	"squeak", "squeaks", "click", "clicks", "footsteps", "wheel", "wheels", "tune", "humming", "hum"]
const TRAIT_WORDS: Array[String] = ["stillness", "lonely", "loneliness", "hearing"]
const PLACE_WORDS: Array[String] = ["clinic", "annex", "playroom", "hospital", "ward", "wards", "office", "offices", "cubicle", "cubicles",
	"lidgate", "soke", "prison", "lift", "elevator", "lobby", "corridor", "atrium", "nursery", "party", "continuance"]
## story.md ST4: the words a rule could hide in, never on a page.
const PAGE_BANNED: Array[String] = ["look", "looks", "looking", "watch", "stare", "alone", "lonely", "noise", "loud", "quiet", "light", "dark", "still",
	"run", "hear", "listen"]

static var _cache := {}

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_FINDABLES_BREAK")
	Findables.test_break = b if b == "from_place" or b == "pin" else ""

class Fl:
	var place: StringName
	var plan: Floor.FloorPlan
	var pieces: Array[Furniture.Piece]
	var spots: Array[Furniture.Piece]
	var fill: Findables.Fill
	var base := 0

static func floor_of(place: StringName, floor_seed: String, depth: int) -> Fl:
	var key := "%s:%s/%d" % [place, floor_seed, depth]
	if not _cache.has(key):
		var f := Fl.new()
		f.place = place
		f.plan = Clinic.generate_clinic(floor_seed, depth) if place == &"clinic" else Annex.generate_annex(floor_seed, depth)
		f.pieces = Furniture.pieces_for(f.plan, floor_seed, depth)
		for p in f.pieces:
			if p.searchable:
				f.spots.append(p)
		f.base = Run.floor_quota(depth, 1 + depth % 4)
		f.fill = Findables.fill_for(f.plan, floor_seed, depth, f.base, Findables.trait_for(place, true), 3, [])
		_cache[key] = f
	return _cache[key]

static func floors(quick: bool, place: StringName) -> Array[Fl]:
	var out: Array[Fl] = []
	for depth: int in [1, 2, 3, 4]:
		for i in (QUICK_SEEDS if quick else SEEDS):
			out.append(floor_of(place, "seed-%d" % i, depth))
	return out

static func _key(f: Fl) -> String:
	return "%s:%s/%d" % [f.place, f.plan.seed, f.plan.depth]

static func _steps(plan: Floor.FloorPlan, dist: PackedInt32Array, p: Furniture.Piece) -> int:
	return dist[Floor.pos_index(plan, Floor.Pos.make(p.level, p.x / 200, p.y / 200))]

# ---------------------------------------------------------------------------------------------
# 1. Where the pieces are.

func test_where_the_searchable_pieces_are(t: T) -> void:
	for place: StringName in [&"clinic", &"annex"]:
		var bad := 0
		var lo := 1 << 30
		var hi := 0
		var total := 0
		var fls := floors(t.quick, place)
		for f in fls:
			var n := f.spots.size()
			lo = mini(lo, n)
			hi = maxi(hi, n)
			total += n
			if place == &"clinic" and (n < Findables.CLINIC_MIN or n > Findables.CLINIC_MAX):
				bad += 1
				if bad <= 4:
					t.check(false, "%s: %d searchable pieces (18 to 30)" % [_key(f), n])
			var hides := Hides.hides_for(f.plan, f.plan.seed)
			var dist := Floor.distances_from(f.plan, f.plan.landing)
			var rooms := {}
			for r in f.plan.rooms:
				rooms[r.id] = r
			var again := Findables.spots_for(f.plan, f.plan.seed, f.plan.depth)
			if again.size() != n:
				bad += 1
				t.check(false, "%s: spots_for has %d, the furniture list %d" % [_key(f), again.size(), n])
			for p in f.spots:
				var why := ""
				var room: Floor.Room = rooms.get(p.room)
				if p.hide >= 0:
					why = "a hide"
				elif room == null or room.kind == &"lobby":
					why = "in the lobby or no room"
				elif not (Findables.SEARCHABLE[place] as Dictionary).has(room.kind) or not (Findables.SEARCHABLE[place][room.kind] as Dictionary).has(p.kind):
					why = "not searchable in a %s" % room.kind
				elif _steps(f.plan, dist, p) <= 3:
					why = "within 3 steps of the landing"
				elif not p.solid:
					why = "not solid"
				else:
					for h in hides:
						if h.level == p.level and h.room == p.room and Furniture.gap2(Rect2i(h.front.x, h.front.y, 0, 0), p.foot) < 120 * 120:
							why = "within 1.2 m of hide %d's front" % h.id
							break
				if why != "":
					bad += 1
					if bad <= 6:
						t.check(false, "%s: piece %d (%s) is %s" % [_key(f), p.id, p.kind, why])
		t.eq(bad, 0, "%s: searchable pieces where none may be" % place)
		t.note("%s: %d floors, %.1f searchable pieces a floor (%d to %d)" % [place, fls.size(), float(total) / fls.size(), lo, hi])
	# The Playroom and the prison: nothing (FD11 is off).
	var pr := Playroom.generate_playroom("seed-1", 4)
	t.eq(Findables.spots_for(pr, "seed-1", 4).size(), 0, "the Playroom's findables wait for FD11")

# ---------------------------------------------------------------------------------------------
# 2. What is inside.

static func _sheet_numbers(text: String) -> Array[int]:
	var out: Array[int] = []
	var re := RegEx.create_from_string("\\d+")
	for m in re.search_all(text):
		out.append(int(m.get_string()))
	return out

func test_what_is_inside(t: T) -> void:
	for place: StringName in [&"clinic", &"annex"]:
		var bad := 0
		var credits := 0
		var share := 0.0
		var fls := floors(t.quick, place)
		for f in fls:
			var fill := f.fill
			var n := fill.pieces.size()
			var count := {"note": 0, "juice": 0, "credits": 0, "page": 0, "nothing": 0}
			var sum := 0
			var near_note := false
			var poems := {}
			var dist := Floor.distances_from(f.plan, f.plan.landing)
			var by_walk: Array = f.spots.duplicate()
			by_walk.sort_custom(func(a: Furniture.Piece, b: Furniture.Piece) -> bool: return _steps(f.plan, dist, a) < _steps(f.plan, dist, b) or (_steps(f.plan, dist, a) == _steps(f.plan, dist, b) and a.id < b.id))
			var third := {}
			var room_of := {}
			for i in by_walk.size():
				third[(by_walk[i] as Furniture.Piece).id] = i * 3 / n
				room_of[(by_walk[i] as Furniture.Piece).id] = (by_walk[i] as Furniture.Piece).room
			var side := {}
			for r in f.plan.rooms:
				side[r.id] = r.branch == &"side"
			for id: int in fill.pieces:
				var c: Dictionary = fill.contents[id]
				var what := str(c["what"])
				count[what] += 1
				var steps := int(c["steps"])
				var units := int(third[id]) + 1 + (2 if bool(side.get(room_of[id], false)) else 0)
				var why := ""
				if int(c["units"]) != units:
					why = "units %d, want %d" % [int(c["units"]), units]
				elif what == "credits" and int(c["credits"]) != units * maxi(1, f.base / 100):
					why = "credits %d for %d units of %d" % [int(c["credits"]), units, f.base]
				elif what == "juice" and steps < Findables.FAR_STEPS:
					why = "a carton %d steps from the landing" % steps
				elif what == "page" and steps < Findables.FAR_STEPS:
					why = "a page %d steps from the landing" % steps
				elif what != "credits" and int(c["credits"]) != 0:
					why = "credits in a piece holding %s" % what
				if why != "":
					bad += 1
					if bad <= 6:
						t.check(false, "%s: piece %d: %s" % [_key(f), id, why])
				if what == "credits":
					sum += int(c["credits"])
				if what == "note":
					poems[str(c["note"])] = true
					near_note = near_note or int(third[id]) == 0
			var want_credits := roundi(n * float(Findables.CREDIT_SHARE[place]))
			var ok: bool = count["note"] == 3 and count["juice"] == 3 and count["credits"] == want_credits and count["page"] == 1 and poems.size() == 3 and near_note \
				and sum == fill.credits and count["credits"] == fill.credit_pieces
			if not ok:
				bad += 1
				if bad <= 6:
					t.check(false, "%s: %d pieces hold %s (want 3 notes, one near, 3 cartons, %d with credits, 1 page), %d poems, credits %d of %d" % [
						_key(f), n, str(count), want_credits, poems.size(), sum, fill.credits])
			# The sheet's numbers are the fill's.
			var nums := _sheet_numbers(Findables.sheet_text(fill))
			var want: Array[int] = [n, fill.credit_pieces, fill.cartons, fill.notes, 1, fill.credits]
			if nums != want:
				bad += 1
				if bad <= 6:
					t.check(false, "%s: the sheet '%s' says %s, the fill %s" % [_key(f), Findables.sheet_text(fill), str(nums), str(want)])
			credits += fill.credits
			share += float(fill.credits) / f.base
		t.eq(bad, 0, "%s: fills that break a rule" % place)
		t.note("%s: %.0f credits hidden a floor, %.1f%% of the floor's quota; e.g. %s" % [place, float(credits) / fls.size(), 100.0 * share / fls.size(), Findables.sheet_text(fls[0].fill)])

func test_pages_by_place_and_tier(t: T) -> void:
	var f := floor_of(&"clinic", "seed-3", 1)
	var dealt := {}
	var used: Array = []
	# Day 1: tier 1 only; each Clinic page once before any repeats.
	for d in 4:
		var fill := Findables.fill_for(f.plan, f.plan.seed, 1, f.base, &"stillness", 1, used)
		t.check(fill.page == "C1" or fill.page == "C3", "day 1 deals a tier 1 Clinic page, not %s" % fill.page)
		if d < 2:
			t.check(not used.has(fill.page), "no page twice while another is unused (%s after %s)" % [fill.page, str(used)])
		used.append(fill.page)
		dealt[fill.page] = true
	t.eq(dealt.size(), 2, "both of day 1's Clinic pages are dealt")
	var fill3 := Findables.fill_for(f.plan, f.plan.seed, 1, f.base, &"stillness", 3, ["C1", "C3"])
	t.eq(fill3.page, "C2", "with C1 and C3 used, day 3 deals C2")
	# The page never reads the trait: the same with any trait.
	for tr: StringName in [&"stillness", &"lonely", &"hearing"]:
		t.eq(Findables.fill_for(f.plan, f.plan.seed, 1, f.base, tr, 2, []).page, Findables.fill_for(f.plan, f.plan.seed, 1, f.base, &"stillness", 2, []).page,
			"the page with trait %s" % tr)
	var a := floor_of(&"annex", "seed-3", 3)
	for day: int in [1, 2, 3]:
		var fa := Findables.fill_for(a.plan, a.plan.seed, 3, a.base, &"lonely", day, [])
		var tier := -1
		for pg: Array in Findables.PAGES:
			if pg[0] == fa.page:
				tier = int(pg[2])
				t.eq(pg[1], &"annex", "the Annex's page is an Annex page")
		t.check(tier >= 1 and tier <= day, "day %d deals %s (tier %d)" % [day, fa.page, tier])

# ---------------------------------------------------------------------------------------------
# 3. The same for everyone.

static func _fill_plain(f: Fl) -> Dictionary:
	var rows: Array = []
	for id: int in f.fill.pieces:
		var c: Dictionary = f.fill.contents[id]
		rows.append([id, str(c["what"]), int(c["credits"]), str(c["note"]), int(c["units"])])
	return {"pieces": rows, "sheet": Findables.sheet_text(f.fill)}

func test_same_fill_for_everyone(t: T) -> void:
	_apply_break()
	var stored := {}
	if not t.recording:
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HASHES_PATH))
		if not t.check(parsed is Dictionary, "cannot read %s" % HASHES_PATH):
			return
		stored = parsed
	var got := {}
	var differ := 0
	var mismatched := 0
	for place: StringName in [&"clinic", &"annex"]:
		for f in floors(t.quick, place):
			var h := Playroom.hash_plain(_fill_plain(f))
			var plan2 := Clinic.generate_clinic(f.plan.seed, f.plan.depth) if place == &"clinic" else Annex.generate_annex(f.plan.seed, f.plan.depth)
			var f2 := Fl.new()
			f2.plan = plan2
			f2.fill = Findables.fill_for(plan2, f.plan.seed, f.plan.depth, f.base, Findables.trait_for(place, true), 3, [])
			if Playroom.hash_plain(_fill_plain(f2)) != h:
				differ += 1
				if differ <= 3:
					t.check(false, "%s: dealt twice, two fills" % _key(f))
			got[_key(f)] = h
			if not t.recording and str(stored.get(_key(f), "(none)")) != h:
				mismatched += 1
				if mismatched <= 3:
					t.check(false, "%s: fill hash %s, stored %s" % [_key(f), h, str(stored.get(_key(f), "(none)"))])
	t.eq(differ, 0, "fills whose two deals differ")
	t.eq(mismatched, 0, "fills whose hash differs from %s" % HASHES_PATH.get_file())
	if t.recording:
		# godot:golden -- prop_findables: the quick pass first, then the default, which leaves all 1600.
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(HASHES_PATH.get_base_dir()))
		var keys: Array = got.keys()
		keys.sort()
		var lines := PackedStringArray()
		for k: String in keys:
			lines.append("  %s: %s" % [JSON.stringify(k), JSON.stringify(got[k])])
		var fa := FileAccess.open(HASHES_PATH, FileAccess.WRITE)
		fa.store_string("{\n" + ",\n".join(lines) + "\n}\n")
		fa.close()
		t.note("wrote %d hashes to %s" % [keys.size(), HASHES_PATH])
	# Same-shaped Annex rooms: identical searchable pieces (in their canonical frames); contents differ somewhere.
	var groups := 0
	var unlike := 0
	var floors_differing := 0
	var fls := floors(t.quick, &"annex")
	for f in fls:
		var p := f.plan
		var by_key := {}
		var differs := false
		for room in p.rooms:
			var sh := Hides.shape_of(p, room)
			var lines: Array[String] = []
			var inside: Array[String] = []
			for pc in f.pieces:
				if pc.room != room.id:
					continue
				var o := Vector2i(room.x * 200, room.y * 200)
				var c := Hides.local_to_canon(sh.sym, room.w * 200, room.h * 200, Vector2i(pc.x, pc.y) - o)
				lines.append("%s %d,%d %s" % [pc.kind, c.x, c.y, pc.searchable])
				if pc.searchable:
					inside.append("%d,%d %s" % [c.x, c.y, str(f.fill.contents[pc.id]["what"])])
			lines.sort()
			inside.sort()
			var text := ";".join(lines)
			if not by_key.has(sh.key):
				by_key[sh.key] = [room, text, ";".join(inside)]
				continue
			groups += 1
			if by_key[sh.key][1] != text:
				unlike += 1
				if unlike <= 3:
					t.check(false, "%s: rooms %d and %d have one shape and different searchable pieces" % [_key(f), (by_key[sh.key][0] as Floor.Room).id, room.id])
			elif by_key[sh.key][2] != ";".join(inside):
				differs = true
		if differs:
			floors_differing += 1
	t.eq(unlike, 0, "same-shaped Annex rooms with different searchable pieces")
	t.check(groups > 0, "same-shaped rooms compared: %d" % groups)
	t.check(floors_differing * 10 >= fls.size() * 9, "same-shaped rooms whose contents differ, on %d of %d floors" % [floors_differing, fls.size()])
	t.note("%d same-shaped room pairs alike; contents differ between same-shaped rooms on %d of %d floors" % [groups, floors_differing, fls.size()])

# ---------------------------------------------------------------------------------------------
# 4. The notes follow the trait.

func test_notes_are_three_poems_of_the_trait(t: T) -> void:
	_apply_break()
	var bad := 0
	var checked := 0
	var seeds := 4 if t.quick else 12
	for i in seeds:
		var seed := "trait-%d" % i
		for depth in range(1, 13):
			var place := Places.place_at(seed, depth, Places.FULL)
			if not Findables.place_on(place):
				continue
			var plan := Places.generate(seed, depth, Places.FULL)
			for lonely: bool in [true, false]:
				var want: StringName = Places.resident_in(place, lonely).trait_name
				var tr := Findables.trait_at(seed, depth, Places.FULL, lonely)
				for crew in range(1, 5):
					var fill := Findables.fill_for(plan, seed, depth, Run.floor_quota(depth, crew), tr, 1 + depth % 3, [])
					var got: Array = []
					for id: int in fill.pieces:
						if fill.contents[id]["what"] == "note":
							got.append(str(fill.contents[id]["note"]))
					checked += 1
					var ok := got.size() == 3
					var distinct := {}
					for id: String in got:
						distinct[id] = true
						ok = ok and (Findables.POEMS[want] as Array).has(id)
					ok = ok and distinct.size() == 3
					if not ok:
						bad += 1
						if bad <= 4:
							t.check(false, "%s depth %d (%s, lonely %s, crew %d): notes %s, want three of %s" % [seed, depth, place, lonely, crew, str(got), want])
	t.eq(bad, 0, "floors whose notes are not three poems of their trait")
	t.note("%d floors and crew sizes checked" % checked)
	Findables.test_break = ""

# ---------------------------------------------------------------------------------------------
# 5. The words.

static func _words(text: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string("[a-z]+")
	for m in re.search_all(text.to_lower()):
		out.append(m.get_string())
	return out

func test_poems_and_pages_say_nothing_plain(t: T) -> void:
	var d := Findables.data()
	var poems: Array = d.get("poems", [])
	t.eq(poems.size(), 9, "poems in the data")
	var by_trait := {}
	for p: Dictionary in poems:
		var id := str(p["id"])
		var lines: Array = p["lines"]
		by_trait[str(p["trait"])] = by_trait.get(str(p["trait"]), []) + [id]
		t.check(lines.size() >= 4 and lines.size() <= 8, "%s has %d lines (4 to 8)" % [id, lines.size()])
		for line: String in lines:
			t.check(line.length() <= 40, "%s: '%s' is %d characters (40 at most)" % [id, line, line.length()])
			t.check(line == line.to_upper(), "%s: '%s' is in capitals" % [id, line])
			for w in _words(line):
				t.check(not BODY_WORDS.has(w), "%s names a body or its things: '%s'" % [id, w])
				t.check(not TRAIT_WORDS.has(w), "%s names a trait: '%s'" % [id, w])
				t.check(not PLACE_WORDS.has(w), "%s names a place: '%s'" % [id, w])
		t.check(Findables.is_poem(id) and Findables.note_lines(id).size() == lines.size(), "%s reads back" % id)
	for tr: StringName in Findables.POEMS:
		var want: Array = Findables.POEMS[tr]
		var have: Array = by_trait.get(String(tr), [])
		want = want.duplicate()
		want.sort()
		have.sort()
		t.eq(have, want, "the %s poems in the data and the rules" % tr)
	var pages: Array = d.get("pages", [])
	var friday := 0
	for pg: Dictionary in pages:
		var id := str(pg["id"])
		var words := _words(str(pg["text"]))
		t.check(words.size() >= 20 and words.size() <= 80, "page %s has %d words (20 to 80)" % [id, words.size()])
		for w in words:
			t.check(not TRAIT_WORDS.has(w), "page %s names a trait: '%s'" % [id, w])
			t.check(not PAGE_BANNED.has(w), "page %s uses '%s'" % [id, w])
		for old: String in ["datum", "lowfield", "upwell", "remission shift"]:
			t.check(not str(pg["text"]).to_lower().contains(old), "page %s uses an old name: %s" % [id, old])
		if bool(pg.get("friday", false)):
			friday += 1
	# The rules' pages (drawers only) are the data's Friday pages of the floors.
	for rp: Array in Findables.PAGES:
		var found := false
		for pg: Dictionary in pages:
			if str(pg["id"]) == rp[0]:
				found = bool(pg["friday"]) and str(pg["place"]) == String(rp[1]) and int(pg["tier"]) == int(rp[2]) and str(pg["where"]) == String(rp[3])
		t.check(found, "page %s: the rules and the data agree" % rp[0])
	t.note("%d poems, %d pages (%d for Friday, %d dealt from drawers)" % [poems.size(), pages.size(), friday, Findables.PAGES.size()])

# ---------------------------------------------------------------------------------------------
# 6. The pins.

func test_every_pin_is_the_rule_today(t: T) -> void:
	_apply_break()
	var rules := Findables.rule_values()
	var pins := 0
	for p: Dictionary in Findables.data().get("poems", []):
		var pinned: Dictionary = p.get("pins", {})
		for k: String in pinned:
			pins += 1
			if not t.check(rules.has(k), "%s pins %s, which no rule has" % [p["id"], k]):
				continue
			var a: Variant = pinned[k]
			var b: Variant = rules[k]
			var same := false
			if a is Array and b is Array:
				same = (a as Array).size() == (b as Array).size()
				for i in (a as Array).size():
					same = same and is_equal_approx(float(a[i]), float(b[i]))
			else:
				same = is_equal_approx(float(a), float(b))
			t.check(same, "%s pins %s at %s; the rule is %s today" % [p["id"], k, str(a), str(b)])
	t.check(pins >= 6, "pins checked: %d" % pins)
	Findables.test_break = ""
