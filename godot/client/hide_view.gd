# The Playroom's count and hiding on screen (docs/floors/playarea.md sections 3, 4, 7, 9 and 10;
# loop/NIGHT-PLAN.md C4). It draws and plays what the host says; it decides no rule.
#
# Everything about a count is worked out from the host's one "count" event (net/client.gd count_event:
# t0, len, last, by, why) against the host clock as this screen estimates it (Client.count_clock with the
# snapshot's hostNow), never from when the event arrived, so every screen goes dark, rings and counts at
# the same moment (North Star: network delay must never make it look like a rule broke):
#   - three xylophone notes and "HIDE." at t0, "STARTED BY: {NAME}, {WHY}." through the 6 s;
#   - count dark: the strip lights go out bank by bank (BANKS, from BANK_FIRST, BANK_STEP apart) and come
#     back the same way when it ends (client/playroom_view.gd set_count_dark);
#   - the floor's tune sags to half speed through a low-pass for the whole count (client/sfx.gd);
#   - the count: one bell stroke a second on the Voice bus, rising in the last five, the number on screen
#     and in a caption; "COMING, READY OR NOT." as it starts; "ALL DONE." at the end;
#   - "FOUND YOU, {NAME}." for every found event in a count, the grab's own line for the Minder's grab
#     outside one (announcer.gd say_grab); the last count's line when the call starts it.
# Every line is a caption in the pixel font, and its recording (T15i, client/count_lines.gd) plays by id
# (client/announcer.gd say_count; the numbers on their own player).
#
# The tuned Playroom (T15m, sim/seek.gd tune: the count event carries "hide"): the bell and the numbers
# (forty, thirty, twenty, ten to one) count down the time to hide, "COMING, READY OR NOT!" starts the search,
# which is quiet but for the Minder's music box; and the anger bar (the seek block's "anger") with what
# fills it printed under it.
#
# This player (the snapshot's mySeek row): the hide in reach and how to get in; sat back in a hide, on the
# Playroom the view out kept (T15m: the ball pit's camera down at the balls, a few at the bottom edge; the
# others the room through the gap and its frame), elsewhere the dark inside; the gap's frame (peeking, W); a rising toy-piano trill and picture noise as their own
# sight or gap total rises; the health bar once the first count has ended, with its rates printed; the
# instrument warning (ticking in a hide within 5 m of it is a reason: LOWER IT); with the Minder's hunt (PT1,
# hunt_of) the bar shows from the first search with HUNT_HEALTH_RATES, the anger rates are the hunt's, and
# there is no instrument warning (it never acts on one); winding down; found (the
# camera is turned to the Minder and, as it bends for the catch, its mask fills the screen); taken (the
# party table, in a paper hat, watching); down (YOU WENT DOWN, main.gd). Other players at the table wear
# paper hats too (drawn here, over their figures).
#
# Off the Playroom (the Clinic and the Annex, sim/hiding.gd; T19b) only the hiding is shown: the prompts for
# a bed, a cabinet, the meeting table (F) and a desk (Ctrl and walk in). No count, no tune, no health, and
# no odds printed.
#
# MH1b (the owner, 21 Nov): nothing is drawn over the picture while you hide, on any floor. The camera is in
# the hide and its own 3D (the den's netting, the cabinet's slats, the bed's underside, the chest's lid) is
# the frame round the view out; HideOverlay draws only the catch's mask and the party hat's brim.
#
# Sounds (client/sfx.gd plays them): the found-you sting when you are found; going down, yours or
# another's where they fell; getting into and out of hides (each kind its own); the Minder's huff at an
# empty hide; squeaker tiles and the ball pit underfoot (_step_sounds, from the rules' own lists).
#
# test_break "arrival" (play_hide's deliberate break): the count is timed from the moment its event
# arrived on this screen's own clock instead of the host's t0, so two screens with different delays go
# dark at different moments.
extends Node

const Client = preload("res://net/client.gd")
const Seek = preload("res://sim/seek.gd")
const Settings = preload("res://sim/settings.gd")
const Floor = preload("res://sim/floor.gd")
const Playroom = preload("res://sim/playroom.gd")

## Count dark: four banks of strip lights, the first going this long after t0 (after the three notes),
## then one every BANK_STEP; back on at the end, one every BACK_STEP.
const BANKS := 4
const BANK_FIRST := 0.6
const BANK_STEP := 0.55
const BACK_STEP := 0.5
## The tune sags to half speed over SAG_TIME from t0, and comes back over SAG_TIME from the end.
const SAG_TIME := 1.5
## Lines shown for this long (ms).
const LINE_MS := 2200
const NUMBER_MS := 950
## The count's number lines start after "COMING, READY OR NOT." has been up this long (s).
const COMING_TIME := 2.0
## The xylophone and HIDE are only played to a screen that sees the count start (not one joining late).
const LATE := 1.5
## The instrument warning: a raised instrument in a hide this close to the Minder (the rule's 5 m, and
## a little warning before it).
const LOWER_RANGE := 6.5
## The catch: the mask fills the screen as it comes within CATCH_NEAR..CATCH_FULL metres.
const CATCH_NEAR := 3.0
const CATCH_FULL := 0.9
## What started a count, in words.
const WHY := {"sprint": "SPRINTING", "squeaker": "A SQUEAKY TILE", "ballpit": "JUMPING IN THE BALL PIT", "flap": "LETTING A FLAP GO",
	"tape": "A DROPPED TAPE", "emote": "A NOISE", "bump": "BUMPING INTO IT", "light": "A LIGHT ON IT", "voice": "A VOICE", "call": "CALLING THE LIFT",
	"fetch": "FREEING THE PARTY TABLE", "hide": "GETTING INTO A HIDE", "open": "OPENING SOMETHING"}
