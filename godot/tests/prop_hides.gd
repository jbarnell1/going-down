# Hiding places on every floor (docs/floors/traits-and-hiding.md section 4 and T19b; sim/hides.gd,
# sim/hiding.gd, sim/entity.gd "Hidden players"). Over 800 Clinics and 800 Annexes (seed-0..199 at depths
# 1 to 4; the quick set seed-0..9, 40 of each):
#   1. from every corridor cell a hide's front cell is within 14 steps (the test's own search); each
#      level's hides hold at least 8; none in the lobby, none within 3 steps of the landing, none in the
#      car; every front spot legal: walkable, in the hide's room (or its corridor cell), not a door cell,
#      clear of walls by 0.3 m, within 0.8 m of the inside spot, the gap facing into the room; each kind
#      as the design's table and in the rooms the design gives it;
#   2. same seed, same list: generated twice alike, and every floor's hash as stored in
#      tests/reference/hides_hashes.json (written by `npm run godot:golden -- prop_hides`), so Windows and
#      Linux hold the same lists; the Playroom's list is Playroom.hides, as tests/playroom_hashes.json has it;
#   3. same-shaped Annex rooms have identical hides (each room read in its own canonical frame);
# and in the run (pure rules), under each built trait off the Playroom (Stillness, in the Orderly's body on
# the Clinic and the Temp's on the Annex):
#   4. over seeded bot runs where bots walk to hides, get in (slow or fast), sit, peek, get out and go on,
#      no player inside a hide is ever caught without a reason logged for that hide since it was last
#      empty; and the look-ins, the lost tracks and the catches from hides all happen (not vacuous);
#   5. scenes: a player seen getting in is caught (reason "seen", the look-in, "caught"); one not seen is
#      not, and it stands where it lost them; one seen getting in while a crewmate watches it is not caught
#      while watched (Stillness's own rule saves them), and is once the watcher looks away; a player peeking
#      at it holds it, sat back does not.
# Breaks (the design's): Hides.test_break "position" (seed the Annex's hides by position: check 3 goes
# red), Entity.hide_break "no_reason" (look into any occupied hide: check 4 goes red), Hides.test_break
# "no_top_up" (skip the top-up cabinets: check 1 goes red).
extends RefCounted

@warning_ignore_start("integer_division")

