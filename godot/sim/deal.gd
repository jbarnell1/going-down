# The elevator deal (ED1; North Star D1, first playable slice). Pure and deterministic: no drawing, no network.
# Only for a run made with the deal (sim/run.gd with_deal; net/host_rules.gd deal, the last parameter). Off, nothing
# here is called and RunState.deal stays null.
#
# The design (D1): "On each ride the crew is offered a card with its odds printed on the back. Taking it is optional.
# The announcer reads it aloud, and every card names who carries the risk: whoever drew it, someone the crew votes
# for, or 'whoever has the most flares left'." Rules that never bend: odds are printed before a chance is taken, and
# one bad roll never ends a run.
#
# How a ride goes (every number a live setting, "THE DEAL", sim/settings.gd):
#  - The car leaves a floor for the floor below (never the ride up, never from the prison). If the floor it is going
#    to is the 2nd to the 5th of its cycle (the Clinic's second floor, the Annex, the Playroom, the Arboretum in the
#    game's deck) the host deals ONE card, drawn from the floor's seed: Rng "deal:<seed>:<day>:<depth left>", so
#    every screen has the same card and a test can say which. The ride lasts at least deal.ride seconds then; once
#    nothing is left to choose the car arrives SETTLED seconds later, never sooner than a ride without a card.
#  - The card shows its name, its two faces (the boon and the curse, each one plain line), who carries it, and its
#    odds: "1 in 2: HAZARD PAY. 1 in 2: SQUEAKY SOLES." The boon's chance is in twelfths (a setting per card).
#  - Each living player in the car presses take or pass. A card that names a vote is taken with a pick: the
#    number key of the crewmate who will carry it. It is TAKEN the moment more than half of them press take; it is
#    PASSED the moment half or more press pass (a tie can no longer become a majority), and when the ride ends with
#    neither. Nobody answering is a pass.
#  - Taken: the carrier is named (whoever pressed take first; the crew's most picked, a tie going to the first
#    taker; the most flares left, a tie going to the first in seat order) and the host rolls: a whole number 0 to
#    11 from Rng "dealroll:<seed>:<day>:<depth left>". Under the boon's twelfths it is the boon, else the curse.
#  - Double or nothing: after a boon, the same carrier may draw again before the ride ends. The second card is
#    already drawn and shown with its own odds made worse by deal.double_drop twelfths (never under 1 in 12). Drawn
#    again: a boon keeps both boons; a curse loses the first boon and lands the second card's curse.
#  - On arrival the card's result holds for that floor only (its depth and its day), and ends when the car leaves it.
#
# The faces (Choices made where the design is silent, listed for the owner in the ticket):
#   hazard        HAZARD PAY: the carrier's own readings pay deal.hazard_pay times
#   squeak        SQUEAKY SOLES: the carrier's footsteps squeak, and count deal.squeak_loud times as loud to a
#                 resident that hears (the Groundskeeper; sim/hearing.gd footstep_scale)
#   torch         NOVELTY TORCH: the carrier's near light is weaker (deal.torch_dim in 100) and flickers (on screen)
#   second        SECOND OPINION: once on the floor, any player on their feet may look through a crewmate's eyes for
#                 deal.second_time seconds (client/crew_watch.gd); the rules count the one use
#   dark_pay      LIGHTS OUT: the floor's lights are out (on screen) and every reading there pays deal.dark_pay times
#   dark          LIGHTS OUT, FOR NOTHING: the lights are out and the pay is the floor's own
#   express       EXPRESS: the car skips a floor and the floor it stops at pays deal.express_pay times
#   express_awake EXPRESS, AND IT'S UP: the same, and the floor's resident is awake as the doors open
# Express is dealt only where skipping is safe: the floor skipped is the 2nd to the 4th of its cycle and the floor
# reached is a Clinic or the Annex (a resident that waits, then hunts), never the Ward or the Reactor (in the game's
# deck: only on the ride from floor 1, 8, 15).
# No face downs, catches, strands or ends anyone: the effects are a pay multiplier, a sound, a light, a look, a skip
# and a resident already hunting (tests/prop_deal.gd test_no_card_downs_anyone).
extends RefCounted

