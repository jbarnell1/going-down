# ED1, the elevator deal (North Star D1; sim/deal.gd, sim/run.gd "The elevator deal"). What is checked:
#   1. Off (the default of HostRules and of every stored run) nothing changes: no deal state, the ride is lift.ride
#      long, the car stops one floor down, no deal event, no "deal" block, an input encodes as before; and a run with
#      the deal on but no card in the deck ticks exactly as one with it off.
#   2. The same seed gives the same card and the same roll: two runs made apart agree, and the block every client
#      decodes from the host's welcome is the host's own.
#   3. The odds printed are the odds rolled: over many seeds each card's boon lands n times in 12, and the card prints
#      n in 12 reduced.
#   4. The majority rule: taken when more than half of the living players in the car press take; passed when half
#      or more press pass, and when the ride ends with neither (nobody answering is a pass).
#   5. Who carries it: the first taker, the crew's pick (a tie to the first taker), the most flares (a tie by seat).
#   6. Each face starts on the floor reached, touches only its carrier where it is personal, and ends with that floor.
#   7. No card downs, catches, strands or ends anyone.
#   8. Double or nothing: worse printed odds, the carrier only, both boons or the second curse.
#   9. Bots and scripted players send no answer, so every card passes for them.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Deal = preload("res://sim/deal.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const HostRules = preload("res://net/host_rules.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const Instr = preload("res://sim/instrument.gd")
const TapeLib = preload("res://sim/tape.gd")
const Snap = preload("res://tests/snap.gd")
const Inventory = preload("res://sim/inventory.gd")
const DealView = preload("res://client/deal_view.gd")
const AnnouncerScript = preload("res://client/announcer.gd")

const DT := 0.05

static func ids_of(n: int) -> Array[String]:
	var out: Array[String] = []
	for i in n:
		out.append("p%d" % i)
	return out

## Every card out of the deck but `card` (&"" for none).
static func only(card: StringName, given: Dictionary = {}) -> Dictionary:
	var out := given.duplicate()
	for c in Deal.CARDS:
		out[StringName("deal.%s_in" % c)] = 1.0 if c == card else 0.0
	return out

## A run of `n` players on floor `depth` of the game's deck, everyone in the car, the deal on unless `deal` is false.
static func at_floor(seed: String, depth: int, n: int, given: Dictionary = {}, deal := true) -> Run.RunState:
	var s := HostRules.new(true, depth, Places.FULL).prepare(Run.create_run(seed, ids_of(n), Places.FULL))
	if deal:
		s = Run.with_deal(s)
	if not given.is_empty():
		s = Run.with_tuning(s, given)
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		np.aboard = true
		players.append(np)
	s = s.copy()
	s.players = players
	return s

## The car leaves now with everyone aboard (Run._ride_down, as the bell does). Returns [state, events].
static func ride(s0: Run.RunState) -> Array:
	var s := s0.copy()
	var players: Array[Run.RunPlayer] = s.players.duplicate()
	var aboard := {}
	for p in players:
		aboard[p.id] = true
	var events: Array[Dictionary] = []
	Run._ride_down(s, players, aboard, s.t, events)
	s.players = players
	return [s, events]

static func still(s: Run.RunState) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		if p.status == &"ok" or p.status == &"down":
			out.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
	return out

## Steps with everyone standing still until the ride is over (arrival). `answers` each tick, if given.
static func to_arrival(s0: Run.RunState, answers: Dictionary = {}, events: Array[Dictionary] = []) -> Run.RunState:
	var s := s0
	for _k in 2000:
		if s.phase != &"riding":
			return s
		if not answers.is_empty():
			s = Run.with_deal_answers(s, Run.deal_crew(s), answers, events)
		var r := Run.step_run(s, still(s), DT)
		events.append_array(r.events)
		s = r.state
	return s

static func answer(seq: int, choice: int, pick := "", dbl := 0, use := -1) -> Array:
	return [seq, choice, pick, dbl, use]

static func offer_of(s: Run.RunState) -> Deal.Offer:
	return (s.deal as Deal.DealState).offer if s.deal != null else null

## A seed whose card on the ride from `from` with only `card` in the deck rolls `boon` (true) or a curse.
static func seed_rolling(card: StringName, from: int, boon: bool, label := "dealroll", day := 1) -> String:
	var n := int(Deal.CARD[card]["odds"])
	for i in 400:
		var seed := "ed1-roll-%s-%d" % [card, i]
		var r := Deal.roll_of(label, seed, day, from)
		if (r < n) == boon:
			if card != &"express" or Deal.express_safe(seed, from, Places.FULL):
				return seed
	return ""

## HostRules with only the deal asked for: every other switch off, deal_ found by its name (the parameter order may
## grow around it).
static func rules_with_deal(depth: int) -> HostRules:
	var names: Array = []
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if str(m["name"]) == "_init":
			for a: Dictionary in m["args"]:
				names.append(str(a["name"]))
	var args: Array = [true, depth, Places.FULL]
	for k in range(3, names.size()):
		args.append(names[k] == "deal_")
	return Callable(HostRules, "new").callv(args)

