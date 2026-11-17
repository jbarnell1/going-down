# The network port (godot/net) on the scripted scenes of tests/inputs/net.json (machines, links,
# clocks and every machine's LocalFrame per frame; made once by tools/net_script.ts), against
# tests/golden/net.json. Each scene is replayed with the same machines, clocks and seeded network,
# every machine handed the same LocalFrame on every frame, and compared exactly:
#   - every message on the network: its text byte for byte, its length, its time, sender and receiver;
#   - every frame of every client: the canonical digest of what it draws (dark, the Orderly's pose,
#     held, seeing, taken, the other players, the render clock, placements, its tank, events), and
#     the whole record every 120 frames;
#   - the host's run state after every tick (Trace: digests, events, snapshots) and its counters,
#     and every client's counters.
# Plus the exact JSON numbers the protocol relies on (net/jsjson.gd), on texts JavaScript wrote
# (tests/inputs/js_texts.json) and on the goldens' own texts.
# (The first goldens were proved equal to src/net, the TypeScript networking this replaced: every
# message equal once decoded, pay within 1e-9; check_goldens_against_typescript.mjs.)
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Golden = preload("res://tests/golden.gd")
const Trace = preload("res://tests/trace.gd")
const NetScene = preload("res://tests/net_scene.gd")
const NetRef = preload("res://tests/net_lib.gd")

## The scripted scenes (inputs).
func _scenes() -> Array:
	return (Golden.input("net.json") as Dictionary)["scenes"]

func _index(name: String) -> int:
	var scenes := _scenes()
	for i in scenes.size():
		if scenes[i]["name"] == name:
			return i
	push_error("no scene " + name)
	return -1

static func _route(s: Array) -> String:
	return ("%s|%s|%s" % [Snap.M.to_hex(s[0]), s[1], s[2]]).md5_text().substr(0, 8)

## What godot:golden records of a replayed scene (the format of dump_reference.ts dumpNet).
static func record(sc: NetScene, host: Trace) -> Dictionary:
	var mask := PackedStringArray()
	var full := PackedStringArray()
	var text := PackedStringArray()
	var route := PackedStringArray()
	var lens: Array = []
	var samples := {}
	for i in sc.sends.size():
		var s: Array = sc.sends[i]
		var data: String = s[3]
		var d := NetRef.message_digests(s)
		mask.append(d[0])
		full.append(d[1])
		text.append(data.md5_text().substr(0, 8))
		route.append(_route(s))
		lens.append(data.length())
		if i % 250 == 0:
			samples[str(i)] = data
	var frames := {}
	for id: String in sc.frames:
		var list: Array = sc.frames[id]
		var digests := PackedStringArray()
		var fulls := {}
		for k in list.size():
			digests.append(Snap.digest(list[k], false))
			if k % 120 == 0 or k == list.size() - 1:
				fulls[str(k)] = list[k]
		frames[id] = {"n": list.size(), "digests": "".join(digests), "full": fulls}
	var hs: Dictionary = sc.host.stats.to_dict()
	hs["putBackDistances"] = Array(sc.host.stats.put_back_distances)
	var cs := {}
	for id: String in sc.clients:
		cs[id] = NetRef.client_stats(sc.clients[id])
	return {
		"name": sc.want["name"], "frames": frames,
		"msgs": {"n": sc.sends.size(), "mask": "".join(mask), "full": "".join(full), "text": "".join(text), "route": "".join(route), "lens": lens, "samples": samples},
		"host": host.to_golden(), "hostStats": hs, "clientStats": cs, "logLength": sc.host.event_log.size(),
	}

