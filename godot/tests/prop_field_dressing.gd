extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Inventory = preload("res://sim/inventory.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Host = preload("res://net/host.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Protocol = preload("res://net/protocol.gd")
const Move = preload("res://sim/move.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const Shop = preload("res://tests/prop_shop.gd")
const Search = preload("res://tests/prop_search.gd")
const Hearing = preload("res://tests/prop_hearing.gd")
const SkillsView = preload("res://client/skills_view.gd")

func test_normal_campaign_admits_medic_with_independent_rollback(t: T) -> void:
	const Places = preload("res://sim/places.gd")
	const Session = preload("res://net/session.gd")
	const HostRules = preload("res://net/host_rules.gd")
	var room := preload("res://server/room.gd").new(null, func(_s: String) -> void: pass)
	var local := preload("res://net/local_room.gd").new()
	var game := preload("res://client/main.gd").new()
	var original := Session.deck
	Session.deck = Places.FULL
	room.configure_campaign_trades({})
	game._configure_campaign_trades(local)
	t.check(local.field_dressing and room.field_dressing, "ordinary campaign entry admits the Medic trade")
	game._field_dressing = false
	room.configure_campaign_trades({"field_dressing": "0"})
	game._configure_campaign_trades(local)
	t.check(not local.field_dressing and not room.field_dressing, "one explicit rollback disables the Medic")
	t.check(local.long_burn and room.long_burn and local.quick_fingers and room.quick_fingers and local.badge_search and room.badge_search,
		"rollback leaves the other trade and badge admissions enabled")
	game._field_dressing = true
	Session.deck = Places.CLINIC_ONLY
	game._configure_campaign_trades(local)
	t.check(not local.field_dressing and not HostRules.new(true, 1).field_dressing, "clinic-only and direct reference callers stay off")
	Session.deck = original
	game.free()

static func _available(s: Run.RunState) -> Run.RunState:
	return Run.with_field_dressing(Run.with_second_wind(Run.with_deep_pockets(Run.with_inventory(Run.with_shop(Run.with_downs(s))))))

func test_medic_badge_trade_prerequisite_lock_and_signed_undo(t: T) -> void:
	var ids := Cabinet.ids_of(2)
	var home := _available(Shop.with_credits(Cabinet.home_run("medic-window", ids), {"p0": 2000, "p1": 2000}))
	t.check(home.field_dressing, "the tested room enables the ordinary skills and rescues")
	var near := {"p0": Shop.window(home, 3), "p1": Shop.window(home, 4)}
	home = Cabinet.with_bags(home, {"p0": [["badge", 1], ["badge", 1]], "p1": [["badge", 1], ["badge", 1]]})
	var ask := {"p0": ["skill", 7], "p1": ["skill", 7]}
	var off := home.copy()
	off.field_dressing = false
	t.eq(_refusal(Cabinet.tick(off, near, ask).events, "p0"), "op", "feature off rejects the new argument")
	var needed := Cabinet.tick(home, near, ask)
	t.eq(_refusal(needed.events, "p0"), "needs", "needs Second Wind even with enough badges")
	home = Cabinet.tick(home, near, {"p0": ["skill", 2], "p1": ["skill", 2]}).state
	t.eq(Shop.credits_of(home, "p0"), 1400, "Second Wind still costs 600 credits")
	home.wallets["p1"].owned.append("quick_fingers")
	var bought := Cabinet.tick(home, near, ask)
	t.eq(_refusal(bought.events, "p1"), "trade", "an existing Porter cannot also learn the Medic trade")
	t.eq(Inventory.bag_of(bought.state.bags, "p1").totals().get("badge"), 2, "Porter refusal keeps both badges")
	t.eq(Shop.credits_of(bought.state, "p0"), 1400, "Medic trade charges no credits")
	t.eq(Inventory.bag_of(bought.state.bags, "p0").totals().get("badge", 0), 0, "two carried badges paid")
	t.eq(Upgrades.trade_of(bought.state.wallets["p0"].owned), "Medic", "purchase stamps the actual trade")
	var again := Cabinet.tick(bought.state, near, ask)
	t.eq(_refusal(again.events, "p0"), "owned", "repeated confirm pays once")
	var key := PackedByteArray()
	key.resize(32)
	var stamp := Save.open(Save.seal(Profiles.collect(bought.state, "p0", Save.fresh("123456789012abcd"), "Medic", false), key), key)
	t.check(stamp.ok and stamp.fields.training_node == "field_dressing" and stamp.fields.training_refund == 0,
		"badge undo and Medic ownership can survive signed reconnect")
	var full := Cabinet.with_bags(bought.state, {"p0": [["juice", 1], ["marker", 1], ["glow", 1], ["", 0]]})
	var undo := Cabinet.tick(full, near, {"p0": ["skill", 1]})
	t.eq(_refusal(undo.events, "p0"), "badge_room", "one empty slot cannot fit both under the untrained bag cap")
	t.eq(Inventory.bag_of(undo.state.bags, "p0").slots, Inventory.bag_of(full.bags, "p0").slots, "no partial refund")
	var room := Cabinet.with_bags(undo.state, {"p0": [["juice", 1], ["marker", 1]]})
	var returned := Cabinet.tick(room, near, {"p0": ["skill", 1]})
	t.eq(Inventory.bag_of(returned.state.bags, "p0").totals().get("badge"), 2, "undo returns exactly two badges")
	t.eq(returned.state.wallets["p0"].owned, ["second_wind"], "undo preserves the credit-funded prerequisite")

func test_actual_held_f_and_stamina_seniority(t: T) -> void:
	var ids: Array[String] = ["medic", "mate"]
	var lane := _available(Search.find_run("medic-hold", ids, 1))
	lane = Run.with_tuning(lane, {&"heal.time": 4.0, &"stamina.tank": 10.0})
	_teach(lane, "medic")
	t.eq(Run.sprint_seconds(lane, "medic"), 11.0, "Medic seniority increases duration only")
	t.eq(Run.sprint_seconds(lane, "mate"), 10.0, "teammate keeps the shared base tank")
	var off := lane.copy()
	off.field_dressing = false
	t.eq(Run.sprint_seconds(off, "medic"), 10.0, "signed skill has no stamina effect with the flag off")
	for state: Run.RunState in [lane, off]:
		var at := Move.Body.make(10.0, 10.0, 0, 0.0)
		var crew: Array[Run.RunPlayer] = state.players.duplicate()
		crew[0] = crew[0].copy()
		crew[0].body = at
		crew[1] = crew[1].copy()
		crew[1].body = Move.Body.make(10.75, 10.0, 0, 0.0)
		var events: Array[Dictionary] = []
		Run._go_down(state, crew, 1, 0.0, &"catch", events)
		var i := Search.inp("medic", at)
		i.use = true
		var inputs := {"medic": i}
		Run._step_downs(state, crew, inputs, 0.05, 0.05, events)
		var start := Cabinet.of_type(events, "healStart")[0]
		var duration := 2.0 if state.field_dressing else 4.0
		t.eq(float(start.done) - float(start.from), duration, "the real host stamps the enabled healer's exact length")
		var wire: Variant = Host.downs_block(state)
		t.eq(wire.down[0].get("healFor"), duration, "both viewers receive that host length")
		Run._step_downs(state, crew, inputs, duration - 0.05, 0.05, events)
		t.eq(crew[1].status, &"down", "recipient stays down until the stamped duration")
		Run._step_downs(state, crew, inputs, duration, 0.05, events)
		t.eq(crew[1].status, &"ok", "actual completion puts the crewmate up")
		var completed := Cabinet.of_type(events, "healed")
		if t.eq(completed.size(), 1, "one confirmed rescue"):
			t.eq(completed[0].by, "medic", "the host credits the actual helper")

func test_first_completed_assist_keeps_actual_garden_cap(t: T) -> void:
	var ids: Array[String] = ["medic", "mate", "new-peer"]
	var healer := Hearing.at(10.0, 40.0)
	var patient := Hearing.at(10.8, 40.0)
	var s := _available(Hearing.garden_run(ids, {"medic": healer, "mate": patient, "new-peer": Hearing.at(30.0, 43.0)}, Hearing.at(25.0, 40.0)))
	Run._sync_garden(s)
	_teach(s, "medic")
	var first := Profiles.restore(s, "medic", _signed("1200000000000001"))
	var other := Profiles.restore(first, "new-peer", _signed("1200000000000001"))
	var e: Array[Dictionary] = [{"type": "healed", "playerId": "mate", "by": "medic", "salts": true}]
	Run._garden_after(other, e)
	t.eq(Run.keeper_heals_left(other, "mate"), 1, "a Medic's instant salts still count and do not use the ordinary F benefit")
	e = [{"type": "healed", "playerId": "mate", "by": "medic"}]
	Run._garden_after(other, e)
	t.eq(Run.keeper_heals_left(other, "mate"), 1, "first completed normal assist preserves the remaining heal")
	t.eq(e[0].get("freeDressing", false), true, "first eligible rescue is marked once")
	t.eq(other.garden.healed, ["mate", "mate"], "free help still makes the usual get-up noise")
	e = [{"type": "healed", "playerId": "mate", "by": "new-peer"}]
	Run._garden_after(other, e)
	t.eq(Run.keeper_heals_left(other, "mate"), 0, "the same signed profile rejoining cannot take another free help")
	t.eq(e[0].has("freeDressing"), false, "repeat assist counts toward the real cap")
	var fresh := _available(Hearing.garden_run(ids, {"medic": healer, "mate": patient, "new-peer": Hearing.at(30.0, 43.0)}, Hearing.at(25.0, 40.0)))
	_teach(fresh, "medic")
	Run._sync_garden(fresh)
	e = [{"type": "healed", "playerId": "mate", "by": "medic"}]
	Run._garden_after(fresh, e)
	t.eq(Run.keeper_heals_left(fresh, "mate"), 2, "the next actual Garden floor has one newly free rescue")
	fresh.field_dressing = false
	e = [{"type": "healed", "playerId": "mate", "by": "medic"}]
	Run._garden_after(fresh, e)
	t.eq(Run.keeper_heals_left(fresh, "mate"), 1, "flag off keeps the legacy cap")

func test_sixth_card_shows_exact_badge_price_and_requirement(t: T) -> void:
	var card := SkillsView.new()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_6
	card.update({}, {}, {}, "medic", 1400, [], 0, {}, [["badge", 2]], {}, {"medic": 4})
	card.key(key)
	t.eq(card.action_label(), "REQUIRES SECOND WIND", "Medic card names the right prerequisite")
	card.update({}, {}, {}, "medic", 1400, [], 0, {}, [["badge", 2]], {}, {"medic": 0})
	t.eq(card.action_label(), "ENTER  TRADE 2 BADGES", "the sixth card uses physical badges")
	key.physical_keycode = KEY_ENTER
	t.eq(card.key(key), ["skill", 7], "old skill operation with a new last argument")
	t.eq(Protocol.INV_OPS[9], "skill", "existing wire action id unchanged")
	card.free()

static func _refusal(events: Array, id: String) -> String:
	for e in Cabinet.of_type(events, "invRefused"):
		if e.playerId == id:
			return str(e.why)
	return ""

static func _teach(s: Run.RunState, id: String) -> void:
	var w := Upgrades.UpgradeState.make()
	w.owned.assign(["second_wind", "field_dressing"])
	s.wallets[id] = w

static func _signed(number: String) -> Dictionary:
	var fields := Save.fresh(number)
	fields.nodes = ["second_wind", "field_dressing"]
	return fields
