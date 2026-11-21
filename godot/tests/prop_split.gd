# Split reality, first playable slice (SR1; sim/split.gd, North Star E1 to E5). Proved here:
#   1. Flag off: no split state, no "split" block, nothing in a player's world.
#   2. Exposure rises with the instrument up, alone and in the dark (not with the lamp lit), falls in the lift, never
#      moves for a downed player, and never rises in the prison.
#   3. A player's world carries only their own exposure and sights; the shared world and another player's carry none;
#      it survives the wire.
#   4. A phantom right in front of a player recording changes nothing the run decides (residents, the instrument,
#      tapes, catches, downs) tick for tick; walking into it reveals it (E4) and still changes nothing.
#   5. The wrong face's guard: never begun with a real resident within FACE_GUARD_METRES of either player, ended the
#      tick one comes that near. It prefers whoever just flared you.
#   6. The phantom exit stands on a plain wall the player cannot walk through.
#   7. False calm at the top; nothing below split.first_at; nothing while a resident is near (A5).
#   8. The same seed gives the same false sights; bot floors give the same run with the flag on and off (the bots act
#      on the true state, so no rate can move), while sights do appear.
#   9. A flare burst lighting a false sight reveals it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Split = preload("res://sim/split.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Places = preload("res://sim/places.gd")
const Sight = preload("res://sim/sight.gd")
const Walls = preload("res://sim/walls.gd")
const Instr = preload("res://sim/instrument.gd")
const Bot = preload("res://sim/bot.gd")
const Stamina = preload("res://sim/stamina.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Transport = preload("res://net/transport.gd")
const PropSettings = preload("res://tests/prop_settings.gd")

const DT := 0.05
## Tuning that makes sights come often (the bot floors and the seed test).
const LOUD := {&"split.lift_fall": 0.0, &"split.first_at": 5, &"split.chance": 100, &"split.every": 2.0, &"split.alone_rise": 3.0, &"split.read_rise": 3.0, &"split.dark_rise": 3.0}

static func eyes(id: String, body: Move.Body, yaw := 0.0) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, yaw, 0.0, 90, 70)

## A two-player Clinic floor, the car away, split on, everyone at exposure 0.
static func fixture(seed := "split-fixture", ids: Array[String] = ["A", "B"]) -> Run.RunState:
	var s := Run.create_run(seed, ids, [Places.CLINIC])
	s = Split.with_split(s)
	s.phase = &"away"
	for p in s.players:
		p.aboard = false
	return s

static func put(s: Run.RunState, id: String, x: float, z: float) -> void:
	for k in s.players.size():
		if s.players[k].id == id:
			var np := s.players[k].copy()
			np.body = Move.Body.make(x, z, 0, 0.0)
			np.aboard = false
			s.players[k] = np

static func body_of(s: Run.RunState, id: String) -> Move.Body:
	for p in s.players:
		if p.id == id:
			return p.body
	return null

static func inputs_of(s: Run.RunState, yaws := {}) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		out.append(eyes(p.id, p.body, float(yaws.get(p.id, 0.0))))
	return out

static func set_e(s: Run.RunState, id: String, e: float) -> void:
	var sp := Split.of(s).copy()
	sp.exposure[id] = e
	s.split = sp

## A walkable cell centre on level 0 (world x, z), the `n`-th from a seeded start.
static func cell_centre(s: Run.RunState, cx: int, cy: int) -> Vector2:
	return Vector2((cx + 0.5) * s.plan.cell_size, (cy + 0.5) * s.plan.cell_size)

## Two or three cells in one room, 4 to 10 m apart from the first, with a clear line between eyes: [A, B, C].
static func open_spots(s: Run.RunState, want := 3) -> Array[Vector2]:
	for room in s.plan.rooms:
		if room.level != 0:
			continue
		var cells: Array[Vector2] = []
		for x in range(room.x, room.x + room.w):
			for y in range(room.y, room.y + room.h):
				if Floor.is_walkable(s.plan, 0, x, y):
					cells.append(cell_centre(s, x, y))
		for a in cells:
			var out: Array[Vector2] = [a]
			for b in cells:
				var d := a.distance_to(b)
				if d >= 4.5 and d <= 10.0 and Sight.has_line_of_sight(s.plan, Sight.Point3.make(a.x, 1.65, a.y, 0), Sight.Point3.make(b.x, 1.2, b.y, 0)):
					var ok := true
					for c in out:
						ok = ok and c.distance_to(b) >= 1.5
					if ok:
						out.append(b)
				if out.size() >= want:
					return out
	return []

