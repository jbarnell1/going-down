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
# With the party table (sim/run.gd party_table, T15h) F held ("use") reaches the run as always; a "tableFreed"
# places everyone it freed beside the table, and the seek block carries who is freeing it (Protocol.enc_seek).
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
# A second Orderly (sim/run.gd second_orderly; T9b): everything above holds for each Orderly on its own. The
# second's seen reports carry "n": 2 and "I can see it" for it is the input's "seeing2"; the host keeps its own
# history, counts as sent and catch waiting (_hist2, _sent_watch2, _pending_catch2) and runs exactly the first's
# code on it (_second_reports: the second swapped in). Each catch wait blinds a late sighting to its own Orderly
# only (PlayerInput blind_first, blind_second). Every snapshot on its floor carries "orderly2", "reloc2" and, with
# two watchers needed, "watch2" (Protocol "o2"); events from the host about it carry "n": 2, as the run's do.
#
# Live settings (docs/floors/live-settings.md LS2; set_tuning): the room's desk decides what is in force and hands it
# over between ticks; the host puts it on the state (RunState.tuning, read by the rules), announces a change with the
# next tick's "tuned" event, and adds the tune block to the snapshots once the revision is above 0. A run nobody
# tunes sends exactly what it did before.
extends RefCounted

const ReactorReview := preload("res://net/reactor_review.gd")
const Ward = preload("res://sim/ward/state.gd")
const RiggerRoam = preload("res://sim/ward/roam.gd")
const WardSettings = preload("res://sim/settings.gd")
const WardLayout = preload("res://sim/ward/layout.gd")
const HostRules = preload("res://net/host_rules.gd")

