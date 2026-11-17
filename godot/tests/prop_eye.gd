# The camera drops when you creep and when you are down (North Star B12), and the eye the rules are sent
# is the eye the screen is drawn from, on every frame (the fairness contract: what counts as looking
# is what the screen shows). Plays alone through the game's own path (client/play_link.gd over
# net/local_room.gd: the real NetClient and host), headless. Run alone with tests/run_eye.gd.
extends RefCounted

const T = preload("res://tests/t.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const PlayLink = preload("res://client/play_link.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Protocol = preload("res://net/protocol.gd")
const Session = preload("res://net/session.gd")
const Pose = preload("res://net/pose.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")

## Creeping must bring the eyes below this (metres above the feet); down, below DOWN_BELOW.
const CREEP_BELOW := 1.3
const DOWN_BELOW := 0.5
const DT := 1.0 / 60.0

func test_heights_and_the_ease(t: T) -> void:
	t.eq(EyeHeight.target("ok", "walk"), EyeHeight.STAND, "walking: standing height")
	t.eq(EyeHeight.target("ok", "sprint"), EyeHeight.STAND, "sprinting: standing height")
	t.check(EyeHeight.target("ok", "creep") < CREEP_BELOW, "creeping: below %.2f m (got %.2f)" % [CREEP_BELOW, EyeHeight.target("ok", "creep")])
	t.check(EyeHeight.target("caught", "walk") < DOWN_BELOW, "down (caught): below %.2f m" % DOWN_BELOW)
	t.eq(EyeHeight.target("caught", "creep"), EyeHeight.DOWN, "down wins over creeping")
	for want: float in [EyeHeight.CREEP, EyeHeight.DOWN, EyeHeight.STAND]:
		var e := EyeHeight.new()
		e.reset(EyeHeight.STAND if want != EyeHeight.STAND else EyeHeight.CREEP)
		var prev := e.eye
		var change := absf(want - e.eye)
		var biggest := 0.0
		var frames := 0
		var cm_only := true
		while e.eye != want and frames < 600:
			var h := e.update(want, DT)
			biggest = maxf(biggest, absf(h - prev))
			cm_only = cm_only and h == Pose.q2(h)
			prev = h
			frames += 1
		t.check(frames >= int(0.15 / DT) and frames <= int(ceilf(0.25 / DT)) + 1, "to %.2f in 0.15-0.25 s (took %d frames at 60 fps)" % [want, frames])
		t.check(biggest < 0.2 * change, "to %.2f: no snap (largest step in a frame %.3f m of %.2f)" % [want, biggest, change])
		t.check(cm_only, "to %.2f: every height on the way is a whole centimetre (as the input carries it)" % want)

## A room alone, a run on `seed`, and the link the game plays through.
func _start(seed: String) -> PlayLink:
	var lr := LocalRoom.new()
	lr.open_local(seed, "T", false)
	lr.start_run()
	return PlayLink.new(lr, true)

## One frame of the game: returns the snapshot.
func _frame(link: PlayLink, now: float, creep: bool, yaw: float = 0.0, pitch: float = 0.0) -> Dictionary:
	return link.step(now, {"dt": DT, "f": 0.0, "r": 0.0, "sprint": false, "creep": creep, "yaw": yaw, "pitch": pitch, "hfov": 90.0, "vfov": 70.0})

func _until_placed(link: PlayLink, clock: Array) -> Dictionary:
	var s := {}
	for i in 600:
		clock[0] += DT
		s = _frame(link, clock[0], false)
		if s.has("me") and link.body != null:
			break
	return s

func test_the_eye_sent_is_the_camera_drawn_every_frame(t: T) -> void:
	var link := _start("eye-frames")
	var clock := [0.0]
	var s := _until_placed(link, clock)
	if not t.check(s.has("me") and link.body != null, "the run starts and the player is placed"):
		return
	var host := (link.rc as LocalRoom).host
	# Stand, creep, stand, down, up: a second each.
	var plan: Array = [["stand", false, false], ["creep", true, false], ["stand", false, false], ["down", false, true], ["stand", false, false]]
	var frames := 0
	var bad_cam := 0
	var bad_sent := 0
	var sent := 0
	var worst := 0.0
	var lows := {"stand": 99.0, "creep": 99.0, "down": 99.0}
	var highs := {"stand": -99.0, "creep": -99.0, "down": -99.0}
	var host_creep := 99.0
	for leg: Array in plan:
		var st: String = leg[0]
		link.set_down(leg[2])
		for i in 60:
			clock[0] += DT
			s = _frame(link, clock[0], leg[1])
			if not s.has("me"):
				continue
			var me: Dictionary = s["me"]
			var c := link.client()
			var lc := c.last_camera
			# The camera as main.gd draws it, against the client's own camera for this frame.
			var drawn := PlayLink.camera_point(me)
			var judged := Vector3(lc.body.x, lc.body.y + lc.eye, lc.body.z)
			frames += 1
			worst = maxf(worst, drawn.distance_to(judged))
			if float(me["eye"]) != lc.eye or drawn.distance_to(judged) > 1e-4:
				bad_cam += 1
			# The input as it went on the wire, when one went on this frame.
			if c.last_input_frame == c.stats.frames:
				var m: Variant = Protocol.decode(c.last_input)
				sent += 1
				if not (m is Dictionary) or float((m as Dictionary)["eye"]) != float(me["eye"]):
					bad_sent += 1
			if i >= 30:
				lows[st] = minf(float(lows[st]), float(me["eye"]))
				highs[st] = maxf(float(highs[st]), float(me["eye"]))
			var hp: Variant = host._players.get("me")
			if st == "creep" and hp != null and hp.input != null:
				host_creep = minf(host_creep, float(hp.input["eye"]))
	t.note("%d frames, %d inputs; camera against the client's camera: largest gap %.6f m" % [frames, sent, worst])
	t.note("eye after half a second: standing %.2f-%.2f, creeping %.2f-%.2f, down %.2f-%.2f; the host's lowest while creeping %.2f" % [
		lows["stand"], highs["stand"], lows["creep"], highs["creep"], lows["down"], highs["down"], host_creep])
	t.check(frames > 250, "not vacuous: frames drawn (%d)" % frames)
	t.check(sent > 60, "not vacuous: inputs sent (%d)" % sent)
	t.eq(bad_cam, 0, "frames on which the camera drawn is not the camera sight is judged from")
	t.eq(bad_sent, 0, "inputs whose eye is not the eye the screen was drawn from on that frame")
	t.check(float(highs["creep"]) < CREEP_BELOW, "creeping drops the eyes below %.2f m (highest %.2f)" % [CREEP_BELOW, highs["creep"]])
	t.check(float(lows["stand"]) == EyeHeight.STAND and float(highs["stand"]) == EyeHeight.STAND, "standing: %.2f m" % EyeHeight.STAND)
	t.check(float(highs["down"]) < DOWN_BELOW, "down: below %.2f m (highest %.2f)" % [DOWN_BELOW, highs["down"]])
	t.check(host_creep == EyeHeight.CREEP, "the host is sent the creeping eye (lowest it had %.2f)" % host_creep)

# --- seeing over an edge -------------------------------------------------------------------------

## Whether a camera at `body` + `eye`, aimed at the figure's chest, could be showing a figure at `fig`.
static func _sees(plan: Floor.FloorPlan, body: Move.Body, eye: float, fig: Move.Body) -> bool:
	var yaw := atan2(-(fig.x - body.x), -(fig.z - body.z))
	var pitch := atan2(fig.y + 1.3 - (body.y + eye), Vector2(fig.x - body.x, fig.z - body.z).length())
	var cam := Pose.Camera.make(body, eye, yaw, pitch, 90.0, 70.0)
	return Session.camera_sees(plan, cam, _pose(fig), false)

static func _pose(b: Move.Body) -> Dictionary:
	return {"x": b.x, "y": b.y, "z": b.z, "level": b.level, "yaw": 0.0, "anim": "idle", "animTime": 0.0}

## A Clinic floor where a standing player under an atrium opening sees the Orderly standing on the
## floor above, back from the opening's edge, and the same player creeping does not (the slab's edge
## hides it): with 0.1 m to spare either way. {seed, cell (Floor.Pos), offset [dx, dz], fig (Move.Body)}.
static func find_slab_edge() -> Dictionary:
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for n in 60:
		var seed := "eye-edge-%d" % n
		var plan := Session.plan_for(seed, 1)
		for y in plan.height:
			for x in plan.width:
				if Floor.cell_at(plan, 1, x, y) != Floor.ATRIUM_OPEN or not Floor.is_walkable(plan, 0, x, y):
					continue
				var at := Move.body_at_cell(plan, Floor.Pos.make(0, x, y))
				for d in dirs:
					for k in range(1, 5):
						var fx := x + d.x * k
						var fy := y + d.y * k
						if Floor.cell_at(plan, 1, fx, fy) == Floor.ATRIUM_OPEN or not Floor.is_walkable(plan, 1, fx, fy):
							continue
						var fig := Move.body_at_cell(plan, Floor.Pos.make(1, fx, fy))
						for i in range(-6, 7):
							var ok := true
							for j: int in [i - 1, i, i + 1]:
								var o := 0.1 * j
								var b := Move.Body.make(at.x + d.x * o, at.z + d.y * o, 0, at.y)
								if not _sees(plan, b, EyeHeight.STAND, fig) or _sees(plan, b, EyeHeight.CREEP, fig):
									ok = false
									break
							if ok:
								return {"seed": seed, "cell": Floor.Pos.make(0, x, y), "offset": [d.x * 0.1 * i, d.y * 0.1 * i], "fig": fig}
	return {}

func test_creeping_hides_what_is_over_an_edge_and_standing_shows_it(t: T) -> void:
	var found := find_slab_edge()
	if not t.check(not found.is_empty(), "a Clinic floor with an Orderly above an atrium's edge (seeds eye-edge-0..59)"):
		return
	var cell: Floor.Pos = found["cell"]
	var fig: Move.Body = found["fig"]
	var link := _start(str(found["seed"]))
	var clock := [0.0]
	_until_placed(link, clock)
	var tp := link.teleport(cell.level, cell.x, cell.y)
	var nd := link.nudge(float(found["offset"][0]), float(found["offset"][1]))
	t.check(tp["ok"] == true and nd["ok"] == true, "the player is put under the opening")
	var b := link.body
	t.note("%s: player at (%.2f, %.2f) on level 0, the Orderly at (%.2f, %.2f) on level 1, %.1f m away" % [found["seed"], b.x, b.z, fig.x, fig.z, Vector2(fig.x - b.x, fig.z - b.z).length()])
	var pose := _pose(fig)
	var plan := link.plan
	var results := {}
	# Creep, stand, creep: each long enough for the camera to settle, aimed at the figure's chest
	# from where the eyes are on that frame. Judged with the client's own camera for the frame.
	for leg: Array in [["creep", true], ["stand", false], ["creep again", true]]:
		var seen := false
		var eye := 0.0
		for i in 30:
			clock[0] += DT
			var e := link.eye
			var yaw := atan2(-(fig.x - b.x), -(fig.z - b.z))
			var pitch := atan2(fig.y + 1.3 - (b.y + e), Vector2(fig.x - b.x, fig.z - b.z).length())
			var s := _frame(link, clock[0], leg[1], yaw, pitch)
			var lc := link.client().last_camera
			seen = Session.camera_sees(plan, lc, pose, Session.doors_open_in(s.get("phase", "")))
			eye = lc.eye
		results[leg[0]] = seen
		t.note("%s: eye %.2f m, the Orderly %s" % [leg[0], eye, "counted as seen" if seen else "not counted as seen"])
	t.check(results["creep"] == false, "creeping under the edge: the Orderly beyond it is not counted as seen")
	t.check(results["stand"] == true, "standing up: it is")
	t.check(results["creep again"] == false, "creeping again: it is not")
