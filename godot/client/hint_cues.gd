# The hints' triggers that only this screen sees, or that need the snapshot rather than an event
# (docs/floors/announcer-hints.md section 2, AH1). main.gd calls update() once a frame, after the frame's
# events have gone to the announcer; every trigger is one call to Announcer.hint (the gate in
# client/hints.gd decides whether it plays). The event triggers are in Announcer.on_events.
#
#   hint_winded          you are winded (the stamina tank's mark), first time tonight
#   hint_left_you/_crew  your own / another player's status becomes leftBehind (a run with days)
#   hint_straggler       the boarding doors are 14 s from closing and an active player is not aboard
#   hint_car_stay        the arrival car has waited 10 s with someone aboard and someone on the floor
#   car_waiting          the car's nags: 20 s, then every 30 s, while anyone keeps it (FD4); the call
#                        panel's CAR WAITING FOR: NAMES is the second caption line
#   hint_car_no_record   you hold the instrument up while aboard the waiting car
#   hint_quiet_needle    120 s on a floor, nothing earned there, an instrument raised at least once
#   hint_hide            a hide's prompt shows on your screen (not on the Playroom)
#   hint_hide_idle       25 s in a hide with no count running
#   hint_play_no_run     you sprint during a Playroom search (after the crew's own first one)
#   hint_last_miss       a new day with two misses this night
#   hint_floor_not_day   the floor quota is met ("quotaMet") while the host says the day is locked (FD3)
#   hint_bank_locked     boarding, someone stands on BANK while the day is locked
#   hint_stakes          the morning, when the monitor's stakes row says someone owns an upgrade
# (hint_day, in place of the night's first ride line, is the announcer's own: Announcer.on_events.)
# The waiting-car lines and hints play only in a run with days (the game's rooms, where the car waits:
# sim/run.gd car_waits); the left-behind lines say "your cell", which only a run with days has.
extends RefCounted

const DayView = preload("res://client/day_view.gd")

const STRAGGLER_AT := 14.0
const CAR_STAY_S := 10.0
const CAR_NAG_FIRST_S := 20.0
const CAR_NAG_EVERY_S := 30.0
const QUIET_NEEDLE_S := 120.0
const HIDE_IDLE_S := 25.0
const LAST_MISS_DELAY_MS := 2200
## The day quota's hints (FD3): after the floor's quota line; a while into the morning.
const FLOOR_NOT_DAY_DELAY_MS := 4500
const STAKES_DELAY_MS := 12000
## A condition that holds is asked again this often while the gate refuses it.
const RETRY_MS := 3000

var _status := {}
var _winded := false
var _sprinting := false
var _near_hide := false
var _raised_aboard := false
var _bell_left := INF
var _floor_key := ""
var _floor_since := -1
var _raised_floor := false
var _unload_since := -1
var _nags := 0
var _hide_since := -1
var _tried := {}
var _stakes_key := -1

func reset() -> void:
	_stakes_key = -1
	_status = {}
	_winded = false
	_sprinting = false
	_near_hide = false
	_raised_aboard = false
	_bell_left = INF
	_floor_key = ""
	_floor_since = -1
	_raised_floor = false
	_unload_since = -1
	_nags = 0
	_hide_since = -1
	_tried = {}

