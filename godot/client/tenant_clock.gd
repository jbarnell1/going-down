# The Tenant clock on screen (TT1; net/host_rules.gd tenant_timer). Everything is the host's: the "tenant" block of
# the newest snapshot ({at, len}: the host time the Tenant arrives and the clock's length) against that snapshot's
# own host time "ht", so every screen shows the same second as the host at the same tick, and a late joiner's
# welcome carries it. Nothing is predicted here.
#  - One line, top right under the quota lines (client/hud.gd tenant_line): "TENANT ARRIVES IN 09:59", the warning
#    colour in the last minute, then "THE TENANT IS HERE" for the rest of the floor.
#  - None while there is no clock: the flag off, the prison, Practice, a ride, and on a floor with the Ward's or the
#    Reactor's own clock (a "ward" or "reactor" block).
#  - At zero ("tenantArrived", once a floor): a door slams for everyone (client/main.gd, Sfx "tenant_slam", the
#    Scare bus, not in the world), and about a second later the announcer's line (client/announcer.gd).
extends RefCounted

## The last minute is shown in the warning colour.
const WARN_SECONDS := 60.0
const HERE := "THE TENANT IS HERE"

## Seconds left on this floor's clock in `latest` (the client's newest decoded world), or null for no clock.
static func left_of(latest: Variant) -> Variant:
	if not latest is Dictionary:
		return null
	var w: Dictionary = latest
	if not w.get("tenant") is Dictionary or w.get("ward") != null or w.get("reactor") != null:
		return null
	if str(w.get("phase", "")) in ["riding", "ended"]:
		return null
	return float(w["tenant"]["at"]) - float(w.get("ht", 0.0))

## The line for `left` seconds: whole seconds rounded up, so 09:59 shows for the second after 10:00, and 00:01
## until the clock is at zero.
static func text(left: float) -> String:
	if left <= 1e-6:
		return HERE
	var s := ceili(left - 1e-6)
	return "TENANT ARRIVES IN %02d:%02d" % [s / 60, s % 60]

## Whether the line is in the warning colour: the last minute and after.
static func warn(left: float) -> bool:
	return left <= WARN_SECONDS + 1e-6

## The HUD's line and colour for `latest`: {text, warn}, the text "" for none.
static func line(latest: Variant) -> Dictionary:
	var left: Variant = left_of(latest)
	if left == null:
		return {"text": "", "warn": false}
	return {"text": text(float(left)), "warn": warn(float(left))}

## HUD1 (the owner, 21 Nov: the clock is not always on the glass; voices announce it): the moments the line shows
## and the voice speaks, all from the host's clock, so every screen does it at the same second.
##  - "tenant_doors": the clock first seen on a floor (the doors open), shown ARRIVAL_SHOW_S;
##  - "tenant_five" at 5:00 and "tenant_two" at 2:00, shown BEAT_SHOW_S each;
##  - "tenant_one" at 1:00, then shown through the whole last minute, and HERE_SHOW_S after the Tenant arrives.
## Tab (DISPLAY) shows it at any time (client/hud.gd).
const ARRIVAL_SHOW_S := 8.0
const BEAT_SHOW_S := 6.0
const HERE_SHOW_S := 6.0
const BEATS := {"tenant_five": 300.0, "tenant_two": 120.0, "tenant_one": 60.0}

## Whether the line belongs on the glass with `left` seconds to go, the clock having had `opened_left` when this
## screen first saw it on this floor.
static func shown(left: float, opened_left: float) -> bool:
	if left <= WARN_SECONDS + 1e-6:
		return left > -HERE_SHOW_S
	if opened_left - left < ARRIVAL_SHOW_S:
		return true
	for b: float in [300.0, 120.0]:
		if left <= b + 1e-6 and left > b - BEAT_SHOW_S:
			return true
	return false

## The voice's moment crossed between two frames (`prev_left` then `left`), or "" for none.
static func beat_crossed(prev_left: float, left: float) -> String:
	for m: String in BEATS:
		var b: float = BEATS[m]
		if prev_left > b + 1e-6 and left <= b + 1e-6:
			return m
	return ""

## Per screen: the clock's left when first seen on this floor, and last frame's left.
var opened_left := NAN
var prev_left := NAN
var _depth := -1

## One frame: {show (the line on the glass), moment (the voice's moment to say now, "" none), left (seconds, or null)}.
## A late joiner first seeing the clock past its opening hears no "doors" line (only within ARRIVAL_SHOW_S of full).
func step(latest: Variant) -> Dictionary:
	var left: Variant = left_of(latest)
	if left == null:
		opened_left = NAN
		prev_left = NAN
		_depth = -1
		return {"show": false, "moment": "", "left": null}
	var l := float(left)
	var depth := int((latest as Dictionary).get("depth", -1))
	var moment := ""
	if is_nan(opened_left) or depth != _depth:
		opened_left = l
		_depth = depth
		var full := float(((latest as Dictionary)["tenant"] as Dictionary).get("len", l))
		if full - l < ARRIVAL_SHOW_S and l > 300.0 + BEAT_SHOW_S:
			moment = "tenant_doors"
	elif not is_nan(prev_left):
		moment = beat_crossed(prev_left, l)
	prev_left = l
	return {"show": shown(l, opened_left), "moment": moment, "left": l}

## Whether the moment's sound and line belong on this screen: the event is for the floor shown, with no Ward or
## Reactor clock of its own.
static func arrived_here(e: Dictionary, latest: Variant) -> bool:
	if str(e.get("type", "")) != "tenantArrived" or not latest is Dictionary:
		return false
	var w: Dictionary = latest
	return w.get("ward") == null and w.get("reactor") == null and int(e.get("depth", -1)) == int(w.get("depth", -2))