const Run = preload("res://sim/run.gd")
const Split = preload("res://sim/split.gd")
## DG0: the dangers (sim/dangers.gd) and their questions (sim/dangers/effects.gd).
const Dangers = preload("res://sim/dangers.gd")
const DangerFx = preload("res://sim/dangers/effects.gd")
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
const Findables = preload("res://sim/findables.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const StationPlan = preload("res://sim/station.gd")

const EPS := 1e-9
const TICK := Session.TICK
## VC2, the intercom's hush (the owner, 20 Nov: "if people are talking a lot when the intercom goes off, the intercom
## responds to that with a throat clearing and asking them to be quiet and then continues saying what I was saying
## before"; "I agree to intercom hushing."). The host decides from the levels it already has, so every screen hears the
## same thing: while two or more players are talking, or one is shouting, it sends the event "crewNoisy" {t, talkers,
## shouting} at most once every HUSH_EVERY seconds; each screen's announcer (client/announcer.gd hush) stops a hushable
## line, shows the hush and says the line again from its start, at most once a line and once a minute. Only in a run
## with the voice (VC1). Talking: level 5 or more (sim/noise.gd VOICE_TALK_AT) for HUSH_HOLD seconds, ending HUSH_GAP
## seconds after the last; shouting the same at level 11 or more. No rule reads it.
const HUSH_EVERY := 1.0
const HUSH_HOLD := 0.2
const HUSH_GAP := 0.4
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
	## VC1: the loudest microphone level (0 to 15) their inputs carried since the run last took it; 0 for a client
	## without a microphone or an old one (protocol.gd "voice"). Never a sound: only this number.
	var voice_level := 0
	## VC1: their newest input says their microphone is listening (the NO MIC marks; protocol.gd "mic").
	var mic_on := false
	## VC2, the intercom's hush: when their talking began and was last heard (host time), and the same for a shout.
	var talk_since := -1.0
	var talk_last := -INF
	var shout_since := -1.0
	var shout_last := -INF
	## The name this player joined with ("" before the join).
	var name := ""
	## The Annex: Q presses counted so far (a press not yet given to the run), peels asked for so far and
	## the mark of a peel not yet given to the run (-1 for none).
	var marks := 0
	var mark_pending := false
	var peels := 0
	var peel_pending := -1
	## The inventory (S1): the slot asked for (-1: none yet), the requests counted so far, and the newest one not
	## yet given to the run ([op, arg], or [] for none).
	var inv_sel := -1
	var invs := 0
	var inv_pending: Array = []

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
## A second Orderly (T9b; see the header): its own history, counts as sent, catch waiting and last catch, swapped
## with the first's (_swap_second) while the first's code runs on it.
var _hist2 := {}
var _sent_watch2 := {}
var _pending_catch2: Variant = null
var _last_catch_tick2 := -1
var _next_id := 1
var _step_fn: Callable
var _trusted := {}
# The isolated Ward review runs in the real host room on explicit opt-in.
# Normal runs have no Ward state or extra snapshot bytes.
var _reactor_review: ReactorReview
var _reactor_plan: Floor.FloorPlan
var _ward_review: Ward
var _ward_plan: Floor.FloorPlan
var _ward_use := {}
## WC1: the Ward's car as the run's car geometry (Run.ward_car), for its lift called from the station.
var _ward_car: Run.CarGeometry = null
## The late floors (FL1; net/host_rules.gd late_floors): off unless enable_late_floors() is called. On, arriving
## at HostRules.WARD_DEPTH starts the Ward exactly as start_ward_review does, and HostRules.REACTOR_DEPTH the
## Reactor exactly as start_reactor_review does, seeded from the day's floor seed (state.seed), with the crew placed
## at the overlay's own lift. While a late Reactor runs (until its lift is called) the floor underneath is held:
## no resident, car, quota or catch of its own is stepped (_step_reactor_hold), as the Ward's step already replaces
## the run's. Each overlay ends the day at the prison as its review does.
var late_floors := false
## Where a late Reactor keeps its recovered tape (sim/reactor_archive.gd), or "" to keep it in memory only.
var late_archive_path := ""
## The floor plan a late overlay was last started on (each arrival starts one, once).
var _late_plan: Floor.FloorPlan
## Whether the running Reactor was started by the late floors (the review keeps its own stepping).
var _reactor_late := false
## RN1, the Reactor as a place (net/host_rules.gd reactor_place): its rules are the run's (state.station); the host
## keeps only the recovered tape's archive (sim/reactor_archive.gd, at late_archive_path), the station whose arrival it
## last saw, and, once the crew has gone up with the lift, the last block, sent on in the prison (lift on, so the
## prison's tape deck works) until the next descent. With the flag off none of these is ever set.
var _station_archive: ReactorReview.Archive
var _station_plan: Floor.FloorPlan
var _station_home: Dictionary = {}
var _station_home_plan: Floor.FloorPlan
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
	# RR1: a piece of the crawling Rigger's graph, between ticks (_prebuild_roam).
	_advance_roam_build()

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

## A second Orderly (T9b), for tests: as replace_orderly, for the second one.
func replace_orderly2(o: Entity.OrderlyState) -> void:
	state = state.copy()
	state.orderly2 = o
	var h := History.make(o)
	for k: int in _hist2.keys():
		_hist2[k] = h
	_hist2[tick] = h
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
	_transport.send(peer, Protocol.encode({"type": "welcome", "you": p.id, "seed": seed, "playing": p.in_run, "evFrom": ev_from, "world": _world_for(world(true), p)}))
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
	if _pending_catch2 != null and _pending_catch2["victim"] == p.id:
		_pending_catch2 = null

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
	# VC1: the loudest level since the run last took it (taken each tick, so a late or missing input is silence).
	p.voice_level = clampi(maxi(p.voice_level, int(m.get("voice", 0))), 0, Run.Noises.VOICE_MAX)
	p.mic_on = m.get("mic", false) == true
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
	# The inventory (S1): the slot asked for is kept; a new request waits for the next tick.
	if m.get("invSel") != null:
		p.inv_sel = int(m["invSel"])
	if int(m.get("invs", 0)) > p.invs:
		p.invs = int(m["invs"])
		p.inv_pending = [StringName(str(m.get("invOp", ""))), m.get("invArg")]
	_step_gait(p, m)
	# The body: not until the client has the latest placement; never further than they could go.
	if p.place != null and int(m["placeAck"]) < int(p.place["seq"]):
		return
	var mb: Move.Body = m["body"]
	if _ward_review != null and _ward_review.phase == &"departed":
		return
	# WC1: caught in the web, carried and hung: the rules hold the body (placed where they hang, and where they are cut down).
	if _ward_review != null and _ward_review.webbed.has(p.id):
		return
	# DG0: held, stumbling, hung or on a ledge by a danger: the rules hold the body (placed where they are held).
	if state != null and state.dangers != null and DangerFx.held_body(state.dangers, p.id, state.t) != null:
		return
	if _ward_review != null and not _trusted.has(p.id):
		var held := Vector3(p.body.x, p.body.y, p.body.z) if p.body != null else Vector3.INF
		var to := Vector3(mb.x, mb.y, mb.z)
		# WN3: the walk is judged as the screen walks it (WN4: the old swapped-in Ward's screen too).
		if p.body != null and not _ward_reach(held, to):
			stats.clamped_inputs += 1
			return
	# RN3: the Reactor's crawl is creep-only; a standing step into it is refused here as the client stops it.
	if p.body != null and state != null and state.plan != null and not _trusted.has(p.id) and p.body.level == mb.level \
			and not StationPlan.crawl_step_ok(state.plan, mb.level, p.body.x, p.body.z, mb.x, mb.z, p.gait == "creep"):
		stats.clamped_inputs += 1
		return
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

## WN3: whether a networked walker's new body is a walk the Ward's own model (sim/ward/state.gd walk, what the screen
## walks with) could have taken from the held one. The screen walks in 7 cm pieces that slide along walls, three
## frames to an input, so the straight line between two inputs can cut the inside of a jamb's clearance that the walk
## went round (the first refusal seen, seed late-5: held (0.46, 0, -6.08), sent (0.53, 0, -5.97), both clear, the
## line between them not). Tried in turn: the straight line, the two ways round one corner, the walk replayed.
## VC2: one tick's level for the hush's talking and shouting (see HUSH_EVERY).
static func _hush_track(p: HostPlayer, lv: int, t: float) -> void:
	if lv >= Run.Noises.VOICE_TALK_AT:
		if p.talk_since < 0.0 or t - p.talk_last > HUSH_GAP + 1e-9:
			p.talk_since = t
		p.talk_last = t
	if lv >= Run.Noises.VOICE_SHOUT_AT:
		if p.shout_since < 0.0 or t - p.shout_last > HUSH_GAP + 1e-9:
			p.shout_since = t
		p.shout_last = t

static func _hush_talking(p: HostPlayer, t: float) -> bool:
	return p.talk_since >= 0.0 and t - p.talk_last <= HUSH_GAP + 1e-9 and t - p.talk_since >= HUSH_HOLD - 1e-9

static func _hush_shouting(p: HostPlayer, t: float) -> bool:
	return p.shout_since >= 0.0 and t - p.shout_last <= HUSH_GAP + 1e-9 and t - p.shout_since >= HUSH_HOLD - 1e-9

var _hush_sent := -INF

## VC2: the "crewNoisy" event, with the voice on, while two or more are talking or one is shouting.
func _hush_check(s: Run.RunState, t: float, extra: Array[Dictionary]) -> void:
	if not s.voice or t - _hush_sent < HUSH_EVERY - 1e-9:
		return
	var talkers := 0
	var shouting := false
	for id: String in _players:
		var hp: HostPlayer = _players[id]
		if not _playing(hp):
			continue
		if _hush_talking(hp, t):
			talkers += 1
		if _hush_shouting(hp, t):
			shouting = true
	if talkers >= 2 or shouting:
		_hush_sent = t
		extra.append({"type": "crewNoisy", "t": t, "talkers": talkers, "shouting": shouting})

## DG0: whether a danger hides the resident from player `p` now (its dark region, a closed door between them, or the
## player blinded): their "I can see it" counts for nothing, as in a blink.
func _danger_hides(s: Run.RunState, p: HostPlayer) -> bool:
	if s.dangers == null or s.plan == null:
		return false
	return DangerFx.blinded(s.dangers, p.id, s.t) or DangerFx.hides_resident(s.dangers, s.orderly.body, p.body, s.t, float(s.plan.cell_size))

func _ward_reach(from: Vector3, to: Vector3) -> bool:
	var w := _ward_review
	if w.walk_clear(from, to):
		return true
	if not w.walk_clear(to, to):
		return false
	for corner: Vector2 in [Vector2(to.x, from.z), Vector2(from.x, to.z)]:
		var y := w.footing.walking_height(corner, from.y, w.bridge_lowered)
		if is_finite(y):
			var c := Vector3(corner.x, y, corner.y)
			if w.walk_clear(from, c) and w.walk_clear(c, to):
				return true
	var replay := w.walk(from, Vector2(to.x - from.x, to.z - from.z))
	return replay.distance_to(to) <= 0.12 and w.walk_clear(replay, to)

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
	var tank := Run.sprint_seconds(state, p.id)
	if p.stamina.tank != tank:
		p.stamina = Stamina.Stamina.make(p.stamina.level, p.stamina.winded, tank)
	var gait := String(Stamina.gait_for(p.stamina, want == "sprint", want == "creep", ground > 0.0, cap))
	p.allowance += (Session.MAX_PLAYER_SPEED if gait == "sprint" else Stamina.WALK_SPEED) * dt
	p.stamina = Stamina.step_stamina(p.stamina, StringName(gait), ground, dt)
	# The shop's speed juice (S2, sim/run.gd): while it lasts sprinting costs nothing; "juiceOut" leaves them winded.
	if state.shop and Shop.juiced(state.shop_state, p.id, state.t):
		p.stamina = Stamina.Stamina.make(1.0, false, tank)
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

## Enable the Ward review on the current logical floor. Normal deck selection owns this later.
func start_ward_review(review_seed: int, place_crew := false) -> void:
	_reactor_review = null
	_reactor_plan = null
	# WG1: with the run flag ward_layout (net/host_rules.gd) the layout comes from the seed and the host's live
	# settings in force now (ward.spread, ward.rise); the snapshot carries them so every screen builds the same.
	var options := WardLayout.options(state.tuning if state != null else null, ward_lift_clear()) if ward_layout() else {}
	# WH1: the homes (net/host_rules.gd ward_homes) ride in the layout's options, so every screen builds the same.
	if ward_homes():
		options["homes"] = 1
	# ST1: a stair's body (net/host_rules.gd ward_stairs) rides there too, so every screen walks by the same rule.
	if ward_stairs():
		options["stairs"] = 1
	_ward_review = Ward.new(review_seed, options)
	# RR1: the solid, crawling Rigger (net/host_rules.gd rigger_roam); off, the Ward is exactly as before. His graph
	# was started on a worker thread with the late floors (_prebuild_roam); wait for it rather than build it twice.
	if rigger_roam():
		_finish_roam_build()
		_ward_review.enable_roam()
	_ward_plan = state.plan
	_ward_use.clear()
	# WC1: the lift called from its station, unless the host has the clock back (ward.lift_clock, read now), and the web.
	_ward_review.called = ward_call_rule() and WardSettings.i(state.tuning, &"ward.lift_clock", 0) == 0
	_ward_review.web = ward_web_rule()
	var foyer := _ward_review.lift_door()
	_ward_car = Run.ward_car(foyer, 1.34, 2.93)
	if place_crew:
		for i in state.players.size():
			var slot := Vector3(-0.28 + float(i % 2) * 0.56, 0.02, -0.55 - 0.59 * float(i / 2))
			var at := _ward_review.lift_door() + slot
			_place(state.players[i].id, Move.Body.make(at.x, at.z, 0, at.y), state.depth, state)

func _step_ward_review(s: Run.RunState, inputs: Array[Run.PlayerInput]) -> Run.RunStep:
	var ward_events: Array[Dictionary] = []
	var crew := {}
	for rp in s.players:
		crew[rp.id] = {"position": Vector3(rp.body.x, rp.body.y, rp.body.z), "aboard": rp.aboard,
			"active": false}
	for i in inputs:
		if not crew.has(i.id):
			continue
		var row: Dictionary = crew[i.id]
		row.position = Vector3(i.body.x, i.body.y, i.body.z)
		row.aboard = _ward_review.in_lift(row.position)
		row.active = not _ward_review.caught.has(i.id)
		row.use = i.use and not _ward_use.get(i.id, false)
		# WC1: F held (a cut down from the web).
		row.hold = i.use
		row.sprint = i.gait == &"sprint"
		# WD1: a creeping walker is never heard; an instrument recording (ticking) may be (sim/ward/state.gd).
		row.creep = i.gait == &"creep"
		# WH1c: the hide key in a Ward home (the press every floor's hides take; sprint held is the fast way).
		if i.hide_use:
			row.hide = true
			row.hide_fast = i.hide_fast
		# PY1 (the run's economy_fix): Soft Shoes shortens how far he hears a walk (sim/ward/state.gd rigger.steps_reach).
		if s.economy_fix and Run.owns_soft_shoes(s, i.id):
			row.soft = true
		# VC1: their voice's reach (0: silent), unless hung in the web; Soft Shoes never shortens it (sim/ward/state.gd).
		if s.voice and not _ward_review.webbed.has(i.id):
			var rp := Run._player_in(s.players, i.id)
			if rp != null:
				row.voice = Run.Noises.voice_radius(Run.voice_level_of(s, rp, i), s.tuning)
		row.recording = _ward_recording(s, i.id)
		_ward_use[i.id] = i.use
	var next_time := s.t + TICK
	_ward_review.tuning = s.tuning
	_ward_review.crew_size = s.players.size()
	var any_out := false
	var any_in := false
	for row: Dictionary in crew.values():
		if row.active:
			# Still in the car, or in its doorway (WF1): the lift leaves only once everyone is clear of its gate.
			if row.aboard or not _ward_review.clear_of_lift(row.position):
				any_in = true
			else:
				any_out = true
	var called := _ward_review.called
	var leave_now := false
	if called:
		# WC1: the Ward's lift is every floor's (sim/run.gd _step_ward_lift); its gate and hearing follow the run's lift.
		_ward_review.phase = _ward_lift_phase(s.phase)
		leave_now = any_out and not any_in and s.phase in [&"unloading", &"arriving"]
	elif any_out and not any_in:
		# PL2: the lift's return time is the live setting ward.lift_minutes, stamped as it leaves (today's 10).
		var minutes := WardSettings.i(s.tuning, &"ward.lift_minutes", int(Ward.RETURN_SECONDS / 60.0))
		ward_events.append_array(_ward_review.leave(next_time, 60.0 * minutes))
	ward_events.append_array(_ward_review.step(next_time, TICK, Run.board_time(s), crew))
	var cues: Array[Dictionary] = []
	for cue in ward_events:
		var event := cue.duplicate()
		event["type"] = "ward_" + str(event["kind"])
		event["t"] = event["at"]
		cues.append(event)
	var opts := {}
	if _ward_review.web:
		opts["web"] = true
	if called:
		opts["car"] = _ward_car
		opts["call_at"] = _ward_review.station
		opts["leave"] = leave_now
	var r := Run.step_ward(s, inputs, crew, _ward_review.posed_limb(next_time), _ward_review.phase,
		maxf(0.0, _ward_review.depart_at - next_time), _ward_review.boarded, TICK, cues, _ward_review.recorders(crew), opts)
	if called:
		_after_ward_lift(r, next_time)
	if ward_native() and _ward_review.phase != &"departed":
		_step_ward_kit(r, inputs, next_time)
	_hear_test_noises(r, next_time)
	# DG0: the dangers' noises of the last tick, heard by the Rigger as a loud noise of their reach; then their step.
	if s.dangers != null:
		for h: Array in Dangers.heard_on_ward(s):
			for cue in _ward_review.hear_loud(h[0], next_time, float(h[1])):
				var event := cue.duplicate()
				event["type"] = "ward_" + str(event["kind"])
				event["t"] = event["at"]
				r.events.append(event)
		var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
		if rules != null and rules.has_method("step_dangers"):
			rules.call("step_dangers", r.state, inputs, TICK, r.events, _ward_review)
	return r

## WC1: the Ward's phase for the run's lift: its gate shuts while the car is away or coming, and it is gone once the
## car has left (riding, or ended).
static func _ward_lift_phase(run_phase: StringName) -> StringName:
	match run_phase:
		&"arriving", &"unloading":
			return &"unloading"
		&"away", &"coming":
			return &"away"
		&"boarding":
			return &"boarding"
	return &"departed"

## WC1, after the Ward's lift tick (sim/run.gd _step_ward_lift): a call is loud at the station (the Rigger hears it as
## he hears a flare, within rigger.call_heard); the Ward's phase follows the run's; when the car goes, who rode and who
## was left (as the Ward's clock always said); and anyone standing in the doorway as the doors shut is put just outside.
func _after_ward_lift(r: Run.RunStep, now: float) -> void:
	var ward := _ward_review
	var heard: Array[Dictionary] = []
	for e in r.events:
		if e["type"] == "called":
			heard.append_array(ward.hear_loud(ward.station, now, WardSettings.f(r.state.tuning, &"rigger.call_heard", Ward.CALL_HEARD)))
	for cue in heard:
		var event := cue.duplicate()
		event["type"] = "ward_" + str(event["kind"])
		event["t"] = event["at"]
		r.events.append(event)
	ward.phase = _ward_lift_phase(r.state.phase)
	for e in r.events:
		if e["type"] != "doorsClosed":
			continue
		var aboard: Array = e["aboard"]
		var k := 0
		for rp in r.state.players:
			var feet := Vector3(rp.body.x, rp.body.y, rp.body.z)
			if not aboard.has(rp.id) and rp.status == &"ok" and not ward.in_lift(feet) and not ward.clear_of_lift(feet):
				var out := ward.lift_door() + Vector3(-0.3 + 0.3 * float(k % 3), 0.0, 0.75 + 0.35 * float(k / 3))
				k += 1
				if ward.walk_clear(out, out):
					rp.body = Move.Body.make(out.x, out.z, 0, out.y)
					_place(rp.id, rp.body, r.state.depth, r.state)
		if ward.phase == &"departed":
			ward.boarded.clear()
			ward.left_behind.clear()
			for rp in r.state.players:
				if aboard.has(rp.id):
					ward.boarded.append(rp.id)
				else:
					ward.left_behind.append(rp.id)
	if ward.phase == &"departed" and ward.boarded.is_empty() and ward.left_behind.is_empty():
		# A wipe: nobody rode.
		for rp in r.state.players:
			ward.left_behind.append(rp.id)

## RW1, tests only: noises a test asked for (net/local_room.gd test_ward_noise, the solo room's; never the server's),
## heard at the next Ward tick exactly as a flare's burst is (_step_ward_kit: Ward.hear_at, its cues as events).
## Empty in every real game, so nothing here runs.
var _test_noises: Array[Vector3] = []

func test_ward_noise(at: Vector3) -> bool:
	if _ward_review == null:
		return false
	_test_noises.append(at)
	return true

func _hear_test_noises(r: Run.RunStep, now: float) -> void:
	for at in _test_noises:
		for cue in _ward_review.hear_at(at, now):
			var event := cue.duplicate()
			event["type"] = "ward_" + str(event["kind"])
			event["t"] = event["at"]
			r.events.append(event)
	_test_noises.clear()

## WD1: whether this player's instrument is up and recording (its reading open), as the last tick left it.
static func _ward_recording(s: Run.RunState, id: String) -> bool:
	for m in s.crew.members:
		if m.id == id:
			return m.instrument.raised and m.instrument.current != null
	return false

## WN2: the Ward as a normal level (ward_place): what the crew carries works here as on any floor (Run.step_ward_kit),
## thrown through the Ward's own walls, and a flare's burst or a toy's rattle is a noise the Ward hears where it is.
func _step_ward_kit(r: Run.RunStep, inputs: Array[Run.PlayerInput], now: float) -> void:
	var ward := _ward_review
	var land := func(from: Move.Body, motion: Vector2) -> Move.Body:
		var to := ward.throw_landing(Vector3(from.x, from.y, from.z), motion)
		return Move.Body.make(to.x, to.z, from.level, to.y)
	var line := func(a: Move.Body, b: Move.Body) -> bool:
		return ward.walk_clear(Vector3(a.x, a.y, a.z), Vector3(b.x, b.y, b.z))
	var first := r.events.size()
	Run.step_ward_kit(r.state, inputs, TICK, r.events, land, line)
	for k in range(first, r.events.size()):
		var e: Dictionary = r.events[k]
		if e["type"] != "flareUsed" and e["type"] != "noise":
			continue
		for cue in ward.hear_at(Vector3(float(e["x"]), float(e["y"]), float(e["z"])), now):
			var event := cue.duplicate()
			event["type"] = "ward_" + str(event["kind"])
			event["t"] = event["at"]
			r.events.append(event)

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
			if int((item[1] as Dictionary).get("n", 1)) == 1:
				s = _apply_report(s, item[0], item[1], extra, t_next)

	# 2. Anyone saying they can see it now: held, and a wind-up is off. With two watchers needed, each
	# is one watcher for the count instead (Entity.note_look): a lone one holds nothing.
	var seeing := false
	var two := s.orderly.need >= 2
	for p: HostPlayer in _players.values():
		if still and _playing(p) and not Run.flare_blinded(s, p.id, s.t) and not _danger_hides(s, p) and p.input["seeing"] == true and ht - p.input_at <= Session.SEEING_TIMEOUT and _before_armed(p.input["renderTime"], true):
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

	# 1 to 3 again for a second Orderly (T9b): the same code, on the second swapped in (see the header).
	if s.orderly2 != null:
		s = _second_reports(s, q, ht, t_next, extra)

	# The players' names, for the Annex's notes (sim/run.gd names).
	var names := {}
	for rp in s.players:
		var hp: HostPlayer = _players.get(rp.id)
		if hp != null and hp.name != "":
			names[rp.id] = hp.name
	if names != s.names:
		s = s.copy()
		s.names = names

	# The vote also belongs to crew members whose view is out of the car after a wipe.
	if s.reel_day > 0 and not s.reel_skipped:
		var reel_crew: Array[String] = []
		var reel_pressed: Array[String] = []
		for rp in s.players:
			var voter: HostPlayer = _players.get(rp.id)
			if voter != null and voter.in_run and voter.connected and not voter.left:
				reel_crew.append(rp.id)
				if voter.input != null and voter.input.get("skipReelAt") == Protocol.q3(s.reel_started):
					reel_pressed.append(rp.id)
		s = Run.with_reel_votes(s, reel_crew, reel_pressed)

	# ED1, the elevator deal (sim/deal.gd; Protocol input "deal"): each connected player's answer to the ride's card,
	# and a second opinion asked for, before the tick, as the reel's votes are.
	if s.deal != null:
		var deal_on := {}
		var answers := {}
		for rp in s.players:
			var dp: HostPlayer = _players.get(rp.id)
			if dp != null and dp.in_run and dp.connected and not dp.left:
				deal_on[rp.id] = true
				if dp.input != null and dp.input.get("deal") is Array:
					answers[rp.id] = dp.input["deal"]
		s = Run.with_deal_answers(s, Run.deal_crew(s, deal_on), answers, extra)

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
			# DG0R3: a player pinned by a danger (hung, on a ledge) may still hold F for the kind (Api.Who.use: a kick); every
			# other downed player's F still counts for nothing.
			if s.dangers != null and (s.dangers as DangerFx.DangerFloor).pins.has(p.id):
				di.use = dm.get("use", false) == true
			inputs.append(di)
			p.call_pending = false
			p.pick_pending = false
			p.hide_pending = false
			p.emote_pending = false
			p.voice_level = 0
			p.mark_pending = false
			p.peel_pending = -1
			p.inv_pending = []
			continue
		if p != null and p.connected and p.in_run and not p.left and p.hide_pending and rp.status == &"caught" and s.seek != null:
			var horn := Seek.party_horn(s.seek, p.id, s.t)
			if not horn.is_empty():
				extra.append(horn)
		if p == null or not _playing(p) or p.input == null:
			if p != null:
				# Out of the run this tick: a press or an emote made meanwhile is not saved up for later.
				p.hide_pending = false
				p.emote_pending = false
				p.voice_level = 0
				p.mark_pending = false
				p.peel_pending = -1
				p.inv_pending = []
			continue
		var m: Dictionary = p.input
		var pc: Variant = _pending_catch
		var pc2: Variant = _pending_catch2 if s.orderly2 != null else null
		var body: Move.Body
		if pc != null and pc["victim"] == p.id and pc["body"] != null:
			body = pc["body"]
		elif pc2 != null and pc2["victim"] == p.id and pc2["body"] != null:
			body = pc2["body"]
		else:
			body = p.body if p.body != null else rp.body
		var inp := Run.PlayerInput.make(p.id, body, m["eye"], m["yaw"], m["pitch"], m["hFovDeg"], m["vFovDeg"])
		inp.raised = m["raised"]
		inp.hold_doors = m["holdDoors"]
		# While a catch waits for its victim, a player drawing a moment past the wind-up's end cannot save them.
		if s.orderly2 == null:
			inp.blind = not _before_armed(m["renderTime"], false)
		else:
			# A second Orderly (T9b): each catch wait blinds to its own Orderly only.
			inp.blind_first = not _before_armed(m["renderTime"], false)
			inp.blind_second = not _before_armed2(m["renderTime"])
		inp.call = p.call_pending
		inp.pick_up = true if p.pick_pending else null
		inp.use = m.get("use", false) == true
		# The Playroom (sim/run.gd): the gait the tank allowed, the hide key, W in a hide, a sound emote.
		inp.gait = StringName(p.gait)
		inp.hide_use = p.hide_pending
		inp.hide_fast = p.hide_pending and p.hide_fast
		inp.peek = m.get("peek", false) == true
		inp.emote_sound = p.emote_pending
		# VC1: how loud they were (read by the rules only with the run's voice on).
		inp.voice_level = p.voice_level
		_hush_track(p, p.voice_level, t_next)
		# The Annex (sim/run.gd): Q pressed, a peel asked for.
		inp.mark = p.mark_pending
		inp.peel = p.peel_pending
		# Findables (sim/run.gd): F held to search, sprint held with it.
		inp.search = m.get("search", false) == true
		inp.search_fast = m.get("searchFast", false) == true
		# The inventory (sim/run.gd): the slot asked for, and the newest request.
		inp.inv_select = p.inv_sel
		if not p.inv_pending.is_empty():
			inp.inv_op = p.inv_pending[0]
			inp.inv_arg = p.inv_pending[1]
		if inp.inv_op == &"skill" and inp.inv_arg == 3:
			inp.inv_op = &""
			if p.stamina.winded and Run.can_second_wind(s, p.id):
				s = Run.spend_second_wind(s, p.id)
				p.stamina = Stamina.Stamina.make(1.0, false, p.stamina.tank)
				inp.wind_gasp = true
				extra.append({"type": "secondWind", "t": t_next, "playerId": p.id, "depth": s.depth,
					"day": s.day_index, "x": body.x, "y": body.y, "z": body.z})
		inputs.append(inp)
		p.call_pending = false
		p.pick_pending = false
		p.hide_pending = false
		p.emote_pending = false
		p.voice_level = 0
		p.mark_pending = false
		p.peel_pending = -1
		p.inv_pending = []

	# VC2: a noisy crew while the intercom may be speaking.
	_hush_check(s, t_next, extra)

	# 5. The run.
	var ward_active := _ward_review != null and _ward_review.phase != &"departed"
	var reactor_hold := _reactor_late and _reactor_review != null and s.plan == _reactor_plan and not _reactor_review.rules.returned
	var r: Run.RunStep
	if ward_active:
		r = _step_ward_review(s, inputs)
	elif reactor_hold:
		r = _step_reactor_hold(s, inputs)
	else:
		r = _step_fn.call(s, inputs, TICK)
	var st := r.state
	var events: Array[Dictionary] = []
	events.append_array(extra)
	for te in _tune_events:
		te["t"] = t_next
		events.append(te)
	_tune_events = []
	events.append_array(r.events)
	_step_reactor_review(st, inputs)
	if _reactor_review != null and _reactor_review.rules.returned and st.depth != 0 and st.day_state != null:
		var home_events: Array[Dictionary] = []
		if _reactor_late and Run.cycles_on(st):
			# Cycles (FL2, sim/run.gd "Cycles"): the ride home from the Reactor is a BANK; the day is settled first.
			Run.bank_reactor(st, st.t, home_events)
		Run._arrive_home(st, st.players, st.t, home_events)
		_reactor_plan = st.plan
		r.events.append_array(home_events)
		events.append_array(home_events)
	_step_station_host(st, events)
	# The Tenant clock (TT1) is not the Ward's or the Reactor's: they keep their own clocks.
	if _ward_review != null or _reactor_review != null or st.station != null:
		var kept_events: Array[Dictionary] = []
		for e in events:
			if e["type"] != "tenantArrived":
				kept_events.append(e)
		events = kept_events

	# 6. After: placements, the gone, joiners.
	for e in r.events:
		var ty: String = e["type"]
		if ty == "doorsClosed":
			var pushed: Dictionary = e["pushedOut"]
			for id: String in pushed:
				_place(id, pushed[id], st.depth, st)
		elif ty == "rodeDown" or ty == "rodeUp" or ty == "newDay" or ty == "wokeUp":
			var bodies: Dictionary = e["bodies"]
			for id: String in bodies:
				_place(id, bodies[id], st.depth, st)
		elif ty == "hideIn" or ty == "hideLeave" or ty == "found" or ty == "taken" or ty == "down" or ty == "downed" or ty == "healed":
			# The Playroom: the rules hold the body (in a hide, at its front, rooted, at the table). Down first,
			# then out: where they fell, and where they get up.
			var hp := _find_run_player(st, str(e["playerId"]))
			if hp != null:
				_place(hp.id, hp.body, st.depth, st)
		elif (ty == "ward_hung" or ty == "ward_cut") and _ward_review != null:
			# WC1: hung at the hang point (feet under the ceiling), or cut down onto the floor below it.
			var wid := str(e["id"])
			var wb := Move.Body.make(float(e["x"]), float(e["z"]), 0, float(e["y"]))
			var wp := _find_run_player(st, wid)
			if wp != null:
				wp.body = wb
			_place(wid, wb, st.depth, st)
		elif ty == "dangerHold" or ty == "dangerStumble" or ty == "dangerPush" or ty == "dangerPinned" or ty == "dangerUnpinned":
			# DG0: the rules hold or move the body (sim/dangers.gd); the player's own screen goes along with it.
			var dp0 := _find_run_player(st, str(e["playerId"]))
			if dp0 != null:
				_place(dp0.id, dp0.body, st.depth, st)
		elif ty == "tableFreed":
			# The party table freed (T15h): everyone who was seated stands beside it, where the rules put them.
			for fid: Variant in e["freed"]:
				var fp := _find_run_player(st, str(fid))
				if fp != null:
					_place(fp.id, fp.body, st.depth, st)
		elif ty == "juiceOut":
			# The shop's speed juice ran out (S2): winded, as a tank run dry is.
			var jp: HostPlayer = _players.get(str(e["playerId"]))
			if jp != null and jp.stamina != null:
				jp.stamina = Stamina.Stamina.make(0.0, true, jp.stamina.tank)
		elif ty == "flareUsed" and e.stunned:
			_pending_catch = null
			_pending_catch2 = null
		elif ty == "caught" and int(e.get("n", 1)) == 2:
			_last_catch_tick2 = tick + 1
			if _pending_catch2 != null and _pending_catch2["victim"] == e["playerId"]:
				_pending_catch2 = null
		elif ty == "caught":
			_last_catch_tick = tick + 1
			if _pending_catch != null and _pending_catch["victim"] == e["playerId"]:
				_pending_catch = null
		elif ty == "windUpCancelled" and int(e.get("n", 1)) == 2:
			if _pending_catch2 != null and _pending_catch2["victim"] == e["playerId"]:
				_pending_catch2 = null
		elif ty == "windUpCancelled" and _pending_catch != null and _pending_catch["victim"] == e["playerId"]:
			_pending_catch = null
	# The tuned Playroom (sim/seek.gd T15m): a grabbed player being dragged to the party table is placed where
	# the rules hold them every tick, so their own screen goes along with it.
	if st.seek != null and (st.seek as Seek.SeekState).tuned and (st.seek as Seek.SeekState).minder.mode == &"drag":
		var dp := _find_run_player(st, (st.seek as Seek.SeekState).minder.victim)
		if dp != null:
			_place(dp.id, dp.body, st.depth, st)
	if st.annex_drag and Run.annex_dragging(st, str(st.orderly.bend_target)):
		var dragged := _find_run_player(st, str(st.orderly.bend_target))
		if dragged != null:
			_place(dragged.id, dragged.body, st.depth, st)
	if st.orderly.mode != &"windUp":
		_pending_catch = null
	if st.orderly2 == null or st.orderly2.mode != &"windUp":
		_pending_catch2 = null
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
	# A practice stop ends by going back up, so its called car is the only later arrival.
	if st.phase == &"arriving" or (st.orientation and s.phase == &"coming" and st.phase == &"boarding"):
		st = _admit(st)
	state = st
	if ward_active and _ward_review.phase == &"departed":
		# The real ride-up uses the normal car geometry. Keep accepted bodies in its
		# cabin until the normal prison placement arrives, even with old inputs in flight.
		for rp in st.players:
			var passenger: HostPlayer = _players.get(rp.id)
			if passenger != null:
				passenger.body = rp.body
	if _ward_review != null and st.plan != _ward_plan:
		_ward_review = null
		_ward_plan = null
	if late_floors:
		_start_late_floor()
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
	if s.orderly2 != null:
		_hist2[tick] = History.make(s.orderly2)
		_sent_watch2[tick] = [s.t, s.orderly2.need, s.orderly2.watchers]
	_hist2.erase(tick - HISTORY_TICKS)
	_sent_watch2.erase(tick - HISTORY_TICKS)
	_states[tick] = s
	_states.erase(tick - STATE_TICKS)

## A second Orderly (T9b; see the header): swaps the first's and the second's host state (history, counts as sent,
## catch waiting, last catch), so the first's code runs on the second as it is. Swapped back right after.
func _swap_second() -> void:
	var h := _hist
	_hist = _hist2
	_hist2 = h
	var w := _sent_watch
	_sent_watch = _sent_watch2
	_sent_watch2 = w
	var pc: Variant = _pending_catch
	_pending_catch = _pending_catch2
	_pending_catch2 = pc
	var lc := _last_catch_tick
	_last_catch_tick = _last_catch_tick2
	_last_catch_tick2 = lc

## Whether a sighting at drawn host time `t` still counts for the second Orderly's catch wait (_before_armed).
func _before_armed2(t: float) -> bool:
	var pc: Variant = _pending_catch2
	return pc == null or t < float(pc["armedAt"]) - 1e-6

## Steps 1 to 3 of the tick for a second Orderly (T9b): its seen reports ("n": 2), "I can see it" for it
## ("seeing2"), and its catch waiting for its victim's screen. Exactly the first's code, run with the second
## swapped in (Run._swap_second, _swap_second); events it adds carry "n": 2.
func _second_reports(s0: Run.RunState, q: Array, ht: float, t_next: float, extra: Array[Dictionary]) -> Run.RunState:
	var s := s0.copy()
	Run._swap_second(s)
	_swap_second()
	var mine: Array[Dictionary] = []
	for item: Array in q:
		if int((item[1] as Dictionary).get("n", 1)) == 2:
			s = _apply_report(s, item[0], item[1], mine, t_next)
	var seeing := false
	var two := s.orderly.need >= 2
	for p: HostPlayer in _players.values():
		if _playing(p) and not Run.flare_blinded(s, p.id, s.t) and p.input.get("seeing2", false) == true and ht - p.input_at <= Session.SEEING_TIMEOUT and _before_armed(p.input["renderTime"], true):
			seeing = true
			if not two:
				break
			var looked := Entity.note_look(s.orderly, p.id, s.orderly.t)
			if looked != s.orderly:
				s = s.copy()
				s.orderly = looked
	if seeing and not two:
		s = _hold(s, true, mine, t_next, false)
	s = _confirm_catch(s, ht)
	_swap_second()
	var out := s.copy()
	Run._swap_second(out)
	for e in mine:
		var n := e.duplicate()
		n["n"] = 2
		extra.append(n)
	return out

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
	if Run.flare_stunned(s, s.t):
		return s
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
	if p == null or not _playing(p) or Run.flare_blinded(s, player_id, s.t):
		return s
	stats.reports += 1
	var ra: int = r["a"]
	var rb: int = r["b"]
	var alpha: float = r["alpha"]
	if s.flare and _states.has(ra) and Run.flare_blinded(_states[ra], player_id, (ra + (rb - ra) * alpha) * TICK):
		return s
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
	var d := {"id": t.id, "owner": t.owner_id, "readings": t.readings.size(), "total": t.total}
	# Findables (FD9): the credits found on it, only when there are any (Protocol "found").
	var found := Run.found_on(t)
	if found > 0.0:
		d["found"] = found
	return d

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
	# A second Orderly (T9b; Protocol "o2"): its pose, its relocation count, and its own count of watchers.
	if s.orderly2 != null:
		out["orderly2"] = Protocol.orderly_snap(s.orderly2)
		out["reloc2"] = s.orderly2.relocations
		var watch2: Variant = watch_block(s, true)
		if watch2 != null:
			out["watch2"] = watch2
	# Lonely (T19c): on a Lonely resident's floor, who it chases ("" for nobody; Protocol "lonely").
	if not Run.at_home(s) and Run.resident_of(s).trait_name == &"lonely":
		var o := s.orderly
		out["lonely"] = str(o.lonely_target) if o.lonely_phase == &"chase" and o.lonely_target != null else ""
	# Solid furniture (FD7): the clients move their own bodies round it (Protocol "solid").
	if s.furniture:
		out["solid"] = Protocol.SOLID_RESTORED if s.furniture_layout else Protocol.SOLID_BASELINE
	# Live settings (LS2): the revision in force, with the whole list in the welcome, for a second after a change
	# and once a second after that (Protocol "tune"). Absent while never tuned.
	if tune_rev > 0:
		out["tune"] = [tune_rev, _tune_list.duplicate()] if full or _tune_list_due else [tune_rev]
	# Findables (FD9): what is open, who is searching, who carries what (Protocol "find").
	var fb: Variant = find_block(s)
	if fb != null:
		out["find"] = fb
	# The inventory (S1): every player's slots and what lies on the floor (Protocol "inv").
	if s.inventory:
		out["inv"] = inv_block(s)
	# The shop and the cabinet (S2): wallets, cabinets, what is lit, the timers (Protocol "shop").
	if s.shop and s.shop_state != null:
		out["shop"] = shop_block(s)
	if s.deep_pockets:
		var skills := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet != null and wallet.owned.has("deep_pockets"):
				skills[p.id] = 2 if wallet.last_id == "deep_pockets" else 1
		out["skills"] = skills
	if s.second_wind:
		var wind := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet != null and wallet.owned.has("second_wind"):
				var status := 2 if wallet.last_id == "second_wind" else 1
				if Run.wind_spent_here(s, p.id):
					status = 3
				wind[p.id] = status
		out["wind"] = wind
	if s.soft_shoes:
		var shoes := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet != null and wallet.owned.has("soft_shoes"):
				shoes[p.id] = 2 if wallet.last_id == "soft_shoes" else 1
		out["shoes"] = shoes
	if s.long_burn:
		var trained := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet != null and wallet.owned.has("long_burn"):
				trained[p.id] = 2 if wallet.last_id == "long_burn" else 1
		out["longBurn"] = trained
	if s.quick_fingers:
		var porter := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet == null:
				wallet = Upgrades.UpgradeState.make()
			porter[p.id] = Upgrades.trade_offer(wallet, "quick_fingers")
		out["porter"] = porter
	if s.field_dressing:
		var medic := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet == null:
				wallet = Upgrades.UpgradeState.make()
			medic[p.id] = Upgrades.trade_offer(wallet, "field_dressing")
		out["medic"] = medic
	if s.steady_gaze:
		var steady := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet == null:
				wallet = Upgrades.UpgradeState.make()
			steady[p.id] = Upgrades.trade_offer(wallet, "steady_gaze")
		out["steady"] = steady
	if s.throwing_arm:
		var listener := {}
		for p: Run.RunPlayer in s.players:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet == null:
				wallet = Upgrades.UpgradeState.make()
			listener[p.id] = Upgrades.trade_offer(wallet, "throwing_arm")
		out["listener"] = listener
	if s.orientation and maxf(s.orientation_standees.x, s.orientation_standees.y) >= 0.0:
		out["orientationStandees"] = [s.orientation_standees.x, s.orientation_standees.y]
	if s.flare:
		out["flares"] = s.flare_bursts if s.flare_plan == s.plan else []
	if s.lamp:
		var lamps: Array[Dictionary] = []
		for p: Run.RunPlayer in s.players:
			var lamp := Run.lamp_of(s, p.id)
			if not lamp.is_empty():
				var row := lamp.duplicate()
				row["playerId"] = p.id
				lamps.append(row)
		out["lamps"] = lamps
	if _ward_review != null:
		out["ward"] = _ward_review.snapshot(s.t)
		# WG1: a generated layout's options, so every screen builds the same Ward (absent for today's).
		if not _ward_review.layout_wire().is_empty():
			out["ward"]["layout"] = _ward_review.layout_wire()
		# WN1: the main scene plays this Ward as a normal level (net/host_rules.gd ward_place); absent with the flag off.
		if ward_native():
			out["ward"]["native"] = true
		# WC1: the station and the web, only with the call or the web on.
		var extras := _ward_review.extras()
		if not extras.is_empty():
			out["ward"]["extras"] = extras
	if _reactor_review != null:
		out["reactor"] = _reactor_review.snapshot()
	elif s.station != null or not _station_home.is_empty():
		out["reactor"] = _station_block(s)
	# The Tenant clock (TT1; net/host_rules.gd, Protocol "tenant"): the floor's deadline in host time. Never beside
	# the Ward's or the Reactor's own clock. Absent with the flag off.
	var tenant: Variant = tenant_block()
	if tenant != null and not out.has("ward") and not out.has("reactor"):
		out["tenant"] = tenant
	# Cycles (FL2; Protocol "cycle"): the cycle of this floor, or of the next descent in the prison; absent in cycle 1.
	if Run.cycles_on(s) and Run.cycle_now(s) >= 2:
		out["cycle"] = Run.cycle_now(s)
		# PY1 (Protocol "economy"): pay and quota by the cycle, so a screen that works out a quota (the ride's sheet)
		# works it out the host's way. Absent in cycle 1, where both rules agree, and with the fix off.
		if s.economy_fix:
			out["economy"] = 1
	# VC1 (Protocol "mic"): whose microphone is listening, for the NO MIC marks; only in a run with the voice.
	if s.voice:
		var mic_ids: Array = []
		for id: String in _players:
			var hp: HostPlayer = _players[id]
			if hp.mic_on and hp.connected and not hp.left:
				mic_ids.append(id)
		mic_ids.sort()
		out["mic"] = mic_ids
	# DF1 (Protocol "pressure"): what the pressures change on screens, from floor 8; absent in cycle 1 and with them off.
	var pressure: Variant = pressure_block(s)
	if pressure != null:
		out["pressure"] = pressure
	# LS1 (sim/last_stand.gd; Protocol "stand", "wipe", "standee"): only with the flag on.
	if s.last_stand and s.stand != null:
		var stand: Variant = Run.LastStand.stand_block(s.stand)
		if stand != null:
			out["stand"] = stand
		if not s.stand.wipe.is_empty() and int(s.stand.wipe["day"]) == s.day_index:
			out["wipe"] = s.stand.wipe
		if s.stand.standee != "":
			out["standee"] = s.stand.standee
	# DG0 (sim/dangers.gd block; Protocol "dg"): the floor's dangers, only in a run with them and only while there are any.
	var danger_block: Variant = Dangers.block(s)
	if danger_block != null:
		out["dangers"] = danger_block
	# ED1 (Protocol "deal"): the ride's card, its answers and roll, and what holds on this floor; absent with it off.
	if s.deal != null:
		var deal_block: Variant = Run.Deal.block(s.deal)
		if deal_block != null:
			out["deal"] = deal_block
	return out

## DF1 (sim/run.gd "Pressures"): the near light every screen draws, the heals left to the crew on this floor (-1: no
## limit) and who still has a free Field Dressing help here. Null with the pressures off, in cycle 1 and in the prison.
static func pressure_block(s: Run.RunState) -> Variant:
	if not s.pressures or Run.pressure_cycle(s) < 2 or s.depth < 1:
		return null
	var free: Array = []
	for p in s.players:
		if Run.pressure_free_help(s, p.id):
			free.append(p.id)
	return {"light": Run.pressure_near_light(s), "heals": Run.pressure_heals_left(s), "free": free}

## RR1: the crawling Rigger's surface graph takes seconds to build (sim/ward/rigger_graph.gd). The run's Ward seed is
## known from the start (late_seed), so it is built in pieces of ROAM_BUILD_US a tick (update) from when the late floors
## are turned on, long before the crew reaches floor 6; only a run begun on floor 6 builds it at once. No thread.
const ROAM_BUILD_US := 3000
var _roam_ward: Ward = null
var _roam_build: RefCounted = null

func _prebuild_roam() -> void:
	if _roam_build != null or not rigger_roam() or state == null:
		return
	# The layout's options as start_ward_review will make them (WG1), so the graph built now is the one it uses.
	var options := WardLayout.options(state.tuning, ward_lift_clear()) if ward_layout() else {}
	if ward_homes():
		options["homes"] = 1
	if ward_stairs():
		options["stairs"] = 1
	_roam_ward = Ward.new(late_seed(state), options)
	_roam_build = RiggerRoam.begin_graph(_roam_ward)

## A piece of the graph's build (each tick), or the rest of it (`all`); kept for the Ward once it is done.
func _advance_roam_build(all := false) -> void:
	if _roam_build == null or _roam_build.call("done"):
		return
	if _roam_build.call("advance", -1 if all else ROAM_BUILD_US):
		RiggerRoam.keep(_roam_ward, _roam_build)

func _finish_roam_build() -> void:
	_advance_roam_build(true)

## RR1: whether the rules stepping this run have the solid, crawling Rigger (net/host_rules.gd rigger_roam).
func rigger_roam() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("rigger_roam"))

