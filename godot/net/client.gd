# A player's machine. Port of src/net/client.ts (NetClient). It owns that player's body and camera
# (moved locally, so walking feels instant), sends the host its body, view and intents about 20 times
# a second, and draws everyone else and the Orderly from the host's snapshots, INTERP_DELAY behind
# the newest it could have.
#
# The Orderly is never seen to move on this screen. Every frame (frame()):
#  1. The drawn Orderly is checked against the real camera where it is DRAWN, with the logic's own
#     generous sight test (Session.camera_sees).
#  2. While the local player can see the drawn figure, the drawing is frozen: same pose, animation
#     clock stopped, whatever snapshots say. The moment it is first seen the client sends the host a
#     seen report at once: the exact pose it froze on and the two snapshots it was blended from.
#     Reports repeat in every input until the host acknowledges them.
#  3. It only goes back to following snapshots on a frame where neither the frozen pose nor the
#     snapshots' pose can be seen, so the jump between the two (if any) is never on screen.
# Consequence: a pose can change between two frames only if at least one of them did not show it.
#
# Blinks: the screen is dark (a) while the estimated host clock is within the blink's blind window
# widened by the clock's error bound plus a tick, and (b) while the snapshots being drawn come from
# inside the blind window, so the movement a blink allows is never drawn lit.
#
# The local body is never taken from snapshots, except when the host moves the player (start, rides,
# being pushed out of the car, joining): those come as a numbered placement, applied here once and
# acknowledged in every input; the host ignores bodies until it is acknowledged.
#
# Being taken: a wind-up aimed at this player that its displayed timeline has followed to its end,
# without any frame of it showing the Orderly, latches "taken": from that frame the screen is blind
# (Frame.dark, no Orderly drawn, nothing can be seen) and the input that confirms it to the host goes
# out at once. It is let go when the catch has been drawn up to, when the snapshots show the host did
# not complete it, or after LATCH_MAX seconds of displayed time with nothing pending.
#
# The tank: the game steps its own copy every frame so a sprint answers at once; the host owns the
# truth and sends it back in every snapshot, as it stood after input `ackIn`. correct_stamina()
# moves the local copy by the difference, and gives it the host's tank size (a paced run's is bigger:
# sim/run.gd paced).
#
# In the dark (T20a, owner 17 Nov: "If the lights are off, don't make a silhouette, just don't hide it"):
# with `draw_in_dark` (the game's clients; tests leave it off) a Stillness resident is drawn on a dark
# frame too, where the snapshots say, with nothing added: the dark lighting is all that hides it. Looking
# in the dark still never counts (nothing is held, frozen or reported), exactly as before.
#
# The day loop (when the host's run has days, sim/run.gd): `seed` is the seed of the day this player is
# on (Run.day_seed(base_seed, day_index)), so Session.plan_for(seed, local_depth) is always the floor
# the host has them on. It changes with the placement that moves the player into a new day (the
# placement carries the day index, as it carries the depth) and with the welcome. LocalFrame.use (F
# held) goes to the host in every input. The newest snapshot's "day" block (latest["day"]) is the day
# number, the quota, who is in bed, the count and lights out in host time, and the settled day's facts.
# With the day quota's lock (sim/run.gd day_lock, FD2) the block also has the day's earned, locked, aboard,
# each and the monitor's stakes row: day_lock() returns them. The host's "dayMet" {day, earned, quota} and
# "bankRefused" {bank, down, day, earned, quota} arrive in `events` like any other.
#
# The Playroom (sim/seek.gd; loop/NIGHT-PLAN.md A3): LocalFrame.hide (F pressed for a hide, hide_fast
# with sprint held) is counted and the counts ride in every input, so no press is lost with a packet;
# LocalFrame.peek (W held in a hide) goes with each input. The count is the host's "count" event with
# the host's own t0: count_clock() works out its phase and seconds left at any host time (use the
# clock's host_time(now)), so every screen starts the dark and the bell at the same moment. The newest
# snapshot's "seek" block has each player's hide, peek, phase, status, health and totals, and the noise.
#
# The floor quota (sim/run.gd quota; North Star C9): quota() is the newest snapshot's quota block,
# {earned, needed} in whole credits (null when the run has no quota), for the call panel. The host's
# "callRefused" {playerId, earned, needed} and "quotaMet" {depth, earned, needed, top} arrive in `events` like
# any other. Nothing is predicted here: the call is pressed as always and the host decides.
#
# The Annex (sim/run.gd annex; docs/floors/annex.md sections 2 and 4; T16h). LocalFrame.mark (Q pressed) and
# LocalFrame.peel (the id of a mark F has been held on for Marks.PEEL_SECONDS) are counted, and the counts
# ride in every input, so no press is lost with a packet. Nothing is predicted: marks(), mark_pad() and
# notes() are the host's, the same on every screen. marks() and mark_pad() come from the newest snapshot's
# annex block; notes() are the floor's notes from the welcome and the "note" events (each exactly once),
# in the order posted. The events "markStart", "markPlaced", "markPeeled", "markRefused" and "note" arrive
# in `events` like any other (for the sounds: the slap, the stapler's click where the note is).
#
# Down first, then out (sim/run.gd downs; North Star B6; T8a). Nothing is predicted: downs(), down_of() and
# spots() are the newest snapshot's downs block, the host's, the same on every screen, with host times for
# the ten seconds and the three (use clock.host_time(now) to count them). A downed player keeps sending
# inputs: the host takes only their body (the crawl) and view. F held (LocalFrame.use) goes in every input
# and heals a downed crewmate within reach. The events "downed", "healStart", "healStop", "healed" and "out"
# arrive in `events` like any other, and the host places a player where they go down and where they get up.
# The resident bent over a downed player ("bending") is drawn as the snapshots say even while it is seen: its
# bend is the one movement it makes while watched. The taken latch treats "bending" as it treats "dormant"
# (the catch was made).
#
# Two-watcher Stillness (sim/entity.gd "Watchers"; docs/floors/traits-and-hiding.md section 1; T19a). The newest
# snapshot's watch block says how many watchers hold it (need) and whom the host counts; without one, one look
# is enough, as always. Rule 2 above applies only when this player's look would complete the count: one
# needed, or another player listed. Then it lights every eye mark, holds at once and reports, as always (the
# host honours the report against what this player had been sent: net/host.gd). Otherwise its look is one
# mark of two: the figure is drawn as the snapshots say (it walks at a lone watcher; the "seeing" flag tells
# the host it is one watcher), nothing is reported, and a hold already made is let go, in view, on the frame
# the marks drop. So the figure never moves on a frame that shows every mark lit (Frame.eyes_all).
#
# Relocation (sim/relocate.gd; T19e). The host moves the resident from a place nobody can see to another nobody
# can see; snapshots carry how often it has on this floor ("reloc"). Between two snapshots whose counts differ the
# figure is never blended: it is drawn at the newer one's pose (a snap), so it is never seen sliding through
# walls on the way. Its arrival cue is the "relocated" event, in `events` like any other.
#
# Lonely (sim/lonely.gd; T19c). On a floor whose Temp is Lonely the snapshots carry "lonely" (who it chases, or
# ""): looking does nothing to it, so it is drawn where the snapshots say, never held, nothing is reported and
# no eye marks show, as for the Minder. The events "chaseStarted" and "chaseEnded" arrive in `events` (the
# phones: client/sfx.gd).
extends RefCounted

