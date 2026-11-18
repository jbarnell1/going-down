# The game's own rules around the run, applied by the host. Port of src/game/runHost.ts (HostRules,
# startSpot, startBody, parkedOrderly). Work-arounds for gaps in the run's logic, kept visible here:
#  - create_run always starts at depth 1. A depth above 1 swaps in floor N's plan, car and Orderly.
#  - The run's deck (sim/places.gd): Clinic only unless one is given; the game (server/room.gd,
#    net/local_room.gd) gives Places.FULL. prepare() puts it on the run and makes floor N with it.
#  - run.gd wipes the run when its last active player is caught. The design says a catch is a wipe
#    only when the car is gone and nobody can call it; while the car is here or coming, a catch is
#    the "YOU WENT DOWN" placeholder and the player must still be able to finish the run. So when a
#    catch would wipe and the car was not 'away', the tick is re-run without the caught players to
#    recover the run's own phase, call and blink; the Orderly and crew are kept from the real tick
#    (the dropped tape, the dormant Orderly), and the players are put back on their feet ('ok').
#  - entity off: the run always has an Orderly. The host parks it, dormant for ever, where it starts.
#    On the Playroom the Minder's rules are off too (sim/run.gd seek_off): no count ever starts.
#  - The soft catch above is the Orderly's. A Playroom's found, taken and down players are not "caught"
#    events (sim/run.gd), so there a crew all found or down is a wipe, as playarea.md 12 says.
#  - A test may press the call button "from the landing" wherever the player stands (force_call).
#  - The day loop (sim/run.gd, docs/floors/prison.md P7): off unless asked (`days`); the game's rooms
#    (server/room.gd, net/local_room.gd) ask for it, so BANK rides up to the prison and bed starts the
#    next day. prepare() turns it on before the first tick. With the resident off, every new day's
#    resident is parked too.
#  - The floor quota (sim/run.gd quota, North Star C9): off unless asked (`quota`); the game's rooms ask
#    for it, so the call button does nothing until the crew has recorded enough on the floor. prepare()
#    turns it on before the first tick, after any depth above 1, so it is that floor's quota. With the
#    resident off nothing can ever be recorded, so the quota would lock the lift for good: it stays off.
#    Test-only: `quota=N` with `auto=1` caps every floor's quota at N (quota_cap_by_arg), so a scripted
#    playthrough (tools/play_quota.mjs) meets it with a reading or two.
#  - The Annex's marks and notes (sim/run.gd annex) are the run's own: the soft catch keeps them from the
#    real tick (the catch's note), and a forced call passes the mark and peel keys on like the rest.
#  - Down first, then out (sim/run.gd downs, North Star B6): off unless asked (`downs`); the game's rooms ask
#    for it, so a catch puts the player down where they stood for ten seconds, a crewmate holding F beside
#    them for three puts them back up, and otherwise they are out until the car next rides down. prepare()
#    turns it on before the first tick. With it on the run's own down replaces the soft catch above (a catch
#    is never a wipe on its own tick, so the soft catch never fires): a crew all out is a wipe, wherever the
#    car is, because nobody is left to board it.
#  - Two-watcher Stillness (sim/run.gd two_watchers, T19a): off unless asked (`watchers`); the game's server
#    room asks for it, so from three up players it takes two watchers to hold a Stillness resident. prepare()
#    turns it on before the first tick.
#  - Relocation (sim/run.gd relocation, sim/relocate.gd, T19e): off unless asked (`relocation`); the game's rooms
#    ask for it (the server's always, playing alone with the game's deck), so a resident may leave where nobody
#    can see it and arrive where nobody can, near a player. prepare() turns it on before the first tick.
#  - The owner's 17 Nov changes (sim/run.gd long_dark, paced, car_waits): off unless asked (`long_dark`,
#    `paced`, `car_waits`); the game's rooms ask for all three, so the blackout is longer, the tank is bigger
#    and the residents hunt faster to match, and the car waits for whoever is aboard, boards for 30 s and
#    leaves anyone out for the day. prepare() turns them on before the first tick.
#  - Lonely (sim/run.gd lonely, sim/lonely.gd, T19c): off unless asked (`lonely`); the game's rooms ask for it
#    (the server's always, playing alone with the game's deck), so the Annex's Temp carries its own mechanic
#    instead of Stillness. prepare() turns it on before the first tick.
#  - The Playroom tuned from the owner's first play (sim/run.gd playroom_tuned, sim/seek.gd T15m): off unless
#    asked (`playroom_tuned`); the game's rooms ask for it, so there are 30-45 s to hide, an anger bar, and the
#    Minder grabs anyone within 1 m outside a count. prepare() turns it on before the first tick.
#  - The day quota's lock (sim/run.gd day_lock, FD2): off unless asked (`day_lock`, the last parameter); the
#    game's rooms ask for it together with the floor quota, so BANK is refused until the crew has earned the
#    day quota. prepare() turns it on before the first tick, and only when the run has days and the floor
#    quota (with nothing to record, or the test switch quota=0, it stays off and a short BANK is a missed
#    day as before). The soft catch keeps the day's earned from the real tick, like the floor's.
#  - Solid furniture (sim/run.gd furniture, sim/furniture.gd, FD7): off unless asked (`furniture`); the game's rooms
#    ask for it (the server's always, playing alone with the game's deck), so players slide along the Clinic's and
#    the Annex's chairs, beds, cabinets and desks instead of walking through them. prepare() turns it on before the
#    first tick.
#  - Findables (sim/run.gd findables, sim/findables.gd, FD9): off unless asked (`findables`, the last parameter); the
#    game's rooms ask for it (the server's always, playing alone with the game's deck), so the Clinic's and the
#    Annex's drawers, gurneys, lockers, copiers and boxes can be searched (F held) for credits, notes and cartons.
#    prepare() turns it on before the first tick. The soft catch keeps what was opened and found on the real tick.
#  - The four-slot inventory (sim/run.gd inventory, sim/inventory.gd, S1): off unless asked (`inventory`, the last
#    parameter); the game's rooms ask for it. prepare() turns it on before the first tick. The soft catch keeps the
#    bags and the pickups of the real tick (what the caught player carried fell where they were caught).
#  - The shop and the cabinet (sim/run.gd shop, sim/shop.gd, S2): off unless asked (`shop`, the last parameter); the
#    game's rooms ask for it, and it needs the inventory. prepare() turns it on before the first tick. The soft catch
#    keeps the cabinets, the lit things and the wallets of the real tick.
# Typed and immutable like godot/sim: a step never edits the state it was given.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Instr = preload("res://sim/instrument.gd")

