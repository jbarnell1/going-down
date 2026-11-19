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
	bad_phase[12][2][5]=3
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
	if screen.film==null:
		t.check(screen.button.disabled and screen.status.text.contains("ReactorCampaign.pck"),"public source checkout shows private media requirement")
	else:
		t.check(not screen.button.disabled,"matching private media enables playback")
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
