# The bank room's upgrades, as pure rules. No engine random, no clock, no rendering. Every call is a
# function from an UpgradeState to a new one; a state you pass in is never edited.
#
# The design (docs/floors/prison.md section 5 and the owner's answers): each player buys from their
# OWN even share of the banked pay, so the API only ever takes the buyer's own state; there is no
# call that spends one player's credits on another's nodes. Prices are multiples of one share (one
# made day's pay): node price = (price_shares + extra_per_owned * nodes already owned) * share,
# read from data/upgrades.json. A purchase can be undone until the player gets into bed. A missed
# day quota takes ONE owned node by a seeded roll, and the odds are readable before the roll.
#
# API (all static, all pure):
#   Upgrades.nodes() -> Array[Dictionary]       the five nodes from data/upgrades.json, in order
#   Upgrades.node(id) -> Dictionary             one node, or {} when unknown
#   Upgrades.UpgradeState.make(credits := 0) -> UpgradeState
#   Upgrades.price_of(id, owned_count, share) -> int     what the node costs this player now
#   Upgrades.buy(s, id, share) -> UpResult
#       Refused (ok false, reason set, state unchanged) when: unknown node ("unknown"), already
#       owned ("owned"), asleep ("in_bed"), prerequisite missing ("needs"), or the price is more
#       than the balance ("poor"). On success: credits - price, node added, and it is the one
#       purchase undo() can reverse.
#   undo(s) -> UpResult
#       Reverses ONLY the last purchase, ONLY before bed, refunding exactly what it cost. Refused
#       with "in_bed" or "nothing_to_undo". A second undo is refused: there is one step of undo.
#   go_to_bed(s) -> UpgradeState                the day ends for this player: no buying or undoing
#   next_morning(s) -> UpgradeState             awake again; the undo step is spent
#   add_credits(s, amount) -> UpgradeState      the player's share of banked pay (never negative)
#   lose_one_by_roll(seed, day, owned) -> String
#       The node a missed day quota takes: one of `owned`, chosen by a roll seeded from the seed
#       and the day number only, so every player sees the same result. The order of `owned` does
#       not matter. "" when nothing is owned. No refund.
#   odds_before_roll(owned) -> Dictionary
#       Printed before the roll: {"count": n, "each": "1 in n", "per_node": {id: "1 in n"},
#       "text": "1 in 3"}; n is the number owned; with none owned, count 0 and text "nothing to take".
#   apply_loss(s, id) -> UpgradeState           remove the taken node (no refund; clears undo)
#   UpgradeState.credits / owned / last_id / last_price / in_bed: read-only data.
extends RefCounted

const Rng = preload("res://sim/rng.gd")

const DATA_PATH := "res://data/upgrades.json"

static var _nodes: Array[Dictionary] = []
static var _extra_per_owned: int = 1

class UpgradeState:
	var credits: int = 0
	var owned: Array[String] = []
	## The one purchase undo() can reverse ("" when none) and what it cost.
	var last_id: String = ""
	var last_price: int = 0
	var in_bed: bool = false

	static func make(start_credits: int = 0) -> UpgradeState:
		var s := UpgradeState.new()
		s.credits = maxi(0, start_credits)
		return s

	func copy() -> UpgradeState:
		var s := UpgradeState.new()
		s.credits = credits
		s.owned = owned.duplicate()
		s.last_id = last_id
		s.last_price = last_price
		s.in_bed = in_bed
		return s

class UpResult:
	var ok: bool = false
	var reason: String = ""
	var state: UpgradeState = null
	var price: int = 0

static func _refuse(s: UpgradeState, reason: String) -> UpResult:
	var r := UpResult.new()
	r.reason = reason
	r.state = s
	return r

static func _load() -> void:
	if not _nodes.is_empty():
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if not (parsed is Dictionary):
		push_error("upgrades.json did not load")
		return
	var data: Dictionary = parsed
	var pricing: Dictionary = data.get("pricing", {})
	_extra_per_owned = int(pricing.get("extra_per_owned", 1))
	for n: Variant in data.get("nodes", []):
		if n is Dictionary:
			var d: Dictionary = n
			_nodes.append(d)

static func nodes() -> Array[Dictionary]:
	_load()
	return _nodes

static func node(id: String) -> Dictionary:
	for n in nodes():
		if String(n["id"]) == id:
			return n
	return {}

static func price_of(id: String, owned_count: int, share: int) -> int:
	var n := node(id)
	if n.is_empty():
		return 0
	return (int(n["price_shares"]) + _extra_per_owned * owned_count) * share

static func add_credits(s: UpgradeState, amount: int) -> UpgradeState:
	var t := s.copy()
	t.credits += maxi(0, amount)
	return t

static func buy(s: UpgradeState, id: String, share: int) -> UpResult:
	var n := node(id)
	if n.is_empty():
		return _refuse(s, "unknown")
	if s.owned.has(id):
		return _refuse(s, "owned")
	if s.in_bed:
		return _refuse(s, "in_bed")
	var need: Variant = n.get("requires", null)
	if need != null and not s.owned.has(String(need)):
		return _refuse(s, "needs")
	var price := price_of(id, s.owned.size(), share)
	if price > s.credits:
		return _refuse(s, "poor")
	var t := s.copy()
	t.credits -= price
	t.owned.append(id)
	t.last_id = id
	t.last_price = price
	var r := UpResult.new()
	r.ok = true
	r.state = t
	r.price = price
	return r

static func undo(s: UpgradeState) -> UpResult:
	if s.in_bed:
		return _refuse(s, "in_bed")
	if s.last_id == "" or not s.owned.has(s.last_id):
		return _refuse(s, "nothing_to_undo")
	var t := s.copy()
	t.owned.erase(s.last_id)
	t.credits += s.last_price
	t.last_id = ""
	t.last_price = 0
	var r := UpResult.new()
	r.ok = true
	r.state = t
	r.price = s.last_price
	return r

static func go_to_bed(s: UpgradeState) -> UpgradeState:
	var t := s.copy()
	t.in_bed = true
	return t

static func next_morning(s: UpgradeState) -> UpgradeState:
	var t := s.copy()
	t.in_bed = false
	t.last_id = ""
	t.last_price = 0
	return t

static func lose_one_by_roll(seed_text: String, day: int, owned: Array[String]) -> String:
	if owned.is_empty():
		return ""
	var sorted_owned: Array[String] = owned.duplicate()
	sorted_owned.sort()
	var rng := Rng.make_rng("%s:upgrade-loss:%d" % [seed_text, day])
	return sorted_owned[rng.int_in(0, sorted_owned.size() - 1)]

static func odds_before_roll(owned: Array[String]) -> Dictionary:
	var count := owned.size()
	if count == 0:
		return {"count": 0, "each": "", "per_node": {}, "text": "nothing to take"}
	var each := "1 in %d" % count
	var per: Dictionary = {}
	for id in owned:
		per[id] = each
	return {"count": count, "each": each, "per_node": per, "text": each}

static func apply_loss(s: UpgradeState, id: String) -> UpgradeState:
	var t := s.copy()
	t.owned.erase(id)
	t.last_id = ""
	t.last_price = 0
	return t