static func yaw_to(from: Vector2, to: Vector2) -> float:
	return atan2(-(to.x - from.x), -(to.y - from.y))

## The resident parked far from (x, z) (or as near as `metres` if given).
static func park_resident(s: Run.RunState, x: float, z: float, metres := 999.0) -> void:
	var best: Vector2 = Vector2.INF
	var best_d := -1.0
	for cx in s.plan.width:
		for cy in s.plan.height:
			if not Floor.is_walkable(s.plan, 0, cx, cy):
				continue
			var c := cell_centre(s, cx, cy)
			var d := c.distance_to(Vector2(x, z))
			if metres < 900.0:
				if d <= metres and d > best_d:
					best = c
					best_d = d
			elif d > best_d:
				best = c
				best_d = d
	var o := s.orderly.copy()
	o.body = Move.Body.make(best.x, best.y, 0, 0.0)
	o.mode = &"dormant"
	o.dormant_left = INF
	s.orderly = o

# ---------------------------------------------------------------------------------------------

func test_flag_off_nothing(t: T) -> void:
	var rules := HostRules.new(true, 1)
	var s := rules.prepare(Run.create_run("split-off", ["A", "B"]))
	t.check(s.split == null and not rules.split, "flag off: no split state")
	var r := rules.step(s, inputs_of(s), DT)
	t.check(r.state.split == null, "flag off: a step makes none")
	t.check(Split.view(r.state, "A") == null, "flag off: no view")
	var net := Transport.MemoryNetwork.new("split-off")
	var host := Host.new(Transport.MemoryTransport.new(net, "host"), "split-off", ["A", "B"], 0.0)
	host.state = r.state
	var a := Host.HostPlayer.new()
	a.id = "A"
	a.in_run = true
	var shared := host.world()
	t.check(is_same(host._world_for(shared, a), shared), "flag off: a player's world is the shared one")
	t.check(not Protocol.world_json(shared).contains("split"), "flag off: no split block on the wire")
	var on := HostRules.new(true, 1)
	on.split = true
	t.check(on.prepare(Run.create_run("split-on", ["A"])).split != null, "flag on: prepare gives the run its state")

