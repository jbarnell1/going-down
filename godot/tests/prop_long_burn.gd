extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")

func test_price_undo_and_signed_return(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var base := Run.with_deep_pockets(Cabinet.home_run("long-burn-shop", ids))
	base = ShopTest.with_credits(base, {"p0": 900, "p1": 599})
	var windows := {"p0": ShopTest.window(base, 3), "p1": ShopTest.window(base, 4)}
	var requests := {"p0": ["skill", 6], "p1": ["skill", 6]}
	var off := Cabinet.tick(base, windows, requests)
	t.eq(ShopTest.credits_of(off.state, "p0"), 900, "a disabled skill cannot debit the wallet")
	t.check(Cabinet.of_type(off.events, "trained").is_empty(), "the flag off does not train anyone")
	var trained := Cabinet.tick(Run.with_long_burn(base), windows, requests)
	t.eq(Cabinet.of_type(trained.events, "trained").size(), 1, "only the player with enough credits trains")
	t.eq(ShopTest.credits_of(trained.state, "p0"), 300, "the induction costs 600")
	t.eq(ShopTest.credits_of(trained.state, "p1"), 599, "an unaffordable purchase costs nothing")
	var repeated := Cabinet.tick(trained.state, windows, requests)
	t.eq(ShopTest.credits_of(repeated.state, "p0"), 300, "duplicate requests never debit twice")
	var key := PackedByteArray()
	key.resize(32)
	key.fill(12)
	var profiles := Profiles.new(key)
	profiles.join("p0", "ANN", "")
	profiles.apply_for(base, "p0", "ANN")
	var signed := profiles.checkpoint(repeated.state, "p0", "ANN", false)
	var opened := Save.open(signed, key)
	t.check(opened.ok and opened.fields.nodes.has("long_burn") and opened.fields.credits == 300
		and opened.fields.training_node == "long_burn", "the signed wallet includes the induction and pre-bed undo")
	profiles.leave("p0")
	profiles.join("p0", "ANN", signed)
	var returned := profiles.apply_for(Run.with_long_burn(base), "p0", "ANN")
	t.eq(ShopTest.credits_of(returned, "p0"), 300, "signed returning profile has the original debit")
	var undo := Cabinet.tick(returned, windows, {"p0": ["skill", 1]})
	t.eq(ShopTest.credits_of(undo.state, "p0"), 900, "undo refunds the exact induction price")
	t.check(not undo.state.wallets["p0"].owned.has("long_burn"), "the refundable node is removed on undo")

func test_real_shop_lights_prolong_only_the_trained_players_use(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var trained := Run.with_long_burn(ShopTest.floor_run("long-burn-use", ids))
	trained = Run.with_tuning(trained, {&"shop.glow": 30.0})
	var wallet := Upgrades.UpgradeState.make()
	wallet.owned.append("long_burn")
	trained.wallets = {"p0": wallet}
	var requests := {"p0": ["use", 0], "p1": ["use", 0]}
	var holding := Cabinet.with_bags(trained, {"p0": [["glow", 1]], "p1": [["glow", 1]]})
	var glows := Cabinet.tick(holding, {}, requests)
	var durations := {}
	for glow: Dictionary in ShopTest.sh_of(glows.state).glows:
		durations[glow.by] = int(roundf(float(glow.until) - glows.state.t))
	t.eq(durations, {"p0": 60, "p1": 30}, "host glow uses double the current setting for its trained user only")
	t.check(Inventory.bag_of(glows.state.bags, "p0").is_empty() and Inventory.bag_of(glows.state.bags, "p1").is_empty(), "both players spent real stock")
	holding = Cabinet.with_bags(trained, {"p0": [["flash", 1]], "p1": [["flash", 1]]})
	var flash := Cabinet.tick(holding, {}, requests)
	var window := flash.state.t + 1.5
	t.check(Shop.flashing(ShopTest.sh_of(flash.state), "p0", window), "the trained flash still counts in the second second")
	t.check(not Shop.flashing(ShopTest.sh_of(flash.state), "p1", window), "an untrained flash has stopped counting")
	t.check(not Shop.flashing(ShopTest.sh_of(flash.state), "p0", flash.state.t + 2.05), "the trained flash ends after two seconds")
	holding.long_burn = false
	var disabled := Cabinet.tick(holding, {}, requests)
	t.check(not Shop.flashing(ShopTest.sh_of(disabled.state), "p0", disabled.state.t + 1.5), "a saved skill does not alter play when the run flag is off")
