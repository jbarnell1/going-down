# Prints the brightness card's pixels and a few dark-floor pixels at every setting (T27a), from the real
# setting (client/brightness.gd) and the tape filter's own constants (tools/brightness_math.gd, which a test
# keeps word for word with client/tape.gdshader). Headless, no window:
#   "$GODOT" --headless --path godot --script res://tools/brightness_table.gd
# Every value is the 8-bit value the window holds (0..255). "diff" is the largest channel difference.
# Near black a difference of 1 or 2 is lost on a typical screen, 3 is barely there, 4 or more is seen.
extends SceneTree

const Brightness = preload("res://client/brightness.gd")
const M = preload("res://tools/brightness_math.gd")

func _initialize() -> void:
	var missing := M.tape_lines_missing()
	if not missing.is_empty():
		print("tape.gdshader no longer has these lines; the sums here are out of date:")
		for line in missing:
			print("  ", line)
		quit(1)
		return
	print("tape.gdshader: the copied lines match.")
	_card_before()
	_card_after()
	_default_and_top()
	_dark_floor()
	quit(0)

func _px(c: Color) -> String:
	var v := M.q3(c)
	return "%3d %3d %3d" % [v.x, v.y, v.z]

func _grey(g: float) -> Color:
	return Color(g, g, g)

func _card_before() -> void:
	print("\nBEFORE (the card and curve at 2391000). Background (0.065, 0.069, 0.073), left 0.105, middle 0.42, right 0.072.")
	print(" lv | background  | left        | middle      | right       | left-bg | right-bg")
	for lv in range(0, Brightness.STEPS + 1):
		var f := func(c: Color) -> Color: return Color(M.old_apply(c.r, lv), M.old_apply(c.g, lv), M.old_apply(c.b, lv))
		var bg: Color = f.call(M.OLD_BG)
		var l: Color = f.call(_grey(M.OLD_LEFT))
		var m: Color = f.call(_grey(M.OLD_MIDDLE))
		var r: Color = f.call(_grey(M.OLD_RIGHT))
		print(" %2d | %s | %s | %s | %s | %7d | %8d" % [lv, _px(bg), _px(l), _px(m), _px(r), M.diff(M.q3(l), M.q3(bg)), M.diff(M.q3(r), M.q3(bg))])

func _card_after() -> void:
	print("\nAFTER (this branch). Background %.3f, left %.3f, middle %.3f, right %.3f. Black point below the default." % [Brightness.BLACK, Brightness.LEFT, Brightness.MIDDLE, Brightness.RIGHT])
	print(" lv | black pt | background  | left        | middle      | right       | left-bg | step | right-bg")
	var prev := 0.0
	for lv in range(0, Brightness.STEPS + 1):
		var bg := Brightness.apply_color(_grey(Brightness.BLACK), lv)
		var l := Brightness.apply_color(_grey(Brightness.LEFT), lv)
		var m := Brightness.apply_color(_grey(Brightness.MIDDLE), lv)
		var r := Brightness.apply_color(_grey(Brightness.RIGHT), lv)
		var exact := (l.r - bg.r) * 255.0
		print(" %2d | %8.4f | %s | %s | %s | %s | %7d | %4.2f | %8d" % [lv, Brightness.black_point(lv), _px(bg), _px(l), _px(m), _px(r), M.diff(M.q3(l), M.q3(bg)), exact - prev, M.diff(M.q3(r), M.q3(bg))])
		prev = exact
	print(" (step: how many levels, before rounding, the left badge gained over the background since the step below)")

func _default_and_top() -> void:
	var worst_default := 0
	var worst_top := 0
	for i in 256:
		var x := i / 255.0
		worst_default = maxi(worst_default, absi(M.q(Brightness.apply(x, Brightness.DEFAULT)) - i))
		for lv in range(Brightness.DEFAULT, Brightness.STEPS + 1):
			worst_top = maxi(worst_top, absi(M.q(Brightness.apply(x, lv)) - M.q(M.old_apply(x, lv))))
	print("\nThe default against the picture as drawn (all 256 greys): largest change %d levels." % worst_default)
	print("Settings %d..%d against the old curve (all 256 greys): largest change %d levels." % [Brightness.DEFAULT, Brightness.STEPS, worst_top])
	var worst_low := 0
	for i in 256:
		worst_low = maxi(worst_low, absi(M.q(Brightness.apply(i / 255.0, Brightness.DEFAULT - 1)) - i))
	print("One step below the default against the default (all 256 greys): largest change %d levels." % worst_low)

func _dark_floor() -> void:
	var g := M.ARBORETUM_GAIN
	# name, scene colour (before the tape), grain, scanline
	var pixels := [
		["blackout, open ground, grain at its mean", Color.BLACK, 0.0, 0.5],
		["blackout, grain at its brightest", Color.BLACK, 0.5, 0.0],
		["blackout, grain at its darkest", Color.BLACK, -0.5, 1.0],
		["near light: bark 1.5 m ahead (est.)", M.near_lit(0.25, 1.5, 1.0, g), 0.0, 0.5],
		["near light: bark 3 m ahead (est.)", M.near_lit(0.25, 3.0, 1.0, g), 0.0, 0.5],
		["near light: gravel 3 m out (est.)", M.near_lit(0.3, 3.4, 0.47, g), 0.0, 0.5],
		["near light: bark 3.8 m, its edge (est.)", M.near_lit(0.25, 3.8, 1.0, g), 0.0, 0.5],
	]
	var cols := [["old 0", 0, true], ["old 10", 10, true], ["old 20", 20, true], ["new 0", 0, false], ["new 1", 1, false], ["new 3", 3, false], ["new 5", 5, false], ["new 10", 10, false], ["new 20", 20, false]]
	print("\nDARK FLOOR (the Arboretum in a blackout, lights out, the tape on, at the picture's centre).")
	print("Scene colours marked est. are an estimate of the near light (Godot's falloff, filmic, sRGB; bark albedo 0.25, gravel 0.30, eye 1.6 m): a real frame is the check.")
	for p: Array in pixels:
		var c: Color = p[1]
		print("  %s: scene %s" % [p[0], _px(c)])
	var head := "  %-42s" % "pixel"
	for col: Array in cols:
		head += " | %-11s" % col[0]
	print(head)
	for p: Array in pixels:
		var line := "  %-42s" % p[0]
		for col: Array in cols:
			var fn: Callable = M.old_apply if col[2] else Brightness.apply
			var out := M.tape(p[1], 1.0, col[1], p[2], p[3], 0.0, 1.0, fn)
			line += " | %s" % _px(out)
		print(line)
	var line2 := "  %-42s" % "near light 3 m bark over the blackout (diff)"
	for col: Array in cols:
		var fn: Callable = M.old_apply if col[2] else Brightness.apply
		var black := M.q3(M.tape(Color.BLACK, 1.0, col[1], 0.0, 0.5, 0.0, 1.0, fn))
		var bark := M.q3(M.tape(pixels[4][1], 1.0, col[1], 0.0, 0.5, 0.0, 1.0, fn))
		line2 += " | %-11d" % M.diff(bark, black)
	print(line2)
