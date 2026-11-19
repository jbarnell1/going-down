# One authoritative profile per connection while a room process is alive.
extends RefCounted

const Save = preload("res://net/save_slip.gd")
const Run = preload("res://sim/run.gd")
const Shop = preload("res://sim/shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")

var key: PackedByteArray
var active := {}
var latest := {}
var applied := {}
var sent := {}

func _init(stamp_key: PackedByteArray) -> void:
	key = stamp_key

## A copied save cannot enter the same room twice as the same player.
func join(id: String, name_: String, line: String) -> void:
	if active.has(id):
		return
	var opened := Save.open(line, key)
	var fields: Dictionary = opened.fields
	var number := str(fields.get("player", ""))
	if number.is_empty() or active.values().has(number):
		number = Save.new_player_number()
		fields = Save.fresh(number)
	elif latest.has(number):
		fields = latest[number].duplicate(true)
	fields.name = name_
	active[id] = number
	latest[number] = fields

func trade_of(id: String) -> String:
	var fields: Dictionary = latest.get(active.get(id, ""), {})
	return Upgrades.trade_of(fields.get("nodes", []))

func leave(id: String) -> void:
	active.erase(id)
	applied.erase(id)
	sent.erase(id)

func apply_for(s: Run.RunState, id: String, name_: String) -> Run.RunState:
	if applied.has(id):
		return s
	if not active.has(id):
		join(id, name_, "")
	applied[id] = true
	return restore(s, id, latest[active[id]])

## Refresh only server-accepted progress, emit once per changed canonical stamp.
func checkpoint(s: Run.RunState, id: String, name_: String, served: bool) -> String:
	if not applied.has(id):
		return ""
	var number: String = active[id]
	var fields: Dictionary = latest[number]
	fields = collect(s, id, fields, name_, served)
	latest[number] = fields
	var line := Save.seal(fields, key)
	if line.is_empty() or sent.get(id, "") == line:
		return ""
	sent[id] = line
	return line

static func restore(s: Run.RunState, id: String, fields: Dictionary) -> Run.RunState:
	var next := s.copy()
	if s.flare or s.lamp:
		next.flare_profiles = s.flare_profiles.duplicate()
		next.flare_profiles[id] = "profile:" + str(fields.player)
	if s.orientation_resume != null:
		next.orientation_resume = restore(s.orientation_resume, id, fields)
		next.wallets = next.orientation_resume.wallets
		return next
	var wallets := s.wallets.duplicate()
	var wallet := Upgrades.UpgradeState.make(int(fields.credits))
	wallet.owned.assign(fields.nodes)
	var training := str(fields.get("training_node", "deep_pockets"))
	if fields.has("training_refund") and Run.training_enabled(s, training):
		wallet.last_id = training
		wallet.last_price = int(fields.training_refund)
	wallets[id] = wallet
	next.wallets = wallets
	if s.second_wind:
		next.wind_profiles = s.wind_profiles.duplicate()
		next.wind_profiles[id] = "profile:" + str(fields.player)
	if next.shop and fields.has("cabinet"):
		next = Run.with_cabinet(next, id, Shop.cabinet_from_text(String(fields.cabinet)))
	return next

static func collect(s: Run.RunState, id: String, old: Dictionary, name_: String, served: bool) -> Dictionary:
	var fields := old.duplicate(true)
	fields.name = name_
	var wallet: Upgrades.UpgradeState = s.wallets.get(id)
	if wallet != null:
		fields.credits = mini(wallet.credits, Save.MAX_INT)
		fields.nodes = wallet.owned.duplicate()
	if served:
		fields.days = mini(int(fields.days) + 1, Save.MAX_INT)
	if s.shop:
		var state: Shop.ShopState = s.shop_state
		fields.cabinet = Shop.cabinet_text(Shop.cabinet_of(state.cabinets, id))
	if s.deep_pockets:
		fields.erase("training_refund")
		fields.erase("training_node")
		if wallet != null and (not Upgrades.induction_node(wallet.last_id).is_empty() or (s.quick_fingers and wallet.last_id == "quick_fingers")):
			fields.training_refund = wallet.last_price
			if wallet.last_id != "deep_pockets":
				fields.training_node = wallet.last_id
	return fields

## Only ordinary Bank and server-accepted transactions change durable state.
static func changed(events: Array) -> Dictionary:
	var ids := {}
	var all := false
	var served := false
	for event: Dictionary in events:
		match str(event.type):
			"stashed", "fetched", "bought", "trained", "trainingUndone", "trainingSettled":
				ids[str(event.playerId)] = true
			"orientationPaid":
				for id: String in event.shares:
					ids[id] = true
			"dayEnded":
				all = true
				var result: Dictionary = event.get("result", {})
				served = result.get("kind", "") == "made" or (not result.has("kind") and result.get("made", false))
			"lightsOut":
				all = true
	return {"ids": ids, "all": all, "served": served}