const Move = preload("res://sim/move.gd")
const Stamina = preload("res://sim/stamina.gd")
const M = preload("res://sim/jsmath.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Pose = preload("res://net/pose.gd")
const Transport = preload("res://net/transport.gd")
const Run = preload("res://sim/run.gd")
const Seek = preload("res://sim/seek.gd")
const Settings = preload("res://sim/settings.gd")

const TICK := Session.TICK
const LAG_WINDOW := 60
const SNAP_KEEP := 3.0
## Inputs whose tank is remembered for correct_stamina().
const TANK_KEEP := 120
## Differences in the tank smaller than this are rounding (the snapshot carries it to 0.001).
const TANK_EPS := 0.004
## A taken latch with nothing pending on the host is let go after this much displayed time (s)...
const LATCH_IDLE := 1.0
## ...and any latch after this much (s), the host's own limit on waiting being CATCH_CONFIRM_MAX.
const LATCH_MAX := 2.5

## What the game hands the client each frame: the camera, and the player's intents.
class LocalFrame:
	var body: Move.Body
	var eye := 1.65
	var yaw := 0.0
	var pitch := 0.0
	var h_fov_deg := 90.0
	var v_fov_deg := 70.0
	var raised := false
	var hold_doors := false
	## The call button was pressed this frame.
	var call := false
	## The pick-up key was pressed this frame.
	var pick_up := false
	## How the player is moving ("walk", "creep", "sprint"), and the game's own copy of their tank (or null).
	var gait := "walk"
	var stamina: Stamina.Stamina = null
	## F is held this frame (the day loop: held on a prison bunk it lies the player down; a new press
	## gets them up). Only ever sent when true.
	var use := false
	## The Playroom: F pressed this frame for a hide (into the one in reach, or out of the one you are
	## in); `hide_fast`: sprint was held as it was pressed (quick and loud). W held inside a hide (`peek`).
	var hide := false
	var hide_fast := false
	var peek := false
	## The Annex: Q pressed this frame (place a mark at your feet, pointing where you face), and the id of a
	## mark to peel (F held on it for Marks.PEEL_SECONDS ended this frame) or -1.
	var mark := false
	var peel := -1
	## Findables (FD9): F held to search the piece in reach (Findables.piece_in_reach), and sprint held with it
	## (the rushed search). Sent while held; the host decides when a search starts, stops and ends.
	var search := false
	var search_fast := false
	## The inventory (S1): the slot asked for (0 to 3, -1 for no change this frame) and a request this frame:
	## "drop", "take" (inv_arg the pickup's id) or "give" (inv_arg the crewmate's id), "" for none.
	var inv_select := -1
	var inv_op := ""
	var inv_arg: Variant = null

## One rendered frame: what to draw.
class Frame:
	## Screen dark for a blink (or taken).
	var dark := false
	## Where the Orderly is on this screen's timeline (a pose Dictionary, the same one for as long as it
	## is held), or null.
	var orderly: Variant = null
	## Whether to draw it. Never on a dark frame: in the dark it is heard (its sound still comes from
	## `orderly`), not seen.
	var visible := false
	## The drawing is frozen (seen, or held until a jump can happen out of view).
	var held := false
	## The local player sees the drawn Orderly on this frame.
	var seeing := false
	## Latched as taken: the screen is blind (also `dark`) until the catch is drawn or called off.
	var taken := false
	## Two-watcher Stillness (see the header): the eye marks. Shown only while the local player sees the
	## figure (eyes_on, a Stillness resident); `eyes_need` marks (1 or 2), `eyes_lit` of them lit (this
	## player's own the frame they look, then one per other watcher the host counts); `eyes_all`: every
	## mark lit, and the drawing held.
	var eyes_on := false
	var eyes_need := 1
	var eyes_lit := 0
	var eyes_all := false
	## The one watcher it walks at while it needs two and has one (the watched walk), else "".
	var watched_by := ""
	## Depth of the floor drawn.
	var depth := 1
	## Everyone else, interpolated: {id, body (Move.Body), yaw, pitch, active, status, gait}.
	var players: Array[Dictionary] = []
	## Host time of the state being drawn (-1 before the first).
	var render_time := -1.0
	## The host moved the local player: adopt this body (else null).
	var placed: Move.Body = null

class ClientStats:
	var frames := 0
	var dark_frames := 0
	var guard_dark_frames := 0
	var reports := 0
	var inputs := 0
	var input_bytes := 0
	var max_input_bytes := 0
	var snapshots := 0
	var max_release_jump := 0.0
	var releases := 0
	var big_releases := 0
	var latches := 0
	var false_latches := 0

## Assigned by the host's welcome. `seed` is the seed of the day the local player is on (the run's own
## seed on day 1 and in a run without days); `base_seed` the run's; `day_index` the day of the run
## the local player is on (1 in a run without days).
var id: Variant = null
var seed: Variant = null
var base_seed: Variant = null
var day_index := 1
## In the run (otherwise watching until the next elevator stop).
var playing := false
## The host is gone: the session is over.
var ended := false
## The newest snapshot (or the welcome's state): phase, depth, crew, tapes, summary.
var latest: Variant = null
## Every event in host order, each exactly once (plain Dictionaries).
var events: Array[Dictionary] = []
## Depth of the floor the local player is on.
var local_depth := 1
## Sequence number of this client's first event (1 unless it joined a run in progress).
var first_event := 1
var clock := Session.HostClock.new()
var stats := ClientStats.new()
## Every input's size in bytes, when a test asks.
var keep_sizes := false
var input_sizes: Array[int] = []
## The local player's tank as the host last said it was (the truth, a round trip old), or null.
var host_stamina: Stamina.Stamina = null
## Draw the resident on a dark frame too (see the header). Off unless the game turns it on.
var draw_in_dark := false
## Live settings (docs/floors/live-settings.md LS2): the revision the host has in force (0: never tuned), and its
## list ({id: number}) as a tuning for this client's own predicted numbers (Settings.f; null for none). The
## snapshots carry the revision always and the list now and then (Protocol "tune"): a lost one heals within a second.
var tune_rev := 0
var tune_in_force := {}
var tuning: Settings.Values = null
## A false latch was let go on the last frame (the game shows it as a drop-out).
var latch_released := false
## Other players' emotes as the host passed them on, in arrival order: {player, emote, t (host time)}.
## Keep your own index into it, as with `events`.
var emotes: Array[Dictionary] = []
## This player's drawn face (FaceCodec text, sent in the join) or "", and the other players' faces as
## the host passed them on: player id -> FaceCodec text (only valid faces get this far).
var face := ""
var faces := {}
var _face_pending := false
var _last_face_send := -INF
## The camera of the last frame (what sight was judged from), the text of the last input sent, and
## the frame it went on (stats.frames): the eye checks compare them with the camera drawn.
var last_camera: Pose.Camera = null
var last_input := ""
var last_input_frame := -1

var host_id: String
var name: String
var _transport: Transport.Transport
var _ev_next := 1
var _ev_buf := {}
var _snaps: Array[Dictionary] = []
var _pin: Variant = null  # {pose, id, depth}
var _lags := PackedFloat64Array()
var _rt: Variant = null
var _rt_local := 0.0
var _drawn: Variant = null
var _drawn_depth := -1
var _frozen := false
var _report_id := 0
var _unacked: Array[Dictionary] = []
var _seq := 0
var _last_send := -INF
var _seeing_latch := false
var _calls := 0
var _pick_ups := 0
var _hides := 0
var _fast_hides := 0
var _marks := 0
var _peels := 0
var _peel_id := -1
## The inventory (S1): the slot asked for (-1: never asked), requests made so far, and the newest.
var _inv_sel := -1
var _invs := 0
var _inv_op := ""
var _inv_arg: Variant = null
## The Annex's notes this client has, by id (the welcome's and the "note" events).
var _notes := {}
var _ack_ht := -INF
var _place_applied := 0
var _pending_place: Variant = null
var _blinks := {}  # at -> {at, len, warn, announced}
var _last_join := -INF
var _interp_delay: float
var _input_interval: float
var _tank_at := {}  # input seq -> Stamina
var _host_tank_seq := 0
var _host_tank_fresh := false
var _wind_up_on := false
var _wind_up_saw := false
var _armed_end: Variant = null
var _latched_end := -INF
var _latch: Variant = null  # {rt, armed, depth}
var _caught_at := -INF
var _orderly_from := -1
## This frame's eye marks: [shown, need, lit, watched by] (_set_eyes).
var _eyes_frame: Array = [false, 1, 0, ""]

## `interp_delay` (default INTERP_DELAY) and `input_interval` (default INPUT_INTERVAL; 0 sends every frame).
## `face`: the player's drawn face (FaceCodec text) to send in the join, or "" for none.
func _init(transport: Transport.Transport, host_id_: String, name_: String, now: float, interp_delay: float = Session.INTERP_DELAY, input_interval: float = Session.INPUT_INTERVAL, face_: String = "") -> void:
	_transport = transport
	host_id = host_id_
	name = name_
	face = Protocol.valid_face(face_)
	_interp_delay = interp_delay
	_input_interval = input_interval
	_send_join(now)

func _send_join(now: float) -> void:
	_last_join = now
	var m := {"type": "join", "name": name, "ct": now}
	if face != "":
		m["face"] = face
	_transport.send(host_id, Protocol.encode(m))

## Changes this player's face during the run (the face kiosk): `face` shows at once on this screen
## (crew_faces in play_link.gd) and goes to the host, which passes it to the others. The host takes one
## change every Protocol.FACE_GAP seconds, so a change sooner than that after the last one sent waits
## and goes out with a later frame (only the newest waiting face is sent). Not a valid face: refused,
## false. Before the welcome the face just rides in the repeated join.
func change_face(face_: String, now: float) -> bool:
	var f := Protocol.valid_face(face_)
	if f == "":
		return false
	face = f
	_face_pending = id != null
	_flush_face(now)
	return true

func _flush_face(now: float) -> void:
	if not _face_pending or ended or id == null:
		return
	if now - _last_face_send < Protocol.FACE_GAP + Protocol.FACE_SEND_SLACK:
		return
	_face_pending = false
	_last_face_send = now
	_transport.send(host_id, Protocol.encode({"type": "setFace", "face": face}))

## A face change is waiting for the host's gap (tests).
func face_change_waiting() -> bool:
	return _face_pending

## Plays an emote for the others (one of Protocol.EMOTES; the host passes it on, rate limited).
func emote(which: String) -> void:
	if id != null and not ended and which in Protocol.EMOTES:
		_transport.send(host_id, Protocol.encode({"type": "emote", "emote": which}))

## Leaves the session.
func leave() -> void:
	_transport.send(host_id, Protocol.encode({"type": "leave"}))
	_transport.close()
	ended = true

## The local player's instrument and tapes, from the newest snapshot (or null).
func me() -> Variant:
	if latest == null:
		return null
	for m: Dictionary in latest["crew"]:
		if m["id"] == id:
			return m
	return null

## Blink starts the client knows of (host time).
func known_blinks() -> Array[float]:
	var out: Array[float] = []
	for k: float in _blinks.keys():
		out.append(k)
	out.sort()
	return out

## When the screen goes dark for each known blink, in LOCAL time, by the clock alone: [{start, end}].
func blink_windows() -> Array[Dictionary]:
	var guard := clock.error_bound() + 0.01
	var off := clock.offset()
	var out: Array[Dictionary] = []
	for at in known_blinks():
		var k: Dictionary = _blinks[at]
		out.append({"start": float(k["at"]) - TICK - guard - off, "end": float(k["at"]) + float(k["len"]) + TICK + guard - off})
	return out

## The floor quota as the newest snapshot has it: {earned, needed} in whole credits, or null when the
## run has no quota (or nothing has arrived yet). The call works once earned >= needed.
func quota() -> Variant:
	if latest == null:
		return null
	return latest.get("quota")

## The day quota's lock (FD2) as the newest snapshot has it: {day, earned, quota, locked, aboard, each,
## stakes}, every number the host's (the client sums nothing), or null when the run has no lock. The lift
## monitor's rows are Day.monitor_rows(day, earned, quota, aboard, each, stakes).
func day_lock() -> Variant:
	if latest == null or latest.get("day") == null:
		return null
	var d: Dictionary = latest["day"]
	if not d.has("earned"):
		return null
	return {"day": d["day"], "earned": d["earned"], "quota": d["quota"], "locked": d["locked"], "aboard": d["aboard"],
		"each": d["each"], "stakes": d["stakes"]}

## Findables (FD9) as the newest snapshot has them: {opened: [{piece, by, what, credits, note, fast, t}] (by piece
## id: draw these open; a note or page id reads with Findables.note_lines), searching: [{playerId, piece, fast,
## from, done}] (host times: a bar fills over (now - from) / (done - from)), items: [{playerId, juice}], base (the
## floor's quota as set on arrival: Findables.fill_for's base, for the sheet)}, or null when there is nothing.
func findables() -> Variant:
	if latest == null:
		return null
	return latest.get("find")

## The inventory (S1) as the newest snapshot has it: {bags: [{playerId, sel, slots: [[item, count] x4]}], pickups:
## [{id, item, count, at}]}, or null in a run without it.
func inventory() -> Variant:
	if latest == null:
		return null
	return latest.get("inv")

## Down first, then out: who is down as the newest snapshot has it, [{id, at, until, by, healer, healFrom}]
## (host times: out at `until` unless healed; a heal is done at healFrom + Run.HEAL_TIME). Empty when nobody
## is down or the run has no down rule.
func downs() -> Array:
	if latest == null or latest.get("downs") == null:
		return []
	return latest["downs"]["down"]

## One player's down as downs() has it, or null when they are not down.
func down_of(player: String) -> Variant:
	for d: Dictionary in downs():
		if d["id"] == player:
			return d
	return null

## This floor's red spots as the newest snapshot has them, [{playerId, x, z, level, y, t}]: where each
## player who went out lay and their tape fell.
func spots() -> Array:
	if latest == null or latest.get("downs") == null:
		return []
	return latest["downs"]["spots"]

## The Annex's marks as the newest snapshot has them: [{id, x, z, level, dir (0..7: Marks.dir_vector),
## player, placedAt (host time)}], in the order placed. Empty off the Annex.
func marks() -> Array:
	if latest == null or latest.get("annex") == null:
		return []
	return latest["annex"]["marks"]

## The crew's pad as the newest snapshot has it: {pad (marks left), size}, or null off the Annex.
func mark_pad() -> Variant:
	if latest == null or latest.get("annex") == null:
		return null
	var a: Dictionary = latest["annex"]
	return {"pad": a["pad"], "size": a["padSize"]}

## This floor's sticky notes, in the order posted: [{id, n, trigger, template, text, x, z, level, yaw, t}].
## Empty off the Annex. A note posted this tick may come with a later snapshot.
func notes() -> Array:
	if latest == null or latest.get("annex") == null:
		return []
	var a: Dictionary = latest["annex"]
	var from := int(a["notesFrom"])
	var out: Array = []
	for i in range(from + 1, from + int(a["noteCount"]) + 1):
		if _notes.has(i):
			out.append(_notes[i])
	return out

## Keeps a note (the welcome's or an event's), plain: {id, n, trigger, template, text, x, z, level, yaw, t}.
func _keep_note(n: Dictionary) -> void:
	var id := int(n["id"])
	if _notes.has(id):
		return
	_notes[id] = {"id": id, "n": int(n["n"]), "trigger": str(n["trigger"]), "template": int(n["template"]), "text": str(n["text"]),
		"x": float(n["x"]), "z": float(n["z"]), "level": int(n["level"]), "yaw": float(n["yaw"]), "t": float(n["t"])}
	# Notes of floors left behind are dropped.
	for k: int in _notes.keys():
		if k < id - 256:
			_notes.erase(k)

## The Playroom's newest count as its host event ({n, t0, len, last, by, why}), or {} before any (or on
## another floor): from the events, else from the newest snapshot's seek block (a player who joined
## during it never got its event).
func count_event() -> Dictionary:
	for i in range(events.size() - 1, -1, -1):
		var e: Dictionary = events[i]
		if e.get("type") == "count":
			return e
		if e.get("type") == "rodeDown" or e.get("type") == "rodeUp" or e.get("type") == "newDay":
			break
	if latest != null and latest.get("seek") != null and int(latest["seek"]["n"]) > 0:
		var k: Dictionary = latest["seek"]
		var e := {"type": "count", "t": k["t0"], "n": k["n"], "t0": k["t0"], "len": k["len"], "last": k["last"], "by": k["by"], "why": k["why"]}
		if k.has("hide"):
			e["hide"] = k["hide"]
		return e
	return {}

## A count event's seconds to hide: its "hide" (the tuned Playroom, sim/seek.gd T15m), else the 6 s.
static func hide_time(ev: Dictionary) -> float:
	return float(ev.get("hide", Seek.HIDE_TIME))

## Where a count stands at host time `host_t`, worked out from its event alone (every screen agrees, as
## the event is the host's): {phase: "hide" (the 6 s, or the event's "hide"), "seek" or "over", left:
## seconds of that phase}.
static func count_clock(ev: Dictionary, host_t: float) -> Dictionary:
	var t0 := float(ev["t0"])
	var hide_end := t0 + hide_time(ev)
	var end := hide_end + float(ev["len"])
	if host_t < hide_end:
		return {"phase": "hide", "left": hide_end - host_t}
	if host_t < end:
		return {"phase": "seek", "left": end - host_t}
	return {"phase": "over", "left": 0.0}

# -------------------------------------------------------------------------------------------
# Receiving.

## Takes in everything that has arrived (call whenever; `now` is the local clock).
func receive(now: float) -> void:
	for pe in _transport.peer_events():
		if pe["kind"] == "left" and pe["peer"] == host_id:
			ended = true
	for d in _transport.receive():
		if d["from"] != host_id:
			continue
		var m: Variant = Protocol.decode(d["data"])
		if m == null:
			continue
		match String(m["type"]):
			"welcome":
				if id != null:
					continue
				id = m["you"]
				seed = m["seed"]
				base_seed = m["seed"]
				playing = m["playing"]
				_ev_next = m["evFrom"]
				first_event = m["evFrom"]
				var w: Dictionary = m["world"]
				latest = w
				local_depth = w["depth"]
				if w.get("day") != null:
					_set_day(int(w["day"]["index"]))
				if w.get("annex") != null and w["annex"].get("notes") != null:
					for n: Dictionary in w["annex"]["notes"]:
						_keep_note(n)
				_insert(w)
				_learn_blink(w)
				_take_tune(w)
			"snap":
				if id == null:
					continue
				stats.snapshots += 1
				if m["echo"] != null:
					clock.sample(m["echo"][0], m["echo"][1], m["st"], now)
				_lags.append(now - float(m["st"]))
				if _lags.size() > LAG_WINDOW:
					_lags.remove_at(0)
				_ack_ht = maxf(_ack_ht, m["ht"])
				var evs: Array = m["events"]
				var ev_from: int = m["evFrom"]
				for i in evs.size():
					var n := ev_from + i
					if n >= _ev_next and not _ev_buf.has(n):
						_ev_buf[n] = evs[i]
				while _ev_buf.has(_ev_next):
					var ev: Dictionary = _ev_buf[_ev_next]
					if ev.get("type") == "caught" and ev.get("playerId") == id:
						_caught_at = maxf(_caught_at, float(ev["t"]))
					if ev.get("type") == "note":
						_keep_note(ev)
					events.append(ev)
					_ev_buf.erase(_ev_next)
					_ev_next += 1
				var kept: Array[Dictionary] = []
				for r in _unacked:
					if int(r["id"]) > int(m["ackSeen"]):
						kept.append(r)
				_unacked = kept
				var pl: Variant = m["place"]
				if pl != null and int(pl["seq"]) > _place_applied and (_pending_place == null or int(pl["seq"]) > int(_pending_place["seq"])):
					_pending_place = pl
				var ack_in: int = m["ackIn"]
				if m["stamina"] != null and ack_in >= _host_tank_seq:
					host_stamina = m["stamina"]
					_host_tank_fresh = _host_tank_fresh or ack_in > _host_tank_seq or _host_tank_seq == 0
					_host_tank_seq = ack_in
				var world: Dictionary = m
				_insert(world)
				if latest == null or int(m["tick"]) > int(latest["tick"]):
					latest = world
					for p: Dictionary in m["players"]:
						if p["id"] == id:
							playing = true
							break
				_learn_blink(world)
				_take_tune(world)
			"pong":
				clock.sample(m["ct"], float(m["st"]) - float(m["hr"]), m["st"], now)
			"emoted":
				if id != null and m["player"] != id:
					emotes.append({"player": m["player"], "emote": m["emote"], "t": m["t"]})
			"face":
				# Before or after the welcome (it follows the welcome, but a repeated join may cross it).
				if m["player"] != id:
					faces[m["player"]] = m["face"]

## Live settings: a snapshot's tune block. The newest revision's list is this client's tuning.
func _take_tune(w: Dictionary) -> void:
	var k: Variant = w.get("tune")
	if k == null or (k as Array).is_empty():
		return
	var rev := int(k[0])
	if rev < tune_rev or (k as Array).size() < 2:
		tune_rev = maxi(tune_rev, rev)
		return
	tune_rev = rev
	var given := {}
	for e: Array in k[1]:
		given[StringName(e[0])] = float(e[1])
	tune_in_force = given
	tuning = Settings.make(given) if not given.is_empty() else null

## The local player is on day `index` of the run: its seed is the one their floors are made from.
func _set_day(index: int) -> void:
	day_index = index
	seed = Run.day_seed(str(base_seed), index)

## The day index of a snapshot (this player's own day when the run has no days).
func _day_of(w: Dictionary) -> int:
	var d: Variant = w.get("day")
	return int(d["index"]) if d != null else day_index

func _insert(w: Dictionary) -> void:
	var s := _snaps
	var i := s.size()
	var t: int = w["tick"]
	while i > 0 and int(s[i - 1]["tick"]) > t:
		i -= 1
	if i > 0 and int(s[i - 1]["tick"]) == t:
		return
	s.insert(i, w)
	var newest: float = s[s.size() - 1]["ht"]
	while s.size() > 2 and float(s[0]["ht"]) < newest - SNAP_KEEP:
		s.remove_at(0)

func _learn_blink(w: Dictionary) -> void:
	var wb: Variant = w["blink"]
	if wb != null:
		var at: float = wb["at"]
		var k: Variant = _blinks.get(at)
		_blinks[at] = {"at": at, "len": wb["len"], "warn": wb["warn"], "announced": bool(wb["announced"]) or (k != null and bool(k["announced"]))}
	# Only the newest state may say a scheduled blink was dropped (the car came first).
	if not is_same(latest, w):
		return
	var ht: float = w["ht"]
	for b: Dictionary in _blinks.values().duplicate():
		var bat: float = b["at"]
		if bat + float(b["len"]) + 10.0 < ht:
			_blinks.erase(bat)
		elif not bool(b["announced"]) and ht >= bat - float(b["warn"]) + TICK and (wb == null or float(wb["at"]) != bat):
			_blinks.erase(bat)

# -------------------------------------------------------------------------------------------
# A frame.

## The host time to draw at: INTERP_DELAY behind the newest snapshot this client could have, judged
## by the fastest recent arrival. Advances with the local clock, slewed by at most 10% toward that
## target, and never runs backwards (except to recover from being more than a second ahead). Null
## until a snapshot has arrived.
func _render_time(now: float) -> Variant:
	if _lags.is_empty():
		return _rt
	var lag := INF
	for l in _lags:
		lag = minf(lag, l)
	var target := now - lag - _interp_delay
	if _rt == null:
		_rt = target
	else:
		var rt: float = _rt
		var dt := maxf(0.0, now - _rt_local)
		var adv := rt + dt
		var err := target - adv
		if err > 0.3:
			adv = target
		elif err < -1.0:
			adv = target
		elif err < -0.3:
			adv = rt  # ahead: wait for it
		else:
			adv += maxf(-0.1 * dt, minf(0.1 * dt, err))
		_rt = adv if err < -1.0 else maxf(rt, adv)
	_rt_local = now
	return _rt

## [a, b, alpha] for drawing at host time `rt` (INF: the newest), or [] with nothing to draw.
func _bracket(rt: float) -> Array:
	var s := _snaps
	if s.is_empty():
		return []
	var i := s.size() - 1
	while i >= 0 and float(s[i]["ht"]) > rt:
		i -= 1
	if i < 0:
		return [s[0], s[0], 0.0]
	var a: Dictionary = s[i]
	if i + 1 >= s.size():
		return [a, a, 0.0]
	var b: Dictionary = s[i + 1]
	if int(b["depth"]) != int(a["depth"]) or _day_of(b) != _day_of(a):
		return [a, a, 0.0]
	var aht: float = a["ht"]
	var bht: float = b["ht"]
	return [a, b, maxf(0.0, minf(1.0, (rt - aht) / (bht - aht)))]

## [dark, by clock only]: whether a blink makes the screen dark, by the estimated host clock or by
## what is being drawn.
func _is_dark(host_now: float, show: Array) -> Array:
	var guard := clock.error_bound() + 0.01
	var dark := false
	var real := false
	for k: Dictionary in _blinks.values():
		var lo := float(k["at"]) - TICK
		var hi := float(k["at"]) + float(k["len"]) + TICK
		if host_now >= lo - guard and host_now <= hi + guard:
			dark = true
		if host_now >= lo and host_now <= hi:
			real = true
		if not show.is_empty() and float(show[0]["ht"]) <= hi and float(show[1]["ht"]) >= lo:
			dark = true
	return [dark, dark and not real]

## One rendered frame at local time `now`: what to draw, and (when due) the input to the host. Call
## receive() first. If the host placed the local player, `placed` says where: adopt it.
func frame(now: float, local: LocalFrame) -> Frame:
	stats.frames += 1
	if local.call:
		_calls += 1
	if local.pick_up:
		_pick_ups += 1
	if local.hide:
		_hides += 1
		if local.hide_fast:
			_fast_hides += 1
	if local.mark:
		_marks += 1
	if local.peel >= 0:
		_peels += 1
		_peel_id = local.peel
	if local.inv_select >= 0:
		_inv_sel = local.inv_select
	if local.inv_op != "":
		_invs += 1
		_inv_op = local.inv_op
		_inv_arg = local.inv_arg
	latch_released = false
	if id == null or seed == null:
		if now - _last_join >= 0.5:
			_send_join(now)
		var e := Frame.new()
		e.depth = local_depth
		return e
	_flush_face(now)
	var placed: Move.Body = null
	if _pending_place != null and int(_pending_place["seq"]) > _place_applied:
		placed = _pending_place["body"]
		_place_applied = _pending_place["seq"]
		local_depth = _pending_place["depth"]
		if _pending_place.get("day") != null:
			_set_day(int(_pending_place["day"]))
		_pending_place = null
	var cam := Pose.Camera.make(placed if placed != null else local.body, local.eye, local.yaw, local.pitch, local.h_fov_deg, local.v_fov_deg)
	last_camera = cam
	var clock_rt: Variant = _render_time(now)
	var show := _bracket(INF if clock_rt == null else float(clock_rt))
	# The host time of the state actually drawn (behind the clock when snapshots are late).
	var rt := -1.0
	if not show.is_empty():
		var aht: float = show[0]["ht"]
		var bht: float = show[1]["ht"]
		rt = aht + (bht - aht) * float(show[2])
	var host_now := clock.host_time(now)
	var dk := _is_dark(host_now, show)
	if dk[0]:
		stats.dark_frames += 1
	if dk[1]:
		stats.guard_dark_frames += 1
	var latched_now := _update_latch(show, rt)
	var taken := _latch != null
	var blind: bool = dk[0] or taken

	# The Orderly.
	_eyes_frame = [false, 1, 0, ""]
	var seeing_now := false
	var report: Variant = null
	var orderly: Variant = null
	if not show.is_empty() and int(show[0]["depth"]) == local_depth and _day_of(show[0]) == day_index and int(show[0]["tick"]) > _orderly_from:
		var a: Dictionary = show[0]
		var b: Dictionary = show[1]
		var alpha: float = show[2]
		var a_depth: int = a["depth"]
		var eyes := _eyes()
		var enough: bool = eyes[0] <= 1 or eyes[1].size() >= eyes[0] - 1
		# Pinned: until the snapshots drawn show the host has handled our last report, they are the
		# timeline it is about to abandon (it puts the Orderly back where we froze it), so keep that.
		if _pin != null and (int(_pin["depth"]) != a_depth or int(a.get("ackSeen", 0)) >= int(_pin["id"])):
			_pin = null
		var pinned := _pin != null
		var cand: Dictionary = _pin["pose"] if pinned else (Pose.quant_pose(b["orderly"]) if _moved_on(a, b) else Pose.lerp_pose(a["orderly"], b["orderly"], alpha))
		var plan := Session.plan_for(seed, a_depth)
		var open := Session.doors_open_in(a["phase"]) or Session.doors_open_in(b["phase"]) or (latest != null and Session.doors_open_in(latest["phase"]))
		var same := _drawn != null and _drawn_depth == a_depth
		if not _still(plan.place, a, b):
			# Not a Stillness resident (the Playroom's Minder, the Lonely Temp): looking does nothing, so it is drawn
			# where the snapshots say, never held, and nothing is reported.
			_frozen = false
			_pin = null
			if _drawn == null or not Pose.same_pose(_drawn, cand):
				_drawn = cand
		elif not pinned and _bending(a, b) and (not _frozen or not same or _same_spot(_drawn, cand)):
			# Bent over a downed player: its bend is the one movement it makes while watched (sim/entity.gd,
			# "except while it has someone"), so it is drawn as the snapshots say, seen or not. It stands
			# where it caught them; a held pose somewhere else keeps the usual rule below.
			seeing_now = _sees(plan, cam, cand, open, blind)
			_frozen = false
			if _drawn == null or not Pose.same_pose(_drawn, cand):
				_drawn = cand
		elif _frozen and same and enough and _sees(plan, cam, _drawn, open, blind):
			# Seen: held exactly where it is, whatever the snapshots say.
			seeing_now = true
		elif _frozen and same and enough and _sees(plan, cam, cand, open, blind):
			# The held pose has left the view but the snapshots' pose is in it: keep holding until
			# neither is, so the jump between them never happens on screen.
			pass
		else:
			if _frozen and _drawn != null:
				var d: Dictionary = _drawn
				stats.releases += 1
				var jump := M.hypot3(float(d["x"]) - float(cand["x"]), float(d["y"]) - float(cand["y"]), float(d["z"]) - float(cand["z"]))
				stats.max_release_jump = maxf(stats.max_release_jump, jump)
				if jump > 0.25:
					stats.big_releases += 1
			if _sees(plan, cam, cand, open, blind) and enough:
				_frozen = true
				seeing_now = true
				if not pinned:
					report = _make_report(a, b, alpha, cand)
			elif _sees(plan, cam, cand, open, blind):
				# One mark of two: it walks on (at this player, perhaps), and this player is one watcher.
				_frozen = false
				seeing_now = true
			else:
				_frozen = false
			if _drawn == null or not Pose.same_pose(_drawn, cand):
				_drawn = cand
		_drawn_depth = a_depth
		orderly = _drawn
		if _still(plan.place, a, b):
			_set_eyes(eyes, seeing_now, not pinned and not _bending(a, b))
	else:
		_drawn = null
		_frozen = false
	if seeing_now:
		_seeing_latch = true
	# A lone watcher of two saves nobody by looking: only a frame with every mark lit counts as seeing it.
	if seeing_now and _wind_up_on and int(_eyes_frame[2]) >= int(_eyes_frame[1]):
		_wind_up_saw = true

	# Everyone else.
	var players: Array[Dictionary] = []
	if not show.is_empty():
		var a: Dictionary = show[0]
		var b: Dictionary = show[1]
		var alpha: float = show[2]
		for pa: Dictionary in a["players"]:
			if pa["id"] == id:
				continue
			var pb := pa
			for q: Dictionary in b["players"]:
				if q["id"] == pa["id"]:
					pb = q
					break
			var ba: Move.Body = pa["body"]
			var bb: Move.Body = pb["body"]
			var k := alpha if ba.level == bb.level else 0.0
			var pay: float = pa["yaw"]
			var pby: float = pb["yaw"]
			var pap: float = pa["pitch"]
			var pbp: float = pb["pitch"]
			players.append({
				"id": pa["id"],
				"body": Move.Body.make(ba.x + (bb.x - ba.x) * k, ba.z + (bb.z - ba.z) * k, ba.level, ba.y + (bb.y - ba.y) * k),
				"yaw": pay + _angle_diff(pay, pby) * k,
				"pitch": pap + (pbp - pap) * k,
				"active": pa["active"],
				"status": pa["status"],
				"gait": pa["gait"] if k < 0.5 else pb["gait"],
			})

	# The input: every INPUT_INTERVAL, and at once on a new sighting.
	if report != null or latched_now or now - _last_send >= _input_interval - 1e-9:
		_send(now, cam, local, rt)
	var shown: Variant = null if taken else orderly
	var f := Frame.new()
	f.dark = blind
	f.orderly = shown
	# Dark: drawn only with draw_in_dark (never while taken: `shown` is null then), and never seen.
	f.visible = shown != null and (not blind or (draw_in_dark and not taken))
	f.held = _frozen
	f.seeing = seeing_now
	f.taken = taken
	f.eyes_on = bool(_eyes_frame[0]) and not blind
	f.eyes_need = int(_eyes_frame[1])
	f.eyes_lit = int(_eyes_frame[2]) if f.eyes_on else 0
	f.eyes_all = f.eyes_on and f.eyes_lit >= f.eyes_need
	f.watched_by = str(_eyes_frame[3]) if not blind else ""
	f.depth = int(show[0]["depth"]) if not show.is_empty() else local_depth
	f.players = players
	f.render_time = rt
	f.placed = placed
	return f

## Two-watcher Stillness: [need, the other players the newest snapshot counts as watchers, every one it
## counts], from its watch block (none: [1, [], []]).
func _eyes() -> Array:
	var wb: Variant = latest.get("watch") if latest != null else null
	if wb == null:
		return [1, [], []]
	var others: Array = []
	for w: Variant in wb["watchers"]:
		if str(w) != str(id):
			others.append(str(w))
	return [int(wb["need"]), others, wb["watchers"]]

## This frame's eye marks ([shown, need, lit, watched by]) from the count (`eyes`, _eyes()) and the local look.
## `free`: the figure may be walking (not pinned to a report, not bent over someone), for the watched walk.
func _set_eyes(eyes: Array, seeing_now: bool, free: bool) -> void:
	var need: int = eyes[0]
	var others: Array = eyes[1]
	var lit := mini(need, others.size() + (1 if seeing_now else 0))
	var by := ""
	if need >= 2 and free and lit < need:
		var all: Array = eyes[2]
		if all.size() == 1:
			by = str(all[0])
		elif all.is_empty() and seeing_now:
			by = str(id)
	_eyes_frame = [seeing_now, need, lit, by]

## The floor's resident is held by looking (Stillness): not the Playroom's Minder, and not a Lonely Temp (its
## floor's snapshots carry "lonely": see the header).
static func _still(place: StringName, a: Dictionary, b: Dictionary) -> bool:
	return Places.resident(place).stillness and not a.has("lonely") and not b.has("lonely")

## The resident relocated between snapshots `a` and `b` (their relocation counts differ): see the header.
static func _moved_on(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("reloc", 0)) != int(b.get("reloc", 0))

## Both snapshots drawn have the resident bent over a downed player.
static func _bending(a: Dictionary, b: Dictionary) -> bool:
	return a["orderly"]["mode"] == "bending" and b["orderly"]["mode"] == "bending"

## Two poses stand on the same spot, facing the same way (the animation aside).
static func _same_spot(p: Dictionary, q: Dictionary) -> bool:
	return int(p["level"]) == int(q["level"]) and absf(float(p["x"]) - float(q["x"])) < 0.011 and absf(float(p["z"]) - float(q["z"])) < 0.011 \
		and absf(float(p["y"]) - float(q["y"])) < 0.011 and absf(_angle_diff(float(p["yaw"]), float(q["yaw"]))) < 0.002

static func _sees(plan: Variant, cam: Pose.Camera, p: Dictionary, open: bool, blind: bool) -> bool:
	return not blind and Session.camera_sees(plan, cam, p, open)

func _end_latch() -> void:
	_latch = null
	_wind_up_on = false
	_wind_up_saw = false
	_armed_end = null

## The resident as a snapshot has it is past a catch: dormant (a catch without the down rule), or bent over
## the one it caught (with it).
static func _after_catch(w: Dictionary) -> bool:
	var mode: String = w["orderly"]["mode"]
	return mode == "dormant" or mode == "bending"

func _mine(w: Variant) -> bool:
	if w == null:
		return false
	var o: Dictionary = w["orderly"]
	return o["mode"] == "windUp" and o.has("windUp") and o["windUp"]["target"] == id

## The taken latch, per frame, from the snapshots being drawn (`show`, at displayed time `rt`) and the
## newest one received. Returns true on the frame it fires (the confirming input goes at once).
func _update_latch(show: Array, rt: float) -> bool:
	var newest: Variant = latest
	if _latch != null:
		var l: Dictionary = _latch
		if _caught_at > float(l["armed"]):
			# The catch happened: blind until the frame drawn is past it.
			if rt >= _caught_at - 1e-9:
				_end_latch()
			return false
		var pending: bool = newest != null and int(newest["depth"]) == int(l["depth"]) and (_mine(newest) or _after_catch(newest))
		var elapsed := rt - float(l["rt"])
		if local_depth != int(l["depth"]) or not pending or (elapsed > LATCH_IDLE and not _mine(newest)) or elapsed > LATCH_MAX:
			_end_latch()
			stats.false_latches += 1
			latch_released = true
		return false
	if show.is_empty() or int(show[0]["depth"]) != local_depth:
		_wind_up_on = false
		_wind_up_saw = false
		_armed_end = null
		return false
	var a: Dictionary = show[0]
	var on_me := _mine(a)
	if on_me:
		if not _wind_up_on:
			_wind_up_on = false
			_wind_up_saw = false
			_armed_end = null
			_wind_up_on = true
		var w: Dictionary = a["orderly"]["windUp"]
		if _armed_end == null and float(w["left"]) <= TICK + 1e-6:
			_armed_end = float(a["ht"]) + float(w["left"])
	var end: Variant = _armed_end
	# The displayed wind-up has reached its end unseen. Only if the host's snapshots agree it ran to
	# its end: still pending (held for our confirmation), or the catch made.
	var due: bool = _wind_up_on and not _wind_up_saw and end != null and float(end) > _latched_end + 1e-6 and rt >= float(end) - 1e-6
	var ran_to_end: bool = end != null and (_caught_at >= float(end) - 1e-6 or (newest != null and int(newest["depth"]) == int(a["depth"]) and (_mine(newest) or _after_catch(newest))))
	if not on_me:
		_wind_up_on = false
		_wind_up_saw = false
		_armed_end = null
	if not due or not ran_to_end or end == null:
		return false
	_latch = {"rt": rt, "armed": float(end) - TICK, "depth": int(a["depth"])}
	_latched_end = end
	stats.latches += 1
	return true

## Forgets the Orderly as drawn (and any pose held because it was in view): the next frame draws it
## from the snapshots. For a test hook's teleport, which is not a move the rule has to hide.
func forget_orderly() -> void:
	_orderly_from = int(latest["tick"]) if latest != null else -1
	_drawn = null
	_frozen = false
	_pin = null
	_drawn_depth = -1

## The game's own tank, corrected toward the host's: by how far the host's tank after input `ackIn`
## differs from what this game had when it sent that input. Call once a frame with the current copy.
func correct_stamina(local_: Stamina.Stamina) -> Stamina.Stamina:
	var local := local_
	if host_stamina != null and local.tank != host_stamina.tank:
		# The host's tank size first (a paced run's is bigger: sim/run.gd sprint_seconds).
		local = Stamina.Stamina.make(local.level, local.winded, host_stamina.tank)
	if not _host_tank_fresh or host_stamina == null:
		return local
	_host_tank_fresh = false
	if not _tank_at.has(_host_tank_seq):
		return local
	var sent: Stamina.Stamina = _tank_at[_host_tank_seq]
	var host := host_stamina
	var d := host.level - sent.level
	var wind_change := host.winded != sent.winded
	if absf(d) < TANK_EPS and not wind_change:
		return local
	var fix := func(st: Stamina.Stamina) -> Stamina.Stamina:
		var out := Stamina.Stamina.new()
		out.level = maxf(0.0, minf(1.0, st.level + (0.0 if absf(d) < TANK_EPS else d)))
		out.winded = st.winded
		out.tank = host.tank
		if wind_change:
			out.winded = host.winded and out.level < Stamina.WINDED_UNTIL
		return out
	# Later inputs were sent from the uncorrected copy: move them too, or the next snapshot corrects twice.
	for k: int in _tank_at.keys():
		if k >= _host_tank_seq:
			_tank_at[k] = fix.call(_tank_at[k])
	return fix.call(local)

func _make_report(a: Dictionary, b: Dictionary, alpha: float, pose: Dictionary) -> Dictionary:
	_report_id += 1
	var r := {"id": _report_id, "depth": a["depth"], "a": a["tick"], "b": b["tick"], "alpha": Protocol.q3(alpha), "pose": pose}
	_unacked.append(r)
	_pin = {"pose": pose, "id": r["id"], "depth": a["depth"]}
	stats.reports += 1
	return r

func _send(now: float, cam: Pose.Camera, local: LocalFrame, rt: float) -> void:
	_seq += 1
	var seen: Array = _unacked.slice(maxi(0, _unacked.size() - 2))
	var m := {
		"type": "input", "seq": _seq, "ct": now, "body": cam.body, "eye": cam.eye, "yaw": cam.yaw, "pitch": cam.pitch,
		"hFovDeg": cam.h_fov_deg, "vFovDeg": cam.v_fov_deg, "raised": local.raised, "holdDoors": local.hold_doors,
		"gait": local.gait, "seeing": _seeing_latch, "calls": _calls, "pickUps": _pick_ups, "ackEvent": _ev_next - 1,
		"ackHt": _ack_ht if not is_inf(_ack_ht) else -1.0, "renderTime": rt, "placeAck": _place_applied, "seen": seen,
	}
	if local.use:
		m["use"] = true
	if local.peek:
		m["peek"] = true
	if local.search:
		m["search"] = true
		if local.search_fast:
			m["searchFast"] = true
	if _hides > 0:
		m["hides"] = _hides
		m["fastHides"] = _fast_hides
	if _marks > 0 or _peels > 0:
		m["marks"] = _marks
		m["peels"] = _peels
		m["peelId"] = _peel_id
	if _inv_sel >= 0 or _invs > 0:
		m["invSel"] = _inv_sel
		m["invs"] = _invs
		m["invOp"] = _inv_op
		m["invArg"] = _inv_arg
	if local.stamina != null:
		var copy := Stamina.Stamina.new()
		copy.level = local.stamina.level
		copy.winded = local.stamina.winded
		copy.tank = local.stamina.tank
		_tank_at[_seq] = copy
		_tank_at.erase(_seq - TANK_KEEP)
	var text := Protocol.encode(m)
	_transport.send(host_id, text)
	last_input = text
	last_input_frame = stats.frames
	_last_send = now
	_seeing_latch = false
	stats.inputs += 1
	stats.input_bytes += text.length()
	stats.max_input_bytes = maxi(stats.max_input_bytes, text.length())
	if keep_sizes:
		input_sizes.append(text.length())

static func _angle_diff(a: float, b: float) -> float:
	var d := fmod(b - a, 2.0 * PI)
	if d > PI:
		d -= 2.0 * PI
	if d < -PI:
		d += 2.0 * PI
	return d