func test_exposure_rises_and_falls(t: T) -> void:
	var s := fixture()
	s.seek_off = true
	put(s, "A", 20, 20)
	put(s, "B", 40, 20)
	Split.step(s, inputs_of(s), 1.0, [])
	t.check(is_equal_approx(Split.exposure_of(s, "A"), Split.ALONE_RISE / 100.0), "alone: rises by the alone rate (%f)" % Split.exposure_of(s, "A"))
	put(s, "B", 25, 20)
	var before := Split.exposure_of(s, "A")
	Split.step(s, inputs_of(s), 1.0, [])
	t.check(is_equal_approx(Split.exposure_of(s, "A"), before), "with a crewmate near and nothing else: steady")
	Instr.member(s.crew, "A").instrument.raised = true
	before = Split.exposure_of(s, "A")
	Split.step(s, inputs_of(s), 1.0, [])
	t.check(is_equal_approx(Split.exposure_of(s, "A") - before, Split.READ_RISE / 100.0), "instrument up: rises by the reading rate")
	t.check(is_equal_approx(Split.exposure_of(s, "B"), Split.ALONE_RISE / 100.0), "B's exposure is B's own")
	Instr.member(s.crew, "A").instrument.raised = false
	s.blink = Run.BlinkState.new()
	s.blink.ends_at = s.t + 10.0
	before = Split.exposure_of(s, "A")
	Split.step(s, inputs_of(s), 1.0, [])
	t.check(is_equal_approx(Split.exposure_of(s, "A") - before, Split.DARK_RISE / 100.0), "in the dark: rises by the dark rate")
	s.lamps = {"A": {"on": true}}
	before = Split.exposure_of(s, "A")
	Split.step(s, inputs_of(s), 1.0, [])
	t.check(is_equal_approx(Split.exposure_of(s, "A"), before), "lamp lit in the dark: not dark")
	s.blink = null
	set_e(s, "A", 0.5)
	s.players[0].aboard = true
	Split.step(s, inputs_of(s), 1.0, [])
	t.check(is_equal_approx(Split.exposure_of(s, "A"), 0.5 - Split.LIFT_FALL / 100.0), "aboard the car: falls by the lift rate")
	s.players[0].aboard = false
	s.players[0].status = &"down"
	before = Split.exposure_of(s, "A")
	Split.step(s, inputs_of(s), 30.0, [])
	t.eq(Split.exposure_of(s, "A"), before, "a downed player's exposure does not move")
	s.players[0].status = &"ok"
	set_e(s, "A", 0.99)
	Instr.member(s.crew, "A").instrument.raised = true
	Split.step(s, inputs_of(s), 100.0, [])
	t.eq(Split.exposure_of(s, "A"), 1.0, "never above the top")
	t.check(not Split.PLACES.has(Places.PRISON) and not Split.PLACES.has(Places.REACTOR), "never in the prison or the Reactor")
	var ward := fixture("split-ward", ["A"] as Array[String])
	ward.depth = 6
	t.check(not Split.sight_floor(ward), "never on the Hanging Ward's floor")
	ward.depth = 13
	t.check(not Split.sight_floor(ward), "nor in a later cycle")
	ward.depth = 9
	t.check(Split.sight_floor(ward), "floor 9 is a Clinic again")

func test_only_its_own_player_is_sent_it(t: T) -> void:
	var s := fixture()
	set_e(s, "A", 0.4)
	set_e(s, "B", 0.7)
	var sp := Split.of(s).copy()
	sp.sights = [{"id": 1, "for": "A", "kind": "phantom", "x": 10.0, "y": 0.0, "z": 12.0, "level": 0, "yaw": 0.5, "who": "", "from": 1.0, "until": 9.0, "gone": -1.0}]
	s.split = sp
	var net := Transport.MemoryNetwork.new("split-net")
	var host := Host.new(Transport.MemoryTransport.new(net, "host"), s.seed, ["A", "B"], 0.0)
	host.state = s
	var a := Host.HostPlayer.new()
	a.id = "A"
	a.in_run = true
	var b := Host.HostPlayer.new()
	b.id = "B"
	b.in_run = true
	var shared := host.world()
	t.check(not shared.has("split"), "the shared world has nobody's exposure")
	var wa := host._world_for(shared, a)
	var wb := host._world_for(shared, b)
	t.eq(wa.split.e, 0.4, "A gets A's exposure")
	t.eq(wa.split.sights.size(), 1, "A gets A's sight")
	t.eq(wb.split.e, 0.7, "B gets B's exposure")
	t.check(wb.split.sights.is_empty(), "B gets none of A's sights")
	t.check(not Protocol.world_json(wb).contains("0.4") and not Protocol.world_json(wb).contains("12,"), "nothing of A's in B's world on the wire")
	b.in_run = false
	t.check(not host._world_for(shared, b).has("split"), "someone not in the run gets nothing")
	var wire := Protocol.encode({"type": "welcome", "you": "A", "seed": s.seed, "playing": true, "evFrom": 1, "world": wa})
	var packet: Variant = Protocol.decode(wire)
	if not t.check(packet != null, "the wire takes the split block"):
		return
	t.eq(packet.world.split.e, 0.4, "exposure survives the wire")
	t.eq(packet.world.split.sights[0].kind, "phantom", "the sight survives the wire")
	t.eq(packet.world.split.sights[0].z, 12.0, "with its place")
	wa.split = {"e": 1.5, "calm": false, "sights": []}
	t.check(Protocol.decode(Protocol.encode({"type": "welcome", "you": "A", "seed": s.seed, "playing": true, "evFrom": 1, "world": wa})) == null, "an exposure over the top is refused on the wire")

