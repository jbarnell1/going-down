extends RefCounted

const T = preload("res://tests/t.gd")
const State = preload("res://sim/reactor.gd")
const GameRun = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const GameLocal = preload("res://net/local_room.gd")
const Protocol = preload("res://net/protocol.gd")
const Wire = preload("res://net/reactor_wire.gd")

func test_reactor_round_trip_and_malformed_blocks(t: T) -> void:
	var room := State.new(1.0,Vector3(-6,1,-5),Vector3(-3,1,5))
	room.observe(12,Vector3(0,0,3))
	var seats := []
	for i in 4:
		seats.append([i,0,-3,0,0,"still",0.0])
	var state := room.snapshot(seats,23)
	state.low = {"12":false}
	var encoded := Wire.encode(state)
	var envelope := {"ward":[],"reactor":encoded}
	var world: Array = []
	world.resize(29)
	world[27] = ["shop"]
	world[28] = envelope
	var received: Dictionary = Wire.decode(world[28].reactor)
	t.check(world[27]==["shop"] and world[28].ward==[],"shop at 27 and Ward sibling remain independent")
	t.check(received.power==0 and received.crew==seats and received.players==state.players,"valid block preserves corpses, players and power; sibling is independent")
	t.check(Wire.decode(encoded.slice(0,13))==null,"truncated nested reactor block refused")
	var missing_pose := encoded.duplicate(true)
	missing_pose[12].pop_back()
	t.check(Wire.decode(missing_pose)==null,"exactly four poses required")
	var bad_phase := encoded.duplicate(true)
	bad_phase[12][2][5]=99
	t.check(Wire.decode(bad_phase)==null,"unknown animation refused")
	var bad_clock := encoded.duplicate(true)
	bad_clock[5]=INF
	t.check(Wire.decode(bad_clock)==null,"nonfinite host time refused")
	var duplicate := encoded.duplicate(true)
	duplicate[13].append(duplicate[13][0])
	t.check(Wire.decode(duplicate)==null,"duplicate player identifier refused")

func test_single_consumption_revive_and_drop(t: T) -> void:
	var fuse := Vector3(-6,0,-5)
	var breaker := Vector3(-3,0,5)
	var room := State.new(1,fuse,breaker)
	room.observe(1,fuse)
	room.observe(2,fuse)
	t.check(room.use(1)=="fuse" and room.use(2)=="","one peer takes the shared item")
	t.check(room.down(1) and room.condition[2]=="up","only contacted target goes down")
	t.check(room.use(2)=="fuse","other peer recovers dropped fuse")
	room.rescue(2,true,3.01)
	t.check(room.condition[1]=="up","continuous three second use revives")
	t.check(not room.down(1),"just-healed player has a personal recovery window")
	room.observe(2,breaker)
	t.check(room.use(2)=="installed" and room.use(2)=="" and room.fuse_uses==1,"one installation restores power")
	room.tick(20.0)
	t.check(room.power==State.Power.RESTORED and room.awake_seconds>=20,"restoration never resets the crew clock")