## WN1: whether the rules stepping this run play the Ward as a normal level (net/host_rules.gd ward_place).
func ward_native() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_place"))

## WC1: whether the rules stepping this run have the Ward's lift called from its station (net/host_rules.gd ward_call)
## and the web (ward_web). The Ward's own clock comes back with the live setting ward.lift_clock (read as the Ward starts).
func ward_call_rule() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_call"))

func ward_web_rule() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_web"))

## WG1: whether the rules stepping this run lay the Ward out from the seed (net/host_rules.gd ward_layout).
func ward_layout() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_layout"))

## RL1: whether the rules stepping this run keep the lift's house from being the lowest (net/host_rules.gd
## ward_lift_clear; sim/ward/layout.gd LIFT_CLEAR). Only with ward_layout.
func ward_lift_clear() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_lift_clear"))

## WH1: whether the rules stepping this run build the Ward's houses from the homes' plans (net/host_rules.gd ward_homes).
func ward_homes() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_homes"))

## ST1: whether the rules stepping this run give the Ward's stairs a body (net/host_rules.gd ward_stairs).
func ward_stairs() -> bool:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	return rules != null and bool(rules.get("ward_stairs"))

## The Tenant clock's block from the rules stepping this run (net/host_rules.gd tenant_block), or null: the plain
## run's step, or rules without the clock.
func tenant_block() -> Variant:
	var rules: Object = _step_fn.get_object() if _step_fn.is_valid() else null
	if rules == null or not rules.has_method("tenant_block"):
		return null
	return rules.call("tenant_block", state)

