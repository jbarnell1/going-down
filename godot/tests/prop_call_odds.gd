# OD1: the HUD's loss-odds rows show wherever the lift's call can be pressed (client/call_reach.gd). North Star:
# "Odds are printed before a chance is taken." Proved here:
#   1. On the Hanging Ward with its call (WC1), the real Host and Client: a player at the station with the odds pending
#      sees them on the HUD (the host takes the call there; the car's doors are 22 m away); in the Ward's car at
#      boarding they see them too (the host has them aboard; the screen's own "aboard" measures the floor plan's car);
#      far from both, not.
#   2. Every floor's car and the Ward's station: at_call with Run.EPS is the host's own Run._at_call at every sampled
#      point, and wherever the screen's "press to call" prompt shows (client/play_link.gd _can_call) the HUD shows the
#      odds.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Ward = preload("res://sim/ward/state.gd")
const Places = preload("res://sim/places.gd")
const Session = preload("res://net/session.gd")
const LocalRoom = preload("res://net/local_room.gd")
const PlayLink = preload("res://client/play_link.gd")
const CallReach = preload("res://client/call_reach.gd")
const WardCall = preload("res://tests/prop_ward_call.gd")

## A day block with the odds pending, as net/host.gd day_block sends it with the lock on and an owner.
const DAY := {"index": 1, "day": 1, "quota": 1200, "earned": 0, "locked": true, "aboard": 0, "each": 0, "stakes": "", "lossOdds": {"one": 3}}

## The frame's snapshot the HUD reads (client/play_link.gd step), with the player's feet at `feet`.
static func _snap(phase: String, feet: Vector3, aboard: bool) -> Dictionary:
	return {"depth": 6, "phase": phase, "playing": true, "day": DAY,
		"me": {"id": "one", "x": feet.x, "y": feet.y, "z": feet.z, "level": 0, "status": "ok", "aboard": aboard}}

## The station as the screen has it (client/ward/floor.gd call_spot): from the wire's extras, or null.
static func _spot(latest: Dictionary) -> Variant:
	var e: Variant = (latest.get("ward", {}) as Dictionary).get("extras", {})
	if e is Dictionary and (e as Dictionary).get("called", false) == true and (e as Dictionary).get("station") is Array:
		var p: Array = (e as Dictionary)["station"]
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	return null

func test_the_wards_station_and_car_show_the_odds(t: T) -> void:
	var rig: WardCall.Rig = WardCall.Rig.new(true, false, {&"rigger.steps_reach": 0.0})
	var w: Ward = rig.ward()
	rig.tick_for(1.5)
	rig.meet_quota()
	rig.tick_for(0.3)
	t.eq(String(rig.host.state.phase), "away", "the car is away: the call is next")
	var car: Run.CarGeometry = rig.host.state.car
	var latest: Dictionary = rig.clients[0].latest
	var spot: Variant = _spot(latest)
	t.check(spot is Vector3, "the client has the station")
	var st: Vector3 = w.station
	var at := Move.Body.make(st.x, st.z, 0, st.y)
	t.check(Run._at_call(at, car, {"call_at": st}), "the host takes the call at the station")
	var door_gap := Vector2(st.x, st.z).distance_to(Vector2(car.door_x, car.door_z))
	t.check(door_gap > Run.CALL_REACH, "the car's doors are out of reach from the station (%.1f m)" % door_gap)
	t.check(CallReach.odds_on_hud(_snap("away", st, false), latest, car, spot), "at the station, the odds are on the HUD")
	var off := st + Vector3(Run.CALL_REACH + 1.0, 0.0, 0.0)
	t.check(not CallReach.odds_on_hud(_snap("away", off, false), latest, car, spot), "a metre out of the station's reach, they are not")
	# The press calls the car (the host's own check), and at boarding the player stands in the Ward's car.
	rig.bodies[0] = st
	rig.tick_for(0.3)
	rig.calling[0] = true
	rig.tick_for(0.3)
	t.eq(String(rig.host.state.phase), "coming", "the press at the station calls the car")
	t.check(rig.until(func() -> bool: return String(rig.host.state.phase) == "boarding", 200.0), "the car arrives")
	rig.bodies[0] = rig.in_car("bank")
	rig.tick_for(0.5)
	var inside: Vector3 = rig.bodies[0]
	var own_aboard := Run.in_car(car, Move.Body.make(inside.x, inside.z, 0, inside.y))
	t.check(not own_aboard, "the screen's own aboard (the floor plan's car) misses the Ward's car")
	t.check(CallReach.host_aboard(rig.clients[0].latest, "one"), "the host has the player aboard")
	t.check(CallReach.odds_on_hud(_snap("boarding", inside, own_aboard), rig.clients[0].latest, car, _spot(rig.clients[0].latest)), "in the Ward's car before the bell, the odds are on the HUD")
	var gone := _snap("boarding", inside, own_aboard)
	(gone["me"] as Dictionary)["status"] = "caught"
	t.check(not CallReach.odds_on_hud(gone, rig.clients[0].latest, car, null), "down, no rows (as before)")

func test_every_floor_the_prompt_implies_the_odds_and_the_host_agrees(t: T) -> void:
	var lr := LocalRoom.new()
	lr.open_local("od1", "T", false)
	lr.start_run()
	var link := PlayLink.new(lr, true)
	var cars: Array[Run.CarGeometry] = []
	for depth in range(1, 10):
		cars.append(Session.car_for(Session.plan_for("od1-%d" % depth, depth, Places.FULL)))
	var rig: WardCall.Rig = WardCall.Rig.new(true, false)
	var st: Vector3 = rig.ward().station
	var cases := 0
	var disagree := 0
	var prompt_without_odds := 0
	var prompts := 0
	var latest := {"players": [{"id": "one", "aboard": false}]}
	for ci in cars.size() + 1:
		var car: Run.CarGeometry = cars[mini(ci, cars.size() - 1)]
		var spot: Variant = st if ci == cars.size() else null
		var centre: Vector3 = st if spot != null else Vector3(car.door_x, car.floor_y, car.door_z)
		var ward := {"call_at": st} if spot != null else {}
		link.car = car
		link.call_spot = spot
		link.body = Move.Body.make(centre.x, centre.z, car.level, centre.y)
		for ix in range(-14, 15):
			for iz in range(-14, 15):
				for dy: float in [0.0, 1.1, 1.3]:
					for lv: int in [car.level, car.level + 1]:
						var b := Move.Body.make(centre.x + ix * 0.19, centre.z + iz * 0.19, lv, centre.y + dy)
						cases += 1
						if CallReach.at_call(b, car, spot, Run.EPS) != Run._at_call(b, car, ward):
							disagree += 1
						var in_car_now := Run.in_car(car, b)
						if link._can_call("away", b, in_car_now):
							prompts += 1
							var s := _snap("away", Vector3(b.x, b.y, b.z), in_car_now)
							(s["me"] as Dictionary)["level"] = b.level
							if not CallReach.odds_on_hud(s, latest, car, spot):
								prompt_without_odds += 1
	t.eq(disagree, 0, "%d points on %d cars and the Ward's station: the screen's question is the host's" % [cases, cars.size()])
	t.check(prompts > 50, "the prompt shows at %d of them" % prompts)
	t.eq(prompt_without_odds, 0, "wherever the call prompt shows, the odds show")
	t.check(not link._can_call("coming", Move.Body.make(cars[0].door_x, cars[0].door_z, cars[0].level, cars[0].floor_y), false), "no prompt while the car is not away")