## A placed phantom for A in front of them (searching A's spots and facings), or {}.
static func phantom_for(s: Run.RunState, id := "A") -> Dictionary:
	var p := s.players[0]
	for cx in s.plan.width:
		for cy in s.plan.height:
			if not Floor.is_walkable(s.plan, 0, cx, cy):
				continue
			var c := cell_centre(s, cx, cy)
			put(s, id, c.x, c.y)
			p = s.players[0]
			for k in 8:
				var i := eyes(id, p.body, k * PI / 4.0)
				var g := Split.place(s, Split.of(s), &"phantom", p, i, "test:%d:%d:%d" % [cx, cy, k])
				if not g.is_empty():
					g["yawUsed"] = k * PI / 4.0
					return g
	return {}

func test_phantom_changes_nothing_the_run_decides(t: T) -> void:
	for seed: String in ["split-phantom-a", "split-phantom-b"]:
		var s := fixture(seed, ["A"] as Array[String])
		var g := phantom_for(s)
		if not t.check(not g.is_empty(), "%s: a phantom fits" % seed):
			continue
		park_resident(s, float(g.x), float(g.z))
		var on := HostRules.new(true, 1)
		var off := HostRules.new(true, 1)
		var lane_on := s.copy()
		var sp := Split.of(lane_on).copy()
		var row := g.duplicate()
		row.erase("yawUsed")
		row.merge({"id": 1, "for": "A", "kind": "phantom", "from": 0.0, "until": 1e6, "gone": -1.0})
		sp.sights = [row]
		sp.next_roll = 1e9
		lane_on.split = sp
		var lane_off := s.copy()
		lane_off.split = null
		var yaw := float(g.yawUsed)
		var target := Vector2(float(g.x), float(g.z))
		var same := true
		var revealed := -1.0
		var standing := 0
		for k in 400:
			var walk := k >= 100
			var inputs: Array[Run.PlayerInput] = []
			for st: Run.RunState in [lane_on, lane_off]:
				var b := st.players[0].body
				var nb := b
				if walk:
					var dir := (target - Vector2(b.x, b.z))
					if dir.length() > 0.05:
						dir = dir.normalized() * minf(dir.length(), 2.2 * DT)
						nb = Move.move_with_collision(st.plan, b, dir.x, dir.y, 0.3)
				var i := eyes("A", nb, yaw)
				i.raised = true
				inputs = [i]
				if st == lane_on:
					lane_on = on.step(lane_on, inputs, DT).state
				else:
					var r := off.step(lane_off, inputs, DT)
					lane_off = r.state
			if PropSettings.fingerprint(lane_on, []) != PropSettings.fingerprint(lane_off, []):
				same = false
			var live := Split.of(lane_on).sights
			if not walk and live.size() == 1:
				standing += 1
			if revealed < 0.0 and live.size() == 1 and float(live[0].gone) >= 0.0:
				revealed = lane_on.t
		t.check(same, "%s: with a phantom in front of a recording player, the run is the same tick for tick" % seed)
		t.eq(standing, 100, "%s: the phantom stood there the whole time" % seed)
		t.check(revealed > 0.0, "%s: walking into it revealed it (E4)" % seed)
		t.check(Split.of(lane_on).sights.is_empty(), "%s: and then it was gone" % seed)
		t.eq(lane_on.players[0].status, &"ok", "%s: it cost nothing: still on their feet" % seed)
		t.eq(Instr.member(lane_on.crew, "A").instrument.needle, Instr.member(lane_off.crew, "A").instrument.needle, "%s: the instrument reads what it reads without it" % seed)

