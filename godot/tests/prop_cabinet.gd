# The cabinet in each cell (S2b, tracker T29; docs/floors/skill-tree.md section 2b; sim/shop.gd, sim/run.gd shop). Proved:
#   1. the cabinet's slots fill as the inventory's do (a stack with room first, then the first empty slot) and never
#      past the open slots (cabinet.slots) or the stack limit;
#   2. at home a player standing at their own cabinet puts a slot in and takes it out again; at a crewmate's cabinet,
#      or away from it, both are refused for reach; a full cabinet refuses; nothing is ever made or lost (every bag,
#      pickup and cabinet counted);
#   3. the night: what is in a cabinet when the lights go out is there in the morning; everything carried, or left
#      lying, is gone; the crew wakes on their bunks; what a player takes out in the morning rides down with them;
#   4. the stamped save carries a cabinet and gives it back (net/save_slip.gd), and a save without one opens as
#      before; a bad cabinet text is refused;
#   5. with the flag off nothing changes: no shop state, the requests are refused as unknown, no world block, and the
#      morning comes LIGHTS_OUT_SECONDS after lights out in the car, as before.
# Breaks (PROP_SHOP_BREAK, sim/shop.gd test_break): "keep" (everything is kept overnight: 3 red).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Shop = preload("res://sim/shop.gd")
const Inventory = preload("res://sim/inventory.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Day = preload("res://sim/day.gd")
const Prison = preload("res://sim/prison.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const SaveSlip = preload("res://net/save_slip.gd")
const DayRigLib = preload("res://tests/day_rig.gd")

const DT := 0.05

static func apply_break() -> void:
	var b := OS.get_environment("PROP_SHOP_BREAK")
	Shop.test_break = b if b in ["free", "keep", "two_flash", "far_salts"] else ""

static func ids_of(n: int) -> Array[String]:
	var out: Array[String] = []
	for k in n:
		out.append("p%d" % k)
	return out

## A crew of `ids` home in the prison after day 1 (days, the inventory, and the shop as asked), the doors open.
static func home_run(seed: String, ids: Array[String], shop: bool = true) -> Run.RunState:
	var rig := DayRigLib.DayRig.new(seed, ids)
	rig.st = Run.with_inventory(rig.st)
	if shop:
		rig.st = Run.with_shop(rig.st)
	rig.until_event("rodeUp", 300.0)
	rig.until(func(s: Run.RunState) -> bool: return s.phase != &"arriving", 10.0)
	return rig.st

## The body standing on cell (x, y) of the prison.
static func at_cell(s: Run.RunState, c: Vector2i) -> Move.Body:
	return Move.body_at_cell(s.plan, Floor.Pos.make(0, c.x, c.y))

static func cab_body(s: Run.RunState, ids: Array[String], id: String) -> Move.Body:
	return at_cell(s, Shop.cabinet_cell(ids, id))

static func inp(id: String, body: Move.Body) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, 0.0, 0.0, 90.0, 70.0)

static func req(i: Run.PlayerInput, op: StringName, arg: Variant = null) -> Run.PlayerInput:
	i.inv_op = op
	i.inv_arg = arg
	return i

## One tick: `bodies` {id: body}, `asks` {id: [op, arg]}, F held by `use` {id: true}.
static func tick(s: Run.RunState, bodies: Dictionary, asks: Dictionary = {}, use: Dictionary = {}) -> Run.RunStep:
	var ins: Array[Run.PlayerInput] = []
	for p in s.players:
		var i := inp(p.id, bodies.get(p.id, p.body))
		if asks.has(p.id):
			i = req(i, StringName(asks[p.id][0]), asks[p.id][1])
		i.use = bool(use.get(p.id, false))
		ins.append(i)
	return Run.step_run(s, ins, DT)

## A copy of the run with these bags ({id: [[item, count], ...]}).
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

static func of_type(events: Array, ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in events:
		if str(e.get("type")) == ty:
			out.append(e)
	return out

## Everyone to their bunk holding F until the morning in the cells begins ("wokeUp", the shop on) or the day starts
## ("newDay", off). Returns [state, events of the whole stretch].
static func sleep_all(s0: Run.RunState, until_type: String) -> Array:
	var s := s0
	var ids: Array[String] = []
	for p in s.players:
		ids.append(p.id)
	var all: Array = []
	for _k in 1200:
		var bodies := {}
		var use := {}
		for id in ids:
			bodies[id] = Run.bunk_body(s.plan, ids, id)
			use[id] = true
		var r := tick(s, bodies, {}, use)
		s = r.state
		all.append_array(r.events)
		if not of_type(r.events, until_type).is_empty():
			break
	return [s, all]

# ---------------------------------------------------------------------------------------------
# 1. The cabinet's slots.

func test_slots_fill_like_the_inventory(t: T) -> void:
	var c := Shop.empty_cabinet()
	t.eq(c.size(), Shop.CAB_MAX, "the wire's cabinet has CAB_MAX slots")
	for item: String in ["glow", "salts", "toy", "flash", "marker", "speed"]:
		var r := Shop.cab_put(c, Shop.CAB_SLOTS, item, 1, 1)
		t.eq(int(r[1]), 1, "%s goes in" % item)
		c = r[0]
	var seventh := Shop.cab_put(c, Shop.CAB_SLOTS, "juice", 1, 1)
	t.check(int(seventh[1]) == 0 and seventh[0] == c, "a seventh item is refused with six slots open, and changes nothing")
	var eight := Shop.cab_put(c, 8, "juice", 1, 1)
	t.eq(int(eight[1]), 1, "with eight open it goes into slot 7")
	var d := Shop.empty_cabinet()
	d[2] = ["glow", 1]
	var r2 := Shop.cab_put(d, 6, "glow", 4, 3)
	t.eq([r2[0][0], r2[0][1], r2[0][2]], [["glow", 2], ["", 0], ["glow", 3]], "a stack of three: slot 3's stack fills first, then slot 1")
	t.eq(int(r2[1]), 4, "all four went in: two topped slot 3 up to three, two into slot 1")
	t.eq(Shop.cab_slots(null), 6, "six slots unless the host says")
	t.eq(Shop.cab_slots(Settings.make({&"cabinet.slots": 4.0})), 4, "the host's four")
	t.eq(Shop.cab_slots(Settings.make({&"cabinet.slots": 8.0})), 8, "the host's eight")

# ---------------------------------------------------------------------------------------------
# 2. Putting in and taking out, at home.

func test_put_in_and_take_out_at_your_own_cabinet(t: T) -> void:
	apply_break()
	var ids := ids_of(2)
	var s := home_run("cab-home", ids)
	if not t.check(Run.at_home(s) and s.shop, "the crew is home with the shop on (phase %s)" % s.phase):
		return
	s = with_bags(s, {"p0": [["glow", 1], ["badge", 1]], "p1": [["salts", 1]]})
	var before := Run.items_with_cabinets(s)
	var mine := cab_body(s, ids, "p0")
	var theirs := cab_body(s, ids, "p1")
	t.check(Shop.cabinet_cell(ids, "p0") != Shop.cabinet_cell(ids, "p1"), "two cells, two cabinets")
	# At someone else's cabinet, and away from any: refused for reach.
	var r := tick(s, {"p0": theirs}, {"p0": ["stash", 0]})
	var ref := of_type(r.events, "invRefused")
	t.check(ref.size() == 1 and str(ref[0]["why"]) == "reach", "at a crewmate's cabinet: refused for reach (%s)" % str(ref))
	t.eq(Shop.cabinet_of((r.state.shop_state as Shop.ShopState).cabinets, "p1"), Shop.empty_cabinet(), "their cabinet is untouched")
	r = tick(s, {"p0": Run.bunk_body(s.plan, ids, "p0")}, {"p0": ["stash", 0]})
	t.eq(of_type(r.events, "invRefused").size(), 1, "on the bunk, not at the cabinet: refused")
	# At your own: in it goes, and out again.
	r = tick(s, {"p0": mine}, {"p0": ["stash", 0]})
	var cab := Shop.cabinet_of((r.state.shop_state as Shop.ShopState).cabinets, "p0")
	t.eq(cab[0], ["glow", 1], "the glow stick is in the cabinet's slot 1")
	t.eq(Inventory.bag_of(r.state.bags, "p0").count(0), 0, "and out of the hand")
	t.eq(of_type(r.events, "stashed").size(), 1, "stashed is said")
	t.eq(Run.items_with_cabinets(r.state), before, "nothing made or lost putting it in")
	var r2 := tick(r.state, {"p0": mine}, {"p0": ["fetch", 0]})
	t.eq(Inventory.bag_of(r2.state.bags, "p0").slots[0], ["glow", 1], "taken out: back in slot 1")
	t.eq(Shop.cabinet_of((r2.state.shop_state as Shop.ShopState).cabinets, "p0")[0], ["", 0], "the cabinet's slot is empty")
	t.eq(Run.items_with_cabinets(r2.state), before, "nothing made or lost taking it out")
	# Empty slots refuse; a full cabinet refuses; full hands refuse a take.
	var r3 := tick(r2.state, {"p0": mine}, {"p0": ["fetch", 3]})
	t.eq(str(of_type(r3.events, "invRefused")[0]["why"]) if not of_type(r3.events, "invRefused").is_empty() else "", "empty", "an empty cabinet slot: refused")
	var full := Shop.empty_cabinet()
	for k in Shop.CAB_SLOTS:
		full[k] = ["toy", 1]
	var sf := Run.with_cabinet(r2.state, "p0", full)
	var r4 := tick(sf, {"p0": mine}, {"p0": ["stash", 1]})
	var w4 := of_type(r4.events, "invRefused")
	t.check(w4.size() == 1 and str(w4[0]["why"]) == "cabFull", "six full slots: the cabinet is full (%s)" % str(w4))
	t.eq(Run.items_with_cabinets(r4.state), Run.items_with_cabinets(sf), "a refusal changes nothing")
	var s4 := Run.with_tuning(sf, {&"cabinet.slots": 8.0})
	var r5 := tick(s4, {"p0": mine}, {"p0": ["stash", 1]})
	t.eq(Shop.cabinet_of((r5.state.shop_state as Shop.ShopState).cabinets, "p0")[6], ["badge", 1], "with cabinet.slots 8 the badge goes into slot 7")
	var hands := with_bags(sf, {"p0": [["juice", 1], ["juice", 1], ["juice", 1], ["juice", 1]]})
	var r6 := tick(hands, {"p0": mine}, {"p0": ["fetch", 0]})
	var w6 := of_type(r6.events, "invRefused")
	t.check(w6.size() == 1 and str(w6[0]["why"]) == "full", "full hands: the take is refused (%s)" % str(w6))

# ---------------------------------------------------------------------------------------------
# 3. The night.

func test_only_the_cabinet_is_kept_overnight(t: T) -> void:
	apply_break()
	var ids := ids_of(2)
	var s := home_run("cab-night", ids)
	if not t.check(Run.at_home(s), "home"):
		return
	s = with_bags(s, {"p0": [["speed", 1], ["glow", 1]], "p1": [["marker", 1]]})
	var r := tick(s, {"p0": cab_body(s, ids, "p0")}, {"p0": ["stash", 0]})
	s = r.state
	# p1 drops the marker on the cell block floor: left lying.
	r = tick(s, {}, {"p1": ["drop", 0]})
	s = r.state
	t.eq(s.pickups.size(), 1, "the marker lies on the floor")
	var res := sleep_all(s, "wokeUp")
	s = res[0]
	var woke := of_type(res[1], "wokeUp")
	if not t.check(woke.size() == 1, "the crew woke in the cells"):
		return
	t.check(of_type(res[1], "newDay").is_empty() and Run.at_home(s), "still in the prison as they wake (no morning in the car yet)")
	var lo := of_type(res[1], "lightsOut")
	t.check(not lo.is_empty() and absf(float(woke[0]["t"]) - float(lo[0]["t"]) - Day.LIGHTS_OUT_SECONDS) <= DT + 1e-6, "they wake LIGHTS_OUT_SECONDS after lights out")
	for p in s.players:
		t.eq(Vector2i(Move.cell_of(s.plan, p.body).x, Move.cell_of(s.plan, p.body).y), Day.bunk_of(ids, p.id), "%s wakes on their own bunk" % p.id)
	t.eq(Shop.cabinet_of((s.shop_state as Shop.ShopState).cabinets, "p0")[0], ["speed", 1], "the speed juice in the cabinet is still there")
	t.check(Inventory.bag_of(s.bags, "p0").is_empty() and Inventory.bag_of(s.bags, "p1").is_empty(), "everything carried is gone: p0 %s, p1 %s" % [str(Inventory.bag_of(s.bags, "p0").slots), str(Inventory.bag_of(s.bags, "p1").slots)])
	t.eq(s.pickups.size(), 0, "what was left lying is gone")
	t.eq(Run.items_with_cabinets(s), {"speed": 1}, "the world holds only what was in a cabinet")
	t.check(not Day.is_lights_out(Day.BedState.make(ids), 0.0) and s.bed == null and s.lights_out_t < 0.0, "the lights are on and nobody is in bed")
	# The morning: take it out, and it goes down.
	r = tick(s, {"p0": cab_body(s, ids, "p0")}, {"p0": ["fetch", 0]})
	s = r.state
	t.eq(Inventory.bag_of(s.bags, "p0").slots[0], ["speed", 1], "taken out in the morning")
	var day := -1
	var newday: Dictionary = {}
	for _k in roundi((Shop.WAKE_SECONDS + 1.0) / DT):
		var rr := tick(s, {"p0": cab_body(s, ids, "p0")})
		s = rr.state
		var nd := of_type(rr.events, "newDay")
		if not nd.is_empty():
			newday = nd[0]
			break
	if not t.check(not newday.is_empty(), "the car took the crew down"):
		return
	t.check(absf(float(newday["t"]) - float(woke[0]["t"]) - Shop.WAKE_SECONDS) <= DT + 1e-6, "WAKE_SECONDS after waking")
	day = s.day_index
	t.eq([s.depth, day], [1, 2], "floor 1, day 2")
	t.eq(Inventory.bag_of(s.bags, "p0").slots[0], ["speed", 1], "the speed juice rode down in p0's hand")
	t.eq(Shop.cabinet_of((s.shop_state as Shop.ShopState).cabinets, "p0"), Shop.empty_cabinet(), "and is out of the cabinet")

# ---------------------------------------------------------------------------------------------
# 4. The stamped save.

func test_the_stamped_save_keeps_the_cabinet(t: T) -> void:
	var key := PackedByteArray()
	for k in 32:
		key.append((k * 37 + 11) % 256)
	var cab := Shop.empty_cabinet()
	cab[0] = ["speed", 1]
	cab[3] = ["glow", 2]
	cab[7] = ["badge", 1]
	var text := Shop.cabinet_text(cab)
	t.eq(text, "speed:1,0,0,glow:2,0,0,0,badge:1", "the cabinet's text")
	t.eq(Shop.cabinet_from_text(text), cab, "read back exactly")
	var fields := SaveSlip.fresh("0123456789abcdef")
	fields["cabinet"] = text
	var sealed := SaveSlip.seal(fields, key)
	t.check(sealed != "", "a save with a cabinet seals")
	var o := SaveSlip.open(sealed, key)
	t.check(bool(o["ok"]), "and opens (%s)" % str(o["reason"]))
	t.eq(Shop.cabinet_from_text(str((o["fields"] as Dictionary).get("cabinet", ""))), cab, "the cabinet comes back from the save")
	# Into a run, as a join would put it.
	var ids := ids_of(1)
	var rules := HostRules.new(false, 1, Places.FULL, true, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true)
	var s := Run.with_cabinet(rules.prepare(Run.create_run("cab-save", ids)), "p0", Shop.cabinet_from_text(str(o["fields"]["cabinet"])))
	t.eq(Shop.cabinet_text(Shop.cabinet_of((s.shop_state as Shop.ShopState).cabinets, "p0")), text, "the run holds the saved cabinet")
	# Without one, a save opens as before; with a changed cabinet, the stamp refuses it.
	var plain := SaveSlip.seal(SaveSlip.fresh("0123456789abcdef"), key)
	t.check(bool(SaveSlip.open(plain, key)["ok"]) and not (SaveSlip.open(plain, key)["fields"] as Dictionary).has("cabinet"), "a save without a cabinet opens as before")
	t.eq(str(SaveSlip.open(sealed.replace("glow:2", "glow:9"), key)["reason"]), "stamp", "a cabinet changed by hand is refused by the stamp")
	var bad := SaveSlip.fresh("0123456789abcdef")
	bad["cabinet"] = "gold:1,0,0,0,0,0,0,0"
	t.eq(SaveSlip.check(bad), "cabinet", "an item the rules do not know is not a cabinet")
	t.eq(Shop.cabinet_from_text("speed:1,0"), [], "the wrong number of slots is not a cabinet")

# ---------------------------------------------------------------------------------------------
# 5. The flag off.

func test_flag_off_changes_nothing(t: T) -> void:
	var ids := ids_of(2)
	var s := home_run("cab-off", ids, false)
	t.check(not s.shop and s.shop_state == null, "no shop state")
	s = with_bags(s, {"p0": [["glow", 1]]})
	var r := tick(s, {"p0": cab_body(s, ids, "p0")}, {"p0": ["stash", 0]})
	var w := of_type(r.events, "invRefused")
	t.check(w.size() == 1 and str(w[0]["why"]) == "op", "a cabinet request is not a request at all (%s)" % str(w))
	t.eq(Inventory.bag_of(r.state.bags, "p0").slots[0], ["glow", 1], "and the item stays in the hand")
	t.check(r.state.shop_state == null and of_type(r.events, "stashed").is_empty(), "no cabinet appears")
	var res := sleep_all(r.state, "newDay")
	t.check(of_type(res[1], "wokeUp").is_empty() and not of_type(res[1], "newDay").is_empty(), "the morning comes in the car, as before, with no waking in the cells")
	var lo := of_type(res[1], "lightsOut")
	var nd := of_type(res[1], "newDay")
	t.check(not lo.is_empty() and not nd.is_empty() and absf(float(nd[0]["t"]) - float(lo[0]["t"]) - Day.LIGHTS_OUT_SECONDS) <= DT + 1e-6, "LIGHTS_OUT_SECONDS after lights out")
	t.check(Inventory.bag_of((res[0] as Run.RunState).bags, "p0").is_empty(), "the morning cleared the hands as before")
	# The host's world: no shop block; with it, one.
	var on_rules := HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true)
	var off_rules := HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, false)
	t.check(on_rules.prepare(Run.create_run("cab-w", ids)).shop, "the flag on: the run has the shop")
	t.check(not off_rules.prepare(Run.create_run("cab-w", ids)).shop, "the flag off: it has not")
	var no_inv := HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)
	t.check(not no_inv.prepare(Run.create_run("cab-w", ids)).shop, "the shop needs the inventory")
