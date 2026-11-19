# The brightness card can be set right (T27a; owner, 18 Nov: "You can see brightness on both extremes.
# (badge on left)"). In 8-bit, the window's own values, round(v * 255). Near black a difference of 1 or 2
# is lost on a typical screen, 3 is barely there, 4 or more is seen. Proved here:
#   1. At the bottom the left badge is exactly the background (difference 0), and so is the right one.
#   2. Raising it, the left badge appears in small steps: the first step it shows at is 2 or 3 over the
#      background, and below the default no step adds more than 3.
#   3. At that first step the right badge is still exactly the background, and it stays lost (at most 1)
#      for several steps more.
#   4. The default is the picture as drawn (every grey within 1 level), and from the default up the curve
#      is the one players already had (within 1 level).
#   5. A value saved on the first card keeps its number but the card is due again; a value saved now is not.
#   6. Nothing about brightness reaches the host: no rule, network or server script, and not the night's
#      log, mentions it; the setting's own scripts use nothing of the network's; the card is drawn over the
#      picture, not into anything sent.
#   7. The tape's last step is still the sum Brightness.apply copies (a negative lift is a black point only
#      because the shader clamps after it), and the dark-floor sums still match the shader.
#   8. A dark floor: at the bottom the game's black is near true black but the grain and what the near
#      light shows at 3 m still stand off it; at the top the blackout is no brighter than before.
extends RefCounted

const T = preload("res://tests/t.gd")
const Brightness = preload("res://client/brightness.gd")
const M = preload("res://tools/brightness_math.gd")

const TEST_PATH := "user://test_brightness_curve.cfg"
## A difference a typical screen shows near black.
const SEEN := 2
## The most one step below the default may add to the left badge.
const MAX_STEP := 3.0

func _clean() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))

func _px(g: float, lv: int) -> Vector3i:
	return M.q3(Brightness.apply_color(Color(g, g, g), lv))

func _left_over(lv: int) -> int:
	return M.diff(_px(Brightness.LEFT, lv), _px(Brightness.BLACK, lv))

func _right_over(lv: int) -> int:
	return M.diff(_px(Brightness.RIGHT, lv), _px(Brightness.BLACK, lv))

## The first setting at which the left badge shows.
func _first_seen() -> int:
	for lv in range(0, Brightness.STEPS + 1):
		if _left_over(lv) >= SEEN:
			return lv
	return -1

func test_left_badge_gone_at_the_bottom(t: T) -> void:
	t.eq(_left_over(0), 0, "at the bottom the left badge is the background, 8-bit for 8-bit")
	t.eq(_right_over(0), 0, "at the bottom the right badge is the background")
	t.check(M.diff(_px(Brightness.MIDDLE, 0), _px(Brightness.BLACK, 0)) > 60, "at the bottom the middle badge is still plain")

func test_left_badge_appears_in_small_steps(t: T) -> void:
	var first := _first_seen()
	t.check(first >= 1 and first <= 3, "the left badge first shows a step or few up from the bottom (at %d)" % first)
	if first < 0:
		return
	t.check(_left_over(first) >= 2 and _left_over(first) <= 3, "where it first shows it is barely there: %d levels over the background" % _left_over(first))
	t.check(_left_over(first - 1) <= 1, "a step lower it is lost (%d)" % _left_over(first - 1))
	var prev := 0.0
	for lv in range(0, Brightness.DEFAULT + 1):
		var over := (Brightness.apply(Brightness.LEFT, lv) - Brightness.apply(Brightness.BLACK, lv)) * 255.0
		t.check(over - prev <= MAX_STEP, "setting %d adds %.2f levels to the left badge (at most %.0f)" % [lv, over - prev, MAX_STEP])
		t.check(over >= prev, "setting %d never takes the left badge back (%.2f after %.2f)" % [lv, over, prev])
		if lv > 0:
			t.check(_left_over(lv) - _left_over(lv - 1) <= int(MAX_STEP), "setting %d: in 8-bit the left badge gains %d" % [lv, _left_over(lv) - _left_over(lv - 1)])
		prev = over

func test_right_badge_hidden_where_left_appears(t: T) -> void:
	var first := _first_seen()
	t.eq(_right_over(first), 0, "at the step the left badge shows (%d), the right one is the background" % first)
	for lv in range(0, first + 5):
		t.check(_right_over(lv) <= 1, "setting %d: the right badge still lost (%d)" % [lv, _right_over(lv)])
	t.check(_right_over(Brightness.STEPS) >= 4, "at the top even the right badge shows (%d): the range reaches a dim screen" % _right_over(Brightness.STEPS))