const KIND_NAMES := {"pit": "BALL PIT", "slide": "TUBE SLIDE", "den": "CRAWL DEN", "playhouse": "PLAYHOUSE", "table": "UNDER THE TABLE",
	"chest": "TOY CHEST", "cubby": "COAT CUBBY", "bed": "UNDER THE BED", "cabinet": "IN THE CABINET", "desk": "UNDER THE DESK",
	"shed": "IN THE SHED", "bench": "UNDER THE BENCH", "under": "UNDER THE BANDSTAND", "log": "IN THE HOLLOW LOG",
	"wardrobe": "IN THE WARDROBE", "bath": "IN THE BATH"}
const HEALTH_RATES := "WALK -3/S  SPRINT -8/S  STILL OR CREEP +1/S"
## PT1 (the Minder's hunt, sim/seek.gd): walking and sprinting cost health only while it searches.
const HUNT_HEALTH_RATES := "WALK -3/S  SPRINT -8/S ONLY WHILE IT SEARCHES  STILL OR CREEP +1/S"
## T15m: what fills the anger bar (sim/seek.gd ANGER_RATES and ANGER_LUMPS), printed under it.
const ANGER_RATES := "SPRINT 2 S OR 3 NOISES FILL IT"
## Live settings: the run's tuning as this client has it (the game sets it every frame; null for none), so the
## printed rates follow the host's minder.anger_sprint and minder.anger_noise.
var tuning: Settings.Values = null
## CS1: set by client/main.gd while the Minder's caught scene has been shown for this found: no flat card mask.
var scene_mask := false

## The anger bar's printed rates: ANGER_RATES, or the same words with the host's numbers. `hunt` (PT1): the
## numbers in force are the host's or else Seek.HUNT_ANGER_SPRINT and Seek.HUNT_ANGER_NOISE.
static func anger_rates_text(t: Settings.Values, hunt: bool = false, party: bool = false) -> String:
	# The party table (T15h): the bar never goes down by itself, only after a count (it drains over the calm), and the
	# words say so.
	if party:
		return anger_rates_text(t, hunt) + ". ONLY A SEARCH EMPTIES IT"
	if not hunt and (t == null or not (t.has(&"minder.anger_sprint") or t.has(&"minder.anger_noise"))):
		return ANGER_RATES
	var sprint0 := Seek.HUNT_ANGER_SPRINT if hunt else 1.0 / float(Seek.ANGER_RATES[&"sprint"])
	var noise0 := Seek.HUNT_ANGER_NOISE if hunt else 100.0 * float(Seek.ANGER_LUMPS[&"emote"])
	var secs := Settings.f(t, &"minder.anger_sprint", sprint0)
	var noises := ceili(100.0 / Settings.f(t, &"minder.anger_noise", noise0) - 1e-9)
	return "SPRINT %s S OR %d NOISE%s FILL IT" % [("%.1f" % secs).trim_suffix(".0"), noises, "" if noises == 1 else "S"]

## PT1: whether the run has the Minder's hunt. The rooms turn it on exactly with the tuned Playroom
## (server/room.gd, net/local_room.gd), whose seek block carries "anger".
static func hunt_of(seek: Dictionary) -> bool:
	return seek.has("anger")

## The health bar's printed rates: the host's health.walk, health.sprint and health.rest when set, else the
## rules' WALK_DRAIN, SPRINT_DRAIN and REST_GAIN (HEALTH_RATES and HUNT_HEALTH_RATES, word for word).
static func health_rates_text(hunt: bool, t: Settings.Values = null) -> String:
	var num := func(id: StringName, v: float) -> String: return ("%.2f" % Settings.f(t, id, v)).trim_suffix("0").trim_suffix("0").trim_suffix(".")
	var walk: String = num.call(&"health.walk", Seek.WALK_DRAIN)
	var sprint: String = num.call(&"health.sprint", Seek.SPRINT_DRAIN)
	var rest: String = num.call(&"health.rest", Seek.REST_GAIN)
	return "WALK -%s/S  SPRINT -%s/S%s  STILL OR CREEP +%s/S" % [walk, sprint, " ONLY WHILE IT SEARCHES" if hunt else "", rest]

## The party table (T15h): whether the run has it (the seek block carries "party", only with the tuned Playroom).
static func party_of(seek: Dictionary) -> bool:
	return seek.has("party")