func test_wrong_face_guard(t: T) -> void:
	var s := fixture("split-face", ["A", "B", "C"] as Array[String])
	var spots := open_spots(s, 3)
	if not t.check(spots.size() == 3, "a room with three spots"):
		return
	put(s, "A", spots[0].x, spots[0].y)
	put(s, "B", spots[1].x, spots[1].y)
	put(s, "C", spots[2].x, spots[2].y)
	var sp := Split.of(s)
	var yaw_b := yaw_to(spots[0], spots[1])
	park_resident(s, spots[0].x, spots[0].y, Split.FACE_GUARD_METRES - 1.0)
	t.check(Split.place(s, sp, &"face", s.players[0], eyes("A", s.players[0].body, yaw_b), "k").is_empty(), "a resident inside the guard of the viewer: no wrong face")
	park_resident(s, spots[1].x, spots[1].y, Split.FACE_GUARD_METRES - 1.0)
	t.check(Split.place(s, sp, &"face", s.players[0], eyes("A", s.players[0].body, yaw_b), "k").is_empty(), "a resident inside the guard of the crewmate: no wrong face")
	park_resident(s, spots[0].x, spots[0].y)
	var far := Split.residents(s)[0]
	t.check(Vector2(far.x - spots[0].x, far.z - spots[0].y).length() > 20.0 or s.seek_off, "the resident is far")
	var g := Split.place(s, sp, &"face", s.players[0], eyes("A", s.players[0].body, yaw_b), "k")
	if not t.check(not g.is_empty(), "the resident far: a wrong face fits"):
		return
	# Who just flared you is asked first (E2).
	var flared := sp.copy()
	flared.flared_by = {"A": ["C", s.t]}
	var gc := Split.place(s, flared, &"face", s.players[0], eyes("A", s.players[0].body, yaw_to(spots[0], spots[2])), "k")
	t.eq(gc.get("who", ""), "C", "the crewmate who just flared you wears it")
	flared.flared_by = {"A": ["B", s.t]}
	t.eq(Split.place(s, flared, &"face", s.players[0], eyes("A", s.players[0].body, yaw_b), "k").get("who", ""), "B", "the other one when they flared you")
	var live := sp.copy()
	g.merge({"id": 1, "for": "A", "kind": "face", "from": s.t, "until": s.t + 100.0, "gone": -1.0})
	live.sights = [g]
	live.next_roll = 1e9
	s.split = live
	Split.step(s, inputs_of(s, {"A": yaw_b}), DT, [])
	t.eq(Split.of(s).sights.size(), 1, "it holds while the guard holds")
	park_resident(s, spots[1].x, spots[1].y, Split.FACE_GUARD_METRES - 1.0)
	Split.step(s, inputs_of(s, {"A": yaw_b}), DT, [])
	t.check(Split.of(s).sights.is_empty(), "the tick a resident comes inside the guard, the wrong face is gone")
	t.check(Split.FACE_GUARD_METRES > 4.0 * 0.9 and Split.FACE_GUARD_METRES > 1.6 * 3.0, "the guard is far outside every catch and reach range")

func test_phantom_exit_is_a_wall(t: T) -> void:
	var placed := 0
	var walls := 0
	var stopped := 0
	for n in (3 if t.quick else 8):
		var s := fixture("split-exit-%d" % n, ["A"] as Array[String])
		s.seek_off = true
		var step := 3
		for cx in range(0, s.plan.width, step):
			for cy in range(0, s.plan.height, step):
				if not Floor.is_walkable(s.plan, 0, cx, cy):
					continue
				var c := cell_centre(s, cx, cy)
				put(s, "A", c.x, c.y)
				for k in 4:
					var g := Split.place(s, Split.of(s), &"exit", s.players[0], eyes("A", s.players[0].body, k * PI / 2.0), "x%d:%d:%d" % [cx, cy, k])
					if g.is_empty():
						continue
					placed += 1
					var side := Vector2(sin(float(g.yaw)), cos(float(g.yaw)))
					var at := Vector2(float(g.x), float(g.z))
					var cs := float(s.plan.cell_size)
					var cell := Vector2i(floori((at.x - side.x * 0.5) / cs), floori((at.y - side.y * 0.5) / cs))
					if Walls.edge_kind(s.plan, 0, cell.x, cell.y, cell.x + roundi(side.x), cell.y + roundi(side.y)) == Walls.WALL:
						walls += 1
					var front := at - side * 0.8
					var walked := Move.move_with_collision(s.plan, Move.Body.make(front.x, front.y, 0, 0.0), side.x * 3.0, side.y * 3.0, 0.3)
					if (Vector2(walked.x, walked.z) - at).dot(side) < 0.0:
						stopped += 1
	t.check(placed >= 10, "exits were placed (%d)" % placed)
	t.eq(walls, placed, "every exit stands on a plain wall")
	t.eq(stopped, placed, "walking into every exit stops at the wall")

