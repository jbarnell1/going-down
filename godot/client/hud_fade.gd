# HUD1 (the screen plan, stage 1; .local/reviews/hud-plan.md principle 2): a line on the glass shows at full when its
# value changes, holds HOLD_MS, then fades out over FADE_MS on a timer (never by distance). It stays at full while it is
# urgent, and while DISPLAY (Tab) is held. Only how visible a line is changes here, never its value: the instrument
# never lies. Pure: no node, no clock of its own; the caller passes the times (ms).
extends RefCounted

const HOLD_MS := 4000
const FADE_MS := 1000

## How visible a line is (0..1): `changed_at_ms` is when its value last changed, `now_ms` the time now.
static func alpha(changed_at_ms: int, now_ms: int, urgent: bool, hold_ms := HOLD_MS) -> float:
	if urgent:
		return 1.0
	var since := now_ms - changed_at_ms
	if since <= hold_ms:
		return 1.0
	return clampf(1.0 - float(since - hold_ms) / float(FADE_MS), 0.0, 1.0)

## Remembers when each named line's value last changed. A value seen for the first time counts as a change (a line
## shows when it first appears, on a floor's arrival).
var _seen := {}

## Records `value` for line `key` at `now_ms` and returns when it last changed.
func changed_at(key: String, value: Variant, now_ms: int) -> int:
	var was: Variant = _seen.get(key)
	if was == null or typeof((was as Array)[0]) != typeof(value) or (was as Array)[0] != value:
		_seen[key] = [value, now_ms]
		return now_ms
	return int((was as Array)[1])

## The line's visibility now: records the value, then alpha(); 1 while `display` (Tab) is held.
func see(key: String, value: Variant, now_ms: int, urgent := false, display := false, hold_ms := HOLD_MS) -> float:
	var at := changed_at(key, value, now_ms)
	if display:
		return 1.0
	return alpha(at, now_ms, urgent, hold_ms)

## Forgets every line (a new run).
func clear() -> void:
	_seen.clear()