func test_game_host_review_entry_and_teardown(t: T) -> void:
	var room := GameLocal.new()
	room.open_local("reactor-owner","Tester",false)
	room.start_run()
	t.check(not room.host.world().has("reactor"),"ordinary local room omits optional reactor world")
	t.check(room.start_reactor_review(23),"explicit local playtest entry constructs the game host")
	for i in 8: room.poll(i*.05)
	var host := room.host
	t.check(host.world().has("reactor"),"game Host.world carries the optional review field")
	var review := host._reactor_review
	# The power hold (RX1) is its own test below; this one checks other rules, so the cut comes at the line.
	review.rules.power_hold = 0.0
	var me: String = room.ME
	var input := GameRun.PlayerInput.new()
	input.id = me
	input.gait = &"walk"
	var inputs: Array[GameRun.PlayerInput] = [input]
	var start: Vector3 = review.rules.fuse
	input.body = Move.Body.make(start.x,start.z,0,0)
	input.use = true
	host._step_reactor_review(host.state,inputs)
	var state: Dictionary = host.world().reactor
	t.check(state.power==1 and state.holder==me and state.players.has(me),"host resolves use from the actual game player id and accepted body")
	t.check(Wire.decode(Wire.encode(state)).holder==me,"wire preserves native string player id when carrying")
	input.use = false
	var breaker: Vector3 = review.rules.breaker
	input.body = Move.Body.make(breaker.x,breaker.z-0.9,0,0)
	host._step_reactor_review(host.state,inputs)
	input.use = true
	host._step_reactor_review(host.state,inputs)
	state=host.world().reactor
	t.check(state.power==2 and state.fuseUses==1,"existing game use input installs once")
	input.use = false
	input.body = Move.Body.make(0,9.3,0,0)
	host._step_reactor_review(host.state,inputs)
	input.use = true
	host._step_reactor_review(host.state,inputs)
	input.use = false
	t.check(host.world().reactor.lift,"game host accepts return after repair")
	for step in 300: host._step_reactor_review(host.state,inputs)
	state=host.world().reactor
	t.check(state.crew.all(func(a: Array) -> bool: return a[5]=="zombie_run"),"four game-host pursuit clocks progress after restoration")
	room.start_run()
	t.check(not room.host.world().has("reactor"),"ordinary restart releases the special-floor state")
	room.leave()

func test_campaign_archive_bank_loss_persistence_and_replay(t: T) -> void:
	var directory := "user://test-reactor-archive/"+str(Time.get_ticks_usec())
	var station := preload("res://net/reactor_review.gd").new(23,directory)
	# The power hold (RX1) is its own test below; this one checks other rules, so the cut comes at the line.
	station.rules.power_hold = 0.0
	var same := preload("res://net/reactor_review.gd").new(23)
	var different := preload("res://net/reactor_review.gd").new(24)
	t.check(station.rules.cassette_at==same.rules.cassette_at and station.rules.cassette_at!=different.rules.cassette_at,"seed selects reproducible tape position on the landing")
	station.player("A",station.rules.cassette_at,true,&"walk",.05)
	station.player("B",station.rules.cassette_at,true,&"walk",.05)
	t.check(station.snapshot().cassetteHolder=="A","simultaneous use produces exactly one real carrier")
	station.player("B",station.rules.fuse,false,&"walk",.05)
	station.rules.down(station.seats.A)
	t.check(station.snapshot().cassetteHolder=="" and not station.rules.collected,"down drops physical cassette")
	station.player("B",station.rules.cassette_at,true,&"walk",.05)
	t.check(station.snapshot().cassetteHolder=="","the dropped cassette remains during rescue")
	station.player("B",station.rules.cassette_at,true,&"walk",3.0)
	station.player("B",station.rules.cassette_at,false,&"walk",.05)
	station.player("B",station.rules.cassette_at,true,&"walk",.05)
	t.check(station.snapshot().cassetteHolder=="B","other crew member recovers the dropped cassette")
	station.leave_missing({"A":true})
	t.check(not station.rules.collected and not station.archive.recovered,"disconnected carrier returns cassette to the station")
	station.rules.power=State.Power.RESTORED
	station.player("C",Vector3(0,0,9),true,&"walk",.05)
	station.tick(.05)
	t.check(station.rules.returned and not station.archive.recovered,"escaping without recovered tape cannot bank it")
	var left := preload("res://net/reactor_review.gd").new(23)
	left.player("carrier",left.rules.cassette_at,true,&"walk",.05)
	left.rules.power=State.Power.RESTORED
	left.player("caller",Vector3(0,0,9),true,&"walk",.05)
	left.tick(.05)
	t.check(left.rules.returned and not left.archive.recovered,"calling inside cannot bank a carrier outside the car")
	var rollback := preload("res://net/reactor_review.gd").new(23,directory)
	t.check(not rollback.rules.collected,"missed tape reappears next visit")
	rollback.player("A",rollback.rules.cassette_at,true,&"walk",.05)
	rollback.player("A",Vector3(0,0,9),false,&"walk",.05)
	rollback.rules.power=State.Power.RESTORED
	rollback.player("A",Vector3(0,0,9),true,&"walk",.05)
	rollback.tick(.05)
	t.check(rollback.archive.recovered and not rollback.archive.discovered,"extraction banks tape without awarding screening")
	t.check(rollback.screening("A","watch",0),"prison opens recovered tape")
	var packet := Wire.encode(rollback.snapshot())
	packet[-1][4] = {"intruder":1}
	t.check(Wire.decode(packet)==null,"screening ticket must belong to a current peer")
	var ticket: int = rollback.archive.tickets.A.ticket
	t.check(not rollback.screening("A","end",ticket),"early finish never awards story")
	t.check(rollback.screening("A","skip",ticket) and not rollback.archive.discovered,"skip remains undiscovered")
	rollback.screening("A","watch",0)
	ticket=rollback.archive.tickets.A.ticket
	rollback.rules.tick(52)
	t.check(rollback.screening("A","end",ticket) and not rollback.screening("A","end",ticket),"natural end with valid session awards once")
	var reloaded := preload("res://net/reactor_review.gd").new(24,directory)
	t.check(reloaded.archive.recovered and reloaded.archive.discovered and reloaded.rules.collected,"fresh host instance reloads archive and suppresses duplicate physical cassette")
	reloaded.rules.power=State.Power.RESTORED
	reloaded.player("R",Vector3(0,0,9),true,&"walk",.05)
	t.check(reloaded.screening("R","watch",0),"discovered tape can replay after restart")
	for marker: String in ["crew23.seen","crew23.recovered"]:
		DirAccess.remove_absolute(directory.path_join(marker))
	DirAccess.remove_absolute(directory)