func test_false_calm_and_the_gates(t: T) -> void:
	var s := fixture("split-gates", ["A"] as Array[String])
	set_e(s, "A", 0.9)
	t.check(Split.view(s, "A").calm, "at the top: false calm")
	set_e(s, "A", 0.89)
	t.check(not Split.view(s, "A").calm, "just under: not calm")
	s.tuning = Run.with_tuning(s, {&"split.calm_at": 50}).tuning
	set_e(s, "A", 0.6)
	t.check(Split.view(s, "A").calm, "the live setting moves it")
	t.eq(Split.chance_at(s, 0.29), 0.0, "no chance below FALSE SIGHTS FROM")
	# A quiet player held at a set exposure, a chance every 2 s at 100 in 100 at the top.
	var g := fixture("split-gates-2", ["A"] as Array[String])
	g.tuning = Run.with_tuning(g, {&"split.chance": 100, &"split.every": 2.0, &"split.alone_rise": 0.0}).tuning
	var c := phantom_for(g)
	park_resident(g, body_of(g, "A").x, body_of(g, "A").z)
	var yaw := float(c.get("yawUsed", 0.0))
	set_e(g, "A", 0.29)
	var seen := 0
	for k in 300:
		g.t += 1.0
		Split.step(g, inputs_of(g, {"A": yaw}), 1.0, [])
		seen += Split.of(g).sights.size()
	t.eq(seen, 0, "below FALSE SIGHTS FROM: never a false sight in 300 s")
	set_e(g, "A", 1.0)
	var starts := 0
	var last := 0
	for k in 300:
		g.t += 1.0
		Split.step(g, inputs_of(g, {"A": yaw}), 1.0, [])
		if Split.of(g).seq != last:
			starts += 1
			last = Split.of(g).seq
	t.check(starts > 5, "at the top: false sights come (%d)" % starts)
	# A5: not while a resident is near.
	park_resident(g, body_of(g, "A").x, body_of(g, "A").z, Split.QUIET_METRES - 2.0)
	var sp := Split.of(g).copy()
	sp.sights = []
	g.split = sp
	var near := 0
	for k in 100:
		g.t += 1.0
		Split.step(g, inputs_of(g, {"A": yaw}), 1.0, [])
		near += Split.of(g).sights.size()
	t.eq(near, 0, "a resident within %d m: never a false sight" % int(Split.QUIET_METRES))

func test_flare_reveals(t: T) -> void:
	var s := fixture("split-flare", ["A"] as Array[String])
	var g := phantom_for(s)
	if not t.check(not g.is_empty(), "a phantom fits"):
		return
	park_resident(s, body_of(s, "A").x, body_of(s, "A").z)
	g.erase("yawUsed")
	g.merge({"id": 1, "for": "A", "kind": "phantom", "from": 0.0, "until": 1e6, "gone": -1.0})
	var sp := Split.of(s).copy()
	sp.sights = [g]
	sp.next_roll = 1e9
	s.split = sp
	var far := {"type": "flareUsed", "playerId": "A", "blind": "", "x": float(g.x) + 40.0, "y": 0.0, "z": float(g.z), "level": 0}
	Split.step(s, inputs_of(s), DT, [far])
	t.eq(float(Split.of(s).sights[0].gone), -1.0, "a flare far away shows nothing")
	var near := {"type": "flareUsed", "playerId": "A", "blind": "", "x": float(g.x), "y": 0.0, "z": float(g.z), "level": 0}
	Split.step(s, inputs_of(s), DT, [near])
	t.check(float(Split.of(s).sights[0].gone) >= 0.0, "a flare lighting it shows the truth")

