# The one room the home server runs: a lobby (the Ready-up screen) until everyone in it is ready, then a
# run (the authoritative NetHost of net/host.gd, stepping the rules through net/host_rules.gd exactly as the
# game does), then back to the lobby a few seconds after the run banks or is wiped (or at once if everyone
# has gone).
#
# Ready-up (docs/floors/findables-and-day.md section 2, FD5). Each player readies once they have read the
# controls card. The host is the first person in the room (`host_id`); when the host leaves, the next in
# arrival order is the host. When everyone in the room is ready a COUNT-second count runs (`start_at`);
# anyone un-readying, or a new arrival, stops it, and the run starts for every ready player on the same
# update. The host alone may start without the stragglers ("start"), once the host is ready and
# WITHOUT_AFTER seconds have passed since the host readied; anyone else's "start", or the host's before
# then, is ignored. Players still reading stay in the lobby and join as late joiners: the host (net/host.gd
# admit_only) admits only those who are ready, at the next stop.
#
# On the wire (text WebSocket messages, after the hello that ws_server.gd checks):
#   server -> client  m|{"t":"you","id":"c3"}                                       once, after the hello
#                     m|{"t":"lobby","epoch":E,"running":true|false,"people":[[id,name,ready,tape,inRun,face],...],
#                        "host":id,"startAt":S|-1,"withoutAt":S|-1,"now":S,"depth":D|-1}
#                                                                                   on every change and every 2 s:
#                                                                                   ready (bool), tape (watching the
#                                                                                   orientation tape), inRun (in the run
#                                                                                   now), face ("" for none); the host's
#                                                                                   id; when the count ends, when the
#                                                                                   host may start without the others
#                                                                                   and the room's clock (seconds); the
#                                                                                   run's floor (-1 with no run)
#                     n<E>|<protocol text>                                           the run's messages (net/protocol.gd),
#                                                                                   including the other players' drawn faces ("F")
#   client -> server  m|{"t":"ready","on":true|false[,"tape":true]}   ready or not (tape: not ready, watching the tape)
#                     m|{"t":"face","face":"..."}   the drawn face shown on the Ready-up list (not valid: ignored)
#                     m|{"t":"start"}        the host's START WITHOUT (see above; ignored otherwise)
#                     m|{"t":"name","name":"..."}
#                     m|{"t":"ping"}         keeps a lobby connection alive (any message does)
#                     m|{"t":"tune",...}     live settings: the host's change (see the block at the end; the
#                                            server answers with "tune" to everyone or "tuneNo" to the sender)
#                     n<E>|<protocol text>   input, join, leave, ping, emote or face change ("C") of run E
#                                            (the host passes emotes on to the others, rate limited; a
#                                            join may carry the player's drawn face, which the host passes
#                                            on once and nothing logs; a face change is passed on the same
#                                            way, at most one per player every Host.FACE_GAP seconds, and
#                                            a "C" whose face is not valid is ignored, not kicked; a client
#                                            may not send "F"); anything else, or a
#                                            message that does not decode exactly (net/protocol.gd
#                                            decode validates every field), closes the connection.
# A client's run messages are passed to the host as coming from that connection's own id, so it can
# only ever speak for its own player.
#
# The run has the day loop (`days`, on unless a test turns it off: sim/run.gd): BANK rides up to the
# prison and bed starts the next day, so the run does not end on a bank or a wipe; the room goes back to
# the lobby when everyone has gone. A run without days ends as before.
#
# The run has the floor quota (`quota`, on unless a test turns it off: sim/run.gd, North Star C9): the
# call button does nothing until the crew has recorded enough on the floor. A server started with the
# argument `quota=0` has none (test-only: tools/play_net.mjs passes it; HostRules.quota_off_by_arg). With the
# quota comes the day quota's lock (sim/run.gd day_lock, FD2): BANK is refused until the crew has earned the
# day's quota; `quota=0` turns it off too.
#
# The run has down first, then out (`downs`, on unless a test turns it off: sim/run.gd, North Star B6): a
# catch puts the player down for ten seconds, a crewmate holding F beside them for three puts them back up,
# and otherwise they are out until the car next rides down.
#
# The run has two-watcher Stillness (`watchers`, on unless a test turns it off: sim/run.gd two_watchers;
# T19a): from three up players on the floor it takes two of them looking to hold a Stillness resident. A
# server started with the argument `watchers=0` holds it with one look at any crew size (test-only:
# tools/net_local.mjs passes it so its three scripted players keep testing the one-watcher hold over real
# connections; the two-watcher hold over the network is proved by tests/prop_watchers.gd).
#
# The run has relocation (`relocation`, on unless a test turns it off: sim/run.gd, sim/relocate.gd; T19e): a
# resident may leave where nobody can see it and arrive where nobody can, near a player, heard as it arrives.
#
# The run has Lonely (`lonely`, on unless a test turns it off: sim/run.gd, sim/lonely.gd; T19c): the Annex's
# Temp goes only for a player who is alone, and breaks off the moment they are not.
# The run has the tuned Playroom (`playroom_tuned`, on unless a test turns it off: sim/run.gd, sim/seek.gd T15m):
# 30-45 s to hide, the anger bar, and the Minder grabs anyone within 1 m outside a count.
# The run has solid furniture (`furniture`, on unless a test turns it off: sim/run.gd, sim/furniture.gd; FD7):
# players slide along the Clinic's and the Annex's pieces instead of walking through them.
# The run has findables (`findables`, on unless a test turns it off: sim/run.gd, sim/findables.gd; FD9): the
# Clinic's and the Annex's drawers, gurneys, lockers, copiers and boxes can be searched for credits, notes, juice.
# The run has the four-slot inventory (`inventory`, on unless a test turns it off: sim/run.gd, sim/inventory.gd; S1).
# The run has the shop and the cabinet (`shop`, on unless a test turns it off: sim/run.gd, sim/shop.gd; S2).
extends RefCounted

