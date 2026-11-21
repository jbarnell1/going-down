# The floor quota on screen (North Star C9; T5r). Everything here is the host's: the quota block of the
# newest snapshot (net/client.gd quota(): {earned, needed}, null when the run has no quota) and the run's
# "callRefused" and "quotaMet" events. Nothing is summed or predicted on this screen.
#  - The lift's call panel (lift.gd show_quota) reads "RECORDED 640 OF 1200" until the quota is met, then
#    "QUOTA MET. CALL THE CAR."; nothing at home (needed 0) or in a run without the quota.
#  - Pressed too early ("callRefused" for this player): a short buzz and, for FLASH_MS, the panel flashes
#    "NOT YET: 640 OF 1200" with the event's own numbers.
#  - In reach of the call button the panel's words are also printed crisp under the prompt (hud.gd
#    quota_line), since the panel itself is small in the 480x270 picture.
#  - "quotaMet": the announcer's quota line (announcer.gd on_events, moment "quota").
#  - PY1: a refusal that carries its own words ("line": the Reactor's call without power, sim/run.gd
#    POWER_REFUSED_LINE) flashes those words, quota or none.
extends RefCounted

const CALL_PROMPT := "F  \u25bc CALL"

const FLASH_MS := 1600
const BLINK_MS := 160

## What the panel says now, as one line ("" for no panel), and its tone: "count", "met" or "refused".
var text := ""
var tone := ""
## The refusal being flashed: its words and until when (msec).
var flash_text := ""
var flash_until := -1
var flashing := false
## PY1: the refusal being flashed carries its own words (shown even where the floor asks no quota).
var flash_own := false
## Tests: how many refusals this screen showed.
var refusals := 0

## Whether the floor is paid from the host's current quota block.
static func floor_met(q: Variant) -> bool:
	return q is Dictionary and int(q.get("needed", 0)) > 0 and int(q.get("earned", 0)) >= int(q["needed"])

static func floor_hud_text(q: Variant, depth: int, phase: String) -> String:
	if depth <= 0 or phase in ["riding", "ended"] or not q is Dictionary or int(q.get("needed", 0)) <= 0:
		return ""
	return "FLOOR RECORDED %d/%d%s" % [int(q.get("earned", 0)), int(q["needed"]), " MET" if floor_met(q) else ""]

## The panel's words for the host's quota block, or "" without one.
static func panel_text(q: Variant) -> String:
	if not q is Dictionary:
		return ""
	var d: Dictionary = q
	var needed := int(d.get("needed", 0))
	if needed <= 0:
		return ""
	var earned := int(d.get("earned", 0))
	if earned < needed:
		return "RECORDED %d OF %d" % [earned, needed]
	return "QUOTA MET. CALL THE CAR."

static func refused_text(earned: int, needed: int) -> String:
	return "NOT YET: %d OF %d" % [earned, needed]

func reset() -> void:
	text = ""
	tone = ""
	flash_text = ""
	flash_own = false
	flash_until = -1
	flashing = false

## This frame's events: a refusal of this player's own press buzzes and starts the flash.
func on_events(events: Array, my_id: String, sfx: Sfx, now: int) -> void:
	for e: Dictionary in events:
		if str(e["type"]) == "callRefused" and str(e.get("playerId", "")) == my_id:
			flash_own = str(e.get("line", "")) != ""
			flash_text = str(e["line"]) if flash_own else refused_text(int(e["earned"]), int(e["needed"]))
			flash_until = now + FLASH_MS
			refusals += 1
			sfx.play("refused")

## The panel and the line under the prompt for this frame. `q` the host's quota block; `prompt` is the current line shown on the HUD. Returns the line to print under the prompt ("" for none).
func update(q: Variant, lift: Lift, prompt: String, now: int) -> String:
	var base := panel_text(q)
	flashing = now < flash_until and (flash_own or (base != "" and not floor_met(q)))
	text = flash_text if flashing else base
	tone = "refused" if flashing else ("" if base == "" else ("met" if base.begins_with("QUOTA MET") else "count"))
	# The flash blinks: off for a beat every other BLINK_MS.
	var lit := not flashing or ((flash_until - now) / BLINK_MS) % 2 == 0
	if lift != null:
		lift.show_quota(text, tone, lit)
	if flashing or (prompt == CALL_PROMPT and base != ""):
		return text
	return ""

func describe() -> Dictionary:
	return {"text": text, "tone": tone, "flashing": flashing, "lastFlash": flash_text, "refusals": refusals}
