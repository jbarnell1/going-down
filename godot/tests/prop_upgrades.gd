# The bank room's guarantees over seeded random sequences (sim/upgrades.gd): credits never go below
# zero, no node is owned twice, undo refunds exactly and is refused after bed, buying only ever
# touches the buyer's own state, and the roll is seeded, takes only owned nodes, and has the odds
# that were printed before it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Upgrades = preload("res://sim/upgrades.gd")

const SHARE := 100
const SEEDS := 40

func _ids() -> Array[String]:
	var out: Array[String] = []
	for n in Upgrades.nodes():
		out.append(String(n["id"]))
	return out

func _distinct(owned: Array[String]) -> bool:
	for i in owned.size():
		for j in range(i + 1, owned.size()):
			if owned[i] == owned[j]:
				return false
	return true

func test_five_nodes_with_branches_and_prices(t: T) -> void:
	var ns := Upgrades.nodes()
	t.eq(ns.size(), 5, "five nodes")
	var branches: Array[String] = []
	for n in ns:
		branches.append(String(n["branch"]))
		t.check(String(n["description"]) != "" and String(n["drawback"]) != "", "%s has a verb and a drawback" % n["id"])
	for b: String in ["Lamp", "Ear", "Hands", "Nerve"]:
		t.check(branches.has(b), "branch %s present" % b)
	t.eq(Upgrades.price_of("flashbulb", 0, SHARE), SHARE, "the first node costs one share")
	t.eq(Upgrades.price_of("whistle", 1, SHARE), 2 * SHARE, "each later node costs one share more")
	t.eq(Upgrades.price_of("doorstop", 4, SHARE), 5 * SHARE, "the fifth costs five shares")

func test_random_play_keeps_credits_and_ownership(t: T) -> void:
	var ids := _ids()
	for k in SEEDS:
		var rng := Rng.make_rng("play-%d" % k)
		var s := Upgrades.UpgradeState.make(rng.int_in(0, 600))
		for _i in 80:
			var before_credits := s.credits
			var before_owned := s.owned.duplicate()
			var op := rng.int_in(0, 9)
			if op <= 4:
				var id: String = ids[rng.int_in(0, ids.size() - 1)]
				var r := Upgrades.buy(s, id, SHARE)
				if r.ok:
					if r.state.credits != before_credits - r.price or before_owned.has(id) or s.in_bed:
						t.check(false, "seed %d: a bad purchase went through (%s)" % [k, id])
				else:
					if r.state != s or s.credits != before_credits or s.owned != before_owned:
						t.check(false, "seed %d: a refusal changed something" % k)
				s = r.state
			elif op == 5:
				s = Upgrades.undo(s).state
			elif op == 6:
				s = Upgrades.add_credits(s, rng.int_in(0, 250))
			elif op == 7 and rng.next() < 0.3:
				s = Upgrades.go_to_bed(s)
			elif op == 8 and s.in_bed:
				s = Upgrades.next_morning(s)
			elif op == 9 and not s.owned.is_empty():
				s = Upgrades.apply_loss(s, Upgrades.lose_one_by_roll("play-%d" % k, _i, s.owned))
			if s.credits < 0:
				t.check(false, "seed %d: credits went below zero (%d)" % [k, s.credits])
			if not _distinct(s.owned):
				t.check(false, "seed %d: a node is owned twice" % k)

func test_buy_refused_when_poor_owned_or_in_bed(t: T) -> void:
	var s := Upgrades.UpgradeState.make(SHARE - 1)
	var r := Upgrades.buy(s, "flashbulb", SHARE)
	t.check(not r.ok and r.reason == "poor", "one credit short is refused")
	t.eq(r.state.credits, SHARE - 1, "a refusal keeps the balance")
	s = Upgrades.UpgradeState.make(10 * SHARE)
	var bought := Upgrades.buy(s, "flashbulb", SHARE)
	t.check(bought.ok, "an affordable node is bought")
	t.eq(bought.state.credits, 9 * SHARE, "the price is taken")
	t.eq(s.credits, 10 * SHARE, "the state passed in is not edited")
	var again := Upgrades.buy(bought.state, "flashbulb", SHARE)
	t.check(not again.ok and again.reason == "owned", "a node cannot be bought twice")
	var unknown := Upgrades.buy(s, "nothing", SHARE)
	t.check(not unknown.ok and unknown.reason == "unknown", "an unknown node is refused")
	var bed := Upgrades.buy(Upgrades.go_to_bed(s), "whistle", SHARE)
	t.check(not bed.ok and bed.reason == "in_bed", "no buying from bed")