func _replay(t: T, index: int) -> void:
	var t0 := Time.get_ticks_msec()
	var spec: Dictionary = _scenes()[index]
	var name: String = spec["name"]
	var want: Variant = Golden.item(t.golden("net.json", "scenes"), index)
	var sc := NetScene.new(spec)
	sc.run()
	var tr := Trace.new(name, 100, want["host"] if want is Dictionary else null)
	for h: Array in sc.host_states:
		tr.tick(Snap.run(h[1]), h[2])
	if t.recording:
		tr.finish(t)
		Golden.put_item("net.json", "scenes", index, record(sc, tr))
		t.note("%s: %d messages, %d host ticks recorded in %.1f s" % [name, sc.sends.size(), sc.host.tick, (Time.get_ticks_msec() - t0) / 1000.0])
		return
	if not (want is Dictionary):
		t.check(false, "%s: not in the golden (run npm run godot:golden)" % name)
		return
	t.eq(String(want["name"]), name, "scene name")
	# Messages: the text byte for byte, its route and length; when a text differs, whether the
	# decoded message differs outside the pay fields too.
	var msgs: Dictionary = want["msgs"]
	var n: int = msgs["n"]
	t.eq(sc.sends.size(), n, "%s: messages" % name)
	var lens: Array = msgs["lens"]
	var mask: String = msgs["mask"]
	var text: String = msgs["text"]
	var route: String = msgs["route"]
	var bad_len := 0
	var bad_text := 0
	var bad_route := 0
	var bad_mask := 0
	var first := ""
	for i in mini(n, sc.sends.size()):
		var s: Array = sc.sends[i]
		var data: String = s[3]
		if data.length() != int(lens[i]):
			bad_len += 1
		if _route(s) != route.substr(i * 8, 8):
			bad_route += 1
			if first.is_empty():
				first = "message %d (%s>%s at %s) sent at another time or between other machines" % [i, s[1], s[2], s[0]]
		if data.md5_text().substr(0, 8) != text.substr(i * 8, 8):
			bad_text += 1
			var outside_pay := NetRef.message_digests(s)[0] != mask.substr(i * 8, 8)
			if outside_pay:
				bad_mask += 1
			if first.is_empty():
				first = "message %d (%s>%s at %s)%s: %s" % [i, s[1], s[2], s[0], "" if outside_pay else " (in the pay fields only)", data.left(300)]
	t.check(bad_text == 0 and bad_route == 0, "%s: %d of %d message texts differ (%d outside the pay fields), %d routes differ (first: %s)" % [name, bad_text, n, bad_mask, bad_route, first])
	t.check(bad_len == 0, "%s: %d messages of another length" % [name, bad_len])
	# Frames.
	var frames: Dictionary = want["frames"]
	var frame_bad := 0
	var frame_first := ""
	var full_diff := Snap.Diff.new()
	var frame_count := 0
	t.eq(sc.frames.size(), frames.size(), "%s: clients drawing" % name)
	for id: String in frames:
		var wf: Dictionary = frames[id]
		var got: Array = sc.frames.get(id, [])
		t.eq(got.size(), int(wf["n"]), "%s %s: frames" % [name, id])
		var digests: String = wf["digests"]
		var fulls: Dictionary = wf["full"]
		for k in mini(got.size(), int(wf["n"])):
			frame_count += 1
			if Snap.digest(got[k], false) != digests.substr(k * 8, 8):
				frame_bad += 1
				if frame_first.is_empty():
					frame_first = "%s frame %d" % [id, k]
			if fulls.has(str(k)):
				full_diff.add(Snap.compare(got[k], fulls[str(k)], "%s %s frame %d" % [name, id, k]))
	t.check(frame_bad == 0, "%s: %d of %d frames differ (first: %s)" % [name, frame_bad, frame_count, frame_first])
	t.check(full_diff.ok(), "%s: frame records: %s" % [name, full_diff.summary()])
	# The host, tick by tick.
	var hd := tr.finish(t)
	# Counters.
	var hs := Snap.compare(sc.host.stats.to_dict(), _without(want["hostStats"], ["putBackDistances"]), "%s.hostStats" % name)
	t.check(hs.ok(), "%s: host counters: %s" % [name, hs.summary()])
	var pbd: Array = want["hostStats"]["putBackDistances"]
	var pd := Snap.compare(Array(sc.host.stats.put_back_distances), pbd)
	t.check(pd.ok(), "%s: put-back distances: %s" % [name, pd.summary()])
	t.eq(sc.host.event_log.size(), int(want["logLength"]), "%s: events logged" % name)
	var cs: Dictionary = want["clientStats"]
	t.eq(sc.clients.size(), cs.size(), "%s: clients" % name)
	for id: String in cs:
		var c: Variant = sc.clients.get(id)
		if c == null:
			t.check(false, "%s: no client %s" % [name, id])
			continue
		var cd := Snap.compare(NetRef.client_stats(c), cs[id], "%s.%s.stats" % [name, id])
		t.check(cd.ok(), "%s %s: client counters: %s" % [name, id, cd.summary()])
	t.note("%s: %d messages (texts identical byte for byte: %d), %d frames, %d host ticks, %d events; host state first differs: %s; %s; %.1f s" % [
		name, n, n - bad_text, frame_count, sc.host.tick, sc.host.event_log.size(), tr.first_difference(), hd.summary(), (Time.get_ticks_msec() - t0) / 1000.0])

