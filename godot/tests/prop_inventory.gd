# The four-slot inventory in the rules (docs/floors/skill-tree.md S1, tracker T21a; sim/inventory.gd, sim/run.gd
# inventory). Proved here:
#   1. a slot fills a stack with room first, then the first empty slot; a fifth different item is refused, and so is
#      a sixth of a full stack; a stack never passes its limit (random adds at limits 1 to 5);
#   2. over many seeded sequences of three players on a floor (moving, selecting, dropping, taking, handing over,
#      one of them going down), no item is ever made or lost: the items in every bag and on the floor are the same
#      before and after every tick, and no slot ever holds more than its limit;
#   3. a player who goes down drops everything where they fell, and a crewmate can take it;
#   4. a hand-over within the reach works, one from just outside it is refused ("reach"), one to full hands is
#      refused ("theirFull"); a drop of an empty hand and a take out of reach are refused and change nothing;
#   5. a carton found by searching goes into slot 1; with full hands the piece stays shut, the carton stays in it,
#      and the finder is told ("searchFull");
#   6. the day's end clears every bag and every pickup (bags are carried home and survive until then);
#   7. with the flag off nothing changes: requests do nothing, no state, no events, no snapshot block, a carton
#      goes where it always went;
#   8. data/items.json names exactly the rules' items, in their order.
# Breaks (PROP_INVENTORY_BREAK, sim/inventory.gd test_break): "stack" (a stack reaches its limit + 1: 1 and 2 red),
# "no_clear" (the morning keeps everything: 6 red), "any_reach" (a hand-over from any distance: 4 red), "dup_drop"
# (a drop leaves the item in the hand too: 2 red).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Inventory = preload("res://sim/inventory.gd")
const Findables = preload("res://sim/findables.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Rng = preload("res://sim/rng.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const PropSearch = preload("res://tests/prop_search.gd")
const DayRigLib = preload("res://tests/day_rig.gd")

const DT := 0.05

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_INVENTORY_BREAK")
	Inventory.test_break = b if b in ["stack", "no_clear", "any_reach", "dup_drop"] else ""

static func _ids(n: int) -> Array[String]:
	var out: Array[String] = []
	for k in n:
		out.append("p%d" % k)
	return out

## A run on floor 1 (the Clinic) of the game's deck with the inventory `on`, the resident parked; downs and
## findables as asked.
static func inv_run(seed: String, ids: Array[String], on: bool = true, downs: bool = false, findables: bool = false) -> Run.RunState:
	var rules := HostRules.new(true, 1, Places.FULL, false, false, downs, false, false, false, false, false, false, false, false, false, findables, on)
	var s := rules.prepare(Run.create_run(seed, ids))
	s = s.copy()
	s.orderly = HostRules.parked_orderly(s)
	return s

static func inp(id: String, body: Move.Body) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)

## Steps with everyone where they are until the arrival doors are open.
static func open_doors(s0: Run.RunState) -> Run.RunState:
	var s := s0
	for _k in 200:
		if s.phase == &"unloading":
			return s
		var ins: Array[Run.PlayerInput] = []
		for p in s.players:
			ins.append(inp(p.id, p.body))
		s = Run.step_run(s, ins, DT).state
	return s

## A spot on the landing outside the car (car-local u < 0 is outside its doors).
static func spot(s: Run.RunState, u: float, v: float) -> Move.Body:
	return Run.car_body(s.car, u, v)

## A copy of the run with these bags ({id: [[item, count], ...]}), selected slot 0.
static func with_bags(s0: Run.RunState, given: Dictionary) -> Run.RunState:
	var s := s0.copy()
	var bags := s.bags.duplicate()
	for id: String in given:
		var b := Inventory.Bag.empty()
		var list: Array = given[id]
		for k in list.size():
			b.slots[k] = [str(list[k][0]), int(list[k][1])]
		bags[id] = b
	s.bags = bags
	return s

## One tick with these inputs; returns the RunStep.
static func tick(s: Run.RunState, ins: Array[Run.PlayerInput]) -> Run.RunStep:
	return Run.step_run(s, ins, DT)

static func ins2(a: Run.PlayerInput, b: Run.PlayerInput) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = [a, b]
	return out

