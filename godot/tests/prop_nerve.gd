extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Transport = preload("res://net/transport.gd")
const Profiles = preload("res://net/profiles.gd")
const Save = preload("res://net/save_slip.gd")

static func fixture(nearby := false) -> Run.RunState:
	var s := Run.create_run("nerve-preview", ["A", "B"], [Places.CLINIC])
	s.nerve_passive = true
	s.players[0].body = Move.Body.make(20, 20, 0, 0)
	s.players[1].body = Move.Body.make(28 if nearby else 32, 20, 0, 0)
	s.nerve_readings = {"A": 70.0, "B": 70.0}
	s.phase = &"away"
	return s

static func eyes(id: String, body: Move.Body) -> Run.PlayerInput:
	return Run.PlayerInput.make(id, body, 1.65, 0, 0, 90, 70)

static func input_rows(s: Run.RunState) -> Array[Run.PlayerInput]:
	return [eyes("A", s.players[0].body), eyes("B", s.players[1].body)]

func test_dark_drains_only_on_live_blink_and_cannot_down(t: T) -> void:
	var s := fixture()
	s.seek_off = true
	s.blink = Run.BlinkState.new()
	s.blink.announced = true
	s.blink.at = s.t + 2.0
	s.blink.len = 4.0
	var warning := Run.step_run(s, input_rows(s), 1.0).state
	t.eq(Run.nerve_of(warning, "A"), 70.0, "single lit player does not restore or drain during warning")
	s.blink.ends_at = s.t + 4.0
	var dark := Run.step_run(s, input_rows(s), 1.0).state
	t.check(is_equal_approx(Run.nerve_of(dark, "A"), 67.0), "real active blink drains three points per second")
	t.eq(s.nerve_readings.A, 70.0, "tick does not mutate the earlier reading")
	s.nerve_readings = {"A": 0.1, "B": 15.0}
	var zero := Run.step_run(s, input_rows(s), 1.0).state
	t.eq(Run.nerve_of(zero, "A"), 0.0, "darkness cannot drain below zero")
	t.eq(zero.players[0].status, &"ok", "zero nerve cannot catch or down a player")

func test_distance_restoration_movement_and_distinct_players(t: T) -> void:
	var s := fixture(true)
	s.orderly.body = Move.Body.make(12, 20, 0, 0)
	var next := s.copy()
	Run._step_nerve(s, next, {"A": eyes("A", s.players[0].body), "B": eyes("B", s.players[1].body)}, 1.0)
	t.eq(Run.nerve_of(next, "A"), 69.0, "eight metres counts, nearby resident drains two, stationary crew restores one")
	t.eq(Run.nerve_of(next, "B"), 71.0, "the peer's different distance yields its own one-point recovery")
	var moved := next.copy()
	moved.players = [s.players[0].copy(), s.players[1].copy()]
	moved.players[0].body = Move.Body.make(20, 20.2, 0, 0)
	s.seek_off = true
	moved.seek_off = true
	Run._step_nerve(s, moved, {"A": eyes("A", moved.players[0].body), "B": eyes("B", moved.players[1].body)}, 1.0)
	t.eq(Run.nerve_of(moved, "A"), 70.0, "moving near crew does not restore")
	s.nerve_readings = {"A": 99.5, "B": 99.5}
	var topped := Run.step_run(s, input_rows(s), 1.0).state
	t.eq(Run.nerve_of(topped, "A"), 100.0, "recovery stays within full")

func test_temp_uses_its_own_company_test_and_safe_ride_resets(t: T) -> void:
	var s := Run.create_run("nerve-temp", ["A"], [Places.ANNEX])
	s = Run.with_lonely(s)
	s.nerve_passive = true
	s.phase = &"away"
	s.players[0].body = Move.Body.make(s.car.door_x - s.car.in_x * 4, s.car.door_z - s.car.in_z * 4, 0, 0)
	s.orderly.body = Move.Body.make(s.players[0].body.x + 20, s.players[0].body.z, 0, 0)
	var next := s.copy()
	Run._step_nerve(s, next, {"A": eyes("A", s.players[0].body)}, 1.0)
	t.eq(Run.nerve_of(next, "A"), 99.0, "unaccompanied Temp target loses one point")
	next.phase = &"riding"
	next.timer = 2.0
	var riding := Run.step_run(next, [eyes("A", next.players[0].body)], 0.1).state
	t.eq(Run.nerve_of(riding, "A"), 100.0, "lift ride refills the reading")
	t.check(riding.nerve_readings.is_empty(), "the old floor's readings are discarded on the ride")
	riding.orientation = true
	t.check(not Run.shows_nerve(riding), "safe practice hides the preview")