## Where a player stands alone in the car at the start: the middle, so the doorway is straight ahead.
const START_U := Run.CAR_DEPTH / 2.0

## Catches turned from a wipe into the placeholder (see the header). (TypeScript: softCatches)
var soft_catches := 0
## Players put back on their feet since the glue last asked.
var revived: Array[String] = []
var _forced_id := ""
var _forced_body: Move.Body = null
var _entity_on: bool
var _depth: int
## The places the run's floors are drawn from.
var deck: Array[StringName]
## The day loop (off unless asked).
var days: bool
## The floor quota (off unless asked; never with the resident off).
var quota: bool
## Test-only: every floor's quota is at most this (0: no cap). See quota_cap_by_arg.
var _quota_cap := 0
## Down first, then out (off unless asked).
var downs: bool
## Two-watcher Stillness (off unless asked).
var watchers: bool
## Relocation (off unless asked).
var relocation: bool
## The owner's 17 Nov changes (off unless asked): the long dark, paced, the car waits.
var long_dark: bool
var paced: bool
var car_waits: bool
## Lonely, the Temp's own mechanic (off unless asked).
var lonely: bool
## The Playroom tuned from the owner's first play (off unless asked; sim/run.gd playroom_tuned, T15m).
var playroom_tuned: bool
## The day quota's lock (off unless asked; only with days and the floor quota both on).
var day_lock: bool
## Solid furniture (off unless asked; sim/run.gd furniture, FD7).
var furniture: bool
## Findables (off unless asked; sim/run.gd findables, FD9).
var findables: bool
## The four-slot inventory (off unless asked; sim/run.gd inventory, S1).
var inventory: bool
## Restored wall furniture (T20j), with solid furniture.
var furniture_layout: bool
## Residents route around the floor's shared solid footprints (off unless asked).
var resident_navigation: bool
## The shop and the cabinet (off unless asked; sim/run.gd shop, S2).
var shop: bool

