# The ride-up reel's closing line on day 1 states the run's real numbers: how many went down and how many came
# up. A solo wipe sends the car up empty ("ONE WENT DOWN. NONE CAME UP."); a full crew home reads as it always did.
# Client text only (client/night_reel_view.gd, sim/night_reels.gd). No recorded voice says this line.
extends RefCounted

const T = preload("res://tests/t.gd")
const Reels = preload("res://sim/night_reels.gd")
const ReelView = preload("res://client/night_reel_view.gd")

static func _row(id: String, status: String, aboard: bool, active: bool = true) -> Dictionary:
	return {"id": id, "status": status, "aboard": aboard, "active": active}

## The caption on the reel's last shot for `players`.
static func _closing(players: Array) -> String:
	var reel := {"day": 1, "started": 0.0, "crew": players.size(), "votes": [], "skipped": false}
	var view := ReelView.new()
	view.present(ReelView.with_counts(reel, players), 1000.0, "p1", null)
	var line := view.caption()
	view.free()
	return line

func test_solo_wipe(t: T) -> void:
	t.eq(_closing([_row("p1", "out", false)]), "CREW 7. DAY 1. ONE WENT DOWN. NONE CAME UP.", "a solo wipe: one down, none up")

func test_four_of_four(t: T) -> void:
	var all: Array = []
	for i in 4:
		all.append(_row("p%d" % i, "ok", true))
	t.eq(_closing(all), "CREW 7. DAY 1. FOUR WENT DOWN. FOUR CAME UP.", "four of four reads as before")
	t.eq(Reels.SHOTS[0][-1][2], "CREW 7. DAY 1. FOUR WENT DOWN. FOUR CAME UP.", "the stored line is unchanged")

func test_three_of_four(t: T) -> void:
	var rows := [_row("p0", "ok", true), _row("p1", "ok", true), _row("p2", "ok", true), _row("p3", "out", false)]
	t.eq(_closing(rows), "CREW 7. DAY 1. FOUR WENT DOWN. THREE CAME UP.", "three of four")

func test_watchers_and_words(t: T) -> void:
	var rows := [_row("p0", "ok", true), _row("w", "ok", false, false)]
	t.eq(_closing(rows), "CREW 7. DAY 1. ONE WENT DOWN. ONE CAME UP.", "a watcher did not go down")
	t.eq(Reels.day_one_line(8, 8), "CREW 7. DAY 1. EIGHT WENT DOWN. EIGHT CAME UP.", "eight")