const Rng = preload("res://sim/rng.gd")
const Settings = preload("res://sim/settings.gd")
const Places = preload("res://sim/places.gd")

## The boon's chance is printed and rolled in twelfths: halves, thirds, quarters and sixths read as themselves.
const TWELFTHS := 12
## The game's numbers (the live settings' today; tests/prop_settings.gd names them).
const RIDE := 15.0
## Once nothing is left to choose, the car arrives this long after (never sooner than a ride without a card).
const SETTLED := 4.0
const HAZARD_PAY := 1.5
const DARK_PAY := 2.0
const EXPRESS_PAY := 2.0
const SQUEAK_LOUD := 1.6
const TORCH_DIM := 45
const SECOND_TIME := 10.0
const DOUBLE_DROP := 3

## Who carries a card's risk (the design's three).
const WHO_DREW := &"drew"
const WHO_VOTE := &"vote"
const WHO_FLARES := &"flares"
const WHO: Array[StringName] = [WHO_DREW, WHO_VOTE, WHO_FLARES]

## The deck, in order. The wire carries a card as its index here.
const CARDS: Array[StringName] = [&"squeak", &"torch", &"second", &"dark", &"express"]
## Each card: its name, who carries it, the boon and the curse, the boon's game odds in twelfths, and its settings.
const CARD := {
	&"squeak": {"name": "SQUEAKY SOLES", "who": WHO_DREW, "boon": &"hazard", "curse": &"squeak", "odds": 6},
	&"torch": {"name": "NOVELTY TORCH", "who": WHO_VOTE, "boon": &"hazard", "curse": &"torch", "odds": 6},
	&"second": {"name": "SECOND OPINION", "who": WHO_FLARES, "boon": &"second", "curse": &"squeak", "odds": 9},
	&"dark": {"name": "LIGHTS OUT", "who": WHO_DREW, "boon": &"dark_pay", "curse": &"dark", "odds": 6},
	&"express": {"name": "EXPRESS", "who": WHO_VOTE, "boon": &"express", "curse": &"express_awake", "odds": 6},
}
## The faces. The wire carries a face as its index here.
const FACES: Array[StringName] = [&"hazard", &"squeak", &"torch", &"second", &"dark_pay", &"dark", &"express", &"express_awake"]
## Faces that touch only their carrier.
const PERSONAL: Array[StringName] = [&"hazard", &"squeak", &"torch"]
## A face's short name, as the card prints it.
const FACE_NAME := {
	&"hazard": "HAZARD PAY", &"squeak": "SQUEAKY SOLES", &"torch": "NOVELTY TORCH", &"second": "SECOND OPINION",
	&"dark_pay": "LIGHTS OUT", &"dark": "LIGHTS OUT, FOR NOTHING", &"express": "EXPRESS", &"express_awake": "EXPRESS, AND IT'S UP",
}

## The offer's states. The wire carries a state as its index here.
const STATES: Array[StringName] = [&"open", &"taken", &"passed"]
## The double's states.
const DOUBLE_STATES: Array[StringName] = [&"", &"offered", &"taken", &"declined"]

## A vote's answers.
const TAKE := 1
const PASS := 2

## One ride's card. Replaced, never edited (copy()).
class Offer extends RefCounted:
	var seq := 0
	var card: StringName = &""
	var who: StringName = &""
	## The boon's chance in twelfths, as printed.
	var n := 6
	var opened := 0.0
	var closes := 0.0
	var from_depth := 0
	var day := 0
	## {player id: TAKE | PASS}; the order players first pressed take; {player id: picked player id}.
	var votes: Dictionary = {}
	var takers: Array[String] = []
	var picks: Dictionary = {}
	var state: StringName = &"open"
	var decided_at := -1.0
	var carrier := ""
	## The roll (0 to 11; -1 before) and what it landed.
	var roll := -1
	var outcome: StringName = &""
	## Double or nothing: the second card, its odds, its state, roll and outcome.
	var dbl_card: StringName = &""
	var dbl_n := 0
	var dbl_state: StringName = &""
	var dbl_roll := -1
	var dbl_outcome: StringName = &""

	func copy() -> Offer:
		var o := Offer.new()
		o.seq = seq
		o.card = card
		o.who = who
		o.n = n
		o.opened = opened
		o.closes = closes
		o.from_depth = from_depth
		o.day = day
		o.votes = votes.duplicate()
		o.takers = takers.duplicate()
		o.picks = picks.duplicate()
		o.state = state
		o.decided_at = decided_at
		o.carrier = carrier
		o.roll = roll
		o.outcome = outcome
		o.dbl_card = dbl_card
		o.dbl_n = dbl_n
		o.dbl_state = dbl_state
		o.dbl_roll = dbl_roll
		o.dbl_outcome = dbl_outcome
		return o

