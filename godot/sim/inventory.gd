# The four-slot inventory (North Star C7, Draft 6; docs/floors/skill-tree.md sections 1 and 6, S1; tracker T21a).
# Pure rules: no drawing, no network. sim/run.gd keeps one Bag per player and the floor's pickups, and steps them
# (run flag `inventory`, Run.with_inventory); net/host.gd sends them; client/inventory_view.gd draws them.
#
# The owner, 17 Nov: "Scroll 1/2/3/4 and just four slots in squares at bottom of screen is fine, with selector
# identifying what's in the hand. Instrument is always in the other hand, so it never counts as a slot. Things
# bought from the store can count as a slot."
#
#   - Every player has SLOTS slots. A slot holds one item id and a count, or nothing.
#   - The stack limit is a number per player, STACK (1) unless the host's live setting `inv.stack` says more.
#     Deep Pockets (a later skill: "The same item stacks three to a slot") changes stack_limit, one line.
#   - add: first tops up a slot holding the same item with room, then the first empty slot. Nothing fits: refused.
#   - Drop puts the selected slot (all of it) at the player's feet as one floor pickup. Taking a pickup puts as much
#     of it as fits into the bag; anything that does not fit stays on the floor. Handing over gives the selected
#     slot to a crewmate within hand_reach as far as their bag has room; the rest stays in the giver's hand.
#   - A player who goes down (or is caught, out, left behind: anything but on their feet) drops everything where
#     they are (B6: "what they carry falls where they fall").
#   - The floor's pickups go when the crew leaves the floor; the morning clears every bag and every pickup ("Only
#     items in your cabinet when you sleep ... are kept; everything else is cleared overnight": the cabinet is S2b).
# Nothing is ever made or lost by these operations: tests/prop_inventory.gd counts every item in the world.
extends RefCounted

const Move = preload("res://sim/move.gd")
const Settings = preload("res://sim/settings.gd")
const M = preload("res://sim/jsmath.gd")

## Four squares. The instrument is in the other hand and is never a slot.
const SLOTS := 4
## A slot holds one item unless the host (or, later, Deep Pockets) says more.
const STACK := 1
## Taking a pickup: the player's feet within this of it (metres; as a dropped tape, Instr.PICKUP_REACH).
const PICKUP_REACH := 1.3
## Handing over: the giver's feet within this of the crewmate's (metres; as a heal, Run.HEAL_REACH).
const HAND_REACH := 1.5
## The item ids the rules know, in wire order (net/protocol.gd sends the index). data/items.json names them and
## says which can be used; tests/prop_inventory.gd checks the two agree.
## The shop's six (sim/shop.gd ITEMS, S2) follow the two found ones.
const ITEMS: Array[String] = ["juice", "badge", "marker", "glow", "flash", "speed", "toy", "salts", "pinecone"]
const DATA_PATH := "res://data/items.json"
const EPS := 1e-9

## The tests' deliberate breaks (tests/prop_inventory.gd; PROP_INVENTORY_BREAK): "stack" lets a stack reach its
## limit + 1; "no_clear" skips the morning's clear; "any_reach" lets a hand-over succeed from any distance;
## "dup_drop" leaves the dropped item in the hand as well.
static var test_break := ""

## One player's four slots and which is in the hand. Replaced, never edited, once in a RunState (copy() first).
class Bag:
	## SLOTS entries, each [item id ("" for empty), count].
	var slots: Array = []
	## The selected slot, 0 to SLOTS - 1.
	var sel := 0

	static func empty() -> Bag:
		var b := Bag.new()
		for _k in SLOTS:
			b.slots.append(["", 0])
		return b

	func copy() -> Bag:
		var b := Bag.new()
		for s: Array in slots:
			b.slots.append([s[0], s[1]])
		b.sel = sel
		return b

	func item(k: int) -> String:
		return str(slots[k][0])

	func count(k: int) -> int:
		return int(slots[k][1])

	func is_empty() -> bool:
		for s: Array in slots:
			if int(s[1]) > 0:
				return false
		return true

	## Every item carried, counted: {item: count}.
	func totals() -> Dictionary:
		var out := {}
		for s: Array in slots:
			if int(s[1]) > 0:
				out[s[0]] = int(out.get(s[0], 0)) + int(s[1])
		return out

## An item lying on the floor where it was dropped.
class Pickup:
	var id := 0
	var item := ""
	var count := 0
	var at: Move.Body

	static func make(id_: int, item_: String, count_: int, at_: Move.Body) -> Pickup:
		var p := Pickup.new()
		p.id = id_
		p.item = item_
		p.count = count_
		p.at = at_
		return p

	func copy() -> Pickup:
		return Pickup.make(id, item, count, at)