## Seeds for a Second Opinion then Lights Out double, ridden from floor 1: {curse, both, lost}.
const DOUBLE_DECK := {&"deal.squeak_in": 0.0, &"deal.torch_in": 0.0, &"deal.second_in": 1.0, &"deal.dark_in": 1.0, &"deal.express_in": 0.0}
static func double_seeds() -> Dictionary:
	var found := {}
	var tn := Settings.make(DOUBLE_DECK)
	for i in 600:
		var seed := "ed1-don-%d" % i
		if Deal.draw(tn, seed, 1, 1, Places.FULL) != &"second":
			continue
		var first := Deal.roll_of("dealroll", seed, 1, 1)
		var second := Deal.roll_of("dealroll2", seed, 1, 1)
		var k := "curse" if first >= 9 else ("both" if second < 3 else "lost")
		if not found.has(k):
			found[k] = seed
		if found.size() == 3:
			break
	return found

# ---------------------------------------------------------------------------------------------
# 1. Off.

func test_flag_off_changes_nothing(t: T) -> void:
	var rules := HostRules.new(true, 1, Places.FULL)
	t.check(not rules.deal, "HostRules leaves the deal off by default")
	var s := rules.prepare(Run.create_run("ed1-off", ids_of(2), Places.FULL))
	t.check(s.deal == null, "a run made without the flag has no deal state")
	var off := at_floor("ed1-off", 1, 2, {}, false)
	var r: Array = ride(off)
	var st: Run.RunState = r[0]
	t.eq(st.timer, Run.RIDE_TIME, "off, the ride is lift.ride long")
	for e: Dictionary in r[1]:
		t.check(not str(e["type"]).begins_with("deal"), "off, no deal event on leaving: %s" % e["type"])
	var evs: Array[Dictionary] = []
	var arrived := to_arrival(st, {}, evs)
	t.eq(arrived.depth, 2, "off, the car stops one floor down")
	for e: Dictionary in evs:
		t.check(not str(e["type"]).begins_with("deal"), "off, no deal event on arriving: %s" % e["type"])
	var same := Run.with_deal_answers(arrived, Run.deal_crew(arrived), {"p0": answer(1, Deal.TAKE)}, evs)
	t.check(same == arrived, "off, an answer changes nothing")
	var net := Transport.MemoryNetwork.new("ed1-off")
	var host := Host.new(net.connect_peer("host"), "ed1-off", ["p0", "p1"], 0.0)
	host.state = st
	t.check(not host.world().has("deal"), "off, the world has no deal block")
	var inp := {"type": "input", "seq": 1, "ct": 1.0, "body": st.players[0].body, "eye": 1.65, "yaw": 0.0, "pitch": 0.0, "hFovDeg": 90.0, "vFovDeg": 70.0,
		"raised": false, "holdDoors": false, "gait": "walk", "seeing": false, "calls": 0, "pickUps": 0, "ackEvent": 0, "ackHt": -1.0, "renderTime": 0.0, "placeAck": 0, "seen": []}
	var plain: Array = JSON.parse_string(Protocol.encode(inp))
	t.eq(plain.size(), 18, "an input without the deal encodes as before")
	# On with no card in the deck: the same run, tick for tick, as with it off (the pay path included).
	var none := only(&"")
	var a := at_floor("ed1-same", 1, 3, none, false)
	var b := at_floor("ed1-same", 1, 3, none, true)
	var ra: Array = ride(a)
	var rb: Array = ride(b)
	var sa: Run.RunState = ra[0]
	var sb: Run.RunState = rb[0]
	t.check(offer_of(sb) == null, "no card in the deck: nothing is dealt")
	var ea: Array[Dictionary] = []
	var eb: Array[Dictionary] = []
	sa = to_arrival(sa, {}, ea)
	sb = to_arrival(sb, {}, eb)
	for _k in (100 if t.quick else 400):
		var x := Run.step_run(sa, still(sa), DT)
		var y := Run.step_run(sb, still(sb), DT)
		ea.append_array(x.events)
		eb.append_array(y.events)
		sa = x.state
		sb = y.state
	var deal_events := eb.filter(func(e: Dictionary) -> bool: return str(e["type"]).begins_with("deal"))
	t.check(deal_events.is_empty(), "no card, no deal event")
	t.eq(JSON.stringify(Snap.run(sb)), JSON.stringify(Snap.run(sa)), "on with no card, the run is the run with it off")
	t.eq(JSON.stringify(Snap.events(eb)), JSON.stringify(Snap.events(ea)), "and its events too")

# ---------------------------------------------------------------------------------------------
# 2. The same seed, the same card and roll, on the host and on every screen.