## The run's deal. Replaced, never edited (copy()).
class DealState extends RefCounted:
	## Cards dealt so far this run.
	var seq := 0
	## This ride's card, or null (no ride, or a ride with no card).
	var offer: Offer = null
	## What holds on the floor reached: [{face, carrier, seq}] for depth/day; and the second opinion's one use.
	var active: Array = []
	var depth := -1
	var day := -1
	var second_by := ""
	var second_at := -1.0
	## The last offer, kept after arrival so every screen can still print what came of it (null before any).
	var last: Offer = null

	func copy() -> DealState:
		var d := DealState.new()
		d.seq = seq
		d.offer = offer
		d.active = active.duplicate()
		d.depth = depth
		d.day = day
		d.second_by = second_by
		d.second_at = second_at
		d.last = last
		return d

# ---------------------------------------------------------------------------------------------
# The numbers.

static func in_deck(tuning: Settings.Values, card: StringName) -> bool:
	return Settings.i(tuning, StringName("deal.%s_in" % card), 1) == 1

static func odds_of(tuning: Settings.Values, card: StringName) -> int:
	return clampi(Settings.i(tuning, StringName("deal.%s" % card), int(CARD[card]["odds"])), 1, TWELFTHS - 1)

static func ride_time(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"deal.ride", RIDE)

static func double_on(tuning: Settings.Values) -> bool:
	return Settings.i(tuning, &"deal.double_in", 1) == 1

static func double_odds(tuning: Settings.Values, card: StringName) -> int:
	return maxi(1, odds_of(tuning, card) - Settings.i(tuning, &"deal.double_drop", DOUBLE_DROP))

static func second_time(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"deal.second_time", SECOND_TIME)

## A floor's place in its cycle of seven (1 to 7).
static func cycle_pos(depth: int) -> int:
	return 1 + (depth - 1) % Places.CYCLE_FLOORS

## Whether the ride from `from_depth` to the floor below deals a card (see the header).
static func deals_on(from_depth: int) -> bool:
	var to := from_depth + 1
	return from_depth >= 1 and cycle_pos(to) >= 2 and cycle_pos(to) <= 5

## Whether Express may be dealt on the ride from `from_depth`: the floor skipped is the 2nd to the 4th of its
## cycle and the floor reached a Clinic or the Annex (see the header).
static func express_safe(seed: String, from_depth: int, deck: Array) -> bool:
	var skipped := from_depth + 1
	var reached := from_depth + 2
	if cycle_pos(skipped) < 2 or cycle_pos(skipped) > 4 or cycle_pos(reached) < 3 or cycle_pos(reached) > 5:
		return false
	var place := Places.place_at(seed, reached, deck)
	return place == Places.CLINIC or place == Places.ANNEX

