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
#    seed with "-1", "-2", ... appended (as the single-player game always did).
#  - `time_scale` runs the room's clock (host and client together) faster or slower: tests only.
#  - The day loop (sim/run.gd days: BANK rides up to the prison, bed starts the next day) is on in the
#    game and off in tests: `days` true or false says so; left null it follows the game's deck (on when
#    Session.deck is Places.FULL, as client/main.gd sets it; tests leave Clinic only).
#  - The floor quota (sim/run.gd quota: the call button does nothing until the crew has recorded enough on
#    the floor) is the same: `quota` true, false, or null to follow the game's deck. With the resident off
#    (`entity_on` false) it is always off (net/host_rules.gd): nothing could ever be recorded. The
#    scripted playthroughs start the game with `auto=1 quota=0` to turn it off (HostRules.quota_off_by_arg).
#  - Down first, then out (sim/run.gd downs: a catch puts the player down for ten seconds, then out) is the
#    same again: `downs` true, false, or null to follow the game's deck. Alone nobody can heal you: down,
#    then out, then (with nobody left standing) the wipe.
#  - Relocation (sim/run.gd relocation, sim/relocate.gd: the resident may leave where nobody can see it and
#    arrive where nobody can) is the same again: `relocation` true, false, or null to follow the game's deck.
#  - The owner's 17 Nov changes (sim/run.gd long_dark, paced, car_waits) are the same once more: `owner_0833`
#    true, false, or null to follow the game's deck. The game's client draws a Stillness resident in the dark
#    too (net/client.gd draw_in_dark), on the same switch.
extends "res://net/room_client.gd"

const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")

## The local player's id in every run (events say "playerId": "me").
const ME := "me"
## A frame longer than this (seconds of real time) moves the room's clock only this far.
const MAX_STEP := 0.25

var host: Host = null
var rules: HostRules = null
var seed := "alpha"
var run_seed := ""
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
## Cost of the host's ticks on this machine (microseconds, summed), for the stats hook.
var host_us := 0
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
	people = [[ME, player_name]]
	status = "lobby"

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

## The room's clock: local seconds, scaled by time_scale.
func room_time() -> float:
	return _vt

## A new run (the previous one, if any, is closed).
func start_run() -> void:
	_close_run()
	run_seed = seed if runs == 0 else "%s-%d" % [seed, runs]
	runs += 1
	epoch += 1
	var o := owner_0833_on()
	rules = HostRules.new(entity_on, 1, Session.deck, days_on(), quota_on(), downs_on(), false, relocation_on(), o, o, o)
	# Method callables hold no reference to this object, so the pipes do not keep it alive.
	_host_pipe = Transport.Pipe.new("host", Callable(self, "_to_client"), Callable(self, "_to_client_all"))
	_client_pipe = Transport.Pipe.new(ME, Callable(self, "_from_client"), Callable(self, "_to_host"))
	var roster: Array[String] = [ME]
	host = Host.new(_host_pipe, run_seed, roster, _vt, Callable(rules, "prepare"), Callable(rules, "step"), roster)
	# A trusted player gets no placement from the host at the start; send the start spot as one, as the
	# server's room does for its players, so the game takes its body from the same place either way.
	for p in host.state.players:
		if p.id == ME:
			host.place_player(ME, p.body)
	client = Client.new(_client_pipe, "host", _name, _vt, Session.INTERP_DELAY, Session.INPUT_INTERVAL, _face)
	client.draw_in_dark = o
	run_on = true
	status = "running"

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

func poll(now: float) -> void:
	if _last_real < 0.0:
		_last_real = now
	_vt += clampf(now - _last_real, 0.0, MAX_STEP) * maxf(0.0, time_scale)
	_last_real = now
	_now = _vt
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
