# FX2: on the Annex, what looks like a hiding place is one, and what is not one does not look like one. The owner,
# 20 Nov: "ctrl + walk under desk doesn't work for annex." and "Same for hiding in cabinet." (PN3 made the real
# hides work under Lonely, flag pn_fixes_); the hiding design: a player must be able to tell by looking what can
# hide them. Checked on the pieces the Annex draws (sim/furniture.gd's one list, drawn by client/annex_view.gd
# piece_boxes), with and without the restored wall furniture (T20j), over many seeds:
#   1. a piece looks enterable (looks_enterable: a kneehole, open under a top from the front, a body wide; or a
#      cupboard's door: a seam, or a leaf with a handle, at its front at least knee to waist tall) exactly when
#      it is a desk, cabinet or table hide on the rules' list;
#   2. in the game's Annex (floor 3 of the full deck, Lonely, pn_fixes on), at every desk, cabinet and table hide
#      on the floor, the press at its front (the client's Ctrl-walk under a desk is the same press) gets the
#      player inside it.
# What changed to make 1 hold (client/annex_view.gd catalogue): the break room's wall table has a solid modesty
# panel to the floor at its front and ends (its open legs read as a desk to crawl under); the kitchen counter has
# drawers where it had cupboard doors; the meeting room's low cupboard is open shelving; the filing cabinet is
# steel grey (the hide's cabinet is cream and twice as wide).
extends RefCounted

