# A helper for tests/prop_cycles.gd and tests/test_cycle_entry.gd (FL2, cycles), not a test file itself.
#
# Crew: the real host and real clients over a seeded in-memory link (as tests/prop_late_floors.gd), with the rules
# given, so the bodies the test sets are what the host accepts. Every host tick's world text and every logged
# event are kept, so a run can be compared tick for tick.
#
# flag_off_digest(): a seeded run with the late floors on and cycles off, through floor 5, the Hanging Ward at 6 and
# its ride home, the next morning, and (a second run) the Reactor at 7 and its ride home. It uses nothing newer
# than commit 1013e52, so the same function was run on that commit to record prop_cycles.gd BASE_DIGEST.
extends RefCounted

const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")
const Protocol = preload("res://net/protocol.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const ReactorState = preload("res://sim/reactor.gd")

class Crew:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var clients: Array[Client] = []
	var names: Array[String] = []
	var bodies: Array[Vector3] = []
	var held: Array[bool] = []
	var now := 0.0
	## One line per host tick: the tick and the sha256 of its world text.
	var ticks: PackedStringArray = PackedStringArray()

	func _init(seed: String, rules_: HostRules, crew: Array[String], late: bool, archive := "") -> void:
		rules = rules_
		names = crew
		for id in names:
			bodies.append(Vector3.ZERO)
			held.append(false)
		net = Transport.MemoryNetwork.new(seed)
		host = Host.new(net.connect_peer("host"), seed, names, now, Callable(rules, "prepare"), Callable(rules, "step"), names)
		for id in names:
			clients.append(Client.new(net.connect_peer(id), "host", id, now))
		if late:
			host.enable_late_floors(archive)

	func tick_for(seconds: float, until: Callable = Callable()) -> bool:
		for frame in ceili(seconds / 0.025):
			now += 0.025
			net.now = now
			for i in clients.size():
				var c := clients[i]
				c.receive(now)
				var local := Client.LocalFrame.new()
				local.body = Move.Body.make(bodies[i].x, bodies[i].z, 0, bodies[i].y)
				local.use = held[i]
				c.frame(now, local)
			var before := host.tick
			host.update(now)
			if host.tick != before:
				ticks.append("%d %s" % [host.tick, Protocol.world_json(host.world()).sha256_text()])
			if until.is_valid() and until.call():
				return true
		return false

	func everyone_at(at: Vector3) -> void:
		for i in bodies.size():
			bodies[i] = at

	## Every player onto their own bunk holding F (bed, then lights out, then the morning).
	func to_bed() -> void:
		var ids: Array[String] = []
		for p in host.state.players:
			ids.append(p.id)
		for i in names.size():
			var bunk := Run.bunk_body(host.state.plan, ids, names[i])
			bodies[i] = Vector3(bunk.x, bunk.y, bunk.z)
			held[i] = true

	## Every event the host logged, as text, in order.
	func log_text() -> String:
		var out := PackedStringArray()
		for row in host.event_log:
			out.append(row.text)
		return "\n".join(out)

## The car leaves for the floor below now (the real arrival code runs on the next tick).
static func ride_down(host: Host) -> void:
	var s := host.state.copy()
	s.phase = &"riding"
	s.going_up = false
	s.timer = 0.0
	host.state = s

## The Hanging Ward's lift, run quickly: off the lift until it has gone, back the moment it returns, then away.
## `stay_out`: indexes of the crew who are not aboard when it leaves.
static func ward_round(crew: Crew, stay_out: Array[int] = []) -> void:
	var ward: Variant = crew.host._ward_review
	crew.everyone_at(ward.lift_door() + Vector3(0, 0, 1.2))
	crew.tick_for(20.0)
	ward.collection_at = crew.host.state.t + 0.3
	crew.everyone_at(ward.lift_door() + Vector3(0, 0, -1.0))
	for i in stay_out:
		crew.bodies[i] = ward.lift_door() + Vector3(0, 0, 6.0)
	crew.tick_for(1.0)
	ward.depart_at = crew.host.state.t + 0.3

## The Reactor's floor, done: the power back, everyone up, the tape carried, the lift called by the second player.
static func reactor_round(crew: Crew) -> void:
	var review: Variant = crew.host._reactor_review
	crew.everyone_at(review.rules.fuse)
	crew.tick_for(3.0)
	review.rules.power = ReactorState.Power.RESTORED
	review.rules.down_time.clear()
	for id: int in review.rules.condition:
		review.rules.condition[id] = "up"
	review.rules.recovery.clear()
	for i in crew.held.size():
		crew.held[i] = false
	crew.everyone_at(review.rules.cassette_at)
	crew.tick_for(0.3)
	crew.held[0] = true
	crew.tick_for(0.3)
	crew.held[0] = false
	crew.everyone_at(Vector3(0, 0, 9.3))
	crew.tick_for(0.3)
	crew.held[mini(1, crew.held.size() - 1)] = true

## See the header. Two seeded runs, flag off; returns the sha256 of every tick's world and every event.
static func flag_off_digest() -> String:
	var parts := PackedStringArray()
	# The Ward: floor 5, down to 6, the lift there and back, home, bed, the morning at floor 1.
	var a := Crew.new("cycles-off-ward", HostRules.new(true, 5, Places.FULL, true), ["one", "two"] as Array[String], true)
	a.tick_for(1.0)
	ride_down(a.host)
	a.tick_for(0.5)
	ward_round(a)
	a.tick_for(15.0, func() -> bool: return a.host.state.depth == 0)
	a.tick_for(2.0)
	a.to_bed()
	a.tick_for(90.0, func() -> bool: return a.host.state.depth >= 1)
	a.tick_for(1.0)
	parts.append("\n".join(a.ticks))
	parts.append(a.log_text())
	# The Reactor: floor 6 already handled (no Ward on it, as tests/prop_late_floors.gd does), down to 7, home.
	# RX1 (net/reactor_review.gd rx1) changed the Reactor floor itself after 1013e52. It is off for this part,
	# so the digest still pins the cycles flag alone against that commit.
	var review_script: Script = load("res://net/reactor_review.gd")
	review_script.set("rx1", false)
	var b := Crew.new("cycles-off-reactor", HostRules.new(true, 6, Places.FULL, true), ["one", "two"] as Array[String], false)
	b.host.late_floors = true
	b.host._late_plan = b.host.state.plan
	b.tick_for(0.5)
	ride_down(b.host)
	b.tick_for(0.5)
	reactor_round(b)
	b.tick_for(3.0, func() -> bool: return b.host.state.depth == 0)
	b.tick_for(2.0)
	review_script.set("rx1", true)
	parts.append("\n".join(b.ticks))
	parts.append(b.log_text())
	return "%d/%d %s" % [a.ticks.size(), b.ticks.size(), "\n".join(parts).sha256_text()]