func test_same_seed_same_card_and_roll_on_host_and_clients(t: T) -> void:
	var seen := {}
	for i in (12 if t.quick else 40):
		var seed := "ed1-same-%d" % i
		var a: Run.RunState = ride(at_floor(seed, 1, 3))[0]
		var b: Run.RunState = ride(at_floor(seed, 1, 3))[0]
		var oa := offer_of(a)
		var ob := offer_of(b)
		if not t.check(oa != null and ob != null, "%s: the ride from floor 1 deals a card" % seed):
			return
		t.check(oa.card == ob.card and oa.n == ob.n and oa.closes == ob.closes, "%s: the same card twice" % seed)
		seen[oa.card] = true
		var ans := {"p0": answer(oa.seq, Deal.TAKE), "p2": answer(oa.seq, Deal.TAKE)}
		var ea: Array[Dictionary] = []
		var eb: Array[Dictionary] = []
		var ta := Run.with_deal_answers(a, Run.deal_crew(a), ans, ea)
		var tb := Run.with_deal_answers(b, Run.deal_crew(b), ans, eb)
		var xa := offer_of(ta)
		var xb := offer_of(tb)
		t.check(xa.state == &"taken" and xa.roll == xb.roll and xa.outcome == xb.outcome and xa.carrier == xb.carrier,
			"%s: the same roll (%d, %d) and carrier" % [seed, xa.roll, xb.roll])
		t.eq(xa.roll, Deal.roll_of("dealroll", seed, ta.day_index, 1), "%s: the roll is the seed's" % seed)
		# The host's welcome, read by two clients: both have the host's own block.
		var net := Transport.MemoryNetwork.new("ed1-wire-%d" % i)
		var host := Host.new(net.connect_peer("host"), seed, ["p0", "p1", "p2"], 0.0)
		host.state = ta
		var w := host.world()
		var want: Variant = Deal.dec(JSON.parse_string(JSON.stringify(Deal.enc(Deal.block(ta.deal)))))
		var got: Array = []
		for you: String in ["p1", "p2"]:
			var pkt := Protocol.encode({"type": "welcome", "you": you, "seed": seed, "playing": true, "evFrom": 0, "world": w})
			var read: Variant = Protocol.decode(pkt)
			got.append(read.world.get("deal") if read != null else null)
		t.check(got[0] != null and got[0] == got[1] and got[0] == want, "%s: both clients decode the host's block" % seed)
		if got[0] is Dictionary:
			var o: Dictionary = got[0]["offer"]
			t.check(Deal.CARDS[int(o["card"])] == xa.card and int(o["roll"]) == xa.roll and int(o["n"]) == xa.n and str(o["carrier"]) == xa.carrier,
				"%s: the screens show the host's card, odds, roll and carrier" % seed)
	t.check(seen.size() >= 3, "the seeds deal different cards: %s" % str(seen.keys()))

func test_the_wire(t: T) -> void:
	var a: Run.RunState = ride(at_floor("ed1-wire", 1, 2))[0]
	var blk: Dictionary = Deal.block(a.deal)
	var text := JSON.stringify(Deal.enc(blk))
	t.check(Deal.dec(JSON.parse_string(text)) is Dictionary, "the block decodes")
	t.check(Deal.dec(JSON.parse_string(text.replace("[", "[\"x\","))) == null, "a malformed block is refused")
	var inp := {"type": "input", "seq": 1, "ct": 1.0, "body": a.players[0].body, "eye": 1.65, "yaw": 0.0, "pitch": 0.0, "hFovDeg": 90.0, "vFovDeg": 70.0,
		"raised": false, "holdDoors": false, "gait": "walk", "seeing": false, "calls": 0, "pickUps": 0, "ackEvent": 0, "ackHt": -1.0, "renderTime": 0.0, "placeAck": 0, "seen": [],
		"deal": [3, Deal.TAKE, "p1", 1, -1]}
	var back: Variant = Protocol.decode(Protocol.encode(inp))
	t.check(back != null and back.get("deal") == [3, Deal.TAKE, "p1", 1, -1] and not back.has("skipReelAt"), "the answer survives the wire: %s" % str(back.get("deal") if back != null else null))
	inp["skipReelAt"] = 12.5
	back = Protocol.decode(Protocol.encode(inp))
	t.check(back != null and is_equal_approx(float(back.get("skipReelAt", -1.0)), 12.5) and back.get("deal") is Array, "with the reel's skip beside it")

# ---------------------------------------------------------------------------------------------
# 3. The odds shown are the odds rolled.

func test_odds_shown_equal_odds_rolled(t: T) -> void:
	var seeds := 600 if t.quick else 3000
	for n: int in [1, 3, 6, 9, 11]:
		var boons := 0
		for i in seeds:
			if Deal.roll_of("dealroll", "ed1-odds-%d" % i, 1, 1) < n:
				boons += 1
		var want := float(n) / 12.0
		var got := float(boons) / float(seeds)
		var sd := sqrt(want * (1.0 - want) / float(seeds))
		t.check(absf(got - want) < 4.0 * sd + 0.005, "%d in 12: the boon landed %.3f of %d rolls (want %.3f)" % [n, got, seeds, want])
	t.eq(Deal.fraction(6), "1 in 2", "6 twelfths print 1 in 2")
	t.eq(Deal.fraction(9), "3 in 4", "9 print 3 in 4")
	t.eq(Deal.fraction(4), "1 in 3", "4 print 1 in 3")
	t.eq(Deal.fraction(5), "5 in 12", "5 print 5 in 12")
	t.eq(Deal.odds_line(&"squeak", 6), "1 in 2: HAZARD PAY. 1 in 2: SQUEAKY SOLES.", "the back of the card")
	# The offer's printed n is what the roll is held to, and the tuning moves both.
	for n: int in [2, 10]:
		var s: Run.RunState = ride(at_floor("ed1-oddset", 1, 1, only(&"squeak", {&"deal.squeak": float(n)})))[0]
		var o := offer_of(s)
		t.eq(o.n, n, "the card is dealt at the host's odds %d" % n)
		var tk := offer_of(Run.with_deal_answers(s, Run.deal_crew(s), {"p0": answer(o.seq, Deal.TAKE)}, [] as Array[Dictionary]))
		t.eq(tk.outcome, &"boon" if tk.roll < n else &"curse", "the outcome is the roll against the printed %d" % n)

# ---------------------------------------------------------------------------------------------
# 4. The majority rule.

