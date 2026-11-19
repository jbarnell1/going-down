extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Cabinet = preload("res://tests/prop_cabinet.gd")
const Move = preload("res://sim/move.gd")
const Inventory = preload("res://sim/inventory.gd")
const Entity = preload("res://sim/entity.gd")
const Host = preload("res://net/host.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const FlareView = preload("res://client/flare_view.gd")

func test_practice_uses_real_stock_once_and_stops_the_safe_target(t: T) -> void:
	var ids: Array[String] = ["a"]
	var normal := Run.create_run("flare-practice", ids)
	var off := Run.with_orientation(normal)
	t.check(not off.inventory and not off.flare, "off retains the old practice inventory")
	var s := Run.with_orientation(Run.with_flare(normal))
	s.phase = &"away"
	var p := s.orderly.body
	var at := Move.Body.make(p.x, p.z + 1.6, 0, p.y)
	var i := Cabinet.inp("a", at)
	i.yaw = PI
	i.blind = true
	var stocked := Run.step_run(s, [i], Cabinet.DT).state
	t.eq(Inventory.bag_of(stocked.bags, "a").totals(), {"flare": 1}, "one actual inventory item")
	var before := stocked.orderly.body
	i.inv_op = &"use"
	var burst := Run.step_run(stocked, [i], Cabinet.DT)
	var cues := Cabinet.of_type(burst.events, "flareUsed")
	if not t.check(cues.size() == 1 and cues[0].stunned and cues[0].noise > 18.0, "the placed burst loudly stuns"):
		return
	t.check(burst.state.orderly.frozen and not burst.state.orderly.seen and not burst.state.orderly.moving, "stun does not invent a watcher")
	t.eq(burst.state.orderly.body, before, "target remains where it was")
	t.check(Inventory.bag_of(burst.state.bags, "a").is_empty(), "actual item consumed")
	var repeat := Run.step_run(burst.state, [i], Cabinet.DT)
	t.eq(Cabinet.of_type(repeat.events, "flareUsed").size(), 0, "repeat without stock cannot fire again")
	var resumed := repeat.state
	for _k in 43:
		resumed = Run.step_run(resumed, [i], Cabinet.DT).state
	t.check(not Run.flare_stunned(resumed, resumed.t) and resumed.orderly.body != before, "safe look-away movement resumes when the stun ends")
	t.eq(resumed.players[0].status, &"ok", "practice leaves the player unharmed")

func test_teammate_hit_is_a_wasted_flare_visible_to_a_late_observer(t: T) -> void:
	var s := Run.with_orientation(Run.with_flare(Run.create_run("flare-friend", ["a", "b"])))
	s.phase = &"away"
	var p := s.orderly.body
	var a := Cabinet.inp("a", Move.Body.make(p.x, p.z + 3.0, 0, p.y))
	var b := Cabinet.inp("b", Move.Body.make(p.x, p.z + 2.0, 0, p.y))
	a.yaw = 0.0
	a.blind = true
	b.blind = true
	a.inv_op = &"use"
	var fired := Run.step_run(s, [a, b], Cabinet.DT)
	var bursts := Cabinet.of_type(fired.events, "flareUsed")
	if not t.check(bursts.size() == 1 and bursts[0].blind == "b" and not bursts[0].stunned, "aiming at a teammate wastes that use"):
		return
	t.check(Run.flare_blinded(fired.state, "b", fired.state.t) and not Run.flare_blinded(fired.state, "a", fired.state.t), "only the struck teammate is blinded")
	t.eq(Inventory.bag_of(fired.state.bags, "b").totals(), {"flare": 1}, "a teammate cannot spend your stock")
	var net := Transport.MemoryNetwork.new("flare-late")
	var host := Host.new(net.connect_peer("host"), "flare-late", ["a", "b"], 0.0)
	t.check(not host.world().has("flares"), "disabled host sends no new state")
	host.state = fired.state
	var pkt := Protocol.encode({"type": "welcome", "you": "b", "seed": s.seed, "playing": true, "evFrom": 0, "world": host.world()})
	var read: Variant = Protocol.decode(pkt)
	if not t.check(read != null and read.world.flares.size() == 1, "late welcome carries the current burst independently of past events"):
		return
	var world := Node3D.new()
	var view := FlareView.new()
	view.update(world, read.world.flares, "b", fired.state.t)
	t.check(view.lights.size() == 1 and view.blind > 0.0, "late teammate sees the burst and their remaining blind")
	view.update(world, read.world.flares, "a", fired.state.t)
	t.eq(view.blind, 0.0, "observer sees light without blindness")
	world.free()
	view.free()

func test_ordinary_orderly_stops_without_damage_or_extra_watchers(t: T) -> void:
	var s := Run.with_flare(Run.create_run("flare-clinic", ["a"]))
	s.phase = &"away"
	s.orderly.mode = &"hunting"
	var p := s.orderly.body
	var i := Cabinet.inp("a", Move.Body.make(p.x, p.z + 2.4, p.level, p.y))
	i.yaw = 0.0
	i.blind = true
	i.inv_op = &"use"
	var r := Run.step_run(s, [i], Cabinet.DT)
	var cues := Cabinet.of_type(r.events, "flareUsed")
	t.check(cues.size() == 1 and cues[0].stunned, "ordinary item and input stun the Clinic resident")
	t.check(r.state.orderly.frozen and not r.state.orderly.seen and not r.state.orderly.moving, "ordinary stun still records the real watch state")
	t.eq(r.state.orderly.body, p, "authoritative body stops at its start position")
	t.eq(r.state.players[0].status, &"ok", "use has no damage effect")
