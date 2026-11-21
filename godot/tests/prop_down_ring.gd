# DR1, the owner's playtest of 20 Nov (sim/run.gd down_ring, down_time; client/hud.gd ring_arc): "When knocked down,
# the player dies pretty darn quickly. like really quick. Probably need 30 seconds. Instead of text, float an O in the
# center of player screen that slowly runs out." This is newer than B6's "about ten seconds" and wins.
#   1. With the flag on a caught player is down 30 s (the live setting down.ring) before they are out; off it is 10 s
#      as recorded (down.time). The Orderly stays bent over them for the whole of it.
#   2. On screen: the ring's share left is the host's time left over the whole down time, it reaches 0 at the out,
#      and its arc is that share of a turn, ending at the top and emptying clockwise from it.
#   3. The flag is off by default and needs the down rule.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")
const DownView = preload("res://client/down_view.gd")
const Hud = preload("res://client/hud.gd")
const PDV = preload("res://tests/prop_down_view.gd")

const DT := 0.05
## The owner's 30 seconds, and B6's recorded ten, restated.
const O_RING := 30.0
const O_OLD := 10.0

## A Clinic run with the down rule, the Orderly a little over a metre from p0 and coming, p0 standing still facing
## it. Returns [downed at, until, out at, ticks the Orderly was bending while p0 was down, ticks p0 was down].
static func down_and_out(seed: String, ring: bool, given: Dictionary = {}) -> PackedFloat64Array:
	var rng := Rng.make_rng(seed)
	var s := Run.with_paced(Run.create_run(seed, ["p0"] as Array[String], [], false, false, true))
	if ring:
		s = Run.with_down_ring(s)
	if not given.is_empty():
		s = Run.with_tuning(s, given)
	var plan := s.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cells: Array[Floor.Pos] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= 3 and p.level == plan.landing.level:
			cells.append(p)
	var vb := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
	var ob := Move.body_at_cell(plan, plan.landing)
	for j in 8:
		var a := (rng.int_in(0, 7) + j) * PI / 4.0
		var b := Move.move_with_collision(plan, vb, cos(a) * 1.2, sin(a) * 1.2, Entity.ORDERLY_RADIUS)
		if M.hypot2(b.x - vb.x, b.z - vb.z) >= 1.15:
			ob = b
			break
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var o := s.orderly.copy()
	o.body = ob
	o.yaw = Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.ever_seen = true
	s.orderly = o
	var np := s.players[0].copy()
	np.body = vb
	np.aboard = false
	s.players = [np] as Array[Run.RunPlayer]
	var yaw := Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	var out := PackedFloat64Array([-1.0, -1.0, -1.0, 0.0, 0.0])
	for _k in roundi(80.0 / DT):
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p0", vb, 1.65, yaw, 0.0, 90.0, 70.0)]
		var r := Run.step_run(s, ins, DT)
		s = r.state
		for e in r.events:
			if e["type"] == "downed" and e["playerId"] == "p0" and out[0] < 0.0:
				out[0] = float(e["t"])
				out[1] = float(e["until"])
			if e["type"] == "out" and e["playerId"] == "p0":
				out[2] = s.t
				return out
		if out[0] >= 0.0 and s.players[0].status == &"down":
			out[4] += 1.0
			if s.orderly.mode == &"bending":
				out[3] += 1.0
	return out

func test_thirty_seconds_down_with_the_ring_ten_without(t: T) -> void:
	var seeds := 3 if t.quick else 8
	for ring: bool in [true, false]:
		var want := O_RING if ring else O_OLD
		var caught := 0
		for i in seeds:
			var seed := "dr1-down-%d" % i
			var got := down_and_out(seed, ring)
			if got[0] < 0.0:
				continue
			caught += 1
			t.check(absf(got[1] - got[0] - want) < 1e-6, "%s ring %s: down %.3f s (want %.0f)" % [seed, str(ring), got[1] - got[0], want])
			t.check(got[2] >= got[1] - 1e-6 and got[2] < got[1] + DT + 1e-6, "%s ring %s: out at %.3f, until %.3f" % [seed, str(ring), got[2], got[1]])
			t.check(got[4] > 0.0 and got[3] >= got[4] - 1.0, "%s ring %s: the Orderly stays bent over them the whole time (%d of %d ticks)" % [seed, str(ring), int(got[3]), int(got[4])])
		t.check(caught > 0, "ring %s: no seed caught p0 (vacuous)" % str(ring))

