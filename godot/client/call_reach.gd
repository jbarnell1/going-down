# OD1: where the lift's call can be pressed, asked one way by everything on the screen. The host's own question is
# Run._at_call (sim/run.gd): within CALL_REACH of the car's doors on the car's level, or, on the Hanging Ward with its
# call (WC1), within CALL_REACH of the station's button and WARD_CALL_RISE of its height. at_call is that question
# with a slack added to the reach: Run.EPS asks exactly what the host asks (tests/prop_call_odds.gd proves the two
# agree on every floor), and -CLIENT_MARGIN asks it a little inside, so the "press to call" prompt never shows where
# the host would refuse the press (client/play_link.gd _can_call).
# North Star: "Odds are printed before a chance is taken." The HUD's loss-odds rows (client/main.gd _show_day_lock)
# show to a player aboard or at the call, wherever the call is.
extends RefCounted

const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")

## The screen's prompt is asked this far inside the host's reach (metres).
const CLIENT_MARGIN := 0.05
## The Ward's station reaches the screen snapped to a centimetre (sim/ward/state.gd), so the HUD's odds are asked
## this much outside the host's reach: they show everywhere the host would take the press.
const WIRE_SLACK := 0.01

## Whether `b` is at the call button: `spot` is the Ward's station (Vector3, feet) or null for the car's doors.
static func at_call(b: Move.Body, car: Run.CarGeometry, spot: Variant, slack: float) -> bool:
	if spot is Vector3:
		var v: Vector3 = spot
		return M.hypot2(b.x - v.x, b.z - v.z) <= Run.CALL_REACH + slack and absf(b.y - v.y) <= Run.WARD_CALL_RISE
	return M.hypot2(b.x - car.door_x, b.z - car.door_z) <= Run.CALL_REACH + slack and b.level == car.level

## Whether the HUD shows the loss-odds rows: `s` the frame's snapshot (client/play_link.gd step), `latest` the host's
## newest world (its "players" rows say who the host has aboard: on the Ward the car is the Ward's, not the floor
## plan's that the screen's own "aboard" measures), `car` the floor plan's car, `spot` the Ward's station or null.
static func odds_on_hud(s: Dictionary, latest: Variant, car: Run.CarGeometry, spot: Variant) -> bool:
	var me: Dictionary = s.get("me", {})
	if car == null or me.is_empty() or not bool(s.get("playing", false)) or str(me["status"]) != "ok":
		return false
	if bool(me["aboard"]) or host_aboard(latest, str(me.get("id", ""))):
		return true
	var b := Move.Body.make(float(me["x"]), float(me["z"]), int(me["level"]), float(me.get("y", 0.0)))
	return at_call(b, car, spot, Run.EPS + WIRE_SLACK)

## Whether the host's newest world has player `id` aboard.
static func host_aboard(latest: Variant, id: String) -> bool:
	if not latest is Dictionary:
		return false
	for p: Variant in (latest as Dictionary).get("players", []):
		if p is Dictionary and str((p as Dictionary).get("id", "")) == id:
			return bool((p as Dictionary).get("aboard", false))
	return false
