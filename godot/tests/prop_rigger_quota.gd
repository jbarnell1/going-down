# RR1 stage 2: the crawling Rigger can still be recorded as the design asks. Sensible bot crews (sim/ward/bots.gd, the
# ones the difficulty numbers come from) stay one Ward each, on the same seeds, with the run flag rigger_roam off and on;
# with it on they meet the floor quota (by recording his climb beside the loaded line and his search from inside the
# house) about as often as with it off (within MARGIN of the stays), and get home at least as often less MARGIN.
# Quick: crews of two on 6 seeds and of four on 4 (seeds 8-11); default: both on 40 seeds (tools/ward_hunt.gd runs the 40-seed table).
extends RefCounted

const T = preload("res://tests/t.gd")
const Bots = preload("res://sim/ward/bots.gd")
const Layout = preload("res://sim/ward/layout.gd")
## How far below the flag-off rates the flag-on rates may be, as a share of the stays.
const MARGIN := 0.10
## The least share of what crews record without him crawling that they must record with him.
const EARNED := 0.85

func test_crews_meet_the_quota_about_as_often_with_him_crawling(t: T) -> void:
	_crews(t, {})

## On the layouts made from the seed (WG1), which the game's rooms play with the late floors.
func test_and_on_generated_layouts(t: T) -> void:
	_crews(t, Layout.options(null))

func _crews(t: T, layout_options: Dictionary) -> void:
	# Quick: two on seeds 1-6 and four on seeds 8-11 (where four meet it without him crawling); default: both on 1-40 (fewer is too few for a count near the line).
	var plan: Array = [[2, 1, 6], [4, 8, 4]] if t.quick else [[2, 1, 40], [4, 1, 40]]
	for row: Array in plan:
		var n: int = row[0]
		var first: int = row[1]
		var seeds: int = row[2]
		var met := [0, 0]
		var home := [0, 0]
		var earned := [0.0, 0.0]
		for k in seeds:
			for on in 2:
				var r := Bots.stay(first + k, n, &"sensible", {"roam": on == 1, "layout": layout_options})
				met[on] += 1 if r.earned >= r.needed else 0
				home[on] += 1 if int(r.home) == n else 0
				earned[on] += float(r.earned)
		# What a crew records: within EARNED of the stays without him crawling (stable on a few seeds).
		t.check(earned[1] >= earned[0] * EARNED, "crews of %d record %.0f a stay with him crawling, %.0f without (at least %.0f%%)" % [n, earned[1] / seeds, earned[0] / seeds, EARNED * 100.0])
		# How often they meet the quota: only at the default size (a count over 4 or 6 seeds says little).
		if not t.quick:
			t.check(met[1] >= met[0] - maxi(1, roundi(MARGIN * seeds)), "crews of %d meet the quota in %d of %d stays with him crawling, %d without (within %d)" % [n, met[1], seeds, met[0], maxi(1, roundi(MARGIN * seeds))])
		t.check(home[1] >= home[0] - maxi(1, roundi(MARGIN * seeds)), "crews of %d all get home in %d of %d stays with him crawling, %d without" % [n, home[1], seeds, home[0]])
		t.note(("generated layouts, " if not layout_options.is_empty() else "") + "crew %d over %d seeds: quota met %d / %d (off / on), all home %d / %d, recorded %.0f / %.0f a stay" % [n, seeds, met[0], met[1], home[0], home[1], earned[0] / seeds, earned[1] / seeds])
