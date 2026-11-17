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
extends RefCounted

const FLASH_MS := 1600
const BLINK_MS := 160

## What the panel says now, as one line ("" for no panel), and its tone: "count", "met" or "refused".
var text := ""
var tone := ""
## The refusal being flashed: its words and until when (msec).
var flash_text := ""
var flash_until := -1
var flashing := false
## Tests: how many refusals this screen showed.
var refusals := 0

## The panel's words for the host's quota block `q` ({earned, needed} or null): "" when there is none.
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
	flash_until = -1
	flashing = false

## This frame's events: a refusal of this player's own press buzzes and starts the flash.
func on_events(events: Array, my_id: String, sfx: Sfx, now: int) -> void:
	for e: Dictionary in events:
		if str(e["type"]) == "callRefused" and str(e.get("playerId", "")) == my_id:
			flash_text = refused_text(int(e["earned"]), int(e["needed"]))
			flash_until = now + FLASH_MS
			refusals += 1
			sfx.play("refused")

## The panel and the line under the prompt for this frame. `q` the host's quota block; `in_reach` the
## player can press the call button. Returns the line to print under the prompt ("" for none).
func update(q: Variant, lift: Lift, in_reach: bool, now: int) -> String:
	var base := panel_text(q)
	flashing = now < flash_until and base != ""
	text = flash_text if flashing else base
	tone = "refused" if flashing else ("" if base == "" else ("met" if base.begins_with("QUOTA MET") else "count"))
	# The flash blinks: off for a beat every other BLINK_MS.
	var lit := not flashing or ((flash_until - now) / BLINK_MS) % 2 == 0
	if lift != null:
		lift.show_quota(text, tone, lit)
	if flashing or (in_reach and base != ""):
		return text
	return ""

func describe() -> Dictionary:
	return {"text": text, "tone": tone, "flashing": flashing, "lastFlash": flash_text, "refusals": refusals}
