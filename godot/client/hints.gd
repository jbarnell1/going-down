# The announcer's hints (docs/floors/announcer-hints.md, AH1): the table as data, and the gate of
# section 4 as plain functions of a clock passed in (milliseconds). No engine time, no audio, no files
# in here: client/announcer.gd asks this gate before it queues a hint (may_request) and again before it
# starts one (may_start), tells it when one starts (started) or is cut short (cut), and keeps the
# player's own record (to_save / from_save, user://hints.cfg) so the first-timer hints retire.
#
# A hint is one recorded line that teaches one system the first time a crew meets it. Every hint is one
# moment in assets_src/voice/lines.json (group "hints") with an A line (_1) and a B line (_2).
#
# The gate (section 4):
#  1. Heard: each hint's repeat rule (night, day, floor, count caps; 0 = no cap). A hint is heard when it
#     STARTS playing; one that expires in the queue or is cut short is not heard and may try again.
#  2. Spacing: the same hint never twice within 60 s; any two hints at least 30 s apart (8 s when the
#     second is priority 4); at most 5 hints on one floor.
#  3. Never over another line: a hint starts only when none of the three players is playing (busy), never
#     while a count number is 6 s or less away, never in the last 11 s of a count.
#  4. Hints never cut (client/announcer.gd). 5. Short life: 6 s in the queue (priority 4: 3 s).
#  6. Replaces: the announcer asks for the hint instead of the line it replaces; refused, the line plays.
#  7. Not in the first 2 s of a run (or a day: every start_run).
#  Retiring (question 3's default): a hint with a "night" cap that this player has heard on two different
#  nights is not played again for them. HINTS: OFF in the Esc menu stops them all.
extends RefCounted

