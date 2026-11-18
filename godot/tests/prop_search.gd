# Searching in the run and on the network (docs/floors/findables-and-day.md section 3 "Searching" and "Credits found,
# the quota and pay", FD9; sim/run.gd findables, sim/findables.gd step, net/host.gd find_block, net/protocol.gd "find").
# Proved here:
#   1. no piece pays twice: two players holding F on one piece, one finds and the other's search stops with nothing;
#      a whole floor searched twice opens each piece once, and the credits found are the fill's;
#   2. found credits raise the day's earned (with the day lock) and the finder's tape, and never the floor's earned:
#      a call short of the floor quota only by found credits is refused;
#   3. a rushed search takes 0.8 s, finds exactly half the credits (rounded down), logs one noise and wakes a
#      resident still standing where the floor began; a careful one takes 2.5 s, finds them all and logs none;
#      letting go does not stop a rushed search;
#   4. under Stillness a searching player is never one of the resident's watchers (while the same player, not
#      searching, is);
#   5. a cancelled search (let go, moved, sprinting) opens nothing and pays nothing;
#   6. a carton adds exactly one to the finder's items and changes nothing else (the inventory and the nerve bar
#      are later work: nothing drinks it yet); cartons are gone the next morning;
#   7. over bot days (6 quick, 40, 200 full): every BANK's total is the readings plus the found credits on the
#      tapes aboard, found credits are never on two tapes or lost while held, and the carton count empties every
#      morning;
#   8. with findables off (every stored result) nothing happens: no state, no events, no snapshot block;
#   9. three bots on lossy links (tests/net_harness.gd's LOSSY), through the real NetHost and NetClient, search
#      pieces on the Clinic: every client ends the floor with the host's opened list and every tape's found credits.
# Breaks (the design's): Findables.test_break "floor_earned" (found credits added to the floor's earned: the refused
# call of check 2 goes red), "careful_noise" (the careful search logs the noise: check 3 goes red).
# PROP_SEARCH_BREAK=floor_earned|careful_noise.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Findables = preload("res://sim/findables.gd")
const Furniture = preload("res://sim/furniture.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Places = preload("res://sim/places.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Harness = preload("res://tests/net_harness.gd")
const DayNet = preload("res://tests/prop_day_net.gd")
const DayRigLib = preload("res://tests/day_rig.gd")

const DT := 0.05

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_SEARCH_BREAK")
	Findables.test_break = b if b == "floor_earned" or b == "careful_noise" else ""

static func _ids(n: int) -> Array[String]:
	var out: Array[String] = []
	for k in n:
		out.append("p%d" % k)
	return out

## A run with findables on floor `depth` of the game's deck (Lonely off: the Annex is Stillness), the resident
## parked unless asked for.
static func find_run(seed: String, ids: Array[String], depth: int = 1, days: bool = false, quota: bool = false, resident: bool = false) -> Run.RunState:
	var rules := HostRules.new(true, depth, Places.FULL, days, quota, false, false, false, false, false, false, false, false, quota and days, false, true)
	var s := rules.prepare(Run.create_run(seed, ids))
	if not resident:
		s = s.copy()
		s.orderly = HostRules.parked_orderly(s)
	return s

static func inp(id: String, body: Move.Body, yaw: float = 0.0, search: bool = false, fast: bool = false) -> Run.PlayerInput:
	var i := Run.PlayerInput.make(id, body, 1.65, yaw, 0.0, 90.0, 70.0)
	i.search = search
	i.search_fast = fast
	return i

## Steps with everyone where the run has them, until the arrival doors are open (the floor's findables are made).
static func open_doors(s0: Run.RunState) -> Run.RunState:
	var s := s0
	for _k in 200:
		if s.phase == &"unloading" and s.find != null:
			return s
		var ins: Array[Run.PlayerInput] = []
		for p in s.players:
			ins.append(inp(p.id, p.body))
		s = Run.step_run(s, ins, DT).state
	return s

## Where to stand to search a piece: 45 cm in front of its side facing into the room, facing its centre.
static func stand(p: Furniture.Piece) -> Array:
	var inward := -Furniture.dir_vec(p.wall) if p.wall != &"" else Furniture.dir_vec(p.facing)
	var ext := p.foot.size.x / 2 if inward.x != 0 else p.foot.size.y / 2
	var c := p.foot.position + p.foot.size / 2
	var at := c + inward * (ext + 45)
	var body := Move.Body.make(at.x / 100.0, at.y / 100.0, p.level, Move.LEVEL_HEIGHT if p.level == 1 else 0.0)
	return [body, Entity.yaw_toward(p.x / 100.0 - body.x, p.y / 100.0 - body.z)]

## The pieces a body standing at stand(p) searches: p itself, for these.
static func reachable(ff: Findables.FindFloor) -> Array[Furniture.Piece]:
	var out: Array[Furniture.Piece] = []
	for p in ff.pieces:
		var sp := stand(p)
		if Findables.piece_in_reach(ff, sp[0], sp[1]) == p:
			out.append(p)
	return out

## The first reachable piece holding `what` (with at least `min_credits`), or null.
static func piece_with(ff: Findables.FindFloor, what: String, min_credits: int = 0) -> Furniture.Piece:
	for p in reachable(ff):
		var c: Dictionary = ff.fill.contents[p.id]
		if str(c["what"]) == what and int(c["credits"]) >= min_credits:
			return p
	return null

static func one(x: Run.PlayerInput) -> Array[Run.PlayerInput]:
	var a: Array[Run.PlayerInput] = [x]
	return a

static func of_type(events: Array, ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in events:
		if str(e.get("type")) == ty:
			out.append(e)
	return out

## Steps `seconds` with these players' inputs (a Callable (RunState, k) -> Array[PlayerInput]); returns
## [state, events].
static func run_for(s0: Run.RunState, seconds: float, inputs: Callable) -> Array:
	var s := s0
	var events: Array[Dictionary] = []
	for k in roundi(seconds / DT):
		var r := Run.step_run(s, inputs.call(s, k), DT)
		s = r.state
		events.append_array(r.events)
	return [s, events]

static func member_found(s: Run.RunState, id: String) -> float:
	var m := Instr.member(s.crew, id)
	var sum := 0.0
	for tp: TapeLib.Tape in [m.tape] + m.carrying:
		sum += Run.found_on(tp)
	return sum

# ---------------------------------------------------------------------------------------------
# 1. No piece pays twice.

func test_no_piece_pays_twice(t: T) -> void:
	for depth: int in [1, 3]:
		var ids := _ids(2)
		var s := open_doors(find_run("twice-%d" % depth, ids, depth))
		if not t.check(s.find != null, "depth %d: the floor's findables are made when the doors open" % depth):
			return
		var ff: Findables.FindFloor = s.find
		var list := reachable(ff)
		t.check(list.size() * 10 >= ff.pieces.size() * 8, "depth %d: %d of %d pieces reached from their front" % [depth, list.size(), ff.pieces.size()])
		# Two players, one piece.
		var p := list[0]
		var sp := stand(p)
		var both := func(_s: Run.RunState, _k: int) -> Array[Run.PlayerInput]:
			var a: Array[Run.PlayerInput] = [inp("p0", sp[0], sp[1], true), inp("p1", sp[0], sp[1], true)]
			return a
		var out := run_for(s, 3.0, both)
		var done := of_type(out[1], "searchDone")
		var stops := of_type(out[1], "searchStop")
		t.eq(done.size(), 1, "depth %d: two holding F on piece %d, one finds" % [depth, p.id])
		t.check(stops.size() == 1 and stops[0]["why"] == "taken" and stops[0]["playerId"] != done[0]["playerId"],
			"depth %d: the other's search stops with nothing: %s" % [depth, str(stops)])
		# Let go, and hold F at the opened piece again: nothing starts.
		var again := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
			var a: Array[Run.PlayerInput] = [inp("p0", sp[0], sp[1], k > 0), inp("p1", sp[0], sp[1], k > 0)]
			return a
		var out2 := run_for(out[0], 3.0, again)
		t.eq(of_type(out2[1], "searchStart").filter(func(e: Dictionary) -> bool: return int(e["piece"]) == p.id).size(), 0, "depth %d: an opened piece is never searched again" % depth)
		# The whole floor, twice, by one player.
		s = out2[0]
		var paid := {p.id: true}
		var credits := int(done[0]["credits"]) if done.size() == 1 else 0
		var twice := 0
		for pass_n in 2:
			for q in list:
				var qs := stand(q)
				var walk := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
					var a: Array[Run.PlayerInput] = [inp("p0", qs[0], qs[1], k > 0 and k < 55), inp("p1", Run.car_body(_s.car, -1.0, 0.0))]
					return a
				var o := run_for(s, 2.9, walk)
				s = o[0]
				for e in of_type(o[1], "searchDone"):
					if paid.has(int(e["piece"])):
						twice += 1
					paid[int(e["piece"])] = true
					credits += int(e["credits"])
		var fill_credits := 0
		for id: int in (s.find as Findables.FindFloor).opened:
			var c: Dictionary = ff.fill.contents[id]
			if c["what"] == "credits":
				fill_credits += int(c["credits"])
		t.eq(twice, 0, "depth %d: pieces that paid twice" % depth)
		t.eq(credits, fill_credits, "depth %d: the credits found are the opened pieces' fill" % depth)
		t.eq(member_found(s, "p0") + member_found(s, "p1"), float(credits), "depth %d: and they are on the finders' tapes" % depth)
		t.note("depth %d (%s): %d pieces, %d opened, %d credits found" % [depth, s.plan.place, ff.pieces.size(), paid.size(), credits])

# ---------------------------------------------------------------------------------------------
# 2. Found credits count for the day, not the floor.

func test_found_credits_count_for_the_day_not_the_floor(t: T) -> void:
	_apply_break()
	var ids := _ids(1)
	var s := open_doors(find_run("day-not-floor", ids, 1, true, true))
	if not t.check(s.day_lock and s.quota and s.findables, "the day lock, the floor quota and findables are on"):
		Findables.test_break = ""
		return
	var ff: Findables.FindFloor = s.find
	var p := piece_with(ff, "credits")
	if not t.check(p != null, "a piece with credits"):
		Findables.test_break = ""
		return
	var sp := stand(p)
	var day0 := s.day_earned
	var floor0 := s.floor_earned
	var hold := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
		return one(inp("p0", sp[0], sp[1], k > 0))
	var out := run_for(s, 2.8, hold)
	s = out[0]
	var done := of_type(out[1], "searchDone")
	if not t.eq(done.size(), 1, "the search finished"):
		Findables.test_break = ""
		return
	var c := int(done[0]["credits"])
	t.check(c > 0, "credits found: %d" % c)
	t.eq(s.day_earned, day0 + c, "the day's earned rose by the credits found")
	t.eq(s.floor_earned, floor0, "the floor's earned did not move")
	t.eq(member_found(s, "p0"), float(c), "the credits are on the finder's tape")
	t.eq(of_type(out[1], "readingClosed").size(), 0, "a find is no reading")
	# Recorded on the instrument: exactly what the floor needs less the credits found. The call is refused.
	s = s.copy()
	s.floor_earned += float(s.floor_needed - c)
	var door := Run.car_body(s.car, -1.0, 0.0)
	var call_it := func(st: Run.RunState, _k: int) -> Array[Run.PlayerInput]:
		var i := inp("p0", door)
		i.call = st.phase == &"away"
		return one(i)
	var o2 := run_for(s, 40.0, call_it)
	var refused := of_type(o2[1], "callRefused")
	t.check(not refused.is_empty() and of_type(o2[1], "called").is_empty(),
		"a call short of the floor quota only by found credits is refused (%d refused, %d called; earned %.0f of %d)" % [refused.size(), of_type(o2[1], "called").size(), (o2[0] as Run.RunState).floor_earned, s.floor_needed])
	Findables.test_break = ""

# ---------------------------------------------------------------------------------------------
# 3. Rushed and careful.

func test_rushed_is_fast_loud_and_half_careful_is_slow_and_silent(t: T) -> void:
	_apply_break()
	var ids := _ids(1)
	var base := open_doors(find_run("rush", ids, 1, false, false, true))
	var ff: Findables.FindFloor = base.find
	var p := piece_with(ff, "credits", 3)
	if not t.check(p != null, "a piece with 3 credits or more"):
		Findables.test_break = ""
		return
	var full := int(ff.fill.contents[p.id]["credits"])
	var sp := stand(p)
	t.eq(base.orderly.mode, &"waiting", "the resident still stands where the floor began")
	var results := {}
	for fast: bool in [false, true]:
		# Hold F (with sprint, rushed) for a moment only: a rushed search goes on; a careful one is held throughout.
		var press := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
			var held := k > 0 and (k < 4 if fast else true)
			return one(inp("p0", sp[0], sp[1], held, fast))
		var out := run_for(base, 3.0, press)
		var ev: Array = out[1]
		var start := of_type(ev, "searchStart")
		var done := of_type(ev, "searchDone")
		var noise := of_type(ev, "searchNoise")
		var woke := of_type(ev, "startedHunting")
		var tag := "rushed" if fast else "careful"
		if not t.check(start.size() == 1 and done.size() == 1, "%s: one search, finished (%d started, %d done)" % [tag, start.size(), done.size()]):
			continue
		var took := float(start[0]["done"]) - float(start[0]["from"])
		t.check(absf(took - (Findables.SEARCH_FAST if fast else Findables.SEARCH_SLOW)) < 1e-6, "%s: takes %.2f s" % [tag, took])
		t.check(absf(float(done[0]["t"]) - float(start[0]["done"])) < DT + 1e-6, "%s: done when it said" % tag)
		t.eq(int(done[0]["credits"]), full / 2 if fast else full, "%s: credits found (the piece holds %d)" % [tag, full])
		t.eq(noise.size(), 1 if fast else 0, "%s: noise events" % tag)
		t.eq(woke.size(), 1 if fast else 0, "%s: the resident woke" % tag)
		results[tag] = int(done[0]["credits"])
	t.note("a piece of %d credits: careful %s, rushed %s" % [full, str(results.get("careful")), str(results.get("rushed"))])
	Findables.test_break = ""

# ---------------------------------------------------------------------------------------------
# 4. A searcher is not a watcher.

func test_a_searcher_is_never_a_watcher(t: T) -> void:
	var ids := _ids(1)
	var s := open_doors(find_run("watch", ids, 1, false, false, true))
	var ff: Findables.FindFloor = s.find
	var tried := 0
	var held_while_looking := 0
	var watched_while_searching := 0
	var searched_ticks := 0
	for p in reachable(ff):
		if tried >= 6:
			break
		var sp := stand(p)
		# The resident where the piece is: in front of the player's eyes.
		var st := s.copy()
		var o := st.orderly.copy()
		o.body = Move.Body.make(p.x / 100.0, p.y / 100.0, p.level, sp[0].y)
		o.mode = &"hunting"
		st.orderly = o
		var look := Run.step_run(st, one(inp("p0", sp[0], sp[1])), DT).state
		if not look.orderly.watchers.has("p0"):
			continue
		tried += 1
		held_while_looking += 1
		var cur := st
		for k in 40:
			var r := Run.step_run(cur, one(inp("p0", sp[0], sp[1], true)), DT)
			cur = r.state
			if Run.searching(cur, "p0"):
				searched_ticks += 1
				if cur.orderly.watchers.has("p0"):
					watched_while_searching += 1
	t.check(tried >= 3, "not vacuous: the player held it by looking at %d pieces" % tried)
	t.eq(watched_while_searching, 0, "ticks a searching player was a watcher (of %d searching ticks)" % searched_ticks)
	t.check(searched_ticks > 0, "searching ticks: %d" % searched_ticks)

# ---------------------------------------------------------------------------------------------
# 5. A cancelled search opens nothing.

func test_a_cancelled_search_opens_nothing(t: T) -> void:
	var ids := _ids(1)
	var s := open_doors(find_run("cancel", ids))
	var ff: Findables.FindFloor = s.find
	var p := piece_with(ff, "credits")
	if not t.check(p != null, "a piece with credits"):
		return
	var sp := stand(p)
	var b0: Move.Body = sp[0]
	for why: String in ["let_go", "moved", "interrupted"]:
		var f := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
			var i := inp("p0", b0, sp[1], k > 0)
			if why == "let_go":
				i.search = k > 0 and k < 20
			elif why == "moved":
				i.body = Move.Body.make(b0.x + (0.3 if k >= 20 else 0.0), b0.z, b0.level, b0.y)
			else:
				i.gait = &"sprint" if k >= 20 else &"walk"
			return one(i)
		var out := run_for(s, 3.5, f)
		var st: Run.RunState = out[0]
		var stops := of_type(out[1], "searchStop")
		t.check(stops.size() == 1 and stops[0]["why"] == why, "%s: the search stops (%s)" % [why, str(stops)])
		t.eq(of_type(out[1], "searchDone").size(), 0, "%s: nothing found" % why)
		t.check(not (st.find as Findables.FindFloor).opened.has(p.id), "%s: the piece is not opened" % why)
		t.eq(member_found(st, "p0"), 0.0, "%s: nothing on the tape" % why)
	# Not while sprinting, in the car, or with F let go in between: a held F does not start a second search.
	var sprinting := func(_s: Run.RunState, _k: int) -> Array[Run.PlayerInput]:
		var i := inp("p0", b0, sp[1], true)
		i.gait = &"sprint"
		return one(i)
	var out2 := run_for(s, 1.0, sprinting)
	t.eq(of_type(out2[1], "searchStart").size(), 0, "no search starts while sprinting")

# ---------------------------------------------------------------------------------------------
# 6. Cartons.

func test_a_carton_is_one_item_and_nothing_else(t: T) -> void:
	var ids := _ids(1)
	var s := open_doors(find_run("carton", ids, 1, true, true))
	var ff: Findables.FindFloor = s.find
	var got := 0
	for p in reachable(ff):
		if ff.fill.contents[p.id]["what"] != "juice":
			continue
		var sp := stand(p)
		var day0 := s.day_earned
		var tape0 := Instr.member(s.crew, "p0").tape
		var hold := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
			return one(inp("p0", sp[0], sp[1], k > 0))
		var out := run_for(s, 2.8, hold)
		var done := of_type(out[1], "searchDone")
		if not t.check(done.size() == 1 and done[0]["what"] == "juice", "a carton found: %s" % str(done)):
			continue
		got += 1
		var st: Run.RunState = out[0]
		t.eq(int((st.items.get("p0", {}) as Dictionary).get(String(Findables.JUICE), 0)), got, "cartons carried after %d found" % got)
		t.eq(st.day_earned, day0, "a carton is no credit")
		t.check(Instr.member(st.crew, "p0").tape == tape0, "the tape is untouched")
		s = st
	t.check(got >= 2, "cartons found: %d" % got)
	var blk: Variant = Host.find_block(s)
	t.check(blk != null and (blk["items"] as Array).size() == 1 and int(blk["items"][0]["juice"]) == got, "the snapshot says who carries what: %s" % str(blk["items"] if blk != null else null))

# ---------------------------------------------------------------------------------------------
# 7. Over bot days: what is banked.

func test_banked_is_readings_plus_found_over_bot_days(t: T) -> void:
	var days := 6 if t.quick else (200 if t.full else 40)
	var ids := _ids(3)
	var rig := DayRigLib.DayRig.new("search-days", ids)
	rig.st = Run.with_findables(rig.st)
	var rng := Rng.make_rng("search-days")
	var c := {"banks": 0, "found": 0, "found_banked": 0, "searches": 0, "cartons": 0, "drops": 0, "bad": 0}
	var visited := {}
	var done := 0
	var k := 0
	var max_ticks := roundi(float(days) * 1500.0 / DayRigLib.DT)
	while done < days and rig.ticks < max_ticks and c["bad"] < 10:
		var key := "%d/%d" % [rig.st.day_index, rig.st.depth]
		if not Run.at_home(rig.st) and rig.st.phase == &"away" and not visited.has(key) and rig.st.find != null:
			visited[key] = true
			for id in ids:
				var roll := rng.next()
				rig.vote[id] = "bank" if roll < 0.6 else ("down" if roll < 0.9 else "out")
			# Somebody searches a few pieces (placed, not walked: the rules do not police speed).
			var who: String = ids[rng.int_in(0, ids.size() - 1)]
			var list := reachable(rig.st.find as Findables.FindFloor)
			for n in rng.int_in(1, 4):
				if list.is_empty():
					break
				var p: Furniture.Piece = list.pop_at(rng.int_in(0, list.size() - 1))
				var sp := stand(p)
				var fast := rng.chance(0.3)
				var go := func(st: Run.RunState, j: int) -> Array[Run.PlayerInput]:
					var a: Array[Run.PlayerInput] = []
					for id in ids:
						if id == who:
							a.append(inp(id, sp[0], sp[1], j > 0 and j < 56, fast))
						else:
							a.append(inp(id, Run.car_body(st.car, -1.0, -0.5 + 0.5 * ids.find(id))))
					return a
				var o := run_for(rig.st, 3.0, go)
				rig.st = o[0]
				rig.events.append_array(o[1])
				for e in of_type(o[1], "searchDone"):
					c["searches"] += 1
					c["found"] += int(e["credits"])
					if e["what"] == "juice":
						c["cartons"] += 1
			rig.bodies[who] = Run.car_body(rig.st.car, -1.0, 0.0)
			var s := rig.st
			for id in ids:
				k += 1
				s = DayRigLib.give(s, id, 1.0 + rng.next() * 300.0, "sd-%d" % k)
			if rng.chance(0.3):
				s = DayRigLib.drop_own(s, ids[rng.int_in(0, 2)])
				c["drops"] += 1
			rig.st = s
		var before := rig.st
		var r := rig.step()
		for e in r.events:
			if e["type"] == "newDay":
				done += 1
				if not rig.st.items.is_empty():
					c["bad"] += 1
					t.check(false, "day %d: cartons carried into the morning: %s" % [rig.st.day_index, str(rig.st.items)])
			if e["type"] != "banked":
				continue
			c["banks"] += 1
			var sm: Run.RunSummary = e["summary"]
			var recorded := 0.0
			var found := 0.0
			for m in before.crew.members:
				for tp: TapeLib.Tape in [m.tape] + m.carrying:
					if sm.tapes.has(tp.id):
						var just: Array[TapeLib.Tape] = [tp]
						found += Run.found_on(tp)
						recorded += TapeLib.tape_value(just) - Run.found_on(tp)
			c["found_banked"] += roundi(found)
			if not t.check(absf(sm.total - (recorded + found)) < 1e-6, "day %d: banked %.2f, readings %.2f plus found %.2f on the tapes aboard" % [before.day_index, sm.total, recorded, found]):
				c["bad"] += 1
	t.eq(done, days, "days played")
	t.check(t.quick or (c["banks"] > 0 and c["found_banked"] > 0 and c["drops"] > 0), "not vacuous: %s" % str(c))
	t.note("%d days: %s" % [done, str(c)])

# ---------------------------------------------------------------------------------------------
# 8. Off changes nothing.

func test_off_changes_nothing(t: T) -> void:
	var ids := _ids(1)
	var off := Run.create_run("off", ids, Places.FULL)
	t.check(not off.findables and off.find == null, "a run made as before has no findables")
	t.check(not HostRules.new(true, 1, Places.FULL).prepare(Run.create_run("off", ids)).findables, "HostRules leaves them off unless asked")
	var on := open_doors(find_run("off", ids))
	var ff: Findables.FindFloor = on.find
	var p := reachable(ff)[0]
	var sp := stand(p)
	var s := off
	var events: Array[Dictionary] = []
	for k in 120:
		var r := Run.step_run(s, one(inp("p0", sp[0] if s.phase != &"arriving" else s.players[0].body, sp[1], true, k % 2 == 0)), DT)
		s = r.state
		events.append_array(r.events)
	var kinds := {}
	for e in events:
		if str(e["type"]).begins_with("search"):
			kinds[str(e["type"])] = true
	t.eq(kinds.keys(), [], "search events with findables off")
	t.check(s.find == null and s.items.is_empty(), "no findables state with findables off")
	t.eq(Host.find_block(s), null, "no find block in the snapshot with findables off")

# ---------------------------------------------------------------------------------------------
# 9. Over the network.

const STEP := 0.025
const FRAME := 0.05
const SPEED := 2.0
const RADIUS := 0.3
const NAMES := {"p0": "Ana", "p1": "Bo", "p2": "Cy"}

class Bot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var walk: Follow.PathWalk = null
	var frames := 0
	## The pieces to search, in order ([piece, fast]), the one under way, and how long F has been held.
	var errands: Array = []
	var step := 0
	var holding := 0.0
	var finished := false

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var seed: String
	var ids: Array[String] = ["p0", "p1", "p2"]
	var rng: Rng
	var final_host := {}
	var final_clients := {}
	var done_at := -1.0

	func _init(seed_: String) -> void:
		seed = seed_
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, true)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		for i in ids.size():
			var n := Harness.lossy()
			var tr := net.connect_peer(ids[i])
			for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
				var delay := n.delay_min + rng.next() * (n.delay_max - n.delay_min)
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := Bot.new()
			b.id = ids[i]
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = g + rng.next() * FRAME
			b.client = Client.new(tr, "host", NAMES[ids[i]], g + b.offset)
			bots.append(b)

static func _rows(opened: Array) -> Array:
	var out: Array = []
	for o: Dictionary in opened:
		out.append([int(o["piece"]), str(o["by"]), str(o["what"]), int(o["credits"]), str(o["note"]), bool(o["fast"]), Protocol.q3(float(o["t"]))])
	return out

func _bot_frame(s: Sess, b: Bot) -> void:
	var c := b.client
	b.frames += 1
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	if c.seed != null and c.latest != null and b.body != null and int(c.latest["depth"]) == c.local_depth:
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var phase := str(c.latest["phase"])
		var body := b.body
		if phase != "arriving" and b.step < b.errands.size():
			var p: Furniture.Piece = b.errands[b.step][0]
			var sp := stand(p)
			var to: Move.Body = sp[0]
			if Run.in_car(car, body) or Run.car_local(car, body.x, body.z)[0] > -0.9:
				body = DayNet.walk_toward(plan, phase, car, body, Run.car_body(car, -1.2, -0.6 + 0.6 * b.index))
			elif Move.cell_of(plan, body).x != Move.cell_of(plan, to).x or Move.cell_of(plan, body).y != Move.cell_of(plan, to).y or Move.cell_of(plan, body).level != to.level:
				if b.walk == null:
					b.walk = Follow.start_path_walk(Floor.find_path(plan, Move.cell_of(plan, body), Move.cell_of(plan, to)))
				body = Follow.step_path_walk(plan, b.walk, body, SPEED * FRAME, RADIUS)
				if Follow.path_done(plan, b.walk, body):
					b.walk = null
			else:
				b.walk = null
				var d := M.hypot2(to.x - body.x, to.z - body.z)
				if d > 0.02:
					var stp := minf(SPEED * FRAME, d)
					body = Move.Body.make(body.x + (to.x - body.x) / d * stp, body.z + (to.z - body.z) / d * stp, body.level, body.y)
				else:
					body = to
					lf.yaw = sp[1]
					lf.search = true
					lf.search_fast = bool(b.errands[b.step][1])
					b.holding += FRAME
					if b.holding >= (1.6 if lf.search_fast else 3.4):
						b.step += 1
						b.holding = 0.0
						lf.search = false
		elif b.step >= b.errands.size():
			b.finished = true
		b.body = body
		lf.body = body
	var f := c.frame(s.g + b.offset, lf)
	if f.placed != null:
		b.body = f.placed
		b.walk = null

func _play(s: Sess, limit: float) -> void:
	var last_tick := -1
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		s.host.update(s.g)
		if s.host.tick != last_tick:
			last_tick = s.host.tick
			var all_done := true
			for b in s.bots:
				all_done = all_done and b.finished
			if all_done and s.done_at < 0.0:
				s.done_at = s.g
			if s.done_at >= 0.0 and s.g >= s.done_at + 4.0:
				var hb: Variant = Host.find_block(s.host.state)
				s.final_host = {"opened": _rows(hb["opened"]) if hb != null else [], "found": _tapes_found_host(s.host.state)}
				for b in s.bots:
					var cb: Variant = b.client.findables()
					s.final_clients[b.id] = {"opened": _rows(cb["opened"]) if cb != null else [], "found": _tapes_found_client(b.client)}
				return
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)