func test_held_use_waits_for_accepted_body(t:T) -> void:
	var station := preload("res://net/reactor_review.gd").new(23)
	station.rules.power=State.Power.RESTORED
	station.rules.collected = true
	station.player("A",Vector3(0,0,6.32),true,&"sprint",.05)
	t.check(not station.rules.returned,"early delivery of held E cannot extract from outside")
	station.player("A",Vector3(0,0,8.22),true,&"sprint",.05)
	t.check(station.rules.returned,"same held input extracts when the server accepts the body inside")
	var with_tape := preload("res://net/reactor_review.gd").new(23)
	with_tape.rules.power = State.Power.RESTORED
	with_tape.player("A",with_tape.rules.cassette_at,true,&"sprint",.05)
	t.check(not with_tape.rules.returned,"taking the cassette cannot phone the lift from the landing")
	with_tape.player("A",Vector3(0,0,8.22),true,&"sprint",.05)
	t.check(with_tape.rules.returned and with_tape.rules.extracted,"an accepted landing pickup cannot consume the lift request after the body has boarded")

func test_actual_game_envelope_preserves_shop_and_ward(t: T) -> void:
	var room := GameLocal.new()
	room.open_local("reactor-envelope","Tester",false)
	room.start_run()
	var base := room.host.world()
	base.erase("shop")
	var legacy := Protocol.enc_world(base)
	var shop := {"credits":[{"playerId":"one","credits":125}],"cabinets":[],"glows":[],"toys":[],"timers":[],"wake":-1.0}
	var ward := {"collectionAt":0.0,"departAt":3.0,"bridgeLowered":false,"phase":"away","house":-1,"startedAt":0.0,"encounter":"idle","armPoints":[],"doors":[false,false,false,false,false,false,false,false],"boarded":[],"leftBehind":[],"seed":51,"caught":[]}
	var rx := preload("res://net/reactor_review.gd").new(23).snapshot()
	for mask in 8:
		var variant := base.duplicate()
		if mask & 1: variant["shop"] = shop
		if mask & 2: variant["ward"] = ward
		if mask & 4: variant["reactor"] = rx
		var encoded := Protocol.enc_world(variant)
		var parsed: Variant = Protocol.decode(JSON.stringify([1,"W","one","seed",1,1,encoded]))
		t.check(parsed!=null,"all eight optional feature combinations decode")
		if parsed==null: continue
		if mask==0: t.eq(encoded,legacy,"disarmed room keeps original shape and values")
		if mask & 1: t.eq(parsed.world.shop.credits[0].credits,125,"shop keeps its actual nonempty credit row")
		if mask & 6:
			t.eq(encoded.size(),29,"keyed floor dictionary sits at index 28")
			t.eq(parsed.world.has("ward"),bool(mask&2),"Ward stays independent")
			t.eq(parsed.world.has("reactor"),bool(mask&4),"reactor stays independent")
			if not mask&1: t.check(encoded[27]==null,"floor-only room leaves shop empty")
		if mask & 4: t.eq(parsed.world.reactor.crew.size(),4,"normal game decoder reads all four seats")
		if mask==7:
			encoded[28].reactor.pop_back()
			encoded[28].reactor.pop_back()
			t.check(Protocol.decode(JSON.stringify([1,"W","one","seed",1,1,encoded]))==null,"truncated reactor key invalidates the message")
	room.leave()