## Nerve is an owner's private floor reading. The shared world never carries the crew's values.
## SR1 (sim/split.gd): so is exposure, and a false sight goes only to the player who sees it ("split").
func _world_for(shared: Dictionary, peer: HostPlayer) -> Dictionary:
	if not peer.in_run:
		return shared
	var nerve := Run.shows_nerve(state)
	var split: Variant = Split.view(state, peer.id)
	if not nerve and split == null:
		return shared
	var own := shared.duplicate()
	if nerve:
		own["nerve"] = Run.Nerve.view(Run.nerve_of(state, peer.id))
	if split != null:
		own["split"] = split
	return own

## The shop and the cabinet (S2; Protocol.enc_shop): every player's credits and cabinet in the run's order, the glow
## sticks and toys on this floor, the juice and flash timers (host times, -1 for none), the morning's wake (or -1).
static func shop_block(s: Run.RunState) -> Dictionary:
	var sh: Shop.ShopState = s.shop_state
	var credits: Array = []
	var cabs: Array = []
	var timers: Array = []
	for rp in s.players:
		var w: Variant = s.wallets.get(rp.id)
		credits.append({"playerId": rp.id, "credits": (w as Upgrades.UpgradeState).credits if w != null else 0})
		cabs.append({"playerId": rp.id, "slots": Shop.cabinet_of(sh.cabinets, rp.id).duplicate(true)})
		var ju := float(sh.juiced.get(rp.id, -1.0))
		var fl := float(sh.flashes.get(rp.id, -1.0))
		if ju >= 0.0 or fl >= 0.0:
			timers.append({"playerId": rp.id, "juice": ju, "flash": fl})
	var glows: Array = []
	for g: Dictionary in sh.glows:
		glows.append({"id": g["id"], "at": g["at"], "until": g["until"]})
	var toys: Array = []
	for g: Dictionary in sh.toys:
		var toy := {"id": g["id"], "at": g["at"], "start": g["start"], "end": g["end"]}
		if g.has("from"):
			toy["from"] = g["from"]
			toy["launch"] = g["launch"]
			toy["land"] = g["land"]
		toys.append(toy)
	return {"credits": credits, "cabinets": cabs, "glows": glows, "toys": toys, "timers": timers, "wake": sh.wake_until}