static func _tapes_found_host(st: Run.RunState) -> Dictionary:
	var out := {}
	for m in st.crew.members:
		for tp: TapeLib.Tape in [m.tape] + m.carrying:
			out[tp.id] = Protocol.q2(Run.found_on(tp))
	return out

static func _tapes_found_client(c: Client) -> Dictionary:
	var out := {}
	if c.latest == null:
		return out
	for m: Dictionary in c.latest["crew"]:
		for tp: Dictionary in [m["tape"]] + m["carrying"]:
			out[str(tp["id"])] = float(tp.get("found", 0.0))
	return out

func test_three_bots_on_a_lossy_link_agree_on_what_was_found(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var s := Sess.new("search-net")
	var st := s.host.state
	var ff := Findables.start_floor(st.plan, st.plan.seed, st.depth, Run.floor_quota(1, 3), &"stillness", 1, [])
	var list := reachable(ff)
	# Each bot two pieces of its own; all three on one piece (only one finds it); one rushed search.
	var shared: Furniture.Piece = list[0]
	for i in 3:
		s.bots[i].errands = [[list[1 + 2 * i], i == 1], [list[2 + 2 * i], false], [shared, false]]
	var t0 := Time.get_ticks_msec()
	_play(s, 240.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	Session.deck = saved
	var events: Array = []
	for le in s.host.event_log:
		events.append(le.e)
	var done := of_type(events, "searchDone")
	t.check(t.eq(s.final_clients.size(), 3, "every client compared at the floor's end"), "the floor's end was reached (done at %.1f s)" % s.done_at)
	t.check(done.size() >= 7, "searches finished on the host: %d" % done.size())
	t.eq(done.filter(func(e: Dictionary) -> bool: return int(e["piece"]) == shared.id).size(), 1, "the shared piece opened once")
	t.check(not of_type(events, "searchNoise").is_empty(), "the rushed search was heard")
	var found_total := 0.0
	for id: String in s.final_host.get("found", {}):
		found_total += float(s.final_host["found"][id])
	for id: String in s.final_clients:
		var cl: Dictionary = s.final_clients[id]
		t.eq(cl["opened"], s.final_host["opened"], "%s's opened list at the floor's end" % id)
		t.eq(cl["found"], s.final_host["found"], "%s's tapes' found credits at the floor's end" % id)
	var lost := 0
	for k: String in s.net.stats:
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	t.note("%.0f s of play in %.1f s: %d searches finished, %d opened, %.0f credits on tapes; %d messages lost" % [s.g, secs, done.size(), (s.final_host.get("opened", []) as Array).size(), found_total, lost])