const T = preload("res://tests/t.gd")
const Hides = preload("res://sim/hides.gd")
const Hiding = preload("res://sim/hiding.gd")
const Playroom = preload("res://sim/playroom.gd")
const Clinic = preload("res://sim/clinic.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Seek = preload("res://sim/seek.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")

const QUICK_SEEDS := 10
const SEEDS := 200
const HASHES_PATH := "res://tests/reference/hides_hashes.json"
const PLAYROOM_HASHES := "res://tests/playroom_hashes.json"
## The design's table (section 4): [holds, eye cm, gap half-angle degrees].
const TABLE := {&"bed": [1, 20, 70], &"cabinet": [1, 150, 20], &"desk": [1, 50, 45], &"table": [2, 30, 60]}
## Where each kind may stand (top-up cabinets anywhere but the lobby).
const ROOMS := {
	&"clinic": {&"bed": [&"ward", &"exam"], &"desk": [], &"table": []},
	&"annex": {&"bed": [], &"desk": [&"office", &"cubicles", &"break"], &"table": [&"meeting"]},
}
const STEPS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const DT := 0.05

static var _cache := {}

## The design's deliberate breaks, from the environment: PROP_HIDES_BREAK=position | no_reason | no_top_up
## (see the header). Unset: none.
static func _apply_break() -> void:
	var b := OS.get_environment("PROP_HIDES_BREAK")
	Hides.test_break = b if b == "position" or b == "no_top_up" else ""
	Entity.hide_break = b if b == "no_reason" else ""

class Fl:
	var place: StringName
	var plan: Floor.FloorPlan
	var hides: Array[Playroom.Hide]

static func floor_of(place: StringName, floor_seed: String, depth: int) -> Fl:
	var key := "%s:%s/%d" % [place, floor_seed, depth]
	if not _cache.has(key) or not Hides.test_break.is_empty():
		var f := Fl.new()
		f.place = place
		f.plan = Clinic.generate_clinic(floor_seed, depth) if place == &"clinic" else Annex.generate_annex(floor_seed, depth)
		f.hides = Hides.hides_for(f.plan, floor_seed)
		if not Hides.test_break.is_empty():
			return f
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

## Steps from the nearest source to every position (pos_index), -1 if not reached, walking backwards
## over Floor.can_step_xy (the test's own search).
static func _search_back(p: Floor.FloorPlan, sources: Array[Floor.Pos]) -> PackedInt32Array:
	var w := p.width
	var n := p.width * p.height
	var dist := PackedInt32Array()
	dist.resize(2 * n)
	dist.fill(-1)
	var queue: Array[int] = []
	for s in sources:
		var k := Floor.pos_index(p, s)
		if dist[k] == -1:
			dist[k] = 0
			queue.append(k)
	var head := 0
	while head < queue.size():
		var ci: int = queue[head]
		head += 1
		var cl := 1 if ci >= n else 0
		var cx := (ci - cl * n) % w
		var cy := (ci - cl * n) / w
		for level: int in [cl, 1 - cl]:
			for d in STEPS:
				var nx := cx + d.x
				var ny := cy + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= p.height:
					continue
				var key := level * n + ny * w + nx
				if dist[key] != -1 or not Floor.can_step_xy(p, level, nx, ny, cl, cx, cy):
					continue
				dist[key] = dist[ci] + 1
				queue.append(key)
	return dist

static func _door_cells(p: Floor.FloorPlan) -> Dictionary:
	var out := {}
	for d in p.doors:
		out[Floor.pos_index(p, Floor.Pos.make(d.level, d.ax, d.ay))] = true
		out[Floor.pos_index(p, Floor.Pos.make(d.level, d.bx, d.by))] = true
	return out

# ---------------------------------------------------------------------------------------------
# 1. Reach, capacity, where they stand, their spots.

func test_reach_capacity_and_spots(t: T) -> void:
	_apply_break()
	var notes: Array[String] = []
	for place: StringName in [&"clinic", &"annex"]:
		var fs := floors(t.quick, place)
		var farthest := 0
		var least_cap := 1 << 30
		var total := 0
		var corridor := 0
		var bad := 0
		var kinds := {}
		for f in fs:
			var p := f.plan
			var n := p.width * p.height
			var fronts: Array[Floor.Pos] = []
			var cap: Array[int] = [0, 0]
			var doors := _door_cells(p)
			var landing := Floor.distances_from(p, p.landing)
			var car := Run.car_geometry(p)
			for h in f.hides:
				total += 1
				kinds[h.kind] = (kinds.get(h.kind, 0) as int) + 1
				cap[h.level] += h.capacity
				fronts.append(Floor.Pos.make(h.level, h.front.x / 200, h.front.y / 200))
				var why := ""
				var row: Array = TABLE.get(h.kind, [])
				if row.size() != 3 or h.capacity != (row[0] as int) or h.eye != (row[1] as int) or h.gap_half != (row[2] as int):
					why = "not as the table"
				var ic := Vector2i(h.inside.x / 200, h.inside.y / 200)
				var fc := Vector2i(h.front.x / 200, h.front.y / 200)
				if h.room >= 0:
					var room := p.rooms[h.room]
					if room.level != h.level:
						why = "on another level than its room"
					if room.kind == &"lobby":
						why = "in the lobby"
					var allowed: Array = (ROOMS[place] as Dictionary).get(h.kind, [])
					if h.kind != &"cabinet" and not allowed.has(room.kind):
						why = "a %s in a %s" % [h.kind, room.kind]
					for q: Vector2i in [h.inside, h.front]:
						if q.x < room.x * 200 + 30 or q.x > (room.x + room.w) * 200 - 30 or q.y < room.y * 200 + 30 or q.y > (room.y + room.h) * 200 - 30:
							why = "a spot not inside its room by 0.3 m"
						if Floor.room_id_at(p, h.level, q.x / 200, q.y / 200) != h.room:
							why = "a spot outside its room"
					var into := h.inside + Vector2i(Floor.dir_dx(h.gap), Floor.dir_dy(h.gap)) * 50
					if Floor.room_id_at(p, h.level, into.x / 200, into.y / 200) != h.room:
						why = "its gap faces out of the room"
				else:
					corridor += 1
					if h.kind != &"cabinet" or Floor.cell_at(p, h.level, fc.x, fc.y) != Floor.CORRIDOR or ic != fc:
						why = "a corridor hide that is not a cupboard in its corridor cell"
				if not Floor.is_walkable(p, h.level, fc.x, fc.y):
					why = "its front is not walkable"
				if doors.has(Floor.pos_index(p, Floor.Pos.make(h.level, fc.x, fc.y))) or doors.has(Floor.pos_index(p, Floor.Pos.make(h.level, ic.x, ic.y))):
					why = "on a door cell"
				if Move.wall_clearance(p, h.level, h.front.x / 100.0, h.front.y / 100.0) < 0.3 - 1e-6:
					why = "its front is within 0.3 m of a wall"
				var dv := h.front - h.inside
				if dv.x * dv.x + dv.y * dv.y > 80 * 80:
					why = "its front is more than 0.8 m from its inside spot"
				for c: Vector2i in [ic, fc]:
					var ld := landing[Floor.pos_index(p, Floor.Pos.make(h.level, c.x, c.y))]
					if ld >= 0 and ld <= 3:
						why = "within 3 steps of the landing"
				for q: Vector2i in [h.inside, h.front]:
					if h.level == car.level and Run.in_car(car, Move.Body.make(q.x / 100.0, q.y / 100.0, h.level, 0.0)):
						why = "in the car"
				if why != "":
					bad += 1
					if bad <= 4:
						t.check(false, "%s: hide %d (%s, room %d, inside %s front %s gap %s): %s" % [_key(f), h.id, h.kind, h.room, h.inside, h.front, h.gap, why])
			for level in 2:
				least_cap = mini(least_cap, cap[level])
				t.check(cap[level] >= 8, "%s: level %d's hides hold %d" % [_key(f), level, cap[level]])
			var dist := _search_back(p, fronts)
			var far := 0
			for k in 2 * n:
				var level := 1 if k >= n else 0
				if p.cells[level][k - level * n] != Floor.CORRIDOR:
					continue
				var d := dist[k] if dist[k] >= 0 else 999
				far = maxi(far, d)
				if d > 14:
					t.check(false, "%s L%d: corridor cell %d,%d is %d steps from a hide" % [_key(f), level, (k - level * n) % p.width, (k - level * n) / p.width, d])
					break
			farthest = maxi(farthest, far)
		t.eq(bad, 0, "%s hides breaking the rules" % place)
		notes.append("%s: %d floors, %d hides %s (%d corridor cupboards); least capacity on a level %d; farthest corridor cell %d steps from a hide" % [place, fs.size(), total, str(kinds), corridor, least_cap, farthest])
	for nt in notes:
		t.note(nt)

# ---------------------------------------------------------------------------------------------
# 2. Same seed, same list (and the Playroom's unchanged).

func test_same_list_for_everyone(t: T) -> void:
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
			var h := Hides.hash_of(f.hides)
			var again_plan := Clinic.generate_clinic(f.plan.seed, f.plan.depth) if place == &"clinic" else Annex.generate_annex(f.plan.seed, f.plan.depth)
			var again := Hides.hash_of(Hides.hides_for(again_plan, f.plan.seed))
			if h != again:
				differ += 1
				if differ <= 3:
					t.check(false, "%s: generated twice, hashes %s and %s" % [_key(f), h, again])
			got[_key(f)] = h
			if not t.recording and str(stored.get(_key(f), "(none)")) != h:
				mismatched += 1
				if mismatched <= 3:
					t.check(false, "%s: hides hash %s, stored %s" % [_key(f), h, str(stored.get(_key(f), "(none)"))])
	t.eq(differ, 0, "lists whose two generations differ")
	t.eq(mismatched, 0, "lists whose hash differs from %s" % HASHES_PATH.get_file())
	if t.recording:
		# godot:golden -- prop_hides: the quick pass first, then the default, which leaves all 1600.
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
	# The Playroom: hides_for gives Playroom.hides, as its own stored list has it.
	var pr: Variant = JSON.parse_string(FileAccess.get_file_as_string(PLAYROOM_HASHES))
	var pr_bad := 0
	var pr_n := 0
	for depth: int in [1, 2, 3, 4]:
		for i in (QUICK_SEEDS if t.quick else 40):
			var p := Playroom.generate_playroom("seed-%d" % i, depth)
			var a := Hides.hash_of(Hides.hides_for(p, p.seed))
			var want: Variant = (pr as Dictionary).get("seed-%d/%d" % [i, depth]) if pr is Dictionary else null
			pr_n += 1
			if a != Hides.hash_of(Playroom.hides(p, p.seed)) or not (want is Array) or str((want as Array)[1]) != a:
				pr_bad += 1
	t.eq(pr_bad, 0, "Playroom floors whose hides_for list is not its own stored list")
	t.note("%d floors generated twice alike, all as stored; %d Playroom floors give Playroom.hides as stored" % [got.size(), pr_n])

# ---------------------------------------------------------------------------------------------
# 3. Same-shaped Annex rooms, identical hides.

## A room's hides in its canonical frame, as sorted text.
static func _canonical(p: Floor.FloorPlan, room: Floor.Room, sh: Hides.Shape, list: Array[Playroom.Hide]) -> Array[String]:
	var out: Array[String] = []
	var wcm := room.w * 200
	var hcm := room.h * 200
	var o := Vector2i(room.x * 200, room.y * 200)
	for h in list:
		if h.room != room.id:
			continue
		var a := Hides.local_to_canon(sh.sym, wcm, hcm, h.inside - o)
		var b := Hides.local_to_canon(sh.sym, wcm, hcm, h.front - o)
		out.append("%s %d,%d %d,%d" % [h.kind, a.x, a.y, b.x, b.y])
	out.sort()
	return out

func test_same_shaped_rooms_identical(t: T) -> void:
	_apply_break()
	var groups_total := 0
	var compared := 0
	var differ := 0
	var topped := 0
	for f in floors(t.quick, &"annex"):
		var p := f.plan
		var base := Hides.by_shape(p)
		var groups := {}
		for room in p.rooms:
			var sh := Hides.shape_of(p, room)
			if not groups.has(sh.key):
				groups[sh.key] = []
			(groups[sh.key] as Array).append([room, sh])
		for key: String in groups:
			var g: Array = groups[key]
			if g.size() < 2:
				continue
			groups_total += 1
			var first: Array = g[0]
			var want := _canonical(p, first[0], first[1], f.hides)
			for i in range(1, g.size()):
				var e: Array = g[i]
				var have := _canonical(p, e[0], e[1], f.hides)
				compared += 1
				if have == want:
					if have.size() > _canonical(p, e[0], e[1], base).size():
						topped += 1
					continue
				differ += 1
				if differ <= 3:
					var r: Floor.Room = e[0]
					var r0: Floor.Room = first[0]
					t.check(false, "%s: room %d (%s at %d,%d L%d) has hides %s, room %d of the same shape at %d,%d has %s" % [_key(f), r.id, r.kind, r.x, r.y, r.level, have, r0.id, r0.x, r0.y, want])
	t.eq(differ, 0, "same-shaped rooms with different hides")
	t.note("%d floors: %d groups of same-shaped rooms, %d rooms compared in their canonical frames, all alike (%d of them with top-up cabinets, at the same canonical spots)" % [floors(t.quick, &"annex").size(), groups_total, compared, topped])

# ---------------------------------------------------------------------------------------------
# The run: bots and scenes.

static func view(id: String, body: Move.Body, yaw: float) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, yaw, 0.0, 90.0, 70.0)

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