## The inventory (S1; Protocol.enc_inv): {bags: [{playerId, sel, slots}], pickups: [{id, item, count, at}]}, every
## player in the run's order (an empty bag for one who has never held anything).
static func inv_block(s: Run.RunState) -> Dictionary:
	var bags: Array = []
	for rp in s.players:
		var b := Inventory.bag_of(s.bags, rp.id)
		bags.append({"playerId": rp.id, "sel": b.sel, "slots": b.slots.duplicate(true)})
	var pickups: Array = []
	for pk: Inventory.Pickup in s.pickups:
		pickups.append({"id": pk.id, "item": pk.item, "count": pk.count, "at": pk.at})
	return {"bags": bags, "pickups": pickups}

## Findables (FD9; Protocol.enc_find): {opened, searching, items, base} as the host has it this tick, or null when
## the run has none, or there is nothing to say (off a Clinic or an Annex, with nobody carrying anything).
static func find_block(s: Run.RunState) -> Variant:
	if not s.findables or (s.find == null and s.items.is_empty()):
		return null
	var ff: Findables.FindFloor = s.find
	var opened: Array = []
	for row: Dictionary in Findables.opened_rows(ff):
		opened.append({"piece": row["piece"], "by": row["by"], "what": row["what"], "credits": row["credits"], "note": row["note"], "fast": row["fast"], "t": row["t"]})
	var searching: Array = []
	var items: Array = []
	for rp in s.players:
		if ff != null and ff.searches.has(rp.id):
			var sr: Findables.Search = ff.searches[rp.id]
			searching.append({"playerId": rp.id, "piece": sr.piece, "fast": sr.fast, "from": sr.from, "done": sr.done})
		var mine: Dictionary = s.items.get(rp.id, {})
		if int(mine.get(String(Findables.JUICE), 0)) > 0:
			items.append({"playerId": rp.id, "juice": int(mine[String(Findables.JUICE)])})
	return {"opened": opened, "searching": searching, "items": items, "base": ff.fill.base if ff != null else 0}

