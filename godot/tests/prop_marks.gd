# The crew marks' guarantees over seeded random input sequences (sim/marks.gd): the shared pad
# never over- or under-counts, nothing is placed while sprinting, down or in the car, a peel
# returns exactly one, the same inputs make the same marks, a direction is one of exactly eight,
# a new floor has a full pad, and no call edits the state it was given.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Move = preload("res://sim/move.gd")
const Marks = preload("res://sim/marks.gd")

const PLAYERS: Array[String] = ["ann", "bo", "cy", "di"]
const GAITS: Array[StringName] = [&"creep", &"walk", &"sprint"]

## One random play of a floor: random begin/finish/cancel/peel/raise calls with random player
## state. Counts every rule breach it sees.
func _play(seed_text: String, pad: int, steps: int) -> Dictionary:
	var rng := Rng.make_rng(seed_text)
	var s := Marks.MarksState.start_floor(pad)
	var now := 0.0
	var log := PackedStringArray()
	var bad_placements := 0
	var broken := 0
	var mutated := 0
	var bad_peels := 0
	var noises := 0
	for _i in steps:
		now += rng.next() * 0.4
		var who: String = PLAYERS[rng.int_in(0, PLAYERS.size() - 1)]
		var status: StringName = &"ok" if rng.next() < 0.8 else &"caught"
		var gait: StringName = GAITS[rng.int_in(0, 2)]
		var aboard := rng.next() < 0.15
		var bad := status != &"ok" or gait == &"sprint" or aboard
		var body := Move.Body.make(rng.next() * 40.0, rng.next() * 40.0, rng.int_in(0, 1), 0.0)
		var yaw := (rng.next() - 0.5) * 40.0
		var before := _fingerprint(s)
		var op := rng.int_in(0, 9)
		var r: Marks.MarkResult = null
		if op <= 3:
			r = Marks.begin_place(s, who, body, yaw, status, gait, aboard, now)
			if bad and r.ok:
				bad_placements += 1
		elif op <= 6:
			var had := s.marks.size()
			r = Marks.finish_place(s, who, status, gait, aboard, now)
			if r.ok:
				if bad:
					bad_placements += 1
				if r.state.marks.size() != had + 1 or r.noise == null:
					broken += 1
				else:
					noises += 1
					if r.noise.radius != 8.0 or r.noise.x != r.mark.x or r.noise.z != r.mark.z:
						broken += 1
		elif op == 7 and not s.marks.is_empty():
			var pick: Marks.Mark = s.marks[rng.int_in(0, s.marks.size() - 1)]
			var pad_before := s.pad
			r = Marks.peel(s, pick.id, who, status)
			if r.ok:
				if r.state.pad != pad_before + 1 or r.state.marks.size() != s.marks.size() - 1:
					bad_peels += 1
			elif status == &"ok":
				bad_peels += 1
		elif op == 8:
			s = Marks.cancel_place(s, who)
		elif op == 9 and rng.next() < 0.1:
			s = Marks.set_pad_size(s, s.pad_size + 1)
		if r != null:
			# Nothing may have edited the state that was passed in; a refusal returns it as it was.
			if _fingerprint(s) != before:
				mutated += 1
			if not r.ok and r.state != s:
				mutated += 1
			s = r.state
		if s.pad < 0 or s.pad > s.pad_size or s.pad + s.marks.size() != s.pad_size:
			broken += 1
		log.append(_fingerprint(s))
	return {"state": s, "log": log, "bad_placements": bad_placements, "broken": broken, "mutated": mutated, "bad_peels": bad_peels, "noises": noises}

func _fingerprint(s: Marks.MarksState) -> String:
	var parts := PackedStringArray(["%d/%d" % [s.pad, s.pad_size], str(s.next_id)])
	for m in s.marks:
		parts.append("m%d:%s:%s:%d:%d:%s:%s" % [m.id, str(m.x), str(m.z), m.level, m.dir, m.player, str(m.placed_at)])
	for p in s.pending:
		parts.append("p%s:%s:%s:%d:%s" % [p.player, str(p.x), str(p.z), p.dir, str(p.started_at)])
	return "|".join(parts)

