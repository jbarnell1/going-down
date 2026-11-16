# The instrument in the player's hand, drawn into the 480x270 picture (so the tape look lies over it):
# an olive field recorder with a needle meter, a cassette window and a lamp, raised while held. It
# shows the rules' needle state only by how the needle behaves (src/render/instrumentView.ts):
#   idle       the needle lies dead still on its left peg, lamp dark;
#   dormant    it twitches just off the peg, harder the closer something is;
#   recording  it swings and climbs toward the red as the reading grows, kicking on every tick;
#   contaminated (reserved by the rules, never produced yet) it would shake in the red.
# The only words it shows are on the paper slip it prints, once per run.
class_name InstrumentView
extends Control

const NEEDLE_REST := -47.0
const NEEDLE_FULL := 47.0
const NEEDLE_K := 260.0
const NEEDLE_ZETA := 0.42
const CLIMB_SCALE := 120.0
const SWING_MIN := 2.0
const SWING_MAX := 7.0
const TICK_KICK := 9.0
const SLIP_PRINT := 1.1
const SLIP_HOLD := 5.5
const SLIP_FALL := 0.6

var raise := 0.0
var angle := NEEDLE_REST
var ang_vel := 0.0
var needle := "off"
var lamp := 0.0
var reel := 0.0
var slip_text := ""
var slip_at := -1.0
var _time := 0.0
var _twitch_in := 0.0
var _twitch := 0.0
var _sway := 0.0
var _walk := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rng.randomize()

func print_slip(text: String) -> void:
	slip_text = text
	slip_at = _time

func slip_shown() -> bool:
	return slip_at >= 0.0 and _time - slip_at < SLIP_PRINT + SLIP_HOLD

func update_view(delta: float, raised: bool, n: String, value: float, distance: Variant, tick_hz: float, ticks: int, walk_speed: float) -> void:
	_time += delta
	needle = n
	var want := 1.0 if raised else 0.0
	var tau := 0.09 if want > raise else 0.14
	raise += (want - raise) * (1.0 - exp(-delta / tau))
	if absf(want - raise) < 0.002:
		raise = want
	_walk = walk_speed
	_sway += delta * (4.0 + walk_speed * 2.4)
	var target := NEEDLE_REST
	var kick := 0.0
	if n == "recording":
		var k := 1.0 - exp(-value / CLIMB_SCALE)
		var swing := SWING_MIN + (SWING_MAX - SWING_MIN) * k
		target = NEEDLE_REST + 6.0 + (NEEDLE_FULL - NEEDLE_REST - 10.0) * k + sin(_time * PI * maxf(2.0, tick_hz * 0.5)) * swing
		kick = ticks * TICK_KICK
		reel -= delta * 1.2 * maxf(3.0, tick_hz)
	elif n == "contaminated":
		target = NEEDLE_FULL - 4.0 + _rng.randf_range(-6.0, 6.0)
	elif n == "dormant":
		_twitch_in -= delta
		if _twitch_in <= 0.0:
			var near := 0.0 if distance == null else clampf(1.0 - float(distance) / 16.0, 0.0, 1.0)
			var amp := lerpf(2.0, 9.0, near)
			_twitch = 4.0 + _rng.randf_range(-1.0, 1.0) * amp
			_twitch_in = _rng.randf_range(0.25, 0.55) if _rng.randf() < 0.2 else _rng.randf_range(0.05, 0.15)
		target = NEEDLE_REST + maxf(0.0, _twitch)
	var left := delta
	while left > 1e-6:
		var h := minf(1.0 / 30.0, left)
		left -= h
		var acc := NEEDLE_K * (target - angle) - 2.0 * NEEDLE_ZETA * sqrt(NEEDLE_K) * ang_vel
		ang_vel += acc * h
		angle += ang_vel * h
	ang_vel += kick * 30.0
	if angle < NEEDLE_REST:
		angle = NEEDLE_REST
		if ang_vel < 0.0:
			ang_vel *= -0.25
	if angle > NEEDLE_FULL + 3.0:
		angle = NEEDLE_FULL + 3.0
		if ang_vel > 0.0:
			ang_vel *= -0.25
	if n == "recording":
		lamp = 1.0 if ticks > 0 else 0.75
	elif n == "dormant":
		lamp = 0.12 + 0.12 * _rng.randf()
	else:
		lamp = 0.0
	queue_redraw()

