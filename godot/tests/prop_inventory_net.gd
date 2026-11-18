# The four-slot inventory over the network (docs/floors/skill-tree.md S1; net/host.gd inv_block, net/protocol.gd "inv",
# net/client.gd inventory()). Two players on lossy links (tests/net_harness.gd's LOSSY), through the real Host and
# Client, on floor 1:
#   - Ana holds a badge and a carton; she puts the carton in her hand (slot 2) and drops it; Bo takes it from the
#     floor and hands it back to her; Bo walks off across the landing and Ana tries to hand it over again: the host
#     refuses that for reach, and nothing moves;
#   - at the end both clients hold exactly the host's inventories, selected slots and pickups;
#   - every request the host carried out or refused came from a client: a hand-over out of reach is refused;
#   - with the inventory off the host's world carries no inv block at all.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Inventory = preload("res://sim/inventory.gd")
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
const PropInventory = preload("res://tests/prop_inventory.gd")
const Protocol = preload("res://net/protocol.gd")
const Floor = preload("res://sim/floor.gd")

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
	## Car-local [u, v] the bot walks to.
	var to: Array = []
	## What it does next, and when its last request went out (local time).
	var stage := 0
	var asked_at := -INF

class Sess:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var bots: Array[Bot] = []
	var g := 0.0
	var seed: String
	var ids: Array[String] = ["p0", "p1"]
	var rng: Rng
	## The far hand-over: the distance between the two on the host the tick it was asked for.
	var far_gap := -1.0

	func _init(seed_: String, on: bool) -> void:
		seed = seed_
		rng = Rng.make_rng("%s:session" % seed)
		net = Transport.MemoryNetwork.new("%s:net" % seed)
		var ht := net.connect_peer("host")
		rules = HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, on)
		host = Host.new(ht, seed, ids, 0.0, Callable(rules, "prepare"), Callable(rules, "step"))
		if on:
			host.state = PropInventory.with_bags(host.state, {"p0": [["badge", 1], ["juice", 1]]})
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
			b.to = [-1.3, -0.5 + 1.0 * i]
			bots.append(b)

## This client's view: {id: [sel, [[item, count] x4]]} and the pickups [[id, item, count]].
static func view_of(block: Variant) -> Array:
	if not block is Dictionary:
		return [{}, []]
	var bags := {}
	for b: Dictionary in block["bags"]:
		var slots: Array = []
		for s: Array in b["slots"]:
			slots.append([str(s[0]), int(s[1])])
		bags[str(b["playerId"])] = [int(b["sel"]), slots]
	var pk: Array = []
	for p: Dictionary in block["pickups"]:
		pk.append([int(p["id"]), str(p["item"]), int(p["count"])])
	return [bags, pk]

static func mine(block: Variant, id: String) -> Array:
	var v := view_of(block)
	return (v[0] as Dictionary).get(id, [0, []])

static func holds(block: Variant, id: String, item: String) -> bool:
	for s: Array in mine(block, id)[1]:
		if s[0] == item and int(s[1]) > 0:
			return true
	return false

## Car-local [u, v] on the landing at least 2.6 m from rom, reached from start in a straight line over open
## floor (every point along it, and 0.4 m to either side, on a walkable cell).
static func far_spot(plan: Floor.FloorPlan, car: Run.CarGeometry, from: Move.Body, start: Move.Body) -> Array:
	var best: Array = []
	var best_d := INF
	for ui in 30:
		for vi in 41:
			var u := -1.3 - 0.2 * ui
			var v := -4.0 + 0.2 * vi
			var to := Run.car_body(car, u, v)
			var gap := M.hypot2(to.x - from.x, to.z - from.z)
			if gap < 2.6:
				continue
			var ok := true
			for k in 21:
				var f := k / 20.0
				var px := start.x + (to.x - start.x) * f
				var pz := start.z + (to.z - start.z) * f
				var dx := -(to.z - start.z)
				var dz := to.x - start.x
				var dl := maxf(1e-6, sqrt(dx * dx + dz * dz))
				for side: float in [-0.4, 0.0, 0.4]:
					var c := Move.cell_of(plan, Move.Body.make(px + dx / dl * side, pz + dz / dl * side, start.level, start.y))
					ok = ok and Floor.is_walkable(plan, c.level, c.x, c.y)
			var walk := M.hypot2(to.x - start.x, to.z - start.z)
			if ok and walk < best_d:
				best = [u, v]
				best_d = walk
	return best if not best.is_empty() else [-1.3, 0.5]

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
		var other := s.bots[1 - b.index]
		var other_there := other.body != null and M.hypot2(other.body.x - Run.car_body(car, float(other.to[0]), float(other.to[1])).x, other.body.z - Run.car_body(car, float(other.to[0]), float(other.to[1])).z) < 0.05
		var wait := local - b.asked_at > 1.5
		if there and other_there and wait and inv is Dictionary:
			if b.id == "p0":
				match b.stage:
					0:
						# The carton in the hand (slot 2), then drop it.
						lf.inv_select = 1
						b.stage = 1
						b.asked_at = local
					1:
						if int(mine(inv, "p0")[0]) == 1:
							lf.inv_op = "drop"
							b.stage = 2
							b.asked_at = local
					2:
						# Bo gave it back and walked off: hand it over again, out of reach.
						if holds(inv, "p0", "juice") and other.stage >= 3:
							lf.inv_op = "give"
							lf.inv_arg = "p1"
							b.stage = 3
							b.asked_at = local
			else:
				match b.stage:
					0:
						var pk: Array = view_of(inv)[1]
						if not pk.is_empty():
							lf.inv_op = "take"
							lf.inv_arg = int(pk[0][0])
							b.stage = 1
							b.asked_at = local
					1:
						if holds(inv, "p1", "juice"):
							lf.inv_op = "give"
							lf.inv_arg = "p0"
							b.stage = 2
							b.asked_at = local
					2:
						if not holds(inv, "p1", "juice") and holds(inv, "p0", "juice"):
							# Off across the landing, well out of reach.
							b.to = far_spot(plan, car, Run.car_body(car, -1.3, -0.5), b.body)
							b.stage = 3
		lf.body = b.body
	var f := c.frame(local, lf)
	if f.placed != null:
		b.body = f.placed

