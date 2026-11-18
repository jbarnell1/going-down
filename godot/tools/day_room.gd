# play_day's room (tools/play_day.mjs, through tools/day_server.gd): the home server's own room (server/room.gd,
# with days, the floor quota and the day quota's lock on as in the game), its resident parked for good so the
# check can play a day without being caught, and the crew's recording done by the check's hand (`earn`).
# Tests only.
#  - earn(n): as if the crew had recorded n credits here: the day's earned rises by n (sim/run.gd day_earned),
#    and this floor's quota is met (so the call works), as readings closing would make them.
#  - info(): the host's phase, tick, day block (net/host.gd day_block) and players.
#  - day_at(k): the host's day block at tick k, as it was then (not ok once the host has dropped that tick, or
#    for the tick earn() rewrote after its snapshot had gone out).
extends "res://server/room.gd"

const Day = preload("res://sim/day.gd")

## Ticks whose stored state earn() rewrote after their snapshot had gone out: day_at() says so.
var acted := {}

func update(now: float) -> void:
	super.update(now)
	if host == null:
		return
	var o := host.state.orderly
	if not (o.mode == &"dormant" and is_inf(o.dormant_left)):
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

func earn(n: float) -> Dictionary:
	if host == null:
		return {"ok": false, "error": "no run"}
	acted[host.tick] = true
	host.act(func(rs: Run.RunState) -> Run.RunStep:
		var x := rs.copy()
		x.day_earned += n
		if x.quota:
			x.floor_earned = maxf(x.floor_earned, float(x.floor_needed))
		var out := Run.RunStep.new()
		out.state = x
		return out)
	return {"ok": true, "earned": floori(host.state.day_earned), "quota": Run.day_quota_now(host.state), "lock": host.state.day_lock}

func info() -> Dictionary:
	if host == null:
		return {"run": false}
	var st := host.state
	var players: Array = []
	for p in st.players:
		players.append({"id": p.id, "name": str(people.get(p.id, "")), "status": String(p.status), "aboard": p.aboard, "side": String(p.side) if p.side != null else ""})
	return {"run": true, "phase": String(st.phase), "depth": st.depth, "tick": host.tick, "lock": st.day_lock,
		"day": Protocol.plain(Host.day_block(st)) if st.days else null, "players": players}

func day_at(k: int) -> Dictionary:
	if host == null:
		return {"ok": false}
	if acted.has(k):
		return {"ok": false, "tick": k, "acted": true}
	var hs := host.state_at(k)
	if hs == null or not hs.days:
		return {"ok": false, "tick": k}
	return {"ok": true, "tick": k, "day": Protocol.plain(Host.day_block(hs))}