func _init(entity_on: bool, depth: int, deck_: Array = [], days_: bool = false, quota_: bool = false, downs_: bool = false,
		watchers_: bool = false, relocation_: bool = false, long_dark_: bool = false, paced_: bool = false, car_waits_: bool = false,
		lonely_: bool = false, playroom_tuned_: bool = false, day_lock_: bool = false, furniture_: bool = false, findables_: bool = false,
		inventory_: bool = false, furniture_layout_: bool = false, resident_navigation_: bool = false,
		shop_: bool = false) -> void:
	shop = shop_
	inventory = inventory_
	findables = findables_
	furniture_layout = furniture_layout_
	resident_navigation = resident_navigation_
	playroom_tuned = playroom_tuned_
	furniture = furniture_
	relocation = relocation_
	lonely = lonely_
	day_lock = day_lock_
	_entity_on = entity_on
	_depth = depth
	deck = Run.deck_of(deck_)
	days = days_
	quota = quota_
	_quota_cap = quota_cap_by_arg() if quota_ else 0
	downs = downs_
	watchers = watchers_
	long_dark = long_dark_
	paced = paced_
	car_waits = car_waits_

## Where player `i` of `n` stands in the car at the start (car-local u, v).
static func start_spot(i: int, n: int) -> PackedFloat64Array:
	if n <= 1:
		return PackedFloat64Array([START_U, 0.0])
	var spots: Array[PackedFloat64Array] = [
		PackedFloat64Array([1.3, -1.0]), PackedFloat64Array([1.3, 1.0]),
		PackedFloat64Array([2.7, -1.0]), PackedFloat64Array([2.7, 1.0]),
	]
	return spots[i % spots.size()]

static func start_body(car: Run.CarGeometry, i: int, n: int) -> Move.Body:
	var uv := start_spot(i, n)
	return Run.car_body(car, uv[0], uv[1])

## A dormant Orderly that never wakes, standing where the floor's Orderly would start (the floor's own
## resident, in its own body).
static func parked_orderly(state: Run.RunState) -> Entity.OrderlyState:
	var o := Places.create_resident(state.plan)
	o.mode = &"dormant"
	o.dormant_left = INF
	return o

## The first state of a run (create_run's, adjusted).
func prepare(s0: Run.RunState) -> Run.RunState:
	var s := s0
	if s.deck != deck:
		s = s.copy()
		s.deck = deck
	if days and not s.days:
		s = Run.with_days(s)
	if _depth > 1:
		var plan := Places.generate(s.seed, _depth, deck)
		s = s.copy()
		s.depth = _depth
		s.plan = plan
		s.car = Run.car_geometry(plan)
		s.orderly = Places.create_resident(plan)
		s.entity_id = Places.entity_id(plan.place, _depth)
	var n := s.players.size()
	var bodies := {}
	for i in n:
		bodies[s.players[i].id] = start_body(s.car, i, n)
	s = s.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		if bodies.has(p.id):
			np.body = bodies[p.id]
		players.append(np)
	s.players = players
	if _depth > 1:
		var c := s.crew.copy()
		var members: Array[Instr.CrewMember] = []
		for m in s.crew.members:
			var nm := m.copy()
			nm.body = bodies[m.id] if bodies.has(m.id) else null
			members.append(nm)
		c.members = members
		s = s.copy()
		s.crew = c
	if not _entity_on:
		s = s.copy()
		s.orderly = parked_orderly(s)
		# The Playroom's Minder too: no count, no search (sim/run.gd seek_off).
		s.seek_off = true
	if quota and _entity_on and not s.quota:
		s = Run.with_quota(s)
	if downs and not s.downs:
		s = Run.with_downs(s)
	if watchers and not s.two_watchers:
		s = Run.with_two_watchers(s)
	if relocation and not s.relocation:
		s = Run.with_relocation(s)
	if long_dark and not s.long_dark:
		s = Run.with_long_dark(s)
	if paced and not s.paced:
		s = Run.with_paced(s)
	if car_waits and not s.car_waits:
		s = Run.with_car_waits(s)
	if lonely and not s.lonely:
		s = Run.with_lonely(s)
	if playroom_tuned and not s.playroom_tuned:
		s = Run.with_playroom_tuned(s)
	# The day lock needs something to earn: only with days and the floor quota on (so never with the
	# resident off, and never with the test switch quota=0).
	if day_lock and s.days and s.quota and not s.day_lock:
		s = Run.with_day_lock(s)
	if furniture and not s.furniture:
		s = Run.with_furniture(s)
	if furniture_layout and s.furniture and not s.furniture_layout:
		s = Run.with_furniture_layout(s)
	if findables and not s.findables:
		s = Run.with_findables(s)
	if inventory and not s.inventory:
		s = Run.with_inventory(s)
	if resident_navigation and not s.resident_navigation:
		s = Run.with_resident_navigation(s)
	if shop and s.inventory and not s.shop:
		s = Run.with_shop(s)
	return _capped(s)

