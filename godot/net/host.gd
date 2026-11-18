# The host: the home server runs the run for everyone. Port of src/net/host.ts (NetHost). It steps
# the run at 20 ticks a second with every player's latest input, is the only authority on the run,
# the Orderly, the instruments and the tapes, and sends every client a snapshot after every tick.
#
# The rule that must survive the network (the Orderly is never seen to move on anyone's screen) is
# kept by the clients' own drawing (client.gd) and honoured here:
#  - A "seen" report says: this client froze its drawing of the Orderly at this pose, blended from
#    these two snapshots. The host keeps HISTORY_SECONDS of the Orderly's states (as sent, quantised).
#    If the Orderly has moved on since, it is put back exactly to the pose the client holds (the state
#    the client was drawing, with the drawn position), and the history from that moment on is
#    rewritten to "it stood there", so later reports about the abandoned timeline change nothing.
#    Beyond PUT_BACK_MAX metres it is not moved; the violation is counted instead.
#  - Looking always saves you: a seen report, or any input saying "I can see it", cancels a wind-up
#    in progress, and the Orderly is held (as if seen this tick, with the usual grace after).
#  - A catch is not completed until the victim's machine has shown, by an input, that it drew every
#    frame up to the moment the wind-up would finish without seeing it (its newest snapshot and its
#    render clock have both passed that moment). Until then the Orderly holds its reach. The victim's
#    own client commits at that same moment of its drawn timeline (client.gd, the taken latch). While
#    the catch waits, a sighting saves the victim only if it is of a moment before the wind-up's end.
#    After CATCH_CONFIRM_MAX the catch completes regardless.
#
# Inputs: the latest by sequence number wins; older ones still deliver their acknowledgements and seen
# reports. Bodies are the clients' own, except that a body further than the player could have gone is
# refused (the allowance grows until the next input fits), bodies are ignored until the client
# acknowledges a placement the run made (rides, push-outs, joining), and inputs from players who are
# caught, left behind or gone are not given to the run.
#
# Gait and breath: the host owns every player's tank (sim/stamina.gd) and steps it on every new input,
# in the client's own clock, with the gait the tank allows and the ground the bodies covered. Each
# snapshot carries the player's own tank back.
#
# Emotes (protocol "E") are passed on to every other player at once ("M"), at most one per player per
# EMOTE_GAP seconds; they never touch the run.
#
# Faces: a join may carry the player's drawn face (protocol "J", fifth element). The host keeps it and
# passes it to the other players once ("F"); a joiner (also a late one) gets everyone else's faces after
# its welcome. A player may change their face during the run (protocol "C", the prison's face kiosk): a
# valid new face is kept and passed to the others with "F", at most one change per player every
# FACE_GAP seconds; a face that is not valid, or one too soon, is ignored (nobody is kicked for it).
# Faces never go in the snapshot and never touch the run.
#
# Events are numbered and kept; each snapshot carries the events after the ones its client has
# acknowledged (up to EVENT_BUDGET bytes), so they arrive exactly once and in order.
#
# The day loop (sim/run.gd days; docs/floors/prison.md P7): when the run has days, the host passes each
# input's "use" (F held) to the run, moves the players the run moves home ("rodeUp") and into the next
# day's car ("newDay") as it does on a ride down, stamps every placement with the day index of its
# floor, and adds the day block to every snapshot (Protocol.enc_day): the day, the quota, who is in bed,
# the bedtime count and lights out in host time, and the facts of the day just settled. A run without
# days sends exactly what it did before.
#
# Seen reports and "I can see it" hold only a Stillness resident (sim/places.gd resident). On a floor whose
# resident is not one (the Playroom's Minder) looking does nothing, so they are dropped.
#
# The Playroom (sim/run.gd, sim/seek.gd; loop/NIGHT-PLAN.md A3): the host gives the run each player's
# gait (the one the tank allowed), the hide key (a new "hides" count is a press; a new "fastHides" says it
# was the quick way), W in a hide ("peek") and a sound emote it passed on (Protocol.SOUND_EMOTES). It
# places a player where the rules hold them when they get into a hide, start getting out, are found, are
# taken to the party table or go down, and adds the seek block to every snapshot (Protocol.enc_seek). The
# count is the run's own event, stamped with the host's time: every client works the count out from it.
#
# The floor quota (sim/run.gd quota; North Star C9): the run decides, the host only reports. When the run
# has the quota on, every snapshot carries the quota block (Protocol.enc_quota: earned and needed, whole
# credits), and the run's "callRefused" and "quotaMet" events reach every client like any other. A press
# of the call button is one call input (the "calls" counter), so each press below the quota is one
# "callRefused". A run without the quota sends exactly what it did before.
#
# The Annex (sim/run.gd annex; T16h): the run decides, the host passes keys on and reports. A new "marks"
# count is a press of Q (PlayerInput.mark); a new "peels" count asks to peel the mark "peelId"
# (PlayerInput.peel). Each player's name, from their join, goes to the run (RunState.names) for the notes.
# On an Annex floor every snapshot carries the annex block (Protocol.enc_annex: the pad, every mark, and
# how many notes the floor has), the welcome also every note so far (so a player who joins mid-floor has
# them all), and the run's mark and note events reach every client like any other. Marks and notes go to
# everyone alike: nothing is sent to one player only.
#
# Down first, then out (sim/run.gd downs; North Star B6; T8a): the run decides, the host passes keys on and
# reports. A downed player's input still goes to the run, but only their body (they crawl: the run follows it
# at its crawl speed) and their view, blind, with no presses: they call, pick up, hide and mark nothing, and
# a press made while down is not saved up. F held ("use") is passed for everyone on their feet, as always:
# held beside a downed player it heals them. The host places a player where they go down ("downed") and
# where they get up ("healed"), so their screen has the run's body. When the run has the down rule every
# snapshot carries the downs block (Protocol.enc_downs): who is down, until when, who is healing them since
# when (host times, so every screen counts the same ten and three seconds), and this floor's red spots. The
# run's "downed", "healStart", "healStop", "healed" and "out" reach every client like any other event. A run
# without the down rule sends exactly what it did before.
#
# Two-watcher Stillness (sim/run.gd two_watchers, sim/entity.gd "Watchers"; T19a): the run decides, the host
# keeps it fair over the network. With two watchers needed (three or more up players):
#  - every snapshot carries the count, the watch block (Protocol.enc_watch: need, and whom the host counts);
#  - "I can see it" makes that player one watcher (Entity.note_look), not a hold: a lone one holds nothing;
#  - a seen report is honoured (put back and held, as above) only if a snapshot the player had been sent and
#    acknowledged, from the newer one it drew from up to its ackHt, said one more look was enough (one needed,
#    or another player counted), even if that other watcher has looked away since: its screen lit every mark
#    and held on what it was told. Otherwise it is one watcher's look, like "I can see it".
# With one needed (one or two up players, or the rule off) everything is as it was.
#
# Relocation (sim/run.gd relocation, sim/relocate.gd; T19e): the run decides. Once the resident has relocated on
# the floor every snapshot carries the count (Protocol "reloc"), and a seen report of a pose from before its last
# relocation is stale (counted as such, nothing put back or held): it is of a place it has left.
#
# Lonely (sim/run.gd lonely, sim/lonely.gd; T19c): the Temp is not a Stillness resident then (Run.resident_of), so
# no seen report or "I can see it" is applied to it: looking does nothing. The catch still waits for its
# victim's screen (_confirm_catch), which the Lonely step honours. Every snapshot on its floor carries who it
# chases (Protocol "lonely"), which also tells each client not to hold the figure.
#
# Live settings (docs/floors/live-settings.md LS2; set_tuning): the room's desk decides what is in force and hands it
# over between ticks; the host puts it on the state (RunState.tuning, read by the rules), announces a change with the
# next tick's "tuned" event, and adds the tune block to the snapshots once the revision is above 0. A run nobody
# tunes sends exactly what it did before.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Instr = preload("res://sim/instrument.gd")
const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const TapeLib = preload("res://sim/tape.gd")
const M = preload("res://sim/jsmath.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Pose = preload("res://net/pose.gd")
const JsJson = preload("res://net/jsjson.gd")
const Transport = preload("res://net/transport.gd")
const Day = preload("res://sim/day.gd")
const Seek = preload("res://sim/seek.gd")
const Hiding = preload("res://sim/hiding.gd")

const EPS := 1e-9
const TICK := Session.TICK
const HISTORY_TICKS := 60  # ceil(HISTORY_SECONDS / TICK)
## Run states kept for inspection (tests compare clients against the host at a given tick).
const STATE_TICKS := 200
## A player's emotes are passed on at most once per this many seconds; the rest are dropped.
const EMOTE_GAP := 0.4
## A player's face changes ("C") are taken at most once per this many seconds (host time); the rest
## are dropped. Each change is passed on to every other player, so this caps what one player can make
## the host send.
const FACE_GAP := Protocol.FACE_GAP

class HostPlayer:
	var id: String
	var peer: String
	var connected := false
	var left := false
	## In the run's player list (else a spectator waiting for the next stop).
	var in_run := false
	var joined := false
	var last_seq := 0
	var input: Variant = null  # the newest input message (Dictionary) or null
	## Host time the latest input arrived.
	var input_at := -INF
	var echo: Variant = null  # [client time, host time] or null
	var body: Move.Body = null
	var body_ct: Variant = null
	var calls := 0
	var call_pending := false
	var pick_ups := 0
	var pick_pending := false
	var ack_event := 0
	var ack_ht := -INF
	var render_time := -INF
	var place: Variant = null  # {seq, depth, body} or null
	var place_ack := 0
	var seen_done := {}
	var ack_seen := 0
	## The tank, owned here, and the gait it allowed on the newest input.
	var stamina: Stamina.Stamina
	var gait: String = "walk"
	## Metres the body may still move before an input is refused.
	var allowance: float = Session.JUMP_SLACK
	## Client time and claimed body of the newest input (for the tank's clock and ground speed).
	var last_ct: Variant = null
	var claim: Move.Body = null
	## Host time of the newest emote passed on (the emote rate limit).
	var last_emote := -INF
	## The face this player drew (FaceCodec text, already validated by the protocol), or "".
	var face := ""
	## Host time of the newest face change taken (the face change rate limit).
	var last_face_change := -INF
	## The Playroom: F presses for a hide counted so far (and those with sprint held); a press not yet
	## given to the run, and whether it was the quick way; a sound emote not yet given to the run.
	var hides := 0
	var fast_hides := 0
	var hide_pending := false
	var hide_fast := false
	var emote_pending := false
	## The name this player joined with ("" before the join).
	var name := ""
	## The Annex: Q presses counted so far (a press not yet given to the run), peels asked for so far and
	## the mark of a peel not yet given to the run (-1 for none).
	var marks := 0
	var mark_pending := false
	var peels := 0
	var peel_pending := -1

class History:
	var o: Entity.OrderlyState
	var pose: Dictionary

	static func make(o_: Entity.OrderlyState) -> History:
		var h := History.new()
		h.o = o_
		h.pose = Protocol.orderly_snap(o_)
		return h

class LoggedEvent:
	var seq: int
	var tick: int
	## Plain data (as JSON.parse would give), and its JSON text.
	var e: Dictionary
	var text: String

class HostStats:
	var ticks := 0
	var reports := 0
	var put_backs := 0
	var max_put_back := 0.0
	var put_back_distances := PackedFloat64Array()
	var bound_violations := 0
	var max_violation_gap := 0.0
	var stale_reports := 0
	var after_catch := 0
	var wind_ups_cancelled_by_report := 0
	var catch_hold_ticks := 0
	var catches_forced := 0
	var late_sightings := 0
	var clamped_inputs := 0
	var snapshots := 0
	var snapshot_bytes := 0
	var max_snapshot_bytes := 0

	func to_dict() -> Dictionary:
		return {"ticks": ticks, "reports": reports, "putBacks": put_backs, "maxPutBack": max_put_back, "boundViolations": bound_violations,
			"maxViolationGap": max_violation_gap, "staleReports": stale_reports, "afterCatch": after_catch,
			"windUpsCancelledByReport": wind_ups_cancelled_by_report, "catchHoldTicks": catch_hold_ticks, "catchesForced": catches_forced,
			"lateSightings": late_sightings, "clampedInputs": clamped_inputs, "snapshots": snapshots, "snapshotBytes": snapshot_bytes,
			"maxSnapshotBytes": max_snapshot_bytes}

var state: Run.RunState
var tick := 0
var ended := false
var seed: String
var event_log: Array[LoggedEvent] = []
var stats := HostStats.new()
## Every snapshot's size in bytes, by number of players in the run, when a test asks: [players, bytes].
var keep_sizes := false
var snapshot_sizes: Array = []
## Emotes passed on to the other players, and dropped by the rate limit (not in HostStats, which the
## reference sessions compare).
var emotes_relayed := 0
var emotes_dropped := 0
## Faces sent to players ("F" messages), and whether faces are passed on at all (tests turn it off to
## show the check that would catch it).
var faces_sent := 0
var relay_faces := true
## Face changes ("C") taken, and ignored (not a valid face, or within FACE_GAP of the last one).
var face_changes := 0
var face_changes_ignored := 0
## Two-watcher Stillness (T19a; not in HostStats, which the reference sessions compare): seen reports not
## honoured because what their player had been sent listed no other watcher (they count as one look).
var reports_unheld := 0
## What each snapshot said of the count, by tick: [host time, need, watcher ids]. Never rewritten by a
## put-back (it is what the clients were told).
var _sent_watch := {}
## Ready-up (server/room.gd): the peers a stop may admit ({peer: true}), or null to admit every spectator
## (the default: every reference session and the game alone).
var admit_only: Variant = null
var _transport: Transport.Transport
var _start_local: float
var _players := {}  # id -> HostPlayer, in arrival order
var _by_peer := {}  # peer -> id
var _hist := {}  # tick -> History
var _states := {}  # tick -> RunState
var _queue: Array = []  # [player id, report]
var _roster_ids := {}
## A catch waiting for its victim's screen: {victim, armedAt, armedHost, body}.
var _pending_catch: Variant = null
var _last_catch_tick := -1
var _next_id := 1
var _step_fn: Callable
var _trusted := {}
## Live settings (docs/floors/live-settings.md LS2; set_tuning): the revision in force (0: never tuned, and the
## snapshot is what it always was), the list in force, the notices waiting for the next tick, and when the
## snapshot next carries the whole list. on_tick: called with every tick's run events after the tick (the room's
## desk lets waiting values in on "carLeft" and "lightsOut", and may call set_tuning then: between two ticks).
var tune_rev := 0
var on_tick: Callable
var _tune_list: Array = []
var _tune_events: Array[Dictionary] = []
var _tune_full_until := -INF
var _tune_last_full := -INF
var _tune_list_due := false

## `roster`: players in the run from the first tick (their peer ids). `now`: host clock at the start
## (tick k is due at now + k * TICK). `prepare` (RunState -> RunState) adjusts the run before the first
## tick; `step` (RunState, Array[PlayerInput], dt -> RunStep) steps it (default Run.step_run; the server
## passes HostRules.step). `trusted`: players whose bodies are taken with no speed check.
func _init(transport: Transport.Transport, seed_: String, roster: Array[String], now: float, prepare: Callable = Callable(), step: Callable = Callable(), trusted: Array[String] = []) -> void:
	_transport = transport
	seed = seed_
	_start_local = now
	for id in roster:
		_roster_ids[id] = true
	_step_fn = step if step.is_valid() else Callable(Run, "step_run")
	for id in trusted:
		_trusted[id] = true
	var s := Run.create_run(seed_, roster)
	if prepare.is_valid():
		s = prepare.call(s)
	state = s
	for id in roster:
		var rp := _find_run_player(s, id)
		var hp := _new_player(id, id, true)
		if rp != null:
			hp.body = rp.body
			if not _trusted.has(id):
				hp.place = {"seq": 1, "depth": s.depth, "body": Protocol.q_body(rp.body)}
				if s.days:
					hp.place["day"] = s.day_index
		_players[id] = hp
		_by_peer[id] = id
	_record()

static func _find_run_player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

func _new_player(id: String, peer: String, in_run: bool) -> HostPlayer:
	var p := HostPlayer.new()
	p.id = id
	p.peer = peer
	p.in_run = in_run
	p.stamina = Stamina.fresh_stamina()
	return p

## Host time (the run's clock) at host-local time `now`.
func host_time(now: float) -> float:
	return now - _start_local

## Host-local time the next tick is due.
func next_tick_at() -> float:
	return _start_local + (tick + 1) * TICK

## The run as it was after tick `k` (recent ticks only), or null.
func state_at(k: int) -> Run.RunState:
	return _states.get(k)

## A player's tank as the host has it (null for nobody by that id).
func stamina_of(id: String) -> Stamina.Stamina:
	var p: HostPlayer = _players.get(id)
	if p == null:
		return null
	var s := Stamina.Stamina.new()
	s.level = p.stamina.level
	s.winded = p.stamina.winded
	s.tank = p.stamina.tank
	return s

## The gait the host allowed a player on their newest input ("" for nobody).
func gait_of(id: String) -> String:
	var p: HostPlayer = _players.get(id)
	return p.gait if p != null else ""

## Players the host knows: {id, connected, inRun, left}.
func roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: HostPlayer in _players.values():
		out.append({"id": p.id, "connected": p.connected, "inRun": p.in_run, "left": p.left})
	return out

## Receives, then runs every tick that is due by `now` (host-local clock).
func update(now: float) -> void:
	if ended:
		return
	for pe in _transport.peer_events():
		if pe["kind"] == "left":
			_leave(pe["peer"])
	for m in _transport.receive():
		_on_message(m["from"], m["data"], now)
	while next_tick_at() <= now + 1e-9:
		_step(now)

## Applies the seen reports that have arrived since the last tick now, between ticks.
func flush_reports(now: float) -> void:
	if ended:
		return
	for m in _transport.receive():
		_on_message(m["from"], m["data"], now)
	if _queue.is_empty():
		return
	var extra: Array[Dictionary] = []
	var s := state
	var q := _queue
	_queue = []
	for item: Array in q:
		s = _apply_report(s, item[0], item[1], extra, s.t)
	state = s
	_states[tick] = s
	for e in extra:
		_log_event(e, tick)

## Replaces the Orderly outright (test hooks). The history is rewritten to the new state.
func replace_orderly(o: Entity.OrderlyState) -> void:
	state = state.copy()
	state.orderly = o
	var h := History.make(o)
	for k: int in _hist.keys():
		_hist[k] = h
	_hist[tick] = h
	_states[tick] = state

## Changes the run outside a tick: f(RunState) -> RunStep. The events reach every client with the next snapshot.
func act(f: Callable) -> void:
	var r: Run.RunStep = f.call(state)
	state = r.state
	_states[tick] = r.state
	for e in r.events:
		_log_event(e, tick)

## Moves a player (the host's decision, like a ride): the client adopts it and acknowledges it.
func place_player(id: String, body: Move.Body) -> void:
	_place(id, body, state.depth, state)
	state = state.copy()
	var players: Array[Run.RunPlayer] = []
	for p in state.players:
		if p.id == id:
			var np := p.copy()
			np.body = body
			players.append(np)
		else:
			players.append(p)
	state.players = players

## Ends the session: every client is told by its transport.
## Live settings (LS2): the values in force from now on ({id: number}, checked by the desk; {} for none), the
## desk's revision, and the change's note ({} for none: a run starting, or nothing to announce). Put on the
## state between ticks, never inside one; the note becomes the next tick's "tuned" event {rev, by, id, was, v,
## when, line}, delivered once to every client like any event. For one second after a change every snapshot
## carries the whole list (the world's tune block), and one a second after that.
func set_tuning(values: Dictionary, rev: int, note: Dictionary = {}) -> void:
	if values.is_empty():
		if state.tuning != null:
			state = state.copy()
			state.tuning = null
	else:
		state = Run.with_tuning(state, values)
	tune_rev = rev
	var ids: Array = values.keys()
	ids.sort()
	_tune_list = []
	for id: Variant in ids:
		_tune_list.append([String(id), float(values[id])])
	_tune_full_until = state.t + 1.0
	if not note.is_empty():
		_tune_events.append({"type": "tuned", "rev": rev, "by": str(note.get("by", "")), "id": str(note.get("id", "")),
			"was": float(note.get("was", 0.0)), "v": float(note.get("v", 0.0)), "when": str(note.get("when", "")), "line": str(note.get("line", ""))})

func close() -> void:
	ended = true
	_transport.close()

func _log_event(e: Dictionary, at_tick: int) -> void:
	var le := LoggedEvent.new()
	le.seq = event_log.size() + 1
	le.tick = at_tick
	le.e = Protocol.plain(e)
	le.text = JsJson.stringify(le.e)
	event_log.append(le)

# -------------------------------------------------------------------------------------------
# Receiving.

func _on_message(from: String, data: String, now: float) -> void:
	var m: Variant = Protocol.decode(data)
	if m == null:
		return
	var ht := host_time(now)
	match String(m["type"]):
		"join":
			_join(from, str(m.get("face", "")), str(m.get("name", "")))
		"leave":
			_leave(from)
		"ping":
			_transport.send(from, Protocol.encode({"type": "pong", "ct": m["ct"], "hr": ht, "st": ht}))
		"input":
			var id: Variant = _by_peer.get(from)
			var p: HostPlayer = _players.get(id) if id != null else null
			if p != null and p.connected and not p.left:
				_on_input(p, m, ht)
		"emote":
			var id: Variant = _by_peer.get(from)
			var p: HostPlayer = _players.get(id) if id != null else null
			if p != null and p.connected and not p.left and p.joined:
				_relay_emote(p, m["emote"], ht)
		"setFace":
			var id: Variant = _by_peer.get(from)
			var p: HostPlayer = _players.get(id) if id != null else null
			if p != null and p.connected and not p.left and p.joined:
				_change_face(p, str(m["face"]), ht)

## A player's new face (the face kiosk): kept and passed on to every other player, once, with "F".
## Ignored when it is not a valid face (the protocol made it ""), when it is the face already kept, or
## within FACE_GAP seconds of the last change taken.
func _change_face(p: HostPlayer, face: String, ht: float) -> void:
	if face == "" or ht - p.last_face_change < FACE_GAP:
		face_changes_ignored += 1
		return
	p.last_face_change = ht
	if face == p.face:
		return
	p.face = face
	face_changes += 1
	if not relay_faces:
		return
	var text := Protocol.encode({"type": "face", "player": p.id, "face": face})
	for q: HostPlayer in _players.values():
		if q != p and q.connected and not q.left and q.joined:
			_transport.send(q.peer, text)
			faces_sent += 1

## An emote: passed on to every other player in the room (not back to its sender), rate limited.
func _relay_emote(p: HostPlayer, emote: String, ht: float) -> void:
	if ht - p.last_emote < EMOTE_GAP:
		emotes_dropped += 1
		return
	p.last_emote = ht
	# A sound emote is heard on the floor (the Playroom: a noise). The run gets it with the next tick.
	if emote in Protocol.SOUND_EMOTES:
		p.emote_pending = true
	var text := Protocol.encode({"type": "emoted", "player": p.id, "emote": emote, "t": ht})
	for q: HostPlayer in _players.values():
		if q != p and q.connected and not q.left and q.joined:
			_transport.send(q.peer, text)
			emotes_relayed += 1

## A join (or a repeated one, when the welcome was lost): the welcome carries the whole state. `face`:
## the face the join carried ("" for none; the protocol has already refused anything not a face).
func _join(peer: String, face: String = "", name: String = "") -> void:
	var id: Variant = _by_peer.get(peer)
	var p: HostPlayer = _players.get(id) if id != null else null
	if p != null and p.left:
		return  # no rejoining under the same peer (known limit)
	if p == null:
		id = peer if (_roster_ids.has(peer) or not _players.has(peer)) else "p%d" % _next_id
		if id != peer:
			_next_id += 1
		p = _new_player(id, peer, false)
		_players[id] = p
		_by_peer[peer] = id
		# A spectator from the first event after now; the welcome carries the state.
		p.ack_event = event_log.size()
	p.connected = true
	p.joined = true
	if name != "":
		p.name = name
	var ev_from := p.ack_event + 1
	_transport.send(peer, Protocol.encode({"type": "welcome", "you": p.id, "seed": seed, "playing": p.in_run, "evFrom": ev_from, "world": world(true)}))
	_share_faces(p, face)

## Faces, after a (repeated) welcome: the joiner gets every other player's face (so a late joiner has
## everyone's), and the others get the joiner's, once: only when it is new or changed. Never in the
## snapshot.
func _share_faces(p: HostPlayer, face: String) -> void:
	if not relay_faces:
		return
	for q: HostPlayer in _players.values():
		if q != p and q.face != "":
			_transport.send(p.peer, Protocol.encode({"type": "face", "player": q.id, "face": q.face}))
			faces_sent += 1
	if face == "" or face == p.face:
		return
	p.face = face
	var text := Protocol.encode({"type": "face", "player": p.id, "face": face})
	for q: HostPlayer in _players.values():
		if q != p and q.connected and not q.left and q.joined:
			_transport.send(q.peer, text)
			faces_sent += 1

func _leave(peer: String) -> void:
	var id: Variant = _by_peer.get(peer)
	var p: HostPlayer = _players.get(id) if id != null else null
	if p == null or p.left:
		return
	p.left = true
	p.connected = false
	p.input = null
	if _pending_catch != null and _pending_catch["victim"] == p.id:
		_pending_catch = null

func _on_input(p: HostPlayer, m: Dictionary, ht: float) -> void:
	p.ack_event = maxi(p.ack_event, mini(int(m["ackEvent"]), event_log.size()))
	p.ack_ht = maxf(p.ack_ht, m["ackHt"])
	p.render_time = maxf(p.render_time, m["renderTime"])
	if p.place != null and int(m["placeAck"]) >= int(p.place["seq"]):
		p.place_ack = maxi(p.place_ack, int(m["placeAck"]))
	for r: Dictionary in m["seen"]:
		var rid: int = r["id"]
		if p.seen_done.has(rid):
			continue
		p.seen_done[rid] = true
		_queue.append([p.id, r])
	while p.seen_done.has(p.ack_seen + 1):
		p.ack_seen += 1
	var seq: int = m["seq"]
	if seq <= p.last_seq:
		return
	p.last_seq = seq
	p.input = m
	p.input_at = ht
	p.echo = [m["ct"], ht]
	if int(m["calls"]) > p.calls:
		p.calls = m["calls"]
		p.call_pending = true
	if int(m["pickUps"]) > p.pick_ups:
		p.pick_ups = m["pickUps"]
		p.pick_pending = true
	if int(m.get("hides", 0)) > p.hides:
		p.hide_pending = true
		p.hide_fast = int(m.get("fastHides", 0)) > p.fast_hides
		p.hides = int(m["hides"])
		p.fast_hides = int(m.get("fastHides", 0))
	if int(m.get("marks", 0)) > p.marks:
		p.marks = int(m["marks"])
		p.mark_pending = true
	if int(m.get("peels", 0)) > p.peels:
		p.peels = int(m["peels"])
		p.peel_pending = int(m.get("peelId", -1))
	_step_gait(p, m)
	# The body: not until the client has the latest placement; never further than they could go.
	if p.place != null and int(m["placeAck"]) < int(p.place["seq"]):
		return
	var mb: Move.Body = m["body"]
	if p.body != null and p.body_ct != null and not _trusted.has(p.id):
		var flat := M.hypot2(mb.x - p.body.x, mb.z - p.body.z)
		# Climbing a stair adds height at most 0.8 m per metre; anything steeper counts as distance.
		var jump := flat + maxf(0.0, absf(mb.y - p.body.y) - 0.85 * flat)
		if jump > p.allowance + 1e-9:
			stats.clamped_inputs += 1
			return
		p.allowance = minf(Session.JUMP_SLACK, p.allowance - jump)
	else:
		p.allowance = Session.JUMP_SLACK
	p.body = mb
	p.body_ct = m["ct"]

## The tank, stepped on a new input over the client time since the previous one.
func _step_gait(p: HostPlayer, m: Dictionary) -> void:
	var ct: float = m["ct"]
	var dt := 0.0 if p.last_ct == null else maxf(0.0, ct - float(p.last_ct))
	var from := p.claim
	var mb: Move.Body = m["body"]
	var ground := M.hypot2(mb.x - from.x, mb.z - from.z) / dt if (dt > 0.0 and from != null and from.level == mb.level) else 0.0
	var want := String(m.get("gait", "walk"))
	var cap := Instr.max_walk_speed(m["raised"], INF)
	# The run's tank size (bigger in a paced run: sim/run.gd sprint_seconds).
	var tank := Run.sprint_seconds(state)
	if p.stamina.tank != tank:
		p.stamina = Stamina.Stamina.make(p.stamina.level, p.stamina.winded, tank)
	var gait := String(Stamina.gait_for(p.stamina, want == "sprint", want == "creep", ground > 0.0, cap))
	p.allowance += (Session.MAX_PLAYER_SPEED if gait == "sprint" else Stamina.WALK_SPEED) * dt
	p.stamina = Stamina.step_stamina(p.stamina, StringName(gait), ground, dt)
	p.gait = gait
	p.last_ct = ct
	p.claim = mb

# -------------------------------------------------------------------------------------------
# The tick.

func _run_player(id: String) -> Run.RunPlayer:
	return _find_run_player(state, id)

func _playing(p: HostPlayer) -> bool:
	if not (p.in_run and p.connected and not p.left and p.input != null):
		return false
	var rp := _run_player(p.id)
	return rp != null and rp.status == &"ok"

func _step(now: float) -> void:
	var ht := host_time(now)
	var extra: Array[Dictionary] = []
	var s := state
	var t_next := s.t + TICK

	# 1. What the clients saw.
	# A Lonely Temp (sim/lonely.gd) is not Stillness: looking does nothing, so no report is applied to it.
	var still := Run.resident_of(s).stillness
	var q := _queue
	_queue = []
	if still:
		for item: Array in q:
			s = _apply_report(s, item[0], item[1], extra, t_next)

	# 2. Anyone saying they can see it now: held, and a wind-up is off. With two watchers needed, each
	# is one watcher for the count instead (Entity.note_look): a lone one holds nothing.
	var seeing := false
	var two := s.orderly.need >= 2
	for p: HostPlayer in _players.values():
		if still and _playing(p) and p.input["seeing"] == true and ht - p.input_at <= Session.SEEING_TIMEOUT and _before_armed(p.input["renderTime"], true):
			seeing = true
			if not two:
				break
			var looked := Entity.note_look(s.orderly, p.id, s.orderly.t)
			if looked != s.orderly:
				s = s.copy()
				s.orderly = looked
	if seeing and not two:
		s = _hold(s, true, extra, t_next, false)

	# 3. A catch waits for its victim's screen.
	s = _confirm_catch(s, ht)

	# The players' names, for the Annex's notes (sim/run.gd names).
	var names := {}
	for rp in s.players:
		var hp: HostPlayer = _players.get(rp.id)
		if hp != null and hp.name != "":
			names[rp.id] = hp.name
	if names != s.names:
		s = s.copy()
		s.names = names

	# 4. Inputs.
	var inputs: Array[Run.PlayerInput] = []
	for rp in s.players:
		var p: HostPlayer = _players.get(rp.id)
		if p != null and rp.status == &"down" and s.downs and p.in_run and p.connected and not p.left and p.input != null:
			# Down: they crawl. Their body and view only, blind; nothing they press counts.
			var dm: Dictionary = p.input
			var di := Run.PlayerInput.make(p.id, p.body if p.body != null else rp.body, dm["eye"], dm["yaw"], dm["pitch"], dm["hFovDeg"], dm["vFovDeg"])
			di.blind = true
			di.gait = &"creep"
			inputs.append(di)
			p.call_pending = false
			p.pick_pending = false
			p.hide_pending = false
			p.emote_pending = false
			p.mark_pending = false
			p.peel_pending = -1
			continue
		if p == null or not _playing(p) or p.input == null:
			if p != null:
				# Out of the run this tick: a press or an emote made meanwhile is not saved up for later.
				p.hide_pending = false
				p.emote_pending = false
				p.mark_pending = false
				p.peel_pending = -1
			continue
		var m: Dictionary = p.input
		var pc: Variant = _pending_catch
		var body: Move.Body
		if pc != null and pc["victim"] == p.id and pc["body"] != null:
			body = pc["body"]
		else:
			body = p.body if p.body != null else rp.body
		var inp := Run.PlayerInput.make(p.id, body, m["eye"], m["yaw"], m["pitch"], m["hFovDeg"], m["vFovDeg"])
		inp.raised = m["raised"]
		inp.hold_doors = m["holdDoors"]
		# While a catch waits for its victim, a player drawing a moment past the wind-up's end cannot save them.
		inp.blind = not _before_armed(m["renderTime"], false)
		inp.call = p.call_pending
		inp.pick_up = true if p.pick_pending else null
		inp.use = m.get("use", false) == true
		# The Playroom (sim/run.gd): the gait the tank allowed, the hide key, W in a hide, a sound emote.
		inp.gait = StringName(p.gait)
		inp.hide_use = p.hide_pending
		inp.hide_fast = p.hide_pending and p.hide_fast
		inp.peek = m.get("peek", false) == true
		inp.emote_sound = p.emote_pending
		# The Annex (sim/run.gd): Q pressed, a peel asked for.
		inp.mark = p.mark_pending
		inp.peel = p.peel_pending
		inputs.append(inp)
		p.call_pending = false
		p.pick_pending = false
		p.hide_pending = false
		p.emote_pending = false
		p.mark_pending = false
		p.peel_pending = -1

	# 5. The run.
	var r: Run.RunStep = _step_fn.call(s, inputs, TICK)
	var st := r.state
	var events: Array[Dictionary] = []
	events.append_array(extra)
	for te in _tune_events:
		te["t"] = t_next
		events.append(te)
	_tune_events = []
	events.append_array(r.events)

	# 6. After: placements, the gone, joiners.
	for e in r.events:
		var ty: String = e["type"]
		if ty == "doorsClosed":
			var pushed: Dictionary = e["pushedOut"]
			for id: String in pushed:
				_place(id, pushed[id], st.depth, st)
		elif ty == "rodeDown" or ty == "rodeUp" or ty == "newDay":
			var bodies: Dictionary = e["bodies"]
			for id: String in bodies:
				_place(id, bodies[id], st.depth, st)
		elif ty == "hideIn" or ty == "hideLeave" or ty == "found" or ty == "taken" or ty == "down" or ty == "downed" or ty == "healed":
			# The Playroom: the rules hold the body (in a hide, at its front, rooted, at the table). Down first,
			# then out: where they fell, and where they get up.
			var hp := _find_run_player(st, str(e["playerId"]))
			if hp != null:
				_place(hp.id, hp.body, st.depth, st)
		elif ty == "caught":
			_last_catch_tick = tick + 1
			if _pending_catch != null and _pending_catch["victim"] == e["playerId"]:
				_pending_catch = null
		elif ty == "windUpCancelled" and _pending_catch != null and _pending_catch["victim"] == e["playerId"]:
			_pending_catch = null
	# The tuned Playroom (sim/seek.gd T15m): a grabbed player being dragged to the party table is placed where
	# the rules hold them every tick, so their own screen goes along with it.
	if st.seek != null and (st.seek as Seek.SeekState).tuned and (st.seek as Seek.SeekState).minder.mode == &"drag":
		var dp := _find_run_player(st, (st.seek as Seek.SeekState).minder.victim)
		if dp != null:
			_place(dp.id, dp.body, st.depth, st)
	if st.orderly.mode != &"windUp":
		_pending_catch = null
	var gone := {}
	for p: HostPlayer in _players.values():
		if p.in_run and p.left:
			gone[p.id] = true
	if not gone.is_empty() and st.phase != &"ended":
		st = st.copy()
		var players: Array[Run.RunPlayer] = []
		for p in st.players:
			if gone.has(p.id) and p.status == &"ok":
				var np := p.copy()
				np.status = &"leftBehind"
				np.side = null
				players.append(np)
			else:
				players.append(p)
		st.players = players
	if st.phase == &"arriving":
		st = _admit(st)
	state = st
	tick += 1
	stats.ticks += 1
	for e in events:
		_log_event(e, tick)
	_record()
	_send_snapshots(ht)
	if on_tick.is_valid():
		on_tick.call(r.events)

func _record() -> void:
	var s := state
	_hist[tick] = History.make(s.orderly)
	_hist.erase(tick - HISTORY_TICKS)
	_sent_watch[tick] = [s.t, s.orderly.need, s.orderly.watchers]
	_sent_watch.erase(tick - HISTORY_TICKS)
	_states[tick] = s
	_states.erase(tick - STATE_TICKS)

## `s`: the run the placement is on (its day index goes with it when it has days).
func _place(id: String, body: Move.Body, depth: int, s: Run.RunState) -> void:
	var p: HostPlayer = _players.get(id)
	if p == null:
		return
	var seq: int = (int(p.place["seq"]) if p.place != null else 0) + 1
	p.place = {"seq": seq, "depth": depth, "body": Protocol.q_body(body)}
	if s.days:
		p.place["day"] = s.day_index
	p.body = body
	p.body_ct = null
	p.claim = null

## Spectators waiting for the next stop join the run now (the car is here, doors shut, crew inside). With
## `admit_only` set (the home server's room: ready-up, findables-and-day.md section 2) only those it lists
## (by peer) are taken; the rest wait for a later stop.
func _admit(s: Run.RunState) -> Run.RunState:
	var waiting: Array[HostPlayer] = []
	for p: HostPlayer in _players.values():
		if not p.in_run and p.connected and not p.left and (admit_only == null or (admit_only as Dictionary).has(p.peer)):
			waiting.append(p)
	if waiting.is_empty():
		return s
	var players: Array[Run.RunPlayer] = s.players.duplicate()
	var crew := s.crew
	for p in waiting:
		var k := players.size()
		var body := Run.car_body(s.car, 0.9 + 0.9 * (floori(k / 2.0) % 3), 1.0 if k % 2 == 1 else -1.0)
		var rp := Run.RunPlayer.new()
		rp.id = p.id
		rp.body = body
		rp.status = &"ok"
		rp.aboard = true
		rp.side = null
		players.append(rp)
		var c := crew.copy()
		var mem := Instr.CrewMember.new()
		mem.id = p.id
		mem.body = null
		mem.active = true
		mem.instrument = Instr.create_instrument()
		mem.tape = TapeLib.empty_tape("tape-%d" % crew.next_tape, p.id)
		mem.carrying = []
		c.members.append(mem)
		c.next_tape = crew.next_tape + 1
		crew = c
		p.in_run = true
		_place(p.id, body, s.depth, s)
	var out := s.copy()
	out.players = players
	out.crew = crew
	return out

# -------------------------------------------------------------------------------------------
# Holding the Orderly.

## Treats the Orderly as seen this tick. `full`: with the usual grace after (as if a player saw it);
## otherwise only for this tick. A full hold also cancels a wind-up: looking always saves you.
func _hold(s: Run.RunState, full: bool, extra: Array[Dictionary], t: float, by_report: bool) -> Run.RunState:
	var o := s.orderly
	var last := o.t if full else o.t - Entity.GRACE + TICK / 2.0
	if o.last_seen_at == null or float(o.last_seen_at) < last:
		o = o.copy()
		o.last_seen_at = last
	# Two watchers needed: the same hold, on the count (Entity.hold_met; with one needed it changes nothing).
	o = Entity.hold_met(o, last)
	if full and o.mode == &"windUp":
		extra.append({"type": "windUpCancelled", "t": t, "playerId": o.wind_up_target if o.wind_up_target != null else ""})
		if by_report:
			stats.wind_ups_cancelled_by_report += 1
		o = o.copy()
		o.mode = &"hunting"
		o.wind_up_target = null
		o.wind_up_left = 0.0
		o.replan_in = 0.0
		_pending_catch = null
	if o == s.orderly:
		return s
	var out := s.copy()
	out.orderly = o
	return out

## Whether a sighting at drawn host time `t` still counts while a catch waits.
func _before_armed(t: float, count: bool) -> bool:
	var pc: Variant = _pending_catch
	if pc == null or t < float(pc["armedAt"]) - 1e-6:
		return true
	if count:
		stats.late_sightings += 1
	return false

func _confirm_catch(s: Run.RunState, ht: float) -> Run.RunState:
	var o := s.orderly
	if o.mode != &"windUp" or o.wind_up_left - TICK > EPS or o.wind_up_target == null or String(o.wind_up_target).is_empty():
		return s
	# Already held this tick by grace: it will not complete now anyway.
	if Entity.held_by_grace(o):
		return s
	var victim := String(o.wind_up_target)
	if _pending_catch == null or _pending_catch["victim"] != victim:
		var vp := _find_run_player(s, victim)
		_pending_catch = {"victim": victim, "armedAt": s.t + TICK, "armedHost": ht, "body": vp.body if vp != null else null}
	var pc: Dictionary = _pending_catch
	var p: HostPlayer = _players.get(victim)
	var gone := p == null or not p.connected or p.left
	var shown := p != null and p.ack_ht >= float(pc["armedAt"]) - 1e-6 and p.render_time >= float(pc["armedAt"]) - 1e-6
	if gone or shown:
		return s
	if ht - float(pc["armedHost"]) >= Session.CATCH_CONFIRM_MAX:
		stats.catches_forced += 1
		return s
	stats.catch_hold_ticks += 1
	return _hold(s, false, [], s.t + TICK, false)

func _apply_report(s: Run.RunState, player_id: String, r: Dictionary, extra: Array[Dictionary], t: float) -> Run.RunState:
	var p: HostPlayer = _players.get(player_id)
	if p == null or not _playing(p):
		return s
	stats.reports += 1
	var ra: int = r["a"]
	var rb: int = r["b"]
	var alpha: float = r["alpha"]
	# A catch waiting for its victim: a sighting of a moment after the wind-up's end saves nobody.
	if not _before_armed((ra + (rb - ra) * alpha) * TICK, true):
		return s
	if int(r["depth"]) != s.depth:
		stats.stale_reports += 1
		return s
	# Relocation (sim/relocate.gd): a sighting from before it relocated is of a place it has left, where nobody
	# could see it; the client snaps to the new pose and never draws between (net/client.gd). Nothing to put back.
	var hr: History = _hist.get(rb, _hist.get(ra))
	if hr != null and hr.o.relocations != s.orderly.relocations:
		stats.stale_reports += 1
		return s
	# Two watchers needed: honoured only if what this player had been sent let one look hold it.
	if not _report_honoured(s, p, r):
		reports_unheld += 1
		var looked := Entity.note_look(s.orderly, player_id, s.orderly.t)
		if looked == s.orderly:
			return s
		var out0 := s.copy()
		out0.orderly = looked
		return out0
	var ha: History = _hist.get(ra)
	var hb: History = _hist.get(rb, ha)
	if ha == null or hb == null:
		stats.stale_reports += 1
		return _hold(s, true, extra, t, true)
	var expected := Pose.lerp_pose(ha.pose, hb.pose, alpha)
	var rpose: Dictionary = r["pose"]
	var target: Dictionary = rpose if _close_pose(expected, rpose) else expected
	var o := s.orderly
	var gap := M.hypot3(o.body.x - float(target["x"]), o.body.z - float(target["z"]), o.body.y - float(target["y"]))
	if gap <= 1e-6 and o.body.level == int(target["level"]) and absf(o.yaw - float(target["yaw"])) < 1e-3:
		return _hold(s, true, extra, t, true)
	# The client froze on the host's own pose as sent (to the centimetre): nothing to put back.
	var sent := Protocol.orderly_snap(o)
	if sent["x"] == target["x"] and sent["y"] == target["y"] and sent["z"] == target["z"] and sent["level"] == int(target["level"]) and sent["yaw"] == target["yaw"]:
		return _hold(s, true, extra, t, true)
	if gap > Session.PUT_BACK_MAX:
		stats.bound_violations += 1
		stats.max_violation_gap = maxf(stats.max_violation_gap, gap)
		return _hold(s, true, extra, t, true)
	if _last_catch_tick > ra:
		stats.after_catch += 1
		return _hold(s, true, extra, t, true)
	var base := (ha if alpha < 0.5 else hb).o
	# Never back into a wall or the car: blends across a missing snapshot can cut a corner.
	if not _valid_spot(s, Pose.pose_body(target)):
		target = {"x": base.body.x, "y": base.body.y, "z": base.body.z, "level": base.body.level, "yaw": base.yaw, "anim": String(base.anim), "animTime": base.anim_time}
	var was_winding := o.mode == &"windUp"
	var mode: StringName = &"hunting" if base.mode == &"windUp" else base.mode
	var restored := base.copy()
	restored.t = o.t
	restored.body = Pose.pose_body(target)
	restored.yaw = target["yaw"]
	restored.anim = StringName(target["anim"])
	restored.anim_time = target["animTime"]
	restored.mode = mode
	restored.wind_up_target = null
	restored.wind_up_left = 0.0
	restored.seen = true
	restored.held = true
	restored.frozen = mode == &"hunting"
	restored.moving = false
	restored.speed = 0.0
	restored.ever_seen = true
	restored.last_seen_at = o.t
	Entity.keep_count(restored, o)
	Entity.keep_relocation(restored, o)
	restored.last_met_at = o.t
	restored.replan_in = 0.0
	restored.dormant_left = base.dormant_left if mode == &"dormant" else 0.0
	# The put-back freezes it outright, so the tick will not see the change: report it here.
	if restored.frozen and not o.frozen:
		extra.append({"type": "froze", "t": t, "playerId": player_id})
	if was_winding:
		extra.append({"type": "windUpCancelled", "t": t, "playerId": o.wind_up_target if o.wind_up_target != null else ""})
		stats.wind_ups_cancelled_by_report += 1
		_pending_catch = null
	stats.put_backs += 1
	stats.max_put_back = maxf(stats.max_put_back, gap)
	stats.put_back_distances.append(gap)
	# Rewrite the history: from that moment it stood there.
	var h := History.make(restored)
	for k: int in _hist.keys():
		if k > ra:
			_hist[k] = h
	var out := s.copy()
	out.orderly = restored
	return out

## Two-watcher Stillness (T19a): whether a seen report may hold the resident. With one watcher needed,
## always (the old rule). With two, only if a snapshot this player had been sent and acknowledged (from the
## newer of the two it drew from, up to its ackHt) said one look was enough: one watcher needed, or another
## player counted. That other watcher may have looked away since: the client held on what it was told, so
## the host holds too. A report with nothing recorded to judge it by (older than the history) is honoured.
func _report_honoured(s: Run.RunState, p: HostPlayer, r: Dictionary) -> bool:
	if s.orderly.need <= 1:
		return true
	var judged := false
	for k in range(int(r["b"]), tick + 1):
		var w: Variant = _sent_watch.get(k)
		if w == null:
			continue
		if float(w[0]) > p.ack_ht + 1e-6:
			break
		judged = true
		if int(w[1]) <= 1:
			return true
		for id: String in w[2]:
			if id != p.id:
				return true
	return not judged

func _valid_spot(s: Run.RunState, b: Move.Body) -> bool:
	var plan := s.plan
	if b.level == s.car.level and Run.rect_distance(s.car.rect, b.x, b.z) < Entity.ORDERLY_RADIUS:
		return false
	if not Floor.is_walkable(plan, b.level, floori(b.x / plan.cell_size), floori(b.z / plan.cell_size)):
		return false
	return Move.wall_clearance(plan, b.level, b.x, b.z) >= Entity.ORDERLY_RADIUS - 0.02

static func _close_pose(a: Dictionary, b: Dictionary) -> bool:
	return int(a["level"]) == int(b["level"]) and M.hypot3(float(a["x"]) - float(b["x"]), float(a["y"]) - float(b["y"]), float(a["z"]) - float(b["z"])) <= 0.05

# -------------------------------------------------------------------------------------------
# Sending.

static func _tape(t: TapeLib.Tape) -> Dictionary:
	return {"id": t.id, "owner": t.owner_id, "readings": t.readings.size(), "total": t.total}

## The shared part of a snapshot (also the welcome's state). `full`: the welcome's, with every note of
## an Annex floor (a snapshot carries only how many there are).
func world(full: bool = false) -> Dictionary:
	var s := state
	var blink: Variant = null
	if s.blink != null:
		var b := s.blink
		blink = {"at": b.at, "len": b.len, "warn": b.warn, "blackout": b.blackout, "announced": b.announced, "endsAt": b.ends_at}
	var players: Array = []
	for rp in s.players:
		var p: HostPlayer = _players.get(rp.id)
		var m: Variant = p.input if p != null else null
		var playing := p != null and _playing(p)
		players.append({
			"id": rp.id, "body": rp.body,
			"yaw": m["yaw"] if m != null else 0.0, "pitch": m["pitch"] if m != null else 0.0,
			"active": playing, "status": String(rp.status), "aboard": rp.aboard,
			"side": String(rp.side) if rp.side != null else null,
			"connected": p != null and p.connected, "gait": p.gait if playing else "walk",
		})
	var crew: Array = []
	for m in s.crew.members:
		var carrying: Array = []
		for t in m.carrying:
			carrying.append(_tape(t))
		crew.append({"id": m.id, "needle": String(m.instrument.needle), "raised": m.instrument.raised,
			"open": m.instrument.current.value if m.instrument.current != null else 0.0, "rate": m.instrument.rate,
			"tickHz": m.instrument.tick_hz, "tape": _tape(m.tape), "carrying": carrying})
	var fl: Array = []
	for f in s.crew.floor:
		var d := _tape(f.tape)
		d["at"] = f.at
		fl.append(d)
	var out := {
		"tick": tick, "ht": s.t, "phase": String(s.phase), "depth": s.depth, "timer": s.timer,
		"floorsAway": s.call.floors_away if s.call != null else null, "bellLeft": s.bell_left, "holdLeft": s.hold_left,
		"held": s.held, "blink": blink, "orderly": Protocol.orderly_snap(s.orderly), "players": players, "crew": crew,
		"floor": fl, "summary": Protocol.summary_plain(s.summary),
	}
	if s.days:
		out["day"] = day_block(s)
	if s.seek != null or s.hiding != null:
		out["seek"] = seek_block(s)
	if s.quota:
		out["quota"] = quota_block(s)
	if s.annex != null:
		out["annex"] = annex_block(s, full)
	if s.downs:
		out["downs"] = downs_block(s)
	var watch: Variant = watch_block(s)
	if watch != null:
		out["watch"] = watch
	# Relocation (T19e): the count, once it has relocated on this floor (Protocol "reloc").
	if s.orderly.relocations > 0:
		out["reloc"] = s.orderly.relocations
	# Lonely (T19c): on a Lonely resident's floor, who it chases ("" for nobody; Protocol "lonely").
	if not Run.at_home(s) and Run.resident_of(s).trait_name == &"lonely":
		var o := s.orderly
		out["lonely"] = str(o.lonely_target) if o.lonely_phase == &"chase" and o.lonely_target != null else ""
	# Solid furniture (FD7): the clients move their own bodies round it (Protocol "solid").
	if s.furniture:
		out["solid"] = 1
	# Live settings (LS2): the revision in force, with the whole list in the welcome, for a second after a change
	# and once a second after that (Protocol "tune"). Absent while never tuned.
	if tune_rev > 0:
		out["tune"] = [tune_rev, _tune_list.duplicate()] if full or _tune_list_due else [tune_rev]
	return out

## Two-watcher Stillness (T19a; Protocol.enc_watch): the count as the host has it this tick, {need,
## watchers (ids, with grace)}. Only in a run with two-watcher Stillness on and Entity.WATCH_CREW or more
## players (null otherwise): with fewer, one watcher is always enough, and the snapshot is what it always was.
static func watch_block(s: Run.RunState) -> Variant:
	if not s.two_watchers or s.players.size() < Entity.WATCH_CREW:
		return null
	var ids: Array = []
	for id in s.orderly.watchers:
		ids.append(id)
	return {"need": s.orderly.need, "watchers": ids}

## The downs block of a run with the down rule (Protocol.enc_downs): who is down (in the run's player order),
## when they went down and when they are out unless healed, who holds F beside them and since when (host
## times), and this floor's red spots.
static func downs_block(s: Run.RunState) -> Dictionary:
	var down: Array = []
	for p in s.players:
		var d: Run.Downed = s.down.get(p.id)
		if d == null:
			continue
		var row := {"id": d.id, "at": d.at, "until": d.until, "by": String(d.by), "healer": d.healer,
			"healFrom": d.heal_from if d.healer != "" else null}
		# Live settings: a hold the host timed differently from Run.HEAL_TIME says how long it takes (Protocol "healFor").
		if d.healer != "" and d.heal_len != Run.HEAL_TIME:
			row["healFor"] = d.heal_len
		down.append(row)
	return {"down": down, "spots": s.spots.duplicate()}

## The Annex's block (Protocol.enc_annex): the crew's pad, every mark down, and this floor's notes (how
## many, and with `full` every one). Null off the Annex.
static func annex_block(s: Run.RunState, full: bool = false) -> Variant:
	if s.annex == null:
		return null
	var a := s.annex
	var marks: Array = []
	for m in a.marks.marks:
		marks.append(Run.mark_plain(m))
	var out := {"pad": a.marks.pad, "padSize": a.marks.pad_size, "marks": marks, "notesFrom": a.notes_from, "noteCount": a.notes.size()}
	if full:
		out["notes"] = a.notes.duplicate()
	return out

## The floor quota block of a run with the quota (Protocol.enc_quota): whole credits recorded on this
## floor against this floor's quota.
static func quota_block(s: Run.RunState) -> Dictionary:
	return {"earned": floori(s.floor_earned), "needed": s.floor_needed}

## The Playroom's seek block (Protocol.enc_seek): the count in host times, and each player's hide,
## peek, health and totals, plus the crew's noise. Null off the Playroom.
static func seek_block(s: Run.RunState) -> Variant:
	if s.seek == null:
		return hiding_block(s)
	var ss: Seek.SeekState = s.seek
	var players: Array = []
	for sp in ss.players:
		players.append({"id": sp.id, "hide": sp.hide, "peek": sp.peeking, "phase": String(sp.phase), "status": String(sp.status),
			"health": sp.health, "sight": sp.sight, "gap": sp.gap, "seat": sp.seat})
	var k := {"noise": ss.noise, "counting": ss.counting, "last": ss.last, "called": ss.called, "done": ss.done, "n": ss.counts,
		"t0": ss.t0, "len": ss.len, "by": ss.by, "why": String(ss.why), "ended": ss.ended, "calmUntil": ss.calm_until,
		"lastAt": ss.last_at, "players": players}
	# T15m (sim/seek.gd tune): the anger bar and the count's seconds to hide, the host's own numbers.
	if ss.tuned:
		k["anger"] = ss.anger
		k["hide"] = ss.hide_len
	return k

## Hiding off the Playroom (sim/hiding.gd, T19b) in the seek block's shape (Protocol.enc_seek, no new
## field): each player's hide, peek and phase, everyone "ok"; no count, nothing found, no health. Sent from
## the first hide press on a Clinic or an Annex until the next floor. Null when nobody has hidden here.
static func hiding_block(s: Run.RunState) -> Variant:
	if s.hiding == null:
		return null
	var hs: Hiding.HidingState = s.hiding
	var players: Array = []
	for rp in s.players:
		var hp := Hiding.player_of(hs, rp.id)
		var inside := hp != null and hp.phase != &"out"
		players.append({"id": rp.id, "hide": hp.hide if inside else -1, "peek": hp.peeking if hp != null else false,
			"phase": String(hp.phase) if hp != null else "out", "status": "ok", "health": Seek.HEALTH_MAX, "sight": 0.0, "gap": 0.0, "seat": -1})
	return {"noise": 0.0, "counting": false, "last": false, "called": false, "done": false, "n": 0,
		"t0": 0.0, "len": 0.0, "by": "", "why": "", "ended": 0, "calmUntil": 0.0, "lastAt": null, "players": players}

## The day block of a run with days (Protocol.enc_day): host times, never durations, so every screen
## counts down to the same moment.
static func day_block(s: Run.RunState) -> Dictionary:
	var b := s.bed
	var lights: Variant = null
	var count_from: Variant = null
	var in_bed: Array = []
	var crew := s.players.size()
	if b != null:
		in_bed = b.in_bed.duplicate()
		crew = b.crew.size()
		if b.count_from >= 0.0:
			count_from = b.count_from
		var at := Day.lights_out_at(b)
		if not is_inf(at):
			lights = at
	var out := {"index": s.day_index, "day": s.day_state.day, "quota": Day.day_quota(s.day_state, Run.DAY_FLOOR_QUOTA), "streak": s.day_state.streak,
		"misses": s.day_state.misses, "inBed": in_bed, "countFrom": count_from, "lightsOutAt": lights,
		"result": Protocol.plain(s.day_result) if s.day_result != null else null, "crew": crew}
	if s.day_lock:
		# The day quota's lock (FD2): the host's numbers for the HUD line and the lift monitor.
		var pv: Day.Preview = Run.day_preview(s)
		out["earned"] = pv.earned
		out["locked"] = pv.locked
		out["aboard"] = pv.banked
		out["each"] = pv.each
		out["stakes"] = pv.rows[2]
	return out

func _send_snapshots(ht: float) -> void:
	_tune_list_due = false
	if tune_rev > 0 and (state.t <= _tune_full_until + 1e-9 or state.t - _tune_last_full >= 1.0 - 1e-9):
		_tune_list_due = true
		_tune_last_full = state.t
	var w := world()
	var text := Protocol.world_json(w)
	var in_run := state.players.size()
	for p: HostPlayer in _players.values():
		if not p.connected or p.left or not p.joined:
			continue
		var evs := PackedStringArray()
		var bytes := 0
		for i in range(p.ack_event, event_log.size()):
			var et := event_log[i].text
			var b := et.length() + 1
			if evs.size() > 0 and bytes + b > Session.EVENT_BUDGET:
				break
			evs.append(et)
			bytes += b
		var place: Variant = p.place if (p.place != null and int(p.place["seq"]) > p.place_ack) else null
		var head := {"st": ht, "ackIn": p.last_seq, "echo": [p.echo[0], ht - float(p.echo[1])] if p.echo != null else null,
			"ackSeen": p.ack_seen, "evFrom": p.ack_event + 1, "place": place, "stamina": p.stamina if p.in_run else null}
		var data := Protocol.snapshot_text(head, evs, text)
		_transport.send(p.peer, data)
		stats.snapshots += 1
		stats.snapshot_bytes += data.length()
		stats.max_snapshot_bytes = maxi(stats.max_snapshot_bytes, data.length())
		if keep_sizes:
			snapshot_sizes.append([in_run, data.length()])

## A member's tapes as the host has them (tests): "id:readings:total".
func tapes_of(id: String) -> Array[String]:
	var out: Array[String] = []
	var m := Instr.member(state.crew, id)
	if m == null:
		return out
	var all: Array[TapeLib.Tape] = [m.tape]
	all.append_array(m.carrying)
	for t in all:
		out.append("%s:%d:%s" % [t.id, t.readings.size(), M.to_fixed(t.total, 2)])
	return out
