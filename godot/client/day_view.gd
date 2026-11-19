# The day quota on screen (FD3; docs/floors/findables-and-day.md section 1, "Where it is shown"). Every
# number is the host's: the snapshot's day block (net/client.gd day_lock(): earned, quota, locked, aboard,
# each, stakes; sim/run.gd day_lock). Nothing is summed here: a client that added up readings it has seen
# would drift from the host under loss.
#  - The HUD's corner line, on a floor and in the car: "DAY EARNED 1650/2400", amber "DAY EARNED 2610/2400 MET" once met.
#  - The lift monitor (lift.gd show_day): row 1 "DAY 2. EARNED 1650 OF 2400.", row 2 "BANK LOCKED. 750 TO
#    GO." or "BANK OPEN. ABOARD 2380. EACH GETS 595.", row 3 (boarding only) what a day nobody comes back
#    from costs (sim/day.gd monitor_rows, stakes_row). Blank at home.
#  - The BANK paint (lift.gd set_bank_locked): hatched grey and LOCKED while the host says locked.
#  - At home the call panel reads CLOSED UNTIL MORNING once the car is shut for the night (no voice).
#  - The captions under the announcer's day lines: "EARNED 1650 OF 2400" (the lines carry no numbers).
# Without the lock (a run without days, or the test switch quota=0) everything here is empty.
extends RefCounted

const Day = preload("res://sim/day.gd")

const CLOSED_TEXT := "CLOSED UNTIL MORNING"

## This frame: the HUD's corner line and whether it is met (amber); the monitor's rows ([] for blank);
## whether BANK is locked; the call panel's night text ("" for none).
var hud_line := ""
var met := false
var rows: PackedStringArray = PackedStringArray()
var locked := false
var closed := ""
## The host's numbers this frame was drawn from ({} without the lock): tests compare them with the host.
var seen := {}

## The host's day lock from a snapshot's day block, or null without one.
static func lock_of(day: Variant) -> Variant:
	if not day is Dictionary or not (day as Dictionary).has("earned"):
		return null
	return day

static func hud_text(d: Dictionary) -> String:
	var earned := int(d["earned"])
	var quota := int(d["quota"])
	return "DAY EARNED %d/%d" % [earned, quota] + ("" if bool(d["locked"]) else " MET")

static func monitor(d: Dictionary, boarding: bool) -> PackedStringArray:
	var r := Day.monitor_rows(int(d["day"]), int(d["earned"]), int(d["quota"]), int(d["aboard"]), int(d["each"]), str(d["stakes"]))
	if not boarding:
		r = r.slice(0, 2)
	return r

## The caption under a day line: the event's own numbers.
static func caption(e: Dictionary) -> String:
	return "DAY EARNED %d OF %d" % [int(e.get("earned", 0)), int(e.get("quota", 0))]

## `s`: the frame's snapshot (client/play_link.gd step: "day", "depth", "phase", "goingUp").
func update(s: Dictionary) -> void:
	hud_line = ""
	met = false
	rows = PackedStringArray()
	locked = false
	closed = ""
	seen = {}
	var d: Variant = lock_of(s.get("day"))
	if d == null:
		return
	seen = {"earned": int(d["earned"]), "quota": int(d["quota"]), "locked": bool(d["locked"])}
	var depth := int(s.get("depth", 0))
	var phase := str(s.get("phase", ""))
	if depth == 0 and not bool(s.get("goingUp", false)):
		if phase == "night":
			closed = CLOSED_TEXT
		return
	var dd: Dictionary = d
	locked = bool(dd["locked"])
	met = not locked
	hud_line = hud_text(dd)
	rows = monitor(dd, phase == "boarding")

func describe() -> Dictionary:
	return {"hud": hud_line, "met": met, "rows": Array(rows), "locked": locked, "closed": closed, "seen": seen}
