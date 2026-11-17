# The Playroom tuned from the owner's first play (T15m; sim/seek.gd "T15m", sim/run.gd playroom_tuned), each
# point proved with the tune on and, as the control, off (every stored result has it off):
#   1. Time to hide: 30, 35, 40, 45 s (45 after that; the last count 30 s), then a 30 s search; the count
#      event carries "hide" and every screen's clock (net/client.gd count_clock) reads it. Off: 6 s, no "hide".
#   2. A view out of the Playroom's hides (client/hide_view.gd HideOverlay.layout, client/play_link.gd): sat
#      back in the ball pit nothing is drawn over the picture but a few balls at the bottom edge, and the camera
#      is at the balls; in every other Playroom hide the gap stays open. Off the Playroom sat back stays dark.
#   3. The anger bar: provocations fill it at their printed rates, it cools when nobody provokes, a count
#      starts the tick it is full, it is full through the count and drains to empty over the 15 s after; the
#      host's number goes to every screen in the seek block. Off: one tick starts a count, no anger on the wire.
#   4. The grab: outside a count the Minder grabs anyone within 1 m ("found" cause "grab", never a count) and
#      drags them to the party table ("taken"); at 1.3 m nobody is grabbed; in a count it does not grab; a count
#      starting mid-drag seats them. Through the run the grabbed player is out (caught) and seated. Off: nobody
#      is ever found outside a count, however close.
#   5. The hint events: "playroomArrived" once, on the first tick off the ride; "sprintDuringHunt" once per
#      sprint started while it searches, never while you hide. Off: neither.
extends RefCounted

