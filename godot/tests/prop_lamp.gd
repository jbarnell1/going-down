extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Lamp = preload("res://sim/lamp.gd")
const Seek = preload("res://sim/seek.gd")
const Places = preload("res://sim/places.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Move = preload("res://sim/move.gd")
const LampView = preload("res://client/lamp_view.gd")
const Profiles = preload("res://net/profiles.gd")
const Save = preload("res://net/save_slip.gd")

func test_battery_drains_only_while_on_and_empty_stays_empty(t: T) -> void:
	var base := Run.create_run("lamp-charge", ["a", "b"])
	var a := Cabinet.inp("a", base.players[0].body)
	var b := Cabinet.inp("b", base.players[1].body)
	a.inv_op = &"lamp"
	a.inv_arg = 1
	var off := Run.step_run(base, [a, b], Cabinet.DT)
	t.check(off.state.lamps.is_empty() and off.events.is_empty(), "disabled flag has no lamp response")
	var s := Run.with_lamp(base)
	var on := Run.step_run(s, [a, b], Cabinet.DT)
	t.eq(Cabinet.of_type(on.events, "lampSwitched").size(), 1, "fresh key request turns one lamp on")
	t.check(is_equal_approx(float(Run.lamp_of(on.state, "a").charge), Lamp.CHARGE - Cabinet.DT), "on drains host time")
	t.eq(Run.lamp_of(on.state, "b").charge, Lamp.CHARGE, "idle teammate does not drain")
	var repeat := Run.step_run(on.state, [a, b], Cabinet.DT)
	t.eq(Cabinet.of_type(repeat.events, "lampSwitched").size(), 0, "repeated target state is idempotent")
	var low: Dictionary = repeat.state.lamps["a"].duplicate()
	low.charge = 0.03
	repeat.state.lamps["a"] = low
	var empty := Run.step_run(repeat.state, [a, b], Cabinet.DT)
	t.check(not Run.lamp_of(empty.state, "a").on and Run.lamp_of(empty.state, "a").charge == 0.0, "depleted lamp always switches off")
	t.eq(Cabinet.of_type(empty.events, "lampEmpty").size(), 1, "one depletion event")
	var again := Run.step_run(empty.state, [a, b], Cabinet.DT)
	t.check(not Run.lamp_of(again.state, "a").on and Cabinet.of_type(again.events, "lampEmpty").is_empty(), "empty cannot be toggled on")
	b.inv_op = &"lamp"
	b.inv_arg = 1
	var lit_b := Run.step_run(again.state, [a, b], Cabinet.DT).state
	var charge_b := float(Run.lamp_of(lit_b, "b").charge)
	b.inv_arg = 0
	var paused := Run.step_run(lit_b, [a, b], Cabinet.DT).state
	t.eq(Run.lamp_of(paused, "b").charge, charge_b, "switch off pauses existing charge")

func test_practice_charge_and_late_view_keep_their_own_state(t: T) -> void:
	var ordinary := Run.with_lamp(Run.create_run("lamp-practice", ["a"], Places.BEFORE_ARBORETUM, true))
	var practice := Run.with_orientation(ordinary, true)
	var a := Cabinet.inp("a", practice.players[0].body)
	a.inv_op = &"lamp"
	a.inv_arg = 1
	var r := Run.step_run(practice, [a], Cabinet.DT)
	t.check(Run.lamp_of(r.state, "a").on and r.state.orientation_resume.lamps.is_empty(), "training demonstration draws from its own battery")
	var events: Array[Dictionary] = []
	var clinic := Run._leave_orientation(r.state, r.state.players, r.state.t, events)
	t.check(clinic.lamp and clinic.lamps.is_empty(), "ordinary Clinic still starts with an unused battery")
	var net := Transport.MemoryNetwork.new("lamp-late")
	var host := Host.new(net.connect_peer("host"), "lamp-late", ["a"], 0.0)
	t.check(not host.world().has("lamps"), "flag off sends no lamp field")
	host.state = r.state
	var pkt := Protocol.encode({"type": "welcome", "you": "a", "seed": practice.seed, "playing": true, "evFrom": 0, "world": host.world()})
	var read: Variant = Protocol.decode(pkt)
	if not t.check(read != null and read.world.lamps[0].on, "a new observer receives the accepted beam in welcome"):
		return
	var world := Node3D.new()
	var view := LampView.new()
	view.update(world, read.world.lamps, "guest")
	t.check(view.beams.has("a") and view.own.is_empty(), "the guest sees the other lamp without inheriting its charge")
	world.free()
	view.free()

func test_paid_morning_and_same_signed_player_keep_used_charge(t: T) -> void:
	var s := Run.with_lamp(Run.create_run("lamp-persist", ["a"], Places.BEFORE_ARBORETUM, true))
	var key := PackedByteArray()
	key.resize(32)
	var profiles := Profiles.new(key)
	var stamp := Save.seal(Save.fresh("1234567890abcdef"), key)
	profiles.join("a", "Ana", stamp)
	s = profiles.apply_for(s, "a", "Ana")
	var i := Cabinet.inp("a", s.players[0].body)
	i.inv_op = &"lamp"
	i.inv_arg = 1
	var used := Run.step_run(s, [i], Cabinet.DT).state
	var charge := float(Run.lamp_of(used, "a").charge)
	var events: Array[Dictionary] = []
	Run._settle_day(used, used.t, 800, events, false)
	Run._arrive_home(used, used.players, used.t, events)
	Run._morning(used, used.players, used.t, events)
	t.check(used.day_index == 2 and is_equal_approx(float(Run.lamp_of(used, "a").charge), charge), "paid floor transition preserves used charge")
	profiles.leave("a")
	profiles.join("rejoined", "Ana", stamp)
	used = profiles.apply_for(used, "rejoined", "Ana")
	t.check(is_equal_approx(float(Run.lamp_of(used, "rejoined").charge), charge), "same signed identity does not get a fresh battery on reconnect")

func test_playroom_uses_the_real_carried_cone_only_when_aimed(t: T) -> void:
	var ids: Array[String] = ["a"]
	var rules := HostRules.new(true, 4, Places.FULL)
	var s := Run.with_lamp(rules.prepare(Run.create_run("lamp-playroom", ids)))
	s.phase = &"away"
	Run._sync_seek(s)
	var target: Move.Body = s.seek.minder.body
	for dir: Vector2 in [Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP]:
		var body := Move.Body.make(target.x + 1.5 * dir.x, target.z + 1.5 * dir.y, target.level, target.y)
		var yaw := atan2(dir.x, dir.y)
		if not Seek.lights(s.plan, Lamp.beam(s.tuning, body, 1.2, yaw, 0.0), target):
			continue
		var actors: Array[Run.RunPlayer] = [s.players[0].copy()]
		actors[0].body = body
		actors[0].aboard = false
		var i := Cabinet.inp("a", body)
		i.eye = 1.2
		i.gait = &"creep"
		i.inv_op = &"lamp"
		i.inv_arg = 1
		var aimed := s.copy()
		var events: Array[Dictionary] = []
		i.yaw = yaw
		Run._step_lamps(aimed, actors, {"a": i}, Cabinet.DT, Cabinet.DT, events)
		Run._step_seek(aimed, actors, {"a": i}, "", 0.0, Cabinet.DT, Cabinet.DT, events)
		t.eq(Cabinet.of_type(events, "count").size(), 1, "the existing Minder rule reacts to the carried beam")
		i.yaw += PI
		events.clear()
		var away := s.copy()
		Run._step_lamps(away, actors, {"a": i}, Cabinet.DT, Cabinet.DT, events)
		Run._step_seek(away, actors, {"a": i}, "", 0.0, Cabinet.DT, Cabinet.DT, events)
		t.check(Cabinet.of_type(events, "count").is_empty(), "aiming away does not trigger the existing light rule")
		return
	t.check(false, "the fixture found a clear line to the Minder")