func _decided(t: T, n: int, votes: Array, want: StringName, what: String) -> void:
	var s: Run.RunState = ride(at_floor("ed1-vote", 1, n, only(&"squeak")))[0]
	var o := offer_of(s)
	var ans := {}
	for i in votes.size():
		if int(votes[i]) != 0:
			ans["p%d" % i] = answer(o.seq, int(votes[i]))
	var ev: Array[Dictionary] = []
	var s2 := Run.with_deal_answers(s, Run.deal_crew(s), ans, ev)
	var got := offer_of(s2).state
	if want == &"open":
		t.eq(got, &"open", "%s: still open" % what)
		var arrived := to_arrival(s2, ans)
		t.eq((arrived.deal as Deal.DealState).last.state, &"passed", "%s: passed when the ride ends" % what)
	else:
		t.eq(got, want, what)

func test_majority_rule(t: T) -> void:
	var Y := Deal.TAKE
	var N := Deal.PASS
	_decided(t, 1, [Y], &"taken", "alone, a take is a majority")
	_decided(t, 1, [N], &"passed", "alone, a pass passes")
	_decided(t, 1, [0], &"open", "alone, no answer")
	_decided(t, 2, [Y, 0], &"open", "two, one take is not a majority")
	_decided(t, 2, [Y, N], &"passed", "two, a tie is a pass")
	_decided(t, 2, [Y, Y], &"taken", "two, both take")
	_decided(t, 3, [Y, Y, 0], &"taken", "three, two takes")
	_decided(t, 3, [Y, N, 0], &"open", "three, one each")
	_decided(t, 4, [Y, Y, N, N], &"passed", "four, two and two")
	_decided(t, 4, [Y, Y, Y, N], &"taken", "four, three takes")
	_decided(t, 4, [0, 0, 0, 0], &"open", "four, nobody answers")
	# An answer for another card, or from someone not in the car, does not count.
	var s: Run.RunState = ride(at_floor("ed1-vote", 1, 2, only(&"squeak")))[0]
	var o := offer_of(s)
	var crew: Array[String] = ["p0"]
	var ev: Array[Dictionary] = []
	t.eq(offer_of(Run.with_deal_answers(s, Run.deal_crew(s), {"p0": answer(o.seq + 1, Y), "p1": answer(o.seq + 1, Y)}, ev)).state, &"open", "an answer to another card")
	t.eq(offer_of(Run.with_deal_answers(s, crew, {"p0": answer(o.seq, Y)}, ev)).state, &"taken", "the crew counted is the car's")
	# Nothing left to choose: the car arrives SETTLED later (never sooner than a ride without a card); open, it waits.
	t.eq(s.timer, Deal.RIDE, "a ride with a card lasts deal.ride")
	var stepped := s
	for _k in 60:
		stepped = Run.step_run(stepped, still(stepped), DT).state
	var passed := Run.with_deal_answers(stepped, Run.deal_crew(stepped), {"p0": answer(o.seq, N), "p1": answer(o.seq, N)}, ev)
	t.check(absf(passed.timer - Deal.SETTLED) < 1e-6 and absf(offer_of(passed).closes - (passed.t + Deal.SETTLED)) < 1e-6, "passed 3 s in: the car arrives %.2f s later (want %.1f)" % [passed.timer, Deal.SETTLED])
	var early := Run.with_deal_answers(s, Run.deal_crew(s), {"p0": answer(o.seq, N), "p1": answer(o.seq, N)}, ev)
	t.check(absf(early.timer - maxf(Run.RIDE_TIME, Deal.SETTLED)) < 1e-6, "passed at once: never sooner than a plain ride (%.2f)" % early.timer)
	var open := Run.with_deal_answers(stepped, Run.deal_crew(stepped), {"p0": answer(o.seq, Y)}, ev)
	t.check(absf(open.timer - stepped.timer) < 1e-9, "still open: the ride is not cut")

# ---------------------------------------------------------------------------------------------
# 5. Who carries it.

func test_who_carries_it(t: T) -> void:
	var ev: Array[Dictionary] = []
	# Whoever drew it: the first to press take, across ticks.
	var s: Run.RunState = ride(at_floor("ed1-who", 1, 3, only(&"squeak")))[0]
	var o := offer_of(s)
	s = Run.with_deal_answers(s, Run.deal_crew(s), {"p2": answer(o.seq, Deal.TAKE)}, ev)
	s = Run.with_deal_answers(s, Run.deal_crew(s), {"p2": answer(o.seq, Deal.TAKE), "p0": answer(o.seq, Deal.TAKE)}, ev)
	t.eq(offer_of(s).carrier, "p2", "whoever drew it: the first taker")
	# The crew's pick (Novelty Torch): most picked; a tie goes to the first taker.
	s = ride(at_floor("ed1-who", 1, 3, only(&"torch")))[0]
	o = offer_of(s)
	var picked := Run.with_deal_answers(s, Run.deal_crew(s), {"p0": answer(o.seq, Deal.TAKE, "p1"), "p2": answer(o.seq, Deal.TAKE, "p1")}, ev)
	t.eq(offer_of(picked).carrier, "p1", "the crew's pick: the most picked")
	var s4: Run.RunState = ride(at_floor("ed1-who", 1, 4, only(&"torch")))[0]
	o = offer_of(s4)
	s4 = Run.with_deal_answers(s4, Run.deal_crew(s4), {"p3": answer(o.seq, Deal.TAKE, "p1")}, ev)
	s4 = Run.with_deal_answers(s4, Run.deal_crew(s4), {"p3": answer(o.seq, Deal.TAKE, "p1"), "p0": answer(o.seq, Deal.TAKE, "p2"), "p1": answer(o.seq, Deal.TAKE)}, ev)
	t.eq(offer_of(s4).carrier, "p3", "a tie of picks goes to the first taker")
	# The most flares left (Second Opinion); a tie goes by seat.
	s = ride(at_floor("ed1-who", 1, 3, only(&"second")))[0]
	o = offer_of(s)
	var bags := {}
	bags["p1"] = Inventory.add(Inventory.Bag.empty(), "flare", 2, 9).bag
	bags["p2"] = Inventory.add(Inventory.Bag.empty(), "flare", 3, 9).bag
	var fl := s.copy()
	fl.bags = bags
	t.eq(offer_of(Run.with_deal_answers(fl, Run.deal_crew(fl), {"p0": answer(o.seq, Deal.TAKE), "p1": answer(o.seq, Deal.TAKE)}, ev)).carrier, "p2", "the most flares left")
	var tie := s.copy()
	bags["p0"] = Inventory.add(Inventory.Bag.empty(), "flare", 3, 9).bag
	tie.bags = bags
	t.eq(offer_of(Run.with_deal_answers(tie, Run.deal_crew(tie), {"p2": answer(o.seq, Deal.TAKE), "p1": answer(o.seq, Deal.TAKE)}, ev)).carrier, "p0", "a tie of flares goes by seat")