func test_ordinary_client_receives_cassette_and_missing_film_is_optional(t:T) -> void:
	var room := GameLocal.new()
	room.open_local("reactor-client","Tester",false)
	room.start_reactor_review(23)
	for n in 12: room.poll(n*.05)
	t.check(room.client.latest!=null and room.client.latest.has("reactor"),"normal client receives opt-in reactor in welcome and snapshots")
	var screen := preload("res://client/reactor_screening.gd").new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(screen)
	screen.show_archive({"recovered":true,"discovered":false,"playing":{}}, "me")
	# IP1: the tape ships in the game; a plain checkout plays it.
	t.check(screen.film != null and not screen.button.disabled, "the game's own tape enables playback")
	t.check(not screen.status.text.contains(".pck"), "no file to install is named: " + screen.status.text)
	screen.free()
	room.leave()

func test_only_reactor_extraction_opens_physical_prison_archive(t: T) -> void:
	var room := GameLocal.new()
	room.open_local("physical-prison", "Tester", false)
	room.start_playtest(1)
	for i in 8: room.poll(i * 0.05)
	t.check(room.host.state.depth == 1 and not room.host.world().has("reactor"), "ordinary room stays on its own floor")
	t.check(not room.host.reactor_screening(GameLocal.ME, "watch", 0), "ordinary room has no reactor playback")
	room.start_reactor_review(23)
	for i in 8: room.poll(1.0 + i * 0.05)
	var host := room.host
	var review := host._reactor_review
	review.rules.power = State.Power.RESTORED
	review.rules.extracted = true
	review.rules.returned = true
	for i in 8: room.poll(2.0 + i * 0.05)
	t.check(host.state.depth == 0 and host.state.plan.place == &"prison", "the same room placed its crew into the real prison")
	t.check(host.world().reactor.archive.recovered, "carried cassette enters the prison with the crew")
	var peer: Variant = host._players[GameLocal.ME]
	peer.body = Move.Body.make(8, 17, 0, 0)
	t.check(not host.reactor_screening(GameLocal.ME, "watch", 0), "a distant client cannot start the player")
	var station := preload("res://net/reactor_review.gd").STATION_POSITION
	peer.body = Move.Body.make(station.x, station.z + 0.8, 0, 0)
	t.check(host.reactor_screening(GameLocal.ME, "watch", 0), "the real prison player is usable within reach")
	room.leave()

func test_prison_deck_copy_distinguishes_storage_from_full_crew_playback(t: T) -> void:
	var screen := preload("res://client/reactor_screening.gd").new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(screen)
	# This checks the controls; the archived film is supplied by the private package.
	screen.film = VideoStreamTheora.new()
	var stored := {"recovered": true, "discovered": false, "playing": {}}
	screen.show_archive(stored, "me")
	t.eq(screen.title.text, "PRISON CASSETTE DECK", "identify the device before the witness refers to the players")
	t.eq(screen.status.text, "Cassette stored. Play it now or leave it here.", "storage allows a choice without revealing the warning")
	screen.ticket = 7
	screen.show_archive(stored, "me")
	t.eq(screen.status.text, "Cassette rewound. No full viewing recorded.", "stopping before the end leaves the copy and no crew viewing")
	screen.show_archive({"recovered": true, "discovered": true, "playing": {}}, "another peer")
	t.eq(screen.status.text, "Full playback logged for your crew. Cassette ready to replay.", "a completed screening belongs to the crew, including a peer who did not watch")
	screen.free()

