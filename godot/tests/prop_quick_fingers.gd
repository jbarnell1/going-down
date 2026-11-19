# T30: badge training, its one-step undo, branch loss and actual silent faster searching.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Day = preload("res://sim/day.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")
const Search = preload("res://tests/prop_search.gd")
const SkillsView = preload("res://client/skills_view.gd")

func test_only_owned_badges_pay_and_all_or_nothing_undo(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var home := ShopTest.with_credits(Cabinet.home_run("porter-purchase", ids), {"p0": 1510, "p1": 900})
	home = Run.with_findables(Run.with_deep_pockets(home))
	var windows := {"p0": ShopTest.window(home, 3), "p1": ShopTest.window(home, 4)}
	var asks := {"p0": ["skill", 5], "p1": ["skill", 5]}
	home = Cabinet.with_bags(home, {"p0": [["badge", 1], ["badge", 1]], "p1": [["badge", 2]]})
	var off := Cabinet.tick(home, windows, asks)
	t.eq(_badge_count(off.state, "p0"), 2, "flag off cannot spend the badges")
	t.check(Cabinet.of_type(off.events, "trained").is_empty(), "no flag-off trade activation")
	home = Run.with_quick_fingers(home)
	var window_refusal := Cabinet.tick(home, {"p0": ShopTest.window(home, 1)}, {"p0": ["skill", 5]})
	t.eq(_why(window_refusal.events, "p0"), "window", "ordinary skills window still required")
	var need := Cabinet.tick(home, windows, asks)
	t.eq(_why(need.events, "p0"), "needs", "Deep Pockets is required")
	home = Cabinet.tick(home, windows, {"p0": ["skill", 0], "p1": ["skill", 0]}).state
	t.eq(ShopTest.credits_of(home, "p0"), 910, "first-layer purchase still costs 600 credits")
	var other: Upgrades.UpgradeState = home.wallets["p1"]
	other.owned.append("field_dressing")
	var backed := Cabinet.with_bags(home, {"p0": [["badge", 1]], "p1": [["badge", 2]]})
	backed = Run.with_cabinet(backed, "p0", _cab_badge())
	var refused := Cabinet.tick(backed, windows, asks)
	t.eq(_why(refused.events, "p0"), "badges", "a cabinet badge and a crew badge cannot pay for my purchase")
	t.eq(_why(refused.events, "p1"), "trade", "Medic is locked out of the Porter layer")
	t.eq(_badge_count(refused.state, "p0"), 1, "unaffordable purchase does not consume the first badge")
	t.eq(_badge_count(refused.state, "p1"), 2, "wrong-trade request consumes neither badge")
	var enough := Cabinet.with_bags(refused.state, {"p0": [["badge", 1], ["badge", 2]], "p1": [["badge", 2]]})
	var paid := Cabinet.tick(enough, windows, asks)
	t.eq(Cabinet.of_type(paid.events, "trained").size(), 1, "only the eligible player buys")
	t.eq(_badge_count(paid.state, "p0"), 1, "exactly two carried badges spent across slots")
	t.eq(ShopTest.credits_of(paid.state, "p0"), 910, "badge trade leaves all credits")
	t.eq(Upgrades.trade_of(paid.state.wallets["p0"].owned), "Porter", "first trade fixes specialization")
	var repeat := Cabinet.tick(paid.state, windows, asks)
	t.eq(_why(repeat.events, "p0"), "owned", "replayed confirmation cannot spend twice")
	t.eq(_badge_count(repeat.state, "p0"), 1, "no double spend")

	var crowded := Cabinet.with_bags(repeat.state, {"p0": [["badge", 2], ["juice", 1], ["marker", 1], ["glow", 1]]})
	var no_space := Cabinet.tick(crowded, windows, {"p0": ["skill", 1]})
	t.eq(_why(no_space.events, "p0"), "badge_room", "undo refuses when only one of two would fit")
	t.eq(Inventory.bag_of(no_space.state.bags, "p0").slots, Inventory.bag_of(crowded.bags, "p0").slots, "neither badge partially returned")
	t.eq(Upgrades.trade_of(no_space.state.wallets["p0"].owned), "Porter", "failed undo retains the learned node")
	var enough_space := Cabinet.with_bags(no_space.state, {"p0": [["badge", 1], ["juice", 1], ["marker", 1], ["glow", 1]]})
	var undone := Cabinet.tick(enough_space, windows, {"p0": ["skill", 1]})
	t.eq(_badge_count(undone.state, "p0"), 3, "undo returns both badges together")
	t.eq(Upgrades.trade_of(undone.state.wallets["p0"].owned), "", "undo of the only trade releases the branch")
	t.eq(ShopTest.credits_of(undone.state, "p0"), 910, "no credits to refund for a badge trade")
	var again := Cabinet.tick(undone.state, windows, {"p0": ["skill", 1]})
	t.eq(_why(again.events, "p0"), "nothing_to_undo", "duplicate undo cannot mint badges")
	t.eq(_badge_count(again.state, "p0"), 3, "badge count remains stable")
	t.eq(Upgrades.buy(undone.state.wallets["p0"], "quick_fingers", 600).reason, "unknown", "old credit API cannot buy a trade")

func test_signed_day_transition_and_branch_loss(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var home := Run.with_quick_fingers(Run.with_deep_pockets(Run.with_findables(Cabinet.home_run("porter-days", ids))))
	var key := PackedByteArray()
	key.resize(32)
	var old := Save.fresh("0123456789abcdef")
	old.credits = 600
	old.nodes = ["deep_pockets", "soft_shoes"]
	var legacy := Save.seal(old, key)
	t.check(Save.open(legacy, key).ok, "legacy signed fields still verify")
	var profiles := Profiles.new(key)
	profiles.join("p0", "Crew", legacy)
	home = profiles.apply_for(home, "p0", "Crew")
	home = Cabinet.with_bags(home, {"p0": [["badge", 3], ["badge", 1]]})
	var window := {"p0": ShopTest.window(home, 3)}
	var paid := Cabinet.tick(home, window, {"p0": ["skill", 5]}).state
	var checkpoint := Save.open(profiles.checkpoint(paid, "p0", "Crew", false), key)
	t.check(checkpoint.ok and checkpoint.fields.get("training_refund") == 0 and checkpoint.fields.get("training_node") == "quick_fingers", "signed pending trade describes badge currency")
	var invalid: Dictionary = checkpoint.fields.duplicate()
	invalid.training_refund = 600
	t.eq(Save.seal(invalid, key), "", "cannot sign a credit refund for a badge trade")
	profiles.leave("p0")
	profiles.join("p0", "Crew", legacy)
	var restored := profiles.apply_for(home, "p0", "Crew")
	t.eq(Upgrades.trade_of(restored.wallets["p0"].owned), "Porter", "old stamped copy uses latest accepted specialization on reconnect")
	t.eq(restored.wallets["p0"].last_id, "quick_fingers", "before bed the authoritative purchase is still undoable")
	var stock := Run.with_cabinet(paid, "p0", _cab_badge())
	var sleep := Cabinet.sleep_all(stock, "wokeUp")
	var rested: Run.RunState = sleep[0]
	var after := Save.open(profiles.checkpoint(rested, "p0", "Crew", true), key)
	t.check(after.ok and after.fields.nodes.has("quick_fingers") and not after.fields.has("training_refund"), "sleep settles the trade before the signed next day")
	t.eq(Run.items_with_cabinets(rested).get("badge", 0), 1, "only the cabinet badge survives lights out")
	var w: Upgrades.UpgradeState = rested.wallets["p0"]
	var odds := Day.loss_odds(rested.wallets, true)
	t.eq(odds.players[0].owned, 2, "printed odds count only the Porter's induction and bought trade")
	var seen := {}
	for j in 18:
		var missed := rested.copy()
		missed.seed = "porter-loss-%d" % j
		missed.day_earned = 0.0
		var events: Array[Dictionary] = []
		Run._settle_day(missed, missed.t, 0, events, false)
		var result := Cabinet.of_type(events, "dayEnded")[0].result as Dictionary
		var taken := str(result.taken[0].node)
		seen[taken] = true
		var expect_trade := "Porter" if taken == "deep_pockets" else ""
		t.eq(Upgrades.trade_of(missed.wallets["p0"].owned), expect_trade, "branch persists exactly until the last trade node is lost")
	t.check(seen.has("deep_pockets") and seen.has("quick_fingers") and seen.size() == 2, "the actual missed-day result uses exactly the displayed branch odds")
	var gap := Upgrades.apply_loss(w, "deep_pockets")
	t.eq(Upgrades.trade_of(gap.owned), "Porter", "a missing induction does not remove a retained trade")
	t.eq(Upgrades.loss_pool(gap.owned), ["quick_fingers"], "the next loss still rolls from the trade")
	var free := Upgrades.apply_loss(w, "quick_fingers")
	t.eq(Upgrades.trade_of(free.owned), "", "losing the last trade frees the player")
	t.eq(Upgrades.loss_pool(free.owned), ["deep_pockets", "soft_shoes"], "the next roll can draw from any induction after that")

func test_same_search_half_time_with_seniority_and_no_noise(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var s := Search.find_run("porter-search", ids, 1, false, false, true)
	s = Run.with_shop(Run.with_inventory(s))
	s = Run.with_quick_fingers(Run.with_deep_pockets(s))
	s = Search.open_doors(s)
	var piece := Search.piece_with(s.find, "credits", 2)
	if not t.check(piece != null, "an ordinary seeded credit drawer is reachable"):
		return
	var stand := Search.stand(piece)
	var learned := s.copy()
	var wallet := Upgrades.UpgradeState.make()
	wallet.owned.assign(["deep_pockets", "quick_fingers"])
	learned.wallets = {"p0": wallet}
	var same_wallet_with_flag_off := learned.copy()
	same_wallet_with_flag_off.quick_fingers = false
	for fast: bool in [false, true]:
		var search := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
			return Search.one(Search.inp("p0", stand[0], stand[1], k > 0, fast))
		var plain := Search.run_for(s, 3.0, search)
		var quiet := Search.run_for(learned, 3.0, search)
		var off := Search.run_for(same_wallet_with_flag_off, 3.0, search)
		var initial := Search.of_type(plain[1], "searchStart")[0]
		var shorter := Search.of_type(quiet[1], "searchStart")[0]
		var before := float(initial.done) - float(initial.from)
		var after := float(shorter.done) - float(shorter.from)
		t.check(is_equal_approx(after, before / 2.2), "time is halved with 10% faster trade seniority")
		t.eq(shorter.get("silent"), true, "host confirmed the search's silent status")
		t.eq(Search.of_type(quiet[1], "searchNoise").size(), 0, "trained search makes no noise")
		t.eq(Search.of_type(quiet[1], "startedHunting").size(), 0, "the silent action does not wake the waiting resident")
		t.eq(Search.of_type(plain[1], "searchNoise").size(), int(fast), "non-owner follows the ordinary careful/rushed sound rule")
		t.eq(Search.of_type(off[1], "searchStart")[0], initial, "stored skill has no effect with its flag off")
		t.eq(Search.of_type(quiet[1], "searchDone")[0].credits, Search.of_type(plain[1], "searchDone")[0].credits, "rushing still halves credits and careful takes the full amount")

func test_trade_wire_and_card_keep_existing_induction(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var memory := Transport.MemoryNetwork.new("porter-wire")
	var host := Host.new(memory.connect_peer("host"), "porter-wire", ids, 0.0)
	t.check(not host.world().has("porter"), "only the opt-in world carries Porter state")
	var on := Run.with_quick_fingers(Run.with_deep_pockets(Run.with_findables(Run.with_shop(Run.with_inventory(host.state)))))
	var wallet := Upgrades.UpgradeState.make()
	wallet.owned.assign(["deep_pockets", "quick_fingers"])
	on.wallets = {"p0": wallet}
	host.state = on
	var world := Protocol.enc_world(host.world())
	t.eq(world[28]["skills"], [["p0", 1]], "previous named world metadata stays")
	t.eq(world[28]["porter"], [["p0", 1]], "Porter uses another optional [28] key")
	t.eq(Protocol.INV_OPS[9], "skill", "existing input op is reused")
	var inp := {"type": "input", "seen": [], "raised": false, "holdDoors": false, "seeing": false,
		"seq": 1, "ct": 1.0, "body": Move.Body.make(0, 0, 0, 0), "eye": 1.65,
		"yaw": 0.0, "pitch": 0.0, "hFovDeg": 90, "vFovDeg": 70, "calls": 0, "pickUps": 0,
		"ackEvent": 0, "ackHt": 0, "renderTime": 0.0, "placeAck": 0, "invs": 1,
		"invOp": "skill", "invArg": 5}
	var decoded: Variant = Protocol.decode(Protocol.encode(inp))
	t.check(decoded != null and decoded.invOp == "skill" and decoded.invArg == 5, "new argument survives encode/decode")
	var card := SkillsView.new()
	card.update({"p0": 1}, {}, {}, "p0", 600, [], 0, {"p0": 0}, [["badge", 2]])
	t.eq(card.action_label(), "LEARNED", "returning owner sees the existing Deep Pockets card")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_4
	card.key(key)
	t.eq(card.action_label(), "ENTER  TRADE 2 BADGES", "actual card prints the price before use")
	t.eq(card.badges, 2, "card displays carried badge stock")
	card.update({"p0": 1}, {}, {}, "p0", 600, [], 0, {"p0": 3}, [["badge", 2]])
	t.eq(card.action_label(), "NOT YOUR TRADE", "ineligible other branch is visibly locked")
	key.physical_keycode = KEY_ENTER
	t.eq(card.key(key), [], "a locked card cannot submit from the UI")
	card.free()

static func _why(events: Array, id: String) -> String:
	for e in Cabinet.of_type(events, "invRefused"):
		if e.playerId == id:
			return str(e.why)
	return ""

static func _badge_count(s: Run.RunState, id: String) -> int:
	return int(Inventory.bag_of(s.bags, id).totals().get("badge", 0))

static func _cab_badge() -> Array:
	var cab := Shop.empty_cabinet()
	cab[0] = ["badge", 1]
	return cab