## The names of everyone seated at the party table, in the block's player order.
static func seated_names(seek: Dictionary, names: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for p: Dictionary in seek.get("players", []):
		if str(p.get("status", "")) == "taken" and int(p.get("seat", -1)) >= 0:
			out.append(str(names.get(str(p["id"]), str(p["id"]))).to_upper())
	return out

## The party table's warning, printed on every screen and on the lift while anyone is seated (with the party table
## on), so nobody loses a friend to a rule they were not told: "ANN IS AT THE PARTY TABLE. THE LIFT LEAVES WITHOUT
## THEM." "" when nobody is seated, or without the party table. `me_seated`: the seated player's own line.
static func party_warning(seek: Dictionary, names: Dictionary, me_seated := false, live: Settings.Values = null) -> String:
	if not party_of(seek):
		return ""
	if me_seated:
		return "THE LIFT LEAVES WITHOUT YOU. A CREWMATE HOLDING F HERE FOR %s S FREES YOU." % secs_text(Seek.fetch_time(live))
	var who := seated_names(seek, names)
	if who.is_empty():
		return ""
	var list := who[0]
	if who.size() > 1:
		list = ", ".join(who.slice(0, who.size() - 1)) + " AND " + who[who.size() - 1]
	return "%s %s AT THE PARTY TABLE. THE LIFT LEAVES WITHOUT THEM." % [list, "IS" if who.size() == 1 else "ARE"]

## Whether a point stands at the party table as the rules judge it (Seek.at_table: within the host's party.reach,
## Seek.fetch_reach, of a seat's spot, on its level). `seats`: Playroom.seats of the floor.
static func near_table(seats: Array, x: float, z: float, level: int, live: Settings.Values = null) -> bool:
	var reach := Seek.fetch_reach(live)
	for st: Playroom.Seat in seats:
		if st.level == level and Vector2(st.at.x / 100.0 - x, st.at.y / 100.0 - z).length() <= reach:
			return true
	return false

## The fetcher's line at the table: what holding F does and what it costs, then the hold's seconds left.
## `left` < 0: not holding yet. `live`: the run's tuning (party.free_time, party.free_anger), so the numbers printed
## are the ones the rules use.
static func fetch_note(n_seated: int, left: float, live: Settings.Values = null) -> String:
	var cost := "ITS ANGER +%d" % roundi(Seek.fetch_anger(live) * 100.0)
	if left >= 0.0:
		return "FREEING THE PARTY TABLE... %.1f S   %s" % [maxf(0.0, left), cost]
	return "HOLD F %s S  FREE THE PARTY TABLE (%d SEATED)   %s" % [secs_text(Seek.fetch_time(live)), n_seated, cost]

## Seconds as printed: whole seconds as "3", anything else to a tenth ("2.5"), so a tuned time is printed as set.
static func secs_text(v: float) -> String:
	return str(roundi(v)) if absf(v - roundf(v)) < 0.05 else "%.1f" % v

## The length of a hold already under way: the host's, fixed when it started (the party block's "len", T22c), so
## a change to party.free_time mid-hold does not move its countdown. A block without it: today's 3 s.
static func hold_len(party: Dictionary) -> float:
	return float(party.get("len", Seek.FETCH_TIME))

## Whether the health bar shows: once the first count has ended; with the hunt also from the first search on
## (health drains there). `phase`: this screen's count phase ("hide", "seek", "over" or "").
static func shows_health(seek: Dictionary, phase: String, hunt: bool) -> bool:
	if int(seek["ended"]) >= 1:
		return true
	return hunt and bool(seek["counting"]) and phase == "seek"

## The line for a raised instrument in a Playroom hide during a count, or "" (none: the other prompts stand).
## With the hunt the Minder never acts on an instrument, so nothing is said.
static func ticking_note(raised: bool, counting: bool, near: bool, hunt: bool) -> String:
	if hunt or not raised or not counting:
		return ""
	return "IT HEARS THE TICKING IN HERE. LOWER IT. (E)" if near else "TICKING IN A HIDE WITHIN 5 M OF IT MAKES IT LOOK IN"

static var test_break := ""

var overlay: HideOverlay
var _hats_root: Node3D
var _hats := {}            # player id -> MeshInstance3D
var _hat_mesh: Mesh = null
## This screen's presentation of the counts.
var dark := 0.0
var sag := 0.0
var count_n := 0           # the newest count number presented
var count_phase := ""      # hide / seek / over / ""
var count_left := 0.0
var started_by := ""
var _bell_i := -1
var _said := {}            # "<n>:<line>" -> true
var _arrived := {}         # count n -> this screen's local seconds when its event was first seen
## Tests: per count, the host time (as this screen estimates it) the count was first seen, and the host
## time its dark first reached full; the bell strokes struck ([n, index, host time]).
var seen_at := {}
var dark_full_at := {}
var strokes: Array = []
## This player.
var noise_k := 0.0
var catch_k := 0.0
var _prev_total := 0.0
var _rising_until := 0
var _found_ids := {}
## The feet heard (_step_sounds): player id -> [cell index, room id] last frame.
var _feet := {}
## The party table (T15h): the warning for the lift's panel (party_warning; "" none), and the floor's seats.
var party_line := ""
var _seats_fp: Floor.FloorPlan = null
var _seats: Array = []

func _seats_of(pv: Object) -> Array:
	var fp: Floor.FloorPlan = pv.get("fp")
	if fp != _seats_fp:
		_seats_fp = fp
		_seats = Playroom.seats(fp) if fp != null else []
	return _seats

func setup(parent: Node, sub: SubViewport) -> void:
	overlay = HideOverlay.new()
	overlay.name = "HideOverlay"
	parent.add_child(overlay)
	_hats_root = Node3D.new()
	_hats_root.name = "PartyHats"
	sub.add_child(_hats_root)

## Off the Playroom, or a new floor: nothing of the count is shown.
func reset() -> void:
	dark = 0.0
	sag = 0.0
	count_n = 0
	count_phase = ""
	count_left = 0.0
	started_by = ""
	_bell_i = -1
	_said.clear()
	_arrived.clear()
	seen_at.clear()
	dark_full_at.clear()
	strokes.clear()
	noise_k = 0.0
	catch_k = 0.0
	_prev_total = 0.0
	_found_ids.clear()
	_feet.clear()
	if overlay != null:
		overlay.mode = ""
		overlay.catch_k = 0.0
		overlay.queue_redraw()
	for id: String in _hats.keys():
		(_hats[id] as Node).queue_free()
	_hats.clear()

## Where another player is drawn (for their sounds), or null if not here.
static func _where(others: Array, id: String) -> Variant:
	for o: Dictionary in others:
		if str(o.get("id", "")) == id:
			return Vector3(float(o["x"]), float(o["y"]) + 0.3, float(o["z"]))
	return null

## The sounds of feet on the Playroom, from the same lists as the rules (sim/seek.gd step 3): a squeaker
## tile stepped onto faster than a creep squeaks; walking into the ball pit off a walkway faster than a
## creep jumps in (loud), at a creep wades. Everyone out of a hide, by the cell they are drawn in; your
## own from where you stand.
func _step_sounds(s: Dictionary, others: Array, my_id: String, sfx: Sfx, pv: Object) -> void:
	if pv == null:
		return
	var fp: Floor.FloorPlan = pv.get("fp")
	var sq: PackedInt32Array = pv.get("squeak")
	if fp == null:
		return
	var bodies: Array = []
	var me: Dictionary = s.get("me", {})
	var row: Variant = s.get("mySeek")
	if not me.is_empty() and (not row is Dictionary or (str(row["status"]) == "ok" and str(row["phase"]) == "out")):
		bodies.append([my_id, me, null])
	for o: Dictionary in others:
		if bool(o.get("active", true)) and str(o.get("seekStatus", "ok")) == "ok" and str(o.get("seekPhase", "out")) == "out":
			bodies.append([str(o["id"]), o, Vector3(float(o["x"]), float(o["y"]) + 0.1, float(o["z"]))])
	var seen := {}
	for b: Array in bodies:
		var id: String = b[0]
		var d: Dictionary = b[1]
		seen[id] = true
		var cx := int(floor(float(d["x"]) / fp.cell_size))
		var cy := int(floor(float(d["z"]) / fp.cell_size))
		var lvl := int(d.get("level", 0))
		if cx < 0 or cy < 0 or cx >= fp.width or cy >= fp.height:
			continue
		var cell := Floor.pos_index(fp, Floor.Pos.make(lvl, cx, cy))
		var room := Floor.room_id_at(fp, lvl, cx, cy)
		var prev: Array = _feet.get(id, [])
		_feet[id] = [cell, room]
		if prev.is_empty() or int(prev[0]) == cell:
			continue
		var fast := str(d.get("gait", "walk")) != "creep"
		if fast and sq.has(cell):
			sfx.squeaker(b[2])
		if room >= 0 and room != int(prev[1]) and fp.rooms[room].kind == &"ballpit":
			sfx.ball_pit(fast, b[2])
	for id: String in _feet.keys():
		if not seen.has(id):
			_feet.erase(id)

## The count's clock on this screen: from the event's own host t0 and the host clock (or, under the
## "arrival" break, from when the event arrived on this screen's clock).
func clock_of(ev: Dictionary, host_now: float, local_now: float) -> Dictionary:
	var n := int(ev["n"])
	if not _arrived.has(n):
		_arrived[n] = local_now
		seen_at[n] = host_now
	var ht := host_now
	if test_break == "arrival":
		ht = float(ev["t0"]) + (local_now - float(_arrived[n]))
	var ck := Client.count_clock(ev, ht)
	ck["ht"] = ht
	return ck

## Count dark (0 lit .. 1 dark) at host time `ht` of count `ev`: the banks going, then dark, then coming back.
static func dark_at(ev: Dictionary, ht: float) -> float:
	var t0 := float(ev["t0"])
	var end := t0 + Client.hide_time(ev) + float(ev["len"])
	if ht < t0:
		return 0.0
	if ht < end:
		var out := clampi(int(floorf((ht - t0 - BANK_FIRST) / BANK_STEP)) + 1, 0, BANKS) if ht - t0 >= BANK_FIRST else 0
		return float(out) / BANKS
	var back := clampi(int(floorf((ht - end) / BACK_STEP)) + 1, 0, BANKS)
	return 1.0 - float(back) / BANKS

## Per frame on any floor. `s`: the snapshot (play_link.gd); `names`: player id -> name. Sets the HUD's
## count lines, prompts and health; drives the dark, the tune, the bell and the trill; returns what main.gd
## draws: {on, dark, noise, look (a point to turn the camera to, or null), catch}.
func update(s: Dictionary, dt: float, local_now: float, names: Dictionary, my_id: String, sfx: Sfx, ann: Announcer, hud: Hud, level: Level, others: Array) -> Dictionary:
	var k: Variant = s.get("seek")
	var place := str((level.plan as Dictionary).get("place", "clinic")) if level != null and level.plan is Dictionary else ""
	if s.get("wardHide") is Dictionary:
		# WH1d: the Hanging Ward's homes (client/play_link.gd wardHide): their hides' prompts; no count.
		if count_n != 0 or dark != 0.0 or not _hats.is_empty():
			reset()
		sfx.playroom(false, 0.0)
		hud.health = -1.0
		hud.anger = -1.0
		hud.count_by = ""
		hud.count_text = ""
		hud.party_note = ""
		party_line = ""
		hud.seek_note = ward_note(s)
		# Nothing is drawn over the picture in a Ward hide: the furniture round the camera is the frame.
		show_nothing_over()
		return {"on": false}
	if place == "clinic" or place == "annex":
		# Hiding off the Playroom (sim/hiding.gd): the hides' prompts, the dark inside and the gap; no count.
		if count_n != 0 or dark != 0.0 or not _hats.is_empty():
			reset()
		sfx.playroom(false, 0.0)
		hud.health = -1.0
		hud.anger = -1.0
		hud.count_by = ""
		hud.count_text = ""
		hud.party_note = ""
		party_line = ""
		_hiding_only(s, hud)
		return {"on": false}
	if not k is Dictionary:
		if count_n != 0 or dark != 0.0 or not _hats.is_empty():
			reset()
		sfx.playroom(false, 0.0)
		hud.health = -1.0
		hud.anger = -1.0
		hud.party_note = ""
		party_line = ""
		hud.count_by = ""
		hud.seek_note = ""
		return {"on": false}
	var seek: Dictionary = k
	var host_now := float(s.get("hostNow", 0.0))
	var row: Variant = s.get("mySeek")
	var ev: Dictionary = s.get("countEvent", {})
	var name_of := func(id: String) -> String: return str(names.get(id, id)).to_upper()
	# --- the count.
	var ck := {}
	if not ev.is_empty():
		ck = clock_of(ev, host_now, local_now)
	var n := int(ev.get("n", 0))
	if n != count_n and n > 0:
		count_n = n
		_bell_i = -1
		var why := str(WHY.get(str(ev["why"]), str(ev["why"]).to_upper()))
		started_by = "STARTED BY: %s, %s." % [name_of.call(str(ev["by"])), why] if str(ev["by"]) != "" else ""
	var ht := float(ck.get("ht", host_now))
	count_phase = str(ck.get("phase", ""))
	count_left = float(ck.get("left", 0.0))
	dark = dark_at(ev, ht) if not ev.is_empty() else 0.0
	if dark >= 1.0 and n > 0 and not dark_full_at.has(n):
		dark_full_at[n] = host_now
	var pv: Object = level.get_meta(&"playroom") if level != null and level.has_meta(&"playroom") else null
	if pv != null:
		pv.call("set_count_dark", dark)
	# The tune sags with the count.
	var want_sag := 0.0
	if not ev.is_empty():
		var t0 := float(ev["t0"])
		var end := t0 + Client.hide_time(ev) + float(ev["len"])
		want_sag = clampf((ht - t0) / SAG_TIME, 0.0, 1.0) if ht < end else clampf(1.0 - (ht - end) / SAG_TIME, 0.0, 1.0)
	sag = want_sag
	sfx.playroom(true, sag)
	# Lines and the bell.
	var tuned := ev.has("hide")
	if n > 0:
		var t0 := float(ev["t0"])
		var hide_len := Client.hide_time(ev)
		var last := bool(ev["last"])
		if count_phase == "hide":
			if ht - t0 < LATE and _once(n, "start"):
				sfx.play("xylo")
			if _once(n, "hide"):
				ann.say_count("hide", "HIDE.", LINE_MS)
			if tuned:
				# T15m: it counts while you hide, so the numbers mean what they say (seconds left to hide):
				# a bell a second, and forty, thirty, twenty, ten to one said (count_lines.gd).
				var hl := int(roundf(hide_len))
				var hi := int(floorf(ht - t0))
				if hi > _bell_i and hi >= 0 and hi < hl:
					_bell_i = hi
					var hnum := hl - hi
					sfx.count_bell(hnum)
					strokes.append([n, hi, host_now])
					if strokes.size() > 120:
						strokes.pop_front()
					if float(hi) >= COMING_TIME:
						ann.say_count("number", "%d." % hnum, NUMBER_MS, hnum, hl)
		elif count_phase == "seek" and tuned:
			# T15m: the search is quiet but for its music box; the line as it starts.
			if _once(n, "coming"):
				ann.say_count("search", "COMING, READY OR NOT!", int(COMING_TIME * 1000.0))
		elif count_phase == "seek":
			var t_s := t0 + hide_len
			var len := int(roundf(float(ev["len"])))
			var i := int(floorf(ht - t_s))
			if _once(n, "coming"):
				ann.say_count("search", "COMING, READY OR NOT!", int(COMING_TIME * 1000.0))
			if i > _bell_i and i >= 0 and i < len:
				_bell_i = i
				var num := len - i
				sfx.count_bell(num)
				strokes.append([n, i, host_now])
				if strokes.size() > 120:
					strokes.pop_front()
				if float(i) >= COMING_TIME:
					ann.say_count("number", "%d." % num, NUMBER_MS, num, len)
		elif count_phase == "over" and ht - (t0 + hide_len + float(ev["len"])) < 3.0:
			if _once(n, "done"):
				ann.say_count("done", "ALL DONE!", LINE_MS)
	# Found, whoever it is. And the sounds of the host's events: the found-you sting in your own ear, going
	# down, hides got into and out of, the Minder's huff at an empty hide (client/sfx.gd).
	var pv_hides: Array = pv.get("hides") if pv != null else []
	for e: Dictionary in s.get("events", []):
		var ty := str(e.get("type", ""))
		var who_id := str(e.get("playerId", ""))
		var at: Variant = null if who_id == my_id else _where(others, who_id)
		match ty:
			"hideStart", "hideLeave":
				if who_id == my_id or at != null:
					var hk := ""
					for h: Variant in pv_hides:
						if int(h.get("id")) == int(e["hide"]):
							hk = str(h.get("kind"))
					sfx.hide_move(hk, ty == "hideStart", bool(e.get("fast", false)), at)
			"partyHorn":
				sfx.play_at("horn", Vector3(float(e["x"]), float(e["y"]), float(e["z"])))
			"emptyHide":
				var mp: Variant = (s.get("orderly", {}) as Dictionary).get("pose")
				if mp is Dictionary:
					sfx.huff_at(Vector3(float(mp["x"]), float(mp["y"]) + Seek.MINDER_HEAD, float(mp["z"])))
			"down":
				if who_id == my_id or at != null:
					sfx.went_down(at)
		match ty:
			"found":
				var who := str(e["playerId"])
				var key := "%d:%s" % [n, who]
				if not _found_ids.has(key):
					_found_ids[key] = true
					# The Minder's grab outside a count has its own lines (announcer.gd say_grab); a count's
					# find says "Found you".
					if str(e.get("cause", "")) != "grab" or ann.say_grab(LINE_MS) == "":
						ann.say_count("found", "FOUND YOU, %s!" % name_of.call(who), LINE_MS)
					if who == my_id:
						sfx.found_me()
			"called":
				if bool(e.get("last", false)):
					ann.say_count("last_called", "YOUR CAR IS ON ITS WAY! ONE MORE ROUND BEFORE WE GO!", LINE_MS + 1800)
	_step_sounds(s, others, my_id, sfx, pv)
	# --- the HUD's count lines.
	var top := ""
	if count_phase == "hide":
		top = "HIDE  %d" % ceili(count_left)
	elif count_phase == "seek" and tuned:
		top = "%s %d" % ["LAST SEARCH" if bool(ev.get("last", false)) else "IT IS SEARCHING", ceili(count_left)]
	elif count_phase == "seek":
		top = "%s %d" % ["LAST COUNT" if bool(ev.get("last", false)) else "COUNTING", ceili(count_left)]
	elif not bool(seek["counting"]) and int(seek["ended"]) >= 1 and host_now < float(seek["calmUntil"]) and not bool(seek["done"]) and not bool(seek["called"]):
		top = "IT IS WINDING DOWN  %d" % ceili(float(seek["calmUntil"]) - host_now)
	elif bool(seek["called"]) and not bool(seek["counting"]) and seek["lastAt"] != null:
		top = "ONE LAST COUNT IN %d" % ceili(maxf(0.0, float(seek["lastAt"]) - host_now))
	hud.count_text = top
	hud.count_by = started_by if count_phase == "hide" else ""
	# T15m: the anger bar, the host's own number (the snapshot's seek block), the same on every screen.
	hud.anger = clampf(float(seek["anger"]), 0.0, 1.0) if seek.has("anger") else -1.0
	var hunt := hunt_of(seek)
	hud.anger_rates = anger_rates_text(tuning, hunt, party_of(seek)) if seek.has("anger") else ""
	# --- this player.
	var look: Variant = null
	var note := ""
	var status := str(row["status"]) if row is Dictionary else "ok"
	var phase := str(row["phase"]) if row is Dictionary else "out"
	var total := (float(row["sight"]) + float(row["gap"])) if row is Dictionary else 0.0
	var now_ms := Time.get_ticks_msec()
	if total > _prev_total + 1e-4 and status == "ok":
		_rising_until = now_ms + 250
	if total < _prev_total - 1e-4:
		_rising_until = 0
	_prev_total = total
	var rising := now_ms < _rising_until
	sfx.trill(total if rising else -1.0, dt)
	# Picture noise grows with the total, and stops growing (falls back) the moment it stops rising.
	var want_noise := clampf(total, 0.0, 1.0) * (1.0 if rising else 0.35) if status == "ok" else 0.0
	noise_k = move_toward(noise_k, want_noise, dt * 3.0)
	var o: Dictionary = s.get("orderly", {})
	var pose: Variant = o.get("pose")
	var me: Dictionary = s["me"]
	var hc: Dictionary = s.get("hideCam", {})
	var ov_mode := ""
	var ov_kind := ""
	if status == "ok":
		if phase == "inside":
			ov_mode = "peek" if bool(hc.get("peek", false)) else "sat"
			ov_kind = str(hc.get("kind", ""))
			note = "F  GET OUT    HOLD W  LEAN TO THE GAP" if ov_mode == "sat" else "LET GO OF W TO SIT BACK"
			var inst: Variant = s.get("inst")
			var raised := inst is Dictionary and bool((inst as Dictionary)["raised"])
			var tick_note := ticking_note(raised, bool(seek["counting"]), pose is Dictionary and float(o.get("distance", 99.0)) <= LOWER_RANGE, hunt)
			if tick_note != "":
				note = tick_note
		elif phase == "entering":
			note = "GETTING IN..."
		elif phase == "leaving":
			note = "GETTING OUT..."
		elif int(s.get("nearHide", -1)) >= 0:
			var kind := str(s.get("nearHideKind", ""))
			note = "F  HIDE: %s    SHIFT+F  QUICK BUT LOUD" % str(KIND_NAMES.get(kind, "HIDE"))
		# The party table (T15h): with someone seated, F held at the table frees them (and gets nobody into a hide).
		if phase == "out" and party_of(seek):
			var n_seated := seated_names(seek, names).size()
			var pt: Dictionary = seek["party"]
			if str(pt.get("by", "")) == my_id and float(pt.get("from", -1.0)) >= 0.0:
				note = fetch_note(n_seated, float(pt["from"]) + hold_len(pt) - host_now, tuning)
			elif n_seated > 0 and pv != null and near_table(_seats_of(pv), float(me["x"]), float(me["z"]), int(me.get("level", 0)), tuning):
				note = fetch_note(n_seated, -1.0, tuning)
	elif status == "found":
		hud.big_note = "FOUND"
		if pose is Dictionary:
			var pd: Dictionary = pose
			look = Vector3(float(pd["x"]), float(pd["y"]) + Seek.MINDER_HEAD + 0.15, float(pd["z"]))
			var d := Vector2(float(pd["x"]) - float(me["x"]), float(pd["z"]) - float(me["z"])).length()
			var om := str(o.get("mode", ""))
			if om == "catch" or om == "run" or om == "grab":
				catch_k = maxf(catch_k, clampf((CATCH_NEAR - d) / (CATCH_NEAR - CATCH_FULL), 0.0, 1.0))
			if om == "catch" or om == "grab":
				catch_k = minf(1.0, catch_k + dt * 0.8)
			elif om == "drag":
				# T15m: dragged to the party table, you see it pulling you along.
				catch_k = move_toward(catch_k, 0.0, dt * 2.0)
	elif status == "taken":
		hud.center_note = "AT THE PARTY TABLE   [F] BLOW HORN" if seek.has("anger") else "TAKEN: AT THE PARTY TABLE. WATCH."
	# The party table (T15h): told before it can happen, on every screen and on the lift.
	party_line = party_warning(seek, names)
	hud.party_note = party_warning(seek, names, status == "taken", tuning) if status == "taken" else party_line
	if status != "found":
		catch_k = move_toward(catch_k, 0.0, dt * 4.0)
	# CS1: once the Minder's own figure has come for you (client/caught_scene.gd), its flat card mask is not drawn.
	if scene_mask:
		catch_k = 0.0
	hud.seek_note = note
	hud.health = float(row["health"]) if row is Dictionary and shows_health(seek, count_phase, hunt) and status == "ok" else -1.0
	hud.health_rates = health_rates_text(hunt, tuning)
	# The overlay: the hiding state (nothing drawn for it), the catch, the hat.
	overlay.mode = ov_mode
	overlay.kind = ov_kind
	overlay.view_out = true
	overlay.catch_k = catch_k
	overlay.hat = status == "taken"
	overlay.queue_redraw()
	_draw_hats(others)
	return {"on": true, "dark": dark, "noise": maxf(noise_k, catch_k * 0.8), "look": look, "catch": catch_k}

## The Clinic's and the Annex's hides (docs/floors/traits-and-hiding.md section 4): F at a bed, a cabinet
## or the meeting table (SHIFT+F quick but loud); a desk by crawling under with Ctrl held (S or F gets you
## out). Inside, sat back in the dark or leaning to the gap with W. Nothing is drawn by chance here, so no
## odds are printed. The snapshot's seek block carries this player's row (net/host.gd's hiding block).
func _hiding_only(s: Dictionary, hud: Hud) -> void:
	var row: Variant = s.get("mySeek")
	var phase := str(row["phase"]) if row is Dictionary else "out"
	var hc: Dictionary = s.get("hideCam", {})
	var note := ""
	var ov_mode := ""
	var ov_kind := ""
	var me: Dictionary = s.get("me", {})
	if str(me.get("status", "ok")) == "ok":
		if phase == "inside":
			ov_mode = "peek" if bool(hc.get("peek", false)) else "sat"
			ov_kind = str(hc.get("kind", ""))
			if ov_mode == "sat":
				note = ("S OR F  CRAWL OUT" if ov_kind == "desk" else "F  GET OUT") + "    HOLD W  LEAN TO THE GAP"
			else:
				note = "LET GO OF W TO SIT BACK"
			var inst: Variant = s.get("inst")
			if inst is Dictionary and bool((inst as Dictionary)["raised"]):
				note = "TICKING IN A HIDE WITHIN 5 M OF IT MAKES IT LOOK IN. (E)"
		elif phase == "entering":
			note = "GETTING IN..."
		elif phase == "leaving":
			note = "GETTING OUT..."
		elif int(s.get("nearHide", -1)) >= 0:
			var kind := str(s.get("nearHideKind", ""))
			if kind == "desk":
				note = "HOLD CTRL AND WALK IN: UNDER THE DESK"
			else:
				note = "F  HIDE: %s    SHIFT+F  QUICK BUT LOUD" % str(KIND_NAMES.get(kind, "HIDE"))
	hud.seek_note = note
	overlay.mode = ov_mode
	overlay.kind = ov_kind
	overlay.view_out = false
	overlay.catch_k = 0.0
	overlay.hat = false
	overlay.queue_redraw()

## WH1d: the Ward homes' hide prompt, in the words of every floor's: in a hide, F gets you out (there is no leaning
## out of these); by one, F gets you in, SHIFT+F quick but loud. "" otherwise.
static func ward_note(s: Dictionary) -> String:
	var wh: Variant = s.get("wardHide")
	if not wh is Dictionary or str((s.get("me", {}) as Dictionary).get("status", "ok")) != "ok":
		return ""
	if bool((wh as Dictionary).get("in", false)):
		return "F  GET OUT"
	if int(s.get("nearHide", -1)) >= 0:
		return "F  HIDE: %s    SHIFT+F  QUICK BUT LOUD" % str(KIND_NAMES.get(str(s.get("nearHideKind", "")), "HIDE"))
	return ""

## The overlay draws nothing: no hiding state, no catch, no hat.
func show_nothing_over() -> void:
	if overlay == null:
		return
	overlay.mode = ""
	overlay.kind = ""
	overlay.view_out = true
	overlay.catch_k = 0.0
	overlay.hat = false
	overlay.queue_redraw()

func _once(n: int, what: String) -> bool:
	var key := "%d:%s" % [n, what]
	if _said.has(key):
		return false
	_said[key] = true
	return true

## Paper party hats on the other players at the table.
func _draw_hats(others: Array) -> void:
	var seen := {}
	for o: Dictionary in others:
		if not bool(o.get("hat", false)):
			continue
		var id := str(o["id"])
		seen[id] = true
		var mi: MeshInstance3D = _hats.get(id)
		if mi == null:
			mi = MeshInstance3D.new()
			mi.mesh = _hat()
			_hats_root.add_child(mi)
			_hats[id] = mi
		# On the crouched (seated) figure's head: its mask is at CREW_CROUCH_MASK above the drawn feet.
		mi.position = Vector3(float(o["x"]), float(o["y"]) + 1.13 + 0.2, float(o["z"]))
	for id: String in _hats.keys():
		if not seen.has(id):
			(_hats[id] as Node).queue_free()
			_hats.erase(id)

func _hat() -> Mesh:
	if _hat_mesh != null:
		return _hat_mesh
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = 0.1
	c.height = 0.24
	c.radial_segments = 10
	c.rings = 1
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.35, 0.55)
	m.emission_enabled = true
	m.emission = Color(0.5, 0.15, 0.3)
	m.emission_energy_multiplier = 0.6
	c.material = m
	_hat_mesh = c
	return c

