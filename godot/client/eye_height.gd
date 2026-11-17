# How high a player's eyes are above their feet: the one place that decides it (North Star B12 "the
# camera drops when you creep and when you are down"). The same number places the camera, goes to the
# rules as the eye of what counts as looking (net/client.gd LocalFrame.eye), and says where another
# player's head is drawn (main.gd name tags; crew_view.gd's clips put the mask at these heights).
#
#   STAND  1.65  the mask of the standing crewmate figure is at 1.62-1.63 (idle clip).
#   CREEP  1.13  the mask of the figure's sneak clip, which others see while you creep, measured at
#                1.10-1.17 (mean 1.13), so the eye the rules use is where your crewmates see your head;
#                about knee-and-a-half high: you see over a desk or a bed, not over a counter's top shelf.
#   DOWN   0.45  near the floor: the downed figure crawls with its mask at 0.45-0.60 and lies at 0.25.
#
# The camera eases between heights over EASE_TIME (smoothstep, no snap). Every value it passes through
# is a whole centimetre, because the input carries the eye to the centimetre (protocol.gd q2): the eye
# the host receives is then exactly the eye the screen was drawn from and the client judged sight with.
extends RefCounted

const Pose = preload("res://net/pose.gd")

const STAND := 1.65
const CREEP := 1.13
const DOWN := 0.45
## Seconds to move from one height to another (whatever the distance).
const EASE_TIME := 0.2

## The height the eyes settle at for a player's status ("ok", "caught", later "down") and gait
## ("walk", "creep", "sprint"). Being down (today: caught) wins over the gait.
static func target(status: String, gait: String) -> float:
	if status == "caught" or status == "down":
		return DOWN
	if gait == "creep":
		return CREEP
	return STAND

## To the whole centimetre, exactly as the protocol sends it.
static func to_cm(x: float) -> float:
	return Pose.q2(x)

var eye := STAND
var _from := STAND
var _to := STAND
var _k := 1.0

## Back to standing at once (a new run).
func reset(h: float = STAND) -> void:
	eye = to_cm(h)
	_from = eye
	_to = eye
	_k = 1.0

## One frame of `dt` seconds toward `want`; returns the eye height for this frame (whole centimetres).
func update(want: float, dt: float) -> float:
	if want != _to:
		_from = eye
		_to = want
		_k = 0.0
	if _k < 1.0:
		_k = minf(1.0, _k + maxf(dt, 0.0) / EASE_TIME)
	var s := _k * _k * (3.0 - 2.0 * _k)
	eye = to_cm(_from + (_to - _from) * s) if _k < 1.0 else to_cm(_to)
	return eye