const Upgrades = preload("res://sim/upgrades.gd")
const Profiles = preload("res://net/profiles.gd")

const Run = preload("res://sim/run.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Places = preload("res://sim/places.gd")
const WsServer = preload("res://net/ws_server.gd")
const TuningDesk = preload("res://net/tuning_desk.gd")

## Seconds after a bank or a wipe before the room goes back to the lobby.
const END_LINGER := 10.0
const LOBBY_EVERY := 2.0
## The run messages (net/protocol.gd types) a client may send; anything else closes the connection.
const ACCEPTED: Array[String] = ["input", "join", "leave", "ping", "emote", "setFace"]
## Ready-up (see the header): the count once everyone is ready, and how long after readying the host may
## start without the others (seconds).
const COUNT := 5.0
const WITHOUT_AFTER := 30.0

## What NetHost talks through: the room pushes what arrives, sends go out framed with the run's epoch.
class RoomTransport extends Transport.Transport:
	var _room: WeakRef
	var _inbox: Array[Dictionary] = []
	var _events: Array[Dictionary] = []

	func _init(room: Object) -> void:
		_room = weakref(room)
		self_id = "host"

	func push(from: String, data: String) -> void:
		_inbox.append({"from": from, "data": data})

	func push_peer(e: Dictionary) -> void:
		_events.append(e)

	func send(to: String, data: String) -> void:
		var r: Object = _room.get_ref()
		if r != null:
			r.call("send_run", to, data)

	func receive() -> Array[Dictionary]:
		var out := _inbox
		_inbox = []
		return out

	func peer_events() -> Array[Dictionary]:
		var out := _events
		_events = []
		return out

var epoch := 0
var host: Host = null
var rules: HostRules = null
var people := {}  # id -> name, in arrival order
## Ready-up (see the header). The host: the first in the room ("" when it is empty).
var host_id := ""
## id -> room time they readied (absent: not ready); ids watching the orientation tape; drawn faces.
var ready := {}
var watching := {}
var faces := {}
## When the count ends (room time), or -1 with no count running.
var start_at := -1.0
## How many times update() has run (tests tell one server update from the next by it).
var updates := 0
## Seed of the next run ("" draws one at random); tests set it.
var fixed_seed := ""
## The floor the next run starts on (1, the game's; server.gd's test argument depth=N sets it).
var first_depth := 1
## Explicit safe practice room. Ordinary rooms keep the existing campaign sequence.
var orientation_review := false
var orientation_campaign := false
var badge_search := false
var quick_fingers := false
var long_burn := false
var field_dressing := false
var steady_gaze := false
var throwing_arm := false
var nerve_passive := false
var ward_review := false
## The day loop in the next run (the game's; tests may turn it off).
var days := true
## The floor quota in the next run (the game's; tests may turn it off): the call button does nothing
## until the crew has recorded enough on the floor (sim/run.gd quota).
var quota := true
## Down first, then out in the next run (the game's; tests may turn it off: sim/run.gd downs).
var downs := true
## Two-watcher Stillness in the next run (the game's; tests may turn it off: sim/run.gd two_watchers):
## from three up players it takes two watchers to hold a Stillness resident.
var watchers := true
## Relocation in the next run (the game's; tests may turn it off: sim/run.gd relocation, sim/relocate.gd).
var relocation := true
## The owner's 17 Nov changes in the next run (the game's; tests may turn them off): the long dark, paced (a
## bigger tank, faster residents) and the car waits (sim/run.gd long_dark, paced, car_waits).
var long_dark := true
var paced := true
var car_waits := true
## Lonely in the next run (the game's; tests may turn it off: sim/run.gd lonely, sim/lonely.gd).
var lonely := true
## The Playroom tuned from the owner's first play in the next run (the game's; tests may turn it off: sim/run.gd
## playroom_tuned, sim/seek.gd T15m).
var playroom_tuned := true
## Solid furniture in the next run (the game's; tests may turn it off: sim/run.gd furniture, FD7).
var furniture := true
## Restored wall furniture in the next run (T20j).
var reactor_review := false
var reactor_archive_path := ""
## The late floors in the next run (FL1, net/host_rules.gd late_floors: the Hanging Ward at floor 6, the Reactor at 7;
## the game's; `late_floors=0` or tests turn it off). Never in a review or practice room.
var late_floors := true
## Cycles in the next run (FL2, net/host_rules.gd cycles: the Ward's lift rides down to the Reactor, the Reactor's
## return settles the day, and once it is done the days start at floor 8). Only with the late floors; the game's;
## `cycles=0` or tests turn it off.
var cycles := true
## DF1: the pressures of floor 8 and deeper (net/host_rules.gd pressures), with cycles; `pressures=0` or tests turn it off.
var pressures := true
## WN1: the Hanging Ward as a normal level (net/host_rules.gd ward_place), with the late floors; `ward_place=0` falls
## back to the scene swap.
var ward_place := true
## The Reactor as a generated place in the next run (RN1, net/host_rules.gd reactor_place: floor 7 is the station, drawn
## by the main game, with no scene swap). Only with the late floors; the game's; `reactor_place=0` falls back to the
## old overlay without a new build.
var reactor_place := true
## Where a normal room keeps each run's recovered Reactor tape (server/server.gd sets the game's user data folder;
## "" keeps it in memory, as tests do). One folder per run seed (late_archive_path).
var late_archive_root := ""
var furniture_layout := true
## Findables in the next run (the game's; tests may turn it off: sim/run.gd findables, sim/findables.gd, FD9).
var findables := true
## The four-slot inventory in the next run (the game's; tests may turn it off: sim/run.gd inventory, S1).
var inventory := true
## The shop and the cabinet in the next run (the game's; tests may turn it off: sim/run.gd shop, S2).
var shop := true
var deep_pockets := true
var second_wind := true
var soft_shoes := true
## The nightly tapes on the ride up (T24).
var nightly_reels := true
## Tick cost, for the log: total and worst microseconds, and ticks.
var tick_us := 0
var tick_max_us := 0
var ticks := 0
var _ws: WsServer
var _transport: RoomTransport = null
var _ended_at := -1.0
var _last_lobby := -INF
var _dirty := false
var _log: Callable
var _day_logged := 1
## Live settings (LS2): the room's desk (server/server.gd gives it the settings file; none by default).
var desk: TuningDesk
var _tune_host := ""
var profiles: Profiles

func configure_campaign_trades(args: Dictionary) -> void:
	badge_search = args.get("badge_search", "1") == "1"
	long_burn = args.get("long_burn", "1") == "1"
	field_dressing = args.get("field_dressing", "1") == "1"
	steady_gaze = args.get("steady_gaze", "1") == "1"
	throwing_arm = args.get("throwing_arm", "1") == "1"
	nerve_passive = args.get("nerve_passive", "0") == "1"
	late_floors = args.get("late_floors", "1") == "1"
	cycles = args.get("cycles", "1") == "1"
	ward_place = args.get("ward_place", "1") == "1"
	reactor_place = args.get("reactor_place", "1") == "1"
	quick_fingers = args.get("quick_fingers", "1") == "1"

func _init(ws: WsServer, log: Callable) -> void:
	_ws = ws
	_log = log
	desk = TuningDesk.new("", log)

func enable_stamped_profiles(key: PackedByteArray) -> void:
	profiles = Profiles.new(key)

func running() -> bool:
	return host != null

## The recovered-tape folder of a normal run with seed `run_seed` ("" without a root).
func late_archive_path(run_seed: String) -> String:
	if late_archive_root.is_empty():
		return ""
	return late_archive_root.path_join(("run:" + run_seed).sha256_text())

func send_run(to: String, data: String) -> void:
	_ws.send(to, "n%d|%s" % [epoch, data])

## Whether player `id` is in the current run (a late joiner waiting for a stop is not).
func in_run(id: String) -> bool:
	if host == null:
		return false
	var hp: Variant = host._players.get(id)
	return hp != null and bool(hp.in_run) and not bool(hp.left)

func _lobby_text(now: float) -> String:
	var list: Array = []
	for id: String in people:
		var row := [id, people[id], ready.has(id), watching.has(id), in_run(id), faces.get(id, "")]
		if quick_fingers or field_dressing or steady_gaze or throwing_arm:
			var trade := _player_trade(id)
			if not trade.is_empty():
				row.append(trade)
		list.append(row)
	var without := -1.0
	if host_id != "" and ready.has(host_id) and host == null:
		without = float(ready[host_id]) + WITHOUT_AFTER
	var lobby := {"t": "lobby", "epoch": epoch, "running": running(), "people": list, "host": host_id,
		"startAt": start_at, "withoutAt": without, "now": now, "depth": host.state.depth if host != null else -1,
		"garden": host != null and host.state.deck.has(Places.ARBORETUM)}
	if host != null and host.state.garden_search:
		lobby["gardenDense"] = true
	# Cycles (FL2): the run's deck repeats its floors in sevens; the client draws its floors with the same deck.
	if host != null and rules != null and Places.cycles_in(rules.deck):
		lobby["cycles"] = true
	# RN1: the run's deck has the Reactor at floor 7; the client draws its floors with the same deck.
	if host != null and rules != null and rules.reactor_place:
		lobby["reactorPlace"] = true
	if orientation_review:
		lobby["orientation"] = true
	if host != null and host.state.orientation_resume != null:
		lobby["orientationPrelude"] = true
	if host != null and host.state.orientation_paid > 0:
		lobby["orientationPaid"] = host.state.orientation_paid
	return "m|" + JSON.stringify(lobby)

func _player_trade(id: String) -> String:
	if host != null:
		var wallet: Upgrades.UpgradeState = host.state.wallets.get(id)
		if wallet != null:
			return Upgrades.trade_of(wallet.owned)
	if profiles != null:
		return profiles.trade_of(id)
	return ""

## The players a run starting now takes: the ready ones, in arrival order.
func _start_roster() -> Array[String]:
	var roster: Array[String] = []
	for id: String in people:
		if ready.has(id):
			roster.append(id)
	return roster

## The host: the first in arrival order (people keeps it).
func _pick_host() -> void:
	var first := ""
	for id: String in people:
		first = id
		break
	if first != host_id:
		host_id = first
		_dirty = true

## Ready-up between runs: everyone ready runs the count; it stops the moment that is no longer so.
func _ready_up(now: float) -> void:
	if host != null:
		start_at = -1.0
		# Late joiners: only the ready ones are admitted at the next stop (net/host.gd _admit).
		var ok := {}
		for id: String in ready:
			ok[id] = true
		host.admit_only = ok
		return
	var all_ready := not people.is_empty()
	for id: String in people:
		if not ready.has(id):
			all_ready = false
			break
	if not all_ready:
		if start_at >= 0.0:
			start_at = -1.0
			_dirty = true
		return
	if start_at < 0.0:
		start_at = now + COUNT
		_dirty = true
	elif now >= start_at:
		_begin(now)

## Starts the run with the ready players; their ready flags are spent (after it, everyone readies again).
func _begin(now: float) -> void:
	_start(now)
	start_at = -1.0
	if host == null:
		return
	for id: String in host._players:
		ready.erase(id)
	_dirty = true

## Handles the door's events and runs the host. `now`: seconds.
func update(now: float) -> void:
	updates += 1
	for e in _ws.events:
		match String(e["kind"]):
			"joined":
				people[e["id"]] = e["name"]
				var welcome := {"t": "you", "id": e["id"]}
				if profiles != null:
					welcome["profile"] = true
				_ws.send(e["id"], "m|" + JSON.stringify(welcome))
				# A new arrival stops the count (it starts again once they are ready too).
				start_at = -1.0
				_tune_joined(e["id"])
				_dirty = true
			"left":
				if profiles != null:
					profiles.leave(e["id"])
				people.erase(e["id"])
				ready.erase(e["id"])
				watching.erase(e["id"])
				faces.erase(e["id"])
				if _transport != null:
					_transport.push_peer({"kind": "left", "peer": e["id"]})
				_dirty = true
			"message":
				_on_message(e["id"], e["data"], now)
	_ws.events.clear()
	_pick_host()
	_ready_up(now)
	_tune_update(now)
	if host != null:
		var tick0 := host.tick
		var t0 := Time.get_ticks_usec()
		host.update(now)
		var dt := Time.get_ticks_usec() - t0
		var n := host.tick - tick0
		if n > 0:
			ticks += n
			tick_us += dt
			tick_max_us = maxi(tick_max_us, dt / n)
		if host.state.days and host.state.day_index != _day_logged:
			_day_logged = host.state.day_index
			_log.call("run %d: day %d begins (day %d of this run)" % [epoch, host.state.day_state.day, host.state.day_index])
		if host.state.phase == &"ended" and _ended_at < 0.0:
			_ended_at = now
			var s := host.state.summary
			_log.call("run %d ended: %s, depth %d, total %.2f" % [epoch, "wiped" if s != null and s.wiped else "banked", host.state.depth, s.total if s != null else 0.0])
		if (_ended_at >= 0.0 and now - _ended_at >= END_LINGER) or people.is_empty():
			_end_run()
	if _dirty or now - _last_lobby >= LOBBY_EVERY:
		_dirty = false
		_last_lobby = now
		var text := _lobby_text(now)
		for id: String in people:
			_ws.send(id, text)

func _end_run() -> void:
	_log.call("run %d over, back to the lobby" % epoch)
	host.close()
	host = null
	if profiles != null:
		profiles.applied.clear()
	desk.run_ended()
	rules = null
	_transport = null
	_ended_at = -1.0
	# Back on the Ready-up screen: everyone readies again (a late joiner never admitted too).
	ready.clear()
	start_at = -1.0
	_dirty = true

## A run with the ready players (_start_roster). Called by the count and by the host's START WITHOUT.
func _start(now: float) -> void:
	var roster := _start_roster()
	if host != null or roster.is_empty():
		return
	epoch += 1
	var seed := fixed_seed
	if seed.is_empty():
		seed = Crypto.new().generate_random_bytes(6).hex_encode()
	# The game's deck: the third floor down is the Annex, the fourth the Playroom (sim/places.gd).
	var q := quota and not HostRules.quota_off_by_arg(false)
	# The day quota's lock goes with the floor quota (net/host_rules.gd): quota=0 turns both off.
	rules = HostRules.new(not (ward_review or reactor_review), first_depth, Places.deck_for_start_depth(first_depth, HostRules.garden_admission_by_arg()), days, q, downs, watchers and not HostRules.watchers_off_by_arg(), relocation, long_dark, paced, car_waits, lonely, playroom_tuned, q, furniture, findables, inventory, furniture_layout, true, shop, nightly_reels, true, true, deep_pockets and not (ward_review or reactor_review), second_wind, soft_shoes, HostRules.flare_on_by_arg() and not (ward_review or reactor_review), HostRules.lamp_on_by_arg() and not (ward_review or reactor_review), badge_search and not (ward_review or reactor_review), quick_fingers and not (ward_review or reactor_review), long_burn and not (ward_review or reactor_review), field_dressing and not (ward_review or reactor_review), HostRules.doorway_shadow_on_by_arg() and not (ward_review or reactor_review or orientation_review), steady_gaze and not (ward_review or reactor_review or orientation_review), throwing_arm and not (ward_review or reactor_review or orientation_review),
		nerve_passive and not (ward_review or reactor_review or orientation_review),
		HostRules.annex_drag_on_by_arg() and not (ward_review or reactor_review or orientation_review),
		playroom_tuned, late_floors and not (ward_review or reactor_review or orientation_review), playroom_tuned, true, not (ward_review or reactor_review or orientation_review), cycles and late_floors and not (ward_review or reactor_review or orientation_review),
		ward_place and late_floors and not (ward_review or reactor_review or orientation_review), reactor_place and late_floors and not (ward_review or reactor_review or orientation_review),
		cycles and late_floors and not (ward_review or reactor_review or orientation_review) and pressures and HostRules.pressures_by_arg())
	if orientation_review:
		rules.enable_orientation()
	elif orientation_campaign:
		rules.enable_orientation_prelude()
	_transport = RoomTransport.new(self)
	_day_logged = 1
	host = Host.new(_transport, seed, roster, now, Callable(rules, "prepare"), Callable(rules, "step"))
	if profiles != null and not orientation_review:
		for id in roster:
			host.state = profiles.apply_for(host.state, id, str(people[id]))
	if ward_review:
		host.start_ward_review(seed.hash(), true)
	elif reactor_review:
		host.start_reactor_review(seed.hash(), true, reactor_archive_path)
	elif rules.late_floors:
		host.enable_late_floors(late_archive_path(seed))
	# Live settings: everything asked for is in force from the first tick.
	desk.run_started()
	host.on_tick = Callable(self, "_tune_tick")
	host.set_tuning(desk.in_force(), desk.rev)
	_dirty = true
	_log.call("run %d started with %d players" % [epoch, roster.size()])

## START WITHOUT: from the host only, ready for WITHOUT_AFTER seconds, with no run on. Otherwise ignored.
func _start_without(id: String, now: float) -> bool:
	if host != null or id != host_id or not ready.has(id) or now - float(ready[id]) < WITHOUT_AFTER:
		return false
	_log.call("the host started without %d still reading" % (people.size() - _start_roster().size()))
	_begin(now)
	return true

func _on_message(id: String, data: String, now: float) -> void:
	# A client's log line ("t|", net/room_client.gd send_telemetry). The home server's night log takes these
	# out before the room sees them (server/night_log.gd pump); a server without one (the test servers in
	# tools/) just lets them go by. It is never a reason to drop a player.
	if data.begins_with("t|"):
		return
	if data.begins_with("m|"):
		var p: Variant = JSON.parse_string(data.substr(2))
		if not p is Dictionary or not (p as Dictionary).get("t") is String:
			_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
			return
		match String(p["t"]):
			"rxFilm":
				if (reactor_review or (rules != null and rules.late_floors)) and host!=null and p.get("epoch")==epoch and p.get("op") in ["watch","skip","end"] and (p.get("ticket") is float or p.get("ticket") is int):
					host.reactor_screening(id,p.op,int(p.ticket))
			"profile":
				var line: Variant = p.get("line")
				if profiles != null and people.has(id) and line is String:
					profiles.join(id, str(people[id]), line)
			"start":
				_start_without(id, now)
			"ready":
				var on: bool = p.get("on") == true
				if on and not ready.has(id):
					ready[id] = now
				elif not on and ready.has(id):
					ready.erase(id)
				if not on and p.get("tape") == true:
					watching[id] = true
				else:
					watching.erase(id)
				_dirty = true
			"face":
				var f := Protocol.valid_face(p.get("face"))
				if f != "" and faces.get(id, "") != f:
					faces[id] = f
					_dirty = true
			"name":
				if p.get("name") is String:
					people[id] = WsServer._clean_name(p["name"])
					_dirty = true
			"ping":
				pass
			"tune":
				_on_tune(id, p, now)
			_:
				_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
		return
	if data.begins_with("n"):
		var bar := data.find("|")
		var e := data.substr(1, bar - 1)
		if bar < 2 or not e.is_valid_int():
			_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
			return
		if int(e) != epoch or _transport == null:
			return  # a late message of a finished run
		var text := data.substr(bar + 1)
		var m: Variant = Protocol.decode(text)
		if m == null or not (String(m["type"]) in ACCEPTED):
			_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")
			return
		_transport.push(id, text)
		return
	_ws.kick(id, WsServer.CLOSE_PROTOCOL, "bad message")

# =============================================================================================
# Live settings (docs/floors/live-settings.md LS2): the host, the desk, the room messages.
#   client -> server  m|{"t":"tune","id":"orderly.speed","v":3.6}    the host asks for a value
#                     m|{"t":"tune","id":"orderly.speed","reset":true}   one back to the game's
#                     m|{"t":"tune","reset":"all"}                    every one back
#   server -> client  m|{"t":"tune","rev":R,"host":id,"set":{...},"file":bool,"saved":"...","force":{...}?,
#                        "line":"..."?,"note":{...}?}   to everyone on every change (the line is the notice), to a
#                                                       joiner as they arrive, and to everyone when the host changes
#                     m|{"t":"tuneNo","id":"...","why":"host"|"id"|"range"|"pair"|"busy"}   to the sender alone
# A refused change changes nothing and never closes the connection; a "tune" that is not a Dictionary does (as
# any m| message).

# ---- WHO THE HOST IS: the one place the room decides it. ------------------------------------------------
# The room's one host is `host_id` (the ready-up screen's, FD5: the first arrival still in the room, passed
# on in arrival order by _pick_host). Everything below asks only this function. `host_id` is picked once an
# update's events are all read, so within that update (a first arrival, or the host having just left) this
# answers with the same rule _pick_host will apply: the first arrival still present.
func _settings_host_id() -> String:
	if host_id != "" and people.has(host_id):
		return host_id
	for id: String in people:
		return id
	return ""
# ---- end of who the host is -----------------------------------------------------------------------------

func _tune_name(id: String) -> String:
	return str(people.get(id, "THE HOST"))

func _tune_send_all(m: Dictionary) -> void:
	var text := "m|" + JSON.stringify(m)
	for id: String in people:
		_ws.send(id, text)

func _tune_joined(id: String) -> void:
	_tune_host = _settings_host_id()
	_ws.send(id, "m|" + JSON.stringify(desk.message(_tune_host, {}, desk.join_line())))

## Every frame: the host passed on (everyone is told), and the file looked at for a hand edit.
func _tune_update(now: float) -> void:
	var h := _settings_host_id()
	if h != _tune_host:
		_tune_host = h
		if h != "":
			_log.call("settings: the host is now %s" % h)
		_tune_send_all(desk.message(h))
	for note in desk.poll(now):
		_log.call("settings: " + str(note["line"]).to_lower())
		_tune_send_all(desk.message(h, note))
		if host != null:
			host.set_tuning(desk.in_force(), desk.rev, note)

## After every tick of the run: the car leaving lets the waiting `floor` values in, lights out the `day` ones.
func _tune_tick(events: Array) -> void:
	_checkpoint_profiles(events)
	if desk.on_events(events) and host != null:
		host.set_tuning(desk.in_force(), desk.rev)
		_tune_send_all(desk.message(_tune_host))

func _checkpoint_profiles(events: Array) -> void:
	if host == null or profiles == null:
		return
	var changed := Profiles.changed(events)
	for id: String in people:
		if not in_run(id):
			continue
		host.state = profiles.apply_for(host.state, id, str(people[id]))
		if not changed.all and not changed.ids.has(id):
			continue
		var line := profiles.checkpoint(host.state, id, str(people[id]), changed.served)
		if not line.is_empty():
			_ws.send(id, "m|" + JSON.stringify({"t": "profile", "line": line}))

func _tune_refuse(id: String, setting: String, why: String) -> void:
	_ws.send(id, "m|" + JSON.stringify({"t": "tuneNo", "id": setting, "why": why}))

func _on_tune(id: String, p: Dictionary, now: float) -> void:
	var setting := str(p.get("id", "")) if p.get("id") is String else ""
	if id != _settings_host_id():
		_tune_refuse(id, setting, "host")
		return
	var res: Array
	if p.get("reset") is String and p["reset"] == "all":
		res = desk.reset_all(_tune_name(id), id, now)
	elif setting.is_empty():
		_tune_refuse(id, setting, "id")
		return
	elif p.get("reset") is bool and p["reset"]:
		res = desk.reset(StringName(setting), _tune_name(id), id, now)
	else:
		res = desk.ask(StringName(setting), p.get("v"), _tune_name(id), id, now)
	if res[0] != &"":
		_tune_refuse(id, setting, String(res[0]))
		return
	var note: Dictionary = res[1]
	if note.is_empty():
		return
	_log.call("settings: " + str(note["line"]).to_lower())
	_tune_send_all(desk.message(_tune_host, note))
	if host != null:
		host.set_tuning(desk.in_force(), desk.rev, note)