## The cards this ride may deal, in deck order.
static func eligible(tuning: Settings.Values, seed: String, from_depth: int, deck: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for c in CARDS:
		if not in_deck(tuning, c):
			continue
		if c == &"express" and not express_safe(seed, from_depth, deck):
			continue
		out.append(c)
	return out

# ---------------------------------------------------------------------------------------------
# Dealing, voting, rolling.

## The card for the ride from `from_depth` on day `day` (a pure function of the seed), or &"" for none.
static func draw(tuning: Settings.Values, seed: String, day: int, from_depth: int, deck: Array) -> StringName:
	var cards := eligible(tuning, seed, from_depth, deck)
	if cards.is_empty():
		return &""
	return Rng.make_rng("deal:%s:%d:%d" % [seed, day, from_depth]).pick(cards)

## The second card of a double or nothing: from the same cards, never the first (&"" when none is left).
static func draw_double(tuning: Settings.Values, seed: String, day: int, from_depth: int, deck: Array, first: StringName) -> StringName:
	var cards := eligible(tuning, seed, from_depth, deck)
	cards.erase(first)
	if cards.is_empty():
		return &""
	return Rng.make_rng("dealdouble:%s:%d:%d" % [seed, day, from_depth]).pick(cards)

## The roll of a card: a whole number 0 to 11, a pure function of the seed. `label` "dealroll" or "dealroll2".
static func roll_of(label: String, seed: String, day: int, from_depth: int) -> int:
	return Rng.make_rng("%s:%s:%d:%d" % [label, seed, day, from_depth]).int_in(0, TWELFTHS - 1)

## A new card on this ride, or the state unchanged when the ride deals none.
static func open(st: DealState, tuning: Settings.Values, seed: String, day: int, from_depth: int, deck: Array, t: float, ride: float) -> DealState:
	var out := st.copy()
	out.offer = null
	if not deals_on(from_depth):
		return out
	var card := draw(tuning, seed, day, from_depth, deck)
	if card == &"":
		return out
	var o := Offer.new()
	out.seq = st.seq + 1
	o.seq = out.seq
	o.card = card
	o.who = CARD[card]["who"]
	o.n = odds_of(tuning, card)
	o.opened = t
	o.closes = t + ride
	o.from_depth = from_depth
	o.day = day
	out.offer = o
	return out

## The crew's answers this tick. `crew`: the living players in the car, in seat order. `answers`: {player id:
## [offer seq, choice (0 none, TAKE, PASS), picked player id or "", double (0 none, 1 draw, 2 keep), use seq]}.
## `flares`: {player id: flares left}. Returns the new state and appends what happened to `events`.
static func answer(st: DealState, tuning: Settings.Values, seed: String, deck: Array, crew: Array[String], answers: Dictionary, flares: Dictionary, t: float, events: Array[Dictionary]) -> DealState:
	if st.offer == null:
		return st
	var o := st.offer
	if o.state == &"open":
		var changed := false
		var no := o.copy()
		for id in crew:
			var a: Variant = answers.get(id)
			if not a is Array or (a as Array).size() < 5 or int(a[0]) != o.seq:
				continue
			var choice := int(a[1])
			if choice != TAKE and choice != PASS:
				continue
			if int(no.votes.get(id, 0)) != choice:
				no.votes[id] = choice
				changed = true
				if choice == TAKE and not no.takers.has(id):
					no.takers.append(id)
				elif choice == PASS:
					no.takers.erase(id)
			if choice == TAKE:
				var pick := str(a[2])
				if pick != "" and crew.has(pick) and str(no.picks.get(id, "")) != pick:
					no.picks[id] = pick
					changed = true
		# Players who left the car's crew no longer count.
		for id: String in no.votes.keys():
			if not crew.has(id):
				no.votes.erase(id)
				no.takers.erase(id)
				no.picks.erase(id)
				changed = true
		if not changed:
			return st
		var takes := 0
		var passes := 0
		for id: String in no.votes:
			if int(no.votes[id]) == TAKE:
				takes += 1
			else:
				passes += 1
		var n := crew.size()
		var out := st.copy()
		if n > 0 and takes * 2 > n:
			no.state = &"taken"
			no.decided_at = t
			no.carrier = carrier_of(no, crew, flares)
			no.roll = roll_of("dealroll", seed, no.day, no.from_depth)
			no.outcome = &"boon" if no.roll < no.n else &"curse"
			events.append({"type": "dealTaken", "t": t, "seq": no.seq, "card": String(no.card), "carrier": no.carrier, "roll": no.roll, "outcome": String(no.outcome)})
			if no.outcome == &"boon" and double_on(tuning):
				var second := draw_double(tuning, seed, no.day, no.from_depth, deck, no.card)
				if second != &"":
					no.dbl_card = second
					no.dbl_n = double_odds(tuning, second)
					no.dbl_state = &"offered"
		elif n > 0 and passes * 2 >= n:
			no.state = &"passed"
			no.decided_at = t
			events.append({"type": "dealPassed", "t": t, "seq": no.seq, "card": String(no.card)})
		out.offer = no
		return out
	if o.state == &"taken" and o.dbl_state == &"offered":
		var a: Variant = answers.get(o.carrier)
		if crew.has(o.carrier) and a is Array and (a as Array).size() >= 5 and int(a[0]) == o.seq and int(a[3]) in [1, 2]:
			var no := o.copy()
			var out := st.copy()
			if int(a[3]) == 1:
				no.dbl_state = &"taken"
				no.dbl_roll = roll_of("dealroll2", seed, no.day, no.from_depth)
				no.dbl_outcome = &"boon" if no.dbl_roll < no.dbl_n else &"curse"
				events.append({"type": "dealDoubled", "t": t, "seq": no.seq, "card": String(no.dbl_card), "carrier": no.carrier, "roll": no.dbl_roll, "outcome": String(no.dbl_outcome)})
			else:
				no.dbl_state = &"declined"
			out.offer = no
			return out
	return st

## Who carries offer `o` (see the header). `crew` in seat order.
static func carrier_of(o: Offer, crew: Array[String], flares: Dictionary) -> String:
	var first := o.takers[0] if not o.takers.is_empty() else (crew[0] if not crew.is_empty() else "")
	match o.who:
		WHO_VOTE:
			var counts := {}
			for id: String in o.picks:
				if int(o.votes.get(id, 0)) == TAKE:
					var p := str(o.picks[id])
					counts[p] = int(counts.get(p, 0)) + 1
			var best := ""
			var best_n := 0
			var tie := false
			for id in crew:
				var c := int(counts.get(id, 0))
				if c > best_n:
					best = id
					best_n = c
					tie = false
				elif c == best_n and c > 0:
					tie = true
			return best if best != "" and not tie else first
		WHO_FLARES:
			var best := ""
			var best_n := -1
			for id in crew:
				var c := int(flares.get(id, 0))
				if c > best_n:
					best = id
					best_n = c
			return best if best != "" else first
	return first

## Whether nothing is left to choose on offer `o`: passed, or taken with no double waiting.
static func settled(o: Offer) -> bool:
	return o.state == &"passed" or (o.state == &"taken" and o.dbl_state != &"offered")

## The state with the ride's card now closing at `closes` (the car arrives then).
static func with_closes(st: DealState, closes: float) -> DealState:
	var out := st.copy()
	out.offer = st.offer.copy()
	out.offer.closes = closes
	return out

## The faces an offer lands, as [face, carrier] pairs (empty: passed, or not decided).
static func faces_of(o: Offer) -> Array:
	if o == null or o.state != &"taken":
		return []
	var c1: Dictionary = CARD[o.card]
	var first: Array = [[c1["boon"] if o.outcome == &"boon" else c1["curse"], o.carrier]]
	if o.dbl_state != &"taken":
		return first
	var c2: Dictionary = CARD[o.dbl_card]
	if o.dbl_outcome == &"boon":
		return first + [[c2["boon"], o.carrier]]
	return [[c2["curse"], o.carrier]]

## The floor the car stops at after the ride from `from_depth`: one more, or two with an Express landed.
static func arrival_depth(st: DealState, from_depth: int) -> int:
	if st == null or st.offer == null:
		return from_depth + 1
	for f: Array in faces_of(st.offer):
		if f[0] == &"express" or f[0] == &"express_awake":
			return from_depth + 2
	return from_depth + 1

## The ride is over: an open card is passed, a double not drawn is kept, and what landed holds on floor
## `depth` of day `day` (and nowhere else).
static func arrive(st: DealState, depth: int, day: int, t: float, events: Array[Dictionary]) -> DealState:
	var out := st.copy()
	out.active = []
	out.depth = depth
	out.day = day
	out.second_by = ""
	out.second_at = -1.0
	if st.offer != null:
		var o := st.offer
		if o.state == &"open" or o.dbl_state == &"offered":
			o = o.copy()
			if o.state == &"open":
				o.state = &"passed"
				o.decided_at = t
				events.append({"type": "dealPassed", "t": t, "seq": o.seq, "card": String(o.card)})
			if o.dbl_state == &"offered":
				o.dbl_state = &"declined"
		for f: Array in faces_of(o):
			out.active.append({"face": f[0], "carrier": f[1], "seq": o.seq})
		if not out.active.is_empty():
			events.append({"type": "dealLanded", "t": t, "seq": o.seq, "depth": depth, "faces": faces_wire(out.active)})
		out.last = o
	out.offer = null
	return out

## The second opinion's one use, by `id` at `t` (the state unchanged when there is none to use).
static func use_second(st: DealState, id: String, depth: int, day: int, t: float, events: Array[Dictionary]) -> DealState:
	if st.second_by != "" or face_carrier(st, &"second", depth, day) == "":
		return st
	var out := st.copy()
	out.second_by = id
	out.second_at = t
	events.append({"type": "dealSecondUsed", "t": t, "playerId": id})
	return out

# ---------------------------------------------------------------------------------------------
# What holds on a floor.

## The carrier of `face` on floor `depth` of day `day`, or "" when it does not hold there.
static func face_carrier(st: DealState, face: StringName, depth: int, day: int) -> String:
	if st == null or st.depth != depth or st.day != day:
		return ""
	for a: Dictionary in st.active:
		if a["face"] == face:
			return str(a["carrier"])
	return ""

static func holds(st: DealState, face: StringName, depth: int, day: int) -> bool:
	return face_carrier(st, face, depth, day) != ""

## What a reading closed by `player_id` on this floor pays, times.
static func pay_mult(st: DealState, tuning: Settings.Values, depth: int, day: int, player_id: String) -> float:
	var m := 1.0
	if st == null or st.depth != depth or st.day != day:
		return m
	for a: Dictionary in st.active:
		match a["face"]:
			&"hazard":
				if str(a["carrier"]) == player_id:
					m *= Settings.f(tuning, &"deal.hazard_pay", HAZARD_PAY)
			&"dark_pay":
				m *= Settings.f(tuning, &"deal.dark_pay", DARK_PAY)
			&"express", &"express_awake":
				m *= Settings.f(tuning, &"deal.express_pay", EXPRESS_PAY)
	return m

## How loud `player_id`'s footsteps are to a resident that hears, times.
static func footstep_scale(st: DealState, tuning: Settings.Values, depth: int, day: int, player_id: String) -> float:
	if face_carrier(st, &"squeak", depth, day) == player_id and player_id != "":
		return Settings.f(tuning, &"deal.squeak_loud", SQUEAK_LOUD)
	return 1.0

# ---------------------------------------------------------------------------------------------
# The words. Every line the card and the outcome print, and the intercom's subtitles.

## "1 in 2" for `n` twelfths.
static func fraction(n: int) -> String:
	var g := _gcd(n, TWELFTHS)
	return "%d in %d" % [n / g, TWELFTHS / g]

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var r := a % b
		a = b
		b = r
	return maxi(1, a)

## The odds as the back of the card prints them: "1 in 2: HAZARD PAY. 1 in 2: SQUEAKY SOLES."
static func odds_line(card: StringName, n: int) -> String:
	var c: Dictionary = CARD[card]
	return "%s: %s. %s: %s." % [fraction(n), FACE_NAME[c["boon"]], fraction(TWELFTHS - n), FACE_NAME[c["curse"]]]

## What a face does, in one plain line. `name` the carrier's name ("" before one is named: "THE CARRIER").
static func face_line(face: StringName, name: String, tuning: Settings.Values) -> String:
	var who := name.to_upper() if name != "" else "THE CARRIER"
	match face:
		&"hazard":
			return "%s'S TAPES PAY X%s" % [who, _x(Settings.f(tuning, &"deal.hazard_pay", HAZARD_PAY))]
		&"squeak":
			return "%s'S SHOES SQUEAK ALL FLOOR" % who
		&"torch":
			return "%s'S LIGHT IS A NOVELTY TORCH" % who
		&"second":
			return "ONE %d-SECOND LOOK THROUGH A CREWMATE'S EYES" % int(second_time(tuning))
		&"dark_pay":
			return "THE NEXT FLOOR IS DARK AND PAYS X%s" % _x(Settings.f(tuning, &"deal.dark_pay", DARK_PAY))
		&"dark":
			return "THE NEXT FLOOR IS DARK, FOR NOTHING"
		&"express":
			return "SKIP A FLOOR. THE ONE AFTER PAYS X%s" % _x(Settings.f(tuning, &"deal.express_pay", EXPRESS_PAY))
		&"express_awake":
			return "SKIP A FLOOR, PAYS X%s, AND IT IS AWAKE" % _x(Settings.f(tuning, &"deal.express_pay", EXPRESS_PAY))
	return ""

static func _x(v: float) -> String:
	return ("%.2f" % v).trim_suffix("0").trim_suffix("0").trim_suffix(".")

## Who carries it, as the card prints it.
static func who_line(who: StringName) -> String:
	match who:
		WHO_VOTE:
			return "CARRIED BY: SOMEONE THE CREW PICKS"
		WHO_FLARES:
			return "CARRIED BY: WHOEVER HAS THE MOST FLARES LEFT"
	return "CARRIED BY: WHOEVER TAKES IT FIRST"

## The intercom's reading of a card (the subtitle; lines to record are in the ticket).
static func read_line(card: StringName) -> String:
	match card:
		&"squeak":
			return "Today's complimentary offer: Squeaky Soles. Whoever takes it first wears them. Odds are on the back."
		&"torch":
			return "Today's offer: the Novelty Torch. The crew chooses who holds it. Odds are on the back."
		&"second":
			return "Today's offer: a Second Opinion. The risk goes to whoever is hoarding flares. Odds are on the back."
		&"dark":
			return "Today's offer: Lights Out. Hazard pay may apply. Whoever takes it first takes the blame."
		&"express":
			return "Today's offer: the Express. Fewer floors, more money. The crew chooses who answers for it."
	return ""

## The intercom's word on how it went.
static func outcome_line(face: StringName, name: String) -> String:
	var n := name if name != "" else "Your carrier"
	match face:
		&"hazard":
			return "Congratulations, %s. Hazard pay is now in effect." % n
		&"squeak":
			return "Commiserations, %s. Your new shoes are very expressive." % n
		&"torch":
			return "%s has been issued a Novelty Torch. Please return it in working order." % n
		&"second":
			return "A Second Opinion is available on the next floor. It may be used once."
		&"dark_pay":
			return "Lights Out has been approved. Hazard pay applies to everything."
		&"dark":
			return "Lights Out has been approved. Hazard pay has not."
		&"express":
			return "Express service confirmed. Please do not wave at the floor we skip."
		&"express_awake":
			return "Express service confirmed. The next floor has been told you are coming."
	return ""

static func passed_line() -> String:
	return "Offer declined. The company respects your caution and has noted it."

static func double_line() -> String:
	return "Feeling lucky? The offer may be doubled. Or not."

## The landed faces as the wire and the events carry them: [[face index, carrier], ...].
static func faces_wire(active: Array) -> Array:
	var out: Array = []
	for a: Dictionary in active:
		out.append([FACES.find(a["face"]), str(a["carrier"])])
	return out

# ---------------------------------------------------------------------------------------------
# The block every screen reads (net/host.gd deal_block, net/protocol.gd "deal"): plain values only.

## The readable block for state `st`, or null when there is nothing to show.
static func block(st: DealState) -> Variant:
	if st == null:
		return null
	var o := st.offer if st.offer != null else st.last
	if o == null and st.active.is_empty():
		return null
	var out := {"live": st.offer != null, "depth": st.depth, "day": st.day, "secondBy": st.second_by, "secondAt": st.second_at,
		"active": faces_wire(st.active)}
	if o != null:
		var votes: Array = []
		for id: String in o.votes:
			votes.append([id, int(o.votes[id]), str(o.picks.get(id, ""))])
		votes.sort()
		out["offer"] = {"seq": o.seq, "card": CARDS.find(o.card), "n": o.n, "opened": o.opened, "closes": o.closes,
			"from": o.from_depth, "state": STATES.find(o.state), "carrier": o.carrier, "roll": o.roll,
			"outcome": 1 if o.outcome == &"boon" else (2 if o.outcome == &"curse" else 0), "votes": votes,
			"dbl": [CARDS.find(o.dbl_card), o.dbl_n, DOUBLE_STATES.find(o.dbl_state), o.dbl_roll,
				1 if o.dbl_outcome == &"boon" else (2 if o.dbl_outcome == &"curse" else 0)]}
	return out

## The block on the wire (JSON-safe, compact).
static func enc(b: Dictionary) -> Array:
	var a: Array = [1 if b["live"] else 0, int(b["depth"]), int(b["day"]), str(b["secondBy"]), _q3(float(b["secondAt"])), b["active"].duplicate(true)]
	if b.has("offer"):
		var o: Dictionary = b["offer"]
		a.append([int(o["seq"]), int(o["card"]), int(o["n"]), _q3(float(o["opened"])), _q3(float(o["closes"])), int(o["from"]),
			int(o["state"]), str(o["carrier"]), int(o["roll"]), int(o["outcome"]), o["votes"].duplicate(true), o["dbl"].duplicate()])
	return a

static func _q3(x: float) -> float:
	return roundf(x * 1000.0) / 1000.0

## The block from the wire, checked; null when anything is out of shape (the snapshot is then refused).
static func dec(v: Variant) -> Variant:
	if not v is Array:
		return null
	var a: Array = v
	if a.size() != 6 and a.size() != 7:
		return null
	if not (_num(a[0]) and _num(a[1]) and _num(a[2]) and a[3] is String and _num(a[4]) and a[5] is Array):
		return null
	var active: Array = []
	for f: Variant in a[5]:
		if not f is Array or (f as Array).size() != 2 or not _num(f[0]) or not f[1] is String:
			return null
		var k := int(f[0])
		if k < 0 or k >= FACES.size():
			return null
		active.append([k, str(f[1])])
	var out := {"live": int(a[0]) == 1, "depth": int(a[1]), "day": int(a[2]), "secondBy": str(a[3]), "secondAt": float(a[4]), "active": active}
	if a.size() == 7:
		if not a[6] is Array or (a[6] as Array).size() != 12:
			return null
		var o: Array = a[6]
		for k: int in [0, 1, 2, 3, 4, 5, 6, 8, 9]:
			if not _num(o[k]):
				return null
		if not o[7] is String or not o[10] is Array or not o[11] is Array or (o[11] as Array).size() != 5:
			return null
		var card := int(o[1])
		if card < 0 or card >= CARDS.size() or int(o[6]) < 0 or int(o[6]) >= STATES.size() or int(o[2]) < 1 or int(o[2]) >= TWELFTHS:
			return null
		var votes: Array = []
		for r: Variant in o[10]:
			if not r is Array or (r as Array).size() != 3 or not r[0] is String or not _num(r[1]) or not r[2] is String:
				return null
			votes.append([str(r[0]), int(r[1]), str(r[2])])
		var dbl: Array = o[11]
		for k in 5:
			if not _num(dbl[k]):
				return null
		if int(dbl[0]) < -1 or int(dbl[0]) >= CARDS.size() or int(dbl[2]) < 0 or int(dbl[2]) >= DOUBLE_STATES.size():
			return null
		out["offer"] = {"seq": int(o[0]), "card": card, "n": int(o[2]), "opened": float(o[3]), "closes": float(o[4]), "from": int(o[5]),
			"state": int(o[6]), "carrier": str(o[7]), "roll": int(o[8]), "outcome": int(o[9]), "votes": votes,
			"dbl": [int(dbl[0]), int(dbl[1]), int(dbl[2]), int(dbl[3]), int(dbl[4])]}
	return out

static func _num(x: Variant) -> bool:
	return (x is int or x is float) and is_finite(float(x))
