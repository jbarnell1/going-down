extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const ShopTest = preload("res://tests/prop_shop.gd")

func test_paid_induction_is_personal_and_exactly_once(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var home := ShopTest.with_credits(Cabinet.home_run("deep-pockets", ids), {"p0": 900, "p1": 599})
	var windows := {"p0": ShopTest.window(home, 3), "p1": ShopTest.window(home, 4)}
	var asks := {"p0": ["skill", 0], "p1": ["skill", 0]}
	var off := Cabinet.tick(home, windows, asks)
	t.eq(off.events.size(), 0, "flag off does not act on skill commands")
	t.eq(ShopTest.credits_of(off.state, "p0"), 900, "flag off has no debit")
	var on := Run.with_deep_pockets(home)
	var away := Cabinet.tick(on, {"p0": ShopTest.window(home, 1)}, {"p0": ["skill", 0]})
	t.eq(ShopTest.credits_of(away.state, "p0"), 900, "requires a skills window")
	var bought := Cabinet.tick(on, windows, asks)
	t.eq(ShopTest.credits_of(bought.state, "p0"), 300, "one share charged once")
	t.eq(ShopTest.credits_of(bought.state, "p1"), 599, "insufficient funds keeps balance")
	t.eq(Cabinet.of_type(bought.events, "trained").size(), 1, "one accepted purchase")
	t.eq(Run.inventory_limit(bought.state, "p0"), 3, "owner stacks three")
	t.eq(Run.inventory_limit(bought.state, "p1"), 1, "the other player still stacks one")
	t.check(Inventory.bag_of(bought.state.bags, "p0").is_empty(), "training takes no slot")
	var replay := Cabinet.tick(bought.state, windows, asks)
	t.eq(ShopTest.credits_of(replay.state, "p0"), 300, "repeat does not debit")
	t.check(Cabinet.of_type(replay.events, "trained").is_empty(), "already trained")
	var shop_window := {"p0": ShopTest.window(home, 1)}
	var state := replay.state
	for _i in 4:
		state = Cabinet.tick(state, shop_window, {"p0": ["buy", 0]}).state
	var bag := Inventory.bag_of(state.bags, "p0")
	t.eq([bag.count(0), bag.count(1)], [3, 1], "actual shop buy honors cap")
	var undone := Cabinet.tick(state, windows, {"p0": ["skill", 1]})
	t.eq(ShopTest.credits_of(undone.state, "p0"), 660, "exact refund after item purchases")
	bag = Inventory.bag_of(undone.state.bags, "p0")
	t.eq([bag.count(0), bag.count(1), bag.count(2), bag.count(3)], [1, 1, 1, 1], "undo moves extras to free slots")

func test_signed_undo_and_cabinet_stock_survive_reconnect(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var home := Run.with_deep_pockets(ShopTest.with_credits(Cabinet.home_run("deep-pockets-save", ids), {"p0": 900}))
	var windows := {"p0": ShopTest.window(home, 3)}
	var profile := Save.fresh("0123456789abcdef")
	profile.credits = 900
	var key := PackedByteArray()
	key.resize(32)
	var old_stamp := Save.seal(profile, key)
	var room := Profiles.new(key)
	room.join("p0", "Ana", old_stamp)
	home = room.apply_for(home, "p0", "Ana")
	var bought := Cabinet.tick(home, windows, {"p0": ["skill", 0]})
	var signed := room.checkpoint(bought.state, "p0", "Ana", false)
	var opened := Save.open(signed, key)
	t.check(opened.ok and opened.fields.get("training_refund") == Shop.SHARE, "latest purchase and pending undo signed")
	t.check(Save.open(old_stamp, key).ok, "older save still opens")
	room.leave("p0")
	room.join("p0", "Ana", old_stamp)
	var restored := room.apply_for(home, "p0", "Ana")
	t.eq(ShopTest.credits_of(restored, "p0"), 300, "reconnect with previous stamp uses latest accepted purchase")
	t.eq(Run.inventory_limit(restored, "p0"), 3, "reconnected owner keeps stack capacity")
	var cabinet := Shop.empty_cabinet()
	cabinet[0] = ["marker", 3]
	restored = Run.with_cabinet(Cabinet.with_bags(restored, {"p0": [["marker", 3], ["glow", 1], ["toy", 1]]}), "p0", cabinet)
	var refused := Cabinet.tick(restored, windows, {"p0": ["skill", 1]})
	t.eq(Cabinet.of_type(refused.events, "invRefused")[0].why, "unstack", "unsafe undo asks to free space")
	t.eq(ShopTest.credits_of(refused.state, "p0"), 300, "unsafe undo leaves balance intact")
	var c := Cabinet.cab_body(restored, ids, "p0")
	var stashed := Cabinet.tick(refused.state, {"p0": c}, {"p0": ["stash", 0]})
	var settled := Cabinet.tick(stashed.state, windows, {"p0": ["skill", 1]})
	t.eq(ShopTest.credits_of(settled.state, "p0"), 900, "storing allows refund")
	t.eq(Run.items_with_cabinets(settled.state).get("marker"), 6, "undo preserves all old stock")
	var fetched := Cabinet.tick(settled.state, {"p0": c}, {"p0": ["fetch", 0]})
	t.eq(Inventory.bag_of(fetched.state.bags, "p0").totals().get("marker"), 2, "untrained owner fetches surplus into separate slots")
	var undo_signed := room.checkpoint(fetched.state, "p0", "Ana", false)
	t.check(Save.open(undo_signed, key).ok and not Save.open(undo_signed, key).fields.has("training_refund"), "refund signed without an open undo")

func test_bedtime_closes_undo_and_a_missed_day_keeps_existing_stock(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var home := Run.with_deep_pockets(ShopTest.with_credits(Cabinet.home_run("deep-pockets-bed", ids), {"p0": 900}))
	var bought := Cabinet.tick(home, {"p0": ShopTest.window(home, 3)}, {"p0": ["skill", 0]}).state
	var sleep := Cabinet.sleep_all(bought, "wokeUp")
	var rested: Run.RunState = sleep[0]
	t.eq(Cabinet.of_type(sleep[1], "trainingSettled").size(), 1, "bed settles training once")
	var wallet: Upgrades.UpgradeState = rested.wallets["p0"]
	t.check(wallet.owned.has("deep_pockets") and wallet.last_id.is_empty(), "ownership remains but undo closes")
	var cabinet := Shop.empty_cabinet()
	cabinet[0] = ["marker", 3]
	var stock := Run.with_cabinet(rested, "p0", cabinet)
	stock.day_earned = 0.0
	var events: Array[Dictionary] = []
	Run._settle_day(stock, stock.t, 0, events, false)
	t.eq(Run.inventory_limit(stock, "p0"), 1, "ordinary missed-day roll removes the single purchased node")
	t.eq(Run.items_with_cabinets(stock).get("marker"), 3, "loss keeps all cabinet stock")

func test_wire_is_optional_and_preserves_the_new_action(t: T) -> void:
	var ids := Cabinet.ids_of(1)
	var net := Transport.MemoryNetwork.new("deep-pockets-wire")
	var host := Host.new(net.connect_peer("host"), "deep-pockets-wire", ids, 0.0)
	var off := host.world()
	t.check(not off.has("skills"), "flag off omits all skill metadata")
	var on := Run.with_deep_pockets(host.state)
	on.wallets = {"p0": Upgrades.buy(Upgrades.UpgradeState.make(900), "deep_pockets", Shop.SHARE).state}
	host.state = on
	var world := Protocol.enc_world(host.world())
	t.eq(world[28]["skills"], [["p0", 2]], "named skill state coexists in extension envelope")
	t.eq(Protocol.INV_OPS[8], "throw", "cone request index preserved")
	t.eq(Protocol.INV_OPS[9], "skill", "skill action gets the next index")
	var inp := {"type": "input", "seen": [], "raised": false, "holdDoors": false, "seeing": false,
		"seq": 1, "ct": 1.0, "body": Move.Body.make(0, 0, 0, 0), "eye": 1.65,
		"yaw": 0.0, "pitch": 0.0, "hFovDeg": 90, "vFovDeg": 70, "calls": 0, "pickUps": 0,
		"ackEvent": 0, "ackHt": 0, "renderTime": 0.0, "placeAck": 0, "invs": 1,
		"invOp": "skill", "invArg": 1}
	var decoded: Variant = Protocol.decode(Protocol.encode(inp))
	t.check(decoded != null and decoded.invOp == "skill" and decoded.invArg == 1, "undo is preserved separately from a purchase")
