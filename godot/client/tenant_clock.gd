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

## Whether the moment's sound and line belong on this screen: the event is for the floor shown, with no Ward or
## Reactor clock of its own.
static func arrived_here(e: Dictionary, latest: Variant) -> bool:
	if str(e.get("type", "")) != "tenantArrived" or not latest is Dictionary:
		return false
	var w: Dictionary = latest
	return w.get("ward") == null and w.get("reactor") == null and int(e.get("depth", -1)) == int(w.get("depth", -2))