func test_default_and_top_unchanged(t: T) -> void:
	for i in 256:
		var x := i / 255.0
		t.check(absi(M.q(Brightness.apply(x, Brightness.DEFAULT)) - i) <= 1, "the default leaves grey %d as it is" % i)
		for lv in range(Brightness.DEFAULT, Brightness.STEPS + 1):
			var now := M.q(Brightness.apply(x, lv))
			var was := M.q(M.old_apply(x, lv))
			if absi(now - was) > 1:
				t.check(false, "setting %d grey %d: %d now, %d before" % [lv, i, now, was])
	t.check(Brightness.apply(Brightness.GAME_BLACK, Brightness.STEPS) > 0.12, "the top still lifts the game's black for a dim screen")

func test_old_saves_keep_their_number_and_ask_again(t: T) -> void:
	_clean()
	var cf := ConfigFile.new()
	cf.set_value("picture", "brightness", 4)   # as the first card saved it: no curve
	cf.save(TEST_PATH)
	var b := Brightness.new()
	b.save_path = TEST_PATH
	b.load_saved()
	t.eq(b.level, 4, "a value from the first card keeps its number")
	t.check(not b.saved, "a value from the first card: the card is due again")
	b.save()
	var c := Brightness.new()
	c.save_path = TEST_PATH
	c.load_saved()
	t.check(c.saved and c.level == 4, "chosen again on this card: kept, and the card is not due")
	var back := ConfigFile.new()
	back.load(TEST_PATH)
	t.eq(int(back.get_value("picture", "brightness_curve", 0)), Brightness.CURVE, "the file says which curve the value was chosen on")
	_clean()

## Every .gd file under a res:// folder.
func _scripts(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)

func test_nothing_reaches_the_host(t: T) -> void:
	var mention := RegEx.create_from_string("(?i)brightness|bright_(lift|gamma|card)|settings\\.cfg")
	var files: Array[String] = []
	for dir: String in ["res://net", "res://server", "res://sim"]:
		_scripts(dir, files)
	files.append("res://client/telemetry.gd")
	t.check(files.size() > 20, "the rule, network and server scripts were found (%d)" % files.size())
	for f in files:
		var m := mention.search(FileAccess.get_file_as_string(f))
		t.check(m == null, "%s never mentions the brightness%s" % [f, "" if m == null else " (it says '%s')" % m.get_string()])
	var reach := RegEx.create_from_string("res://(net|server|sim)/|(?i)telemetry|room")
	for f: String in ["res://client/brightness.gd", "res://client/brightness_card.gd"]:
		var m := reach.search(FileAccess.get_file_as_string(f))
		t.check(m == null, "%s uses nothing of the network's%s" % [f, "" if m == null else " (it says '%s')" % m.get_string()])
	# main.gd: no line that touches the setting also touches the room, the client or the night's log.
	var sends := RegEx.create_from_string("(?i)\\b(room|rc|client|telemetry|net)\\.|send")
	var n := 0
	for line in FileAccess.get_file_as_string("res://client/main.gd").split("\n"):
		if mention.search(line) != null:
			n += 1
			t.check(sends.search(line) == null, "main.gd keeps the brightness to this screen: %s" % line.strip_edges())
	t.check(n > 5, "main.gd's brightness lines were found (%d)" % n)

func test_shader_still_matches(t: T) -> void:
	var missing := M.tape_lines_missing()
	t.check(missing.is_empty(), "tape.gdshader still has the lines the brightness sums copy; missing: %s" % str(missing))

func test_dark_floor(t: T) -> void:
	# The Arboretum in a blackout at the picture's centre, the tape on (tools/brightness_table.gd prints all).
	var black := func(lv: int, grain: float) -> Vector3i: return M.q3(M.tape(Color.BLACK, 1.0, lv, grain, 0.5))
	var bark := M.near_lit(0.25, 3.0, 1.0, M.ARBORETUM_GAIN)
	var bottom := black.call(0, 0.0) as Vector3i
	t.check(maxi(bottom.x, maxi(bottom.y, bottom.z)) <= 4, "at the bottom the blackout is near true black %s" % str(bottom))
	t.check(M.diff(black.call(0, 0.5), bottom) >= 8, "at the bottom the tape's grain still sparkles in the dark (%d)" % M.diff(black.call(0, 0.5), bottom))
	t.check(M.diff(M.q3(M.tape(bark, 1.0, 0, 0.0, 0.5)), bottom) >= 20, "at the bottom bark 3 m away in the near light still stands off the black (estimate)")
	var top := black.call(Brightness.STEPS, 0.0) as Vector3i
	var old_top := M.q3(M.tape(Color.BLACK, 1.0, Brightness.STEPS, 0.0, 0.5, 0.0, 1.0, M.old_apply))
	t.check(M.diff(top, old_top) <= 1, "at the top the blackout is as dark as it was (%s, was %s)" % [str(top), str(old_top)])
	t.check(top.x <= 45, "at the top the blackout is still dark: %s out of 255" % str(top))
