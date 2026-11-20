# Playing alone: the room a server runs, on this machine. The same host (net/host.gd stepping the rules
# through net/host_rules.gd, exactly as server/room.gd does) and the same NetClient (net/client.gd) the
# game uses with friends, joined by two in-memory pipes (net/transport.gd Pipe) instead of a WebSocket:
# no socket, no passphrase, no delay beyond one frame. The game talks to it exactly as it talks to a
# RoomClient (it is one: poll, start_run, frame, client, status, people, my_id).
#
# What differs from the server's room, all of it for one player on their own machine:
#  - The player's own body is trusted (net/host.gd `trusted`: no speed check), so the test hooks
#    (teleport, walk at any pace) work alone; with friends the server checks every body.
#  - A run starts at once when asked (no lobby, nobody to wait for), and the next run's seed is the
#    seed with "-1", "-2", ... appended (as the single-player game always did). Ready-up alone: the player
#    is the host, and set_ready(true) (the controls card's I'M READY) starts the run at once.
#  - `time_scale` runs the room's clock (host and client together) faster or slower: tests only.
#  - The day loop (sim/run.gd days: BANK rides up to the prison, bed starts the next day) is on in the
#    game and off in tests: `days` true or false says so; left null it follows the game's deck (on when
#    Session.deck is Places.FULL, as client/main.gd sets it; tests leave Clinic only).
#  - The floor quota (sim/run.gd quota: the call button does nothing until the crew has recorded enough on
#    the floor) is the same: `quota` true, false, or null to follow the game's deck. With the resident off
#    (`entity_on` false) it is always off (net/host_rules.gd): nothing could ever be recorded. The
#    scripted playthroughs start the game with `auto=1 quota=0` to turn it off (HostRules.quota_off_by_arg).
#    The day quota's lock (sim/run.gd day_lock, FD2) follows it: on with the quota (and days), off with it.
#  - Down first, then out (sim/run.gd downs: a catch puts the player down for ten seconds, then out) is the
#    same again: `downs` true, false, or null to follow the game's deck. Alone nobody can heal you: down,
#    then out, then (with nobody left standing) the wipe.
#  - Relocation (sim/run.gd relocation, sim/relocate.gd: the resident may leave where nobody can see it and
#    arrive where nobody can) is the same again: `relocation` true, false, or null to follow the game's deck.
#  - The owner's 17 Nov changes (sim/run.gd long_dark, paced, car_waits) are the same once more: `owner_0833`
#    true, false, or null to follow the game's deck. The game's client draws a Stillness resident in the dark
#    too (net/client.gd draw_in_dark), on the same switch.
#  - Lonely (sim/run.gd lonely, sim/lonely.gd: the Temp's own mechanic) is the same again: `lonely` true, false,
#    or null to follow the game's deck. Alone you are always lonely, and it chases slower than you walk.
#  - The tuned Playroom (sim/run.gd playroom_tuned, sim/seek.gd T15m: 30-45 s to hide, the anger bar, the
#    grab at 1 m) is the same again: `playroom_tuned` true, false, or null to follow the game's deck.
#  - Solid furniture (sim/run.gd furniture, sim/furniture.gd, FD7) is the same again: `furniture` true, false, or
#    null to follow the game's deck.
#  - Findables (sim/run.gd findables, sim/findables.gd, FD9) are the same again: `findables` true, false, or null to
#    follow the game's deck.
#  - The four-slot inventory (sim/run.gd inventory, sim/inventory.gd, S1) is the same again: `inventory` true, false,
#    or null to follow the game's deck.
#  - The shop and the cabinet (sim/run.gd shop, sim/shop.gd, S2) are the same again: `shop` true, false, or null to
#    follow the game's deck.
#  - Live settings (docs/floors/live-settings.md LS3): the room owns a desk exactly as the server's room does
#    (net/tuning_desk.gd), and the player is the host. The game gives it the file user://settings.json
#    (open_settings); under automation (auto=1) it has none, so no scripted playthrough reads a saved change.
extends "res://net/room_client.gd"

