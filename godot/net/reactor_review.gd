extends RefCounted
## Per-floor adapter for the regular room host. It reads only accepted bodies, use and gait.
const STATION_POSITION := Vector3(23.0, 1.44, 16.17)

static func at_prison_station(x: float, z: float) -> bool:
	return Vector2(x,z).distance_to(Vector2(STATION_POSITION.x,STATION_POSITION.z)) <= 1.8

const Archive := preload("res://sim/reactor_archive.gd")
const State := preload("res://sim/reactor.gd")
const StationRules := preload("res://sim/station_floor.gd")

## RN1, the Reactor as a place: the same block as snapshot() below, built from the run's station (sim/station_floor.gd)
## and the run's players {id: RunPlayer} on the floor (connected, still in the run). Every old field, positions in the
## plan's metres; new: native (true), holdLeft (seconds of light left, -1 before the hold starts, 0 after the cut),
## seats ([1, 2, 3, 4], the crew poses' seat numbers). The host adds archive.
static func native_snapshot(sf: StationRules.StationFloor, players: Dictionary, tuning: Variant) -> Dictionary:
	var peers := {}
	var states := {}
	var low := {}
	for id: String in players:
		var rp: Variant = players[id]
		var b: Variant = rp.body
		peers[id] = [b.x, b.y, b.z]
		var st := str(rp.status)
		states[id] = "up" if st == "ok" else ("down" if st == "down" else "out")
		low[id] = bool(sf.low.get(id, false))
	var seats := []
	for b in sf.bodies:
		seats.append(b.seat)
	return {"seed": sf.seed_value, "seq": sf.seq, "rev": sf.rev, "power": sf.power, "time": sf.awake,
		"holder": sf.holder if not sf.holder.is_empty() else 0, "fuseUses": sf.fuse_uses, "cassette": sf.collected,
		"lift": sf.returned, "players": peers, "crew": StationRules.seat_poses(sf, tuning), "status": states, "low": low,
		"cassetteHolder": sf.cassette_holder, "extracted": sf.extracted, "fuseAt": [sf.fuse.x, sf.fuse.y, sf.fuse.z],
		"tapeAt": [sf.tape.x, sf.tape.y, sf.tape.z], "native": true, "holdLeft": sf.hold_left, "seats": seats}
const SPAWN := [Vector3(-3,0,-4),Vector3(1,0,-3),Vector3(6,2,-8),Vector3(6,0,-3)]
## RX1: where the fuse can be, one chosen from the floor seed (the same for every player; late joiners get it
## in the block's fuseAt). Each is out of plain sight in the room the ReactorCampaign pack draws: on the floor
## in the gap behind one of the three west pillars (x -8.5, between pillar and wall), or in the shadow under
## the control gallery's lip (the gallery is x 3.55 to 9.25, z -10.5 to 0.5, its underside 1.1 m up), 1.45 m
## in: seen by looking under it, and in reach (2 m) of a player standing at the edge. The old spots were three
## open shelf tops by the west wall; the pack still draws its FUSE STORES stand at one of them.
const FUSE_SPOTS := [Vector3(-9.02,.07,-11.0),Vector3(-9.02,.07,-5.0),Vector3(-9.02,.07,1.0),
	Vector3(5.0,.07,-2.5),Vector3(5.0,.07,-8.0)]
## RX1: host seconds the lights hold after the first player crosses the outage line, before the cut. The
## owner: "The lights should stay on for awhile....Get you feeling save and then power cuts out." A constant
## for game night (not yet a live setting: the Reactor host gets no tuning values).
const POWER_HOLD := 45.0
## RX1: where the pack draws the tape's plinth (its cassette node's default, floor.gd), and how far the seed
## may move the tape and still leave it lying on the plinth top (the plinth is 0.66 m by 0.5 m).
const TAPE_PLINTH := Vector3(-.52,0,6.6)
## RX1 is on in the game. Off, this floor is exactly the one before RX1 (the open shelves, the tape's old offset,
## the cut at the line): only tests turn it off, to prove that (tests/cycles_rig.gd flag_off_digest).
static var rx1 := true
const OLD_STORES := [Vector3(-6.8,.92,-6.5),Vector3(-6.4,.92,-10),Vector3(-5.8,.92,-2.4)]
var seed_value: int
var archive: Archive
var rules: State
var grid := AStarGrid2D.new()
var actors: Array[Dictionary] = []
var seats := {}
var next_seat := 1
var use_before := {}
var low := {}

func _init(seed_number: int, archive_path := "") -> void:
	archive = Archive.new(archive_path)
	seed_value = seed_number & 0x7fffffff
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in 4:
		rng.randf() # each source rig has an offset for its original idle
	var trigger := rng.randf_range(.8,2.5)
	if not rx1:
		rules = State.new(trigger,OLD_STORES[rng.randi_range(0,2)],Vector3(-3.3,1.05,5.55))
		rules.cassette_at = Vector3(-1.02-rng.randf_range(0,.2),0,6.58+rng.randf_range(0,.12))
	else:
		rules = State.new(trigger,FUSE_SPOTS[rng.randi_range(0,FUSE_SPOTS.size()-1)],Vector3(-3.3,1.05,5.55))
		rules.power_hold = POWER_HOLD
		# On the plinth beside the lift door (the old -1.02 offset left the tape hanging in the air beside it).
		rules.cassette_at = TAPE_PLINTH+Vector3(rng.randf_range(-.07,.07),0,rng.randf_range(0,.12))
	rules.collected = archive.recovered
	grid.region = Rect2i(-9,-13,19,27)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for x in range(-9,10):
		for z in range(-13,14):
			var obstruction := (z==6 and x!=0) or (x>=-3 and x<=2 and z>=-9 and z<=-4) or (x>=4 and z>=-10 and z<=0)
			grid.set_point_solid(Vector2i(x,z),obstruction or (x==4 and z in [-11,-5,1]))
	for i in 4:
		actors.append({"at":SPAWN[i],"phase":"still","yaw":-.72+i*.46,"clock":.65+i*.43,"wind":0.0,"victim":0,
			"rear":i==2,"tray":i==3})

