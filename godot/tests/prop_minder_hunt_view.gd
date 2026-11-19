# The screen side of the Minder's hunt (PT1; client/hide_view.gd). "Odds are printed before a chance is taken" and
# "the instrument never lies": with the hunt on the screen says what the rules do, and with it off every line
# stays exactly as it was:
#   1. The health bar shows from the first search (health drains there); off, only once the first count ended.
#   2. The health bar's rates say walking and sprinting cost only while it searches; off, HEALTH_RATES.
#   3. No instrument warning in a Playroom hide (the Minder never acts on one); off, the two lines as before.
#   4. The anger bar's rates are the hunt's numbers in force (1 S, 2 NOISES; the host's when set) and match what
#      the rules do; off, ANGER_RATES (2 S, 3 NOISES).
# And the client's way of telling (hunt_of: the seek block carries "anger") holds for the rooms' switches.
extends RefCounted

const T = preload("res://tests/t.gd")
const Seek = preload("res://sim/seek.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Settings = preload("res://sim/settings.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const HideView = preload("res://client/hide_view.gd")
const MH = preload("res://tests/prop_minder_hunt.gd")
const CR = preload("res://tests/prop_count_run.gd")

## A seek block as the snapshot carries it (net/host.gd seek_block): `tuned` adds "anger".
static func block(ended: int, counting: bool, tuned: bool) -> Dictionary:
	var k := {"noise": 0.0, "counting": counting, "last": false, "called": false, "done": false, "n": ended + (1 if counting else 0),
		"t0": 0.0, "len": 30.0, "by": "", "why": "", "ended": ended, "calmUntil": 0.0, "lastAt": null, "players": []}
	if tuned:
		k["anger"] = 1.0 if counting else 0.0
	return k

func test_the_health_bar_shows_from_the_first_search(t: T) -> void:
	var on := block(0, true, true)
	var off := block(0, true, false)
	t.check(HideView.hunt_of(on) and not HideView.hunt_of(off), "the hunt is read from the seek block's anger")
	# On: hidden before any count and in the first time to hide; shown from the first search; and after.
	t.check(not HideView.shows_health(block(0, false, true), "", true), "on: no bar before any count")
	t.check(not HideView.shows_health(on, "hide", true), "on: no bar in the first time to hide")
	t.check(HideView.shows_health(on, "seek", true), "on: the bar shows in the first search")
	t.check(HideView.shows_health(block(1, false, true), "over", true) and HideView.shows_health(block(1, true, true), "hide", true), "on: and after the first count, as before")
	# Off: exactly as before (only once the first count has ended).
	t.check(not HideView.shows_health(off, "seek", false) and not HideView.shows_health(off, "hide", false), "off: no bar in the first count")
	t.check(HideView.shows_health(block(1, false, false), "over", false) and HideView.shows_health(block(2, true, false), "seek", false), "off: the bar once the first count has ended")

func test_the_health_rates_say_only_while_it_searches(t: T) -> void:
	var on := HideView.health_rates_text(true)
	var off := HideView.health_rates_text(false)
	t.eq(off, HideView.HEALTH_RATES, "off: the old line")
	t.eq(off, "WALK -3/S  SPRINT -8/S  STILL OR CREEP +1/S", "off: word for word")
	t.check(on.contains("ONLY WHILE IT SEARCHES") and on.contains("WALK -%d/S" % roundi(Seek.WALK_DRAIN)) and on.contains("SPRINT -%d/S" % roundi(Seek.SPRINT_DRAIN))
		and on.contains("+%d/S" % roundi(Seek.REST_GAIN)), "on: \"%s\" says the rules' rates, only while it searches" % on)
	t.note("on: %s" % on)

func test_no_instrument_warning_with_the_hunt(t: T) -> void:
	for raised: bool in [false, true]:
		for counting: bool in [false, true]:
			for near: bool in [false, true]:
				t.eq(HideView.ticking_note(raised, counting, near, true), "", "on: raised %s, counting %s, near %s: no warning" % [raised, counting, near])
	# Off: the two lines as before.
	t.eq(HideView.ticking_note(true, true, true, false), "IT HEARS THE TICKING IN HERE. LOWER IT. (E)", "off: near it, LOWER IT")
	t.eq(HideView.ticking_note(true, true, false, false), "TICKING IN A HIDE WITHIN 5 M OF IT MAKES IT LOOK IN", "off: further off, the reminder")
	t.eq(HideView.ticking_note(false, true, true, false), "", "off: lowered, nothing")
	t.eq(HideView.ticking_note(true, false, true, false), "", "off: outside a count, nothing")

func test_the_anger_rates_are_the_ones_in_force(t: T) -> void:
	t.eq(HideView.anger_rates_text(null, false), HideView.ANGER_RATES, "off: the old line")
	t.eq(HideView.anger_rates_text(null, false), "SPRINT 2 S OR 3 NOISES FILL IT", "off: word for word")
	var on := HideView.anger_rates_text(null, true)
	t.eq(on, "SPRINT 1 S OR 2 NOISES FILL IT", "on, nothing set: the hunt's numbers")
	t.eq(HideView.anger_rates_text(Settings.make({&"minder.anger_sprint": 3.0, &"minder.anger_noise": 34.0}), true), "SPRINT 3 S OR 3 NOISES FILL IT", "on, the host's numbers")
	t.eq(HideView.anger_rates_text(Settings.make({&"minder.anger_sprint": 3.0}), false), "SPRINT 3 S OR 3 NOISES FILL IT", "off, the host's sprint: as before")
	# The printed numbers are what the rules do (prop_minder_hunt's measures).
	var secs := MH.sprint_secs(0, true, null)
	var noises := MH.noises_to_count(0, true, null, MH.O_NOISE_GAP)
	t.check(on == "SPRINT %d S OR %d NOISES FILL IT" % [roundi(secs), noises] and absf(secs - roundf(secs)) <= MH.DT + 1e-6,
		"on: printed \"%s\", the rules filled it in %.2f s of sprint or %d noises" % [on, secs, noises])
	# The game's values in the panel are the hunt's too.
	t.eq(Settings.today(&"minder.anger_sprint"), Seek.HUNT_ANGER_SPRINT, "the panel's game value for the sprint")
	t.eq(Settings.today(&"minder.anger_noise"), Seek.HUNT_ANGER_NOISE, "the panel's game value for a noise")

func test_the_client_can_tell(t: T) -> void:
	# The rooms turn the hunt on exactly with the tuned Playroom, so a tuned seek block means the hunt.
	var r := CR.Rig.new("hunt-view-0")
	r.st = Run.with_minder_hunt(Run.with_playroom_tuned(r.st))
	r.run(0.1)
	t.check(HideView.hunt_of(Host.seek_block(r.st)) and r.seek().hunt, "tuned with the hunt: the block says so")
	var r0 := CR.Rig.new("hunt-view-0")
	r0.run(0.1)
	t.check(not HideView.hunt_of(Host.seek_block(r0.st)) and not r0.seek().hunt, "neither: the block says not")