const Profiles = preload("res://net/profiles.gd")
const SaveSlip = preload("res://net/save_slip.gd")

const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const TuningDesk = preload("res://net/tuning_desk.gd")
const CrewBot = preload("res://net/local_crew_bot.gd")

## The file playing alone keeps the host's changes in (client/main.gd passes it unless automated).
const SETTINGS_FILE := "user://settings.json"
const PROFILE_FILE := "user://saves/solo.gds"

## The local player's id in every run (events say "playerId": "me").
const ME := "me"
## A frame longer than this (seconds of real time) moves the room's clock only this far.
const MAX_STEP := 0.25
const BOT_NAMES := ["Ash", "Moss", "Flint"]

var host: Host = null
var rules: HostRules = null
var seed := "alpha"
var run_seed := ""
var _playtest_depth := -1
var _orientation_playtest := false
var orientation_campaign := false
var badge_search := false
var quick_fingers := false
var long_burn := false
var field_dressing := false
var steady_gaze := false
var throwing_arm := false
var runs := 0
var entity_on := true
var time_scale := 1.0
## The day loop: true, false, or null to follow the game's deck (see the header).
var days: Variant = null
## The floor quota: true, false, or null to follow the game's deck (see the header).
var quota: Variant = null
## Down first, then out: true, false, or null to follow the game's deck (see the header).
var downs: Variant = null
## Relocation: true, false, or null to follow the game's deck (see the header).
var relocation: Variant = null
## The owner's 17 Nov changes (the long dark, paced, the car waits): true, false, or null to follow the deck.
var owner_0833: Variant = null
## Lonely: true, false, or null to follow the game's deck (see the header).
var lonely: Variant = null
## The Playroom tuned from the owner's first play (T15m): true, false, or null to follow the deck.
var playroom_tuned: Variant = null
## Solid furniture (sim/run.gd furniture, FD7): true, false, or null to follow the game's deck.
var furniture: Variant = null
## Restored wall furniture (T20j): true, false, or null to follow the game's deck.
var furniture_layout: Variant = null
## Findables (sim/run.gd findables, FD9): true, false, or null to follow the game's deck.
var findables: Variant = null
## The four-slot inventory (sim/run.gd inventory, S1): true, false, or null to follow the game's deck.
var inventory: Variant = null
## The shop and the cabinet (sim/run.gd shop, S2): true, false, or null to follow the game's deck.
var shop: Variant = null
var deep_pockets: Variant = null
var second_wind: Variant = null
var soft_shoes: Variant = null
## Cost of the host's ticks on this machine (microseconds, summed), for the stats hook.
var host_us := 0
## Live settings: this room's desk (no file until open_settings gives it one).
var desk: TuningDesk = TuningDesk.new()
var solo_profile_path := ""
var _solo_profile := {}
var _vt := 0.0
var _last_real := -1.0
var _host_pipe: Transport.Pipe = null
var _client_pipe: Transport.Pipe = null
var _bot_count := 0
var _bot_network: Transport.MemoryNetwork
var _crew_bots: Array[CrewBot] = []

## Opens the room (no run yet: start_run() starts one). `face`: the player's drawn face ("" for none).
func open_local(seed_: String, player_name: String, entity: bool, face: String = "", bot_count := 0) -> void:
	seed = seed_
	_name = player_name
	_face = face
	entity_on = entity
	_bot_count = clampi(bot_count, 0, BOT_NAMES.size())
	my_id = ME
	host_id = ME
	_update_local_people(false, false, false)
	status = "lobby"
	_take_tune(desk.message(ME))

## Live settings: the desk keeps its changes in `file` ("" for none), read now. The join line says what is changed.
func open_settings(file: String) -> void:
	desk = TuningDesk.new(file, func(text: String) -> void: print(text))
	_take_tune(desk.message(ME, {}, desk.join_line()))
	if host != null:
		desk.run_started()
		host.set_tuning(desk.in_force(), desk.rev)

