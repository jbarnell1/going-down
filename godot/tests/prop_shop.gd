# The shop and its six items (S2, tracker T28; docs/floors/skill-tree.md sections 1 and 5; sim/shop.gd, sim/run.gd shop).
# Proved:
#   1. money is never made or lost by buying: over many seeded rounds of two players asking at the windows, each
#      wallet's credits plus what it paid stay what they were, every purchase is one item in the buyer's hands, and
#      each price is the host's (shop.price.<item>) or the game's;
#   2. a purchase with full hands, without the money, away from windows 1 and 2, at a skill window, or in the morning
#      changes nothing and says why;
#   3. (the items, one test each, below) what each does and its limit.
# Breaks (PROP_SHOP_BREAK, sim/shop.gd test_break): "free" (a purchase that does not take the money: 1 red), "two_flash"
# (a flash counts as two watchers: the flashbulb red), "far_salts" (salts from across the room: the salts red).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Shop = preload("res://sim/shop.gd")
const Inventory = preload("res://sim/inventory.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Prison = preload("res://sim/prison.gd")
const Settings = preload("res://sim/settings.gd")
const Rng = preload("res://sim/rng.gd")
const PropCabinet = preload("res://tests/prop_cabinet.gd")
const PropInventory = preload("res://tests/prop_inventory.gd")
const PropDowns = preload("res://tests/prop_downs.gd")
const PropWatchers = preload("res://tests/prop_watchers.gd")
const PropSeek = preload("res://tests/prop_seek.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Stamina = preload("res://sim/stamina.gd")
const Bot = preload("res://sim/bot.gd")
const Marks = preload("res://sim/marks.gd")

## The run with these credits in each wallet ({id: credits}).
static func with_credits(s0: Run.RunState, given: Dictionary) -> Run.RunState:
	var s := s0.copy()
	var w := s.wallets.duplicate()
	for id: String in given:
		w[id] = Upgrades.UpgradeState.make(int(given[id]))
	s.wallets = w
	return s

static func credits_of(s: Run.RunState, id: String) -> int:
	var w: Variant = s.wallets.get(id)
	return (w as Upgrades.UpgradeState).credits if w != null else 0

static func window(s: Run.RunState, n: int) -> Variant:
	return PropCabinet.at_cell(s, Prison.WINDOWS[n - 1])

# ---------------------------------------------------------------------------------------------
# 1. Money is never made or lost.

func test_buying_never_makes_or_loses_money(t: T) -> void:
	PropCabinet.apply_break()
	var ids := PropCabinet.ids_of(2)
	var home := PropCabinet.home_run("shop-money", ids)
	if not t.check(Run.at_home(home) and home.shop, "home with the shop (phase %s)" % home.phase):
		return
	var rng := Rng.make_rng("shop-money")
	var bad := 0
	var bought := 0
	var refused := 0
	for round_n in 12:
		var start := {"p0": rng.int_in(0, 400), "p1": rng.int_in(0, 400)}
		var tuned := {}
		if round_n % 3 == 1:
			tuned[Shop.price_id(Shop.ITEMS[rng.int_in(0, Shop.ITEMS.size() - 1)])] = float(5 * rng.int_in(0, 60))
		var s := with_credits(PropCabinet.with_bags(home, {"p0": [], "p1": []}), start)
		if not tuned.is_empty():
			s = Run.with_tuning(s, tuned)
		var paid := {"p0": 0, "p1": 0}
		var got := {"p0": 0, "p1": 0}
		for _k in 12:
			var asks := {}
			var bodies := {}
			for id in ids:
				bodies[id] = window(s, 1 + rng.int_in(0, 1))
				asks[id] = ["buy", rng.int_in(0, Shop.ITEMS.size() - 1)]
			var r := PropCabinet.tick(s, bodies, asks)
			for e: Dictionary in PropCabinet.of_type(r.events, "bought"):
				var id := str(e["playerId"])
				var want := Shop.price(s.tuning, str(e["item"]))
				if int(e["price"]) != want:
					bad += 1
				paid[id] = int(paid[id]) + int(e["price"])
				got[id] = int(got[id]) + 1
				bought += 1
			refused += PropCabinet.of_type(r.events, "invRefused").size()
			s = r.state
		for id in ids:
			if credits_of(s, id) + int(paid[id]) != int(start[id]):
				bad += 1
				t.check(false, "round %d: %s started with %d, paid %d, holds %d" % [round_n, id, int(start[id]), int(paid[id]), credits_of(s, id)])
			var held := 0
			for k in Inventory.SLOTS:
				held += Inventory.bag_of(s.bags, id).count(k)
			if held != int(got[id]):
				bad += 1
				t.check(false, "round %d: %s bought %d and holds %d" % [round_n, id, int(got[id]), held])
	t.eq(bad, 0, "credits + paid is constant and every purchase is one item in hand")
	t.check(bought > 20 and refused > 20, "purchases and refusals both happened (%d bought, %d refused)" % [bought, refused])

# ---------------------------------------------------------------------------------------------
# 2. Refusals change nothing.

func test_refused_purchases_change_nothing(t: T) -> void:
	var ids := PropCabinet.ids_of(1)
	var home := PropCabinet.home_run("shop-no", ids)
	if not t.check(Run.at_home(home), "home"):
		return
	var speed := Shop.ITEMS.find("speed")
	var rich := with_credits(PropCabinet.with_bags(home, {"p0": []}), {"p0": 1000})
	var cases := [
		["full hands", with_credits(PropCabinet.with_bags(home, {"p0": [["glow", 1], ["glow", 1], ["toy", 1], ["salts", 1]]}), {"p0": 1000}), window(home, 1), "full"],
		["too little money", with_credits(PropCabinet.with_bags(home, {"p0": []}), {"p0": Shop.base_price("speed") - 1}), window(home, 2), "poor"],
		["no wallet at all", PropCabinet.with_bags(home, {"p0": []}), window(home, 1), "poor"],
		["at a skill window", rich, window(home, 3), "window"],
		["on the bunk", rich, Run.bunk_body(home.plan, ids, "p0"), "window"],
	]
	for cs: Array in cases:
		var s: Run.RunState = cs[1]
		var r := PropCabinet.tick(s, {"p0": cs[2]}, {"p0": ["buy", speed]})
		var w := PropCabinet.of_type(r.events, "invRefused")
		t.check(w.size() == 1 and str(w[0]["why"]) == cs[3], "%s: refused, %s (%s)" % [cs[0], cs[3], str(w)])
		t.eq(credits_of(r.state, "p0"), credits_of(s, "p0"), "%s: the credits are untouched" % cs[0])
		t.eq(Inventory.bag_of(r.state.bags, "p0").totals(), Inventory.bag_of(s.bags, "p0").totals(), "%s: the hands are untouched" % cs[0])
		t.check(PropCabinet.of_type(r.events, "bought").is_empty(), "%s: nothing bought" % cs[0])
	# Exactly the price, at both shop windows.
	for n: int in [1, 2]:
		var r := PropCabinet.tick(rich, {"p0": window(home, n)}, {"p0": ["buy", speed]})
		t.eq(credits_of(r.state, "p0"), 1000 - Shop.base_price("speed"), "window %d: speed juice costs %d" % [n, Shop.base_price("speed")])
		t.eq(Inventory.bag_of(r.state.bags, "p0").slots[0], ["speed", 1], "window %d: it is in your hands" % n)
	# The host's price.
	var tuned := Run.with_tuning(rich, {&"shop.price.speed": 35.0})
	var rt := PropCabinet.tick(tuned, {"p0": window(home, 1)}, {"p0": ["buy", speed]})
	t.eq(credits_of(rt.state, "p0"), 965, "the host's price is what is taken")
	# In the morning the shop is shut: buy, then sleep (C6).
	var res := PropCabinet.sleep_all(rich, "wokeUp")
	var morning: Run.RunState = res[0]
	var rm := PropCabinet.tick(morning, {"p0": window(morning, 1)}, {"p0": ["buy", speed]})
	var wm := PropCabinet.of_type(rm.events, "invRefused")
	t.check(wm.size() == 1 and str(wm[0]["why"]) == "closed", "in the morning: the shop is shut (%s)" % str(wm))
	t.eq(credits_of(rm.state, "p0"), credits_of(morning, "p0"), "and nothing is taken")
	# The flag off: buying is not a request.
	var off := PropCabinet.home_run("shop-off", ids, false)
	var ro := PropCabinet.tick(with_credits(off, {"p0": 1000}), {"p0": window(off, 1)}, {"p0": ["buy", speed]})
	var wo := PropCabinet.of_type(ro.events, "invRefused")
	t.check(wo.size() == 1 and str(wo[0]["why"]) == "op" and credits_of(ro.state, "p0") == 1000, "with the flag off: refused as unknown, nothing taken (%s)" % str(wo))

func test_the_item_table_and_the_prices(t: T) -> void:
	for item in Shop.ITEMS:
		t.check(Inventory.ITEMS.has(item), "%s is an item a slot can hold" % item)
		t.check(bool(Inventory.item_row(item).get("usable", false)), "%s is usable in items.json" % item)
		t.check(str(Inventory.item_row(item).get("shop", "")) != "", "%s has its line for the shop card" % item)
		t.check(Settings.has(Shop.price_id(item)), "%s has its price setting" % item)
		t.eq(Settings.today(Shop.price_id(item)), float(Shop.base_price(item)), "%s: the setting's today is the design's price" % item)
	t.eq([Shop.base_price("marker"), Shop.base_price("glow"), Shop.base_price("flash"), Shop.base_price("speed"), Shop.base_price("toy"), Shop.base_price("salts")],
		[60, 90, 120, 150, 150, 180], "the design's shares of a 600-credit share")
	var rising := true
	for k in range(1, Shop.ITEMS.size()):
		rising = rising and Shop.base_price(Shop.ITEMS[k - 1]) <= Shop.base_price(Shop.ITEMS[k])
	t.check(rising, "the card lists them cheapest first")
	for item: String in ["juice", "badge"]:
		t.check(not Shop.usable(item) and not bool(Inventory.item_row(item).get("usable", true)), "%s is not used from the hand" % item)

# ---------------------------------------------------------------------------------------------
# Using what is in the hand (the left mouse button sends "use").

func test_use_needs_a_shop_item_in_the_hand(t: T) -> void:
	var ids := PropCabinet.ids_of(1)
	var home := PropCabinet.home_run("shop-use", ids)
	for cs: Array in [["an empty hand", [], "empty"], ["a carton of juice", [["juice", 1]], "unusable"], ["a crew badge", [["badge", 1]], "unusable"]]:
		var s := PropCabinet.with_bags(home, {"p0": cs[1]})
		var r := PropCabinet.tick(s, {}, {"p0": ["use", 0]})
		var w := PropCabinet.of_type(r.events, "invRefused")
		t.check(w.size() == 1 and str(w[0]["why"]) == cs[2], "%s: refused, %s (%s)" % [cs[0], cs[2], str(w)])
		t.eq(Inventory.bag_of(r.state.bags, "p0").totals(), Inventory.bag_of(s.bags, "p0").totals(), "%s: the hand is unchanged" % cs[0])

# ---------------------------------------------------------------------------------------------
# 3. The six items, each with its effect and its limit.

## A crew of `ids` on floor `depth` of the game's deck (the resident parked), the inventory, the shop, the downs and
## the two-watcher rule as asked, the doors open.
static func floor_run(seed: String, ids: Array[String], depth: int = 1, downs: bool = false, watchers: bool = false) -> Run.RunState:
	var rules := HostRules.new(false, depth, Places.FULL, false, false, downs, watchers, false, false, false, false, false, false, false, false, false, true, false, false, true)
	var s := rules.prepare(Run.create_run(seed, ids))
	return PropInventory.open_doors(s)

static func holding(s0: Run.RunState, id: String, item: String) -> Run.RunState:
	return PropCabinet.with_bags(s0, {id: [[item, 1]]})

static func sh_of(s: Run.RunState) -> Shop.ShopState:
	return s.shop_state as Shop.ShopState

## Steps everyone standing still for `secs`; returns [state, events].
static func idle(s0: Run.RunState, secs: float) -> Array:
	var s := s0
	var all: Array = []
	for _k in roundi(secs / PropCabinet.DT):
		var r := PropCabinet.tick(s, {})
		s = r.state
		all.append_array(r.events)
	return [s, all]

func test_speed_juice(t: T) -> void:
	var ids := PropCabinet.ids_of(1)
	var s := holding(floor_run("item-speed", ids), "p0", "speed")
	var r := PropCabinet.tick(s, {}, {"p0": ["use", 0]})
	var t0 := r.state.t
	t.check(Shop.juiced(sh_of(r.state), "p0", t0), "on juice the tick it is drunk")
	t.check(Inventory.bag_of(r.state.bags, "p0").is_empty(), "used up")
	var res := idle(r.state, Shop.JUICE_SECONDS + 0.5)
	var outs := PropCabinet.of_type(res[1], "juiceOut")
	t.check(outs.size() == 1 and absf(float(outs[0]["t"]) - t0 - Shop.JUICE_SECONDS) <= PropCabinet.DT + 1e-6, "it runs out once, JUICE_SECONDS later (%s)" % str(outs))
	t.check(not Shop.juiced(sh_of(res[0]), "p0", (res[0] as Run.RunState).t), "and is over")
	# The host's tank (net/host.gd _step_gait): sprinting on juice costs nothing; without it, it empties.
	for on: bool in [true, false]:
		var net := Transport.MemoryNetwork.new("juice-net")
		var rules := HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true)
		var host := Host.new(net.connect_peer("host"), "item-speed-host", ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		var st := host.state.copy()
		var sh := (st.shop_state as Shop.ShopState).copy()
		sh.juiced = {"p0": st.t + Shop.JUICE_SECONDS} if on else {}
		st.shop_state = sh
		host.state = st
		var hp := Host.HostPlayer.new()
		hp.id = "p0"
		hp.stamina = Stamina.fresh_stamina(Run.sprint_seconds(st))
		var b: Move.Body = st.players[0].body
		hp.claim = b
		hp.last_ct = 0.0
		var lowest := 1.0
		for k in 120:
			var nb := Move.Body.make(b.x + 0.25 * (k + 1) * (1 if k % 2 == 0 else 1), b.z, b.level, b.y)
			host._step_gait(hp, {"ct": 0.05 * (k + 1), "body": nb, "gait": "sprint", "raised": false})
			hp.claim = Move.Body.make(b.x, b.z, b.level, b.y) if k % 2 == 1 else hp.claim
			lowest = minf(lowest, hp.stamina.level)
		if on:
			t.check(lowest >= 1.0 - 1e-9 and not hp.stamina.winded and hp.gait == "sprint", "on juice six seconds of sprinting leave the tank full (lowest %.2f)" % lowest)
		else:
			t.check(lowest < 0.5, "without it the same sprint empties the tank (lowest %.2f)" % lowest)

func test_smelling_salts(t: T) -> void:
	PropCabinet.apply_break()
	var ids := PropCabinet.ids_of(2)
	var s0 := floor_run("item-salts", ids, 1, true)
	var a := PropInventory.spot(s0, -1.5, -0.7)
	# p1 down at a spot 1.2 m from p0's.
	var s := s0.copy()
	var players := s.players.duplicate()
	var downb := PropInventory.spot(s0, -1.5, 0.5)
	var np: Run.RunPlayer = players[1].copy()
	np.body = downb
	players[1] = np
	var evs: Array[Dictionary] = []
	Run._go_down(s, players, 1, s.t, &"catch", evs)
	s.players = players
	s = holding(s, "p0", "salts")
	if not t.check(s.players[1].status == &"down", "p1 is down"):
		return
	var face := func(from: Move.Body, to: Move.Body) -> float:
		return atan2(-(to.x - from.x), -(to.z - from.z))
	var ins := func(body: Move.Body, yaw: float) -> Array[Run.PlayerInput]:
		var i0 := PropCabinet.req(PropCabinet.inp("p0", body), &"use", 0)
		i0.yaw = yaw
		var i1 := PropCabinet.inp("p1", downb)
		var out: Array[Run.PlayerInput] = [i0, i1]
		return out
	# Facing them within reach: up at once, as a heal.
	var r := Run.step_run(s, ins.call(a, face.call(a, downb)), PropCabinet.DT)
	var healed := PropCabinet.of_type(r.events, "healed")
	t.check(healed.size() == 1 and str(healed[0]["playerId"]) == "p1" and str(healed[0]["by"]) == "p0" and bool(healed[0].get("salts", false)), "facing them 1.2 m away: healed by p0 with salts (%s)" % str(healed))
	t.eq(r.state.players[1].status, &"ok", "p1 is on their feet at once")
	t.check(Inventory.bag_of(r.state.bags, "p0").is_empty(), "the salts are used up")
	# Facing away; too far (across the landing): refused, nothing used.
	var away := Run.step_run(s, ins.call(a, face.call(a, downb) + PI), PropCabinet.DT)
	t.check(str(PropCabinet.of_type(away.events, "invRefused")[0]["why"]) == "nobody" if not PropCabinet.of_type(away.events, "invRefused").is_empty() else false, "with their back to them: nobody in reach")
	t.eq(away.state.players[1].status, &"down", "still down")
	var dir := Vector2(downb.x - a.x, downb.z - a.z).normalized()
	var far := Move.Body.make(downb.x - dir.x * 6.0, downb.z - dir.y * 6.0, a.level, a.y)
	var fr := Run.step_run(s, ins.call(far, face.call(far, downb)), PropCabinet.DT)
	var w := PropCabinet.of_type(fr.events, "invRefused")
	t.check(w.size() == 1 and str(w[0]["why"]) == "nobody", "from 6 m away, facing them: refused (%s)" % str(w))
	t.eq(fr.state.players[1].status, &"down", "and they stay down")
	t.eq(Inventory.bag_of(fr.state.bags, "p0").slots[0], ["salts", 1], "the salts are kept")

func test_glow_stick(t: T) -> void:
	var ids := PropCabinet.ids_of(1)
	for secs: float in [Shop.GLOW_SECONDS, 30.0]:
		var s := holding(floor_run("item-glow", ids), "p0", "glow")
		if secs != Shop.GLOW_SECONDS:
			s = Run.with_tuning(s, {&"shop.glow": secs})
		var r := PropCabinet.tick(s, {}, {"p0": ["use", 0]})
		var g: Array = sh_of(r.state).glows
		t.check(g.size() == 1 and absf(float(g[0]["until"]) - r.state.t - secs) < 1e-6, "%.0f s: one glow stick lit, until %.0f s from now" % [secs, secs])
		var at: Move.Body = g[0]["at"]
		var me: Move.Body = r.state.players[0].body
		t.check(Inventory.within(at, me, 0.05), "at the feet")
		t.check(Inventory.bag_of(r.state.bags, "p0").is_empty(), "out of the hand")
		var res := idle(r.state, secs + 0.2)
		t.eq(PropCabinet.of_type(res[1], "glowOut").size(), 1, "%.0f s: it goes out once" % secs)
		t.eq(sh_of(res[0]).glows.size(), 0, "and is gone")
	t.eq(Shop.glow_seconds(null), Shop.GLOW_SECONDS, "untuned: three minutes")

func test_flashbulb_is_one_watcher_in_the_dark(t: T) -> void:
	PropCabinet.apply_break()
	var done := 0
	for i in 12:
		var rng := Rng.make_rng("item-flash:%d" % i)
		var ids: Array[String] = ["p0", "p1", "p2"]
		var s := Run.with_shop(Run.with_inventory(Run.with_two_watchers(Run.create_run("item-flash-%d" % i, ids))))
		var plan := s.plan
		var cells := PropDowns.cells_from(plan, 3)
		if cells.is_empty():
			continue
		var ob := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
		var wb: Move.Body = null
		for d: float in [4.0, 5.0, 3.0, 6.0]:
			for k in 8:
				var c := PropDowns.spot_from(plan, ob, d, k)
				if PropWatchers.flat(c, ob) > 2.5 and PropWatchers.sees(plan, PropWatchers.facing("p0", c, ob), ob):
					wb = c
					break
			if wb != null:
				break
		if wb == null:
			continue
		var fb := PropDowns.spot_from(plan, ob, 9.0, rng.int_in(0, 7))
		s = s.copy()
		s.phase = &"away"
		s.call = null
		s.lure = false
		var o := s.orderly.copy()
		o.body = ob
		o.mode = &"hunting"
		o.replan_in = 0.0
		o.ever_seen = true
		s.orderly = o
		# The dark: every player is blind (the blackout and a blink are the same blindness to the rules).
		var b := Run.BlinkState.new()
		b.at = s.t
		b.len = 30.0
		b.warn = 0.0
		b.blackout = false
		b.announced = true
		b.ends_at = s.t + 30.0
		s.blink = b
		var yaw := Entity.yaw_toward(ob.x - wb.x, ob.z - wb.z)
		var step := func(st: Run.RunState) -> Run.RunStep:
			var ins: Array[Run.PlayerInput] = []
			for id in ids:
				var body: Move.Body = wb if id == "p0" else fb
				ins.append(Run.PlayerInput.make(id, body, Bot.BOT_EYE, yaw if id == "p0" else yaw + PI, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG))
			return Run.step_run(st, ins, PropCabinet.DT)
		var dark: Run.RunStep = step.call(s)
		t.check(dark.state.orderly.watchers.is_empty(), "%d: in the dark nobody watches it (%s)" % [i, str(dark.state.orderly.watchers)])
		# p0's flash: for its second, one watcher, of the two three players need.
		var sf := s.copy()
		var sh := (sf.shop_state as Shop.ShopState).copy()
		sh.flashes = {"p0": sf.t + Shop.FLASH_SECONDS}
		sf.shop_state = sh
		var lit: Run.RunStep = step.call(sf)
		t.eq(lit.state.orderly.need, 2, "%d: three up players need two watchers" % i)
		t.eq(lit.state.orderly.watchers, ["p0"] as Array[String], "%d: the flash makes p0 one watcher, and only one" % i)
		# The limit: a second, then the grace, and it is dark again.
		var sl := lit.state
		for _k in roundi((Shop.FLASH_SECONDS + Entity.GRACE + 0.2) / PropCabinet.DT):
			sl = (step.call(sl) as Run.RunStep).state
		t.check(sl.orderly.watchers.is_empty(), "%d: after its second (and the grace) nobody watches (%s)" % [i, str(sl.orderly.watchers)])
		done += 1
		if done >= 3:
			break
	t.check(done >= 1, "found a floor with a spot that sees the resident (%d)" % done)
	# Used from the hand: the flash's second starts now.
	var ids2 := PropCabinet.ids_of(1)
	var s2 := holding(floor_run("item-flash-use", ids2), "p0", "flash")
	var r2 := PropCabinet.tick(s2, {}, {"p0": ["use", 0]})
	t.check(Shop.flashing(sh_of(r2.state), "p0", r2.state.t) and not Shop.flashing(sh_of(r2.state), "p0", r2.state.t + Shop.FLASH_SECONDS + 1e-6), "a flashbulb used: one second of looking")
	t.check(PropCabinet.of_type(r2.events, "itemUsed").size() == 1 and Inventory.bag_of(r2.state.bags, "p0").is_empty(), "said, and used up")

func test_marker(t: T) -> void:
	var ids := PropCabinet.ids_of(1)
	var off := holding(floor_run("item-mark-clinic", ids), "p0", "marker")
	var ro := PropCabinet.tick(off, {}, {"p0": ["use", 0]})
	var wo := PropCabinet.of_type(ro.events, "invRefused")
	t.check(wo.size() == 1 and str(wo[0]["why"]) == "annexOnly" and not Inventory.bag_of(ro.state.bags, "p0").is_empty(), "off the Annex: refused and kept (%s)" % str(wo))
	var s := holding(floor_run("item-mark", ids, 3), "p0", "marker")
	if not t.check(s.annex != null and s.plan.place == &"annex", "floor 3 is the Annex (%s)" % str(s.plan.place)):
		return
	var pad0: int = s.annex.marks.pad
	var out := PropInventory.spot(s, -1.5, 0.0)
	var r := PropCabinet.tick(s, {"p0": out}, {"p0": ["use", 0]})
	var placed := PropCabinet.of_type(r.events, "markPlaced")
	t.check(placed.size() == 1 and bool(placed[0].get("own", false)) and str(placed[0]["mark"]["player"]) == "p0", "one mark in p0's colour (%s)" % str(placed))
	t.eq(r.state.annex.marks.pad, pad0, "the crew's pad is untouched")
	t.eq(r.state.annex.marks.marks.size(), 1, "one mark on the floor")
	t.check(Inventory.bag_of(r.state.bags, "p0").is_empty(), "the marker is used up")
	# A shared one from the pad, then peel the bought one: the pad does not grow.
	var st := r.state
	var me: Move.Body = st.players[0].body
	var step := func(x: Run.RunState, mark: bool, peel: int) -> Run.RunStep:
		var i := PropCabinet.inp("p0", me)
		i.mark = mark
		i.peel = peel
		var ins: Array[Run.PlayerInput] = [i]
		return Run.step_run(x, ins, PropCabinet.DT)
	st = (step.call(st, true, -1) as Run.RunStep).state
	for _k in roundi((Marks.PLACE_SECONDS + 0.1) / PropCabinet.DT):
		st = (step.call(st, false, -1) as Run.RunStep).state
	t.eq(st.annex.marks.pad, pad0 - 1, "a shared mark took one from the pad")
	var own_id := int(placed[0]["mark"]["id"])
	var rp: Run.RunStep = step.call(st, false, own_id)
	t.eq(rp.state.annex.marks.marks.size(), 1, "peeled, the bought mark is gone, the shared one stays")
	t.eq(rp.state.annex.marks.pad, pad0 - 1, "and the pad did not grow")

func test_wind_up_toy(t: T) -> void:
	var ids := PropCabinet.ids_of(1)
	var s := holding(floor_run("item-toy", ids), "p0", "toy")
	var r := PropCabinet.tick(s, {}, {"p0": ["use", 0]})
	var t0 := r.state.t
	var toys: Array = sh_of(r.state).toys
	t.check(toys.size() == 1 and absf(float(toys[0]["start"]) - t0 - Shop.TOY_WAIT) < 1e-6 and absf(float(toys[0]["end"]) - t0 - Shop.TOY_WAIT - Shop.TOY_RATTLE) < 1e-6, "set down: it rattles in three seconds, for six")
	var res := idle(r.state, Shop.TOY_WAIT + Shop.TOY_RATTLE + 0.3)
	var noise := PropCabinet.of_type(res[1], "noise")
	t.check(noise.size() == 1 and absf(float(noise[0]["t"]) - t0 - Shop.TOY_WAIT) <= PropCabinet.DT + 1e-6 and float(noise[0]["radius"]) == Shop.TOY_RADIUS and str(noise[0]["by"]) == "p0", "one host noise as it starts (%s)" % str(noise))
	var at: Move.Body = toys[0]["at"]
	t.check(not noise.is_empty() and absf(float(noise[0]["x"]) - at.x) < 1e-6 and absf(float(noise[0]["z"]) - at.z) < 1e-6, "where it was set")
	t.eq(PropCabinet.of_type(res[1], "toyDone").size(), 1, "then it is done")
	t.eq(sh_of(res[0]).toys.size(), 0, "and gone")
	t.eq(Shop.rattles_from(sh_of(r.state), t0, t0 + Shop.TOY_WAIT - 0.01), {}, "not before its three seconds")
	t.eq(Shop.rattles_from(sh_of(r.state), t0 + Shop.TOY_WAIT - 0.01, t0 + Shop.TOY_WAIT + 0.01), {"p0": true}, "the Playroom hears its owner's noise in the tick it starts")
	# On the Playroom: the toy is a provocation, as a noise is.
	var f := PropSeek.floor_of(0)
	var cells := PropSeek.far_cells(f, 8.0, Rng.make_rng("item-toy-seek"))
	var a := PropSeek.cell_body(f.plan, cells[0])
	var toy := PropSeek.inp("p", a)
	toy.toy = true
	var c := PropSeek.provoke_once(t, f, a, toy, "toy")
	t.check(not c.is_empty() and str(c["why"]) == "toy", "on the Playroom it starts a count (%s)" % str(c))
	t.check(PropSeek.provoke_once(t, f, a, PropSeek.inp("p", a), "quiet").is_empty(), "standing still beside nothing does not")