## A run on one place's floor 1, its doors open and the car gone, with `ids` stood at the landing.
static func run_on(place: StringName, floor_seed: String, ids: Array[String]) -> Run.RunState:
	var s := Run.create_run(floor_seed, ids, [place])
	s = s.copy()
	s.phase = &"away"
	s.timer = 0.0
	return s

## The resident set where it is wanted: hunting (or dormant for `dormant` seconds), facing `yaw`.
static func put_resident(s: Run.RunState, at: Move.Body, yaw: float, dormant: float = 0.0) -> void:
	var o := s.orderly.copy()
	o.body = at
	o.yaw = yaw
	o.mode = &"dormant" if dormant > 0.0 else &"hunting"
	o.dormant_left = dormant
	o.replan_in = 0.0
	o.path = []
	s.orderly = o

class Bot:
	var id: String
	var body: Move.Body
	var yaw: float = 0.0
	## &"walk" (to `hide`), &"wait" (at the front, then F), &"in" (inside until `until`), &"out"
	var mode: StringName = &"walk"
	var hide: int = -1
	var walk: Follow.PathWalk = null
	var until: float = 0.0
	var fast: bool = false
	var peek: bool = false

## The fuzz: bots walk to hides near them, get in (a quarter fast), sit 3 to 12 s (a quarter of them peeking
## for a spell, looking round the gap), get out (a quarter fast) and go to another. Returns the counts.
static func bot_run(t: T, place: StringName, floor_seed: String, crew: int, seconds: float, counts: Dictionary) -> void:
	var ids: Array[String] = []
	for i in crew:
		ids.append("b%d" % i)
	var s := run_on(place, floor_seed, ids)
	var plan := s.plan
	var hides := Hides.hides_for(plan, plan.seed)
	var rng := Rng.make_rng("prop_hides:%s:%s" % [place, floor_seed])
	var bots: Array[Bot] = []
	var players: Array[Run.RunPlayer] = []
	for i in crew:
		var b := Bot.new()
		b.id = ids[i]
		bots.append(b)
		var np := s.players[i].copy()
		np.body = Run._landing_slot(s.car, i)
		np.aboard = false
		players.append(np)
	s.players = players
	# The resident starts hunting from its own start.
	put_resident(s, s.orderly.body, s.orderly.yaw)
	# Per hide: a reason logged since it was last empty.
	var open := {}
	var tick := 0
	while s.t < seconds:
		tick += 1
		var inputs: Array[Run.PlayerInput] = []
		var hs: Hiding.HidingState = s.hiding
		for b in bots:
			var rp := _player(s, b.id)
			if rp == null or rp.status != &"ok":
				continue
			var hp: Hiding.HidePlayer = Hiding.player_of(hs, b.id) if hs != null else null
			var phase: StringName = hp.phase if hp != null else &"out"
			var inp := view(b.id, rp.body, b.yaw)
			match b.mode:
				&"walk":
					if b.hide < 0:
						b.hide = _pick_hide(plan, hides, rp.body, rng)
						var h := hides[b.hide]
						var to := Seek.hide_front_body(plan, h)
						b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, rp.body), Move.cell_of(plan, to)))
					var to := Seek.hide_front_body(plan, hides[b.hide])
					var nb := rp.body
					if b.walk != null and not Follow.path_done(plan, b.walk, rp.body):
						nb = Follow.step_path_walk(plan, b.walk, rp.body, 3.0 * DT, 0.3)
					else:
						var d := flat(rp.body, to)
						if d > 0.05:
							var st := minf(3.0 * DT, d)
							nb = Move.move_with_collision(plan, rp.body, (to.x - rp.body.x) / d * st, (to.z - rp.body.z) / d * st, 0.3)
					if flat(nb, rp.body) > 1e-4:
						b.yaw = Seek.yaw_toward(nb.x - rp.body.x, nb.z - rp.body.z)
					inp.body = nb
					if flat(nb, to) <= 0.5 or (b.walk != null and Follow.path_done(plan, b.walk, nb) and flat(nb, to) < 1.1):
						b.mode = &"wait"
				&"wait":
					inp.hide_use = true
					b.fast = rng.int_in(0, 3) == 0
					inp.hide_fast = b.fast
					b.mode = &"in"
					b.until = s.t + rng.int_in(30, 120) / 10.0
					b.peek = rng.int_in(0, 3) == 0
				&"in":
					if phase == &"inside":
						inp.peek = b.peek and rng.int_in(0, 9) < 8
						b.yaw += rng.int_in(-10, 10) / 20.0
						inp.yaw = b.yaw
						if s.t >= b.until:
							inp.hide_use = true
							inp.hide_fast = rng.int_in(0, 3) == 0
							b.mode = &"out"
					elif phase == &"out" and s.t > b.until + 2.0:
						# Refused (full), or pulled out: go on.
						b.mode = &"walk"
						b.hide = -1
				&"out":
					if phase == &"out":
						b.mode = &"walk"
						b.hide = -1
			inputs.append(inp)
		var inside_before := {}
		if s.hiding != null:
			for hp: Hiding.HidePlayer in (s.hiding as Hiding.HidingState).players:
				if hp.phase == &"inside":
					inside_before[hp.id] = hp.hide
		var r := Run.step_run(s, inputs, DT)
		for e in r.events:
			match str(e["type"]):
				"reason":
					open[int(e["hide"])] = true
					counts["reasons"] = (counts.get("reasons", 0) as int) + 1
				"look":
					counts["looks"] = (counts.get("looks", 0) as int) + 1
				"lostTrack":
					counts["lost"] = (counts.get("lost", 0) as int) + 1
				"hideIn":
					counts["ins"] = (counts.get("ins", 0) as int) + 1
				"caught":
					var id := str(e["playerId"])
					if inside_before.has(id):
						var hid: int = inside_before[id]
						counts["from_hides"] = (counts.get("from_hides", 0) as int) + 1
						if not open.has(hid):
							counts["bad"] = (counts.get("bad", 0) as int) + 1
							if (counts["bad"] as int) <= 3:
								t.check(false, "%s %s: %s caught out of hide %d at %.2f s with no reason logged" % [place, floor_seed, id, hid, float(e["t"])])
					else:
						counts["open_catches"] = (counts.get("open_catches", 0) as int) + 1
		s = r.state
		if s.hiding != null:
			for hid: int in open.keys():
				if Hiding.occupants(s.hiding, hid) == 0:
					open.erase(hid)
			for hp: Hiding.HidePlayer in (s.hiding as Hiding.HidingState).players:
				if hp.phase == &"inside":
					counts["hidden_ticks"] = (counts.get("hidden_ticks", 0) as int) + 1
		if s.phase == &"ended":
			break