# ---------------------------------------------------------------------------------------------
# 6. Each face on its floor, on its carrier.

## Takes the ride's one card by p0 (and p1 picked for a vote card) and rides to the floor. Returns the state there.
static func landed(seed: String, card: StringName, n: int, given: Dictionary = {}) -> Run.RunState:
	var s: Run.RunState = ride(at_floor(seed, 1, n, only(card, given)))[0]
	var o := offer_of(s)
	var ans := {}
	for i in n:
		ans["p%d" % i] = answer(o.seq, Deal.TAKE, "p1" if n > 1 else "")
	s = Run.with_deal_answers(s, Run.deal_crew(s), {"p1" if n > 1 else "p0": ans["p1" if n > 1 else "p0"]}, [] as Array[Dictionary])
	s = Run.with_deal_answers(s, Run.deal_crew(s), ans, [] as Array[Dictionary])
	return to_arrival(s)

## A reading closed by `who` worth 100, through the run's pay (depth and deal).
static func paid(s: Run.RunState, who: String) -> float:
	var out := Instr.CrewStep.new()
	var rd := TapeLib.Reading.new()
	rd.id = "r-%s" % who
	rd.player_id = who
	rd.value = 100.0
	rd.peak_rate = 10.0
	var crew := s.crew.copy()
	crew.members = []
	for m in s.crew.members:
		var nm := m.copy()
		if m.id == who:
			nm.tape = TapeLib.add_reading(m.tape, rd)
		crew.members.append(nm)
	out.crew = crew
	out.events = [{"type": "readingClosed", "t": s.t, "playerId": who, "tapeId": "x", "reading": rd, "value": 100.0}] as Array[Dictionary]
	var r := Run._deal_crew_tick(s, out, 1.0)
	return float(r.events[0]["value"])