static func of_type(events: Array, ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in events:
		if str(e.get("type")) == ty:
			out.append(e)
	return out

static func req(i: Run.PlayerInput, op: StringName, arg: Variant = null, sel: int = -1) -> Run.PlayerInput:
	i.inv_op = op
	i.inv_arg = arg
	i.inv_select = sel
	return i

## The most any slot holds, in every bag.
static func most_in_a_slot(s: Run.RunState) -> int:
	var most := 0
	for id: String in s.bags:
		var b: Inventory.Bag = s.bags[id]
		for k in Inventory.SLOTS:
			most = maxi(most, b.count(k))
	return most

# ---------------------------------------------------------------------------------------------
# 1. Slots and stacks.

func test_slots_fill_and_a_fifth_is_refused(t: T) -> void:
	_apply_break()
	var b := Inventory.Bag.empty()
	for item: String in ["a", "b", "c", "d"]:
		var r := Inventory.add(b, item, 1, 1)
		t.eq(r.added, 1, "%s goes in" % item)
		b = r.bag
	t.eq([b.item(0), b.item(1), b.item(2), b.item(3)], ["a", "b", "c", "d"], "four different items, one a slot, in order")
	var fifth := Inventory.add(b, "e", 1, 1)
	t.check(fifth.added == 0 and fifth.left == 1 and fifth.bag.totals() == b.totals(), "a fifth different item is refused and changes nothing")
	var again := Inventory.add(b, "a", 1, 1)
	t.check(again.added == 0, "a second of an item at a stack of one is refused when every slot is used")
	# Stacks with room first, then the first empty slot.
	var d := Inventory.Bag.empty()
	d.slots[1] = ["juice", 1]
	var r2 := Inventory.add(d, "juice", 3, 3)
	t.eq([r2.bag.slots[0], r2.bag.slots[1]], [["juice", 1], ["juice", 3]], "with a stack of three the open stack in slot 2 fills first, then slot 1")
	t.eq(r2.added, 3, "three went in")
	# A stack never passes its limit.
	var rng := Rng.make_rng("stacks")
	var over := 0
	for n in (100 if t.quick else 2000):
		var limit := rng.int_in(1, 5)
		var bag := Inventory.Bag.empty()
		for _k in rng.int_in(1, 12):
			bag = Inventory.add(bag, ["juice", "badge"][rng.int_in(0, 1)], rng.int_in(1, 4), limit).bag
		for k in Inventory.SLOTS:
			if bag.count(k) > limit:
				over += 1
	t.eq(over, 0, "slots over their limit after random adds at limits 1 to 5")

# ---------------------------------------------------------------------------------------------
# 2. Nothing made, nothing lost.

func test_no_item_is_made_or_lost(t: T) -> void:
	_apply_break()
	var seeds := 4 if t.quick else (40 if t.full else 12)
	var ticks := 160 if t.quick else 400
	var c := {"drop": 0, "take": 0, "give": 0, "fell": 0, "refused": 0, "ticks": 0}
	var bad := 0
	for sn in seeds:
		var ids := _ids(3)
		var s := open_doors(inv_run("conserve-%d" % sn, ids, true, true))
		var rng := Rng.make_rng("conserve-%d" % sn)
		var limit := 1 if sn % 2 == 0 else 3
		if limit != 1:
			s = Run.with_tuning(s, {&"inv.stack": float(limit)})
		var given := {}
		for id in ids:
			var list: Array = []
			for k in rng.int_in(1, 4):
				list.append([["juice", "badge"][rng.int_in(0, 1)], rng.int_in(1, limit)])
			given[id] = list
		s = with_bags(s, given)
		var bodies := {}
		for k in ids.size():
			bodies[ids[k]] = spot(s, -1.2, -0.6 + 0.6 * k)
		var plan := s.plan
		var downed := false
		for k in ticks:
			var ins: Array[Run.PlayerInput] = []
			for id in ids:
				var p: Run.RunPlayer = null
				for q in s.players:
					if q.id == id:
						p = q
				if p.status != &"ok":
					ins.append(inp(id, p.body))
					continue
				if rng.chance(0.08):
					bodies[id] = spot(s, -0.8 - rng.next() * 2.4, -1.4 + rng.next() * 2.8)
				var i := inp(id, bodies[id])
				var roll := rng.next()
				if roll < 0.12:
					i.inv_select = rng.int_in(0, 3)
				elif roll < 0.22:
					req(i, &"drop")
				elif roll < 0.4:
					var arg: Variant = rng.int_in(0, 20)
					if not s.pickups.is_empty() and rng.chance(0.8):
						arg = (s.pickups[rng.int_in(0, s.pickups.size() - 1)] as Inventory.Pickup).id
					req(i, &"take", arg)
				elif roll < 0.52:
					req(i, &"give", ids[rng.int_in(0, ids.size() - 1)])
				ins.append(i)
			if not downed and k > 20 and rng.chance(0.01):
				# One of them goes down where they stand (as a catch does with the down rule).
				downed = true
				var st := s.copy()
				var players := st.players.duplicate()
				var ev: Array[Dictionary] = []
				Run._go_down(st, players, rng.int_in(0, ids.size() - 1), st.t, &"catch", ev)
				st.players = players
				s = st
			var before := Run.items_in_world(s)
			var r := tick(s, ins)
			var after := Run.items_in_world(r.state)
			c["ticks"] += 1
			if before != after and bad < 5:
				bad += 1
				t.check(false, "seed %d tick %d: items %s became %s (events %s)" % [sn, k, str(before), str(after), str(r.events.filter(func(e: Dictionary) -> bool: return str(e["type"]).begins_with("item")))])
			if most_in_a_slot(r.state) > limit and bad < 5:
				bad += 1
				t.check(false, "seed %d tick %d: a slot holds %d, over the limit %d" % [sn, k, most_in_a_slot(r.state), limit])
			for e in r.events:
				match str(e["type"]):
					"itemDropped":
						c["fell" if e["why"] == "down" else "drop"] += 1
					"itemTaken":
						c["take"] += 1
					"itemGiven":
						c["give"] += 1
					"invRefused":
						c["refused"] += 1
			s = r.state
			if s.plan != plan:
				t.check(false, "seed %d: the floor changed under the test" % sn)
				break
	t.check(c["drop"] > 0 and c["take"] > 0 and c["give"] > 0 and c["refused"] > 0, "not vacuous: %s" % str(c))
	t.check(t.quick or c["fell"] > 0, "someone went down with something in hand: %s" % str(c))
	t.note("%d seeds: %s" % [seeds, str(c)])

# ---------------------------------------------------------------------------------------------
# 3. Down: it falls where they fall.

func test_going_down_drops_everything_where_they_fell(t: T) -> void:
	_apply_break()
	var ids := _ids(2)
	var s := open_doors(inv_run("fall", ids, true, true))
	s = with_bags(s, {"p0": [["juice", 1], ["badge", 1]]})
	var at := spot(s, -1.5, 0.0)
	var near := spot(s, -1.5, 0.8)
	var r := tick(s, ins2(inp("p0", at), inp("p1", near)))
	var st := r.state.copy()
	var players := st.players.duplicate()
	var ev: Array[Dictionary] = []
	Run._go_down(st, players, 0, st.t, &"catch", ev)
	st.players = players
	r = tick(st, ins2(inp("p0", at), inp("p1", near)))
	var drops := of_type(r.events, "itemDropped")
	t.eq(drops.size(), 2, "both items fell")
	t.check(Inventory.bag_of(r.state.bags, "p0").is_empty(), "the downed player's hands are empty")
	var placed := true
	for pk: Inventory.Pickup in r.state.pickups:
		placed = placed and absf(pk.at.x - at.x) < 1e-9 and absf(pk.at.z - at.z) < 1e-9
	t.check(r.state.pickups.size() == 2 and placed, "two pickups where p0 fell: %d" % r.state.pickups.size())
	t.check(drops.all(func(e: Dictionary) -> bool: return e["why"] == "down"), "said as fallen")
	# The crewmate takes one, then the other (one slot each at a stack of one).
	var s2 := r.state
	for n in 2:
		var pk: Inventory.Pickup = s2.pickups[0]
		r = tick(s2, ins2(inp("p0", at), req(inp("p1", near), &"take", pk.id)))
		s2 = r.state
	t.eq(Inventory.bag_of(s2.bags, "p1").totals(), {"juice": 1, "badge": 1}, "the crewmate carries both")
	t.eq(s2.pickups.size(), 0, "nothing left on the floor")

# ---------------------------------------------------------------------------------------------
# 4. Hand-overs and refusals.

func test_hand_over_reach_and_refusals(t: T) -> void:
	_apply_break()
	var ids := _ids(2)
	var s := open_doors(inv_run("hand", ids))
	s = with_bags(s, {"p0": [["juice", 1]]})
	var a := spot(s, -1.5, -0.7)
	var reach := Inventory.HAND_REACH
	# Just outside the reach: refused, nothing moves.
	var far := Move.Body.make(a.x, a.z, a.level, a.y)
	var dir := spot(s, -1.5, 0.7)
	var dx := dir.x - a.x
	var dz := dir.z - a.z
	var dl := sqrt(dx * dx + dz * dz)
	far = Move.Body.make(a.x + dx / dl * (reach + 0.05), a.z + dz / dl * (reach + 0.05), a.level, a.y)
	var r := tick(s, ins2(req(inp("p0", a), &"give", "p1"), inp("p1", far)))
	var refused := of_type(r.events, "invRefused")
	t.check(refused.size() == 1 and refused[0]["why"] == "reach", "a hand-over %.2f m away is refused for reach: %s" % [reach + 0.05, str(refused)])
	t.eq(Inventory.bag_of(r.state.bags, "p0").totals(), {"juice": 1}, "the giver still holds it")
	t.check(Inventory.bag_of(r.state.bags, "p1").is_empty(), "the crewmate got nothing")
	# Just inside: it goes over.
	var inside := Move.Body.make(a.x + dx / dl * (reach - 0.05), a.z + dz / dl * (reach - 0.05), a.level, a.y)
	r = tick(r.state, ins2(req(inp("p0", a), &"give", "p1"), inp("p1", inside)))
	t.eq(of_type(r.events, "itemGiven").size(), 1, "a hand-over %.2f m away goes through" % (reach - 0.05))
	t.eq(Inventory.bag_of(r.state.bags, "p1").totals(), {"juice": 1}, "the crewmate holds it")
	t.check(Inventory.bag_of(r.state.bags, "p0").is_empty(), "the giver's hand is empty")
	# The host's setting moves the reach.
	var tuned := Run.with_tuning(with_bags(r.state, {"p0": [["badge", 1]]}), {&"inv.hand_reach": 2.5})
	var mid := Move.Body.make(a.x + dx / dl * 2.0, a.z + dz / dl * 2.0, a.level, a.y)
	var r2 := tick(tuned, ins2(req(inp("p0", a), &"give", "p1"), inp("p1", mid)))
	t.eq(of_type(r2.events, "itemGiven").size(), 1, "with HAND OVER WITHIN at 2.5 m, 2.0 m goes through")
	# Full hands: refused.
	var full := with_bags(r.state, {"p0": [["badge", 1]], "p1": [["juice", 1], ["juice", 1], ["juice", 1], ["juice", 1]]})
	r = tick(full, ins2(req(inp("p0", a), &"give", "p1"), inp("p1", inside)))
	refused = of_type(r.events, "invRefused")
	t.check(refused.size() == 1 and refused[0]["why"] == "theirFull", "to full hands: refused, theirFull: %s" % str(refused))
	# An empty hand cannot drop; a pickup out of reach cannot be taken.
	var e := with_bags(r.state, {"p0": [], "p1": [["juice", 1]]})
	r = tick(e, ins2(req(inp("p0", a), &"drop"), req(inp("p1", inside), &"drop")))
	refused = of_type(r.events, "invRefused")
	t.check(refused.size() == 1 and refused[0]["playerId"] == "p0" and refused[0]["why"] == "empty", "an empty hand's drop is refused: %s" % str(refused))
	t.eq(r.state.pickups.size(), 1, "the other's drop lies on the floor")
	var pk: Inventory.Pickup = r.state.pickups[0]
	var away := Move.Body.make(pk.at.x + Inventory.PICKUP_REACH + 0.2, pk.at.z, pk.at.level, pk.at.y)
	r = tick(r.state, ins2(req(inp("p0", away), &"take", pk.id), inp("p1", inside)))
	refused = of_type(r.events, "invRefused")
	t.check(refused.size() == 1 and refused[0]["why"] == "reach" and r.state.pickups.size() == 1, "a take out of reach is refused: %s" % str(refused))
	# Selecting a slot.
	r = tick(r.state, ins2(req(inp("p0", away), &"", null, 2), inp("p1", inside)))
	t.eq(Inventory.bag_of(r.state.bags, "p0").sel, 2, "slot 3 is in the hand")

# ---------------------------------------------------------------------------------------------
# 5. Searching puts a carton into the hand.

func test_a_carton_found_goes_into_a_slot(t: T) -> void:
	_apply_break()
	var ids := _ids(1)
	var s := PropSearch.open_doors(inv_run("carton-slot", ids, true, false, true))
	var ff: Findables.FindFloor = s.find
	var cartons: Array = []
	for p in PropSearch.reachable(ff):
		if ff.fill.contents[p.id]["what"] == "juice":
			cartons.append(p)
	if not t.check(cartons.size() >= 2, "two cartons within reach on this floor: %d" % cartons.size()):
		return
	var sp: Array = PropSearch.stand(cartons[0])
	var hold := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
		return PropSearch.one(PropSearch.inp("p0", sp[0], sp[1], k > 0))
	var out := PropSearch.run_for(s, 2.8, hold)
	var st: Run.RunState = out[0]
	var bag := Inventory.bag_of(st.bags, "p0")
	t.check(bag.item(0) == "juice" and bag.count(0) == 1, "the carton is in slot 1: %s" % str(bag.slots))
	t.check(st.items.is_empty(), "and not in the old carton count")
	# Full hands: the second carton stays in its piece.
	st = with_bags(st, {"p0": [["badge", 1], ["badge", 1], ["badge", 1], ["badge", 1]]})
	var sp2: Array = PropSearch.stand(cartons[1])
	var hold2 := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
		return PropSearch.one(PropSearch.inp("p0", sp2[0], sp2[1], k > 0))
	out = PropSearch.run_for(st, 2.8, hold2)
	var st2: Run.RunState = out[0]
	var full := of_type(out[1], "searchFull")
	t.check(full.size() == 1 and int(full[0]["piece"]) == (cartons[1] as Object).get("id"), "the finder is told their hands are full: %s" % str(full))
	t.eq(of_type(out[1], "searchDone").size(), 0, "no searchDone for a carton left behind")
	t.check(not (st2.find as Findables.FindFloor).opened.has((cartons[1] as Object).get("id")), "the piece stays shut, the carton in it")
	t.eq(Inventory.bag_of(st2.bags, "p0").totals(), {"badge": 4}, "the hands are as they were")

# ---------------------------------------------------------------------------------------------
# 6. The day's end clears everything.

func test_the_days_end_clears_every_bag_and_pickup(t: T) -> void:
	_apply_break()
	var ids := _ids(2)
	var rig := DayRigLib.DayRig.new("inv-day", ids)
	rig.st = Run.with_inventory(rig.st)
	if not t.check(rig.until(func(s: Run.RunState) -> bool: return s.phase == &"away", 60.0), "the crew is out on floor 1"):
		return
	rig.st = with_bags(rig.st, {"p0": [["juice", 1]], "p1": [["badge", 1]]})
	if not t.check(rig.until(func(s: Run.RunState) -> bool: return Run.at_home(s) and s.phase == &"night", 400.0), "home for the night"):
		return
	t.eq(Run.items_in_world(rig.st), {"juice": 1, "badge": 1}, "what was carried came home")
	# Something left lying in the prison too.
	var s := rig.st.copy()
	s.pickups = [Inventory.Pickup.make(99, "juice", 1, s.players[0].body)]
	s.pickups_plan = s.plan
	rig.st = s
	var e := rig.until_event("newDay", 200.0)
	t.check(not e.is_empty(), "the morning came")
	t.eq(Run.items_in_world(rig.st), {}, "in the morning nothing is carried and nothing lies anywhere")

# ---------------------------------------------------------------------------------------------
# 7. Off changes nothing.

func test_off_changes_nothing(t: T) -> void:
	_apply_break()
	var ids := _ids(2)
	t.check(not Run.create_run("off", ids).inventory, "a run made as before has no inventory")
	t.check(not HostRules.new(true, 1, Places.FULL).prepare(Run.create_run("off", ids)).inventory, "HostRules leaves it off unless asked")
	var a := open_doors(inv_run("inv-off", ids, false, true, true))
	var b := a
	var rng := Rng.make_rng("inv-off")
	var same := true
	var off_events := 0
	for k in 200:
		var ia: Array[Run.PlayerInput] = []
		var ib: Array[Run.PlayerInput] = []
		for n in ids.size():
			var body := spot(a, -1.2 - 0.02 * k, -0.6 + 1.2 * n)
			ib.append(inp(ids[n], body))
			var i := inp(ids[n], body)
			req(i, [&"drop", &"take", &"give"][rng.int_in(0, 2)], ids[1 - n] if rng.chance(0.5) else rng.int_in(0, 3), rng.int_in(0, 3))
			ia.append(i)
		var ra := tick(a, ia)
		var rb := tick(b, ib)
		a = ra.state
		b = rb.state
		same = same and JSON.stringify(Protocol.plain(ra.events)) == JSON.stringify(Protocol.plain(rb.events)) \
			and JSON.stringify(Protocol.plain(a.players.map(func(p: Run.RunPlayer) -> String: return "%s %s %s" % [p.id, p.status, str(p.body.x)]))) \
				== JSON.stringify(Protocol.plain(b.players.map(func(p: Run.RunPlayer) -> String: return "%s %s %s" % [p.id, p.status, str(p.body.x)])))
		for e in ra.events:
			if str(e["type"]).begins_with("item") or e["type"] == "invRefused" or e["type"] == "searchFull":
				off_events += 1
	t.check(same, "the same events and players with and without requests")
	t.eq(off_events, 0, "inventory events with it off")
	t.check(not a.inventory and a.bags.is_empty() and a.pickups.is_empty() and a.pickup_seq == 0, "no inventory state with it off")
	# The input: a client that never asks sends the old shapes.
	var m := {"type": "input", "seq": 1, "ct": 0.0, "body": a.players[0].body, "eye": 1.65, "yaw": 0.0, "pitch": 0.0, "hFovDeg": 90.0,
		"vFovDeg": 70.0, "raised": false, "holdDoors": false, "gait": "walk", "seeing": false, "calls": 0, "pickUps": 0, "ackEvent": 0,
		"ackHt": 0.0, "renderTime": 0.0, "placeAck": 0, "seen": []}
	t.eq((JSON.parse_string(Protocol.encode(m)) as Array).size(), 18, "an input without the inventory is as it was")
	m["invSel"] = 2
	m["invs"] = 1
	m["invOp"] = "give"
	m["invArg"] = "p1"
	var dm: Dictionary = Protocol.decode(Protocol.encode(m))
	t.check(dm != null and dm["invSel"] == 2 and dm["invs"] == 1 and dm["invOp"] == "give" and dm["invArg"] == "p1" and not dm.has("hides"), "an input with a request round-trips: %s" % str(dm))

# ---------------------------------------------------------------------------------------------
# 8. The item table.

func test_the_item_table_names_the_rules_items(t: T) -> void:
	var rows: Array = Inventory.data().get("items", [])
	var ids: Array[String] = []
	for r: Dictionary in rows:
		ids.append(str(r["id"]))
		t.check(r.has("name") and r.has("short") and r.has("usable") and r["usable"] is bool, "%s has a name, a short name and usable" % r.get("id"))
	t.eq(ids, Inventory.ITEMS, "data/items.json lists the rules' items, in order")
	t.eq(Inventory.short_name("juice"), "JUICE", "the carton's square says JUICE")
	t.eq(Inventory.long_name("badge"), "AN OLD CREW BADGE", "the badge's name")
	t.check(Findables.JUICE == &"juice", "a found carton is the item juice")