static func _player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

## One of the five hides nearest by straight line, seeded.
static func _pick_hide(plan: Floor.FloorPlan, hides: Array[Playroom.Hide], b: Move.Body, rng: Rng) -> int:
	var order: Array = []
	for h in hides:
		if h.level != b.level:
			continue
		var d := int(M.hypot2(h.front.x / 100.0 - b.x, h.front.y / 100.0 - b.z) * 100.0)
		var at := order.size()
		for i in order.size():
			if d < int(order[i][0]):
				at = i
				break
		order.insert(at, [d, h.id])
	if order.is_empty():
		return 0
	return int(order[rng.int_in(0, mini(4, order.size() - 1))][1])

func test_no_catch_from_a_hide_without_a_reason(t: T) -> void:
	_apply_break()
	var runs := 6 if t.quick else 24
	for place: StringName in [&"clinic", &"annex"]:
		var counts := {}
		for i in runs:
			bot_run(t, place, "hide-bots-%d" % i, 1 + i % 3, 60.0, counts)
		t.eq(int(counts.get("bad", 0)), 0, "%s: catches out of a hide without a reason" % place)
		var body := "the Orderly's" if place == &"clinic" else "the Temp's"
		t.note("%s (Stillness, %s body): %d runs; %d times in, %d ticks hidden; %d reasons, %d look-ins, %d catches out of hides, all with a reason; %d lost tracks; %d catches in the open" % [
			place, body, runs, int(counts.get("ins", 0)), int(counts.get("hidden_ticks", 0)), int(counts.get("reasons", 0)), int(counts.get("looks", 0)),
			int(counts.get("from_hides", 0)), int(counts.get("lost", 0)), int(counts.get("open_catches", 0))])
		t.check(int(counts.get("from_hides", 0)) > 0, "%s: nobody was ever caught out of a hide (vacuous)" % place)
		t.check(int(counts.get("ins", 0)) > 20, "%s: hardly anyone hid (vacuous)" % place)