static func _without(d: Dictionary, keys: Array) -> Dictionary:
	var out := d.duplicate()
	for k: String in keys:
		out.erase(k)
	return out

func test_pair_0ms(t: T) -> void:
	_replay(t, _index("pair-0ms"))

func test_pair_100ms(t: T) -> void:
	if t.quick:
		return
	_replay(t, _index("pair-100ms"))

func test_trio_300ms_jitter(t: T) -> void:
	_replay(t, _index("trio-300ms-jitter"))

func test_catch_latch(t: T) -> void:
	_replay(t, _index("catch-latch"))

func test_lossy(t: T) -> void:
	if t.quick:
		return
	_replay(t, _index("lossy"))

func test_four_bank(t: T) -> void:
	if t.quick:
		return
	_replay(t, _index("four-bank"))

## The first 12 s of four-bank, in every run (the whole scene runs only in the default run): four
## players over links of 50 to 300 ms watching the Orderly, so the host holds it on what the clients
## say they see and what they report. Replayed to 12 s and compared with the beginning of the golden
## record of the whole scene: every host tick's state, its events and snapshots, every message (text,
## route, length) and every drawn frame up to then.
func test_four_bank_opening(t: T) -> void:
	if t.recording:
		return  # it reads the record of the whole scene, which test_four_bank records
	var t0 := Time.get_ticks_msec()
	var index := _index("four-bank")
	var spec: Dictionary = (_scenes()[index] as Dictionary).duplicate()
	spec["until"] = 12.0
	var name := "four-bank (first 12 s)"
	var want: Variant = Golden.item(t.golden("net.json", "scenes"), index)
	if not (want is Dictionary):
		t.check(false, "four-bank: not in the golden (run npm run godot:golden)")
		return
	var sc := NetScene.new(spec)
	sc.run()
	# The host, tick by tick, against the first ticks of the whole scene's record.
	var tr := Trace.new(name, 100, want["host"])
	for h: Array in sc.host_states:
		tr.tick(Snap.run(h[1]), h[2])
	t.check(tr.ticks <= int(want["host"]["ticks"]), "%s: %d host ticks, the golden has %d" % [name, tr.ticks, int(want["host"]["ticks"])])
	t.check(tr.full_bad == 0, "%s: host state differs from the golden from tick %d (%d ticks differ; %s)" % [name, tr.full_first, tr.full_bad, tr.first_difference()])
	t.check(tr.snap_diff.ok(), "%s: host snapshots: %s" % [name, tr.snap_diff.summary()])
	var want_events: Array = []
	for ev: Array in want["host"]["events"]:
		if int(ev[0]) < tr.ticks:
			want_events.append(ev)
	var ed := Snap.compare(tr.events, want_events, "%s.events" % name)
	t.check(ed.ok(), "%s: host events: %s" % [name, ed.summary()])
	# Messages.
	var msgs: Dictionary = want["msgs"]
	var text: String = msgs["text"]
	var route: String = msgs["route"]
	var lens: Array = msgs["lens"]
	t.check(sc.sends.size() <= int(msgs["n"]), "%s: %d messages, the golden has %d" % [name, sc.sends.size(), int(msgs["n"])])
	var bad := 0
	var first := ""
	for i in mini(sc.sends.size(), int(msgs["n"])):
		var s: Array = sc.sends[i]
		var data: String = s[3]
		if data.md5_text().substr(0, 8) != text.substr(i * 8, 8) or _route(s) != route.substr(i * 8, 8) or data.length() != int(lens[i]):
			bad += 1
			if first.is_empty():
				first = "message %d (%s>%s at %s): %s" % [i, s[1], s[2], s[0], data.left(300)]
	t.check(bad == 0, "%s: %d of %d messages differ from the golden (first: %s)" % [name, bad, sc.sends.size(), first])
	# Frames.
	var frames: Dictionary = want["frames"]
	var frame_bad := 0
	var frame_count := 0
	var frame_first := ""
	for id: String in frames:
		var got: Array = sc.frames.get(id, [])
		var digests: String = frames[id]["digests"]
		for k in mini(got.size(), int(frames[id]["n"])):
			frame_count += 1
			if Snap.digest(got[k], false) != digests.substr(k * 8, 8):
				frame_bad += 1
				if frame_first.is_empty():
					frame_first = "%s frame %d" % [id, k]
	t.check(frame_bad == 0, "%s: %d of %d frames differ (first: %s)" % [name, frame_bad, frame_count, frame_first])
	t.note("%s: %d messages, %d frames, %d host ticks, %d events compared with the golden; host state first differs: %s; %.1f s" % [
		name, sc.sends.size(), frame_count, tr.ticks, tr.events.size(), tr.first_difference(), (Time.get_ticks_msec() - t0) / 1000.0])