func _play(s: Sess, limit: float) -> void:
	var asked := false
	while s.g < limit:
		s.g += STEP
		s.net.now = s.g
		var tick := s.host.tick
		s.host.update(s.g)
		if s.host.tick != tick and not asked:
			for le: Host.LoggedEvent in s.host.event_log.slice(maxi(0, s.host.event_log.size() - 8)):
				if str(le.e.get("type")) == "invRefused" and str(le.e.get("op")) == "give" and str(le.e.get("playerId")) == "p0":
					asked = true
					var a: Move.Body = null
					var b: Move.Body = null
					for p in s.host.state.players:
						if p.id == "p0":
							a = p.body
						elif p.id == "p1":
							b = p.body
					s.far_gap = M.hypot2(a.x - b.x, a.z - b.z)
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += FRAME
				_bot_frame(s, b)

func test_two_clients_see_the_hosts_inventories(t: T) -> void:
	# The rules' deliberate breaks reach here too (PROP_INVENTORY_BREAK=any_reach turns the refusal red).
	PropInventory._apply_break()
	var saved := Session.deck
	Session.deck = Places.FULL
	var s := Sess.new("inv-net", true)
	var t0 := Time.get_ticks_msec()
	_play(s, 70.0)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	Session.deck = saved
	var events: Array = []
	for le: Host.LoggedEvent in s.host.event_log:
		events.append(le.e)
	var kinds := {}
	for e: Dictionary in events:
		var ty := str(e["type"])
		if ty.begins_with("item") or ty == "invRefused":
			kinds[ty] = int(kinds.get(ty, 0)) + 1
	t.check(int(kinds.get("itemDropped", 0)) == 1 and int(kinds.get("itemTaken", 0)) == 1 and int(kinds.get("itemGiven", 0)) == 1,
		"one drop, one take, one hand-over, each asked for by a client: %s" % str(kinds))
	var far := events.filter(func(e: Dictionary) -> bool: return str(e["type"]) == "invRefused" and str(e["op"]) == "give")
	t.check(far.size() == 1 and str(far[0]["why"]) == "reach", "the hand-over from across the landing is refused for reach: %s" % str(far))
	t.check(s.far_gap > Inventory.HAND_REACH, "the two were %.2f m apart when it was asked (reach %.1f)" % [s.far_gap, Inventory.HAND_REACH])
	var want := view_of(Host.inv_block(s.host.state))
	t.eq(want, [{"p0": [1, [["badge", 1], ["juice", 1], ["", 0], ["", 0]]], "p1": [0, [["", 0], ["", 0], ["", 0], ["", 0]]]}, []],
		"the host: Ana holds the badge and, in her hand, the carton; Bo nothing; nothing on the floor")
	for b in s.bots:
		t.eq(view_of(b.client.inventory()), want, "%s's screen has the host's inventories and pickups" % NAMES[b.id])
	var lost := 0
	for k: String in s.net.stats:
		lost += (s.net.stats[k] as Transport.LinkStats).lost
	t.note("%.0f s of play in %.1f s: %s; %d messages lost" % [s.g, secs, str(kinds), lost])

func test_off_sends_no_block(t: T) -> void:
	var saved := Session.deck
	Session.deck = Places.FULL
	var off := Sess.new("inv-net-off", false)
	var on := Sess.new("inv-net-on", true)
	Session.deck = saved
	t.check(not off.host.world().has("inv") and not off.host.world(true).has("inv"), "with the inventory off the world has no inv block")
	t.check(on.host.world().has("inv"), "with it on it has")
	var wire: Array = JSON.parse_string(JSON.stringify(Protocol.enc_world(off.host.world())))
	t.check(wire.size() <= 26, "the off world's wire form is no longer than before (%d elements)" % wire.size())