# ---------------------------------------------------------------------------------------------
# Bot floors, flag on and off.

class Lane:
	var st: Run.RunState
	var rules: HostRules
	var bots: Array[Bot.WaitBot] = []

	func _init(s: Run.RunState, style: StringName, split: bool) -> void:
		rules = HostRules.new(true, s.depth)
		st = s.copy()
		st.split = null
		if split:
			# Everyone starts at the top, so the floor's quiet moments (and nothing else) decide when sights come.
			var sp := Split.SplitState.new()
			sp.plan = st.plan
			for p in st.players:
				sp.exposure[p.id] = 1.0
			st.split = sp
		for k in st.players.size():
			var b := Bot.create_wait_bot(st, st.players[k].id, k, style)
			b.stamina = Stamina.fresh_stamina(Run.sprint_seconds(st))
			bots.append(b)
		var players: Array[Run.RunPlayer] = []
		for k in st.players.size():
			var np := st.players[k].copy()
			np.body = bots[k].body
			players.append(np)
		st.players = players

	func tick(k: int) -> Array[Dictionary]:
		var live: Array[Bot.WaitBot] = []
		for b in bots:
			for q in st.players:
				if q.id == b.id and q.status == &"ok":
					live.append(b)
		if k > 0:
			for b in live:
				Bot.step_wait_bot(st, b, DT)
		var waiting := false
		for b in live:
			if not Run.in_car(st.car, b.body):
				waiting = true
		var inputs: Array[Run.PlayerInput] = []
		for j in live.size():
			inputs.append(Bot.wait_bot_input(live[j], live[j].mode == &"aboard" and waiting, k == 0 and j == 0))
		var r := rules.step(st, inputs, DT)
		st = r.state
		return r.events

func test_bot_floors_same_with_the_flag_on(t: T) -> void:
	var floors := 4 if t.quick else 16
	var secs := 60.0
	var sights := 0
	var differ := 0
	var kinds := {}
	var places := {}
	for i in floors:
		var depth := 1 + i % 5
		var n := 2 + (i / 5) % 3
		var seed := "split-bots-%d" % i
		var base := Run.with_tuning(PropSettings.game_floor(seed, depth, n), LOUD)
		places[base.plan.place] = true
		var style: StringName = &"stay" if i % 2 == 0 else &"flee"
		var a := Lane.new(base, style, true)
		var b := Lane.new(base, style, false)
		var c := Lane.new(base, style, true)
		var seen := {}
		for k in roundi(secs / DT):
			var ea := a.tick(k)
			var eb := b.tick(k)
			c.tick(k)
			if PropSettings.fingerprint(a.st, ea) != PropSettings.fingerprint(b.st, eb):
				differ += 1
			if str(Split.of(a.st).sights) != str(Split.of(c.st).sights) or Split.of(a.st).exposure != Split.of(c.st).exposure:
				differ += 1
			for g in Split.of(a.st).sights:
				if not seen.has(g.id):
					seen[g.id] = true
					kinds[g.kind] = int(kinds.get(g.kind, 0)) + 1
		sights += seen.size()
	t.eq(differ, 0, "the run with the flag on is the run with it off, tick for tick, and the same seed gives the same sights")
	t.check(sights > 0, "false sights did appear on the bot floors (%d)" % sights)
	t.note("%d floors %s, %d false sights %s, every tick the same" % [floors, str(places.keys()), sights, str(kinds)])

# ---------------------------------------------------------------------------------------------
# The live settings' proof (tests/prop_settings.gd test_split_numbers): each split.* row changes what it says, at least,
# today's and most.

static func _tuned(id: StringName, v: float) -> Run.RunState:
	var s := fixture("split-settings", ["A", "B"] as Array[String])
	s.seek_off = true
	s.tuning = Run.with_tuning(s, {id: v}).tuning
	put(s, "A", 20, 20)
	put(s, "B", 60, 20)
	return s

