# DG0D, the dangers' base and a danger's dark region (sim/dangers.gd ask.dark), on screen and on the host:
#   1. A dark region hides only the resident standing in it: a screen never turns the whole floor into the lift's blink
#      for it (net/client.gd frame: f.dark is the blink, being taken and the flare, never the region).
#   2. Each Orderly is tested by its own poses (the second, from depth 2, too): the second in a dark region is not held by
#      a look (screen and host), and the first in one blinds nobody to the second.
#   3. What sees in a blink sees in a dark region: a lit flashbulb and a Steady Gaze hold the resident there
#      (sim/run.gd _step_stillness; net/host.gd _danger_hides).
#   4. The near light comes on at and near a dark region round the camera (client/dangers/dangers_view.gd near_dark,
#      client/main.gd), and kind views can read its reach (kind_view.gd).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const Shop = preload("res://sim/shop.gd")
const Dangers = preload("res://sim/dangers.gd")
const DangerFx = preload("res://sim/dangers/effects.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const SO = preload("res://tests/prop_second_orderly.gd")
const Watch = preload("res://tests/prop_watchers.gd")
const Gaze = preload("res://tests/prop_steady_gaze.gd")
const DangersView = preload("res://client/dangers/dangers_view.gd")
const KindView = preload("res://client/dangers/kind_view.gd")

const DT := 0.05
## Half the side of the dark box kept round an Orderly (m).
const HALF := 1.5

# ---------------------------------------------------------------------------------------------
# A networked session (prop_second_orderly's: a host, two clients on lossy links of 50 to 200 ms, both Orderlies
# hunting a few cells from the players) with the dangers' base on.

class Tally:
	var frames := 0
	var dark := 0
	var seen1 := 0
	var seen2 := 0
	var walk1 := 0.0
	var walk2 := 0.0
	var caught := false
	var overlap := false

static func _session(t: T, seed: String) -> SO.NSess:
	var s: SO.NSess = SO.new()._nsession(t, seed)
	if s == null:
		return null
	s.rules.dangers = [&"test_tile"] as Array[StringName]
	s.host.state = Dangers.with_dangers(s.host.state, [&"test_tile"])
	return s

## Keeps a dark region round Orderly `which` (1 or 2; 0: none) on the host, dark from host time `from` (announced
## ahead, as a kind does, so every screen has it on time) and for 5 s more.
static func _dark_round(s: SO.NSess, which: int, from: float) -> void:
	var st := s.host.state.copy()
	var d := (st.dangers as DangerFx.DangerFloor).copy()
	d.dark = []
	if which > 0:
		var o: Move.Body = (st.orderly if which == 1 else st.orderly2).body
		d.dark = [[o.level, o.x - HALF, o.z - HALF, o.x + HALF, o.z + HALF, maxf(st.t, from) + 5.0, 99, from]]
	st.dangers = d
	s.host.state = st

## Plays `secs` with the bots looking at `look` (SO.NBot.look) and a dark round Orderly `dark_on` from `lead` seconds on
## (announced now), counting from then; `lie`: every player's last input says it sees the second. Stops at a catch.
static func _play(s: SO.NSess, secs: float, look: int, dark_on: int, lie := false, lead := 0.6) -> Tally:
	var tl := Tally.new()
	for b in s.bots:
		b.look = look
	var from := s.host.state.t + (lead if dark_on > 0 else 0.0)
	var until := s.g + secs + (lead if dark_on > 0 else 0.0)
	while s.g < until and not tl.caught:
		s.g += 0.025
		s.net.now = s.g
		_dark_round(s, dark_on, from)
		var on := s.host.state.t >= from
		if lie and on:
			for p: Host.HostPlayer in s.host._players.values():
				if p.input is Dictionary:
					p.input["seeing2"] = true
		var o1 := s.host.state.orderly.body
		var o2 := s.host.state.orderly2.body
		if on and dark_on > 0 and absf(o1.x - o2.x) <= 2.0 * HALF + 0.6 and absf(o1.z - o2.z) <= 2.0 * HALF + 0.6:
			tl.overlap = true
		s.host.update(s.g)
		if on:
			tl.walk1 += SO.flat(o1, s.host.state.orderly.body)
			tl.walk2 += SO.flat(o2, s.host.state.orderly2.body)
		for p in s.host.state.players:
			if p.status != &"ok":
				tl.caught = true
		for b in s.bots:
			b.client.receive(s.g + b.offset)
		for b in s.bots:
			while b.next_frame <= s.g + 1e-9:
				b.next_frame += 0.05
				var f := _frame(b, s.g)
				if f.taken or not on:
					continue
				tl.frames += 1
				if f.dark:
					tl.dark += 1
				if f.seeing:
					tl.seen1 += 1
				if f.seeing2:
					tl.seen2 += 1
	return tl

static func _frame(b: SO.NBot, g: float) -> Client.Frame:
	var c := b.client
	var lf := Client.LocalFrame.new()
	lf.body = b.body if b.body != null else Move.Body.make(0.0, 0.0, 0, 0.0)
	lf.h_fov_deg = Bot.BOT_HFOV_DEG
	lf.v_fov_deg = Bot.BOT_VFOV_DEG
	if c.latest != null and b.body != null:
		var key := "orderly2" if b.look == 1 or b.look == 3 else "orderly"
		var o: Variant = c.latest.get(key, c.latest["orderly"])
		lf.yaw = Entity.yaw_toward(float(o["x"]) - b.body.x, float(o["z"]) - b.body.z) + (PI if b.look >= 2 else 0.0)
	var f := c.frame(g + b.offset, lf)
	if f.placed != null:
		b.body = f.placed
	return f

## Sessions each test plays (seeds where the players cannot see the Orderly from their spot are skipped, up to 4 more).
static func _sessions(t: T) -> int:
	return 1 if t.quick else 3

## Stands one Orderly still out of play (dormant, as prop_second_orderly does), so only the other hunts.
static func _rest(s: SO.NSess, which: int) -> void:
	var o := (s.host.state.orderly if which == 1 else s.host.state.orderly2).copy()
	o.mode = &"dormant"
	o.dormant_left = INF
	if which == 1:
		s.host.replace_orderly(o)
	else:
		s.host.replace_orderly2(o)

func test_the_floor_stays_lit_while_the_orderly_stands_in_a_dark(t: T) -> void:
	var played := 0
	for i in _sessions(t) + 4:
		if played >= _sessions(t):
			break
		var s := _session(t, "dg0d-lit-%d" % i)
		if s == null:
			continue
		_rest(s, 2)
		var lit := _play(s, 1.0, 0, 0)
		t.eq(lit.dark, 0, "session %d: lit: no screen dark" % i)
		if lit.seen1 == 0:
			t.note("session %d: the first is out of the players' sight; skipped" % i)
			continue
		var tl := _play(s, 1.5, 0, 1)
		t.check(tl.frames > 40, "session %d: frames drawn %d" % [i, tl.frames])
		t.eq(tl.dark, 0, "session %d: the first in a dark region: no screen goes dark (the blink's dark), frames %d" % [i, tl.frames])
		t.eq(tl.seen1, 0, "session %d: and every screen is blind to it there" % i)
		t.check(tl.walk1 > 0.3 or tl.caught, "session %d: it walks while looked at in the dark, as in a blink (%.2f m)" % [i, tl.walk1])
		t.note("session %d: lit %d frames seen; dark %d frames, %d dark, %d seen, walked %.2f m" % [i, lit.seen1, tl.frames, tl.dark, tl.seen1, tl.walk1])
		played += 1
	t.eq(played, _sessions(t), "sessions played")

func test_the_second_orderly_keeps_its_rule_in_a_dark(t: T) -> void:
	var played := 0
	for i in _sessions(t) + 4:
		if played >= _sessions(t):
			break
		var s := _session(t, "dg0d-two-%d" % i)
		if s == null:
			continue
		_rest(s, 1)
		var lit := _play(s, 1.0, 1, 0)
		if lit.seen2 == 0:
			t.note("session %d: the second is out of the players' sight; skipped" % i)
			continue
		# (a) The second in a dark region: no screen says it sees it, and it walks.
		var tl := _play(s, 1.0, 1, 2)
		t.check(tl.frames > 20, "session %d: frames drawn %d" % [i, tl.frames])
		t.eq(tl.seen2, 0, "session %d: the second in a dark region: no screen sees it" % i)
		t.eq(tl.dark, 0, "session %d: and no screen goes dark" % i)
		t.check(tl.walk2 > 0.3 or tl.caught, "session %d: it walks while looked at in the dark (%.2f m)" % [i, tl.walk2])
		# (a, the host) A screen that says it sees the second in the dark all the same counts for nothing.
		if not tl.caught:
			var lie := _play(s, 0.6, 1, 2, true, 0.0)
			t.check(lie.walk2 > 0.2 or lie.caught, "session %d: the host takes no \"I can see it\" for the second in a dark region (%.2f m walked)" % [i, lie.walk2])
			t.note("session %d: a lying screen: the second walked %.2f m" % [i, lie.walk2])
		t.note("session %d: lit %d frames seen; dark %d frames, %d seen, walked %.2f m" % [i, lit.seen2, tl.frames, tl.seen2, tl.walk2])
		played += 1
	t.eq(played, _sessions(t), "sessions played")

func test_the_first_in_a_dark_blinds_nobody_to_the_second(t: T) -> void:
	var played := 0
	for i in _sessions(t) + 6:
		if played >= _sessions(t):
			break
		var s := _session(t, "dg0d-both-%d" % i)
		if s == null:
			continue
		var lit := _play(s, 0.6, 1, 0)
		if lit.seen2 == 0:
			t.note("session %d: the second is out of the players' sight; skipped" % i)
			continue
		var tl := _play(s, 1.2, 1, 1)
		if tl.overlap or tl.frames < 20:
			t.note("session %d: the two Orderlies came within the dark box, or a catch came first (%d frames); skipped" % [i, tl.frames])
			continue
		t.check(tl.seen2 > 0, "session %d: the first in a dark region, the second lit and looked at: seen on %d frames of %d" % [i, tl.seen2, tl.frames])
		t.eq(tl.dark, 0, "session %d: no screen goes dark" % i)
		t.note("session %d: the first dark, the second seen on %d of %d frames" % [i, tl.seen2, tl.frames])
		played += 1
	t.eq(played, _sessions(t), "sessions played")

# ---------------------------------------------------------------------------------------------
# 3. A flash and a Steady Gaze in a dark region, as in a blink (sim/run.gd, the rules alone).

## One player watching a hunting Orderly 4 to 9 m off on the Clinic, with the shop (flashbulbs) and a DangerFloor.
static func _solo(seed: String) -> Run.RunState:
	for k in 30:
		var st := Watch.stage("%s-%d" % [seed, k], 1, Rng.make_rng("%s:%d" % [seed, k]), 1, 4.0, 9.0)
		if st.is_empty():
			continue
		var s := Run.with_shop(Run.with_inventory(Run.create_run("%s-%d" % [seed, k], ["p0"] as Array[String])))
		s.plan = st[0]
		s.orderly = st[1]
		s.players[0].body = (st[2] as Array)[0]
		s.phase = &"away"
		s.call = null
		s.lure = false
		return s
	return null

static func _with_dark(s0: Run.RunState) -> Run.RunState:
	var s := Dangers.with_dangers(s0, [&"test_tile"]).copy()
	var d := (s.dangers as DangerFx.DangerFloor).copy()
	var o := s.orderly.body
	d.dark = [[o.level, o.x - 2.0, o.z - 2.0, o.x + 2.0, o.z + 2.0, s.t + 30.0, 99, s.t - 1.0]]
	s.dangers = d
	return s

static func _with_blink(s0: Run.RunState) -> Run.RunState:
	var s := s0.copy()
	var b := Run.BlinkState.new()
	b.at = s.t
	b.len = 30.0
	b.warn = 0.0
	b.blackout = false
	b.announced = true
	b.ends_at = s.t + 30.0
	s.blink = b
	return s

static func _with_flash(s0: Run.RunState) -> Run.RunState:
	var s := s0.copy()
	var sh := (s.shop_state as Shop.ShopState).copy()
	sh.flashes = {"p0": s.t + Shop.FLASH_SECONDS}
	s.shop_state = sh
	return s

## How far the Orderly moves in `ticks` with p0 looking straight at it.
static func _moved(s0: Run.RunState, ticks: int) -> float:
	var s := s0
	var from := s.orderly.body
	var p := s.players[0].body
	for _k in ticks:
		var o := s.orderly.body
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p0", p, Bot.BOT_EYE, Entity.yaw_toward(o.x - p.x, o.z - p.z), 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)]
		s = Run.step_run(s, ins, DT).state
	return SO.flat(from, s.orderly.body)

func test_a_flash_and_a_steady_gaze_see_in_a_dark(t: T) -> void:
	var s := _solo("dg0d-flash")
	if not t.check(s != null, "a Clinic floor with a spot that sees the Orderly"):
		return
	t.check(_moved(s, 10) < 1e-6, "lit and watched: it holds")
	var in_dark := _moved(_with_dark(s), 10)
	t.check(in_dark > 0.1, "in a dark region, watched, no flash: it walks (%.3f m)" % in_dark)
	t.check(_moved(_with_blink(s), 10) > 0.1, "in a blink, the same (the rule it copies)")
	t.check(_moved(_with_flash(_with_blink(s)), 10) < 1e-6, "in a blink, a lit flash holds it")
	var flashed := _moved(_with_flash(_with_dark(s)), 10)
	t.check(flashed < 1e-6, "in a dark region, a lit flash holds it: 0 m moved (%.3f m)" % flashed)
	# Steady Gaze (prop_steady_gaze's stage: three players, p0 a Lamplighter whose lamp is on it, counting twice).
	var g := Gaze._stage()
	if not t.check(g != null, "a Steady Gaze stage"):
		return
	var gd := Run.step_run(_with_dark(g), Gaze._inputs(g), DT).state
	t.check(Array(gd.orderly.watchers) == ["p0", "p0"], "in a dark region, the Lamplighter's steady lamp counts twice (%s)" % str(gd.orderly.watchers))
	t.check(gd.orderly.held, "and holds it")
	var gb := Run.step_run(_with_blink(g), Gaze._inputs(g), DT).state
	t.check(gb.orderly.held, "as it does in a blink")
	# A closed door still hides it from the flash (the door's line is kept in the per-player blindness).
	t.check(FileAccess.get_file_as_string("res://sim/run.gd").contains("DangerFx.blinded(s.dangers, p.id, t) or (p.body.level == s.orderly.body.level and DangerFx.line_blocked("), "the Stillness step keeps the door's line for each player")

func test_the_host_takes_a_flash_holders_look_in_a_dark(t: T) -> void:
	var s := _with_dark(_solo("dg0d-host"))
	var host := Host.new(Transport.MemoryNetwork.new("dg0d-host").connect_peer("host"), "dg0d-host", ["p0"], 0.0)
	var hp := Host.HostPlayer.new()
	hp.id = "p0"
	hp.body = s.players[0].body
	t.check(host._danger_hides(s, hp), "in a dark region a plain look counts for nothing on the host")
	t.check(not host._danger_hides(_with_flash(s), hp), "with a lit flash it counts, as the rules' own sight does")
	var gz := s.copy()
	gz.orderly = s.orderly.copy()
	gz.orderly.watchers = ["p0", "p0"] as Array[String]
	t.check(not host._danger_hides(gz, hp), "with the host's Steady Gaze count it counts")
	var lit := Dangers.with_dangers(_solo("dg0d-host"), [&"test_tile"])
	t.check(not host._danger_hides(lit, hp), "out of any dark region it counts")
	var blinded := (s.dangers as DangerFx.DangerFloor).copy()
	blinded.fx = {"p0|blind": {"kind": &"blind", "until": s.t + 2.0, "body": null}}
	var sb := _with_flash(s)
	sb.dangers = blinded
	t.check(host._danger_hides(sb, hp), "a player a danger blinded sees nothing, flash or not")

# ---------------------------------------------------------------------------------------------
# 4. The near light.

func test_the_near_light_follows_a_dark_at_the_camera(t: T) -> void:
	var b := {"dark": [[0, 10.0, 10.0, 14.0, 20.0, 50.0, 40.0]]}
	var r := 4.0
	t.eq(DangersView.near_dark(b, 45.0, 0, Vector3(12.0, 1.6, 15.0), r), 1.0, "inside a live region: fully on")
	t.eq(DangersView.near_dark(b, 45.0, 0, Vector3(16.0, 1.6, 15.0), r), 1.0, "2 m from it (half the reach): fully on")
	t.check(absf(DangersView.near_dark(b, 45.0, 0, Vector3(17.0, 1.6, 15.0), r) - 0.5) < 1e-6, "3 m: half")
	t.eq(DangersView.near_dark(b, 45.0, 0, Vector3(18.0, 1.6, 15.0), r), 0.0, "at the reach: off")
	t.eq(DangersView.near_dark(b, 45.0, 1, Vector3(12.0, 1.6, 15.0), r), 0.0, "another level: off")
	t.eq(DangersView.near_dark(b, 39.0, 0, Vector3(12.0, 1.6, 15.0), r), 0.0, "before it is dark: off")
	t.eq(DangersView.near_dark(b, 50.0, 0, Vector3(12.0, 1.6, 15.0), r), 0.0, "once it is over: off")
	t.eq(DangersView.near_dark({}, 45.0, 0, Vector3(12.0, 1.6, 15.0), r), 0.0, "no block: off")
	var main := FileAccess.get_file_as_string("res://client/main.gd")
	t.check(main.contains("near = maxf(near, DANGER_DARK_NEAR * DangersView.near_dark(dangers_view.block, float(s.get(\"hostNow\", 0.0)), int(me.get(\"level\", 0)), cam.global_position, NEAR_LIGHT_REACH))"),
		"main.gd brings the near light on by it")
	t.check(main.contains("\tvar dark: bool = s[\"dark\"]\n"), "the rest of the blink (lamps, hum, name tags) still goes by the frame's dark alone")
	t.eq(KindView.NEAR_LIGHT_REACH, preload("res://client/main.gd").NEAR_LIGHT_REACH, "kind views know the near light's reach")
	var base := DangersView.new()
	var v := KindView.new()
	v.base = base
	t.eq(v.near_light_reach(), 0.0, "off: no reach")
	base.near_reach = 4.5
	base.near_at = Vector3(1.0, 2.0, 3.0)
	t.eq(v.near_light_reach(), 4.5, "a view reads the near light's reach now")
	t.eq(v.near_light_at(), Vector3(1.0, 2.0, 3.0), "and where it is")
	v.free()
	base.free()
