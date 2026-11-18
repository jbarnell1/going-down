# The player's brightness (client/brightness.gd) and its card (client/brightness_card.gd). Proved here:
#   1. The level is clamped to 0..STEPS (the fairness guard), the default is the middle, and the default
#      leaves the picture exactly as it is.
#   2. A saved value is read back; a player who never chose has nothing saved (the card shows at the start).
#   3. Automated runs (persist = false, as main.gd sets under auto=1) never read or write the file and always
#      play at the default.
#   4. For every setting in range the card's greys keep their order after the change: right < the threshold
#      < left < middle, the left one above the game's black, the middle one plain: so "raise until the left
#      badge is barely there, the right one should stay hidden" is always possible.
#   5. The card: arrows and A / D move it a step and say so, Enter is done and saves.
# The tape's last step (client/tape.gdshader) is the same sum as Brightness.apply; tools/playthrough.mjs
# measures a blackout frame at the lowest, the default and the highest setting.
extends RefCounted

const T = preload("res://tests/t.gd")
const Brightness = preload("res://client/brightness.gd")
const Card = preload("res://client/brightness_card.gd")

const TEST_PATH := "user://test_brightness.cfg"

func _clean() -> void:
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))

func test_clamped_and_default_in_the_middle(t: T) -> void:
	t.eq(Brightness.DEFAULT * 2, Brightness.STEPS, "the default is the middle of the range")
	var b := Brightness.new()
	t.eq(b.level, Brightness.DEFAULT, "a new setting is the default")
	b.set_level(-5)
	t.eq(b.level, 0, "under the range: the bottom")
	b.set_level(99)
	t.eq(b.level, Brightness.STEPS, "over the range: the top")
	t.eq(Brightness.clamp_level(Brightness.STEPS + 1), Brightness.STEPS, "clamp_level keeps the top")
	t.eq(Brightness.clamp_level(-1), 0, "clamp_level keeps the bottom")
	var p := Brightness.params(Brightness.DEFAULT)
	t.check(is_equal_approx(float(p["lift"]), 0.0) and is_equal_approx(float(p["gamma"]), 1.0), "the default changes nothing: %s" % str(p))
	for i in 101:
		var x := i / 100.0
		t.check(is_equal_approx(Brightness.apply(x, Brightness.DEFAULT), x), "the default leaves grey %.2f as it is" % x)
	# The ends of the range: brighter at the top, darker at the bottom, white stays white.
	t.check(Brightness.apply(0.1, Brightness.STEPS) > 0.1 and Brightness.apply(0.1, 0) < 0.1, "the top raises the dark, the bottom lowers it")
	t.check(is_equal_approx(Brightness.apply(1.0, 0), 1.0) and is_equal_approx(Brightness.apply(1.0, Brightness.STEPS), 1.0), "white stays white")

func test_saved_value_read_back(t: T) -> void:
	_clean()
	var b := Brightness.new()
	b.save_path = TEST_PATH
	b.load_saved()
	t.check(not b.saved and b.level == Brightness.DEFAULT, "nothing saved yet: the default, and the card is due")
	b.set_level(14)
	b.save()
	var c := Brightness.new()
	c.save_path = TEST_PATH
	c.load_saved()
	t.eq(c.level, 14, "the saved value read back")
	t.check(c.saved, "a saved choice: the card is not due again")
	# A file someone edited by hand out of range comes back clamped.
	var cf := ConfigFile.new()
	cf.load(TEST_PATH)
	cf.set_value("picture", "brightness", 500)
	cf.save(TEST_PATH)
	c.load_saved()
	t.eq(c.level, Brightness.STEPS, "an out-of-range saved value is clamped")
	_clean()

func test_automated_runs_never_touch_the_file(t: T) -> void:
	_clean()
	var cf := ConfigFile.new()
	cf.set_value("picture", "brightness", 3)
	cf.save(TEST_PATH)
	var before := FileAccess.get_file_as_string(TEST_PATH)
	var b := Brightness.new()
	b.persist = false
	b.save_path = TEST_PATH
	b.load_saved()
	t.eq(b.level, Brightness.DEFAULT, "automated: the default, not the file's 3")
	t.check(not b.saved, "automated: nothing counts as saved")
	b.set_level(17)
	b.save()
	t.eq(FileAccess.get_file_as_string(TEST_PATH), before, "automated: the file is not written")
	_clean()
	b.save()
	t.check(not FileAccess.file_exists(TEST_PATH), "automated: no file is made")
	# The game's own path is the player's settings file; main.gd sets persist = not automated.
	t.eq(Brightness.SAVE_PATH, "user://settings.cfg", "the player's settings file")

func test_badge_greys_ordered_at_every_setting(t: T) -> void:
	t.check(Brightness.BLACK < Brightness.RIGHT and Brightness.RIGHT < Brightness.THRESHOLD and Brightness.THRESHOLD < Brightness.LEFT and Brightness.LEFT < Brightness.MIDDLE,
		"the greys as drawn: black < right < threshold < left < middle")
	for lv in range(0, Brightness.STEPS + 1):
		var bl := Brightness.apply(Brightness.BLACK, lv)
		var r := Brightness.apply(Brightness.RIGHT, lv)
		var th := Brightness.apply(Brightness.THRESHOLD, lv)
		var l := Brightness.apply(Brightness.LEFT, lv)
		var m := Brightness.apply(Brightness.MIDDLE, lv)
		t.check(r < th and th < l and l < m, "setting %d: right %.4f < threshold %.4f < left %.4f < middle %.4f" % [lv, r, th, l, m])
		t.check(l > bl and r >= bl, "setting %d: the left badge %.4f above the black %.4f (right %.4f)" % [lv, l, bl, r])
		t.check(m - bl > 0.2, "setting %d: the middle badge plain to see (%.3f over the black)" % [lv, m - bl])
	# The range does its job: at the top the left badge stands clearly off the black, at the bottom the
	# right one is lost in it.
	t.check(Brightness.apply(Brightness.LEFT, Brightness.STEPS) - Brightness.apply(Brightness.BLACK, Brightness.STEPS) > Brightness.LEFT - Brightness.BLACK,
		"the top widens the gap between the left badge and the black")
	t.check(Brightness.apply(Brightness.RIGHT, 0) - Brightness.apply(Brightness.BLACK, 0) < Brightness.RIGHT - Brightness.BLACK,
		"the bottom narrows the gap between the right badge and the black")

func test_card_keys(t: T) -> void:
	_clean()
	var card := Card.new()
	card.setting.save_path = TEST_PATH
	var heard: Array = []
	var done: Array = []
	card.changed.connect(func(lv: int) -> void: heard.append(lv))
	card.finished.connect(func() -> void: done.append(true))
	card.start()
	t.check(card.is_open(), "start opens the card")
	for code: Key in [KEY_RIGHT, KEY_D, KEY_LEFT, KEY_A, KEY_A]:
		var k := InputEventKey.new()
		k.physical_keycode = code
		k.pressed = true
		card.key(k)
	t.eq(heard, [11, 12, 11, 10, 9], "arrows and A / D move a step each and say so")
	for i in 30:
		card.step(-1)
	t.eq(card.setting.level, 0, "held left stops at the bottom")
	card.step(5)
	var enter := InputEventKey.new()
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	card.key(enter)
	t.check(not card.is_open() and done.size() == 1, "Enter is done")
	var c := Brightness.new()
	c.save_path = TEST_PATH
	c.load_saved()
	t.eq(c.level, 5, "done saves the choice")
	card.free()
	_clean()
