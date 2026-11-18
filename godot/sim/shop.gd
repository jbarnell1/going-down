# The shop and the cabinet (North Star F1 and G1, V44 and V47; docs/floors/skill-tree.md sections 1, 2b and 5;
# tracker T28 and T29). Pure rules: no drawing, no network. sim/run.gd keeps one ShopState in the run (run flag
# `shop`, Run.with_shop) and steps it; net/host.gd sends it; client/shop_view.gd and client/cabinet_view.gd draw it.
#
# The owner, 18 Nov: "Things like flashlights, speed juice, etc can be bought at shop for temp boost." "Only items
# stored in the cabinet before sleeping and or shutting off the game for awhile are saved. Everything else gets
# repaved overnight so clutter can't accumulate."
#
#   - Six items, sold at the prison's shop windows (Prison.SHOP_WINDOWS, 1 and 2) for credits from the buyer's own
#     wallet (the same Upgrades.UpgradeState the bank pays a share into). A price is a host setting,
#     shop.price.<item>, in credits; the game's price is the design's share of a made day's pay (SHARE credits).
#     Buying puts the item into the buyer's hands (sim/inventory.gd): refused with full hands, or without the money.
#   - One cabinet per cell, beside the bunk (cabinet_cell). Its own player opens it standing there. cabinet.slots
#     slots (6, 4 to 8; the wire always carries MAX_SLOTS), the inventory's stack rule. What is in it survives the
#     night; everything else is cleared (sim/run.gd, the morning).
#   - Using the item in the hand: each item's effect is stepped by sim/run.gd; this file holds the numbers and the
#     state (glow sticks lying lit, wind-up toys, the juice and the flash timers, the marker's own marks).
# Nothing is ever made or lost by buying: a purchase moves exactly its price out of the wallet (tests/prop_shop.gd).
extends RefCounted

