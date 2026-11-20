# FD1: the one switch (client/figures.gd) that picks which resident figures every view draws. The new figures are
# the default; `figures=old` (or `--figures=old` after `--`, or `?figures=old` in the web address) is the way back,
# and `figures=new` still means new. Tests can force either through Figures.override.
extends RefCounted

const T = preload("res://tests/t.gd")

func test_the_arguments_pick_the_figures(t: T) -> void:
	var none := PackedStringArray()
	t.check(Figures.new_for(none, ""), "nothing: the new figures")
	t.check(not Figures.new_for(PackedStringArray(["figures=old"]), ""), "figures=old: the old figures")
	t.check(not Figures.new_for(PackedStringArray(["--figures=old"]), ""), "--figures=old: the old figures")
	t.check(not Figures.new_for(PackedStringArray(["x", "figures=old"]), ""), "figures=old among other arguments")
	t.check(Figures.new_for(PackedStringArray(["figures=new"]), ""), "figures=new: the new figures")
	t.check(Figures.new_for(PackedStringArray(["--figures=new"]), ""), "--figures=new: the new figures")
	t.check(Figures.new_for(PackedStringArray(["--port=4820"]), ""), "an unrelated argument: the new figures")
	t.check(Figures.new_for(PackedStringArray(["figures=older"]), ""), "only the exact argument counts")
	t.check(not Figures.new_for(none, "?figures=old"), "?figures=old in the address: the old figures")
	t.check(not Figures.new_for(none, "?room=a&figures=old"), "figures=old among other query fields")
	t.check(Figures.new_for(none, "?figures=new"), "?figures=new in the address: the new figures")
	t.check(Figures.new_for(none, "?room=a"), "an unrelated query field: the new figures")
	t.check(Figures.new_for(none, "?figures=older"), "only the exact query field counts")

func test_the_override_wins_and_clears(t: T) -> void:
	t.eq(Figures.override, "", "the tests' override starts clear")
	t.check(not OS.get_cmdline_user_args().has("figures=old"), "this test run was not started with figures=old")
	t.check(Figures.use_new(), "with no argument this run draws the new figures")
	Figures.override = "old"
	t.check(not Figures.use_new(), "override old: the old figures")
	Figures.override = "new"
	t.check(Figures.use_new(), "override new: the new figures")
	Figures.override = ""
	t.check(Figures.use_new(), "cleared: back to following the arguments")
