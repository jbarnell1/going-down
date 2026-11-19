## Preview the actual lift monitor through three regular banks using the day test driver.
extends SceneTree

const Game = preload("res://client/main.gd")
const Rules = preload("res://sim/run.gd")
const Rig = preload("res://tests/day_rig.gd")
const Reels = preload("res://sim/night_reels.gd")
const TransportHost = preload("res://net/host.gd")
const Shop = preload("res://sim/shop.gd")

const BLEEDS := [
	"CREW 7. DAY 1. FOUR WENT DOWN. FOUR CAME UP.",
	"CREW 7. DAY 9. FOUR WENT DOWN. ONE IS BELOW, WITH ALL FOUR TAPES. IT IS RECORDING.",
	"CREW 7. THE ONE BELOW HAS A NEW UNIFORM. IT KEPT ITS FACE.",
]

func _initialize() -> void:
	run.call_deferred()

var failures := 0

func expect(ok: bool, note: String) -> bool:
	if not ok:
		printerr(note)
		failures += 1
	return ok

func run() -> void:
	var rig := Rig.DayRig.new("monitor-preview", ["p1", "p2"])
	rig.st = Rules.with_nightly_reels(Rules.with_shop(Rules.with_inventory(rig.st)))
	var game := Game.new()
	var lift := Lift.new()
	root.add_child(lift)
	lift.build({"width": 3.0, "depth": 2.5, "doorWidth": 1.4, "doorX": 0.0, "doorZ": 0.0,
		"floorY": 0.0, "rightX": 1.0, "rightZ": 0.0, "inX": 0.0, "inZ": -1.0})
	lift.set_faces(["", ""])
	var hashes := lift.monitor_hashes()
	for day in range(1, 4):
		if not expect(rig.until(func(s: Rules.RunState) -> bool: return s.phase == &"boarding", 200.0), "No boarding"):
			break
		rig.st = Rig.give(rig.st, "p1", 2000, "preview-%d" % day)
		if not expect(rig.until(func(s: Rules.RunState) -> bool: return s.going_up, 30.0), "No bank ride"):
			break
		var state := rig.st
		var started := state.reel_started
		var block: Dictionary = TransportHost.day_block(state)
		game.snap = {"goingUp": state.going_up, "day": block}
		var reel: Variant = game._active_reel(game.snap)
		if not expect(reel is Dictionary and reel["day"] == day, "Wrong reel in ride-up block"):
			break
		var count := 0
		var elapsed := 0.0
		for cue: Array in Reels.SHOTS[day - 1]:
			lift.show_reel(reel, started + elapsed + 0.25, "p1", null)
			expect(lift._reel_view.shot == count and lift._reel_view.cue == cue, "Wrong monitor cue")
			count += 1
			elapsed += float(cue[0])
		expect(lift._reel_view.cue[2] == BLEEDS[day - 1], "Wrong bleed transcript")
		expect(lift._monitor.material_override == lift._reel_material, "Reel material never reached monitor")
		expect(game._vote_reel() and game._reel_skip_at == started, "Skip vote did not name the ride")
		lift.show_reel(reel, started + 0.5, "p1", game._reel_skip_at)
		expect(lift._reel_view.status_text == "VOTED 0/2", "Wrong pending vote or two-seat majority")
		var tied := Rules.with_reel_votes(state, ["p1", "p2"], ["p1"])
		expect(not tied.reel_skipped and tied.reel_votes == ["p1"], "Tie skipped a two-player reel")
		var majority := Rules.with_reel_votes(tied, ["p1", "p2"], ["p2"])
		expect(majority.reel_skipped, "A majority did not skip")
		var skipped := TransportHost.day_block(majority)
		lift.show_reel(game._active_reel({"goingUp": true, "day": skipped}), started + 0.5, "p1", started)
		expect(lift._monitor.material_override == lift._face_material, "Skip did not restore monitor")
		expect(lift.monitor_hashes() == hashes, "Faces changed after reel")
		expect(rig.until(func(s: Rules.RunState) -> bool: return not s.going_up, 35.0), "Never arrived")
		expect(rig.st.t - started + 0.06 >= Reels.duration(day), "Ride arrived before the reel ended")
		print("Day %d: %d cues, %.1fs, majority routing and normal arrival passed" % [day, count, elapsed])
		if day < 3:
			var woke := rig.until_event("wokeUp", 60.0)
			if not expect(not woke.is_empty(), "The shop's wake-up period disappeared"):
				break
			expect(is_equal_approx(float(woke["leaveAt"]) - float(woke["t"]), Shop.WAKE_SECONDS), "Wrong wake-up period")
			var morning := rig.until_event("newDay", 20.0)
			expect(not morning.is_empty() and rig.st.day_index == day + 1, "No new morning")
			expect(absf(float(morning.get("t", -1.0)) - float(woke["leaveAt"])) <= Rig.DT, "The next ride interrupted wake-up")
			print("Shop wake-up stayed %.1fs" % [float(morning.get("t", -1.0)) - float(woke["t"])])
	var off := Rig.DayRig.new("monitor-disabled", ["p1"])
	if expect(off.until(func(st: Rules.RunState) -> bool: return st.going_up, 200.0), "No flag-off bank"):
		var begin := off.st.t
		expect(not TransportHost.day_block(off.st).has("reel"), "Disabled flag sent reel data")
		expect(off.until(func(st: Rules.RunState) -> bool: return not st.going_up, 15.0), "Flag-off ride never ended")
		expect(absf(off.st.t - begin - Rules.RIDE_UP_TIME) <= Rig.DT, "Flag-off ride timing changed")
	game.free()
	lift.free()
	quit(1 if failures > 0 else 0)
