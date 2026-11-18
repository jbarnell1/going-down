# play_arboretum's room (tools/play_arboretum.mjs, through tools/garden_server.gd): the home server's own room
# (server/room.gd, every rule the game's rooms turn on), unchanged but for where a run starts and what the
# check needs to be quick and sure. Tests only.
#  - The run starts on the room's `first_depth` (server/room.gd), 5 here: the Arboretum is floor 5 of the
#    game's deck.
#  - Down lasts 60 s (the live setting down.time), so the script has time to draw the Groundskeeper off and
#    creep back to heal.
#  - The Groundskeeper starts at `keeper_at`, a spot 12 to 15 m from the first whistle instead of the landmark
#    farthest from the lift, so the crew need not cross the whole garden first. It listens there as it would
#    anywhere: nothing else about it is changed.
#  - `stations` are five moss cells in a straight line (the nearest such run to the landing): the check's
#    players stand, whistle and creep along them. The room only finds and announces them.
extends "res://server/room.gd"

const Arboretum = preload("res://sim/arboretum.gd")
const Noises = preload("res://sim/noise.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")

## The five stations' middles (metres: x, z), the Groundskeeper's spot, and the floor's hash, once a run started.
var stations: Array[Vector2] = []
var keeper_at := Vector2.ZERO
var garden_hash := ""

func _init(ws: WsServer, log: Callable) -> void:
	super(ws, log)
	first_depth = 5

func _start(now: float) -> void:
	# The ready players, as the room's own start (server/room.gd ready-up).
	var roster := _start_roster()
	if host != null or roster.is_empty():
		return
	epoch += 1
	var seed := fixed_seed
	if seed.is_empty():
		seed = Crypto.new().generate_random_bytes(6).hex_encode()
	rules = HostRules.new(true, first_depth, Places.FULL, days, false, downs, watchers and not HostRules.watchers_off_by_arg(), relocation, long_dark, paced, car_waits, lonely, playroom_tuned, false, furniture, findables, inventory)
	_transport = RoomTransport.new(self)
	_day_logged = 1
	host = Host.new(_transport, seed, roster, now, Callable(self, "_prepare"), Callable(rules, "step"))
	# Live settings as the room's own start, with down lasting 60 s for the check.
	desk.run_started()
	host.on_tick = Callable(self, "_tune_tick")
	var forced := desk.in_force()
	forced[&"down.time"] = 60.0
	host.set_tuning(forced, desk.rev)
	_dirty = true
	var parts := PackedStringArray()
	for s in stations:
		parts.append("%.1f,%.1f" % [s.x, s.y])
	_log.call("garden: run %d at depth %d stations %s keeper %.1f,%.1f hash %s" % [epoch, first_depth, " ".join(parts), keeper_at.x, keeper_at.y, garden_hash])

func _prepare(s0: Run.RunState) -> Run.RunState:
	var s := rules.prepare(s0)
	var g := Arboretum.garden_of(s.plan)
	if g == null:
		return s
	garden_hash = Arboretum.floor_hash(s.plan)
	var W := Arboretum.W
	var dist := Floor.distances_from(s.plan, s.plan.landing)
	# The straight run of five moss cells nearest the landing by walking (not within 4 cells of it).
	var best := -1
	var best_d := 1 << 30
	var best_step := 1
	for c in W * Arboretum.H:
		for step: int in [1, W]:
			var ok := true
			var worst := 0
			for k in 5:
				var i := c + step * k
				if i >= W * Arboretum.H or g.cells[i] != Noises.MOSS or dist[i] < 0 \
						or maxi(absi(i % W - s.plan.landing.x), absi(i / W - s.plan.landing.y)) <= 4 \
						or (step == 1 and i / W != c / W):
					ok = false
					break
				worst = maxi(worst, dist[i])
			if not ok or worst >= best_d:
				continue
			# A spot for the Groundskeeper: open ground 12.5 to 15 m from the run's far end, 11 m or more from
			# the rest of it and from the pavilion's doorway.
			var far := c + step * 4 if dist[c + step * 4] > dist[c] else c
			var spot := _keeper_spot(s, g, c, step, far)
			if spot < 0:
				continue
			best = c
			best_d = worst
			best_step = step
			keeper_at = Vector2((spot % W + 0.5) * 2.0, (spot / W + 0.5) * 2.0)
	if best < 0:
		return s
	stations = []
	var from_far := dist[best + best_step * 4] > dist[best]
	for k in 5:
		# Station 0 is the end nearer the lift; station 4 the far end, where the first whistle is.
		var i := best + best_step * (k if from_far else 4 - k)
		stations.append(Vector2((i % W + 0.5) * 2.0, (i / W + 0.5) * 2.0))
	var o := s.orderly.copy()
	o.body = Move.Body.make(keeper_at.x, keeper_at.y, 0, 0.0)
	s = s.copy()
	s.orderly = o
	return s

func _keeper_spot(s: Run.RunState, g: Arboretum.Garden, c: int, step: int, far: int) -> int:
	var W := Arboretum.W
	var fx := (far % W + 0.5) * 2.0
	var fz := (far / W + 0.5) * 2.0
	var door := Vector2((g.door_out % W + 0.5) * 2.0, (g.door_out / W + 0.5) * 2.0)
	for i in W * Arboretum.H:
		if Floor.cell_at(s.plan, 0, i % W, i / W) != Floor.CORRIDOR or g.cells[i] != Noises.LITTER:
			continue
		var p := Vector2((i % W + 0.5) * 2.0, (i / W + 0.5) * 2.0)
		var d := p.distance_to(Vector2(fx, fz))
		if d < 12.5 or d > 15.0 or p.distance_to(door) < 12.0:
			continue
		var clear := true
		for k in 5:
			var m := c + step * k
			if m != far and p.distance_to(Vector2((m % W + 0.5) * 2.0, (m / W + 0.5) * 2.0)) < 11.0:
				clear = false
		if clear:
			return i
	return -1