func test_rescue_owns_use_until_release(t: T) -> void:
	var station := preload("res://net/reactor_review.gd").new(7)
	var rules := station.rules
	# The power hold (RX1) is its own test below; this one checks other rules, so the cut comes at the line.
	rules.power_hold = 0.0
	var fuse := rules.fuse
	var helper := fuse + Vector3(0.75,0,0)
	station.player("victim",fuse,false,&"walk",0.02)
	station.player("helper",helper,false,&"walk",0.02)
	rules.down(1)
	station.player("helper",helper,true,&"walk",1.0)
	t.check(rules.healing.has(2) and rules.holder==0,"rescue takes priority over fuse pickup")
	station.player("helper",helper,false,&"walk",0.01)
	t.check(rules.healing.is_empty(),"release interrupts rescue progress")
	station.player("helper",helper,true,&"walk",2.5)
	t.eq(rules.condition[1],"down","a new press restarts the rescue")
	station.player("helper",helper,true,&"walk",0.51)
	station.player("helper",helper,true,&"walk",0.1)
	t.check(rules.condition[1]=="up" and rules.holder==0,"completion still consumes the held press")
	station.player("helper",helper,false,&"walk",0.02)
	station.player("helper",helper,true,&"walk",0.02)
	t.eq(rules.holder,2,"a fresh press takes the fuse")
	station.player("helper",rules.breaker,false,&"walk",0.02)
	station.player("victim",rules.breaker,false,&"walk",0.02)
	rules.tick(2.3)
	rules.down(1)
	station.player("helper",rules.breaker,true,&"walk",0.02)
	station.leave_missing({"helper":true})
	station.player("helper",rules.breaker,true,&"walk",0.02)
	t.check(rules.fuse_uses==0 and rules.healing.is_empty(),"disconnect clears rescue without installing the fuse")
	station.player("helper",rules.breaker,false,&"walk",0.02)
	station.player("helper",rules.breaker,true,&"walk",0.02)
	t.eq(rules.fuse_uses,1,"fresh press after disconnect installs the fuse once")

# ---- RX1: the power holds, the fuse is hidden, the tape is on its plinth and glows ----------------------

const Review = preload("res://net/reactor_review.gd")
const Marks = preload("res://client/reactor_marks.gd")
const Screening = preload("res://client/reactor_screening.gd")

func test_rx1_power_holds_after_the_line_then_cuts_on_host_time(t: T) -> void:
	var station := Review.new(23)
	var rules := station.rules
	t.check(Review.POWER_HOLD >= 30.0, "the hold is long enough to feel safe (%.0f s)" % Review.POWER_HOLD)
	t.eq(rules.power_hold, Review.POWER_HOLD, "the real floor holds the lights")
	station.player("A", Vector3(0, 0, 9.3), false, &"walk", 0.05)
	station.tick(0.05)
	station.player("A", Vector3(0, 0, rules.outage_plane - 1.0), false, &"walk", 0.05)
	t.eq(rules.power, State.Power.NORMAL, "crossing the line does not cut the power")
	var cut_at := -1.0
	var host_time := 0.0
	var second := false
	var downed_early := false
	while host_time < Review.POWER_HOLD + 1.0:
		station.tick(0.05)
		host_time += 0.05
		if host_time > 10.0 and not second:
			# A second player crossing later must not restart the clock.
			station.player("B", Vector3(1, 0, rules.outage_plane - 2.0), false, &"walk", 0.05)
			second = true
		if rules.power != State.Power.NORMAL and cut_at < 0:
			cut_at = host_time
		if rules.power == State.Power.NORMAL and rules.down(1):
			downed_early = true
	t.check(absf(cut_at - Review.POWER_HOLD) < 0.06, "the cut comes POWER_HOLD host seconds after the first crossing (at %.2f s)" % cut_at)
	t.eq(rules.power, State.Power.EMERGENCY, "then the power is out")
	t.check(not downed_early, "nobody can be downed while the lights hold")
	# Before anyone crosses, the clock never runs.
	var idle := Review.new(23)
	idle.player("A", Vector3(0, 0, 9.3), false, &"walk", 0.05)
	for i in 2000:
		idle.tick(0.05)
	t.eq(idle.rules.power, State.Power.NORMAL, "the lights stay on while the crew stays at the lift")
	# Zero hold is the old rule: the cut at the line.
	var old := State.new(1.0, Vector3(-6, 1, -5), Vector3(-3, 1, 5))
	old.observe(1, Vector3(0, 0, 0))
	t.eq(old.power, State.Power.EMERGENCY, "with no hold the line cuts at once, as before")