## Test-only: `quota=N` (a whole number above 0, as a desktop or server argument after `--` or the web
## page's ?quota=N), honoured only together with `auto=1`: every floor's quota is at most N credits, so a
## scripted playthrough (tools/play_quota.mjs) can meet it with a reading or two. 0 when not asked.
static func quota_cap_by_arg() -> int:
	var cap := 0
	var auto := false
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("quota=") and a.substr(6).is_valid_int():
			cap = int(a.substr(6))
		auto = auto or a == "auto=1"
	if OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('quota') ?? ''", true))
		var au := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('auto') ?? ''", true))
		if q.is_valid_int():
			cap = int(q)
		auto = auto or au == "1"
	return cap if auto and cap > 0 else 0

## The state with this floor's quota at most the test cap (unchanged without one).
func _capped(s: Run.RunState) -> Run.RunState:
	if _quota_cap <= 0 or not s.quota or s.floor_needed <= _quota_cap:
		return s
	var c := s.copy()
	c.floor_needed = _quota_cap
	return c

## Test-only, and THE one reader of the floor a run starts on: runs start on floor N of the deck, so a check
## or a look at a deep place (the Arboretum is floor 5) need not ride down to it. 1 when not asked. Two
## spellings reach it, and both end as a room's first depth (server/room.gd `first_depth`, the depth
## net/local_room.gd gives its rules):
##  - a dedicated server (`server` true: server/server.gd): its argument `depth=N`, alone
##    (tools/exported_server_check.mjs passes depth=3);
##  - a client playing alone (`server` false: net/local_room.gd): `floor=N` (a desktop argument after `--`, or the
##    web page's ?floor=N), honoured only together with `auto=1`.
## Kept to the deck's fixed floors (sim/places.gd FIXED), whichever spelling asked.
static func start_depth_by_arg(server := false) -> int:
	var depth := 1
	var auto := server
	var key := "depth=" if server else "floor="
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with(key) and a.substr(key.length()).is_valid_int():
			depth = int(a.substr(key.length()))
		auto = auto or a == "auto=1"
	if not server and OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('floor') ?? ''", true))
		var au := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('auto') ?? ''", true))
		if q.is_valid_int():
			depth = int(q)
		auto = auto or au == "1"
	return clampi(depth, 1, Places.FIXED.size() - 1) if auto else 1

## Test-only: whether this server was started with `watchers=0` (an argument after `--`): Stillness is then
## held by one look at any crew size, as before T19a (tools/net_local.mjs; server/room.gd).
static func watchers_off_by_arg() -> bool:
	for raw in OS.get_cmdline_user_args():
		if raw.trim_prefix("--") == "watchers=0":
			return true
	return false

## Test-only: whether this process was started with the floor quota turned off, `quota=0` (a desktop or
## server argument after `--`, or the web page's ?quota=0). The scripted playthroughs (tools/play_*.mjs)
## pass it so their one reading is enough to call the lift; the quota itself is proved headless
## (tests/prop_quota_net.gd). `need_auto`: honoured only together with `auto=1` (the game's automation
## flag), so a player cannot turn it off by accident in a normal game.
static func quota_off_by_arg(need_auto: bool) -> bool:
	var off := false
	var auto := false
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		off = off or a == "quota=0"
		auto = auto or a == "auto=1"
	if OS.has_feature("web"):
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('quota') ?? ''", true))
		var au := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('auto') ?? ''", true))
		off = off or q == "0"
		auto = auto or au == "1"
	return off and (auto or not need_auto)