const T = preload("res://tests/t.gd")
const Seek = preload("res://sim/seek.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Playroom = preload("res://sim/playroom.gd")
const Places = preload("res://sim/places.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const Client = preload("res://net/client.gd")
const HideView = preload("res://client/hide_view.gd")
const PlayLink = preload("res://client/play_link.gd")
const PS = preload("res://tests/prop_seek.gd")
const CR = preload("res://tests/prop_count_run.gd")

const DT := 0.05
const TEPS := 1e-6

# The owner's numbers, restated (not imported).
const O_HIDES: Array[float] = [30.0, 35.0, 40.0, 45.0, 45.0]
const O_LAST_HIDE := 30.0
const O_SEARCH := 30.0
const O_CALM := 15.0
const O_SPRINT_RATE := 0.5
const O_LUMP := 0.34
const O_COOL := 0.02
const O_GRAB := 1.0

## A seek state on floor `i` of prop_seek's floors, tuned or not, stepped with its own clock.
class Sk:
	var s: Seek.SeekState
	var events: Array[Dictionary] = []
	func step(inputs: Array[Seek.SeekInput], fl: Seek.FloorInput = null) -> Array[Dictionary]:
		var r := Seek.step_seek(s, inputs, DT, fl)
		s = r.state
		events.append_array(r.events)
		return r.events
	func run(inputs: Array[Seek.SeekInput], secs: float, fl: Seek.FloorInput = null) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for _k in roundi(secs / DT):
			out.append_array(step(inputs, fl))
		return out

static func sk(i: int, ids: Array[String], tuned: bool) -> Sk:
	var f := PS.floor_of(i)
	var k := Sk.new()
	k.s = Seek.create_seek(f.plan, ids, f.data)
	if tuned:
		k.s = Seek.tune(k.s)
	return k

static func of_type(evs: Array[Dictionary], ty: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in evs:
		if e["type"] == ty:
			out.append(e)
	return out

## The walkway spot (no squeaker under it) furthest from where the Minder is now, so it cannot reach
## anyone standing there for a while (it grabs within 1 m outside a count).
static func away(k: Sk, i: int) -> Move.Body:
	var f := PS.floor_of(i)
	var mb := k.s.minder.body
	var best: Move.Body = null
	var best_d := -1.0
	for c in f.walkway:
		if f.squeak.has(Floor.pos_index(f.plan, c)):
			continue
		var b := PS.cell_body(f.plan, c)
		var d := M.hypot2(b.x - mb.x, b.z - mb.z)
		if d > best_d:
			best = b
			best_d = d
	return best

## A walkway spot at least `far` m from the Minder's start (no squeaker under it).
static func far_spot(i: int, far: float, k: int = 0) -> Move.Body:
	var f := PS.floor_of(i)
	var cells := PS.far_cells(f, far, Rng.make_rng("tuned:%d" % i))
	var n := 0
	for c in cells:
		if f.squeak.has(Floor.pos_index(f.plan, c)):
			continue
		if n == k:
			return PS.cell_body(f.plan, c)
		n += 1
	return PS.cell_body(f.plan, cells[0])

## Sprints in place until a count starts (at most 10 s); returns its event.
static func provoke(k: Sk, id: String, b: Move.Body) -> Dictionary:
	for _i in 200:
		var c := of_type(k.step([PS.inp(id, b, &"sprint")]), "count")
		if not c.is_empty():
			return c[0]
	return {}

## Runs the running count out with `id` gone (inactive), then the calm after it.
static func run_out(k: Sk, id: String, b: Move.Body) -> Dictionary:
	var gone := PS.inp(id, b)
	gone.active = false
	var end := {}
	for _i in 4000:
		var e := of_type(k.step([gone]), "countEnd")
		if not e.is_empty():
			end = e[0]
			break
	k.run([gone], O_CALM + DT)
	return end

# ---------------------------------------------------------------------------------------------
# 1. Time to hide.

func test_t15m_time_to_hide(t: T) -> void:
	var floors := 2 if t.quick else 6
	var seen: Array = []
	for i in floors:
		var k := sk(i, ["a"], true)
		var b := away(k, i)
		k.run([PS.inp("a", b)], 0.5)
		for n in O_HIDES.size():
			b = away(k, i)
			var c := provoke(k, "a", b)
			var want := O_HIDES[n]
			t.check(not c.is_empty() and absf(float(c.get("hide", -1.0)) - want) < TEPS and absf(float(c["len"]) - O_SEARCH) < TEPS,
				"floor %d count %d: hide %s len %s, want %.0f and %.0f" % [i, n + 1, str(c.get("hide")), str(c.get("len")), want, O_SEARCH])
			if c.is_empty():
				break
			var t0 := float(c["t0"])
			# The phase by the rules, either side of the end of the hiding time.
			var gone := PS.inp("a", b)
			gone.active = false
			while k.s.t < t0 + want - 0.5 * DT - TEPS:
				t.check(Seek.phase_of(k.s) == &"hide", "floor %d count %d: %s at %.2f s, still hiding time" % [i, n + 1, Seek.phase_of(k.s), k.s.t - t0])
				if Seek.phase_of(k.s) != &"hide":
					break
				k.step([gone])
			k.step([gone])
			t.eq(Seek.phase_of(k.s), &"seek", "floor %d count %d: searching once the %.0f s are up" % [i, n + 1, want])
			var end := run_out(k, "a", b)
			t.check(not end.is_empty() and absf(float(end["t"]) - t0 - want - O_SEARCH) < TEPS, "floor %d count %d: ended %.3f s after it started" % [i, n + 1, float(end.get("t", 0.0)) - t0])
			if i == 0:
				seen.append(want)
		# The last count: the call.
		b = away(k, i)
		var evs := k.step([PS.inp("a", b)], PS.flin(true, "a"))
		var lc := of_type(evs, "count")
		t.check(lc.size() == 1 and bool(lc[0]["last"]) and absf(float(lc[0].get("hide", -1.0)) - O_LAST_HIDE) < TEPS and absf(float(lc[0]["len"]) - O_SEARCH) < TEPS,
			"floor %d: the last count %s" % [i, str(lc)])
	# Every screen's clock reads it: hiding until t0 + hide, then the search, then over.
	var ev := {"t0": 100.0, "len": O_SEARCH, "hide": 35.0}
	t.check(Client.count_clock(ev, 134.9)["phase"] == "hide" and absf(float(Client.count_clock(ev, 134.9)["left"]) - 0.1) < 1e-9, "the screens' clock: hiding at 34.9 s of 35")
	t.check(Client.count_clock(ev, 135.1)["phase"] == "seek" and Client.count_clock(ev, 165.1)["phase"] == "over", "the screens' clock: the search, then over")
	t.check(absf(HideView.dark_at(ev, 160.0) - 1.0) < 1e-9 and HideView.dark_at(ev, 170.0) < 1.0, "count dark lasts the hiding time and the search")
	# Through the run: the game's rooms ask for it (HostRules), and the last count opens the doors at t0 + 30 + 30.
	var rules := HostRules.new(true, 4, Places.FULL, false, false, false, false, false, false, false, false, false, true)
	var st := rules.prepare(Run.create_run("tuned-run", ["p0"] as Array[String], Places.FULL))
	t.check(st.playroom_tuned, "HostRules turns the tuned Playroom on")
	t.check(not HostRules.new(true, 4, Places.FULL).prepare(Run.create_run("tuned-run", ["p0"] as Array[String], Places.FULL)).playroom_tuned, "off unless asked")
	# The control: off, 6 s to hide and no "hide" on the event.
	var off := sk(0, ["a"], false)
	var b0 := away(off, 0)
	off.run([PS.inp("a", b0)], 0.5)
	var oc := of_type(off.step([PS.inp("a", b0, &"sprint")]), "count")
	t.check(oc.size() == 1 and not oc[0].has("hide") and absf(off.s.hide_len - 6.0) < TEPS and float(oc[0]["len"]) == 30.0, "off: one sprint tick, 6 s to hide, no hide on the event: %s" % str(oc))
	t.check(Client.count_clock({"t0": 0.0, "len": 30.0}, 5.9)["phase"] == "hide" and Client.count_clock({"t0": 0.0, "len": 30.0}, 6.1)["phase"] == "seek", "off: the screens' clock is the 6 s")
	t.note("hiding times %s s then %.0f s searches; the last count %.0f + %.0f; off: 6 s" % [str(seen), O_SEARCH, O_LAST_HIDE, O_SEARCH])

func test_t15m_the_last_count_through_the_run(t: T) -> void:
	var r := CR.Rig.new("tuned-last-0")
	r.st = Run.with_playroom_tuned(r.st)
	r.run(0.1)
	t.check(r.seek() != null and r.seek().tuned, "the run's seek state is tuned")
	CR.to_away(t, r)
	# p0 at the call button calls; then nobody is on the floor for it (inactive players are never hunted).
	r.bodies["p0"] = CR.at_door(r)
	r.step()
	r.call_by = "p0"
	var evs := r.step().events
	for id in CR.IDS:
		r.off[id] = true
	var lc := CR.of_type(evs, "count")
	t.check(lc.size() == 1 and bool(lc[0]["last"]) and absf(float(lc[0].get("hide", -1.0)) - O_LAST_HIDE) < TEPS and absf(float(lc[0]["len"]) - O_SEARCH) < TEPS,
		"the call started the tuned last count: %s" % str(lc))
	if lc.is_empty():
		return
	var t0 := float(lc[0]["t0"])
	var opened := r.until_event("doorsOpened", O_LAST_HIDE + O_SEARCH + 2.0)
	t.check(not opened.is_empty() and absf(float(opened["t"]) - (t0 + O_LAST_HIDE + O_SEARCH)) < 1e-6, "the doors opened %.3f s after the last count began" % (float(opened.get("t", 0.0)) - t0))

# ---------------------------------------------------------------------------------------------
# 2. A view out.

func test_t15m_a_view_out_of_the_hides(t: T) -> void:
	var w := 640.0
	var h := 360.0
	var lay := HideView.HideOverlay.layout("sat", "pit", true, w, h)
	var covered := 0.0
	if int(lay["balls"]) > 0:
		var br: Rect2 = lay["ballRect"]
		covered = br.intersection(Rect2(0, 0, w, h)).get_area() / (w * h)
	t.check(float(lay["dark"]) == 0.0 and lay["hole"] == null and int(lay["balls"]) <= 8 and (lay["ballRect"] as Rect2).position.y >= h * 0.9 - 1e-6,
		"sat back in the ball pit: nothing over the view but a few balls at the bottom edge: %s" % str(lay))
	var peek := HideView.HideOverlay.layout("peek", "pit", true, w, h)
	t.check(int(peek["balls"]) <= 8 and (peek["ballRect"] as Rect2).position.y >= h * 0.9 - 1e-6, "peeking from the ball pit: a few balls at the edge at most")
	var open := {}
	for kind: String in ["slide", "den", "playhouse", "table", "chest", "cubby"]:
		var l := HideView.HideOverlay.layout("sat", kind, true, w, h)
		var hole: Variant = l["hole"]
		var frac := (hole as Rect2).get_area() / (w * h) if hole is Rect2 else 0.0
		open[kind] = snappedf(frac, 0.01)
		t.check(float(l["dark"]) == 0.0 and frac >= 0.05, "sat back in the %s: the gap stays open (%.2f of the picture, no dark over it)" % [kind, frac])
	# The camera: down at the balls (their top layer is 0.33 to 0.49 m), under the peeking eye.
	t.check(PlayLink.PIT_SAT_EYE >= 0.38 and PlayLink.PIT_SAT_EYE <= PlayLink.PIT_PEEK_EYE, "the pit's sat-back eye %.2f m is at the balls" % PlayLink.PIT_SAT_EYE)
	# The control: off the Playroom (blind by sim/hiding.gd's rules) sat back stays dark.
	for kind: String in ["bed", "cabinet", "desk"]:
		var l2 := HideView.HideOverlay.layout("sat", kind, false, w, h)
		t.check(float(l2["dark"]) >= 0.9, "off the Playroom, sat back in the %s stays dark" % kind)
	t.note("ball pit: %.0f%% of the picture under balls; gaps open: %s" % [covered * 100.0, str(open)])

# ---------------------------------------------------------------------------------------------
# 3. The anger bar.

func test_t15m_the_anger_bar(t: T) -> void:
	var floors := 2 if t.quick else 6
	for i in floors:
		var tag := "floor %d" % i
		# Sprinting: O_SPRINT_RATE a second, exactly; the count the tick it is full.
		var k := sk(i, ["a"], true)
		var b := away(k, i)
		k.run([PS.inp("a", b)], 0.5)
		t.check(k.s.anger == 0.0, "%s: standing adds nothing" % tag)
		# Walking and creeping, back and forth along the walkway (moving: a walk is not a noise).
		var nb := beside(PS.floor_of(i).plan, b, 0.5)
		if nb == null:
			nb = b
		for n in 40:
			k.step([PS.inp("a", nb if n % 2 == 0 else b, &"walk" if n < 20 else &"creep")])
		t.check(k.s.anger == 0.0 and not k.s.counting, "%s: walking and creeping add nothing (anger %.3f)" % [tag, k.s.anger])
		b = away(k, i)
		var evs := k.run([PS.inp("a", b, &"sprint")], 1.0)
		t.check(absf(k.s.anger - O_SPRINT_RATE * 1.0) < 1e-9 and of_type(evs, "count").is_empty(), "%s: a second of sprint: anger %.4f, want %.2f, no count" % [tag, k.s.anger, O_SPRINT_RATE])
		# Cooling: 5 s of quiet.
		k.run([PS.inp("a", b)], 5.0)
		b = away(k, i)
		t.check(absf(k.s.anger - (O_SPRINT_RATE - 5.0 * O_COOL)) < 1e-9, "%s: cools to %.4f, want %.4f" % [tag, k.s.anger, O_SPRINT_RATE - 5.0 * O_COOL])
		# Sprint on: the count starts the tick it reaches full, and not before.
		var ticks := 0
		var c := {}
		var level_before := 0.0
		while ticks < 200:
			level_before = k.s.anger
			var cs := of_type(k.step([PS.inp("a", b, &"sprint")]), "count")
			ticks += 1
			if not cs.is_empty():
				c = cs[0]
				break
		t.check(not c.is_empty() and c["why"] == "sprint" and c["by"] == "a" and level_before + O_SPRINT_RATE * DT >= 1.0 - TEPS and level_before < 1.0 - TEPS,
			"%s: the count started at full (%.4f before the last tick): %s" % [tag, level_before, str(c)])
		t.check(k.s.anger == 1.0, "%s: full through the count" % tag)
		# Full through the count, then empty over the 15 s after it.
		var gone := PS.inp("a", b)
		gone.active = false
		var full_ok := true
		while k.s.counting:
			k.step([gone])
			full_ok = full_ok and (k.s.anger == 1.0 or not k.s.counting)
		t.check(full_ok, "%s: the bar stayed full while it counted" % tag)
		var drain_ok := true
		var calm := k.s.calm_until
		while k.s.t < calm - TEPS:
			k.step([PS.inp("a", b, &"sprint")])
			var want := clampf((calm - k.s.t) / O_CALM, 0.0, 1.0)
			drain_ok = drain_ok and (absf(k.s.anger - want) < 1e-9 or k.s.t >= calm - TEPS)
		t.check(drain_ok and not k.s.counting, "%s: it drained to empty over the 15 s after, sprinting or not" % tag)
		# Lumps: an emote is O_LUMP; the third fills it.
		var k2 := sk(i, ["a"], true)
		var b2 := away(k2, i)
		k2.run([PS.inp("a", b2)], 0.5)
		var em := PS.inp("a", b2)
		em.emote_sound = true
		var counts := 0
		for n in 3:
			counts += of_type(k2.step([em]), "count").size()
			if n < 2:
				# Each noise adds its lump; the quiet tick between them cools it a little.
				t.check(absf(k2.s.anger - (O_LUMP * (n + 1) - n * O_COOL * DT)) < 1e-9 and counts == 0, "%s: emote %d: anger %.4f" % [tag, n + 1, k2.s.anger])
			k2.step([PS.inp("a", b2)])
		t.check(counts == 1 and k2.s.counting and k2.s.why == &"emote", "%s: the third noise started the count (%d counts)" % [tag, counts])
	# The same number for every player: the host's block carries it, and it survives the wire.
	var r := CR.Rig.new("tuned-anger-0")
	r.st = Run.with_playroom_tuned(r.st)
	r.run(0.1)
	CR.to_away(t, r)
	r.gait["p1"] = &"sprint"
	r.run(0.6)
	r.gait["p1"] = &"creep"
	var blk: Dictionary = Host.seek_block(r.st)
	var dec := Protocol.dec_seek(Protocol._V.new(), JSON.parse_string(JSON.stringify(Protocol.enc_seek(blk))))
	t.check(blk.has("anger") and absf(float(blk["anger"]) - r.seek().anger) < 1e-12 and r.seek().anger > 0.2 and absf(float(dec.get("anger", -1.0)) - r.seek().anger) <= 0.0005 + 1e-9,
		"the snapshot carries the host's anger: state %.4f, block %s, decoded %s" % [r.seek().anger, str(blk.get("anger")), str(dec.get("anger"))])
	t.check(absf(float(dec.get("hide", -1.0)) - r.seek().hide_len) < 1e-6, "and the count's hiding time")
	# The printed line matches the rules: 2 s of sprint, 3 noises.
	t.check(HideView.ANGER_RATES.contains("SPRINT %d S" % roundi(1.0 / Seek.ANGER_RATES[&"sprint"])) and HideView.ANGER_RATES.contains("%d NOISES" % ceili(1.0 / float(Seek.ANGER_LUMPS[&"emote"]) - 1e-9)),
		"the printed rates \"%s\" match the rules" % HideView.ANGER_RATES)
	# The control: off, one tick starts a count, and the wire has no anger (11 elements, as before).
	var off := sk(0, ["a"], false)
	var b0 := far_spot(0, 10.0)
	off.run([PS.inp("a", b0)], 0.5)
	t.eq(of_type(off.step([PS.inp("a", b0, &"sprint")]), "count").size(), 1, "off: one sprint tick starts a count")
	var r0 := CR.Rig.new("tuned-anger-0")
	r0.run(0.1)
	var blk0: Dictionary = Host.seek_block(r0.st)
	t.check(not blk0.has("anger") and Protocol.enc_seek(blk0).size() == 11, "off: the seek block is as before")

# ---------------------------------------------------------------------------------------------
# 4. The grab.

## A spot `d` m from the Minder's body along an open way (the rules' walls), or null.
static func beside(plan: Floor.FloorPlan, mb: Move.Body, d: float) -> Move.Body:
	for v: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		var n := Move.move_with_collision(plan, mb, v.x * d, v.y * d, 0.3)
		if absf(M.hypot2(n.x - mb.x, n.z - mb.z) - d) < 1e-6:
			return n
	return null

func test_t15m_the_grab(t: T) -> void:
	var floors := 3 if t.quick else 10
	var grabbed := 0
	var seated := 0
	var drag_s: Array[float] = []
	for i in floors:
		var f := PS.floor_of(i)
		var tag := "floor %d" % i
		var k := sk(i, ["a"], true)
		# It wanders its round a while first (from the party room), so the drag is a long one.
		for _n in 6 + 4 * i:
			k.run([PS.inp("a", away(k, i))], 1.0)
		# At 1.3 m, walking quietly beside it: not grabbed.
		var near := beside(f.plan, k.s.minder.body, 1.3)
		if near == null:
			continue
		var evs := k.step([PS.inp("a", near, &"creep")])
		t.check(of_type(evs, "found").is_empty() and Seek.player_of(k.s, "a").status == &"ok", "%s: grabbed at 1.3 m" % tag)
		# Within 1 m: grabbed, found by "grab", and no count.
		var close := beside(f.plan, k.s.minder.body, 0.85)
		if close == null:
			continue
		evs = k.step([PS.inp("a", close, &"creep")])
		var fo := of_type(evs, "found")
		t.check(fo.size() == 1 and fo[0]["cause"] == "grab" and fo[0]["playerId"] == "a" and of_type(evs, "count").is_empty() and not k.s.counting,
			"%s: within 1 m: %s" % [tag, str(evs)])
		if fo.is_empty():
			continue
		grabbed += 1
		t.check(k.s.minder.mode == &"grab", "%s: it holds them (%s)" % [tag, k.s.minder.mode])
		# Dragged to the party table: the body comes along behind it; then taken, at the seat.
		var t_grab := k.s.t
		var taken := {}
		var behind_ok := true
		var a_in := PS.inp("a", close)
		for _n in roundi((Seek.DRAG_MAX + 3.0) / DT):
			a_in = PS.inp("a", Seek.player_of(k.s, "a").body)   # rooted where the rules hold them (as the run does)
			var e := k.step([a_in])
			if k.s.minder.mode == &"drag":
				var pb := Seek.player_of(k.s, "a").body
				behind_ok = behind_ok and pb.level == k.s.minder.body.level and M.hypot2(pb.x - k.s.minder.body.x, pb.z - k.s.minder.body.z) <= Seek.DRAG_BEHIND + 1e-6
			var tk := of_type(e, "taken")
			if not tk.is_empty():
				taken = tk[0]
				break
		t.check(behind_ok, "%s: dragged along behind it, within %.1f m" % [tag, Seek.DRAG_BEHIND])
		t.check(not taken.is_empty() and taken["playerId"] == "a" and int(taken["seat"]) >= 0, "%s: taken to the party table: %s" % [tag, str(taken)])
		if not taken.is_empty():
			seated += 1
			drag_s.append(snappedf(k.s.t - t_grab, 0.05))
			var sp := Seek.player_of(k.s, "a")
			var seat: Playroom.Seat = k.s.floor.seats[sp.seat]
			var sb := Seek.point_body(f.plan, seat.at, seat.level)
			t.check(sp.status == &"taken" and sp.body.same(sb), "%s: sat at seat %d" % [tag, sp.seat])
			t.eq(k.s.minder.mode, &"wander", "%s: back on its round" % tag)
		t.check(not k.s.counting and k.s.counts == 0, "%s: the grab started no count" % tag)
	t.check(grabbed >= 1 and seated == grabbed, "not vacuous: %d grabbed, %d seated" % [grabbed, seated])
	# In a count it does not grab: within 1 m in the hiding time nobody is found.
	var kc := sk(0, ["a"], true)
	var f0 := PS.floor_of(0)
	var b0 := away(kc, 0)
	kc.run([PS.inp("a", b0)], 0.5)
	provoke(kc, "a", b0)
	var cl := beside(f0.plan, kc.s.minder.body, 0.85)
	var fe := kc.run([PS.inp("a", cl, &"creep")], 2.0)
	t.check(Seek.phase_of(kc.s) == &"hide" and of_type(fe, "found").is_empty(), "in the hiding time nobody within 1 m is grabbed")
	# A count starting mid-drag seats them at once.
	var kd := sk(0, ["a", "b"], true)
	var bd := away(kd, 0)
	kd.run([PS.inp("a", bd), PS.inp("b", bd)], 3.0)
	var cd := beside(f0.plan, kd.s.minder.body, 0.85)
	kd.step([PS.inp("a", cd), PS.inp("b", bd)])
	kd.run([PS.inp("a", Seek.player_of(kd.s, "a").body), PS.inp("b", bd)], 1.5)
	var mid := kd.s.minder.mode
	var de: Array[Dictionary] = []
	for _n in 200:
		var e2 := kd.step([PS.inp("a", Seek.player_of(kd.s, "a").body), PS.inp("b", bd, &"sprint")])
		de.append_array(e2)
		if not of_type(e2, "count").is_empty():
			break
	var tk2 := of_type(de, "taken")
	t.check(mid == &"drag" and kd.s.counting and tk2.size() == 1 and Seek.player_of(kd.s, "a").status == &"taken", "a count mid-drag seats them at once (%s, %s)" % [mid, str(tk2)])
	# Through the run: out of the run (caught) and seated.
	var r := CR.Rig.new("tuned-grab-0")
	r.st = Run.with_playroom_tuned(r.st)
	r.run(0.1)
	CR.to_away(t, r)
	var mb := r.seek().minder.body
	var rb := beside(r.plan(), mb, 0.85)
	r.bodies["p1"] = rb
	var got := r.until_event("found", 0.2)
	t.check(not got.is_empty() and got["cause"] == "grab" and got["playerId"] == "p1", "through the run: grabbed (%s)" % str(got))
	t.eq(r.rp("p1").status, &"caught", "through the run: the grabbed player is out of the run")
	var seat_ev := r.until_event("taken", Seek.DRAG_MAX + 2.0)
	t.check(not seat_ev.is_empty() and r.sp("p1").status == &"taken" and r.rp("p1").body.same(r.sp("p1").body), "through the run: seated at the party table (%s)" % str(seat_ev))
	# The control: off, nobody is ever found outside a count, however close (0.6 m: not yet a bump).
	var ko := sk(0, ["a"], false)
	ko.run([PS.inp("a", away(ko, 0))], 3.0)
	var co := beside(f0.plan, ko.s.minder.body, 0.6)
	var oe := ko.run([PS.inp("a", co, &"creep")], 0.2)
	t.check(of_type(oe, "found").is_empty(), "off: nobody found outside a count at 0.6 m")
	t.note("%d floors: %d grabbed at 0.85 m, all seated, drags of %s s; none at 1.3 m, none in a count" % [floors, grabbed, str(drag_s)])

# ---------------------------------------------------------------------------------------------
# 5. The hint events.

func test_t15m_hint_events(t: T) -> void:
	var k := sk(0, ["a"], true)
	var b := away(k, 0)
	var ride := k.run([PS.inp("a", b)], 0.5, PS.flin(false, "", false, true))
	t.check(of_type(ride, "playroomArrived").is_empty(), "not while riding")
	var first := k.step([PS.inp("a", b)])
	var arrived := of_type(first, "playroomArrived")
	t.check(arrived.size() == 1 and int(arrived[0]["depth"]) == PS.floor_of(0).plan.depth, "playroomArrived on the first tick off the ride: %s" % str(first))
	var later := k.run([PS.inp("a", b)], 2.0)
	t.check(of_type(later, "playroomArrived").is_empty(), "said once")
	var c := provoke(k, "a", b)
	# Sprinting while hiding is free and says nothing.
	var hiding := k.run([PS.inp("a", b, &"sprint")], 3.0)
	t.check(of_type(hiding, "sprintDuringHunt").is_empty(), "nothing while you hide")
	var gone := PS.inp("a", b)
	gone.active = false
	while Seek.phase_of(k.s) == &"hide":
		k.step([gone])
	# Two sprints in the search (moving): one event each, on the tick each starts.
	var nb := beside(PS.floor_of(0).plan, b, 0.25)
	if nb == null:
		nb = b
	var says := 0
	var at := b
	for burst in 2:
		for n in 6:
			at = nb if (n % 2 == 0) else b
			var e := k.step([PS.inp("a", at, &"sprint")])
			var sd := of_type(e, "sprintDuringHunt")
			says += sd.size()
			if n == 0:
				t.check(sd.size() == 1 and sd[0]["playerId"] == "a" and int(sd[0]["n"]) == int(c["n"]), "burst %d: said on its first tick" % (burst + 1))
			elif Seek.player_of(k.s, "a").status != &"ok":
				break
		k.step([PS.inp("a", at, &"creep")])
		if Seek.player_of(k.s, "a").status != &"ok":
			break
	t.check(says == 2, "once per sprint, not every tick: %d for 2 sprints" % says)
	# The control: off, neither.
	var off := sk(0, ["a"], false)
	var oe := off.run([PS.inp("a", b)], 0.5)
	oe.append_array(off.run([PS.inp("a", b, &"sprint")], 8.0))
	t.check(of_type(oe, "playroomArrived").is_empty() and of_type(oe, "sprintDuringHunt").is_empty(), "off: no hint events")
	t.note("playroomArrived once off the ride; sprintDuringHunt %d for 2 sprints in the search, none while hiding" % says)