func _draw() -> void:
	if raise <= 0.002 and not slip_shown():
		return
	var e := 1.0 - pow(1.0 - raise, 3.0)
	var bob := minf(1.0, _walk / 3.0)
	var base := Vector2(330, 160)
	var down := Vector2(330, 290)
	var o := down.lerp(base, e) + Vector2(sin(_sway) * 2.0 * bob, absf(cos(_sway)) * 3.0 * bob)
	o = o.round()
	# The slip, rising from the slot on top.
	if slip_at >= 0.0:
		var age := _time - slip_at
		if age < SLIP_PRINT + SLIP_HOLD + SLIP_FALL:
			var parts := slip_text.split(": ", false)
			var rows: Array[String] = []
			if parts.size() == 2:
				rows = [parts[0] + ":", parts[1]]
			else:
				rows = [slip_text]
			var sw := 116.0
			var sh := 8.0 + rows.size() * 9.0
			var up := clampf(age / SLIP_PRINT, 0.0, 1.0) * sh
			var fall := clampf((age - SLIP_PRINT - SLIP_HOLD) / SLIP_FALL, 0.0, 1.0)
			var sp := o + Vector2(2, -up + fall * 40.0)
			draw_set_transform(sp + Vector2(sw * 0.5, sh), -0.05, Vector2.ONE)
			draw_rect(Rect2(-sw * 0.5, -sh, sw, sh), Color(0.85, 0.84, 0.79))
			for i in rows.size():
				PixelFont.draw(self, rows[i], Vector2(-sw * 0.5 + 4, -sh + 4 + i * 9), 1.0, Color(0.16, 0.15, 0.13))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if raise <= 0.002:
		return
	# The case.
	var body := Rect2(o, Vector2(120, 104))
	draw_rect(body.grow(1), Color(0.07, 0.08, 0.06))
	draw_rect(body, Color(0.33, 0.36, 0.25))
	draw_rect(Rect2(o, Vector2(120, 4)), Color(0.42, 0.45, 0.32))
	draw_rect(Rect2(o + Vector2(10, 1), Vector2(100, 2)), Color(0.1, 0.1, 0.09))  # the slot
	# The meter window.
	var win := Rect2(o + Vector2(10, 10), Vector2(100, 46))
	draw_rect(win.grow(2), Color(0.12, 0.12, 0.1))
	draw_rect(win, Color(0.86, 0.83, 0.68))
	var pivot := o + Vector2(60, 60)
	var r := 40.0
	for i in 11:
		var deg := lerpf(NEEDLE_REST, NEEDLE_FULL, i / 10.0)
		var a := deg_to_rad(deg)
		var dir := Vector2(sin(a), -cos(a))
		var col := Color(0.77, 0.16, 0.12) if deg > 20.0 else Color(0.11, 0.11, 0.09)
		draw_line(pivot + dir * (r - (5.0 if i % 5 == 0 else 3.0)), pivot + dir * r, col, 1.0)
	draw_arc(pivot, r, deg_to_rad(20.0 - 90.0), deg_to_rad(NEEDLE_FULL - 90.0), 8, Color(0.77, 0.16, 0.12), 2.0)
	var na := deg_to_rad(angle)
	draw_line(pivot, pivot + Vector2(sin(na), -cos(na)) * (r + 1.0), Color(0.08, 0.07, 0.06), 1.0)
	draw_rect(Rect2(pivot - Vector2(4, 6), Vector2(8, 6)), Color(0.12, 0.12, 0.1))
	# The lamp.
	var lc := Color(0.23 + lamp * 0.75, 0.05 + lamp * 0.12, 0.04 + lamp * 0.06)
	draw_rect(Rect2(o + Vector2(104, 62), Vector2(8, 6)), lc)
	# The cassette window with its two reels.
	var cw := Rect2(o + Vector2(16, 66), Vector2(80, 30))
	draw_rect(cw.grow(1), Color(0.1, 0.1, 0.09))
	draw_rect(cw, Color(0.16, 0.15, 0.14))
	for i in 2:
		var c := o + Vector2(36 + i * 40, 81)
		draw_circle(c, 9.0, Color(0.72, 0.7, 0.66))
		draw_circle(c, 3.0, Color(0.12, 0.12, 0.1))
		for s in 3:
			var sa := reel * (1.0 if i == 0 else 1.25) + s * TAU / 3.0
			draw_line(c + Vector2(cos(sa), sin(sa)) * 3.0, c + Vector2(cos(sa), sin(sa)) * 8.0, Color(0.2, 0.2, 0.18), 2.0)
