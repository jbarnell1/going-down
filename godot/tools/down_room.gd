# play_down's room (tools/play_down.mjs, through tools/down_server.gd): the home server's own room
# (server/room.gd, the down rule on as in the game), with the floor's resident under the test's hand so a
# down happens when the check asks for it and nowhere else. Tests only.
#  - Parked: the resident stands where it is, dormant, until asked (it never wakes on its own).
#  - behind(name): put it a little over a metre behind that player (as they face on the host), hunting:
#    it catches them as any catch (the wind-up, the victim's screen confirming it), they go down and it
#    bends over them (sim/run.gd, sim/entity.gd). Once it lets them go (a heal or the out) it is parked again.
extends "res://server/room.gd"

const Entity = preload("res://sim/entity.gd")
const Move = preload("res://sim/move.gd")

## The test has sent the resident after someone and it has not caught them yet.
var armed := false
var _armed_at := 0.0
## Give up on a catch that never comes after this long (seconds).
const ARM_LIMIT := 12.0

func update(now: float) -> void:
	super.update(now)
	if host == null:
		return
	var o := host.state.orderly
	if armed and (o.mode == &"bending" or now - _armed_at > ARM_LIMIT):
		armed = false
	if not armed and o.mode != &"bending" and not (o.mode == &"dormant" and is_inf(o.dormant_left)):
		var p := o.copy()
		p.mode = &"dormant"
		p.dormant_left = INF
		p.wind_up_target = null
		p.bend_target = null
		p.target_id = null
		p.path = []
		p.moving = false
		p.speed = 0.0
		host.replace_orderly(p)

## Sends the resident after the player called `name`, from just behind them. Returns what it did.
func behind(name: String, now: float) -> Dictionary:
	if host == null:
		return {"ok": false, "error": "no run"}
	var id := ""
	for pid: String in people:
		if str(people[pid]) == name:
			id = pid
	var st := host.state
	var rp: Run.RunPlayer = null
	for p in st.players:
		if p.id == id:
			rp = p
	if rp == null:
		return {"ok": false, "error": "no player %s" % name}
	var hp: Variant = host._players.get(id)
	var yaw: float = float(hp.input["yaw"]) if hp != null and hp.input != null else 0.0
	# Straight behind them (the way they face is (-sin yaw, -cos yaw)); else the next way open that far.
	var k := posmod(roundi(atan2(cos(yaw), sin(yaw)) / (PI / 4.0)), 8)
	var at := rp.body
	var spot := at
	var best := -1.0
	for j: int in [0, 1, 7, 2, 6, 3, 5, 4]:
		var a := (k + j) * PI / 4.0
		var b := Move.move_with_collision(st.plan, at, cos(a) * 1.3, sin(a) * 1.3, Entity.ORDERLY_RADIUS)
		var got := Vector2(b.x - at.x, b.z - at.z).length()
		if got >= 1.25:
			spot = b
			break
		if got > best:
			best = got
			spot = b
	var o := st.orderly.copy()
	o.body = spot
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.dormant_left = 0.0
	o.wind_up_target = null
	o.bend_target = null
	o.last_seen_at = null
	host.replace_orderly(o)
	armed = true
	_armed_at = now
	return {"ok": true, "id": id, "at": [spot.x, spot.z, spot.level]}

## What the test reads: the resident and every player as the host has them.
func info() -> Dictionary:
	if host == null:
		return {"run": false}
	var st := host.state
	var o := st.orderly
	var players: Array = []
	for p in st.players:
		players.append({"id": p.id, "name": str(people.get(p.id, "")), "status": String(p.status), "x": p.body.x, "z": p.body.z, "level": p.body.level})
	return {"run": true, "phase": String(st.phase), "t": st.t, "armed": armed, "orderly": {"mode": String(o.mode), "x": o.body.x, "z": o.body.z, "anim": String(o.anim)},
		"players": players, "spots": st.spots.duplicate()}