func test_the_live_setting_moves_it(t: T) -> void:
	var s := Run.with_down_ring(Run.create_run("dr1-set", ["p0"] as Array[String], [], false, false, true))
	t.eq(Run.down_time(s), O_RING, "the game's value: 30 s")
	t.eq(Run.down_time(Run.with_tuning(s, {&"down.ring": 45.0})), 45.0, "down.ring 45")
	t.eq(Run.down_time(Run.with_tuning(s, {&"down.time": 12.0})), O_RING, "down.time is not read with the ring")
	var off := Run.create_run("dr1-set", ["p0"] as Array[String], [], false, false, true)
	t.eq(Run.down_time(off), O_OLD, "off: ten as recorded")
	t.eq(Run.down_time(Run.with_tuning(off, {&"down.ring": 45.0})), O_OLD, "off: down.ring is not read")
	var seed_hit := false
	for i in (3 if t.quick else 6):
		var got := down_and_out("dr1-down-%d" % i, true, {&"down.ring": 20.0})
		if got[0] >= 0.0:
			seed_hit = true
			t.check(absf(got[1] - got[0] - 20.0) < 1e-6, "down.ring 20 in a run: %.3f" % (got[1] - got[0]))
	t.check(seed_hit, "a seed caught p0 (vacuous)")

## A downs block with one row for "a", down `span` seconds from 100.
static func snap_at(host_now: float, span: float) -> Dictionary:
	var row := PDV.row("a", 100.0)
	row["until"] = 100.0 + span
	return PDV.snap("down", [row], [PDV.fig("b", "ok", 5, 0)], host_now)

func test_the_ring_on_screen(t: T) -> void:
	var v := DownView.new()
	var names := {"a": "Ann", "b": "Bob"}
	var last := 2.0
	var steps := 0
	for k in 61:
		var now := 100.0 + k * 0.5
		v.update(snap_at(now, O_RING), "a", names, false)
		var want := clampf((100.0 + O_RING - now) / O_RING, 0.0, 1.0)
		t.check(absf(v.left - want) < 1e-9, "at %.1f s: the ring's share %.4f is the time left over the whole (%.4f)" % [now - 100.0, v.left, want])
		t.check(v.left <= last + 1e-12, "it only runs out (%.4f after %.4f)" % [v.left, last])
		last = v.left
		var arc := Hud.ring_arc(v.left)
		t.check(absf((arc[1] - arc[0]) - TAU * v.left) < 1e-9 and absf(arc[1] - (-PI * 0.5 + TAU)) < 1e-9,
			"at %.1f s: the arc is %.4f of a turn ending at the top" % [now - 100.0, (arc[1] - arc[0]) / TAU])
		steps += 1
	t.eq(steps, 61, "half-second steps over the 30 s")
	v.update(snap_at(100.0 + O_RING, O_RING), "a", names, false)
	t.eq(v.left, 0.0, "at the out the ring is empty")
	t.check(Hud.ring_arc(0.0)[1] - Hud.ring_arc(0.0)[0] == 0.0, "an empty ring draws nothing")
	t.check(absf(Hud.ring_arc(1.0)[1] - Hud.ring_arc(1.0)[0] - TAU) < 1e-9, "a full ring is the whole circle")
	# Clockwise from the top: as it runs out, the start of what is left moves round clockwise (angles grow).
	t.check(Hud.ring_arc(0.75)[0] < Hud.ring_arc(0.5)[0] and Hud.ring_arc(0.5)[0] < Hud.ring_arc(0.25)[0], "it empties clockwise")
	# The heal prompt is still there.
	var healing := snap_at(110.0, O_RING)
	(healing["downs"]["down"][0] as Dictionary)["healer"] = "b"
	(healing["downs"]["down"][0] as Dictionary)["healFrom"] = 109.0
	v.update(healing, "a", names, false)
	t.check(v.line == "BOB IS HELPING YOU UP" and v.heal > 0.0, "the heal's line and bar stay (%s, %.2f)" % [v.line, v.heal])

func test_the_flag_needs_the_down_rule(t: T) -> void:
	var r := HostRules.new(true, 1, Places.FULL)
	t.check(not r.down_ring, "off by default")
	var st := r.prepare(Run.create_run("dr1-flag", ["p0", "p1"] as Array[String], Places.FULL))
	t.check(not st.down_ring, "off: the run does not have it")
	var on := HostRules.new(true, 1, Places.FULL, false, false, true)
	on.down_ring = true
	t.check(on.prepare(Run.create_run("dr1-flag", ["p0", "p1"] as Array[String], Places.FULL)).down_ring, "on with downs: the run has it")
	var nodowns := HostRules.new(true, 1, Places.FULL)
	nodowns.down_ring = true
	t.check(not nodowns.prepare(Run.create_run("dr1-flag", ["p0", "p1"] as Array[String], Places.FULL)).down_ring, "without the down rule it stays off")
	t.check(Run.with_down_ring(st).copy().down_ring, "copy() keeps it")
