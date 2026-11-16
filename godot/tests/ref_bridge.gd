# The client's rules bridge (client/rules_bridge.gd) against the reference host it replaces
# (tools/rules_host.ts, the real TypeScript rules), on the scripted sequences of tools/bridge_script.ts:
# every request is replayed and every reply compared. Per request: the reply without its events and
# plan must give the same canonical digest with the pay fields masked (everything else exact), every
# event must match, every plan field by field, the full reply every 20 requests and the last, and the
# pay-derived values of every reply within 1e-9 (tools/dump_reference.ts dumpBridge).
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Trace = preload("res://tests/trace.gd")
const Bridge = preload("res://client/rules_bridge.gd")

var _ref: Variant = null

func _scenes() -> Array:
	if _ref == null:
		_ref = Snap.load_ref("bridge.json")
	return (_ref as Dictionary)["scenes"]

static func _request(row: Variant, keys: Array) -> Dictionary:
	if row is Dictionary:
		return row
	var a: Array = row
	var d := {"op": "frame"}
	for i in keys.size():
		d[keys[i]] = a[i]
	return d

static func _dispatch(b: Bridge, req: Dictionary) -> Dictionary:
	match str(req["op"]):
		"start":
			return b.start(str(req["seed"]), int(req["depth"]), bool(req["entity"]))
		"frame":
			var d := req.duplicate()
			d.erase("op")
			return b.step(d)
		"teleport":
			return b.teleport(int(req["level"]), int(req["x"]), int(req["y"]))
		"walkTo":
			return b.walk_to(int(req["level"]), int(req["x"]), int(req["y"]), float(req["pace"]) if req.has("pace") else 3.0)
		"nudge":
			return b.nudge(float(req["dx"]), float(req["dz"]))
		"stopWalk":
			return b.stop_walk()
		"debug":
			return b.debug_info()
	push_error("unknown request " + str(req["op"]))
	return {}

## dump_reference.ts payOf.
static func _pay(r: Dictionary) -> Array:
	var inst: Variant = r.get("inst")
	var tapes: Variant = r.get("tapes")
	var summary: Variant = r.get("summary")
	var id: Dictionary = inst if inst is Dictionary else {}
	var td: Dictionary = tapes if tapes is Dictionary else {}
	var sd: Dictionary = summary if summary is Dictionary else {}
	return [id.get("value"), id.get("rate"), id.get("tickHz"), id.get("loudness"), td.get("value"), r.get("ticks"), sd.get("total")]

func _replay(t: T, scene: Dictionary) -> void:
	var b := Bridge.new()
	var tr := Trace.new(scene["trace"])
	var plans: Dictionary = scene["plans"]
	var keys: Array = scene["frameKeys"]
	var requests: Array = scene["requests"]
	var plan_diff := Snap.Diff.new()
	var plans_seen := 0
	var frames := 0
	var frame_us := 0
	var frame_max := 0
	for k in requests.size():
		var req := _request(requests[k], keys)
		var f0 := Time.get_ticks_usec()
		var reply := _dispatch(b, req)
		if req["op"] == "frame":
			frames += 1
			var us := Time.get_ticks_usec() - f0
			frame_us += us
			frame_max = maxi(frame_max, us)
		var rest := reply.duplicate()
		var events: Array = rest.get("events", [])
		rest.erase("events")
		if rest.has("plan") or plans.has(str(k)):
			plans_seen += 1
			if not plans.has(str(k)):
				t.check(false, "%s@%d: a plan the reference does not have" % [scene["name"], k])
			elif not rest.has("plan"):
				t.check(false, "%s@%d: no plan, the reference has one" % [scene["name"], k])
			else:
				plan_diff.add(Snap.compare(rest["plan"], plans[str(k)], "%s@%d.plan" % [scene["name"], k]))
			rest.erase("plan")
		tr.tick(rest, events, _pay(reply))
	var d := tr.finish(t, true)
	t.eq(plans_seen, plans.size(), "%s: plans" % scene["name"])
	t.check(plan_diff.ok(), "%s: plans: %s" % [scene["name"], plan_diff.summary()])
	t.note("%s: %d requests (%d frames; the bridge took %.2f ms a frame, at most %.1f ms), %d plans; first difference: %s; %s" % [scene["name"], requests.size(),
		frames, frame_us / 1000.0 / maxi(frames, 1), frame_max / 1000.0, plans_seen, tr.first_difference(), d.summary()])
	b.free()

func test_bank_run(t: T) -> void:
	_replay(t, _scenes()[0])

func test_ride_down(t: T) -> void:
	_replay(t, _scenes()[1])

func test_start_deeper(t: T) -> void:
	_replay(t, _scenes()[2])