## Ready-up alone (findables-and-day.md section 2): the same card, and READY starts the run at once.
## Watching the tape is not ready; un-readying with a run on changes nothing.
func set_ready(on: bool, tape: bool = false) -> void:
	my_ready = on
	my_tape = tape and not on
	_update_local_people(run_on, on, my_tape)
	if on and not run_on:
		start_run()

func _update_local_people(active: bool, ready: bool, tape: bool) -> void:
	people = [[ME, _name, ready, tape, active, _face]]
	if _playtest_depth < 0:
		for i in _bot_count:
			people.append(["bot-%d" % (i + 1), BOT_NAMES[i], true, false, active, ""])

## Whether the next run has the day loop.
func days_on() -> bool:
	if days != null:
		return bool(days)
	return Session.deck == Places.FULL

## Whether the next run has the floor quota (with the resident on).
func quota_on() -> bool:
	if quota != null:
		return bool(quota)
	if HostRules.quota_off_by_arg(true):
		return false
	return Session.deck == Places.FULL

## Whether the next run has down first, then out.
func downs_on() -> bool:
	if downs != null:
		return bool(downs)
	return Session.deck == Places.FULL

## Whether the next run has Lonely.
func lonely_on() -> bool:
	if lonely != null:
		return bool(lonely)
	return Session.deck == Places.FULL

## Whether the next run has relocation.
func relocation_on() -> bool:
	if relocation != null:
		return bool(relocation)
	return Session.deck == Places.FULL

## Whether the next run has the owner's 17 Nov changes (the long dark, paced, the car waits).
func owner_0833_on() -> bool:
	if owner_0833 != null:
		return bool(owner_0833)
	return Session.deck == Places.FULL

## Whether the next run has the tuned Playroom (sim/run.gd playroom_tuned, sim/seek.gd T15m).
func playroom_tuned_on() -> bool:
	if playroom_tuned != null:
		return bool(playroom_tuned)
	return Session.deck == Places.FULL

## Whether the next run has solid furniture (sim/run.gd furniture, FD7).
func furniture_on() -> bool:
	if furniture != null:
		return bool(furniture)
	return Session.deck == Places.FULL

func furniture_layout_on() -> bool:
	if furniture_layout != null:
		return bool(furniture_layout)
	return Session.deck == Places.FULL

## Whether the next run has findables (sim/run.gd findables, FD9).
func findables_on() -> bool:
	if findables != null:
		return bool(findables)
	return Session.deck == Places.FULL

## Whether the next run has the shop and the cabinet (sim/run.gd shop, S2).
func shop_on() -> bool:
	if shop != null:
		return bool(shop)
	return Session.deck == Places.FULL

## Whether the next run has the four-slot inventory (sim/run.gd inventory, S1).
func inventory_on() -> bool:
	if inventory != null:
		return bool(inventory)
	return Session.deck == Places.FULL

## The room's clock: local seconds, scaled by time_scale.
func room_time() -> float:
	return _vt

## WN1: the Hanging Ward as a normal level in the next run (net/host_rules.gd ward_place), with the late floors.
## Tests set it false for FL1's scene swap; the command line's `ward_place=0` does the same.
var ward_place := true

## Whether the next run has the late floors (FL1, net/host_rules.gd late_floors): the game's deck only.
func late_floors_on() -> bool:
	return Session.deck == Places.FULL

## The Reactor as a generated place (RN1, net/host_rules.gd reactor_place), with the late floors. On unless the game
## was started with `reactor_place=0` (the way back to the old overlay without a new build); tests may set it.
var reactor_place := HostRules.reactor_place_by_arg()

## Where a solo run keeps its recovered Reactor tape: the game's user data, one folder per run seed ("" keeps it in
## memory; tests may set it).
var late_archive_root := "user://reactor-campaigns"

## The folder a run keeps its recovered Reactor tape in, or "" (in memory, for this run only). T22c: the Host
## Playtest sandbox (the floor picker) always reuses the room's seed, so on disk one success would leave the tape
## gone from every later visit; it keeps the tape in memory instead, and each fresh visit finds it on its table.
## A solo campaign run keeps it on disk under its seed, as before.
func late_archive_path(run_seed_: String) -> String:
	if late_archive_root.is_empty() or _playtest_depth >= 0:
		return ""
	return late_archive_root.path_join(("solo:" + run_seed_).sha256_text())

