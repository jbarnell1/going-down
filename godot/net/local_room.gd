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

const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const TuningDesk = preload("res://net/tuning_desk.gd")

## The file playing alone keeps the host's changes in (client/main.gd passes it unless automated).
const SETTINGS_FILE := "user://settings.json"

## The local player's id in every run (events say "playerId": "me").
const ME := "me"
## A frame longer than this (seconds of real time) moves the room's clock only this far.
const MAX_STEP := 0.25

var host: Host = null
var rules: HostRules = null
var seed := "alpha"
var run_seed := ""
var _playtest_depth := -1
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
## Cost of the host's ticks on this machine (microseconds, summed), for the stats hook.
var host_us := 0
## Live settings: this room's desk (no file until open_settings gives it one).
var desk: TuningDesk = TuningDesk.new()
var _vt := 0.0
var _last_real := -1.0
var _host_pipe: Transport.Pipe = null
var _client_pipe: Transport.Pipe = null

## Opens the room (no run yet: start_run() starts one). `face`: the player's drawn face ("" for none).
func open_local(seed_: String, player_name: String, entity: bool, face: String = "") -> void:
	seed = seed_
	_name = player_name
	_face = face
	entity_on = entity
	my_id = ME
	host_id = ME
	people = [[ME, player_name, false, false, false, face]]
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
	people = [[ME, _name, on, my_tape, run_on, _face]]
	if on and not run_on:
		start_run()

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

## The fixed floors and any additional places available in the seeded deck.
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
	return out

## Start a fresh sandbox run at a destination on this machine. Reopening the same floor uses the same seed.
func start_playtest(depth: int) -> bool:
	for destination in playtest_destinations(seed, Session.deck):
		if depth == int(destination["depth"]):
			_playtest_depth = depth
			days = true
			open_settings("")
			my_ready = true
			start_run()
			return true
	return false

## Explicit owner-only review entry. This does not register a campaign destination.
func start_reactor_review(review_seed: int, archive_path := "") -> bool:
	if not start_playtest(1): return false
	host.start_reactor_review(review_seed, true, archive_path)
	return true

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
	var deck := Places.deck_for_start_depth(depth) if Session.deck == Places.FULL else Session.deck
	rules = HostRules.new(entity_on, depth, deck, days_on(), q, downs_on(), false, relocation_on(), o, o, o, lonely_on(), playroom_tuned_on(), q, furniture_on(), findables_on(), inventory_on(), furniture_layout_on(), Session.deck == Places.FULL, shop_on())
	# Method callables hold no reference to this object, so the pipes do not keep it alive.
	_host_pipe = Transport.Pipe.new("host", Callable(self, "_to_client"), Callable(self, "_to_client_all"))
	_client_pipe = Transport.Pipe.new(ME, Callable(self, "_from_client"), Callable(self, "_to_host"))
	var roster: Array[String] = [ME]
	var prepare := Callable(self, "_prepare_playtest_prison") if _playtest_depth == 0 else Callable(rules, "prepare")
	host = Host.new(_host_pipe, run_seed, roster, _vt, prepare, Callable(rules, "step"), roster)
	# A trusted player gets no placement from the host at the start; send the start spot as one, as the
	# server's room does for its players, so the game takes its body from the same place either way.
	for p in host.state.players:
		if p.id == ME:
			host.place_player(ME, p.body)
	client = Client.new(_client_pipe, "host", _name, _vt, Session.INTERP_DELAY, Session.INPUT_INTERVAL, _face)
	client.floor_deck = deck
	client.draw_in_dark = o
	# Live settings: everything asked for is in force from the first tick.
	desk.run_started()
	host.on_tick = Callable(self, "_tune_tick")
	host.set_tuning(desk.in_force(), desk.rev)
	run_on = true
	status = "running"
	people = [[ME, _name, my_ready, false, true, _face]]

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
	if host != null:
		host.update(_vt)
		host.close()
	host = null
	client = null
	run_on = false
	desk.run_ended()

func poll(now: float) -> void:
	if _last_real < 0.0:
		_last_real = now
	_vt += clampf(now - _last_real, 0.0, MAX_STEP) * maxf(0.0, time_scale)
	_last_real = now
	_now = _vt
	for note in desk.poll(now):
		_tune_apply(note)
	if host != null:
		var t0 := Time.get_ticks_usec()
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
	if desk.on_events(events) and host != null:
		host.set_tuning(desk.in_force(), desk.rev)
		_take_tune(desk.message(ME))

func reactor_screening(operation: String, ticket := 0) -> bool:
	return host!=null and host.reactor_screening(ME,operation,ticket)