func test_undo_refunds_exactly_and_only_the_last(t: T) -> void:
	for k in SEEDS:
		var rng := Rng.make_rng("undo-%d" % k)
		var s := Upgrades.UpgradeState.make(rng.int_in(300, 2000))
		var ids := _ids()
		var a: String = ids[rng.int_in(0, 4)]
		s = Upgrades.buy(s, a, SHARE).state
		var b: String = ids[rng.int_in(0, 4)]
		var rb := Upgrades.buy(s, b, SHARE)
		var base_credits := s.credits
		if rb.ok:
			var u := Upgrades.undo(rb.state)
			t.check(u.ok, "seed %d: undo works before bed" % k)
			t.eq(u.state.credits, base_credits, "seed %d: refund is exact" % k)
			t.eq(u.state.owned, s.owned, "seed %d: owned is back as it was" % k)
			t.check(not Upgrades.undo(u.state).ok, "seed %d: a second undo is refused" % k)
	var fresh := Upgrades.undo(Upgrades.UpgradeState.make(500))
	t.check(not fresh.ok and fresh.reason == "nothing_to_undo", "undo with nothing bought is refused")

func test_undo_refused_after_bed(t: T) -> void:
	var s := Upgrades.buy(Upgrades.UpgradeState.make(500), "whistle", SHARE).state
	var slept := Upgrades.go_to_bed(s)
	var u := Upgrades.undo(slept)
	t.check(not u.ok and u.reason == "in_bed", "undo is refused in bed")
	t.eq(u.state.credits, slept.credits, "a refused undo refunds nothing")
	t.check(u.state.owned.has("whistle"), "the node stays")
	var morning := Upgrades.next_morning(slept)
	t.check(not Upgrades.undo(morning).ok, "yesterday's purchase cannot be undone the next morning")

func test_buying_for_another_player_is_impossible(t: T) -> void:
	var ann := Upgrades.UpgradeState.make(500)
	var bo := Upgrades.UpgradeState.make(0)
	var r := Upgrades.buy(ann, "doorstop", SHARE)
	t.check(r.ok, "ann buys from her own share")
	t.eq(bo.credits, 0, "bo's credits are untouched")
	t.check(bo.owned.is_empty(), "bo owns nothing")
	t.check(not Upgrades.buy(bo, "doorstop", SHARE).ok, "bo cannot buy from ann's money")
	t.eq(r.state.credits, 400, "only ann's balance fell")

func test_roll_is_seeded_and_takes_an_owned_node(t: T) -> void:
	var ids := _ids()
	for k in SEEDS:
		var rng := Rng.make_rng("roll-%d" % k)
		var owned: Array[String] = []
		for id in ids:
			if rng.next() < 0.6:
				owned.append(id)
		var day := rng.int_in(1, 20)
		var got := Upgrades.lose_one_by_roll("seed-%d" % k, day, owned)
		if owned.is_empty():
			t.eq(got, "", "seed %d: nothing owned takes nothing" % k)
			continue
		t.check(owned.has(got), "seed %d: the roll takes an owned node" % k)
		t.eq(Upgrades.lose_one_by_roll("seed-%d" % k, day, owned), got, "seed %d: same seed and day, same result" % k)
		var flipped: Array[String] = owned.duplicate()
		flipped.reverse()
		t.eq(Upgrades.lose_one_by_roll("seed-%d" % k, day, flipped), got, "seed %d: order does not matter" % k)
	var spread := {}
	for d in 60:
		spread[Upgrades.lose_one_by_roll("spread", d, ids)] = true
	t.check(spread.size() >= 3, "across days the roll is not stuck on one node (%d kinds)" % spread.size())

func test_odds_equal_one_over_number_owned(t: T) -> void:
	var ids := _ids()
	var none: Array[String] = []
	var o0 := Upgrades.odds_before_roll(none)
	t.eq(int(o0["count"]), 0, "none owned: count 0")
	t.eq(String(o0["text"]), "nothing to take", "none owned: says so")
	for n in range(1, 6):
		var owned: Array[String] = ids.slice(0, n)
		var o := Upgrades.odds_before_roll(owned)
		t.eq(int(o["count"]), n, "%d owned: count" % n)
		t.eq(String(o["text"]), "1 in %d" % n, "%d owned: text" % n)
		var per: Dictionary = o["per_node"]
		t.eq(per.size(), n, "%d owned: every node has its odds" % n)
	var three: Array[String] = ids.slice(0, 3)
	var hits := {}
	for d in 600:
		var got := Upgrades.lose_one_by_roll("odds", d, three)
		hits[got] = int(hits.get(got, 0)) + 1
	for id in three:
		var share_seen := float(int(hits.get(id, 0))) / 600.0
		t.check(absf(share_seen - 1.0 / 3.0) < 0.07, "%s taken about 1 in 3 (%.2f)" % [id, share_seen])

func test_apply_loss_removes_one_and_refunds_nothing(t: T) -> void:
	var s := Upgrades.buy(Upgrades.UpgradeState.make(500), "second_wind", SHARE).state
	var lost := Upgrades.apply_loss(s, "second_wind")
	t.check(lost.owned.is_empty(), "the node is gone")
	t.eq(lost.credits, s.credits, "no refund")
	t.check(not Upgrades.undo(lost).ok, "a lost node cannot be undone back")