func test_rx1_fuse_spot_comes_from_the_seed_and_is_out_of_plain_sight(t: T) -> void:
	var used := {}
	var bad := 0
	for seed_number in 300:
		var a := Review.new(seed_number)
		var b := Review.new(seed_number)
		if a.rules.fuse != b.rules.fuse or not Review.FUSE_SPOTS.has(a.rules.fuse):
			bad += 1
		used[a.rules.fuse] = true
		for open_shelf: Vector3 in Review.OLD_STORES:
			if a.rules.fuse.distance_to(open_shelf) < 1.0:
				bad += 1
		var snap := a.snapshot()
		if Vector3(snap.fuseAt[0], snap.fuseAt[1], snap.fuseAt[2]) != a.rules.fuse:
			bad += 1
	t.eq(bad, 0, "one seed, one spot for every player (and late joiners: it is in fuseAt), never an open shelf")
	t.eq(used.size(), Review.FUSE_SPOTS.size(), "every hiding place is used by some seed")
	for spot: Vector3 in Review.FUSE_SPOTS:
		# The pack's west pillars: x -8.72 to -8.28 at z -11, -5 and 1 (0.46 deep); the wall's face is x -9.3.
		var behind_pillar := spot.x < -8.72 and spot.x > -9.3 and [-11.0, -5.0, 1.0].any(func(z: float) -> bool: return absf(spot.z - z) < 0.07)
		var under_gallery := spot.x > 3.55 and spot.x < 9.25 and spot.z > -10.5 and spot.z < 0.5 and spot.y < 1.1
		t.check(behind_pillar or under_gallery, "%s is behind a west pillar or under the gallery" % spot)
		if under_gallery:
			t.check(spot.x - 3.32 < 2.0, "%s is in reach of a player standing at the gallery's edge" % spot)

func test_rx1_tape_lies_on_its_plinth(t: T) -> void:
	# The pack draws the plinth at its cassette node's default spot and the tape at the node + this offset
	# (floor.gd and crew.gd _make_tape: plinth 0.66 x 0.5 at (-0.76, 0.42, 0.12); tape 0.46 x 0.22, turned 0.26).
	var plinth := Review.TAPE_PLINTH + Vector3(-0.76, 0, 0.12)
	var half_x := 0.33 - (0.23 * cos(0.26) + 0.11 * sin(0.26))
	var half_z := 0.25 - (0.23 * sin(0.26) + 0.11 * cos(0.26))
	var bad := 0
	for seed_number in 300:
		var tape := Review.new(seed_number).rules.cassette_at + Vector3(-0.76, 0, 0.04)
		if absf(tape.x - plinth.x) > half_x or absf(tape.z - plinth.z) > half_z:
			bad += 1
	t.eq(bad, 0, "on every seed the tape lies on the plinth top, not in the air beside it")
	t.check(Review.new(23).rules.cassette_at != Review.new(24).rules.cassette_at, "still placed by the seed")
	# With RX1 off the floor is the old one (the open shelf, the tape's old offset, the cut at the line).
	Review.rx1 = false
	var old := Review.new(23)
	Review.rx1 = true
	t.check(Review.OLD_STORES.has(old.rules.fuse) and old.rules.power_hold == 0.0 and old.rules.cassette_at.x <= -1.02, "rx1 off is the floor before RX1")