func test_ride_join_leave(t: T) -> void:
	if t.quick:
		return
	_replay(t, _index("ride-join-leave"))

## The protocol's numbers: message texts read and written again by net/jsjson.gd give the same
## text (JavaScript's own number formatting and exact reading): texts JavaScript wrote (the first
## reference's samples, tests/inputs/js_texts.json), and the goldens' own samples.
func test_json_numbers(t: T) -> void:
	const JsJson = preload("res://net/jsjson.gd")
	var all: Array = (Golden.input("js_texts.json") as Array).duplicate()
	var js := all.size()
	if not t.recording:
		var g: Variant = t.golden("net.json", "scenes")
		if g is Array:
			for s: Variant in g:
				if s is Dictionary:
					var samples: Dictionary = s["msgs"]["samples"]
					for k: String in samples:
						all.append(samples[k])
	var texts := 0
	var bad := 0
	var first := ""
	for txt: String in all:
		var p := JsJson.parse(txt)
		texts += 1
		if not p.ok or JsJson.stringify(p.value) != txt:
			bad += 1
			if first.is_empty():
				first = txt.left(200)
	t.check(bad == 0, "%d of %d texts not written back identically (first: %s)" % [bad, texts, first])
	# Shortest round trip on awkward values.
	# (bits, JavaScript's text): 0.1, 0.1 + 0.05, 1e21, 1.5e-7, 123456789012345680000, -0, the smallest
	# subnormal, the largest double, 1e-6, 2.5, 100, 74.521636962890625 (an exact tie at 16 digits).
	var cases := [["3fb999999999999a", "0.1"], ["3fc3333333333334", "0.15000000000000002"], ["444b1ae4d6e2ef50", "1e+21"],
		["3e8421f5f40d8376", "1.5e-7"], ["441ac53a7e04bcda", "123456789012345680000"], ["8000000000000000", "0"],
		["0000000000000001", "5e-324"], ["7fefffffffffffff", "1.7976931348623157e+308"], ["3eb0c6f7a0b5ed8d", "0.000001"],
		["4004000000000000", "2.5"], ["4059000000000000", "100"], ["4052a16280000000", "74.52163696289062"]]
	for c: Array in cases:
		var x := Snap.M.from_hex(c[0])
		t.eq(JsJson.num(x), String(c[1]), "JavaScript's text of %s" % c[0])
		var p2 := JsJson.parse(c[1])
		t.check(p2.ok and Snap.M.to_hex(absf(float(p2.value)) if x == 0.0 else float(p2.value)) == (c[0] if x != 0.0 else "0000000000000000"), "reading %s" % c[1])
	t.note("%d message texts read and written back (%d written by JavaScript)" % [texts, js])
