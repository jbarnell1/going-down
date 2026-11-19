# The Arboretum's rules: noise and the Groundskeeper's Hearing (sim/noise.gd, sim/hearing.gd, and their part of
# sim/run.gd; piece AR1). Proved here by the test's own geometry and the design's numbers restated (not the
# rules' constants):
#   1. Over seeded bot floors (200, 12 in the quick set): three bots wander a garden of pillars, standing,
#      creeping, walking, sprinting and whistling by the seed. On every tick: with a noise inside its radius of
#      a listening Groundskeeper (this test's own table), it tilts or strikes on that very tick; it only ever
#      goes to the place of a noise, made since its last arrival by the player it names; whoever it takes was
#      within 2 m of it, and made a noise that tick or the lean ended that tick; and when a lean ends it takes
#      exactly the bots on their feet within 2 m of it.
#   2. It walks to where the noise WAS: a bot that whistles and creeps more than the reach away on moss is never
#      taken, and it arrives at the whistle's place.
#   3. The lean and the snatch: a bot that stays within the reach of the place is always taken when the lean
#      ends; one standing between the reach and the lean range is leaned over and never taken; one that creeps
#      out of reach on moss during the lean is not taken; one that creeps out over litter is; and the lean's
#      pose and length are identical in every case until its last tick.
#   4. The survival table: a whistle at 18 m, a twig crack at 12 m, a walk on litter at 8 m and a walk on moss
#      at 3 m bring it in 0.8 s + distance / 6 m/s, each within one tick, and a creep on moss gets 4.56, 3.36,
#      2.56 and 1.56 m from the place by then (the last is inside its reach).
#   5. An escaping runner can leave earshot during the tilt. A close sustained sprint is caught,
#      unless a friend draws the keeper off. All allowed pursuit speeds exceed the sprint.
#   6. The instrument records only on coming and leaning ticks, to holders in range, never while it listens,
#      tilts or sweeps; the lean pays 1.5 at the lean range rising to 3 at its reach.
#   7. A louder or a nearer noise retargets it on that tick; a quieter one further off does not; ties resolve
#      the same in three reruns (the louder, then the nearer, then the lower id).
#   8. The catch: down while the player has a heal left on the floor ("downed" with `more`), the heal's own noise
#      brings it, and the third snatch is "out" at once; `groundskeeper.heals` moves the limit.
#   9. A player sitting in a hide is silent and safe unless the noise it came to was that hide's own.
#  10. Off elsewhere: with its resident off nothing is ever heard or taken; a crew in the car is never taken; and
#      an instrument tick with no pay computes exactly as before.
#  11. Searching and carrying on the garden floor (sim/findables.gd, sim/inventory.gd, both on as in the game's
#      rooms). The Arboretum has no findables: the place says so, no piece of a real floor is searchable, and a
#      player holding the search key starts no search and makes no noise. The four slots work as anywhere:
#      a carton put down lies on the garden's ground, a crewmate in reach picks it up, the Groundskeeper does
#      not hear either, and whoever it takes drops all they carry where they fall. Nothing is made or lost.
# Deliberate breaks (PROP_HEARING_BREAK): moss_creep (it hears a silent creep on moss: 3's creeps-out-on-moss
# goes red), far_take (it takes a player standing outside its reach at the end of a lean: 3 goes red),
# short_lean (the lean is shorter when it will not snatch: 3's identical lean goes red), record_listening (the
# instrument records while it listens: 6 goes red), dup_drop (sim/inventory.gd's own break: a dropped carton
# stays in the hand as well: 11's "nothing made or lost" goes red).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Noises = preload("res://sim/noise.gd")
const Hearing = preload("res://sim/hearing.gd")
const Instr = preload("res://sim/instrument.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const Stamina = preload("res://sim/stamina.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Protocol = preload("res://net/protocol.gd")
const Findables = preload("res://sim/findables.gd")
const Inventory = preload("res://sim/inventory.gd")
const Furniture = preload("res://sim/furniture.gd")
const Arboretum = preload("res://sim/arboretum.gd")
const PropInventory = preload("res://tests/prop_inventory.gd")

const DT := 0.05
const EPS := 1e-6
## The design's numbers, restated on purpose (docs: the Arboretum, sections 2 and 4).
const O_REACH := 2.0
const O_LEAN_RANGE := 4.0
const O_LEAN := 2.5
const O_BEAT := 0.5
const O_SWEEP := 2.0
const O_TILT := 0.8
const O_SPEED := 6.0
const O_DARK_SPEED := 6.5
const O_CREEP := 1.2
const O_WALK := 3.0
const O_SPRINT := 5.0
## The design's noise table: [gait][surface] and the events.
const O_CREEP_LOUD := 2.5
const O_WALK_MOSS := 3.0
const O_WALK_LITTER := 8.0
const O_WALK_GRAVEL := 10.0
const O_TWIG := 12.0
const O_SPRINT_R := 14.0
const O_EMOTE := 18.0
const R := 0.3

const W := 40
const H := 40

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_HEARING_BREAK")
	Noises.test_break = b if b == "moss_creep" else ""
	Hearing.test_break = b if (b == "far_take" or b == "short_lean" or b == "record_listening") else ""
	Inventory.test_break = b if b == "dup_drop" else ""

# ---------------------------------------------------------------------------------------------
# A garden for the tests: an open field with a void border (the car's space at the top), and its ground.

## The field: W x H cells of open ground inside a two-cell void border, the landing at the top middle. With a
## seed, pillars of thicket stand on a lattice (never sealing anything).
static func field(seed: String = "") -> Floor.FloorPlan:
	var p := Floor.FloorPlan.new()
	p.place = Places.ARBORETUM
	p.seed = "field:" + seed
	p.depth = 5
	p.width = W
	p.height = H
	p.cell_size = 2
	var l0: Array = []
	var l1: Array = []
	for y in H:
		for x in W:
			var open := x >= 2 and y >= 2 and x < W - 2 and y < H - 2
			l0.append(Floor.CORRIDOR if open else Floor.VOID)
			l1.append(Floor.VOID)
	if seed != "":
		var rng := Rng.make_rng("field:" + seed)
		for cy in range(5, H - 5, 4):
			for cx in range(5, W - 5, 4):
				var roll := rng.next()
				if roll < 0.45:
					l0[cy * W + cx] = Floor.VOID
					if roll < 0.2:
						l0[cy * W + cx + 1] = Floor.VOID
						l0[(cy + 1) * W + cx] = Floor.VOID
						l0[(cy + 1) * W + cx + 1] = Floor.VOID
	var lx := W / 2
	l0[2 * W + lx] = Floor.LANDING
	p.cells = [l0, l1]
	p.landing = Floor.Pos.make(0, lx, 2)
	p.doors.append(Floor.Door.make(0, lx, 2, lx, 3))
	p.doors.append(Floor.Door.make(0, lx, 2, lx - 1, 2))
	p.doors.append(Floor.Door.make(0, lx, 2, lx + 1, 2))
	p.entity_start = Floor.Pos.make(0, lx, H - 6)
	var g := Noises.Ground.make(W, H)
	for y in H:
		for x in W:
			if l0[y * W + x] != Floor.VOID:
				g.put(x, y, Noises.LITTER)
	p.ground = g
	return p

## The field with stripes: moss where x < 14 (cells), litter to 26, gravel beyond; a twig fall (id 0) on the
## litter at cells (19..20, 30).
static func striped() -> Floor.FloorPlan:
	var p := field()
	var g: Noises.Ground = p.ground
	for y in H:
		for x in W:
			if g.surface(x, y) == Noises.NONE:
				continue
			g.put(x, y, Noises.MOSS if x < 14 else (Noises.LITTER if x < 26 else Noises.GRAVEL))
	g.put(19, 30, Noises.TWIG, 0)
	g.put(20, 30, Noises.TWIG, 0)
	return p

static func at(x: float, z: float) -> Move.Body:
	return Move.Body.make(x, z, 0, 0.0)

static func flat(a: Move.Body, b: Move.Body) -> float:
	return M.hypot2(a.x - b.x, a.z - b.z)

## The test's own noise table: the radius of a gait on a surface.
static func o_radius(gait: StringName, surface: int) -> float:
	if gait == &"sprint":
		return O_SPRINT_R
	if gait == &"creep":
		return 0.0 if surface == Noises.MOSS else O_CREEP_LOUD
	if surface == Noises.MOSS:
		return O_WALK_MOSS
	return O_WALK_GRAVEL if surface == Noises.GRAVEL else O_WALK_LITTER

static func o_speed(gait: StringName) -> float:
	return O_SPRINT if gait == &"sprint" else (O_CREEP if gait == &"creep" else O_WALK)

# ---------------------------------------------------------------------------------------------
# A driver for sim/hearing.gd alone.

class Bot:
	var id: String
	var body: Move.Body
	## &"stand" | &"creep" | &"walk" | &"sprint", and the way it goes.
	var gait: StringName = &"stand"
	var dx := 0.0
	var dz := 0.0
	var emote := false
	var up := true
	var hide := -1
	var hide_noise := -1
	## The noise this test's table says it made on the last tick (0 for none), and where.
	var o_r := 0.0
	var o_at: Move.Body = null

	static func make(id_: String, body_: Move.Body) -> Bot:
		var b := Bot.new()
		b.id = id_
		b.body = body_
		return b

	func go(gait_: StringName, dx_: float = 0.0, dz_: float = 0.0) -> void:
		gait = gait_
		var d := M.hypot2(dx_, dz_)
		dx = dx_ / d if d > 0.0 else 0.0
		dz = dz_ / d if d > 0.0 else 0.0

class Sim:
	var plan: Floor.FloorPlan
	var ground: Noises.Ground
	var k: Hearing.Keeper
	var bots: Array[Bot] = []
	var dark := false
	var tuning: Settings.Values = null
	var events: Array[Dictionary] = []
	var taken := {}
	var ticks := 0
	## The bots the rules saw on the tick before (a body's first tick on the floor is never a step).
	var present := {}

	static func make(plan_: Floor.FloorPlan, keeper_at: Move.Body) -> Sim:
		var s := Sim.new()
		s.plan = plan_
		s.ground = plan_.ground
		s.k = Hearing.create(keeper_at, 0.0)
		return s

	func bot(id: String, body: Move.Body) -> Bot:
		var b := Bot.make(id, body)
		bots.append(b)
		return b

	func tick() -> Hearing.Step:
		var people: Array[Hearing.Person] = []
		for b in bots:
			b.o_r = 0.0
			b.o_at = null
			if not b.up:
				continue
			var before := b.body
			if b.gait != &"stand" and b.hide < 0:
				var sp := O_SPRINT if b.gait == &"sprint" else (O_CREEP if b.gait == &"creep" else O_WALK)
				b.body = Move.move_with_collision(plan, b.body, b.dx * sp * 0.05, b.dz * sp * 0.05, 0.3)
			var p := Hearing.Person.make(b.id, b.body, &"walk" if b.gait == &"stand" else b.gait)
			p.emote = b.emote
			p.hide = b.hide
			p.hide_noise = b.hide_noise
			people.append(p)
			# This test's own table.
			var moved := M.hypot2(b.body.x - before.x, b.body.z - before.z) / 0.05 if present.has(b.id) else 0.0
			if b.hide < 0 or b.hide_noise >= 0:
				if moved > 0.2 and b.gait != &"stand":
					var gs := StringName(b.gait)
					var sf := ground.surface_at(b.body.x, b.body.z)
					if gs == &"sprint":
						b.o_r = 14.0
					elif gs == &"creep":
						b.o_r = 0.0 if sf == Noises.MOSS else 2.5
					else:
						b.o_r = 3.0 if sf == Noises.MOSS else (10.0 if sf == Noises.GRAVEL else 8.0)
				if b.hide_noise >= 0:
					b.o_r = maxf(b.o_r, 4.0)
				if b.emote:
					b.o_r = 18.0
				if b.o_r > 0.0:
					b.o_at = b.body
		present = {}
		for p in people:
			present[p.id] = true
		var none: Array[Noises.Sound] = []
		var r := Hearing.step(plan, ground, k, people, none, dark, 0.05, tuning)
		k = r.state
		ticks += 1
		for e in r.events:
			events.append(e)
		for id in r.taken:
			taken[id] = true
			for b in bots:
				if b.id == id:
					b.up = false
		for b in bots:
			b.emote = false
			b.hide_noise = -1
		return r

	## One tick with everyone standing: the rules then know where each bot was (a body's first tick on the
	## floor is never a step).
	func warm() -> void:
		var gaits: Array = []
		for b in bots:
			gaits.append([b.gait, b.emote, b.hide_noise])
			b.gait = &"stand"
			b.emote = false
			b.hide_noise = -1
		tick()
		for n in bots.size():
			bots[n].gait = gaits[n][0]
			bots[n].emote = gaits[n][1]
			bots[n].hide_noise = gaits[n][2]

	func of_type(type: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for e in events:
			if e["type"] == type:
				out.append(e)
		return out

	## Ticks until `type` happens (at most `most` seconds); -1 if it does not.
	func until(type: String, most: float) -> int:
		var n := 0
		while n * 0.05 < most:
			var r := tick()
			n += 1
			for e in r.events:
				if e["type"] == type:
					return n
		return -1

# ---------------------------------------------------------------------------------------------
# 1. Bot floors.

func _bot_floor(t: T, i: int, secs: float, tally: Dictionary) -> void:
	var plan := field("bots-%d" % i)
	var rng := Rng.make_rng("hearing-bots:%d" % i)
	var sim := Sim.make(plan, Move.body_at_cell(plan, plan.entity_start))
	var cs := 2.0
	for n in 3:
		var c := Floor.Pos.make(0, 4 + rng.int_in(0, W - 9), 6 + rng.int_in(0, H - 17))
		while not Floor.is_walkable(plan, 0, c.x, c.y):
			c = Floor.Pos.make(0, 4 + rng.int_in(0, W - 9), 6 + rng.int_in(0, H - 17))
		sim.bot("b%d" % n, at((c.x + 0.5) * cs, (c.y + 0.5) * cs))
	sim.warm()
	var noisy := {}          # {id: made a noise since its last arrival}
	var places := {}         # {"x,z": id} every noise place this floor
	var fails := 0
	var steps := int(secs / DT)
	for step in steps:
		# The bots change their minds now and then.
		for b in sim.bots:
			if rng.chance(0.012):
				var roll := rng.next()
				var a := rng.next() * TAU
				if roll < 0.45:
					b.go(&"stand")
				elif roll < 0.65:
					b.go(&"creep", cos(a), sin(a))
				elif roll < 0.9:
					b.go(&"walk", cos(a), sin(a))
				else:
					b.go(&"sprint", cos(a), sin(a))
			if rng.chance(0.004):
				b.emote = true
				if rng.chance(0.6):
					b.go(&"stand")
		var before := sim.k
		var r := sim.tick()
		var after := sim.k
		# The test's own hearing: every noise inside its radius of where it stood.
		var o_heard := false
		var o_close := {}
		for b in sim.bots:
			if b.o_r <= 0.0 or b.o_at == null:
				continue
			noisy[b.id] = true
			places["%.6f,%.6f" % [b.o_at.x, b.o_at.z]] = b.id
			var d := flat(b.o_at, before.body)
			if d <= b.o_r + EPS:
				o_heard = true
				if d <= O_REACH + EPS:
					o_close[b.id] = true
		if o_heard:
			tally["heard"] = int(tally.get("heard", 0)) + 1
		# (a) A listening Groundskeeper tilts (or strikes) on the tick of the noise.
		if before.mode == &"listening" and o_heard and not (after.mode == &"tilt" or after.mode == &"strike"):
			fails += 1
			t.check(fails > 3, "floor %d tick %d: a noise inside its radius, and it is %s (not tilting)" % [i, step, after.mode])
		if before.mode == &"listening" and not o_heard and after.mode != &"listening":
			fails += 1
			t.check(fails > 3, "floor %d tick %d: no noise inside its radius, and it went %s" % [i, step, after.mode])
		# (b) It goes only to the place of a noise, made since its last arrival by the player it names.
		if after.target != null:
			var key := "%.6f,%.6f" % [after.target.x, after.target.z]
			if not (places.has(key) and places[key] == after.target.by and noisy.get(after.target.by, false)):
				fails += 1
				t.check(fails > 3, "floor %d tick %d: it goes to (%s), which is not the place of a noise by %s since it last arrived" % [i, step, key, after.target.by])
		if after.body.x != before.body.x or after.body.z != before.body.z:
			tally["moved"] = int(tally.get("moved", 0)) + 1
			if before.mode != &"coming" or before.target == null:
				fails += 1
				t.check(fails > 3, "floor %d tick %d: it moved while %s" % [i, step, before.mode])
		# (c) Whoever it takes was within 2 m of it, and made a noise there or the lean ended.
		var lean_end := false
		for e in r.events:
			if e["type"] == "keeperLeanEnd" and e["why"] == "end":
				lean_end = true
		for id in r.taken:
			tally["taken"] = int(tally.get("taken", 0)) + 1
			var bb: Bot = null
			for b in sim.bots:
				if b.id == id:
					bb = b
			var d := flat(bb.body, before.body)
			if not (d <= O_REACH + EPS and (o_close.has(id) or lean_end)):
				fails += 1
				t.check(fails > 3, "floor %d tick %d: it took %s at %.2f m (noise up close %s, lean ended %s)" % [i, step, id, d, o_close.has(id), lean_end])
		# (d) A lean's end takes exactly those on their feet within its reach.
		if lean_end:
			tally["leans"] = int(tally.get("leans", 0)) + 1
			for b in sim.bots:
				var was_up := b.up or r.taken.has(b.id)
				var inside := was_up and flat(b.body, before.body) <= O_REACH + EPS
				if inside != r.taken.has(b.id):
					fails += 1
					t.check(fails > 3, "floor %d tick %d: the lean ended with %s at %.2f m, taken %s" % [i, step, b.id, flat(b.body, before.body), r.taken.has(b.id)])
		for e in r.events:
			if e["type"] == "keeperArrived":
				noisy = {}
		# Taken bots get back up somewhere else after a while (so the floor stays busy).
		for b in sim.bots:
			if not b.up and rng.chance(0.01):
				b.up = true
				b.go(&"stand")

func test_bot_floors(t: T) -> void:
	_apply_break()
	var n := 12 if t.quick else 200
	var tally := {}
	for i in n:
		_bot_floor(t, i, 60.0, tally)
	if not t.quick:
		t.check(int(tally.get("taken", 0)) >= n and int(tally.get("leans", 0)) >= n / 10, "not vacuous: %s" % str(tally))
	t.check(int(tally.get("heard", 0)) > 0 and int(tally.get("moved", 0)) > 0, "it heard and came at all: %s" % str(tally))
	t.note("%d floors x 60 s: %s" % [n, str(tally)])

# ---------------------------------------------------------------------------------------------
# 2. It walks to where the noise was.

func test_it_goes_to_where_the_noise_was(t: T) -> void:
	_apply_break()
	var plan := striped()
	var n := 8 if t.quick else 40
	var arrived := 0
	for i in n:
		var rng := Rng.make_rng("where:%d" % i)
		# On the moss (x under 28 m): the bot whistles, then creeps away on moss.
		var bx := 8.0 + rng.next() * 14.0
		var bz := 20.0 + rng.next() * 40.0
		var d := 4.0 + rng.next() * 13.5
		var a := -0.9 + rng.next() * 1.8
		var sim := Sim.make(plan, at(bx + cos(a) * d, bz + sin(a) * d))
		var b := sim.bot("a", at(bx, bz))
		b.emote = true
		sim.tick()
		var place := b.body
		# Away from it, staying on the moss.
		b.go(&"creep", -1.0, 0.3 if bz < 40.0 else -0.3)
		var got := sim.until("keeperArrived", 12.0)
		t.check(got > 0, "setup %d: it never arrived" % i)
		if got < 0:
			continue
		arrived += 1
		t.check(flat(sim.k.body, place) < 1e-3, "setup %d: it stands %.3f m from where the whistle was" % [i, flat(sim.k.body, place)])
		var away := flat(b.body, place)
		for _n in int(6.0 / DT):
			sim.tick()
		if away > O_REACH + 0.1:
			t.check(not sim.taken.has("a"), "setup %d: the bot was %.2f m from the place when it arrived, and was taken" % [i, away])
	t.note("%d whistles: it arrived at the place every time (%d)" % [n, arrived])

# ---------------------------------------------------------------------------------------------
# 3. The lean and the snatch.

## One lean: a bot whistles at `spot` with it `d` away, then does `plan_of` (a Callable(bot, sim, phase) called
## each tick with phase "coming" or "lean"). Returns {taken, leaned, pose (the lean's ticks as rows), ticks}.
func _lean_case(plan: Floor.FloorPlan, spot: Move.Body, d: float, act: Callable) -> Dictionary:
	var sim := Sim.make(plan, at(spot.x + d, spot.z))
	var b := sim.bot("a", spot)
	b.emote = true
	sim.tick()
	var pose: Array = []
	var leaned := false
	var beat := 0
	for _n in int(14.0 / DT):
		act.call(b, sim, String(sim.k.mode))
		var before := sim.k
		sim.tick()
		if before.mode == &"lean" and sim.k.mode == &"lean":
			# A tick of the lean before its last: the pose.
			pose.append([String(sim.k.mode), String(sim.k.anim), snappedf(sim.k.anim_time, 1e-6), sim.k.moving])
		if sim.k.mode == &"lean":
			leaned = leaned or sim.k.lean_id == "a"
		if sim.k.mode == &"beat":
			beat += 1
		if sim.k.mode == &"listening" and sim.k.arrived_at > 0.0:
			break
	return {"taken": sim.taken.has("a"), "leaned": leaned, "pose": pose, "beat": beat, "sim": sim}

func test_the_lean_and_the_snatch(t: T) -> void:
	_apply_break()
	var plan := striped()
	var n := 4 if t.quick else 16
	for i in n:
		var rng := Rng.make_rng("lean:%d" % i)
		var d := 9.0 + rng.next() * 8.0
		var moss := at(10.0 + rng.next() * 6.0, 24.0 + rng.next() * 30.0)
		# (a) Stays where the noise was: taken when the lean ends.
		var stay := _lean_case(plan, moss, d, func(_b: Bot, _s: Sim, _m: String) -> void: pass)
		t.check(stay["taken"] and stay["leaned"], "case %d: a bot that stayed at the place was not taken (leaned %s)" % [i, stay["leaned"]])
		# (a2) Stays within the reach of the place (creeps 1.5 m off on moss, then stands): taken.
		var near := _lean_case(plan, moss, d, func(b: Bot, _s: Sim, _m: String) -> void:
			if flat(b.body, moss) < 1.5:
				b.go(&"creep", -1.0, 0.0)
			else:
				b.go(&"stand"))
		t.check(near["taken"], "case %d: a bot standing 1.5 m from the place was not taken" % i)
		# (b) Stands between the reach and the lean range (3 m off): leaned over, never taken.
		var between := _lean_case(plan, moss, d, func(b: Bot, _s: Sim, _m: String) -> void:
			if flat(b.body, moss) < 3.0:
				b.go(&"creep", -1.0, 0.0)
			else:
				b.go(&"stand"))
		t.check(between["leaned"] and not between["taken"], "case %d: a bot standing 3 m from the place: leaned %s, taken %s" % [i, between["leaned"], between["taken"]])
		t.check(absf(float(between["beat"]) * DT - O_BEAT) <= DT + EPS, "case %d: the beat after lasted %.2f s" % [i, float(between["beat"]) * DT])
		# (c) Stands at the place until the lean starts, then creeps out of reach on moss: not taken.
		var slide := _lean_case(plan, moss, d, func(b: Bot, _s: Sim, m: String) -> void:
			if m == "lean":
				b.go(&"creep", -1.0, 0.0)
			else:
				b.go(&"stand"))
		t.check(slide["leaned"] and not slide["taken"], "case %d: a bot that crept out of reach on moss during the lean: leaned %s, taken %s" % [i, slide["leaned"], slide["taken"]])
		# (d) The same over litter: taken.
		var litter := at(30.0 + rng.next() * 16.0, moss.z)
		var crunch := _lean_case(plan, litter, d, func(b: Bot, _s: Sim, m: String) -> void:
			if m == "lean":
				b.go(&"creep", -1.0, 0.0)
			else:
				b.go(&"stand"))
		t.check(crunch["taken"], "case %d: a bot that crept out over litter during the lean was not taken" % i)
		# The lean is identical, to its last tick, whether it will take them or not.
		var want: Array = stay["pose"]
		t.check(absf((want.size() + 1) * DT - O_LEAN) <= DT + EPS, "case %d: the lean lasted %.2f s" % [i, (want.size() + 1) * DT])
		for other: Dictionary in [near, between, slide]:
			var got: Array = other["pose"]
			t.check(got == want, "case %d: the lean's pose or length differs between a bot in reach and one out of it (%d ticks against %d)" % [i, got.size(), want.size()])
	t.note("%d places x 5 bots: stays, 1.5 m, 3 m, creeps out on moss, creeps out over litter" % n)

# ---------------------------------------------------------------------------------------------
# 4. The survival table.

func test_the_survival_table(t: T) -> void:
	_apply_break()
	var plan := striped()
	var lines: PackedStringArray = []
	# [name, radius, the bot's first move (gait), where it starts (x, z), the creep's direction]
	# Moss is x < 28 m, litter to 52 m; the twig fall is at cells (19..20, 30): x 38..42, z 60..62.
	var rows := [
		["a whistle", O_EMOTE, &"emote", at(20.0, 40.0), 4.56, true],
		["a twig crack", O_TWIG, &"twig", at(37.9, 61.0), 3.36, true],
		["a walk on litter", O_WALK_LITTER, &"walk", at(28.2, 40.0), 2.56, true],
		["a walk on moss", O_WALK_MOSS, &"walk", at(20.0, 40.0), 1.56, false],
	]
	for row: Array in rows:
		var r: float = row[1]
		var start: Move.Body = row[3]
		var first: StringName = row[2]
		# The bot's one noise, on the first tick; the Groundskeeper stands at that noise's radius, to the east.
		var probe := Sim.make(plan, at(start.x + 30.0, start.z))
		var pb := probe.bot("a", start)
		probe.warm()
		if first == &"emote":
			pb.emote = true
		else:
			pb.go(&"walk", 1.0, 0.0)
		probe.tick()
		var place := pb.body
		var sim := Sim.make(plan, at(place.x + r - 0.001, place.z))
		var b := sim.bot("a", start)
		sim.warm()
		if first == &"emote":
			b.emote = true
		else:
			b.go(&"walk", 1.0, 0.0)
		var step0 := sim.tick()
		t.check(not step0.heard.is_empty() and sim.k.mode == &"tilt", "%s at %.1f m: not heard (%s)" % [row[0], r, sim.k.mode])
		t.check(absf(step0.heard[0].r - r) < EPS if not step0.heard.is_empty() else false, "%s: its radius is not %.1f m" % [row[0], r])
		# Then it creeps away on moss (west), at once.
		b.go(&"creep", -1.0, 0.0)
		var ticks := sim.until("keeperArrived", 10.0)
		var took := ticks * DT
		var want := O_TILT + r / O_SPEED
		t.check(ticks > 0 and absf(took - want) <= DT + EPS, "%s at %.1f m: it arrived after %.2f s, the table says %.2f" % [row[0], r, took, want])
		var away := flat(b.body, place)
		var want_away: float = row[4]
		t.check(absf(away - want_away) <= O_CREEP * DT * 2.0 + 0.05, "%s: the creep got %.2f m from the place, the table says %.2f" % [row[0], away, want_away])
		var out := away > O_REACH
		t.check(out == row[5], "%s: out of its reach on arrival %s, the table says %s" % [row[0], out, row[5]])
		t.check(sim.k.mode == &"lean" or away > O_LEAN_RANGE, "%s: within the lean range and not leaned to" % row[0])
		lines.append("%s at %.0f m: %.2f s, %.2f m%s" % [row[0], r, took, away, "" if out else " (inside its reach)"])
	t.note("; ".join(lines))

# ---------------------------------------------------------------------------------------------
# 5. Sprinting away never works.

## A bot sprints from `d` metres off in direction `a` (radians). `tank`: seconds of sprint in a full tank (0: an
## endless one); out of breath it walks until it can sprint again. Returns the seconds until it was taken, or -1.
func _sprint_case(plan: Floor.FloorPlan, i: int, d: float, from: float, a: float, tank: float, most: float) -> float:
	var centre := at(W * 1.0, H * 1.0)
	var sim := Sim.make(plan, centre)
	var start := at(centre.x + cos(from) * d, centre.z + sin(from) * d)
	if not Floor.is_walkable(plan, 0, int(start.x / 2.0), int(start.z / 2.0)) or Move.wall_clearance(plan, 0, start.x, start.z) < R:
		return -2.0
	var b := sim.bot("a", start)
	sim.warm()
	var st := Stamina.fresh_stamina(tank if tank > 0.0 else 5.0)
	var turn := Rng.make_rng("sprint-turn:%d" % i)
	for n in int(most / DT):
		var gait := &"sprint"
		if tank > 0.0:
			gait = Stamina.gait_for(st, true, false, true, INF)
		b.go(gait, cos(a), sin(a))
		var before := b.body
		sim.tick()
		var sp := flat(b.body, before) / DT
		if tank > 0.0:
			st = Stamina.step_stamina(st, gait, sp, DT)
		if sim.taken.has("a"):
			return (n + 1) * DT
		# Stopped by the thicket or the edge: it turns and keeps running.
		if sp < 1.0:
			a += 1.2 + turn.next() * 2.0
	return -1.0

func test_close_sustained_sprints_are_caught(t: T) -> void:
	_apply_break()
	var n := 20 if t.quick else 200
	var worst := 0.0
	var worst_tank := 0.0
	var ran := 0
	for i in n:
		var rng := Rng.make_rng("sprint:%d" % i)
		var plan := field("sprint-%d" % (i % 10))
		var d := 2.2 + rng.next() * 3.0
		var from := rng.next() * TAU
		var a := rng.next() * TAU
		var got := _sprint_case(plan, i, d, from, a, 0.0, 120.0)
		if got == -2.0:
			continue
		ran += 1
		t.check(got > 0.0, "start %d: a bot sprinting from %.1f m (direction %.2f) was never taken in 120 s" % [i, d, a])
		worst = maxf(worst, got)
		# With the game's tank (7 s paced), on litter: out of breath it walks, and is run down all the same.
		var tanked := _sprint_case(plan, i, d, from, a, Stamina.PACED_SPRINT_SECONDS, 120.0)
		t.check(tanked > 0.0, "start %d: a bot sprinting with the game's tank from %.1f m was never taken in 120 s" % [i, d])
		worst_tank = maxf(worst_tank, tanked)
	t.check(ran >= n * 3 / 4, "only %d of %d starts stood on open ground" % [ran, n])
	# Unless a friend's louder noise retargets it first.
	var plan := field()
	var sim := Sim.make(plan, at(40.0, 40.0))
	var runner := sim.bot("a", at(40.0, 50.0))
	var friend := sim.bot("b", at(52.0, 34.0))
	sim.warm()
	runner.go(&"sprint", 0.0, 1.0)
	for _n in int(1.5 / DT):
		sim.tick()
	t.check(sim.k.mode == &"coming" and sim.k.target != null and sim.k.target.by == "a", "it comes for the sprinter (%s)" % sim.k.mode)
	friend.emote = true
	sim.tick()
	t.check(sim.k.target != null and sim.k.target.by == "b", "a friend's whistle (louder) retargets it on that tick")
	runner.go(&"stand")
	for _n in int(8.0 / DT):
		sim.tick()
	t.check(not sim.taken.has("a"), "the sprinter who stopped once it was drawn off was taken")
	# Its coming speed is at least 1.2 times the sprint under every allowed pair of settings.
	var pairs := 0
	var sp_row := Settings.row(&"player.sprint")
	for id: StringName in [&"groundskeeper.speed", &"groundskeeper.dark_speed"]:
		var row := Settings.row(id)
		t.check(row != null and row.wired, "%s is a wired setting" % id)
		if row == null:
			continue
		var v := row.lo
		while v <= row.hi + 1e-9:
			var sprint := sp_row.lo
			while sprint <= sp_row.hi + 1e-9:
				# (The other speed at its most, so only this one is on trial.)
				var asked := {&"player.sprint": Settings.snap(&"player.sprint", sprint),
					(&"groundskeeper.dark_speed" if id == &"groundskeeper.speed" else &"groundskeeper.speed"): 9.0}
				var ok := Settings.check(id, v, asked) == &""
				var fast := Settings.snap(id, v) >= 1.2 * Settings.snap(&"player.sprint", sprint) - 1e-6
				if ok:
					pairs += 1
				t.check(ok == fast or (not fast and not ok), "%s %.1f with a sprint of %.1f: allowed %s" % [id, v, sprint, ok])
				t.check(not ok or fast, "%s %.1f is allowed with a sprint of %.1f: under 1.2 times" % [id, v, sprint])
				sprint += sp_row.step
			v += row.step
	t.check(pairs > 100, "allowed pairs tried: %d" % pairs)
	t.check(O_SPEED >= 1.2 * O_SPRINT - 1e-9 and absf(Settings.today(&"groundskeeper.speed") - O_SPEED) < 1e-9 and absf(Settings.today(&"groundskeeper.dark_speed") - O_DARK_SPEED) < 1e-9, "today's speeds are the design's")
	# For the report: the game's tank on moss (a walk on moss carries 3 m).
	var moss_plan := field()
	var mg: Noises.Ground = moss_plan.ground
	for y in H:
		for x in W:
			if mg.surface(x, y) != Noises.NONE:
				mg.put(x, y, Noises.MOSS)
	var moss_taken := 0
	var moss_n := 0
	for i in (8 if t.quick else 40):
		var rng := Rng.make_rng("sprint:%d" % i)
		var got := _sprint_case(moss_plan, i, 2.2 + rng.next() * (O_SPRINT_R - 2.3), rng.next() * TAU, rng.next() * TAU, Stamina.PACED_SPRINT_SECONDS, 120.0)
		if got == -2.0:
			continue
		moss_n += 1
		if got > 0.0:
			moss_taken += 1
	t.note("%d starts: the endless sprinter taken in at most %.1f s, the game's tank on litter in at most %.1f s; %d allowed setting pairs; on a floor that is all moss the game's tank was taken %d times in %d" % [ran, worst, worst_tank, pairs, moss_taken, moss_n])

# ---------------------------------------------------------------------------------------------
# Runs on an Arboretum plan (the field), for the instrument and the catch.

## A run out on the field: the car gone, the crew of `ids` standing at `bodies`, the Groundskeeper at `keeper`.
static func garden_run(ids: Array[String], bodies: Dictionary, keeper: Move.Body, downs: bool = true, plan: Floor.FloorPlan = null) -> Run.RunState:
	var p := plan if plan != null else striped()
	var s := Run.create_run("hearing", ids, [], false, false, downs)
	s = s.copy()
	s.depth = 5
	s.plan = p
	s.car = Run.car_geometry(p)
	s.orderly = Places.create_resident(p)
	var o := s.orderly.copy()
	o.body = keeper
	s.orderly = o
	s.entity_id = Places.entity_id(p.place, 5)
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var players: Array[Run.RunPlayer] = []
	for pl in s.players:
		var np := pl.copy()
		np.body = bodies.get(pl.id, pl.body)
		np.aboard = false
		players.append(np)
	s.players = players
	return s

static func input(id: String, body: Move.Body, gait: StringName = &"walk", raised: bool = false) -> Run.PlayerInput:
	var i := Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)
	i.gait = gait
	i.raised = raised
	return i

static func one(i: Run.PlayerInput) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = [i]
	return out

static func player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

static func events_of(evs: Array[Dictionary], type: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == type:
			out.append(e)
	return out

# ---------------------------------------------------------------------------------------------
# 6. The instrument.

func test_the_instrument_records_only_coming_and_leaning(t: T) -> void:
	_apply_break()
	var ids: Array[String] = ["a", "b", "c"]
	var by_mode := {}
	var wrong := 0
	var missed := 0
	var pay_checked := 0
	var n := 3 if t.quick else 12
	for i in n:
		var rng := Rng.make_rng("record:%d" % i)
		# On the moss: a whistles and stands (it will be leaned over and taken), b holds an instrument 2.2 to 6 m
		# from the place, c holds one 20 m off (out of range).
		var spot := at(12.0 + rng.next() * 6.0, 30.0 + rng.next() * 20.0)
		var hd := 2.2 + rng.next() * 3.8
		var ha := rng.next() * TAU
		var bodies := {"a": spot, "b": at(spot.x + cos(ha) * hd, spot.z + sin(ha) * hd), "c": at(spot.x, spot.z - 20.0)}
		var s := garden_run(ids, bodies, at(spot.x + 12.0 + rng.next() * 5.0, spot.z + 3.0))
		# A few seconds of listening first, the instruments up: nothing must be recorded.
		for step in int(22.0 / DT):
			var ins: Array[Run.PlayerInput] = []
			for id in ids:
				if player(s, id).status != &"ok":
					continue
				var inp := input(id, bodies[id], &"walk", id != "a")
				inp.emote_sound = id == "a" and step == int(3.0 / DT)
				ins.append(inp)
			var r := Run.step_run(s, ins, DT)
			s = r.state
			var mode := String(s.garden.keeper.mode)
			for id: String in ["b", "c"]:
				var m := Instr.member(s.crew, id)
				var d := flat(bodies[id], s.orderly.body)
				var recording := m.instrument.rate > 0.0
				if recording:
					by_mode[mode] = int(by_mode.get(mode, 0)) + 1
					if mode != "coming" and mode != "lean":
						wrong += 1
						t.check(wrong > 3, "case %d: %s's instrument recorded while it was %s" % [i, id, mode])
				elif (mode == "coming" or mode == "lean") and d <= Instr.RECORD_RANGE - 0.01:
					missed += 1
					t.check(missed > 3, "case %d: %s holds an instrument %.1f m from it while it is %s, and records nothing" % [i, id, d, mode])
				if recording and mode == "lean":
					# The lean's pay: 1.5 at the lean range and beyond, rising to 3 at its reach.
					var w := clampf((O_LEAN_RANGE - d) / (O_LEAN_RANGE - O_REACH), 0.0, 1.0)
					var want := Instr.rate_at(d) * m.instrument.factor * (1.5 + 1.5 * w)
					pay_checked += 1
					t.check(absf(m.instrument.rate - want) < 1e-6 * maxf(1.0, want), "case %d: the lean pays %s %.3f a second at %.2f m, want %.3f" % [i, id, m.instrument.rate, d, want])
	t.check(int(by_mode.get("coming", 0)) > 0 and int(by_mode.get("lean", 0)) > 0 and pay_checked > 0, "not vacuous: recorded by mode %s" % str(by_mode))
	var far := Hearing.create(at(0.0, 0.0))
	far.mode = &"lean"
	t.check(absf(Hearing.lean_pay(far, O_LEAN_RANGE) - 1.5) < 1e-9 and absf(Hearing.lean_pay(far, O_REACH) - 3.0) < 1e-9 and absf(Hearing.lean_pay(far, 3.0) - 2.25) < 1e-9 and absf(Hearing.lean_pay(far, 9.0) - 1.5) < 1e-9,
		"the lean pays 1.5 at 4 m, 2.25 at 3 m, 3 at 2 m")
	far.mode = &"coming"
	t.check(Hearing.lean_pay(far, 2.0) == 1.0, "coming pays as usual")
	t.note("%d cases: recording ticks by its mode %s; the lean's pay checked on %d ticks" % [n, str(by_mode), pay_checked])

# ---------------------------------------------------------------------------------------------
# 7. Retargeting and ties.

func test_louder_or_nearer_retargets_and_ties(t: T) -> void:
	_apply_break()
	var plan := field()
	# It comes for a walker on litter (8 m); a sprint further off (louder) takes its place on that tick.
	var sim := Sim.make(plan, at(40.0, 40.0))
	var a := sim.bot("a", at(46.0, 40.0))
	var b := sim.bot("b", at(40.0, 53.0))
	var c := sim.bot("c", at(30.0, 40.0))
	var d := sim.bot("d", at(40.0, 46.0))
	var e := sim.bot("e", at(40.0, 32.5))
	var f := sim.bot("f", at(33.0, 40.0))
	sim.warm()
	a.go(&"walk", 0.0, 1.0)
	sim.tick()
	a.go(&"stand")
	t.check(sim.k.mode == &"tilt" and sim.k.target.by == "a", "it tilts to the walker")
	b.go(&"sprint", 1.0, 0.0)
	sim.tick()
	t.check(sim.k.target.by == "b" and sim.k.mode == &"tilt", "a louder noise during the tilt takes its place, and the tilt does not start again")
	var left := sim.k.left
	t.check(absf(left - (O_TILT - DT)) < 1e-9, "the tilt has %.2f s left" % left)
	b.go(&"stand")
	# A quieter noise further off is let go; a quieter noise nearer takes its place.
	c.go(&"walk", 0.0, -1.0)   # 8 m on litter, 10 m off: not heard at all
	sim.tick()
	t.check(sim.k.target.by == "b", "a noise outside its radius changes nothing")
	c.go(&"stand")
	d.go(&"walk", 1.0, 0.0)    # 8 m, quieter than the sprint, and nearer than the sprint's place
	sim.tick()
	t.check(sim.k.target.by == "d", "a quieter noise nearer to it takes its place")
	d.go(&"stand")
	e.go(&"walk", 1.0, 0.0)    # 8 m, as loud as the one it goes to, further off: the nearer target stays
	sim.tick()
	t.check(sim.k.target.by == "d", "a farther equally loud friend does not take its place")
	e.go(&"stand")
	f.go(&"creep", 0.0, 1.0)   # 2.5 m, 7 m off: not heard
	sim.tick()
	t.check(sim.k.target.by == "d", "a creep 7 m off is not heard")
	# Ties: two whistles at once, the same distance: the lower id, the same in three reruns. Then nearer wins.
	var firsts: Array = []
	for rerun in 3:
		var s2 := Sim.make(plan, at(40.0, 40.0))
		var p1 := s2.bot("m", at(48.0, 40.0))
		var p2 := s2.bot("k", at(32.0, 40.0))
		var p3 := s2.bot("z", at(40.0, 48.0))
		p1.emote = true
		p2.emote = true
		p3.emote = true
		s2.tick()
		firsts.append(s2.k.target.by)
		var trail: Array = []
		for _n in 60:
			s2.tick()
			trail.append([snappedf(s2.k.body.x, 1e-9), snappedf(s2.k.body.z, 1e-9), String(s2.k.mode)])
		firsts.append(trail.hash())
	t.check(firsts[0] == "k" and firsts[0] == firsts[2] and firsts[2] == firsts[4] and firsts[1] == firsts[3] and firsts[3] == firsts[5], "three whistles at one distance: the lower id, the same in three reruns (%s)" % str(firsts))
	var s3 := Sim.make(plan, at(40.0, 40.0))
	var q1 := s3.bot("a", at(50.0, 40.0))
	var q2 := s3.bot("b", at(40.0, 47.0))
	var q3 := s3.bot("c", at(34.0, 40.0))
	s3.warm()
	q1.emote = true
	q2.emote = true
	q3.go(&"sprint", 0.0, 1.0)
	s3.tick()
	t.check(s3.k.target.by == "b", "two whistles and a sprint: the louder, then the nearer (%s)" % s3.k.target.by)
	# Cross the hearing boundary during tilt, then turn back into range during pursuit.
	var s4 := Sim.make(plan, at(20.0, 40.0))
	var runner := s4.bot("a", at(33.5, 40.0))
	s4.warm()
	runner.go(&"sprint", 1.0, 0.0)
	var last_heard := 0.0
	var missed := 0
	for _n in 16:
		var ear := s4.k.body
		var step := s4.tick()
		if flat(ear, runner.body) <= O_SPRINT_R + EPS:
			last_heard = runner.body.x
		else:
			missed += 1
			t.check(step.heard.is_empty() and s4.k.target.x == last_heard, "an outside step leaves the target at the last heard place")
	t.check(missed > 0 and s4.k.mode == &"tilt", "the sprinter escapes earshot during the tilt")
	runner.go(&"stand")
	var before_pursuit := s4.k.body.x
	for _n in 4:
		s4.tick()
	t.check(s4.k.mode == &"coming" and s4.k.body.x > before_pursuit and s4.k.target.x == last_heard,
		"the keeper walks towards the last audible step while the runner is quiet")
	runner.go(&"sprint", -1.0, 0.0)
	var acquired := false
	for _n in 24:
		var ear := s4.k.body
		var step := s4.tick()
		if flat(ear, runner.body) <= O_SPRINT_R + EPS:
			acquired = step.heard.size() == 1 and s4.k.target.x == runner.body.x
			break
	t.check(acquired, "the first step back within earshot refreshes the target")
	# Every mode and pose it has is on the wire's lists.
	for m: String in ["listening", "tilt", "coming", "lean", "beat", "sweep", "strike"]:
		t.check(Protocol.MODES.has(m), "the wire has no code for its mode %s" % m)
	for an: String in ["idle", "tilt", "walk", "lean", "sweep", "catch"]:
		t.check(Protocol.ANIMS.has(an), "the wire has no code for its pose %s" % an)

# ---------------------------------------------------------------------------------------------
# 8. The catch: down, the two heals, out.

func test_the_catch_and_the_two_heals(t: T) -> void:
	_apply_break()
	# a claps and stands where it claps (and is taken there); b creeps in on moss and heals; c, 14 m off, whistles
	# it away as a goes down, then creeps off and stands (getting up beside it would be heard up close).
	for limit: int in ([2] if t.quick else [2, 0, 1, 3]):
		var ids: Array[String] = ["a", "b", "c"]
		var a_at := at(10.0, 40.0)
		var b_home := at(10.0, 45.0)
		var c_home := at(20.0, 50.0)
		var s := garden_run(ids, {"a": a_at, "b": b_home, "c": c_home}, at(16.0, 40.0))
		if limit != 2:
			s = Run.with_tuning(s, {&"groundskeeper.heals": float(limit)})
		var downs: Array[Dictionary] = []
		var outs: Array[Dictionary] = []
		var healed := 0
		var counted := true
		var b_body := b_home
		var c_body := c_home
		var others_taken := false
		var was_down := false
		for step in int(150.0 / DT):
			var a := player(s, "a")
			if a.status == &"out" or player(s, "b").status != &"ok" or player(s, "c").status != &"ok":
				others_taken = player(s, "b").status != &"ok" or player(s, "c").status != &"ok"
				break
			var mode: StringName = s.garden.keeper.mode if s.garden != null else &"listening"
			var kb := s.orderly.body
			var ia := input("a", a_at, &"walk")
			ia.emote_sound = a.status == &"ok" and mode == &"listening" and flat(b_body, b_home) < 0.05 and step > 20
			var ib := input("b", b_body, &"creep")
			if a.status == &"down":
				var d := flat(b_body, a.body)
				if d > 1.2:
					b_body = at(b_body.x + (a.body.x - b_body.x) / d * O_CREEP * DT, b_body.z + (a.body.z - b_body.z) / d * O_CREEP * DT)
				ib = input("b", b_body, &"creep")
				ib.use = d <= 1.4
			elif flat(b_body, b_home) > 0.0:
				var d2 := flat(b_body, b_home)
				var stp := minf(d2, O_CREEP * DT)
				b_body = at(b_body.x + (b_home.x - b_body.x) / d2 * stp, b_body.z + (b_home.z - b_body.z) / d2 * stp)
				ib = input("b", b_body, &"creep")
			var ic := input("c", c_body, &"creep")
			if a.status == &"down" and not was_down:
				ic.emote_sound = true
			elif a.status == &"down" and (mode == &"tilt" or mode == &"coming"):
				c_body = at(c_body.x, c_body.z + O_CREEP * DT)
				ic = input("c", c_body, &"creep")
			elif flat(c_body, c_home) > 0.0 and flat(kb, c_home) > 6.0:
				var d3 := flat(c_body, c_home)
				var st3 := minf(d3, O_CREEP * DT)
				c_body = at(c_body.x + (c_home.x - c_body.x) / d3 * st3, c_body.z + (c_home.z - c_body.z) / d3 * st3)
				ic = input("c", c_body, &"creep")
			was_down = a.status == &"down"
			var ins: Array[Run.PlayerInput] = [ia, ib, ic]
			var r := Run.step_run(s, ins, DT)
			s = r.state
			for e in r.events:
				if e["type"] == "downed":
					downs.append(e)
				elif e["type"] == "out":
					outs.append(e)
				elif e["type"] == "healed":
					healed += 1
					counted = counted and s.garden.healed.has("a") and int(s.garden.heals.get("a", 0)) == healed
		t.check(not others_taken, "limit %d: the healer or the decoy was taken" % limit)
		t.eq(downs.size(), limit, "limit %d: times down before out" % limit)
		for n in downs.size():
			t.check(int(downs[n].get("more", -1)) == limit - n - 1 and downs[n]["by"] == "catch", "limit %d: down %d says %s more" % [limit, n + 1, str(downs[n].get("more"))])
		t.check(outs.size() == 1 and outs[0].get("by") == "keeper" and outs[0]["playerId"] == "a", "limit %d: then out at once, by the keeper (%d outs)" % [limit, outs.size()])
		t.eq(healed, limit, "limit %d: heals" % limit)
		t.check(counted, "limit %d: every heal is counted, and heard on the next tick" % limit)
		t.check(player(s, "a").status == &"out", "limit %d: a is out" % limit)
	# Getting back up is a 6 m noise where they lie: 5 m off it tilts; up close it is a snatch at once.
	for d: float in [5.0, 1.5, 7.0]:
		var sim := Sim.make(striped(), at(16.0, 40.0))
		var k0 := sim.k
		var who := Hearing.Person.make("a", at(16.0 - d, 40.0))
		who.healed = true
		var ppl: Array[Hearing.Person] = [who]
		var none: Array[Noises.Sound] = []
		var r := Hearing.step(sim.plan, sim.ground, k0, ppl, none, false, DT)
		var want := "tilt" if d == 5.0 else ("strike" if d == 1.5 else "listening")
		t.check(String(r.state.mode) == want, "healed back up %.1f m from it: it is %s, want %s" % [d, r.state.mode, want])
	# Without the down rule a snatch is a catch.
	var solo: Array[String] = ["a"]
	var s2 := garden_run(solo, {"a": at(16.0, 40.0)}, at(20.0, 40.0), false)
	var caught := false
	for step in int(10.0 / DT):
		var ia := input("a", at(16.0, 40.0))
		ia.emote_sound = step == 2
		var r := Run.step_run(s2, one(ia), DT)
		s2 = r.state
		caught = caught or not events_of(r.events, "caught").is_empty()
		if s2.phase == &"ended":
			break
	t.check(caught, "without the down rule: caught")

# ---------------------------------------------------------------------------------------------
# 9. Hides, read for a blind resident.

func test_a_hide_is_safe_unless_its_own_noise_brought_it(t: T) -> void:
	_apply_break()
	var plan := striped()
	# A friend whistles right beside a hide and creeps off on moss; the hider sits silent: leaned past, safe.
	var sim := Sim.make(plan, at(26.0, 40.0))
	var hider := sim.bot("h", at(16.0, 40.0))
	hider.hide = 7
	var friend := sim.bot("f", at(16.6, 40.0))
	friend.emote = true
	sim.tick()
	friend.go(&"creep", -0.2, 1.0)
	for _n in int(10.0 / DT):
		sim.tick()
	t.check(not sim.taken.has("h") and not sim.taken.has("f"), "a silent hider beside a friend's whistle: taken %s" % str(sim.taken.keys()))
	t.check(sim.of_type("keeperLean").is_empty() or sim.of_type("keeperLean")[0]["playerId"] != "h", "it leaned to a hider whose hide it never heard")
	# Getting in is a 4 m noise: heard from 3.5 m, it comes, leans on the hide and takes whoever is inside.
	var sim2 := Sim.make(plan, at(19.5, 40.0))
	var h2 := sim2.bot("h", at(16.0, 40.0))
	h2.hide_noise = 7
	var s0 := sim2.tick()
	t.check(not s0.heard.is_empty() and absf(s0.heard[0].r - 4.0) < EPS and sim2.k.mode == &"tilt", "getting into a hide is a 4 m noise")
	h2.hide = 7
	for _n in int(8.0 / DT):
		sim2.tick()
	var leans := sim2.of_type("keeperLean")
	t.check(sim2.taken.has("h") and not leans.is_empty() and int(leans[0]["hide"]) == 7, "it heard them get in, and took them out of the hide: %s" % str(sim2.taken.keys()))
	# Not heard (5 m off): safe for good.
	var sim3 := Sim.make(plan, at(21.5, 40.0))
	var h3 := sim3.bot("h", at(16.0, 40.0))
	h3.hide_noise = 7
	sim3.tick()
	h3.hide = 7
	for _n in int(8.0 / DT):
		sim3.tick()
	t.check(not sim3.taken.has("h") and sim3.k.mode == &"listening", "a hide it did not hear is safe")

# ---------------------------------------------------------------------------------------------
# 10. Off elsewhere.

func test_off_elsewhere(t: T) -> void:
	_apply_break()
	# The resident off (net/host_rules.gd's seek_off): nothing is heard, nobody is taken.
	var ids: Array[String] = ["a"]
	var s := garden_run(ids, {"a": at(30.0, 40.0)}, at(34.0, 40.0))
	s = s.copy()
	s.seek_off = true
	var keeper_events := 0
	for step in int(6.0 / DT):
		var ia := input("a", at(30.0 + step * 0.01, 40.0), &"sprint")
		ia.emote_sound = step % 20 == 0
		var r := Run.step_run(s, one(ia), DT)
		s = r.state
		for e in r.events:
			if String(e["type"]).begins_with("keeper") or e["type"] == "caught":
				keeper_events += 1
	t.check(s.garden == null and keeper_events == 0 and player(s, "a").status == &"ok", "with its resident off the floor does not listen")
	# In the car nobody makes a noise and nobody is taken.
	var s2 := garden_run(ids, {}, at(40.0, 12.0))
	var car := s2.car
	var inside := Run.car_body(car, 2.0, 0.0)
	var heard := 0
	for step in int(6.0 / DT):
		var ia := input("a", inside, &"sprint")
		ia.emote_sound = step % 10 == 0
		var r := Run.step_run(s2, one(ia), DT)
		s2 = r.state
		heard += events_of(r.events, "keeperTilt").size()
	t.check(heard == 0 and player(s2, "a").status == &"ok" and s2.garden != null and s2.garden.keeper.mode == &"listening", "a crew in the car is never heard")
	# No floor but an Arboretum has a garden: a Clinic run with every switch never makes one.
	var s3 := Run.create_run("hearing-clinic", ids, [], false, false, true)
	for step in 200:
		var body := s3.players[0].body
		var ia := input("a", body, &"sprint")
		ia.emote_sound = true
		var r := Run.step_run(s3, one(ia), DT)
		s3 = r.state
		if s3.garden != null:
			t.check(false, "a Clinic floor has a garden")
			break
	# An instrument tick with no pay computes exactly as before; a pay of 1 changes nothing either.
	var plan := striped()
	var o1 := Places.create_resident(plan)
	var o2 := o1.copy()
	o2.body = at(o1.body.x + 0.3, o1.body.z)
	var none: Array[Dictionary] = []
	var crew := Instr.set_raised(Instr.create_crew(ids), "a", true)
	var cp: Array[Instr.CrewPlayer] = [Instr.CrewPlayer.make("a", at(o2.body.x + 4.0, o2.body.z), true)]
	var rates: Array = []
	for pay: Variant in [null, {"a": 1.0}, {"a": 2.0}, {}]:
		var et := Instr.EntityTick.make("groundskeeper-5", &"listening", o1, o2, none)
		et.acting = true
		et.pay = pay
		var ets: Array[Instr.EntityTick] = [et]
		var out := Instr.step_crew(plan, crew, cp, ets, DT)
		rates.append(Instr.member(out.crew, "a").instrument.rate)
	t.check(rates[0] > 0.0 and rates[0] == rates[1] and rates[0] == rates[3] and absf(rates[2] - 2.0 * rates[0]) < 1e-9, "the pay multiplier: %s" % str(rates))

# ---------------------------------------------------------------------------------------------
# 11. Searching and carrying on the garden floor.

func test_searching_and_carrying_on_the_garden_floor(t: T) -> void:
	_apply_break()
	# No findables here: the place, and every piece of real floors.
	t.check(not Findables.place_on(Places.ARBORETUM), "the Arboretum is a place with findables")
	var searchable := 0
	var pieces := 0
	for k in (1 if t.quick else 4):
		var real := Arboretum.generate_arboretum("carry-%d" % k, 5)
		for pc in Furniture.pieces_for(real):
			pieces += 1
			if pc.searchable:
				searchable += 1
		t.eq(Findables.spots_for(real).size(), 0, "carry-%d: searchable pieces on a real floor" % k)
	t.check(searchable == 0 and pieces > 0, "%d of %d pieces of real floors are searchable" % [searchable, pieces])
	# A run out on the field with both rules on: a (empty hands) and b (two cartons in two slots) 1 m apart on
	# moss, the Groundskeeper 13 m off.
	var ids: Array[String] = ["a", "b"]
	var a_at := at(12.0, 40.0)
	var b_at := at(11.0, 40.0)
	var s := Run.with_inventory(Run.with_findables(garden_run(ids, {"a": a_at, "b": b_at}, at(24.0, 40.0))))
	s = PropInventory.with_bags(s, {"b": [["juice", 1], ["juice", 1]]})
	var all: Array[Dictionary] = []
	var r := Run.step_run(s, PropInventory.ins2(input("a", a_at, &"creep"), input("b", b_at, &"creep")), DT)
	s = r.state
	# The search key, held and rushed: nothing.
	for _n in 20:
		var ia := input("a", a_at, &"creep")
		ia.search = true
		ia.search_fast = true
		r = Run.step_run(s, PropInventory.ins2(ia, input("b", b_at, &"creep")), DT)
		s = r.state
		all.append_array(r.events)
	var searches := 0
	for e in all:
		if str(e["type"]).begins_with("search"):
			searches += 1
	t.check(s.find == null and searches == 0, "holding the search key on the garden floor: find %s, %d search events" % [str(s.find), searches])
	t.check(s.garden != null and s.garden.keeper.mode == &"listening", "it heard the search key")
	# b puts a carton down; a picks it up.
	r = Run.step_run(s, PropInventory.ins2(input("a", a_at, &"creep"), PropInventory.req(input("b", b_at, &"creep"), &"drop", null, 0)), DT)
	s = r.state
	all.append_array(r.events)
	var dropped := events_of(r.events, "itemDropped")
	t.check(dropped.size() == 1 and str(dropped[0]["why"]) == "drop" and s.pickups.size() == 1, "a carton put down lies on the ground: %s" % str(dropped))
	t.eq(Run.items_in_world(s), {"juice": 2}, "after the drop: nothing made or lost")
	if dropped.size() == 1:
		r = Run.step_run(s, PropInventory.ins2(PropInventory.req(input("a", a_at, &"creep"), &"take", int(dropped[0]["pickup"])), input("b", b_at, &"creep")), DT)
		s = r.state
		all.append_array(r.events)
		var taken := events_of(r.events, "itemTaken")
		t.check(taken.size() == 1 and Inventory.bag_of(s.bags, "a").totals() == {"juice": 1} and s.pickups.is_empty(), "a crewmate in reach picks it up: %s" % str(taken))
	for _n in 20:
		r = Run.step_run(s, PropInventory.ins2(input("a", a_at, &"creep"), input("b", b_at, &"creep")), DT)
		s = r.state
		all.append_array(r.events)
	t.check(s.garden.keeper.mode == &"listening" and events_of(all, "keeperTilt").is_empty(), "it heard a carton put down or picked up")
	# b whistles and stands; a creeps away on the moss. b is taken and drops what it carries where it falls.
	var a_body := a_at
	var whistled := false
	var fell: Array[Dictionary] = []
	for _n in int(30.0 / DT):
		if player(s, "b").status != &"ok":
			break
		a_body = at(a_body.x, a_body.z + O_CREEP * DT)
		var ib := input("b", b_at, &"creep")
		ib.emote_sound = not whistled
		whistled = true
		r = Run.step_run(s, PropInventory.ins2(input("a", a_body, &"creep"), ib), DT)
		s = r.state
		fell.append_array(events_of(r.events, "itemDropped"))
	t.check(player(s, "b").status != &"ok" and player(s, "a").status == &"ok", "the whistler was taken and the one who crept off was not (%s, %s)" % [player(s, "b").status, player(s, "a").status])
	t.check(fell.size() == 1 and str(fell[0]["why"]) == "down" and str(fell[0]["playerId"]) == "b" and flat(fell[0]["at"], b_at) < 0.01,
		"whoever it takes drops what they carry where they fall: %s" % str(fell))
	t.check(Inventory.bag_of(s.bags, "b").is_empty() and s.pickups.size() == 1, "the taken player's hands are empty and the carton lies there (%d on the ground)" % s.pickups.size())
	t.eq(Run.items_in_world(s), {"juice": 2}, "after the snatch: nothing made or lost")