const Inventory = preload("res://sim/inventory.gd")
const Settings = preload("res://sim/settings.gd")
const Prison = preload("res://sim/prison.gd")
const Day = preload("res://sim/day.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const M = preload("res://sim/jsmath.gd")

## The requests the shop's step answers (they come as the inventory's: PlayerInput.inv_op; net/protocol.gd INV_OPS).
const OPS: Array[String] = ["stash", "fetch", "buy", "use"]
## The shop's items, cheapest first, in the shop card's order. The ids are also in Inventory.ITEMS.
const ITEMS: Array[String] = ["marker", "glow", "flash", "speed", "toy", "salts"]
## What one share is in credits: a made day's pay for one player on day 1 (Day 1 owes 1.5 floor-1 quotas of
## Run.QUOTA_PER_PLAYER = 400 each: 600). The design prices items in shares (skill-tree.md section 5).
const SHARE := 600
## The design's prices, in shares (skill-tree.md section 5).
const SHARES := {"marker": 0.10, "glow": 0.15, "flash": 0.20, "speed": 0.25, "toy": 0.25, "salts": 0.30}

## The cabinet: six slots unless the host says 4 to 8; the wire always carries MAX_SLOTS.
const CAB_SLOTS := 6
const CAB_MIN := 4
const CAB_MAX := 8

## The items' numbers (skill-tree.md section 5).
const JUICE_SECONDS := 8.0
const GLOW_SECONDS := 180.0
const FLASH_SECONDS := 1.0
## Your own screen is white this long after a flash (a client concern, exported for it).
const FLASH_WHITE_SECONDS := 2.0
const TOY_WAIT := 3.0
const TOY_RATTLE := 6.0
## How far the toy's rattle carries (the host event `noise`; as a mark's slap, Marks.NOISE_RADIUS).
const TOY_RADIUS := 8.0
## Smelling salts: facing the downed crewmate within this many degrees of where you look (as a hand-over).
const SALTS_FACE_DEG := 50.0
## The morning in the cells (shop on): this long on your bunk, lights on, before the car takes the crew down.
const WAKE_SECONDS := 15.0

## The tests' deliberate breaks (tests/prop_shop.gd, tests/prop_cabinet.gd; PROP_SHOP_BREAK): "free" lets a purchase
## through without taking the money; "keep" keeps everything overnight, not only the cabinet; "two_flash" counts a
## flash as two watchers; "far_salts" lets salts work from any distance.
static var test_break := ""

## The shop's state in a run. Replaced, never edited, once in a RunState (copy() first).
class ShopState:
	## Each player's cabinet {id: Array of CAB_MAX [item, count]}.
	var cabinets: Dictionary = {}
	## Glow sticks lit on this floor: {id, at (a body), until, by}.
	var glows: Array = []
	## Wind-up toys set on this floor: {id, at, start (the rattle's), end, by}.
	var toys: Array = []
	## The plan the glows and the toys lie on (they go with the floor).
	var plan: Variant = null
	## Speed juice and the flash: {id: host time it ends}.
	var juiced: Dictionary = {}
	## {id: host time it ends}.
	var flashes: Dictionary = {}
	## Marks placed with a bought marker (the Annex): {mark id: true}. Peeling one never adds to the crew's pad.
	var own_marks: Dictionary = {}
	## The next glow or toy id.
	var seq: int = 0
	## The morning in the cells: the host time the car takes the crew down, or -1.
	var wake_until: float = -1.0

	func copy() -> ShopState:
		var s := ShopState.new()
		s.cabinets = cabinets
		s.glows = glows
		s.toys = toys
		s.plan = plan
		s.juiced = juiced
		s.flashes = flashes
		s.own_marks = own_marks
		s.seq = seq
		s.wake_until = wake_until
		return s

# ---------------------------------------------------------------------------------------------
# Prices.

## The game's price of an item in credits (the design's shares of SHARE).
static func base_price(item: String) -> int:
	return roundi(float(SHARES.get(item, 0.0)) * SHARE)

## The setting that prices an item.
static func price_id(item: String) -> StringName:
	return StringName("shop.price.%s" % item)

## What an item costs now, in credits: the host's setting, else the game's price.
static func price(tuning: Settings.Values, item: String) -> int:
	return maxi(0, Settings.i(tuning, price_id(item), base_price(item)))

# ---------------------------------------------------------------------------------------------
# The cabinet.

## How many of the cabinet's slots are open (cabinet.slots, clamped to 4 to 8).
static func cab_slots(tuning: Settings.Values) -> int:
	return clampi(Settings.i(tuning, &"cabinet.slots", CAB_SLOTS), CAB_MIN, CAB_MAX)

static func empty_cabinet() -> Array:
	var out: Array = []
	for _k in CAB_MAX:
		out.append(["", 0])
	return out

## The cabinet of `id` in `cabinets`, or an empty one.
static func cabinet_of(cabinets: Dictionary, id: String) -> Array:
	var c: Variant = cabinets.get(id)
	return c if c is Array else empty_cabinet()

## Puts up to `n` of `item` into the cabinet's first `open` slots: a slot with the same item and room first, then
## the first empty one (Inventory.add's rule). Returns [cabinet after, how many went in].
static func cab_put(cab: Array, open: int, item: String, n: int, limit: int) -> Array:
	var c := cab.duplicate(true)
	var left := n
	for k in open:
		if left <= 0:
			break
		if str(c[k][0]) == item and int(c[k][1]) > 0 and int(c[k][1]) < limit:
			var put := mini(left, limit - int(c[k][1]))
			c[k] = [item, int(c[k][1]) + put]
			left -= put
	for k in open:
		if left <= 0:
			break
		if int(c[k][1]) <= 0:
			var put := mini(left, limit)
			c[k] = [item, put]
			left -= put
	return [c, n - left]

## The cell of the cabinet of player `id`: beside their bunk, in the other column of their cell (Day.bunk_of over
## the run's players; the bunk stands in the door's column).
static func cabinet_cell(crew: Array[String], id: String) -> Vector2i:
	var b := Day.bunk_of(crew, id)
	if b.x < 0:
		return b
	return Vector2i(b.x + 1, b.y)

## Every cabinet's cell, in bunk order 1..8 (the look draws one in each cell).
static func cabinet_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for b in Prison.bunk_positions():
		out.append(Vector2i(b.x + 1, b.y))
	return out

## Whether a body stands at player `id`'s own cabinet in the prison.
static func at_cabinet(plan: Floor.FloorPlan, crew: Array[String], id: String, body: Move.Body) -> bool:
	if plan == null or plan.place != Prison.PLACE or body == null or body.level != 0:
		return false
	var c := Move.cell_of(plan, body)
	return Vector2i(c.x, c.y) == cabinet_cell(crew, id)

## Whether a body stands at a shop window (Prison.SHOP_WINDOWS) in the prison.
static func at_shop(plan: Floor.FloorPlan, body: Move.Body) -> bool:
	if plan == null or plan.place != Prison.PLACE or body == null or body.level != 0:
		return false
	var c := Move.cell_of(plan, body)
	return Prison.station_at(Vector2i(c.x, c.y)) == &"shop"

## Every item in every cabinet: {item: count}.
static func cabinet_totals(cabinets: Dictionary) -> Dictionary:
	var out := {}
	for id: String in cabinets:
		for s: Array in cabinets[id]:
			if int(s[1]) > 0:
				out[s[0]] = int(out.get(s[0], 0)) + int(s[1])
	return out

# ---------------------------------------------------------------------------------------------
# The stamped save (net/save_slip.gd): a cabinet as one short text, "item:count" or "0" a slot, comma-separated,
# CAB_MAX slots. Only [a-z0-9_:,] (an item id is lowercase letters).

static func cabinet_text(cab: Array) -> String:
	var parts: Array[String] = []
	for k in CAB_MAX:
		var s: Array = cab[k] if k < cab.size() else ["", 0]
		parts.append("%s:%d" % [s[0], int(s[1])] if int(s[1]) > 0 and str(s[0]) != "" else "0")
	return ",".join(parts)

## A cabinet from its text, or [] when the text is not one (an unknown item, a count out of range, the wrong size).
static func cabinet_from_text(text: String) -> Array:
	var parts := text.split(",", true)
	if parts.size() != CAB_MAX:
		return []
	var out: Array = []
	for p: String in parts:
		if p == "0":
			out.append(["", 0])
			continue
		var kv := p.split(":", true)
		if kv.size() != 2 or not Inventory.ITEMS.has(kv[0]) or not kv[1].is_valid_int():
			return []
		var n := int(kv[1])
		if n < 1 or n > 99 or str(n) != kv[1]:
			return []
		out.append([kv[0], n])
	return out

# ---------------------------------------------------------------------------------------------
# The items.

## Whether the item in a hand can be used (data/items.json "usable" agrees: tests/prop_shop.gd).
static func usable(item: String) -> bool:
	return ITEMS.has(item)

## How long a glow stick stays lit (shop.glow, seconds).
static func glow_seconds(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"shop.glow", GLOW_SECONDS)

## Whether player `id` is in a flash's second at host time t.
static func flashing(sh: ShopState, id: String, t: float) -> bool:
	return sh != null and t < float(sh.flashes.get(id, -INF))

## How many watchers a flash counts as (one; the deliberate break makes it two).
static func flash_watchers() -> int:
	return 2 if test_break == "two_flash" else 1

## Whether player `id` is on speed juice at host time t.
static func juiced(sh: ShopState, id: String, t: float) -> bool:
	return sh != null and t < float(sh.juiced.get(id, -INF))

## The players whose toy's rattle starts in (t0, t1]: the Playroom counts each as a noise of theirs.
static func rattles_from(sh: ShopState, t0: float, t1: float) -> Dictionary:
	var out := {}
	if sh == null:
		return out
	for toy: Dictionary in sh.toys:
		var st := float(toy["start"])
		if st > t0 and st <= t1 + 1e-9:
			out[str(toy["by"])] = true
	return out

## The smelling salts' reach (Run.HEAL_REACH is passed in: this file does not load run.gd).
static func salts_reach(heal_reach: float) -> float:
	return INF if test_break == "far_salts" else heal_reach