func test_each_face_on_its_floor_and_its_carrier(t: T) -> void:
	var Y := true
	# Personal: hazard pay and squeaky soles (Squeaky Soles' two faces), on the carrier only, on the floor reached only.
	for boon: bool in [true, false]:
		var seed := seed_rolling(&"squeak", 1, boon)
		var s := landed(seed, &"squeak", 2)
		var d: Deal.DealState = s.deal
		t.eq(s.depth, 2, "squeak: the car stops one floor down")
		var carrier := d.last.carrier
		var other := "p1" if carrier == "p0" else "p0"
		if boon:
			t.check(absf(paid(s, carrier) - 150.0) < 1e-6 and absf(paid(s, other) - 100.0) < 1e-6, "hazard pay: x1.5 for %s only (%.1f, %.1f)" % [carrier, paid(s, carrier), paid(s, other)])
			t.check(Deal.footstep_scale(d, s.tuning, s.depth, s.day_index, carrier) == 1.0, "no squeak with the boon")
		else:
			t.check(absf(Deal.footstep_scale(d, s.tuning, s.depth, s.day_index, carrier) - Deal.SQUEAK_LOUD) < 1e-9 and Deal.footstep_scale(d, s.tuning, s.depth, s.day_index, other) == 1.0, "squeaky soles: the carrier only")
			t.check(absf(paid(s, carrier) - 100.0) < 1e-6, "no hazard pay with the curse")
		# The floor after: nothing holds.
		var next: Run.RunState = ride(s)[0]
		next = to_arrival(next)
		var nd: Deal.DealState = next.deal
		t.check(nd.active.is_empty() or nd.depth != 2, "the face ends with its floor")
		t.check(absf(paid(next, carrier) - 100.0) < 1e-6, "the next floor pays its own")
		t.eq(Deal.footstep_scale(nd, next.tuning, next.depth, next.day_index, carrier), 1.0, "the squeak ends with its floor")
	# Novelty Torch: the curse holds for the crew's pick only.
	var torch := landed(seed_rolling(&"torch", 1, false), &"torch", 3)
	var td: Deal.DealState = torch.deal
	t.eq(Deal.face_carrier(td, &"torch", torch.depth, torch.day_index), "p1", "the torch is the picked player's")
	t.eq(Deal.face_carrier(td, &"torch", torch.depth + 1, torch.day_index), "", "and only on its floor")
	# Lights Out: everyone's readings on the dark floor; for nothing, no pay.
	var dark := landed(seed_rolling(&"dark", 1, Y), &"dark", 2)
	t.check(Deal.holds(dark.deal, &"dark_pay", 2, dark.day_index) and absf(paid(dark, "p0") - 200.0) < 1e-6 and absf(paid(dark, "p1") - 200.0) < 1e-6, "lights out pays x2 for everyone")
	var dull := landed(seed_rolling(&"dark", 1, false), &"dark", 2)
	t.check(Deal.holds(dull.deal, &"dark", 2, dull.day_index) and absf(paid(dull, "p0") - 100.0) < 1e-6, "lights out for nothing pays the floor's own")
	# Express: skips a floor and pays double there; the curse wakes the resident as the doors open.
	var ex := landed(seed_rolling(&"express", 1, true), &"express", 2)
	t.eq(ex.depth, 3, "express: the car stops two floors down")
	t.check(absf(paid(ex, "p0") - 200.0) < 1e-6, "express pays x2 on the floor reached")
	t.eq(ex.orderly.mode, &"waiting", "express with the boon: the resident waits as usual")
	var up := landed(seed_rolling(&"express", 1, false), &"express", 2)
	t.eq(up.depth, 3, "express, and it is up: two floors down too")
	t.eq(up.orderly.mode, &"hunting", "and the resident is awake as the doors open")
	t.check(not Deal.express_safe("ed1-any", 2, Places.FULL) and not Deal.express_safe("ed1-any", 3, Places.FULL), "no express where it would skip into the Playroom or beyond")
	t.check(not Deal.eligible(null, "ed1-any", 2, Places.FULL).has(&"express"), "express is not dealt from floor 2")
	t.check(not Deal.deals_on(0) and not Deal.deals_on(5) and not Deal.deals_on(6) and Deal.deals_on(1) and Deal.deals_on(4), "cards are dealt on rides to the 2nd to 5th floors only")
	# Second Opinion: once, by anyone on their feet, on its floor only.
	var so := landed(seed_rolling(&"second", 1, true), &"second", 3)
	var sd: Deal.DealState = so.deal
	var seq := sd.last.seq
	var ev: Array[Dictionary] = []
	while so.phase == &"arriving":
		so = Run.step_run(so, still(so), DT).state
	var used := Run.with_deal_answers(so, Run.deal_crew(so), {"p2": answer(seq, 0, "", 0, seq)}, ev)
	t.eq((used.deal as Deal.DealState).second_by, "p2", "the second opinion is used by the one who asked")
	var again := Run.with_deal_answers(used, Run.deal_crew(used), {"p0": answer(seq, 0, "", 0, seq)}, ev)
	t.check(again == used, "and only once")
	t.eq(ev.filter(func(e: Dictionary) -> bool: return e["type"] == "dealSecondUsed").size(), 1, "one use, one event")

# ---------------------------------------------------------------------------------------------
# 7. No card downs anyone.

func test_no_card_downs_anyone(t: T) -> void:
	for card in Deal.CARDS:
		for boon: bool in [true, false]:
			var seed := seed_rolling(card, 1, boon)
			if not t.check(seed != "", "%s: a seed for each outcome" % card):
				continue
			var s := landed(seed, card, 3)
			var d: Deal.DealState = s.deal
			t.check(d.last != null and d.last.state == &"taken" and d.last.outcome == (&"boon" if boon else &"curse"), "%s: taken and rolled %s" % [card, "boon" if boon else "curse"])
			t.check(s.phase == &"arriving" and s.summary == null, "%s: the car arrives and the run goes on" % card)
			# The first seconds on the floor with the crew standing in the car: nobody is down, out or left.
			for _k in 60:
				s = Run.step_run(s, still(s), DT).state
			for p in s.players:
				t.check(p.status == &"ok" and Run.in_car(s.car, p.body), "%s: %s is on their feet in the car (%s)" % [card, p.id, p.status])
			t.check(s.plan != null and s.phase != &"ended", "%s: nobody is stranded" % card)
	# A double's curse too.
	var dseed := str(double_seeds().get("lost", ""))
	if not t.check(dseed != "", "a seed for a lost double"):
		return
	var s: Run.RunState = ride(at_floor(dseed, 1, 1, DOUBLE_DECK))[0]
	var o := offer_of(s)
	s = Run.with_deal_answers(s, ["p0"] as Array[String], {"p0": answer(o.seq, Deal.TAKE)}, [] as Array[Dictionary])
	s = Run.with_deal_answers(s, ["p0"] as Array[String], {"p0": answer(o.seq, Deal.TAKE, "", 1)}, [] as Array[Dictionary])
	s = to_arrival(s)
	t.check(s.players[0].status == &"ok" and s.summary == null, "a lost double downs nobody")

# ---------------------------------------------------------------------------------------------
# 8. Double or nothing.