## Tests: the next tick presses the call button for `id` from `body`.
func force_call(id: String, body: Move.Body) -> void:
	_forced_id = id
	_forced_body = body

## One tick of the run, with the rules above.
func step(before: Run.RunState, raw: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
	var inputs := raw
	if _forced_body != null:
		var fid := _forced_id
		var fbody := _forced_body
		_forced_id = ""
		_forced_body = null
		inputs = []
		for i in raw:
			if i.id == fid:
				var ni := _copy_input(i)
				ni.body = Move.Body.make(fbody.x, fbody.z, fbody.level, fbody.y)
				ni.call = true
				inputs.append(ni)
			else:
				inputs.append(i)
	var r := Run.step_run(before, inputs, dt)
	var events := r.events
	var caught := {}
	var wiped := false
	for e in events:
		if e["type"] == "caught":
			caught[str(e["playerId"])] = true
		elif e["type"] == "wiped":
			wiped = true
	if not caught.is_empty() and wiped and before.phase != &"away":
		# Not a wipe by the design's rule: the car is here or coming. See the header.
		var kept: Array[Run.PlayerInput] = []
		for i in inputs:
			if not caught.has(i.id):
				kept.append(i)
		var alt := Run.step_run(before, kept, dt)
		var players: Array[Run.RunPlayer] = []
		for p in r.state.players:
			if caught.has(p.id):
				var np := p.copy()
				np.status = &"ok"
				players.append(np)
			else:
				players.append(p)
		var st := alt.state.copy()
		st.orderly = r.state.orderly
		st.crew = r.state.crew
		# The floor quota goes with the crew: the victim's reading closed as they were caught counts.
		st.floor_earned = r.state.floor_earned
		st.floor_by = r.state.floor_by
		st.floor_needed = r.state.floor_needed
		st.quota_met = r.state.quota_met
		# The day's earned likewise (FD2), and whether "dayMet" was said.
		st.day_earned = r.state.day_earned
		st.day_met = r.state.day_met
		# The Annex's marks and notes too: the catch's note was triggered by the real tick.
		st.annex = r.state.annex
		st.note_seq = r.state.note_seq
		# Findables (FD9): what was opened and found on the real tick (the credits ride on its crew's tapes).
		st.find = r.state.find
		st.lore_used = r.state.lore_used
		st.items = r.state.items
		# The inventory (S1): the bags and pickups of the real tick.
		st.bags = r.state.bags
		st.pickups = r.state.pickups
		st.pickups_plan = r.state.pickups_plan
		st.pickup_seq = r.state.pickup_seq
		# The shop (S2): the cabinets, what was lit, and what was bought, of the real tick.
		if st.shop:
			st.shop_state = r.state.shop_state
			st.wallets = r.state.wallets
		st.players = players
		st.summary = null
		var kept_events: Array[Dictionary] = []
		for e in events:
			if e["type"] != "wiped":
				kept_events.append(e)
		events = kept_events
		r = Run.RunStep.new()
		r.state = st
		r.events = events
		soft_catches += 1
		for id: String in caught:
			revived.append(id)
	var state := r.state
	if not _entity_on:
		for e in events:
			if e["type"] == "rodeDown" or e["type"] == "newDay":
				state = state.copy()
				state.orderly = parked_orderly(state)
				break
	var out := Run.RunStep.new()
	out.state = _capped(state)
	out.events = events
	return out

static func _copy_input(i: Run.PlayerInput) -> Run.PlayerInput:
	var n := Run.PlayerInput.make(i.id, i.body, i.eye, i.yaw, i.pitch, i.h_fov_deg, i.v_fov_deg)
	n.call = i.call
	n.hold_doors = i.hold_doors
	n.raised = i.raised
	n.pick_up = i.pick_up
	n.blind = i.blind
	n.use = i.use
	n.gait = i.gait
	n.hide_use = i.hide_use
	n.hide_fast = i.hide_fast
	n.peek = i.peek
	n.emote_sound = i.emote_sound
	n.voice = i.voice
	n.horn = i.horn
	n.light = i.light
	n.mark = i.mark
	n.peel = i.peel
	n.search = i.search
	n.search_fast = i.search_fast
	n.inv_select = i.inv_select
	n.inv_op = i.inv_op
	n.inv_arg = i.inv_arg
	return n
