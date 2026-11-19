extends RefCounted

const Seek = preload("res://sim/seek.gd")
const Settings = preload("res://sim/settings.gd")
const Move = preload("res://sim/move.gd")

const CHARGE := 60.0
const REACH := 12.0
const HALF_DEG := 24.0

static func new_charge(tuning: Settings.Values) -> float:
	return Settings.f(tuning, &"lamp.seconds", CHARGE)

static func beam(tuning: Settings.Values, body: Move.Body, eye: float, yaw: float, pitch: float) -> Seek.Light:
	return Seek.Light.make(body.x, body.y + eye, body.z, body.level, yaw, pitch, HALF_DEG,
		Settings.f(tuning, &"lamp.range", REACH))