## What add() did: the bag after, how many went in and how many did not.
class Added:
	var bag: Bag
	var added := 0
	var left := 0

# ---------------------------------------------------------------------------------------------
# The numbers.

## How many of one item a slot of this player's holds. Deep Pockets (S4) is this line.
static func stack_limit(tuning: Settings.Values, _player_id: String) -> int:
	return maxi(1, Settings.i(tuning, &"inv.stack", STACK))

## How near a crewmate must be to be handed something (metres).
static func hand_reach(tuning: Settings.Values) -> float:
	var r := Settings.f(tuning, &"inv.hand_reach", HAND_REACH)
	return INF if test_break == "any_reach" else r

## The most a slot may hold under `limit` (the deliberate break lets one more in).
static func _cap(limit: int) -> int:
	return limit + 1 if test_break == "stack" else limit

# ---------------------------------------------------------------------------------------------
# The operations. None edits what it is given.

## Puts up to `n` of `item` into the bag: a slot with the same item and room first, then the first empty slot.
static func add(bag: Bag, item: String, n: int, limit: int) -> Added:
	var r := Added.new()
	var b := bag.copy()
	var left := n
	var cap := _cap(limit)
	for k in SLOTS:
		if left <= 0:
			break
		if b.item(k) == item and b.count(k) > 0 and b.count(k) < cap:
			var put := mini(left, cap - b.count(k))
			b.slots[k][1] = b.count(k) + put
			left -= put
	for k in SLOTS:
		if left <= 0:
			break
		if b.count(k) <= 0:
			var put := mini(left, cap)
			b.slots[k] = [item, put]
			left -= put
	r.bag = b
	r.added = n - left
	r.left = left
	return r

## Whether at least one of `item` fits.
static func has_room(bag: Bag, item: String, limit: int) -> bool:
	return add(bag, item, 1, limit).added > 0

## The bag with one taken from slot `k` (unchanged if it is empty).
static func remove_one(bag: Bag, k: int) -> Bag:
	var b := bag.copy()
	if k < 0 or k >= SLOTS or b.count(k) <= 0:
		return b
	var n := b.count(k) - 1
	b.slots[k] = [b.item(k) if n > 0 else "", n]
	return b

## The bag with slot `k` emptied.
static func clear_slot(bag: Bag, k: int) -> Bag:
	var b := bag.copy()
	b.slots[k] = ["", 0]
	return b

## The bag with slot `k` (0 to SLOTS - 1) in the hand; out of range changes nothing.
static func select(bag: Bag, k: int) -> Bag:
	var b := bag.copy()
	if k >= 0 and k < SLOTS:
		b.sel = k
	return b

## The scroll wheel: the next slot (+1) or the one before (-1), round the four.
static func step_sel(bag: Bag, d: int) -> Bag:
	return select(bag, posmod(bag.sel + d, SLOTS))

## Whether a body's feet are within `reach` of a point on the same level.
static func within(a: Move.Body, b: Move.Body, reach: float) -> bool:
	return a != null and b != null and a.level == b.level and M.hypot3(a.x - b.x, a.y - b.y, a.z - b.z) <= reach + EPS

## The bag of `id` in `bags` ({id: Bag}), or an empty one.
static func bag_of(bags: Dictionary, id: String) -> Bag:
	var b: Bag = bags.get(id)
	return b if b != null else Bag.empty()

## Every item in the world: in every bag and on the floor. {item: count}.
static func world_totals(bags: Dictionary, pickups: Array) -> Dictionary:
	var out := {}
	for id: String in bags:
		var t: Dictionary = (bags[id] as Bag).totals()
		for item: String in t:
			out[item] = int(out.get(item, 0)) + int(t[item])
	for p: Pickup in pickups:
		out[p.item] = int(out.get(p.item, 0)) + p.count
	return out

# ---------------------------------------------------------------------------------------------
# The item table (data/items.json): names for the screens, and whether an item can be used.

static var _data: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if parsed is Dictionary:
			_data = parsed
		else:
			push_error("items.json did not parse")
	return _data

## The row of an item id, or {}.
static func item_row(id: String) -> Dictionary:
	for e: Dictionary in data().get("items", []):
		if str(e.get("id", "")) == id:
			return e
	return {}

## What the squares print for an item ("JUICE"), or the id in capitals.
static func short_name(id: String) -> String:
	return str(item_row(id).get("short", id.to_upper()))

## The item's name in a sentence ("A CARTON OF JUICE").
static func long_name(id: String) -> String:
	return str(item_row(id).get("name", id.to_upper()))