func test_double_or_nothing(t: T) -> void:
	var g := DOUBLE_DECK
	var found := double_seeds()
	if not t.check(found.size() == 3, "seeds for every double: %s" % str(found)):
		return
	# A curse first: no double offered.
	var c: Run.RunState = ride(at_floor(found["curse"], 1, 2, g))[0]
	var co := offer_of(c)
	c = Run.with_deal_answers(c, Run.deal_crew(c), {"p0": answer(co.seq, Deal.TAKE), "p1": answer(co.seq, Deal.TAKE)}, [] as Array[Dictionary])
	t.eq(offer_of(c).dbl_state, &"", "after a curse there is no double")
	for k: String in ["both", "lost"]:
		var s: Run.RunState = ride(at_floor(found[k], 1, 2, g))[0]
		var o := offer_of(s)
		s = Run.with_deal_answers(s, Run.deal_crew(s), {"p1": answer(o.seq, Deal.TAKE)}, [] as Array[Dictionary])
		s = Run.with_deal_answers(s, Run.deal_crew(s), {"p1": answer(o.seq, Deal.TAKE), "p0": answer(o.seq, Deal.TAKE)}, [] as Array[Dictionary])
		o = offer_of(s)
		t.check(o.outcome == &"boon" and o.dbl_state == &"offered" and o.dbl_card == &"dark", "%s: a boon offers the double, already drawn" % k)
		t.eq(o.dbl_n, int(Deal.CARD[&"dark"]["odds"]) - Deal.DOUBLE_DROP, "%s: at worse printed odds" % k)
		# Second Opinion is the most flares' card: nobody has any, so the first in seat order carries it.
		t.eq(o.carrier, "p0", "%s: the carrier is the first seat" % k)
		var not_carrier := Run.with_deal_answers(s, Run.deal_crew(s), {"p1": answer(o.seq, Deal.TAKE, "", 1), "p0": answer(o.seq, Deal.TAKE)}, [] as Array[Dictionary])
		t.eq(offer_of(not_carrier).dbl_state, &"offered", "%s: only the carrier can draw again" % k)
		var kept := to_arrival(s)
		t.eq((kept.deal as Deal.DealState).active.size(), 1, "%s: not drawn, the boon is kept" % k)
		t.check(Deal.holds(kept.deal, &"second", kept.depth, kept.day_index), "%s: the kept boon holds" % k)
		var drawn := Run.with_deal_answers(s, Run.deal_crew(s), {"p0": answer(o.seq, Deal.TAKE, "", 1)}, [] as Array[Dictionary])
		var arrived := to_arrival(drawn)
		var d: Deal.DealState = arrived.deal
		if k == "both":
			t.check(Deal.holds(d, &"second", arrived.depth, arrived.day_index) and Deal.holds(d, &"dark_pay", arrived.depth, arrived.day_index), "won: both boons")
		else:
			t.check(not Deal.holds(d, &"second", arrived.depth, arrived.day_index) and Deal.holds(d, &"dark", arrived.depth, arrived.day_index), "lost: the first boon goes and the second's curse lands")

# ---------------------------------------------------------------------------------------------
# 9. Bots pass.

func test_no_answer_passes_every_card(t: T) -> void:
	var rules := rules_with_deal(1)
	t.check(rules.deal, "the deal_ parameter turns it on")
	var s := rules.prepare(Run.create_run("ed1-bots", ids_of(4), Places.FULL))
	t.check(s.deal != null, "prepare turns it on")
	for i in 3:
		var players: Array[Run.RunPlayer] = []
		for p in s.players:
			var np := p.copy()
			np.aboard = true
			players.append(np)
		s = s.copy()
		s.players = players
		var r: Array = ride(s)
		var ev: Array[Dictionary] = []
		s = to_arrival(r[0], {}, ev)
		var d: Deal.DealState = s.deal
		t.check(d.last != null and d.last.state == &"passed" and d.active.is_empty(), "ride %d: nobody answers, the card is passed" % (i + 1))
		t.eq(ev.filter(func(e: Dictionary) -> bool: return e["type"] == "dealPassed").size(), 1, "ride %d: one dealPassed" % (i + 1))
		t.eq(s.depth, i + 2, "ride %d: one floor down" % (i + 1))

# ---------------------------------------------------------------------------------------------
# 10. On screen (client/deal_view.gd, client/announcer.gd deal_say): the card shows its odds before anyone answers,
# the keys make the answer the host reads, the intercom reads it, and the floor's marks follow the block.

static func _client_block(s: Run.RunState) -> Variant:
	return Deal.dec(JSON.parse_string(JSON.stringify(Deal.enc(Deal.block(s.deal)))))

static func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.pressed = true
	return k