## The fixed floors and any additional places available in the seeded deck; with the game's deck, the late floors
## too (place &"ward" at HostRules.WARD_DEPTH, &"reactor" at HostRules.REACTOR_DEPTH: overlays on that depth's plan),
## and the start of cycle 2 (FL2: CYCLE_TWO, floor 8, the Clinic again; floors 9 to 14 are not listed).
const CYCLE_TWO := {"depth": 8, "place": &"clinic"}

static func playtest_destinations(seed_: String, deck: Array[StringName]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Array[StringName] = []
	for depth in range(Places.FIXED.size() + 128):
		var place := Places.place_at(seed_, depth, deck)
		if depth < Places.FIXED.size() or not seen.has(place):
			out.append({"depth": depth, "place": place})
			seen.append(place)
		if depth >= Places.FIXED.size() - 1 and deck.all(func(p: StringName) -> bool: return seen.has(p)):
			break
	if deck == Places.FULL:
		out.append({"depth": HostRules.WARD_DEPTH, "place": &"ward"})
		out.append({"depth": HostRules.REACTOR_DEPTH, "place": &"reactor"})
		out.append(CYCLE_TWO.duplicate())
	return out

## Start a fresh sandbox run at a destination on this machine. Reopening the same floor uses the same seed.
## `carried`: the host's changed settings from the room it jumps from (TuningDesk.asked), kept in force here
## (in memory only: the sandbox writes no settings file).
func start_playtest(depth: int, carried: Dictionary = {}) -> bool:
	for destination in playtest_destinations(seed, Session.deck):
		if depth == int(destination["depth"]):
			_playtest_depth = depth
			_orientation_playtest = false
			days = true
			open_settings("")
			_carry_settings(carried)
			solo_profile_path = ""
			_solo_profile.clear()
			my_ready = true
			start_run()
			return true
	return false

## Explicit owner-only review entry. This does not register a campaign destination.
func start_reactor_review(review_seed: int, archive_path := "") -> bool:
	if not start_playtest(1): return false
	host.start_reactor_review(review_seed, true, archive_path)
	return true

## The safe practice route has its own run and does not load or save a campaign profile.
func start_orientation(carried: Dictionary = {}) -> void:
	_playtest_depth = 1
	_orientation_playtest = true
	open_settings("")
	_carry_settings(carried)
	solo_profile_path = ""
	_solo_profile.clear()
	my_ready = true
	start_run()

## The sandbox's desk takes the changes the host made in the room it jumped from (each checked again), so a
## jump never quietly puts a tuned value back. In force from the run's first tick (start_run: run_started).
func _carry_settings(carried: Dictionary) -> void:
	for id: Variant in carried:
		var sid := StringName(str(id))
		if TuningDesk.Settings.row(sid) != null and TuningDesk.Settings.check(sid, float(carried[id]), desk.asked) == &"":
			desk.asked[sid] = TuningDesk.Settings.snap(sid, float(carried[id]))
	if not desk.asked.is_empty():
		desk.rev += 1
		_take_tune(desk.message(ME))

func _prepare_playtest_prison(initial: Run.RunState) -> Run.RunState:
	var s := rules.prepare(initial)
	var events: Array[Dictionary] = []
	Run._arrive_home(s, s.players, s.t, events)
	return s

## A new run (the previous one, if any, is closed).
func start_run() -> void:
	_close_run()
	run_seed = seed if runs == 0 or _playtest_depth >= 0 else "%s-%d" % [seed, runs]
	runs += 1
	epoch += 1
	var o := owner_0833_on()
	# The day quota's lock goes with the floor quota (net/host_rules.gd turns it on only with days too).
	var q := quota_on()
	var depth := HostRules.start_depth_by_arg() if _playtest_depth < 0 else maxi(1, _playtest_depth)
	var deck := Places.deck_for_start_depth(depth, HostRules.garden_admission_by_arg()) if Session.deck == Places.FULL else Session.deck
	var induction := Session.deck == Places.FULL if deep_pockets == null else bool(deep_pockets)
	var nerve := Session.deck == Places.FULL if second_wind == null else bool(second_wind)
	var ear := Session.deck == Places.FULL if soft_shoes == null else bool(soft_shoes)
	rules = HostRules.new(entity_on, depth, deck, days_on(), q, downs_on(), false, relocation_on(), o, o, o, lonely_on(), playroom_tuned_on(), q, furniture_on(), findables_on(), inventory_on(), furniture_layout_on(), Session.deck == Places.FULL, shop_on(), Session.deck == Places.FULL, true, true, induction, nerve, ear, HostRules.flare_on_by_arg(), HostRules.lamp_on_by_arg(), badge_search, quick_fingers, long_burn, field_dressing, HostRules.doorway_shadow_on_by_arg() and Session.deck == Places.FULL and not _orientation_playtest, steady_gaze, throwing_arm,
		HostRules.nerve_passive_on_by_arg() and not _orientation_playtest,
		HostRules.annex_drag_on_by_arg() and not _orientation_playtest,
		playroom_tuned_on(), late_floors_on() and not _orientation_playtest, playroom_tuned_on(), Session.deck == Places.FULL, Session.deck == Places.FULL, late_floors_on() and not _orientation_playtest,
		late_floors_on() and not _orientation_playtest and not HostRules.ward_place_off_by_arg() and ward_place, reactor_place and late_floors_on() and not _orientation_playtest)
	if _orientation_playtest:
		rules.enable_orientation()
	elif orientation_campaign and _playtest_depth < 0:
		rules.enable_orientation_prelude()
	# Method callables hold no reference to this object, so the pipes do not keep it alive.
	var roster: Array[String] = [ME]
	var host_link: Transport.Transport
	var human_link: Transport.Transport
	if _bot_count > 0 and _playtest_depth < 0:
		_bot_network = Transport.MemoryNetwork.new(run_seed)
		_bot_network.now = _vt
		host_link = _bot_network.connect_peer("host")
		human_link = _bot_network.connect_peer(ME)
		for i in _bot_count:
			var id := "bot-%d" % (i + 1)
			var peer := Client.new(_bot_network.connect_peer(id), "host", BOT_NAMES[i], _vt)
			_crew_bots.append(CrewBot.new(id, i, peer))
			roster.append(id)
	else:
		_host_pipe = Transport.Pipe.new("host", Callable(self, "_to_client"), Callable(self, "_to_client_all"))
		_client_pipe = Transport.Pipe.new(ME, Callable(self, "_from_client"), Callable(self, "_to_host"))
		host_link = _host_pipe
		human_link = _client_pipe
	var prepare := Callable(self, "_prepare_playtest_prison") if _playtest_depth == 0 else Callable(rules, "prepare")
	host = Host.new(host_link, run_seed, roster, _vt, prepare, Callable(rules, "step"), roster)
	if not solo_profile_path.is_empty():
		if _solo_profile.is_empty():
			var read := SaveSlip.read_local(ProfileStore.read(solo_profile_path))
			_solo_profile = read.fields if read.ok else SaveSlip.fresh(SaveSlip.new_player_number())
		host.state = Profiles.restore(host.state, ME, _solo_profile)
	# A trusted player gets no placement from the host at the start; send the start spot as one, as the
	# server's room does for its players, so the game takes its body from the same place either way.
	for p in host.state.players:
		if p.id in roster:
			host.place_player(p.id, p.body)
	if rules.late_floors:
		host.enable_late_floors(late_archive_path(run_seed))
	client = Client.new(human_link, "host", _name, _vt, Session.INTERP_DELAY, Session.INPUT_INTERVAL, _face)
	client.floor_deck = rules.deck
	client.garden_dense = host.state.garden_search
	client.orientation_prelude = host.state.orientation_resume != null
	orientation_paid = 0
	client.draw_in_dark = o
	for bot in _crew_bots:
		bot.peer.floor_deck = client.floor_deck
		bot.peer.garden_dense = client.garden_dense
		bot.peer.orientation_prelude = client.orientation_prelude
		bot.peer.draw_in_dark = o
	# Live settings: everything asked for is in force from the first tick.
	desk.run_started()
	host.on_tick = Callable(self, "_tune_tick")
	host.set_tuning(desk.in_force(), desk.rev)
	run_on = true
	status = "running"
	_update_local_people(true, my_ready, false)

func _to_client(to: String, data: String) -> void:
	if to == ME and _client_pipe != null:
		bytes_in += data.length()
		_client_pipe.push("host", data)

func _to_client_all(data: String) -> void:
	_to_client(ME, data)

func _from_client(_to: String, data: String) -> void:
	_to_host(data)

func _to_host(data: String) -> void:
	if _host_pipe != null:
		bytes_out += data.length()
		_host_pipe.push(ME, data)

func _close_run() -> void:
	if client != null and not client.ended:
		client.leave()
	for bot in _crew_bots:
		bot.peer.leave()
	if host != null:
		host.update(_vt)
		host.close()
	host = null
	client = null
	_crew_bots.clear()
	_bot_network = null
	run_on = false
	desk.run_ended()

func poll(now: float) -> void:
	if _last_real < 0.0:
		_last_real = now
	var dt := clampf(now - _last_real, 0.0, MAX_STEP) * maxf(0.0, time_scale)
	_vt += dt
	_last_real = now
	_now = _vt
	for note in desk.poll(now):
		_tune_apply(note)
	if host != null:
		var t0 := Time.get_ticks_usec()
		if _bot_network != null:
			_bot_network.now = _vt
			for bot in _crew_bots:
				bot.poll(host.state, _vt, dt, ME)
		host.update(_vt)
		host_us += Time.get_ticks_usec() - t0
	if client != null:
		client.receive(_vt)

func frame(_now_real: float, local: Client.LocalFrame) -> Client.Frame:
	if client == null:
		return null
	return client.frame(_vt, local)

func leave() -> void:
	_close_run()
	status = "closed"
	close_code = 1000

## Test hook: moves the local player (the host takes a trusted body as it comes).
func place(body: Move.Body) -> void:
	if host != null:
		host.place_player(ME, body)

# ---------------------------------------------------------------------------------------------
# Live settings: the player is the host, and the desk is this room's.

func is_host() -> bool:
	return true

func tune_set(id: StringName, value: float) -> bool:
	return _tune_result(desk.ask(id, value, _name, ME, _vt))

func tune_reset(id: StringName) -> bool:
	return _tune_result(desk.reset(id, _name, ME, _vt))

func tune_reset_all() -> bool:
	return _tune_result(desk.reset_all(_name, ME, _vt))

func _tune_result(res: Array) -> bool:
	if res[0] != &"":
		tune_refusals.append({"id": "", "why": String(res[0])})
		return true
	if not (res[1] as Dictionary).is_empty():
		_tune_apply(res[1])
	return true

func _tune_apply(note: Dictionary) -> void:
	_take_tune(desk.message(ME, note))
	if host != null:
		host.set_tuning(desk.in_force(), desk.rev, note)

func _tune_tick(events: Array) -> void:
	if host != null and orientation_campaign:
		orientation_paid = host.state.orientation_paid
	if host != null and not solo_profile_path.is_empty():
		var changed := Profiles.changed(events)
		if changed.all or changed.ids.has(ME):
			var name_ := _name if SaveSlip._good_name(_name) else "player"
			_solo_profile = Profiles.collect(host.state, ME, _solo_profile, name_, changed.served)
			ProfileStore.store(solo_profile_path, SaveSlip.make(_solo_profile))
	if desk.on_events(events) and host != null:
		host.set_tuning(desk.in_force(), desk.rev)
		_take_tune(desk.message(ME))

func reactor_screening(operation: String, ticket := 0) -> bool:
	return host!=null and host.reactor_screening(ME,operation,ticket)