## Two-watcher Stillness (T19a; Protocol.enc_watch): the count as the host has it this tick, {need,
## watchers (ids, with grace; twice for a qualified Steady Gaze)}. Only in a run with two-watcher Stillness on and Entity.WATCH_CREW or more
## players (null otherwise): with fewer, one watcher is always enough, and the snapshot is what it always was.
static func watch_block(s: Run.RunState, second := false) -> Variant:
	if not s.two_watchers or s.players.size() < Entity.WATCH_CREW:
		return null
	var o := s.orderly2 if second else s.orderly
	var ids: Array = []
	for id in o.watchers:
		ids.append(id)
	return {"need": o.need, "watchers": ids}

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
		if Run.annex_dragging(s, d.id):
			row["drag"] = {"rear": d.drag_rear, "held": Run.resident_of(s).stillness and s.orderly.held}
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
		# The party table (T15h, sim/seek.gd with_party): who is freeing it and the host time their hold counts from.
		if ss.party:
			# T22c: and the hold's length, fixed when it started (party.free_time), so a hold under way keeps its count.
			k["party"] = {"by": ss.fetch_by, "from": ss.fetch_from, "len": ss.fetch_len}
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
	var out := {"index": s.day_index, "day": s.day_state.day, "quota": Day.day_quota(s.day_state, Run.day_floor_quota(s)), "streak": s.day_state.streak,
		"misses": s.day_state.misses, "inBed": in_bed, "countFrom": count_from, "lightsOutAt": lights,
		"result": Protocol.plain(s.day_result) if s.day_result != null else null, "crew": crew}
	if s.reel_day > 0:
		out["reel"] = {"day": s.reel_day, "started": s.reel_started, "crew": s.reel_crew,
			"votes": s.reel_votes.duplicate(), "skipped": s.reel_skipped}
	if s.day_lock:
		# The day quota's lock (FD2): the host's numbers for the HUD line and the lift monitor.
		var pv: Day.Preview = Run.day_preview(s)
		out["earned"] = pv.earned
		out["locked"] = pv.locked
		out["aboard"] = pv.banked
		out["each"] = pv.each
		out["stakes"] = pv.rows[2]
		if not pv.per_player.is_empty():
			var loss_odds := {}
			for owner in pv.per_player:
				loss_odds[owner["player"]] = owner["owned"]
			out["lossOdds"] = loss_odds
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
			var logged := event_log[i]
			var et := logged.text
			# Keep the reliable event sequence contiguous without sending the private cue or position.
			if logged.e.get("type") == "doorwayShadow" and logged.e.get("playerId") != p.id:
				et = '{"type":"privateEvent"}'
			var b := et.length() + 1
			if evs.size() > 0 and bytes + b > Session.EVENT_BUDGET:
				break
			evs.append(et)
			bytes += b
		var place: Variant = p.place if (p.place != null and int(p.place["seq"]) > p.place_ack) else null
		var head := {"st": ht, "ackIn": p.last_seq, "echo": [p.echo[0], ht - float(p.echo[1])] if p.echo != null else null,
			"ackSeen": p.ack_seen, "evFrom": p.ack_event + 1, "place": place, "stamina": p.stamina if p.in_run else null}
		var own := _world_for(w, p)
		var data := Protocol.snapshot_text(head, evs, text if is_same(own, w) else Protocol.world_json(own))
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

