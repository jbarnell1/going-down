# The client's rules bridge (client/rules_bridge.gd) on the scripted sequences of requests in
# tests/inputs/bridge.json (made once by tools/bridge_script.ts through the reference host it replaced,
# tools/rules_host.ts): every request is replayed and every reply compared with tests/golden/bridge.json.
# Per request: the canonical digest of the reply without its events and plan (pay included), every
# event, every plan field by field, the full reply every 20 requests and the last, and the pay-derived
# values of every reply, all exactly. (The first goldens were proved equal to the reference host's
# replies, pay within 1e-9: check_goldens_against_typescript.mjs.)
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Golden = preload("res://tests/golden.gd")
const Trace = preload("res://tests/trace.gd")
const Bridge = preload("res://client/rules_bridge.gd")

## The scripted requests (tests/inputs/bridge.json, written once by the historical bridge_script.ts).
func _scenes() -> Array:
	return (Golden.input("bridge.json") as Dictionary)["scenes"]

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

func _replay(t: T, index: int) -> void:
	var scene: Dictionary = _scenes()[index]
	var want: Variant = Golden.item(t.golden("bridge.json", "scenes"), index)
	var b := Bridge.new()
	var tr := Trace.new(scene["name"], 20, want["trace"] if want is Dictionary else null)
	var plans: Dictionary = want["plans"] if want is Dictionary else {}
	var got_plans := {}
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
		if t.recording:
			if rest.has("plan"):
				got_plans[str(k)] = rest["plan"]
				plans_seen += 1
				rest.erase("plan")
		elif rest.has("plan") or plans.has(str(k)):
			plans_seen += 1
			if not plans.has(str(k)):
				t.check(false, "%s@%d: a plan the golden does not have" % [scene["name"], k])
			elif not rest.has("plan"):
				t.check(false, "%s@%d: no plan, the golden has one" % [scene["name"], k])
			else:
				plan_diff.add(Snap.compare(rest["plan"], plans[str(k)], "%s@%d.plan" % [scene["name"], k]))
			rest.erase("plan")
		tr.tick(rest, events, _pay(reply))
	var d := tr.finish(t)
	if t.recording:
		Golden.put_item("bridge.json", "scenes", index, {"name": scene["name"], "trace": tr.to_golden(), "plans": got_plans})
	else:
		t.eq(plans_seen, plans.size(), "%s: plans" % scene["name"])
		t.check(plan_diff.ok(), "%s: plans: %s" % [scene["name"], plan_diff.summary()])
	t.note("%s: %d requests (%d frames; the bridge took %.2f ms a frame, at most %.1f ms), %d plans; first difference: %s; %s" % [scene["name"], requests.size(),
		frames, frame_us / 1000.0 / maxi(frames, 1), frame_max / 1000.0, plans_seen, tr.first_difference(), d.summary()])
	b.free()

func test_bank_run(t: T) -> void:
	_replay(t, 0)

func test_ride_down(t: T) -> void:
	_replay(t, 1)

func test_start_deeper(t: T) -> void:
	_replay(t, 2)