# --- 5. Scenes.

class Scene:
	var s: Run.RunState
	var h: Playroom.Hide
	var front: Move.Body
	var at: Move.Body
	var ok := false

## A Clinic or Annex floor, a hide on level 0 away from the landing, and a spot 3 to 5 m out from its
## front with a clear line from the resident's head to a player standing at the front.
static func scene(place: StringName, floor_seed: String, ids: Array[String]) -> Scene:
	var sc := Scene.new()
	sc.s = run_on(place, floor_seed, ids)
	var plan := sc.s.plan
	var head := Entity.kind_of(sc.s.orderly).height
	for h in Hides.hides_for(plan, plan.seed):
		if h.level != 0 or h.room < 0:
			continue
		var front := Seek.hide_front_body(plan, h)
		var gx := float(Floor.dir_dx(h.gap))
		var gz := float(Floor.dir_dy(h.gap))
		for d: float in [4.5, 4.0, 3.5, 3.0]:
			var at := Move.move_with_collision(plan, front, gx * d, gz * d, 0.35)
			if flat(at, front) < d - 0.05:
				continue
			var yaw := Seek.yaw_toward(front.x - at.x, front.z - at.z)
			if not Hiding.in_view(plan, Hiding.Watcher.make(at, yaw, head), front):
				continue
			sc.h = h
			sc.front = front
			sc.at = at
			sc.ok = true
			return sc
	return sc