func test_rx1_prompts_mirror_the_hosts_use(t: T) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	var bad := 0
	var seen := {}
	for i in 600:
		var station := Review.new(i % 37)
		station.rules.power_hold = 0.0
		var rules := station.rules
		# Somewhere near one of the three props, in any power state, with or without the tape taken.
		var props: Array[Vector3] = [rules.fuse, rules.breaker, rules.cassette_at]
		var near: Vector3 = props[rng.randi_range(0, 2)]
		var at := near + Vector3(rng.randf_range(-2.6, 2.6), 0, rng.randf_range(-2.6, 2.6))
		at.y = 0.0
		station.player("me", at, false, &"walk", 0.02)
		rules.power = [State.Power.NORMAL, State.Power.EMERGENCY, State.Power.RESTORED][rng.randi_range(0, 2)]
		if rng.randf() < 0.3:
			rules.collected = true
		if rules.power == State.Power.EMERGENCY and rng.randf() < 0.3:
			rules.holder = station.seats["me"]
		var frame := station.snapshot()
		var said := Marks.prompt_for(frame, "me", rules.breaker)
		var did := rules.use(station.seats["me"])
		var want: String = {"fuse": "fuse", "cassette": "tape"}.get(did, "")
		if said != want:
			bad += 1
		seen[want] = true
	t.eq(bad, 0, "the E prompt names what the host would do on that press, every time")
	t.check(seen.has("fuse") and seen.has("tape") and seen.has(""), "fuse, tape and no-prompt cases were all tried")
	var station := Review.new(23)
	station.player("me", station.rules.cassette_at, false, &"walk", 0.02)
	var frame := station.snapshot()
	frame.status["me"] = "down"
	t.eq(Marks.prompt_for(frame, "me", station.rules.breaker), "", "no prompt while down")
	t.eq(Marks.prompt_for(frame, "", station.rules.breaker), "", "no prompt for nobody")

class FakeFloor extends Node3D:
	var cassette := Node3D.new()
	var frame := {}
	var hud := Label.new()
	var socket := Vector3(-3.3, 1.05, 5.55)
	var view_id := "me"

func test_rx1_marks_join_only_the_reactor_scene(t: T) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var scene := FakeFloor.new()
	tree.root.add_child(scene)
	scene.add_child(scene.cassette)
	var body := Node3D.new()
	body.position = Vector3(-0.76, 1.01, 0.04)
	scene.cassette.add_child(body)
	var piece := MeshInstance3D.new()
	piece.mesh = BoxMesh.new()
	body.add_child(piece)
	scene.cassette.position = Review.TAPE_PLINTH
	var layer := CanvasLayer.new()
	scene.add_child(layer)
	layer.add_child(scene.hud)
	var screen := Screening.new()
	layer.add_child(screen)
	screen._mark_floor()
	var marks: Variant = scene.get_node_or_null("ReactorMarks")
	t.check(marks != null and scene.find_children("ReactorMarks", "", false, false).size() == 1, "the Reactor's scene gets the marks once")
	if marks != null:
		var station := Review.new(23)
		station.player("me", station.rules.cassette_at + Vector3(0, 0, 0.8), false, &"walk", 0.02)
		scene.frame = station.snapshot()
		scene.hud.text = "WASD  Move"
		marks._process(0.016)
		marks._process(0.016)
		t.eq(scene.hud.text, "WASD  Move" + Marks.TAPE_PROMPT, "in reach of the tape the HUD says E takes it, once")
		t.check(marks.glow.visible and marks.glow.global_position.distance_to(body.global_position) < 0.5, "a warm light sits over the tape")
		t.check(piece.material_override is StandardMaterial3D and (piece.material_override as StandardMaterial3D).emission_enabled, "the tape itself glows")
		scene.frame.cassette = true
		scene.cassette.hide()
		marks._process(0.016)
		t.eq(scene.hud.text, "WASD  Move", "taken: the prompt goes")
		t.check(not marks.glow.visible, "and the light with it")
	scene.free()
	# The prison's cassette deck uses the same screen: no marks there.
	var prison := Control.new()
	tree.root.add_child(prison)
	var deck := Screening.new()
	prison.add_child(deck)
	t.check(prison.get_node_or_null("ReactorMarks") == null and tree.root.get_node_or_null("ReactorMarks") == null, "no marks outside the Reactor")
	prison.free()