func leave_missing(connected: Dictionary) -> void:
	for id: String in seats.keys():
		if not connected.has(id):
			archive.tickets.erase(id)
			rules.leave(seats[id])
			seats.erase(id)
			use_before.erase(id)
			low.erase(id)

func player(id: String, at: Vector3, held: bool, gait: StringName, dt: float) -> void:
	if not seats.has(id):
		seats[id] = next_seat
		next_seat += 1
	var seat: int = seats[id]
	rules.observe(seat,at)
	var rescuing := rules.rescue(seat,held,dt)
	if not held:
		use_before.erase(id)
	elif rescuing:
		# The helper must release use before this same press can operate a floor prop.
		use_before[id] = "rescue"
	else:
		var previous: String = use_before.get(id,"")
		# During a sprint the accepted body can still be beside the tape when the lift button arrives.
		var entered_lift := previous == "cassette" and at.z > 8 and rules.power == State.Power.RESTORED
		if previous.is_empty() or entered_lift:
			var action := rules.use(seat)
			if not action.is_empty():
				use_before[id] = action
	low[id] = gait==&"creep" or rules.condition[seat]=="down"

func nearest(at: Vector3) -> Vector2i:
	var center := Vector2i(clampi(roundi(at.x),-9,9),clampi(roundi(at.z),-13,13))
	if not grid.is_point_solid(center):
		return center
	var best := center
	var dist := INF
	for x in range(maxi(-9,center.x-6),mini(9,center.x+6)+1):
		for z in range(maxi(-13,center.y-6),mini(13,center.y+6)+1):
			var p := Vector2i(x,z)
			var d := Vector2(x-at.x,z-at.z).length_squared()
			if d<dist and not grid.is_point_solid(p):
				best = p
				dist = d
	return best

func tick(dt: float) -> void:
	rules.tick(dt)
	if rules.extracted and not archive.recovered: archive.bank()
	if rules.power==State.Power.NORMAL: return
	for i in 4:
		var age := rules.awake_seconds-1.1-i*.62
		if age<0: continue
		var a := actors[i]
		var at: Vector3 = a.at
		var victim := 0
		var distance := INF
		for id: int in rules.players:
			if rules.condition[id]!="up": continue
			var d := at.distance_to(rules.players[id])
			if d<distance:
				victim = id
				distance = d
		var crawl: bool = age<4.2 or a.tray
		var clip := "zombie_crawl" if crawl else "zombie_run"
		if a.phase!=clip: a.clock = 0.0
		a.phase = clip
		a.clock = fmod(float(a.clock)+dt*(1.0 if crawl else 3.4/3.03),5.13 if crawl else .8)
		if victim==0: continue
		var goal: Vector3 = rules.players[victim]
		var gallery_target := goal.x>=3.6 and goal.z>=-10.7 and goal.z<.7 and goal.y>=1.2
		if gallery_target and a.rear:
			# Already on the gallery walkway, immediately turn toward the player.
			pass
		elif a.tray:
			goal = Vector3(3.1,0,-3)
			if at.x<3.32: a.tray = false
		elif a.rear:
			goal = Vector3(6.4,2,-10.6) if at.z> -10.5 else Vector3(6.4,0,-13.5)
			if at.z < -13.25: a.rear = false
		else:
			if gallery_target:
				goal = Vector3(6.4,0,-13.4)
				if at.distance_to(goal)<.5:
					a.rear = true
			var path := grid.get_id_path(nearest(at),nearest(goal))
			if path.size()>1: goal = Vector3(path[1].x,0,path[1].y)
			elif at.distance_to(goal)>1.6:
				var k := nearest(goal)
				goal = Vector3(k.x,0,k.y)
		if a.rear and gallery_target and at.z< -10.52:
			goal = Vector3(6.4,2,-10.45)
		var next := at.move_toward(goal,(.427 if crawl else 3.4)*dt)
		var heading := next-at
		if heading.length_squared()>.00001: a.yaw = atan2(heading.x,heading.z)
		a.at = next
		if distance>.72 or a.victim!=victim: a.wind = 0.0
		a.victim = victim
		if distance<=.72:
			a.wind += dt
			if a.wind>=.43: rules.down(victim)

func seat_poses() -> Array:
	var poses := []
	for i in 4:
		var a := actors[i]
		var at: Vector3 = a.at
		var rest := 1.0-smoothstep(0,1.25,rules.awake_seconds-1.1-i*.62)
		poses.append([at.x,at.y+(.23 if i%2==0 else .27)*rest,at.z,a.yaw,(-1.29 if i%2==0 else 1.32)*rest,a.phase,a.clock])
	return poses

func snapshot() -> Dictionary:
	var world := rules.snapshot(seat_poses(),seed_value)
	var peers := {}
	var states := {}
	var holder: Variant = 0
	var tape_carrier := ""
	for id: String in seats:
		var index := str(seats[id])
		peers[id] = world.players[index]
		states[id] = world.status[index]
		if rules.holder==seats[id]: holder = id
		if rules.cassette_holder==seats[id]: tape_carrier = id
	world.players = peers
	world.status = states
	world.low = low.duplicate()
	world.holder = holder
	world.cassetteHolder = tape_carrier
	world.archive = archive.snapshot()
	return world

func screening(peer: String, operation: String, ticket: int) -> bool:
	return rules.returned and seats.has(peer) and archive.action(peer,operation,ticket,rules.awake_seconds)
