# The Temp's on-screen smoothness, measured (PT4). Headless, no window:
#   godot --headless --path godot --script res://tools/temp_jitter.gd [-- seconds=90 seed=annex-1]
# Two kinds of run, each printing one line from tools/temp_meter.gd:
#  - "line": the client's own pipeline on a made-up walk. The host's 20 Hz snapshots (quantised as
#    net/pose.gd quant_pose sends them) of a Temp walking a zigzag at a steady speed, drawn at 60 or 144
#    frames a second through Pose.lerp_pose, with frame times wobbling 15% and the render clock slewing 5%,
#    as net/client.gd's _render_time does.
#  - "room": the real thing alone: a LocalRoom on the Annex (depth 3, the playtest entry), the human
#    standing and looking at the Temp, teleported to another room when it comes within 3 m, the frames the
#    game's client gives (net/client.gd Frame) fed to a TempView exactly as client/main.gd does.
extends SceneTree

const View = preload("res://client/temp_view.gd")
const Meter = preload("res://tools/temp_meter.gd")
const Pose = preload("res://net/pose.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Client = preload("res://net/client.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")

var _done := false

# The views must be inside the tree (their bone turns read global transforms): run on the first frame.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	var seconds := float(args.get("seconds", "90"))
	var seed := str(args.get("seed", "annex-1"))
	if str(args.get("only", "")) != "room":
		for fps: float in [60.0, 144.0]:
			for speed: float in [1.0, 2.0, 2.6, 3.9]:
				print(run_line(self, speed, fps, 20.0).line("line %.1f m/s at %d fps" % [speed, int(fps)]))
	if str(args.get("only", "")) != "line":
		print(run_room(self, seed, seconds, 60.0))
	quit(0)
	return true

## The client pipeline on a zigzag walk at `pace` (m/s, or an Array of [from host second, m/s] steps), drawn
## at `fps`, for `seconds` of host time. `setup` (if valid) is called with the view first (tests: the breaks).
## Returns the Meter (and frees the view).
static func run_line(tree: SceneTree, pace: Variant, fps: float, seconds: float, seed := 11, setup := Callable()) -> Meter:
	var view := View.new()
	tree.root.add_child(view)
	if setup.is_valid():
		setup.call(view)
	var meter := Meter.new(view)
	var snaps := line_snaps(pace, seconds)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var rt := 0.0
	var i := 0
	while rt < seconds - Session.TICK:
		var dt := (1.0 / fps) * (1.0 + rng.randf_range(-0.15, 0.15))
		rt += dt * (1.0 + 0.05 * sin(rt * 1.7))
		while i + 1 < snaps.size() and float(snaps[i + 1]["ht"]) <= rt:
			i += 1
		var a: Dictionary = snaps[i]
		var b: Dictionary = snaps[mini(i + 1, snaps.size() - 1)]
		var alpha := 0.0 if b == a else clampf((rt - float(a["ht"])) / Session.TICK, 0.0, 1.0)
		var pose := Pose.lerp_pose(a["pose"], b["pose"], alpha)
		view.set_watched(null)
		view.show_pose(pose, true)
		meter.feed(view, pose)
	view.free()
	return meter

## Host snapshots of a Temp walking a zigzag (4 m along x, 4 m along z, ...) at `pace` (see run_line).
static func line_snaps(pace: Variant, seconds: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := int(seconds / Session.TICK) + 2
	var d := 0.0
	for k in n:
		var t := k * Session.TICK
		if k > 0:
			d += _pace_at(pace, t) * Session.TICK
		var leg := floori(d / 4.0)
		var into := d - leg * 4.0
		var x := 2.0 + 4.0 * ceili(leg / 2.0) + (into if leg % 2 == 0 else 0.0)
		var z := 2.0 + 4.0 * floori(leg / 2.0) + (into if leg % 2 == 1 else 0.0)
		var yaw := -PI * 0.5 if leg % 2 == 0 else PI
		out.append({"ht": t, "pose": Pose.quant_pose({"x": x, "y": 0.0, "z": z, "level": 0, "yaw": yaw, "anim": "walk", "animTime": t})})
	return out

static func _pace_at(pace: Variant, t: float) -> float:
	if pace is Array:
		var v := 0.0
		for step: Array in pace:
			if t >= float(step[0]):
				v = float(step[1])
		return v
	return float(pace)

## The real local room on the Annex. Returns the Meter's line plus what the host said about its speeds.
static func run_room(tree: SceneTree, seed: String, seconds: float, fps: float) -> String:
	var old_deck := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.open_local(seed, "Player", true)
	if not room.start_playtest(3) or room.host.state.plan.place != Places.ANNEX:
		Session.deck = old_deck
		return "room: no Annex at depth 3 for seed %s" % seed
	var view := View.new()
	tree.root.add_child(view)
	var meter := Meter.new(view)
	var body: Move.Body = room.host.state.players[0].body
	var plan: Floor.FloorPlan = room.host.state.plan
	var spots: Array[Move.Body] = []
	for r: Floor.Room in plan.rooms:
		if r.level == 0:
			spots.append(Move.body_at_cell(plan, Floor.Pos.make(0, r.x + r.w / 2, r.y + r.h / 2)))
	var speeds := {}
	var hops := 0
	var now := 0.0
	var frame_dt := 1.0 / fps
	while now < seconds:
		now += frame_dt
		room.poll(now)
		var s := room.host.state
		if s == null:
			break
		var o := s.orderly
		speeds[snappedf(o.speed, 0.1)] = int(speeds.get(snappedf(o.speed, 0.1), 0)) + 1
		var input := Client.LocalFrame.new()
		var dx := o.body.x - body.x
		var dz := o.body.z - body.z
		if (s.phase == &"away" or s.phase == &"unloading") and not spots.is_empty() and (hops == 0 or (o.body.level == body.level and Vector2(dx, dz).length() < 3.0)):
			# Out of the lift at once, then away to the next room whenever it comes close.
			body = spots[(hops * 7) % spots.size()]
			hops += 1
		if int(now * fps) % int(fps * 10.0) == 0:
			print("  room t=%.0f phase %s mode %s anim %s speed %.2f" % [now, s.phase, o.mode, o.anim, o.speed])
		input.body = body
		input.eye = 1.6
		input.h_fov_deg = 90.0
		input.v_fov_deg = 65.0
		input.yaw = atan2(-dx, -dz)
		var f := room.frame(now, input)
		if f == null:
			break
		if f.placed != null:
			body = f.placed
		var watched: Variant = null
		if f.watched_by != "":
			watched = [body.x, body.y + 1.6, body.z]
		view.set_watched(watched)
		view.show_pose(f.orderly, f.visible)
		meter.feed(view, f.orderly)
	room.leave()
	view.free()
	for l in meter.log:
		print("  ", l)
	Session.deck = old_deck
	var keys := speeds.keys()
	keys.sort()
	var hist := PackedStringArray()
	for k: Variant in keys:
		if float(k) > 0.0:
			hist.append("%.1f:%d" % [k, speeds[k]])
	return meter.line("room %s %.0f s at %d fps (%d teleports)" % [seed, seconds, int(fps), hops]) + "; host speeds (m/s:frames) " + ", ".join(hist)