func test_pad_is_conserved_and_never_over_the_size(t: T) -> void:
	var runs := 30 if t.quick else 120
	var placed := 0
	for i in runs:
		var pad := 1 + (i % 5)
		var r := _play("marks-pad-%d" % i, pad, 200)
		t.eq(r["broken"], 0, "run %d: pad + marks == pad size and 0 <= pad <= size" % i)
		t.eq(r["mutated"], 0, "run %d: a call edited the state it was given" % i)
		t.eq(r["bad_peels"], 0, "run %d: a peel did not return exactly one" % i)
		placed += int(r["noises"])
		var s: Marks.MarksState = r["state"]
		t.check(s.marks.size() <= s.pad_size, "run %d: %d marks on the floor, pad size %d" % [i, s.marks.size(), s.pad_size])
	t.check(placed > runs, "not vacuous: only %d marks placed over %d runs" % [placed, runs])
	t.note("%d runs of 200 random inputs, %d marks placed in all" % [runs, placed])

func test_nothing_placed_while_sprinting_down_or_in_the_car(t: T) -> void:
	var runs := 30 if t.quick else 120
	for i in runs:
		var r := _play("marks-ctx-%d" % i, 3, 200)
		t.eq(r["bad_placements"], 0, "run %d: a mark was begun or finished in a refused state" % i)
	var s := Marks.MarksState.start_floor()
	var body := Move.Body.make(5.0, 5.0, 0, 0.0)
	var cases: Array = [[&"ok", &"sprint", false, &"sprinting"], [&"caught", &"walk", false, &"down"], [&"leftBehind", &"creep", false, &"down"], [&"ok", &"walk", true, &"in_car"]]
	for c: Array in cases:
		var b := Marks.begin_place(s, "ann", body, 0.0, c[0], c[1], c[2], 0.0)
		t.check(not b.ok and b.reason == c[3] and b.state == s, "begin refused for %s" % str(c))
	# Started legally, then sprinting at the end: refused too.
	var started := Marks.begin_place(s, "ann", body, 0.0, &"ok", &"walk", false, 0.0)
	t.check(started.ok, "a legal begin works")
	var f := Marks.finish_place(started.state, "ann", &"ok", &"sprint", false, 1.0)
	t.check(not f.ok and f.reason == &"sprinting", "finish refused while sprinting")
	var early := Marks.finish_place(started.state, "ann", &"ok", &"walk", false, 0.4)
	t.check(not early.ok and early.reason == &"too_early", "finish before the half second is refused")
	var good := Marks.finish_place(started.state, "ann", &"ok", &"walk", false, 0.5)
	t.check(good.ok and good.state.pad == 2 and good.noise != null, "finish after the half second places and slaps")

func test_empty_pad_refuses_and_the_crew_shares_one_pad(t: T) -> void:
	var s := Marks.MarksState.start_floor()
	var body := Move.Body.make(3.0, 3.0, 0, 0.0)
	var now := 0.0
	var who: Array[String] = ["ann", "bo", "cy", "di", "ann"]
	var placed := 0
	for p in who:
		var b := Marks.begin_place(s, p, body, 0.3, &"ok", &"walk", false, now)
		if not b.ok:
			t.eq(b.reason, &"pad_empty", "refusal reason with an empty pad")
			t.eq(s.pad, 0, "refused only once the shared pad is empty")
			continue
		now += 0.5
		var f := Marks.finish_place(b.state, p, &"ok", &"walk", false, now)
		t.check(f.ok, "finish for %s" % p)
		s = f.state
		placed += 1
	t.eq(placed, 3, "four players share three marks, not three each")
	t.eq(s.marks.size(), 3, "three marks on the floor")
	# A friend takes the last mark while another is mid-placing.
	var s2 := Marks.MarksState.start_floor(1)
	var a := Marks.begin_place(s2, "ann", body, 0.0, &"ok", &"walk", false, 0.0)
	var b2 := Marks.begin_place(a.state, "bo", body, 0.0, &"ok", &"walk", false, 0.0)
	var fa := Marks.finish_place(b2.state, "ann", &"ok", &"walk", false, 0.6)
	var fb := Marks.finish_place(fa.state, "bo", &"ok", &"walk", false, 0.7)
	t.check(fa.ok and not fb.ok and fb.reason == &"pad_empty", "the second finisher finds the pad empty")
	t.eq(fb.state.pad + fb.state.marks.size(), 1, "still one in all")