func test_off_wire_and_hud_use_the_same_rates(t: T) -> void:
	var off := HostRules.new(true, 1).prepare(Run.create_run("nerve-off", ["A"]))
	var net := Transport.MemoryNetwork.new("nerve-off")
	var host := Host.new(Transport.MemoryTransport.new(net, "host"), "nerve-off", ["A"], 0.0)
	host.state = off
	var shared := host.world()
	t.check(Run.nerve_of(off, "A") == 0.0 and off.nerve_readings.is_empty(), "default run has no nerve state")
	t.check(Protocol.enc_world(shared).size() <= Protocol.WORLD_FLOOR_EXTENSIONS_INDEX, "default world has no added tail")
	shared["medic"] = {"A": 2}
	shared["nerve"] = Run.Nerve.view(72.125)
	var wire := Protocol.encode({"type":"welcome", "you":"A", "seed":"nerve-off", "playing":true, "evFrom":1, "world":shared})
	var packet: Variant = Protocol.decode(wire)
	if not t.check(packet != null, "actual welcome accepts the bounded named block"):
		return
	t.eq(packet.world.medic, {"A": 2}, "Medic's named extension survives alongside the bar")
	t.eq(packet.world.nerve, [72.125, -3.0, -2.0, -1.0, 1.0, -15.0, 0.0], "rates and reading survive canonical wire encoding")
	var hud := Hud.new()
	t.check(hud.nerve_lines().is_empty(), "flag off omits all lines")
	hud.nerve = packet.world.nerve
	t.eq(hud.nerve_lines(), PackedStringArray(["NERVE 73/100", "DARK -3/S  RESIDENT -2/S", "APART -1/S  WITH CREW +1/S", "SEE A CATCH -15"]), "HUD prints the host's exact rules")
	hud.free()
	shared["nerve"][0] = 101.0
	var bad := Protocol.encode({"type":"welcome", "you":"A", "seed":"nerve-off", "playing":true, "evFrom":1, "world":shared})
	t.check(Protocol.decode(bad) == null, "out-of-range reading is rejected on the wire")

func test_exact_recipient_and_signed_profile_unchanged(t: T) -> void:
	var s := fixture()
	s.nerve_readings = {"A": 38.0, "B": 84.0}
	var net := Transport.MemoryNetwork.new("nerve-recipients")
	var host := Host.new(Transport.MemoryTransport.new(net, "host"), s.seed, ["A", "B"], 0.0)
	host.state = s
	var a := Host.HostPlayer.new()
	a.id = "A"
	a.in_run = true
	var b := Host.HostPlayer.new()
	b.id = "B"
	b.in_run = true
	var shared := host.world()
	t.check(not shared.has("nerve"), "a shared world has no private owner readings")
	t.eq(host._world_for(shared, a).nerve, Run.Nerve.view(38), "first recipient receives just their own reading")
	t.eq(host._world_for(shared, b).nerve, Run.Nerve.view(84), "other recipient receives just their own reading")
	b.in_run = false
	t.check(not host._world_for(shared, b).has("nerve"), "spectator receives no reading")
	var key := PackedByteArray()
	key.resize(32)
	var initial := Save.fresh("a0123456789bcdef")
	var with_bar := Save.seal(Profiles.collect(s, "A", initial, "Nurse", false), key)
	s.nerve_passive = false
	s.nerve_readings = {}
	var without_bar := Save.seal(Profiles.collect(s, "A", initial, "Nurse", false), key)
	t.check(not with_bar.is_empty(), "produced a signed profile")
	t.eq(with_bar, without_bar, "passive floor data never changes signed progression")