const T = preload("res://tests/t.gd")
const AnnexView = preload("res://client/annex_view.gd")
const Annex = preload("res://sim/annex.gd")
const Furniture = preload("res://sim/furniture.gd")
const Hides = preload("res://sim/hides.gd")
const Hiding = preload("res://sim/hiding.gd")
const Playroom = preload("res://sim/playroom.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Seek = preload("res://sim/seek.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")

const LOOK_SEEDS := 40
const QUICK_LOOK_SEEDS := 12
const ENTER_SEEDS := 3
const QUICK_ENTER_SEEDS := 1
const HIDE_KINDS: Array[StringName] = [&"desk", &"cabinet", &"table"]
const DT := 0.05
const IDS: Array[String] = ["p0", "p1"]

## The lowest front of a set of boxes ([size, centre, colour], front towards -z).
static func _front(boxes: Array) -> float:
	var front := INF
	for b: Array in boxes:
		front = minf(front, (b[1] as Vector3).z - (b[0] as Vector3).z * 0.5)
	return front

static func _lo(b: Array) -> Vector3:
	return (b[1] as Vector3) - (b[0] as Vector3) * 0.5

static func _hi(b: Array) -> Vector3:
	return (b[1] as Vector3) + (b[0] as Vector3) * 0.5

## A kneehole: a top between 55 and 95 cm up, at least 60 by 35 cm, with a run at least 50 cm wide open under it
## from 10 to 50 cm up along its front 15 cm.
static func kneehole(boxes: Array) -> bool:
	for top: Array in boxes:
		var lo := _lo(top)
		var hi := _hi(top)
		if lo.y < 0.55 or lo.y > 0.95 or hi.x - lo.x < 0.6 or hi.z - lo.z < 0.35:
			continue
		var blocked: Array[Vector2] = []
		for b: Array in boxes:
			var blo := _lo(b)
			var bhi := _hi(b)
			if bhi.y > 0.1 and blo.y < 0.5 and bhi.z > lo.z and blo.z < lo.z + 0.15:
				blocked.append(Vector2(blo.x, bhi.x))
		blocked.sort_custom(func(a: Vector2, c: Vector2) -> bool: return a.x < c.x)
		var at := lo.x
		var widest := 0.0
		for run: Vector2 in blocked:
			widest = maxf(widest, run.x - at)
			at = maxf(at, run.y)
		widest = maxf(widest, hi.x - at)
		if widest >= 0.5:
			return true
	return false

## A cupboard's door at the front: a seam (at most 5 cm wide) or a leaf with a handle on it, at least 45 cm tall.
static func door(boxes: Array) -> bool:
	var front := _front(boxes)
	for b: Array in boxes:
		var size: Vector3 = b[0]
		var lo := _lo(b)
		var hi := _hi(b)
		if size.z > 0.035 or size.y < 0.45 or lo.z > front + 0.06:
			continue
		if size.x <= 0.05:
			return true
		for k: Array in boxes:
			var ks: Vector3 = k[0]
			var kc: Vector3 = k[1]
			if maxf(ks.x, ks.y) <= 0.2 and kc.z < (b[1] as Vector3).z and kc.x > lo.x and kc.x < hi.x and kc.y > lo.y and kc.y < hi.y:
				return true
	return false

static func looks_enterable(boxes: Array) -> bool:
	return kneehole(boxes) or door(boxes)

func test_only_the_hides_look_like_hides(t: T) -> void:
	var seeds := QUICK_LOOK_SEEDS if t.quick else LOOK_SEEDS
	var wrong: Array[String] = []
	var counts := {}
	for k in seeds:
		var plan := Annex.generate_annex("fx2-look-%d" % k, 1 + k % 4)
		var hides := Hides.hides_for(plan, plan.seed)
		for restored: bool in [false, true]:
			for pc: Furniture.Piece in Furniture.pieces_for(plan, plan.seed, plan.depth, restored, hides):
				var boxes := AnnexView.piece_boxes(pc, hides)
				var is_hide := pc.hide >= 0 and HIDE_KINDS.has((hides[pc.hide] as Playroom.Hide).kind)
				var looks := looks_enterable(boxes)
				var key := "%s%s" % ["hide:" if pc.hide >= 0 else "", pc.kind]
				counts[key] = int(counts.get(key, 0)) + 1
				if looks != is_hide:
					var what := "%s on %s (%s)" % [key, plan.seed, "looks like a hide and is not one" if looks else "is a hide and does not look like one"]
					if not wrong.has(what):
						wrong.append(what)
	t.check(wrong.is_empty(), "a piece looks enterable exactly when it is a desk, cabinet or table hide (%d wrong: %s)" % [wrong.size(), "; ".join(wrong.slice(0, 6))])
	for kind: String in ["hide:desk", "hide:cabinet", "hide:table", "break_table", "counter", "cabinet_low", "filing"]:
		t.check(int(counts.get(kind, 0)) > 0, "the seeds draw at least one %s (%d)" % [kind, int(counts.get(kind, 0))])
	t.note("%d Annexes, with and without the restored furniture: %s" % [seeds, str(counts)])

## The game's Annex (floor 3 of the full deck, Lonely on), the fixes on.
static func annex(run_seed: String) -> Run.RunState:
	var rules := HostRules.new(true, 3, Places.FULL, false, false, true, false, false, false, false, false, true)
	rules.pn_fixes = true
	return rules.prepare(Run.create_run(run_seed, IDS, Places.FULL))

static func _inputs(s: Run.RunState, bodies: Dictionary, press: bool) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		var inp := Run.PlayerInput.make(p.id, bodies.get(p.id, p.body), 1.65, 0.0, 0.0, 90.0, 70.0)
		inp.gait = &"creep"
		inp.hide_use = press and p.id == "p0"
		out.append(inp)
	return out

## p0 at the hide's front and p1 at the landing, both off the car; F once, then 2 s. Whether p0 is inside it.
static func gets_in(s0: Run.RunState, h: Playroom.Hide) -> bool:
	var s := s0.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	var bodies := {"p0": Seek.hide_front_body(s.plan, h), "p1": Move.body_at_cell(s.plan, s.plan.landing)}
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		np.body = bodies[p.id]
		np.aboard = false
		players.append(np)
	s.players = players
	s = Run.step_run(s, _inputs(s, bodies, false), DT).state
	s = Run.step_run(s, _inputs(s, bodies, true), DT).state
	for _k in roundi(2.0 / DT):
		s = Run.step_run(s, _inputs(s, bodies, false), DT).state
	var hp := Hiding.player_of(s.hiding, "p0") if s.hiding != null else null
	return hp != null and hp.phase == &"inside" and hp.hide == h.id

func test_every_desk_cabinet_and_table_takes_you_in(t: T) -> void:
	var seeds := QUICK_ENTER_SEEDS if t.quick else ENTER_SEEDS
	var tried := 0
	var refused: Array[String] = []
	for k in seeds:
		var s := annex("fx2-enter-%d" % k)
		if not t.check(s.plan.place == Places.ANNEX and Run.resident_of(s).trait_name == &"lonely", "seed %d: the game's Annex with the Lonely Temp" % k):
			continue
		for h: Playroom.Hide in Hides.hides_for(s.plan, s.plan.seed):
			if not HIDE_KINDS.has(h.kind):
				continue
			tried += 1
			if not gets_in(s, h):
				refused.append("%s %d (level %d) on %s" % [h.kind, h.id, h.level, s.plan.seed])
	t.check(tried > 0, "hides tried (%d)" % tried)
	t.check(refused.is_empty(), "every desk, cabinet and table takes a player in at a press at its front (%d of %d refused: %s)" % [refused.size(), tried, ", ".join(refused.slice(0, 6))])
	t.note("%d hides entered on %d Annexes" % [tried, seeds])