## Tests: what this screen shows of the count and the hiding.
func describe() -> Dictionary:
	return {"n": count_n, "phase": count_phase, "left": count_left, "dark": dark, "sag": sag, "startedBy": started_by,
		"seenAt": seen_at, "darkFullAt": dark_full_at, "strokes": strokes.duplicate(), "noise": noise_k, "catch": catch_k,
		"overlay": overlay.mode if overlay != null else "", "overlayKind": overlay.kind if overlay != null else "", "hat": overlay.hat if overlay != null else false,
		"hats": _hats.keys(), "break": test_break, "viewOut": overlay.view_out if overlay != null else false}

## Drawn over the picture, under the HUD: the Minder's mask filling the screen at the catch and the brim of
## your own paper hat. Nothing while you hide (MH1b; the owner, 21 Nov: "The camera correctly being placed in
## the hiding spot means you don't need to add stuff as a mask over the camera itself, the objects do it for
## you."): the camera sits inside the hide (client/play_link.gd hide_camera) and the hide's own 3D walls,
## slats, netting, coats, lid and frame are what you see round its gap. `mode`, `kind` and `view_out` stay
## as the state (the playthroughs read them); none of them draws anything.
class HideOverlay:
	extends Control
	var mode := ""       # "" | "sat" | "peek"
	var kind := ""
	var catch_k := 0.0
	var hat := false
	## The Playroom (T15m): sat back you still see out. Kept as state only: no hiding state draws over the picture.
	var view_out := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _process(_d: float) -> void:
		var want := get_viewport_rect().size
		if size != want:
			position = Vector2.ZERO
			size = want

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if not draws_anything(mode, catch_k, hat):
			return
		if catch_k > 0.0:
			_mask(catch_k)
		if hat:
			# The brim of your own paper hat, just in view at the top.
			var c := Color(0.95, 0.35, 0.55, 0.85)
			draw_colored_polygon(PackedVector2Array([Vector2(w * 0.38, 0), Vector2(w * 0.62, 0), Vector2(w * 0.5, h * 0.035)]), c)

	## Whether the overlay draws anything: only the catch's mask and the hat's brim, never a hiding state
	## (sat back or peeking, in any kind of hide). Tests read it (tests/test_hide_inside.gd).
	static func draws_anything(_mode: String, catch_k_: float, hat_: bool) -> bool:
		return catch_k_ > 0.0 or hat_

	## What the overlay draws for a hiding state, as a pure function (tests/prop_playroom_tuned.gd and
	## tests/test_hide_inside.gd read it): no dark, no gap, no frame, no balls, for every mode and kind. The
	## view out, and the dark inside, are the hide's own 3D.
	static func layout(_mode: String, _kind: String, _view_out: bool, _w: float, _h: float) -> Dictionary:
		return {"dark": 0.0, "hole": null, "holeAlpha": 0.0, "frame": false, "balls": 0, "ballRect": Rect2(), "ballAlpha": 0.0}

	## The Minder's card mask, filling the screen as it bends for the catch: a pale glowing card, two
	## dots and a curve, its edge running off the screen.
	func _mask(k: float) -> void:
		var w := size.x
		var h := size.y
		var c := Vector2(w * 0.5, h * 0.5)
		var r := lerpf(h * 0.18, h * 0.95, k)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55 * k))
		draw_circle(c, r * 1.08, Color(0.55, 0.95, 0.6, 0.25 * k))
		draw_circle(c, r, Color(0.88, 0.95, 0.78, 0.92 * minf(1.0, k * 1.6)))
		var ink := Color(0.05, 0.05, 0.06, minf(1.0, k * 1.6))
		draw_circle(c + Vector2(-r * 0.32, -r * 0.18), r * 0.09, ink)
		draw_circle(c + Vector2(r * 0.32, -r * 0.18), r * 0.09, ink)
		draw_arc(c + Vector2(0, r * 0.05), r * 0.42, 0.25, PI - 0.25, 24, ink, maxf(2.0, r * 0.05))
