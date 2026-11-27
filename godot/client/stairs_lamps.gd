# HU2 (the screen plan, stage 2; the owner's yes of 21 Nov to question 3, "Can the Tenant get a lamp row by the lift
# ("STAIRS"), lit floor by floor, in stage 2?"): a row of LAMPS lamps over the landing doors, above the car's own
# indicator (North Star C5 keeps that one for the car), under a small STAIRS plate. It is the Tenant's clock (A4: "Let's
# just make a Timer") put into the world, as an old lift's floor lamps:
#   - the doors open: the first lamp is lit; one more lamp lights each tenth of the clock, so the last is lit through
#     the last tenth (on the ten-minute clock, one lamp a minute; the last minute is the last lamp);
#   - the last minute (TenantClock.WARN_SECONDS): the lit lamps turn red, as the screen line does;
#   - the Tenant here (the clock at zero): every lamp red, blinking, for the rest of the floor;
#   - no clock (the prison, Practice, a ride, the Ward's and the Reactor's own clocks): the row is not there.
# Everything is the host's: the newest snapshot's "tenant" block against its own host time (TenantClock.left_of), so
# every screen lights the same lamp at the same tick. Nothing is predicted and nothing names a rule.
extends Node3D

const TenantClock = preload("res://client/tenant_clock.gd")

const LAMPS := 10
## The picture: the plate's word over the lamps, each LAMP_PX square with a LAMP_GAP between, in texels.
const LAMP_PX := 6
const LAMP_GAP := 2
const PX := Vector2i(LAMPS * (LAMP_PX + LAMP_GAP) + 2, 19)
## Its size on the wall (m).
const SIZE := Vector2(1.1, 1.1 * 19.0 / (LAMPS * (LAMP_PX + LAMP_GAP) + 2))
const WORD := "STAIRS"
const BG := Color("#0b0605")
const OFF := Color("#2a0f06")
const ON := Color("#ffb02a")
const WARN := Color("#ff4a2a")
const WORD_INK := Color("#d8d2c0")
const BLINK_S := 0.5

## How many lamps are lit with `left` seconds of a clock of `length`: 1 at the doors, LAMPS in the last tenth and
## after; 0 for no clock.
static func lit_of(left: float, length: float) -> int:
	if length <= 0.0:
		return 0
	if left <= 1e-6:
		return LAMPS
	var gone := clampf(length - left, 0.0, length)
	return clampi(floori(gone / length * LAMPS + 1e-6) + 1, 1, LAMPS)

## The row's state for `latest` (the client's newest decoded world): {on (a clock), lit, warn (the last minute), here
## (the Tenant has arrived), left (seconds, or -1)}.
static func state_of(latest: Variant) -> Dictionary:
	var left: Variant = TenantClock.left_of(latest)
	if left == null:
		return {"on": false, "lit": 0, "warn": false, "here": false, "left": -1.0}
	var l := float(left)
	var length := float(((latest as Dictionary)["tenant"] as Dictionary).get("len", 600.0))
	return {"on": true, "lit": lit_of(l, length), "warn": TenantClock.warn(l), "here": l <= 1e-6, "left": l}

var state := {"on": false, "lit": 0, "warn": false, "here": false, "left": -1.0}
var _img: Image
var _tex: ImageTexture
var _key := "-"
var _t := 0.0

func _init() -> void:
	name = "StairsLamps"
	_img = Image.create(PX.x, PX.y, false, Image.FORMAT_RGBA8)
	_img.fill(BG)
	_tex = ImageTexture.create_from_image(_img)
	var back := MeshInstance3D.new()
	back.name = "StairsPlate"
	var b := BoxMesh.new()
	b.size = Vector3(SIZE.x + 0.08, SIZE.y + 0.06, 0.02)
	back.mesh = b
	back.material_override = Level.prop_material(Color(0.19, 0.21, 0.23))
	back.position = Vector3(0, 0, -0.015)
	add_child(back)
	var q := QuadMesh.new()
	q.size = SIZE
	var face := MeshInstance3D.new()
	face.name = "StairsFace"
	face.mesh = q
	face.material_override = Level.glow_material(Color.WHITE, 1.0, _tex)
	add_child(face)
	visible = false
	_paint()

## One frame: the row for `latest`.
func show_for(latest: Variant) -> void:
	state = state_of(latest)
	visible = bool(state["on"])

func _process(dt: float) -> void:
	_t += dt
	if visible:
		_paint()

## Redraws the picture when what it shows changes (the blink once the Tenant is here).
func _paint() -> void:
	if _img == null:
		return
	var blink_on := not bool(state["here"]) or fmod(_t, BLINK_S * 2.0) < BLINK_S
	var key := "%d|%s|%s|%s" % [int(state["lit"]), state["warn"], state["here"], blink_on]
	if key == _key:
		return
	_key = key
	_img.fill(BG)
	PixelFont.blit(_img, WORD, Vector2i(floori((PX.x - PixelFont.width(WORD)) / 2.0), 1), WORD_INK)
	var lit := int(state["lit"])
	var col := WARN if bool(state["warn"]) else ON
	for i in LAMPS:
		var c := OFF
		if i < lit and blink_on:
			c = col
		var x := 1 + i * (LAMP_PX + LAMP_GAP) + LAMP_GAP / 2
		_img.fill_rect(Rect2i(x, 10, LAMP_PX, LAMP_PX), c)
	_tex.update(_img)