## Local review entry. Ordinary rooms construct this floor only through the late floors (enable_late_floors).
func start_reactor_review(review_seed: int, place_crew := false, archive_path := "") -> void:
	_ward_review = null
	_ward_plan = null
	_reactor_late = false
	_reactor_review = ReactorReview.new(review_seed,archive_path)
	_reactor_plan = state.plan
	for i in state.players.size():
		var rp := state.players[i]
		# Cycles (FL2): whoever the Ward's lift left behind arrives out of the run; the Reactor does not seat them.
		if Run.cycles_on(state) and rp.status != &"ok":
			continue
		var at := Vector3((i%3-1)*.55,0,9.3)
		_reactor_review.player(rp.id,at,false,&"walk",0)
		if place_crew:
			_place(rp.id,Move.Body.make(at.x,at.z,0,at.y),state.depth,state)

## Turn the late floors on (see _reactor_late's header above). Called by the room right after the host is made;
## a run that starts on a late floor (the solo floor picker) gets its overlay now, before the first tick.
func enable_late_floors(archive_path := "") -> void:
	late_floors = true
	late_archive_path = archive_path
	_prebuild_roam()
	_start_late_floor()

## The late floor of the current state, started once per arrival.
func _start_late_floor() -> void:
	var s := state
	if s == null or s.plan == null or s.plan == _late_plan or s.phase == &"ended":
		return
	# Cycles (FL2): the floor of cycle one this floor repeats (13 is a Ward, 14 a Reactor); without them, the depth.
	var local := Places.local_depth(s.depth, s.deck)
	if s.plan.place == Places.REACTOR:
		# RN1: the Reactor is a place here; its rules run in the run (no overlay, no scene swap).
		return
	if local == HostRules.WARD_DEPTH and _ward_review == null:
		_late_plan = s.plan
		start_ward_review(late_seed(s), true)
	elif local == HostRules.REACTOR_DEPTH and _reactor_review == null:
		_late_plan = s.plan
		start_reactor_review(late_seed(s), true, late_archive_path)
		_reactor_late = true