static func settings_proof(t: T) -> void:
	const Settings = preload("res://sim/settings.gd")
	for id: StringName in [&"split.read_rise", &"split.alone_rise", &"split.dark_rise", &"split.lift_fall", &"split.alone_m",
			&"split.first_at", &"split.calm_at", &"split.every", &"split.chance", &"split.lasts"]:
		var row := Settings.row(id)
		for v: float in [row.lo, row.today, row.hi]:
			var s := _tuned(id, v)
			var tag := "%s at %s" % [id, str(v)]
			match id:
				&"split.alone_rise":
					Split.step(s, inputs_of(s), 1.0, [])
					t.check(is_equal_approx(Split.exposure_of(s, "A"), v / 100.0), tag)
				&"split.read_rise":
					s.tuning = Run.with_tuning(s, {id: v, &"split.alone_rise": 0.0}).tuning
					Instr.member(s.crew, "A").instrument.raised = true
					Split.step(s, inputs_of(s), 1.0, [])
					t.check(is_equal_approx(Split.exposure_of(s, "A"), v / 100.0), tag)
				&"split.dark_rise":
					s.tuning = Run.with_tuning(s, {id: v, &"split.alone_rise": 0.0}).tuning
					s.blink = Run.BlinkState.new()
					s.blink.ends_at = s.t + 5.0
					Split.step(s, inputs_of(s), 1.0, [])
					t.check(is_equal_approx(Split.exposure_of(s, "A"), v / 100.0), tag)
				&"split.lift_fall":
					set_e(s, "A", 0.5)
					s.players[0].aboard = true
					Split.step(s, inputs_of(s), 1.0, [])
					t.check(is_equal_approx(Split.exposure_of(s, "A"), 0.5 - v / 100.0), tag)
				&"split.alone_m":
					put(s, "B", 20 + v - 0.5, 20)
					Split.step(s, inputs_of(s), 1.0, [])
					t.eq(Split.exposure_of(s, "A"), 0.0, tag + ": a crewmate just inside is company")
					put(s, "B", 20 + v + 0.5, 20)
					Split.step(s, inputs_of(s), 1.0, [])
					t.check(Split.exposure_of(s, "A") > 0.0, tag + ": just outside is alone")
				&"split.first_at":
					t.eq(Split.chance_at(s, v / 100.0 - 0.01), 0.0, tag + ": none just under")
					t.check(v >= 100.0 or Split.chance_at(s, minf(1.0, v / 100.0 + 0.01)) > 0.0, tag + ": a chance just over")
				&"split.calm_at":
					set_e(s, "A", v / 100.0)
					t.check(Split.view(s, "A").calm, tag + ": calm at it")
					set_e(s, "A", v / 100.0 - 0.01)
					t.check(not Split.view(s, "A").calm, tag + ": not just under")
				&"split.every":
					s.t = 50.0
					Split.step(s, inputs_of(s), DT, [])
					t.check(is_equal_approx(Split.of(s).next_roll - s.t, v), tag + ": the next chance comes after it")
				&"split.chance":
					t.check(is_equal_approx(Split.chance_at(s, 1.0), v / 100.0), tag + ": the chance at the top")
				&"split.lasts":
					var g := phantom_for(s)
					if not t.check(not g.is_empty(), tag + ": a phantom fits"):
						continue
					park_resident(s, body_of(s, "A").x, body_of(s, "A").z)
					s.tuning = Run.with_tuning(s, {id: v, &"split.chance": 100, &"split.first_at": 5}).tuning
					set_e(s, "A", 1.0)
					var sp := Split.of(s).copy()
					sp.next_roll = s.t
					s.split = sp
					var inputs: Array[Run.PlayerInput] = [eyes("A", body_of(s, "A"), float(g.yawUsed)), eyes("B", body_of(s, "B"))]
					Split.step(s, inputs, DT, [])
					var live := Split.of(s).sights
					t.check(live.size() == 1 and is_equal_approx(float(live[0].until) - s.t, v), tag + ": it lasts that long")