## Steps the scene: `a` at the hide's front presses F on the first tick, facing the wall behind the hide;
## `watch` (if given) is the watcher's input each tick. Returns the events.
static func play(sc: Scene, seconds: float, watcher: Callable = Callable(), peek_yaw: Variant = null, press: bool = true) -> Array[Dictionary]:
	var evs: Array[Dictionary] = []
	var away := Seek.yaw_toward(-float(Floor.dir_dx(sc.h.gap)), -float(Floor.dir_dy(sc.h.gap)))
	var first := press
	while sc.s.t < seconds:
		var inputs: Array[Run.PlayerInput] = []
		var a := _player(sc.s, "a")
		if a != null and a.status == &"ok":
			var ai := view("a", a.body if not first else sc.front, away)
			ai.hide_use = first
			if peek_yaw != null:
				ai.peek = true
				ai.yaw = float(peek_yaw)
			inputs.append(ai)
		if watcher.is_valid():
			var wi: Variant = watcher.call(sc.s)
			if wi != null:
				inputs.append(wi)
		first = false
		var r := Run.step_run(sc.s, inputs, DT)
		evs.append_array(r.events)
		sc.s = r.state
	return evs

static func _types(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if str(e["type"]) == type:
			out.append(e)
	return out

func test_seen_getting_in_is_caught(t: T) -> void:
	_apply_break()
	var tried := 0
	var seen_caught := 0
	var unseen_safe := 0
	var stood := 0
	var watched_safe := 0
	var released_caught := 0
	var peek_held := 0
	var sat_not_held := 0
	var n := 4 if t.quick else 16
	for place: StringName in [&"clinic", &"annex"]:
		for i in n:
			var ids: Array[String] = ["a"]
			var sc := scene(place, "hide-scene-%d" % i, ids)
			if not sc.ok:
				continue
			tried += 1
			var yaw_at := Seek.yaw_toward(sc.front.x - sc.at.x, sc.front.z - sc.at.z)
			# Seen getting in, nobody watching: a reason, the look-in, caught.
			put_resident(sc.s, sc.at, yaw_at, 2.0)
			var evs := play(sc, 12.0)
			var reasons := _types(evs, "reason")
			var caught := _types(evs, "caught")
			if t.check(not reasons.is_empty() and str(reasons[0]["why"]) == "seen" and not caught.is_empty() and str(caught[0]["playerId"]) == "a" and not _types(evs, "lookDone").is_empty(),
				"%s seed %d: seen getting in and not caught (reasons %s, caught %s)" % [place, i, str(reasons), str(caught)]):
				seen_caught += 1
			# Not seen (it faces away): never caught, never looked for in a hide.
			sc = scene(place, "hide-scene-%d" % i, ids)
			put_resident(sc.s, sc.at, yaw_at + PI, 2.0)
			evs = play(sc, 12.0)
			if t.check(_types(evs, "caught").is_empty() and _types(evs, "reason").is_empty() and _types(evs, "look").is_empty(), "%s seed %d: caught or looked for without being seen" % [place, i]):
				unseen_safe += 1
			# Hunted but not seen getting in: it stands where it lost them, then gives up.
			sc = scene(place, "hide-scene-%d" % i, ids)
			var far: Variant = _out_of_sight(sc)
			if far != null:
				put_resident(sc.s, far, 0.0)
				var o := sc.s.orderly.copy()
				o.target_id = "a"
				sc.s.orderly = o
				evs = play(sc, 25.0)
				if _types(evs, "reason").is_empty():
					t.check(_types(evs, "caught").is_empty(), "%s seed %d: caught out of a hide it had no reason to look in" % [place, i])
					if not _types(evs, "lostTrack").is_empty() and not _types(evs, "searchEnd").is_empty():
						stood += 1
			# Seen getting in while a crewmate watches it: held, so never caught while watched; then the
			# watcher looks away and it comes.
			var ids2: Array[String] = ["a", "w"]
			sc = scene(place, "hide-scene-%d" % i, ids2)
			put_resident(sc.s, sc.at, yaw_at, 2.0)
			var wb: Variant = _watch_spot(sc)
			if wb != null:
				var res_at := sc.at
				var watch := func(st: Run.RunState) -> Run.PlayerInput:
					var look := Seek.yaw_toward(res_at.x - wb.x, res_at.z - wb.z)
					return view("w", wb, look if st.t < 10.0 else look + PI)
				evs = play(sc, 18.0, watch)
				var c2 := _types(evs, "caught")
				var early := false
				for e in c2:
					if float(e["t"]) < 10.0:
						early = true
				if t.check(not early, "%s seed %d: caught while a crewmate watched it" % [place, i]):
					watched_safe += 1
				for e in c2:
					if str(e["playerId"]) == "a":
						released_caught += 1
						break
			# Peeking at it holds it; sat back does not.
			sc = scene(place, "hide-scene-%d" % i, ids)
			put_resident(sc.s, sc.at, yaw_at + PI, 30.0)
			play(sc, 2.0)
			var gap_yaw := Seek.yaw_toward(float(Floor.dir_dx(sc.h.gap)), float(Floor.dir_dy(sc.h.gap)))
			var to_it := Seek.yaw_toward(sc.at.x - sc.front.x, sc.at.z - sc.front.z)
			play(sc, 4.5, Callable(), to_it, false)
			if sc.s.orderly.held:
				peek_held += 1
			play(sc, 7.5, Callable(), null, false)
			if not sc.s.orderly.held:
				sat_not_held += 1
			t.check(absf(Run._wrap_pi(to_it - gap_yaw)) < 0.2, "%s seed %d: the resident is not in the gap" % [place, i])
	t.check(tried >= (4 if t.quick else 24), "only %d scenes could be set up" % tried)
	t.eq(seen_caught, tried, "scenes where a player seen getting in was caught")
	t.eq(unseen_safe, tried, "scenes where a player not seen getting in was left alone")
	t.eq(peek_held, tried, "scenes where peeking at it held it")
	t.eq(sat_not_held, tried, "scenes where sitting back did not hold it")
	t.note("%d scenes on Clinics and Annexes: seen getting in, caught %d; not seen, left alone %d; hunted but lost, it stood and gave up %d; watched by a crewmate, safe while watched %d (caught once the watcher looked away %d); peeking held it %d, sat back did not %d" % [
		tried, seen_caught, unseen_safe, stood, watched_safe, released_caught, peek_held, sat_not_held])
	if not t.quick:
		t.check(stood > 0 and released_caught > 0, "the lost track or the release never happened (vacuous)")

## A walkable spot 10 or more steps from the hide's front with no clear line to it, or null.
static func _out_of_sight(sc: Scene) -> Variant:
	var plan := sc.s.plan
	var dist := Floor.distances_from(plan, Move.cell_of(plan, sc.front))
	for k in dist.size():
		if dist[k] < 10 or dist[k] > 16:
			continue
		var c := Floor.pos_from_index(plan, k)
		if c.level != sc.h.level:
			continue
		var b := Move.body_at_cell(plan, c)
		if not Hiding.in_view(plan, Hiding.Watcher.make(b, Seek.yaw_toward(sc.front.x - b.x, sc.front.z - b.z), Entity.kind_of(sc.s.orderly).height), sc.front):
			return b
	return null

## A spot for the watcher with the resident in plain view, further from it by walking than the hide's
## front (so once let go it looks in first), or null.
static func _watch_spot(sc: Scene) -> Variant:
	var plan := sc.s.plan
	var dist := Floor.distances_from(plan, Move.cell_of(plan, sc.at))
	var front_steps := dist[Floor.pos_index(plan, Move.cell_of(plan, sc.front))]
	for k in dist.size():
		if dist[k] < front_steps + 2 or dist[k] > front_steps + 6:
			continue
		var c := Floor.pos_from_index(plan, k)
		if c.level != sc.h.level:
			continue
		var b := Move.body_at_cell(plan, c)
		var v := Entity.PlayerView.make("w", b, 1.65, Seek.yaw_toward(sc.at.x - b.x, sc.at.z - b.z), 0.0, 90.0, 70.0, true)
		var one: Array[Entity.PlayerView] = [v]
		if Entity.seen_by(plan, sc.at, one, Entity.kind_of(sc.s.orderly)) != null:
			return b
	return null

# --- 6. On the wire: the hiding block (net/host.gd hiding_block) in the seek block's shape.

func test_hiding_on_the_wire(t: T) -> void:
	_apply_break()
	var ids: Array[String] = ["a", "b"]
	var sc := scene(&"clinic", "hide-scene-0", ids)
	if not t.check(sc.ok, "no scene"):
		return
	t.check(Host.seek_block(sc.s) == null, "a seek block before anyone hid")
	put_resident(sc.s, sc.at, 0.0, 30.0)
	play(sc, 2.0)
	var blk: Variant = Host.seek_block(sc.s)
	if not t.check(blk is Dictionary, "no block once a player hid"):
		return
	var c := Protocol._V.new()
	var back := Protocol.dec_seek(c, JSON.parse_string(JSON.stringify(Protocol.enc_seek(blk))))
	t.check(not c.bad, "the block does not decode")
	var rows := {}
	for p: Dictionary in back.get("players", []):
		rows[str(p["id"])] = p
	var a: Dictionary = rows.get("a", {})
	t.check(str(a.get("phase", "")) == "inside" and int(a.get("hide", -1)) == sc.h.id and str(a.get("status", "")) == "ok", "a's row: %s" % str(a))
	var b: Dictionary = rows.get("b", {})
	t.check(str(b.get("phase", "")) == "out" and int(b.get("hide", 0)) == -1, "b's row: %s" % str(b))
	t.check(int(back.get("n", 1)) == 0 and not bool(back.get("counting", true)), "a count in the hiding block")
	t.note("the hiding block goes as a seek block: a inside hide %d, b out, no count" % sc.h.id)

func test_annex_top_ups_reuse_fixed_wall_slots(t: T) -> void:
	var plan := Annex.generate_annex("arrival-a", 3)
	var ctx := Hides._ctx(plan)
	for room in plan.rooms:
		var expected := Playroom._slots(plan, room, ctx.doors)
		if expected.is_empty():
			continue
		var first := Hides._top_up_slots(ctx, room)
		var slot := expected[0]
		ctx.used[Floor.pos_index(plan, Floor.Pos.make(room.level, slot.x, slot.y))] = true
		var repeat := Hides._top_up_slots(ctx, room)
		t.eq(first, expected, "the same ordered perimeter slots")
		t.check(is_same(first, repeat), "a later cabinet reuses the static perimeter after live occupancy changes")
		return
	t.check(false, "the Annex provides at least one wall slot")


func test_annex_top_up_arrival_layouts_match_the_previous_resolver(t: T) -> void:
	var baseline := {
		"arrival-a": "7b434c2b389d0c2a",
		"arrival-b": "4c0f3dddb6336593",
		"arrival-c": "16b31fe2a1dbf319",
		"arrival-d": "d74c8bb0494947ff",
	}
	for seed: String in baseline:
		var plan := Annex.generate_annex(seed, 3)
		t.eq(Hides.hash_of(Hides.hides_for(plan)), baseline[seed], "%s keeps every hide and its ID, including top-ups" % seed)