## `s`: the frame's snapshot (client/play_link.gd step); `latest`: the host's newest snapshot (players
## with "aboard", "active", "status"); `quota`: the host's quota block or null; `car_text`: the call
## panel's CAR WAITING FOR line ("" when nobody keeps the car); `now`: ms.
func update(ann: Announcer, s: Dictionary, latest: Variant, quota: Variant, car_text: String, now: int) -> void:
	if not s.has("me"):
		return
	var me: Dictionary = s["me"]
	var my_id := str(me.get("id", ""))
	var days := s.get("day") != null
	var phase := str(s.get("phase", ""))
	var place := ann.place
	# The day quota's lock (FD3): the host's day block, or null without the lock.
	var lock: Variant = DayView.lock_of(s.get("day"))
	for e: Dictionary in s.get("events", []):
		if str(e.get("type", "")) == "newDay":
			var day: Variant = s.get("day")
			if day is Dictionary and int((day as Dictionary).get("misses", 0)) == 2:
				ann.later("hint_last_miss", LAST_MISS_DELAY_MS)
		elif str(e.get("type", "")) == "quotaMet" and lock is Dictionary and bool((lock as Dictionary)["locked"]):
			# This floor is paid but today is not: after the quota line.
			ann.later("hint_floor_not_day", FLOOR_NOT_DAY_DELAY_MS)
	# A morning (or the first day) when someone in the crew owns an upgrade: what an empty car costs (the
	# monitor's stakes row names an owner's loss only when somebody owns one).
	if lock is Dictionary:
		var dkey := int((lock as Dictionary)["day"]) * 1000 + int(s.get("depth", 0))
		if dkey != _stakes_key and int(s.get("depth", 0)) == 1:
			_stakes_key = dkey
			if str((lock as Dictionary)["stakes"]).contains("LOSES ONE UPGRADE"):
				ann.later("hint_stakes", STAKES_DELAY_MS)

	# The floor: what it has seen since the doors opened.
	var key := "%s/%d" % [str(s.get("seed", "")), int(s.get("depth", 0))]
	if key != _floor_key:
		_floor_key = key
		_floor_since = -1
		_raised_floor = false
		_unload_since = -1
		_nags = 0
		_tried = {}
	if _floor_since < 0 and phase != "arriving" and phase != "riding":
		_floor_since = now
	var inst: Variant = s.get("inst")
	var raised := inst is Dictionary and bool((inst as Dictionary).get("raised", false))
	if raised:
		_raised_floor = true
	for o: Dictionary in s.get("others", []):
		if bool(o.get("raised", false)):
			_raised_floor = true

	# Winded, the first time tonight.
	var winded := bool(me.get("winded", false))
	if winded and not _winded:
		ann.hint("hint_winded")
	_winded = winded

	# Left behind (a run with days): your own status, or a crewmate's.
	var now_status := {my_id: str(me.get("status", "ok"))}
	for o: Dictionary in s.get("others", []):
		now_status[str(o.get("id", ""))] = str(o.get("status", "ok"))
	for id: String in now_status:
		var st: String = now_status[id]
		var was: String = _status.get(id, st)
		if days and st == "leftBehind" and was != "leftBehind":
			ann.hint("hint_left_you" if id == my_id else "hint_left_crew")
	_status = now_status

	# The players as the host has them.
	var aboard_n := 0
	var floor_n := 0
	var on_bank := false
	if latest is Dictionary:
		for p: Dictionary in (latest as Dictionary).get("players", []):
			if not bool(p.get("active", false)) or str(p.get("status", "")) != "ok":
				continue
			if str(p.get("side", "")) == "bank":
				on_bank = true
			if bool(p.get("aboard", false)):
				aboard_n += 1
			else:
				floor_n += 1

	# Boarding: 14 s before the doors close, someone active is not aboard.
	if phase == "boarding":
		var bl := float(s.get("bellLeft", INF))
		if _bell_left > STRAGGLER_AT and bl <= STRAGGLER_AT and floor_n > 0:
			ann.hint("hint_straggler")
		_bell_left = bl
		# Someone stands on BANK while the host says it is locked (FD3).
		if on_bank and lock is Dictionary and bool((lock as Dictionary)["locked"]):
			_try(ann, "hint_bank_locked", now)
	else:
		_bell_left = INF

	# The waiting car (FD4, a run with days).
	var host_phase := str((latest as Dictionary).get("phase", "")) if latest is Dictionary else ""
	if days and host_phase == "unloading" and aboard_n > 0:
		if _unload_since < 0:
			_unload_since = now
		var waited := (now - _unload_since) / 1000.0
		if waited >= CAR_STAY_S and floor_n > 0:
			_try(ann, "hint_car_stay", now)
		if waited >= CAR_NAG_FIRST_S + CAR_NAG_EVERY_S * _nags:
			_nags += 1
			ann.request("car_waiting", Announcer.EXPIRE_LONG_MS, car_text)
		var up_aboard := raised and bool(me.get("aboard", false))
		if up_aboard and not _raised_aboard:
			ann.hint("hint_car_no_record")
		_raised_aboard = up_aboard
	else:
		_unload_since = -1
		_nags = 0
		_raised_aboard = false

	# Nothing recorded after two minutes on the floor, with an instrument raised at least once.
	if quota is Dictionary and int(s.get("depth", 0)) >= 1 and _floor_since >= 0 and _raised_floor \
		and int((quota as Dictionary).get("earned", 0)) == 0 and now - _floor_since >= int(QUIET_NEEDLE_S * 1000.0):
		_try(ann, "hint_quiet_needle", now)

	# The hides: a prompt showing (off the Playroom), and sitting in one.
	var near := int(s.get("nearHide", -1)) >= 0
	if near and not _near_hide:
		ann.hint("hint_hide")
	_near_hide = near
	var my_seek: Variant = s.get("mySeek")
	var inside := my_seek is Dictionary and str((my_seek as Dictionary).get("phase", "")) == "inside"
	var counting := str(ann.count_ctx.get("phase", "")) in ["hide", "seek"]
	if inside and not counting:
		if _hide_since < 0:
			_hide_since = now
		if now - _hide_since >= int(HIDE_IDLE_S * 1000.0):
			_try(ann, "hint_hide_idle", now)
	else:
		_hide_since = -1

	# Sprinting during a Playroom search.
	var sprinting := str(me.get("gait", "")) == "sprint" and str(ann.count_ctx.get("phase", "")) == "seek"
	if sprinting and not _sprinting and place == "playroom":
		ann.hint("hint_play_no_run")
	_sprinting = sprinting

func _try(ann: Announcer, id: String, now: int) -> void:
	if _tried.has(id) and now - int(_tried[id]) < RETRY_MS:
		return
	_tried[id] = now
	ann.hint(id)
