extends RefCounted
## One instance per reactor floor. The host supplies collision-resolved bodies and time.
## Seat identifiers refer to the authenticated room peer. Positions never come from use requests.

enum Power { NORMAL, EMERGENCY, RESTORED }
var power := Power.NORMAL
var awake_seconds := 0.0
var holder := 0
var collected := false
var returned := false
var extracted := false
var fuse_uses := 0
var condition := {}
var down_time := {}
var healing := {}
var recovery := {}
var cassette_holder := 0
var cassette_at := Vector3(-.52,0,6.6)
var revision := 0
var sequence := 0
var outage_plane: float
## RX1: how long the power holds after the first player crosses outage_plane, in host seconds. 0 cuts it at
## once (the old rule, still the default here); the real floor (net/reactor_review.gd POWER_HOLD) sets it.
## Counted down only in tick(), from host time, so every player sees the cut on the same host tick.
var power_hold := 0.0
## -1 until someone crosses the line; then the host seconds still to run before the cut.
var hold_left := -1.0
var fuse: Vector3
var breaker: Vector3
var players := {}

func _init(trigger_z: float, fuse_at: Vector3, breaker_at: Vector3) -> void:
	outage_plane = trigger_z
	fuse = fuse_at
	breaker = breaker_at

func observe(peer: int, at: Vector3) -> void:
	players[peer] = at
	if not condition.has(peer):
		condition[peer] = "up"
	if power==Power.NORMAL and hold_left<0 and at.z<outage_plane:
		hold_left = power_hold
		if hold_left<=0:
			_cut()

func _cut() -> void:
	power = Power.EMERGENCY
	hold_left = 0.0
	revision += 1

func leave(peer: int) -> void:
	drop_carried(peer)
	players.erase(peer)
	condition.erase(peer)
	down_time.erase(peer)
	healing.erase(peer)
	recovery.erase(peer)

func tick(dt: float) -> void:
	sequence += 1
	for peer: int in recovery.keys():
		recovery[peer] -= dt
		if recovery[peer]<=0:
			recovery.erase(peer)
	for peer: int in down_time.keys():
		down_time[peer] -= dt
		if down_time[peer]<=0:
			condition[peer] = "out"
			down_time.erase(peer)
			revision += 1
	if power==Power.NORMAL and hold_left>0:
		hold_left -= dt
		if hold_left<=0:
			_cut()
	if power!=Power.NORMAL:
		awake_seconds += dt

func use(peer: int) -> String:
	if not players.has(peer) or condition[peer]!="up":
		return ""
	var at: Vector3 = players[peer]
	var action := ""
	if power==Power.EMERGENCY and holder==0 and at.distance_to(fuse)<2:
		holder = peer
		action = "fuse"
	elif power==Power.EMERGENCY and holder==peer and at.distance_to(breaker)<2:
		power = Power.RESTORED
		holder = 0
		fuse_uses += 1
		action = "installed"
	elif not collected and at.distance_to(cassette_at)<2.2:
		collected = true
		cassette_holder = peer
		action = "cassette"
	elif power==Power.RESTORED and at.z>8 and not returned:
		returned = true
		if cassette_holder!=0 and players.has(cassette_holder) and players[cassette_holder].z>8.0 and condition[cassette_holder]=="up":
			extracted = true
		for other: int in condition:
			if condition[other]=="out":
				condition[other] = "up"
		action = "lift"
	if not action.is_empty():
		revision += 1
	return action

func snapshot(crew: Array, seed_value: int) -> Dictionary:
	var states := {}
	for id: int in condition:
		states[str(id)] = condition[id]
	var peers := {}
	for id: int in players:
		var pos: Vector3 = players[id]
		peers[str(id)] = [pos.x,pos.y,pos.z]
	return {"seed":seed_value,"seq":sequence,"rev":revision,"power":power,"time":awake_seconds,
		"holder":holder,"fuseUses":fuse_uses,"cassette":collected,"lift":returned,
		"players":peers,"crew":crew,"status":states,"cassetteHolder":cassette_holder,"extracted":extracted,"fuseAt":[fuse.x,fuse.y,fuse.z],"tapeAt":[cassette_at.x,cassette_at.y,cassette_at.z]}

func drop_carried(peer: int) -> void:
	if holder==peer:
		holder = 0
		fuse = players[peer]+Vector3.UP*.18
		revision += 1
	if cassette_holder==peer:
		cassette_holder = 0
		collected = false
		cassette_at = players[peer]
		revision += 1

func down(peer: int) -> bool:
	if power==Power.NORMAL or returned or condition.get(peer)!="up" or recovery.has(peer):
		return false
	condition[peer] = "down"
	down_time[peer] = 10.0
	drop_carried(peer)
	revision += 1
	return true

func rescue(helper: int, held: bool, dt: float) -> bool:
	if not held or condition.get(helper)!="up":
		healing.erase(helper)
		return false
	var victim := 0
	for other: int in down_time:
		if players[helper].distance_to(players[other])<=1.4:
			victim = other
			break
	if victim==0:
		healing.erase(helper)
		return false
	var progress: Dictionary = healing.get(helper,{})
	if progress.get("peer")!=victim:
		progress = {"peer":victim,"elapsed":0.0}
	progress.elapsed += dt
	healing[helper] = progress
	if progress.elapsed>=3.0:
		condition[victim] = "up"
		recovery[victim] = 2.2
		down_time.erase(victim)
		healing.erase(helper)
		revision += 1
	return true