func test_card_on_screen(t: T) -> void:
	var s: Run.RunState = ride(at_floor("ed1-view", 1, 3, only(&"torch")))[0]
	var o := offer_of(s)
	var crew := Run.deal_crew(s)
	var names := {"p0": "Ann", "p1": "Bob", "p2": "Cy"}
	var v := DealView.new()
	v.update(_client_block(s), "p2", crew, names, null, s.t, s.depth, s.day_index, true)
	var lines := v.lines()
	t.check(lines.has("NOVELTY TORCH") and lines.has("ODDS: 1 IN 2: HAZARD PAY. 1 IN 2: NOVELTY TORCH.") and lines.has(Deal.who_line(Deal.WHO_VOTE)),
		"the card: its name, its odds on the back and who carries it, before anyone answers: %s" % str(lines))
	t.check(v.said.size() == 1 and v.said[0] == Deal.read_line(&"torch"), "the intercom reads the card: %s" % str(v.said))
	t.eq(v.answer(), [o.seq, 0, "", 0, -1], "no key: no answer (a pass at the ride's end)")
	t.check(v.key(_key(KEY_2)), "a number key on a pick card is taken")
	t.eq(v.answer(), [o.seq, Deal.TAKE, "p1", 0, -1], "2: take it, and pick the second in seat order")
	t.check(v.key(_key(KEY_N)) and v.answer() == [o.seq, Deal.PASS, "", 0, -1], "N: pass")
	t.check(not v.key(_key(KEY_O)), "O does nothing during a ride")
	# The host reads the answers of all three; the client shows the outcome and the intercom says it.
	var ans := {"p0": [o.seq, Deal.TAKE, "p1", 0, -1], "p1": [o.seq, Deal.TAKE, "p1", 0, -1]}
	var taken := Run.with_deal_answers(s, crew, ans, [] as Array[Dictionary])
	v.update(_client_block(taken), "p2", crew, names, null, taken.t, taken.depth, taken.day_index, true)
	var landed := offer_of(taken).outcome
	var face: StringName = Deal.CARD[&"torch"]["boon"] if landed == &"boon" else Deal.CARD[&"torch"]["curse"]
	t.check(v.said.size() >= 2 and v.said[1] == Deal.outcome_line(face, "Bob"), "the intercom says how it went: %s" % str(v.said))
	var arrived := to_arrival(taken)
	v.update(_client_block(arrived), "p1", crew, names, null, arrived.t, arrived.depth, arrived.day_index, false)
	t.eq(v.answer(), null, "on the floor: nothing to answer")
	var floor_lines := v.lines()
	t.check(floor_lines.has("YOU: %s" % Deal.FACE_NAME[face]), "the carrier's mark on the floor: %s" % str(floor_lines))
	v.update(_client_block(arrived), "p0", crew, names, null, arrived.t, arrived.depth, arrived.day_index, false)
	t.check(v.lines().has("BOB: %s" % Deal.FACE_NAME[face]), "and everyone else's")
	v.update(_client_block(arrived), "p0", crew, names, null, arrived.t, arrived.depth + 1, arrived.day_index, false)
	t.check(v.lines().is_empty(), "nothing on another floor")
	v.free()
	# Lights Out and the torch, from the block alone; the flicker is the host time's, the same on every screen.
	var dark := landed_state_for_view()
	t.check(DealView.lights_out(_client_block(dark), dark.depth, dark.day_index) and not DealView.lights_out(_client_block(dark), dark.depth + 1, dark.day_index), "lights out on its floor only")
	var flicker: Array = []
	for i in 40:
		flicker.append(DealView.torch_flicker(100.0 + i * 0.125))
	t.check(flicker.has(1.0) and (flicker.has(0.1) or flicker.has(0.55)), "the torch flickers: %s" % str(flicker))
	t.eq(DealView.torch_flicker(123.456), DealView.torch_flicker(123.456), "the same flicker for the same host time")
	# The intercom's subtitles: each line in turn, under a recorded line when one plays.

	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.deal_say("First.")
	a.deal_say("Second.")
	t.eq(a.shown(), "First.", "the first line")
	a.clock_ms = 6000
	t.eq(a.shown(), "Second.", "then the next")
	a.clock_ms = 20000
	t.eq(a.shown(), "", "then nothing")
	a.free()

static func landed_state_for_view() -> Run.RunState:
	return landed(seed_rolling(&"dark", 1, true), &"dark", 2)

# ---------------------------------------------------------------------------------------------
# The settings' proof (tests/prop_settings.gd test_deal_settings calls it): each row moves what it names.

static func settings_proof(t: T) -> void:
	var s: Run.RunState = ride(at_floor("ed1-set", 1, 1, only(&"squeak", {&"deal.ride": 25.0})))[0]
	t.eq(s.timer, 25.0, "deal.ride: the ride with a card")
	for c in Deal.CARDS:
		var none := only(&"")
		none[StringName("deal.%s_in" % c)] = 1.0
		var tn := Run.with_tuning(at_floor("ed1-set", 1, 1, {}, false), none).tuning
		var cards := Deal.eligible(tn, "ed1-set", 1, Places.FULL)
		t.eq(cards, [c] as Array[StringName], "deal.%s_in: only that card" % c)
		t.eq(Deal.odds_of(Run.with_tuning(at_floor("ed1-set", 1, 1, {}, false), {StringName("deal.%s" % c): 2.0}).tuning, c), 2, "deal.%s: its odds" % c)
	var tt := func(g: Dictionary) -> Settings.Values: return Settings.make(g)
	t.check(not Deal.double_on(tt.call({&"deal.double_in": 0.0})) and Deal.double_on(null), "deal.double_in")
	t.eq(Deal.double_odds(tt.call({&"deal.double_drop": 5.0}), &"second"), 4, "deal.double_drop")
	var d := Deal.DealState.new()
	d.depth = 2
	d.day = 1
	d.active = [{"face": &"hazard", "carrier": "p0", "seq": 1}, {"face": &"squeak", "carrier": "p0", "seq": 1}]
	t.eq(Deal.pay_mult(d, tt.call({&"deal.hazard_pay": 2.5}), 2, 1, "p0"), 2.5, "deal.hazard_pay")
	t.eq(Deal.footstep_scale(d, tt.call({&"deal.squeak_loud": 2.0}), 2, 1, "p0"), 2.0, "deal.squeak_loud")
	d.active = [{"face": &"dark_pay", "carrier": "p0", "seq": 1}]
	t.eq(Deal.pay_mult(d, tt.call({&"deal.dark_pay": 3.0}), 2, 1, "p1"), 3.0, "deal.dark_pay")
	d.active = [{"face": &"express", "carrier": "p0", "seq": 1}]
	t.eq(Deal.pay_mult(d, tt.call({&"deal.express_pay": 1.25}), 2, 1, "p1"), 1.25, "deal.express_pay")
	t.eq(Deal.second_time(tt.call({&"deal.second_time": 20.0})), 20.0, "deal.second_time")
	t.check(absf(DealView.torch_strength(tt.call({&"deal.torch_dim": 30.0})) - 0.3) < 1e-9, "deal.torch_dim")