const SAME_GAP_MS := 60000
const ANY_GAP_MS := 30000
const URGENT_GAP_MS := 8000
const URGENT := 4
const FLOOR_MAX := 5
const LIFE_MS := 6000
const URGENT_LIFE_MS := 3000
const RUN_QUIET_MS := 2000
## No hint starts while a spoken count number is this close (seconds), or in the count's last seconds.
const NUMBER_CLEAR_S := 6.0
const COUNT_TAIL_S := 11.0
## The Playroom's count (client/hide_view.gd, client/count_lines.gd): the numbers said, and the search's
## first seconds that belong to "Coming, ready or not!" (hide_view.gd COMING_TIME).
const NUMBERS := [40, 30, 20, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
const COMING_TIME := 2.0
const HIDE_TIME := 6.0
## Nights heard before a first-timer hint retires.
const RETIRE_NIGHTS := 2

## The deliberate breaks (AH1): "heard_on_request" marks a hint heard when it is asked for, not when it
## starts; "no_same_gap" drops the 60 s rule. Tests only.
static var test_break := ""

## The table (section 2). pri: the announcer's priority 1..5. night/day/floor/count: the most times it is
## heard per night, day, floor, count (0: no cap). who: "C" (the whole crew: a shared event) or "Y" (only
## this screen). replaces: the moment it is asked for instead of. only/never: places it may / may not
## play on. wired: its trigger exists in the code today; otherwise waits names the piece that brings it.
const TABLE := {
	"hint_job": {"pri": 2, "night": 1, "who": "C", "wired": true},
	"hint_quiet_needle": {"pri": 2, "night": 1, "who": "C", "wired": true},
	"hint_call_dead": {"pri": 2, "floor": 1, "day": 2, "who": "C", "wired": true},
	"hint_floor_not_day": {"pri": 2, "day": 1, "who": "C", "waits": "FD2 (the day's earned on screen)"},
	"hint_board": {"pri": 3, "day": 1, "who": "C", "replaces": "arrived", "wired": true},
	"hint_straggler": {"pri": 3, "day": 2, "who": "C", "wired": true},
	"hint_left_crew": {"pri": 3, "day": 1, "who": "C", "wired": true},
	"hint_left_you": {"pri": 4, "who": "Y", "wired": true},
	"hint_car_stay": {"pri": 2, "day": 1, "who": "C", "wired": true},
	"hint_car_no_record": {"pri": 2, "day": 1, "who": "Y", "wired": true},
	"hint_car_here": {"pri": 2, "day": 1, "who": "C", "waits": "a refused call while the car is held (no event yet)"},
	"hint_vote": {"pri": 2, "night": 1, "who": "C", "wired": true},
	"hint_bank_locked": {"pri": 3, "day": 1, "who": "C", "waits": "FD2 (BANK locked until the day quota)"},
	"hint_day": {"pri": 2, "night": 1, "who": "C", "replaces": "ride", "waits": "FD2 (the day quota on the lift monitor)"},
	"hint_stakes": {"pri": 2, "night": 1, "who": "C", "waits": "FD2 (the odds on the monitor) and the crew's upgrades on the client"},
	"hint_last_miss": {"pri": 3, "who": "C", "wired": true},
	"hint_down_crew": {"pri": 4, "day": 2, "who": "C", "wired": true},
	"hint_down_you": {"pri": 4, "day": 2, "who": "Y", "wired": true},
	"hint_out": {"pri": 2, "day": 1, "who": "C", "wired": true},
	"hint_winded": {"pri": 1, "night": 1, "who": "Y", "wired": true},
	"hint_search": {"pri": 1, "night": 1, "who": "Y", "waits": "FD10 (the search prompt)"},
	"hint_note": {"pri": 2, "night": 1, "who": "C", "waits": "FD9 (poem notes found)"},
	"hint_juice": {"pri": 1, "night": 1, "who": "Y", "waits": "FD9 (juice cartons)"},
	"hint_odds": {"pri": 1, "night": 1, "who": "Y", "waits": "FD10 (the lobby's findables sheet)"},
	"hint_marks": {"pri": 2, "night": 1, "who": "C", "only": ["annex"], "wired": true},
	"hint_hide": {"pri": 1, "night": 1, "who": "Y", "never": ["playroom"], "wired": true},
	"hint_hide_idle": {"pri": 1, "day": 1, "who": "Y", "wired": true},
	"hint_play_arrive": {"pri": 3, "who": "C", "replaces": "doors", "only": ["playroom"], "wired": true},
	"hint_play_anger": {"pri": 2, "floor": 1, "who": "C", "only": ["playroom"], "waits": "the anger bar"},
	"hint_play_instruments": {"pri": 4, "floor": 1, "who": "C", "only": ["playroom"], "wired": true},
	"hint_play_no_run": {"pri": 4, "floor": 3, "count": 1, "who": "C", "only": ["playroom"], "wired": true},
	"hint_play_after": {"pri": 3, "floor": 1, "who": "C", "only": ["playroom"], "wired": true},
	"hint_play_table": {"pri": 2, "day": 1, "who": "Y", "only": ["playroom"], "waits": "T15h (the horn on F at the party table)"},
	"hint_listen": {"pri": 2, "night": 1, "who": "C", "wired": true},
	"hint_new_floor": {"pri": 2, "night": 1, "who": "C", "replaces": "doors", "wired": true},
	"hint_reroll": {"pri": 2, "day": 1, "who": "C", "replaces": "doors", "never": ["playroom"], "wired": true},
	"hint_home": {"pri": 2, "night": 1, "who": "C", "only": ["prison"], "waits": "the prison's shop windows (CLOSED today: the line says spend there)"},
	"hint_bed": {"pri": 2, "night": 1, "who": "C", "only": ["prison"], "wired": true},
}

## The words no hint may say (section 2 "Why each is safe" and AH1's checks): the trait names and the
## residents' bodies (findables-and-day.md FD8's body list).
const TRAIT_WORDS := ["stillness", "lonely", "hearing", "watched", "light-shy", "lightshy"]
const BODY_WORDS := ["orderly", "temp", "minder", "trolley", "stapler", "mask", "gurney", "clipboard", "lanyard", "scrubs"]

var enabled := true
## This night's key (any string unique to the night: the announcer uses the start time).
var night_key := ""
## The player's record: hint id -> [night keys it was heard on] (only hints with a night cap).
var nights_heard := {}
var heard_night := {}
var heard_day := {}
var heard_floor := {}
var heard_count := {}
var last_of := {}
var last_any := -1
var last_pri := 0
var floor_n := 0
var run_at := -100000

static func is_hint(moment: String) -> bool:
	return TABLE.has(moment)

static func priority(id: String) -> int:
	return int(TABLE[id]["pri"]) if TABLE.has(id) else 1

static func life_ms(id: String) -> int:
	return URGENT_LIFE_MS if priority(id) >= URGENT else LIFE_MS

static func wired(id: String) -> bool:
	return TABLE.has(id) and bool(TABLE[id].get("wired", false))

## Whether a hint may play on a place ("clinic", "annex", "playroom", "prison"; "" unknown).
static func place_ok(id: String, place: String) -> bool:
	var row: Dictionary = TABLE.get(id, {})
	var only: Array = row.get("only", [])
	if not only.is_empty() and not only.has(place):
		return false
	return not (row.get("never", []) as Array).has(place)

## Seconds until the count's next spoken number (INF when none is coming). `count`: {"phase": "hide" |
## "seek" | "", "left": seconds left of that phase, "len": the search's length}.
static func number_in(count: Dictionary) -> float:
	var phase := str(count.get("phase", ""))
	var left := float(count.get("left", 0.0))
	var length := int(count.get("len", 0))
	if phase != "hide" and phase != "seek":
		return INF
	var best := INF
	for r: int in NUMBERS:
		# Said on the stroke where `r` seconds are left, never the count's own length, never in
		# "Coming"'s first seconds (hide_view.gd).
		if r >= length or float(length - r) < COMING_TIME:
			continue
		var at := (left + float(length - r)) if phase == "hide" else (left - float(r))
		if at >= -0.001 and at < best:
			best = at
	return maxf(0.0, best)

## Why a hint may not be asked for now, or "" when it may.
func may_request(id: String, now: int, place: String) -> String:
	if not TABLE.has(id):
		return "not a hint"
	if not enabled:
		return "hints off"
	if retired(id):
		return "retired"
	if not place_ok(id, place):
		return "place"
	if now - run_at < RUN_QUIET_MS:
		return "run start"
	var row: Dictionary = TABLE[id]
	for cap: String in ["night", "day", "floor", "count"]:
		var n := int(row.get(cap, 0))
		var heard: Dictionary = get("heard_" + cap)
		if n > 0 and int(heard.get(id, 0)) >= n:
			return "heard this " + cap
	if floor_n >= FLOOR_MAX:
		return "floor full"
	if test_break != "no_same_gap" and last_of.has(id) and now - int(last_of[id]) < SAME_GAP_MS:
		return "same within 60 s"
	var gap := URGENT_GAP_MS if int(row["pri"]) >= URGENT else ANY_GAP_MS
	if last_any >= 0 and now - last_any < gap:
		return "spacing"
	return ""

## Why a queued hint may not start now, or "" when it may. `busy`: any of the announcer's three players
## is playing. `count`: as number_in.
func may_start(id: String, now: int, place: String, busy: bool, count: Dictionary) -> String:
	var why := may_request(id, now, place)
	if why != "":
		return why
	if busy:
		return "busy"
	if number_in(count) <= NUMBER_CLEAR_S:
		return "number soon"
	if str(count.get("phase", "")) == "seek" and float(count.get("left", 0.0)) <= COUNT_TAIL_S:
		return "count tail"
	return ""

## A hint started: heard. Returns what to give back to cut() if it is stopped before it ends.
func started(id: String, now: int) -> Dictionary:
	var undo := {"id": id, "last_of": last_of.get(id, null), "last_any": last_any, "last_pri": last_pri, "nights": (nights_heard.get(id, []) as Array).duplicate()}
	for cap: String in ["night", "day", "floor", "count"]:
		var heard: Dictionary = get("heard_" + cap)
		heard[id] = int(heard.get(id, 0)) + 1
	floor_n += 1
	last_of[id] = now
	last_any = now
	last_pri = priority(id)
	if int(TABLE[id].get("night", 0)) > 0 and night_key != "":
		var nights: Array = nights_heard.get(id, [])
		if not nights.has(night_key):
			nights = nights.duplicate()
			nights.append(night_key)
			nights_heard[id] = nights
	return undo

## A started hint was cut short: not heard after all.
func cut(undo: Dictionary) -> void:
	var id := str(undo.get("id", ""))
	if id == "":
		return
	for cap: String in ["night", "day", "floor", "count"]:
		var heard: Dictionary = get("heard_" + cap)
		var n := int(heard.get(id, 0)) - 1
		if n > 0:
			heard[id] = n
		else:
			heard.erase(id)
	floor_n = maxi(0, floor_n - 1)
	if undo["last_of"] == null:
		last_of.erase(id)
	else:
		last_of[id] = int(undo["last_of"])
	last_any = int(undo["last_any"])
	last_pri = int(undo["last_pri"])
	var nights: Array = undo["nights"]
	if nights.is_empty():
		nights_heard.erase(id)
	else:
		nights_heard[id] = nights

## Retired for this player: a first-timer hint heard on RETIRE_NIGHTS other nights.
func retired(id: String) -> bool:
	if int(TABLE.get(id, {}).get("night", 0)) <= 0:
		return false
	var n := 0
	for k: String in nights_heard.get(id, []):
		if k != night_key:
			n += 1
	return n >= RETIRE_NIGHTS

func new_night(key: String, now: int) -> void:
	night_key = key
	heard_night = {}
	last_of = {}
	last_any = -1
	new_day(now)

func new_day(now: int) -> void:
	heard_day = {}
	run_at = now
	new_floor()

func new_floor() -> void:
	heard_floor = {}
	floor_n = 0
	new_count()

func new_count() -> void:
	heard_count = {}

func to_save() -> Dictionary:
	return {"enabled": enabled, "nights": nights_heard.duplicate(true)}

func from_save(d: Dictionary) -> void:
	enabled = bool(d.get("enabled", true))
	nights_heard = {}
	var n: Variant = d.get("nights", {})
	if n is Dictionary:
		for id: Variant in n:
			if TABLE.has(str(id)) and n[id] is Array:
				var keys: Array = []
				for k: Variant in n[id]:
					keys.append(str(k))
				nights_heard[str(id)] = keys