## The overlay's seed: the day's floor seed (the run's seed on day one, as the review rooms use it).
static func late_seed(s: Run.RunState) -> int:
	return s.seed.hash()

## A late Reactor's tick on the floor underneath: the clock and the accepted bodies move, nothing else does. The
## floor's own resident, car, quota and catches are not stepped (Run.step_ward with no Rigger, no cues and nobody
## active), and the phase reads "unloading" (the crew is out of the lift) so nobody is admitted mid-floor.
func _step_reactor_hold(s: Run.RunState, inputs: Array[Run.PlayerInput]) -> Run.RunStep:
	var crew := {}
	for rp in s.players:
		crew[rp.id] = {"position": Vector3(rp.body.x, rp.body.y, rp.body.z), "aboard": false, "active": false}
	for i in inputs:
		if crew.has(i.id):
			crew[i.id].position = Vector3(i.body.x, i.body.y, i.body.z)
	var nobody: Array[String] = []
	var no_cues: Array[Dictionary] = []
	return Run.step_ward(s, inputs, crew, PackedVector3Array(), &"unloading", 0.0, nobody, TICK, no_cues)

func _step_reactor_review(s: Run.RunState, inputs: Array[Run.PlayerInput]) -> void:
	if _reactor_review==null: return
	if s.plan!=_reactor_plan:
		_reactor_review = null
		_reactor_plan = null
		return
	var connected := {}
	for rp in s.players:
		var hp: HostPlayer = _players.get(rp.id)
		if hp!=null and hp.connected:
			connected[rp.id] = true
	_reactor_review.leave_missing(connected)
	if s.depth == 0 and _reactor_review.rules.returned:
		_reactor_review.rules.awake_seconds += TICK
		return
	for input in inputs:
		if connected.has(input.id):
			_reactor_review.player(input.id,Vector3(input.body.x,input.body.y,input.body.z),input.use,input.gait,TICK)
	_reactor_review.tick(TICK)

## RN1: after each tick on the station's rules (state.station): the archive is opened when the crew reaches the
## station (a tape already recovered is not on the table again), and banked when the tape is carried out; the last
## block is kept for the prison once the lift has gone up, and dropped at the next descent.
func _step_station_host(st: Run.RunState, events: Array[Dictionary]) -> void:
	var sf: Run.StationRules.StationFloor = st.station
	if sf != null and sf.plan != _station_plan:
		_station_plan = sf.plan
		_station_home = {}
		_station_home_plan = null
		if _station_archive == null:
			_station_archive = ReactorReview.Archive.new(late_archive_path)
		if _station_archive.recovered and not sf.collected:
			# This tick's own copy (the run made it this tick): the tape is already in the archive.
			sf.collected = true
	for e in events:
		if e["type"] == "tapeExtracted" and _station_archive != null:
			_station_archive.bank()
	if sf != null and sf.returned:
		_station_home = {}
		_station_home = _station_block(st)
		_station_home_plan = null
	elif sf == null and not _station_home.is_empty():
		if _station_home_plan == null and st.depth == 0:
			_station_home_plan = st.plan
		elif _station_home_plan != st.plan:
			_station_home = {}
			_station_home_plan = null

## RN1: the world's "reactor" block on the station (or, in the prison after its lift, the last one kept), with every
## field the old floor's block has (net/reactor_review.gd snapshot), positions in the plan's metres, plus native.
func _station_block(s: Run.RunState) -> Dictionary:
	var sf: Run.StationRules.StationFloor = s.station
	var block: Dictionary
	if sf == null:
		block = _station_home.duplicate()
	else:
		var connected := {}
		for rp in s.players:
			var hp: HostPlayer = _players.get(rp.id)
			if hp != null and hp.connected and rp.status != &"leftBehind":
				connected[rp.id] = rp
		block = ReactorReview.native_snapshot(sf, connected, s.tuning)
	block["archive"] = _station_archive.snapshot() if _station_archive != null else {"recovered": false, "discovered": false, "playing": {}}
	return block

func reactor_screening(peer: String, operation: String, ticket: int) -> bool:
	if _reactor_review == null and _station_archive != null and not _station_home.is_empty():
		# RN1: the prison's tape deck after the station's lift.
		if not _players.has(peer) or not _players[peer].connected or state.depth != 0: return false
		if operation == "watch":
			var at: Move.Body = _players[peer].body
			if not ReactorReview.at_prison_station(at.x, at.z): return false
		return _station_archive.action(peer, operation, ticket, state.t)
	if _reactor_review==null or not _players.has(peer) or not _players[peer].connected: return false
	if state.depth != 0: return false
	if operation == "watch":
		var body: Move.Body = _players[peer].body
		if not ReactorReview.at_prison_station(body.x, body.z): return false
	return _reactor_review.screening(peer,operation,ticket)