func test_peel_returns_exactly_one_and_any_player_can(t: T) -> void:
	var s := Marks.MarksState.start_floor()
	var body := Move.Body.make(3.0, 3.0, 0, 0.0)
	for k in 3:
		var b := Marks.begin_place(s, "ann", body, 0.0, &"ok", &"walk", false, float(k))
		s = Marks.finish_place(b.state, "ann", &"ok", &"walk", false, float(k) + 0.5).state
	t.eq(s.pad, 0, "pad empty after three")
	var r := Marks.peel(s, s.marks[1].id, "bo", &"ok")
	t.check(r.ok and r.state.pad == 1 and r.state.marks.size() == 2, "bo peels a mark of ann: one back")
	t.check(r.mark.player == "ann", "the peeled mark was placed by ann")
	var again := Marks.peel(r.state, s.marks[1].id, "bo", &"ok")
	t.check(not again.ok and again.reason == &"no_such_mark" and again.state.pad == 1, "peeling it twice returns nothing more")
	var down := Marks.peel(s, s.marks[0].id, "bo", &"caught")
	t.check(not down.ok, "a caught player cannot peel")
	# A skill-tree raise adds to the pad; a smaller size is ignored.
	var up := Marks.set_pad_size(r.state, 5)
	t.check(up.pad_size == 5 and up.pad == 3 and up.pad + up.marks.size() == 5, "raising the size raises the pad")
	t.check(Marks.set_pad_size(up, 2) == up, "never lowered")

func test_same_inputs_same_marks(t: T) -> void:
	var runs := 20 if t.quick else 60
	for i in runs:
		var a := _play("marks-det-%d" % i, 3, 150)
		var b := _play("marks-det-%d" % i, 3, 150)
		t.check(a["log"] == b["log"], "run %d: two plays of the same inputs differ" % i)
	var x := _play("marks-det-x", 3, 150)
	var y := _play("marks-det-y", 3, 150)
	t.check(x["log"] != y["log"], "different inputs should differ (not vacuous)")

func test_snapping_is_exactly_eight_directions(t: T) -> void:
	var rng := Rng.make_rng("marks-snap")
	var seen := {}
	for _i in 2000:
		var yaw := (rng.next() - 0.5) * 100.0
		var d := Marks.snap_dir(yaw)
		t.check(d >= 0 and d < 8, "dir %d out of range for yaw %s" % [d, str(yaw)])
		seen[d] = true
		var best_err := 99.0
		for k in 8:
			best_err = minf(best_err, absf(wrapf(yaw - float(k) * PI / 4.0, -PI, PI)))
		if absf(wrapf(yaw - float(d) * PI / 4.0, -PI, PI)) > best_err + 1e-6:
			t.check(false, "yaw %s snapped to %d, which is not the nearest" % [str(yaw), d])
	t.eq(seen.size(), 8, "all eight directions come up and no others")
	t.eq(Marks.snap_dir(0.0), 0, "yaw 0 is dir 0")
	t.eq(Marks.snap_dir(PI / 2.0), 2, "a quarter turn is dir 2")
	t.eq(Marks.snap_dir(-PI / 4.0), 7, "an eighth the other way is dir 7")
	t.eq(Marks.snap_dir(PI / 8.0 - 0.001), 0, "just under half an eighth rounds down")
	for k in 8:
		var v := Marks.dir_vector(k)
		t.check(absf(v.length() - 1.0) < 1e-6, "dir_vector %d is a unit vector" % k)
	var f := Marks.dir_vector(0)
	t.check(absf(f.x) < 1e-6 and absf(f.y + 1.0) < 1e-6, "dir 0 faces -z")

func test_a_new_floor_has_a_full_pad(t: T) -> void:
	for n: int in [0, 1, 3, 5, 10]:
		var s := Marks.MarksState.start_floor(n)
		t.check(s.pad == n and s.pad_size == n and s.marks.is_empty() and s.next_id == 0, "start_floor(%d)" % n)
	var d := Marks.MarksState.start_floor()
	t.check(d.pad == 3 and d.pad_size == 3, "the default pad is three")
	var body := Move.Body.make(1.0, 1.0, 0, 0.0)
	var used := Marks.finish_place(Marks.begin_place(d, "ann", body, 0.0, &"ok", &"walk", false, 0.0).state, "ann", &"ok", &"walk", false, 1.0).state
	t.eq(used.pad, 2, "used one")
	var next_floor := Marks.MarksState.start_floor(used.pad_size)
	t.check(next_floor.pad == 3 and next_floor.marks.is_empty(), "the next floor is full again")
