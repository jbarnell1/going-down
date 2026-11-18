# The shop and the cabinet over the network (S2; net/host.gd shop_block, net/protocol.gd "shop", net/client.gd shop()).
# Two players on lossy links (tests/net_harness.gd's LOSSY), through the real Host and Client, on floor 3 (the Annex),
# the host's state given wallets, cabinets and three items in Ana's hands:
#   - Ana steps out of the car and uses, from her hand, a glow stick (dropped lit at her feet), a marker (one mark of
#     hers on the floor, the crew's pad untouched) and speed juice (eight seconds; then the host has her winded);
#   - Bo asks to use an empty hand: the host refuses it, and nothing changes;
#   - at the end both clients hold exactly the host's credits, cabinets, glow sticks and marks.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Shop = preload("res://sim/shop.gd")
const Inventory = preload("res://sim/inventory.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")
const Places = preload("res://sim/places.gd")
const Rng = preload("res://sim/rng.gd")
const HostRules = preload("res://net/host_rules.gd")
const Session = preload("res://net/session.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Harness = preload("res://tests/net_harness.gd")
const DayNet = preload("res://tests/prop_day_net.gd")
const PropCabinet = preload("res://tests/prop_cabinet.gd")
const Protocol = preload("res://net/protocol.gd")

const STEP := 0.025
const FRAME := 0.05
const NAMES := {"p0": "Ana", "p1": "Bo"}

class Bot:
	var id: String
	var index: int
	var client: Client
	var offset: float
	var next_frame: float
	var body: Move.Body = null
	var to: Array = []
	var stage := 0
	var asked_at := -INF

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	## Kept here: the host holds only method callables, which do not keep it alive.
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var ids: Array[String] = ["p0", "p1"]
	var rng: Rng
	## Ana's host tank the tick after her juice ran out (null until then).
	var after_juice: Variant = null

	func _init(seed: String) -> void:
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(false, 3, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		var s := PropCabinet.with_bags(host.state, {"p0": [["glow", 1], ["marker", 1], ["speed", 1]]})
		var w := s.wallets.duplicate()
		w["p0"] = Upgrades.UpgradeState.make(510)
		w["p1"] = Upgrades.UpgradeState.make(95)
		s.wallets = w
		var c0 := Shop.empty_cabinet()
		c0[0] = ["salts", 1]
		c0[4] = ["toy", 1]
		var c1 := Shop.empty_cabinet()
		c1[1] = ["flash", 1]
		s = Run.with_cabinet(Run.with_cabinet(s, "p0", c0), "p1", c1)
		host.state = s
		for i in ids.size():
			var n := Harness.lossy()
			var tr := net.connect_peer(ids[i])
			for pair: Array in [["host", ids[i]], [ids[i], "host"]]:
				var delay := n.delay_min + rng.next() * (n.delay_max - n.delay_min)
				net.set_link(pair[0], pair[1], Transport.LinkConfig.make(delay, n.jitter, n.loss, n.reorder, n.reorder_delay, n.duplicate))
			var b := Bot.new()
			b.id = ids[i]
			b.index = i
			b.offset = (rng.next() - 0.5) * 200.0
			b.next_frame = g + rng.next() * FRAME
			b.client = Client.new(tr, "host", NAMES[ids[i]], g + b.offset)
			b.to = [-1.4, -0.6 + 1.2 * i]
			bots.append(b)

## A shop block as plain comparable data: credits, cabinets, glows [id, x, z, until].
static func view_of(block: Variant) -> Array:
	if not block is Dictionary:
		return []
	var credits := {}
	for r: Dictionary in block["credits"]:
		credits[str(r["playerId"])] = int(r["credits"])
	var cabs := {}
	for r: Dictionary in block["cabinets"]:
		var slots: Array = []
		for s: Array in r["slots"]:
			slots.append([str(s[0]), int(s[1])])
		cabs[str(r["playerId"])] = slots
	var glows: Array = []
	for gl: Dictionary in block["glows"]:
		var at: Variant = gl["at"]
		glows.append([int(gl["id"]), snappedf(float(at.x if at is Object else at["x"]), 0.01), snappedf(float(at.z if at is Object else at["z"]), 0.01), snappedf(float(gl["until"]), 0.01)])
	return [credits, cabs, glows]

static func marks_of(list: Array) -> Array:
	var out: Array = []
	for m: Dictionary in list:
		out.append([int(m["id"]), str(m["player"]), snappedf(float(m["x"]), 0.01), snappedf(float(m["z"]), 0.01)])
	return out

static func slot_of(inv: Variant, id: String, item: String) -> int:
	if not inv is Dictionary:
		return -1
	for b: Dictionary in inv["bags"]:
		if str(b["playerId"]) == id:
			for k in (b["slots"] as Array).size():
				if str(b["slots"][k][0]) == item and int(b["slots"][k][1]) > 0:
					return k
	return -1

static func sel_of(inv: Variant, id: String) -> int:
	for b: Dictionary in inv["bags"]:
		if str(b["playerId"]) == id:
			return int(b["sel"])
	return -1

func _bot_frame(s: Sess, b: Bot) -> void:
	var c := b.client
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	var local := s.g + b.offset
	if c.seed != null and c.latest != null and b.body != null and int(c.latest["depth"]) == c.local_depth:
		var plan := Session.plan_for(str(c.seed), c.local_depth)
		var car := Session.car_for(plan)
		var phase := str(c.latest["phase"])
		var to := Run.car_body(car, float(b.to[0]), float(b.to[1]))
		if phase != "arriving":
			b.body = DayNet.walk_toward(plan, phase, car, b.body, to)
		var there := M.hypot2(b.body.x - to.x, b.body.z - to.z) < 0.05
		var inv: Variant = c.inventory()
		if there and inv is Dictionary and local - b.asked_at > 1.0:
			if b.id == "p0" and b.stage < 3:
				var item: String = ["glow", "marker", "speed"][b.stage]
				var k := slot_of(inv, "p0", item)
				if k >= 0 and sel_of(inv, "p0") != k:
					lf.inv_select = k
					b.asked_at = local
				elif k >= 0:
					lf.inv_op = "use"
					lf.inv_arg = 0
					b.asked_at = local
				else:
					b.stage += 1
			elif b.id == "p1" and b.stage == 0:
				lf.inv_op = "use"
				lf.inv_arg = 0
				b.stage = 1
				b.asked_at = local
		lf.body = b.body
	var f := c.frame(local, lf)
	if f.placed != null:
		b.body = f.placed

func _play(s: Sess, limit: float) -> void:
	var seen := 0
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		s.host.update(s.g)
		while seen < s.host.event_log.size():
			var le: Host.LoggedEvent = s.host.event_log[seen]
			seen += 1
			if str(le.e.get("type")) == "juiceOut" and s.after_juice == null:
				var st := s.host.stamina_of("p0")
				s.after_juice = [st.level, st.winded] if st != null else []
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)

func test_two_clients_see_the_hosts_shop(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var s := Sess.new("shop-net")
	var t0 := Time.get_ticks_msec()
	_play(s, 45.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	Session.deck = saved
	var used := {}
	var refused: Array = []
	for le: Host.LoggedEvent in s.host.event_log:
		if str(le.e["type"]) == "itemUsed":
			used[str(le.e["item"])] = int(used.get(str(le.e["item"]), 0)) + 1
		elif str(le.e["type"]) == "invRefused":
			refused.append(le.e)
	t.eq(used, {"glow": 1, "marker": 1, "speed": 1}, "Ana used each of her three once, each asked for by her client")
	t.check(refused.size() == 1 and str(refused[0]["playerId"]) == "p1" and str(refused[0]["why"]) == "empty", "Bo's empty hand was refused (%s)" % str(refused))
	t.check(s.after_juice is Array and (s.after_juice as Array).size() == 2 and bool(s.after_juice[1]), "when the juice ran out the host had her winded (%s)" % str(s.after_juice))
	var st := s.host.state
	t.check(Inventory.bag_of(st.bags, "p0").is_empty(), "her hands are empty")
	var want := view_of(Host.shop_block(st))
	t.eq((want[0] as Dictionary), {"p0": 510, "p1": 95}, "the host's credits: nothing bought, nothing taken")
	t.eq((want[2] as Array).size(), 1, "one glow stick lit on the host")
	var want_marks := marks_of(Host.annex_block(st)["marks"])
	t.check(want_marks.size() == 1 and want_marks[0][1] == "p0", "one mark, Ana's (%s)" % str(want_marks))
	t.eq(int(Host.annex_block(st)["pad"]), int(Host.annex_block(st)["padSize"]), "the crew's pad is full: the marker did not take from it")
	for b in s.bots:
		t.eq(view_of(b.client.shop()), want, "%s's screen has the host's credits, cabinets and glow sticks" % NAMES[b.id])
		t.eq(marks_of(b.client.marks()), want_marks, "%s's screen has the host's marks" % NAMES[b.id])
	t.note("%.0f s of play in %.1f s: %s" % [s.g, secs, str(used)])

func test_off_sends_no_block(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var net := Transport.MemoryNetwork.new("shop-off")
	var ids: Array[String] = ["p0"]
	var rules := HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, false)
	var host := Host.new(net.connect_peer("host"), "shop-off", ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
	Session.deck = saved
	t.check(not host.world().has("shop") and not host.world(true).has("shop"), "with the shop off the world has no shop block")
	var wire: Array = JSON.parse_string(JSON.stringify(Protocol.enc_world(host.world())))
	t.check(wire.size() <= 27, "the off world's wire form is no longer than before (%d elements)" % wire.size())
