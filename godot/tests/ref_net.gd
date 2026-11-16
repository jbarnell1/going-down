# The network port (godot/net) against the TypeScript networking it replaces (src/net), on the
# scripted scenes of tools/net_script.ts (dump_reference.ts job 'net', tests/reference/net.json).
# Each scene is replayed with the same machines, clocks and seeded network, every machine handed
# the same LocalFrame on every frame, and compared exactly:
#   - every message on the network: its length, and the decoded message with its sender, receiver
#     and time, pay fields masked (the unmasked digest may differ only by pow's last bits, which the
#     masked one hides; see godot/README.md); and how many texts are identical byte for byte;
#   - every frame of every client: the canonical digest of what it draws (dark, the Orderly's pose,
#     held, seeing, taken, the other players, the render clock, placements, its tank, events), and
#     the whole record every 120 frames;
#   - the host's run state after every tick (Trace: digests, events, snapshots) and its counters,
#     and every client's counters.
# Plus the exact JSON numbers the protocol relies on (net/jsjson.gd) on the reference's own texts.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Trace = preload("res://tests/trace.gd")
const NetScene = preload("res://tests/net_scene.gd")
const NetRef = preload("res://tests/net_lib.gd")

var _ref: Variant = null

func _scenes() -> Array:
	if _ref == null:
		_ref = Snap.load_ref("net.json")
	return (_ref as Dictionary)["scenes"]

func _scene(name: String) -> Dictionary:
	for s: Dictionary in _scenes():
		if s["name"] == name:
			return s
	push_error("no scene " + name)
	return {}

func _replay(t: T, want: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var sc := NetScene.new(want)
	sc.run()
	var name: String = want["name"]
	# Messages.
	var msgs: Dictionary = want["msgs"]
	var n: int = msgs["n"]
	t.eq(sc.sends.size(), n, "%s: messages" % name)
	var lens: Array = msgs["lens"]
	var mask: String = msgs["mask"]
	var full: String = msgs["full"]
	var text: String = msgs["text"]
	var route: String = msgs["route"]
	var bad_len := 0
	var bad_mask := 0
	var bad_full := 0
	var same_text := 0
	var first := ""
	for i in mini(n, sc.sends.size()):
		var s: Array = sc.sends[i]
		var data: String = s[3]
		if data.length() != int(lens[i]):
			bad_len += 1
		# The same text (and so the same message) needs no decoding; the time, sender and receiver
		# are compared through the digests of the others and through every frame and tick.
		var rt := ("%s|%s|%s" % [Snap.M.to_hex(s[0]), s[1], s[2]]).md5_text().substr(0, 8)
		if data.md5_text().substr(0, 8) == text.substr(i * 8, 8) and rt == route.substr(i * 8, 8):
			same_text += 1
			continue
		var d := NetRef.message_digests(s)
		if d[0] != mask.substr(i * 8, 8):
			bad_mask += 1
			if first.is_empty():
				first = "message %d (%s>%s at %s): %s" % [i, s[1], s[2], s[0], data.left(300)]
		if d[1] != full.substr(i * 8, 8):
			bad_full += 1
	t.check(bad_mask == 0, "%s: %d of %d messages differ (first: %s)" % [name, bad_mask, n, first])
	t.check(bad_len == 0, "%s: %d messages of another length" % [name, bad_len])
	# Frames.
	var frames: Dictionary = want["frames"]
	var frame_bad := 0
	var frame_first := ""
	var full_diff := Snap.Diff.new()
	var frame_count := 0
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
	var tr := Trace.new(want["host"])
	for h: Array in sc.host_states:
		tr.tick(Snap.run(h[1]), h[2])
	var hd := tr.finish(t, true)
	# Counters.
	var hs := Snap.compare(sc.host.stats.to_dict(), _without(want["hostStats"], ["putBackDistances"]), "%s.hostStats" % name)
	t.check(hs.ok(), "%s: host counters: %s" % [name, hs.summary()])
	var pbd: Array = want["hostStats"]["putBackDistances"]
	t.check(Snap.compare(Array(sc.host.stats.put_back_distances), pbd).ok(), "%s: put-back distances" % name)
	t.eq(sc.host.event_log.size(), int(want["logLength"]), "%s: events logged" % name)
	var cs: Dictionary = want["clientStats"]
	for id: String in cs:
		var c: Variant = sc.clients.get(id)
		if c == null:
			t.check(false, "%s: no client %s" % [name, id])
			continue
		var cd := Snap.compare(NetRef.client_stats(c), cs[id], "%s.%s.stats" % [name, id])
		t.check(cd.ok(), "%s %s: client counters: %s" % [name, id, cd.summary()])
	t.note("%s: %d messages (%d texts identical byte for byte, the rest equal once decoded (key order of bodies in events); %d differ only in pay bits), %d frames, %d host ticks, %d events; host state first differs: %s; %s; %.1f s" % [
		name, n, same_text, bad_full, frame_count, sc.host.tick, sc.host.event_log.size(), tr.first_difference(), hd.summary(), (Time.get_ticks_msec() - t0) / 1000.0])

static func _without(d: Dictionary, keys: Array) -> Dictionary:
	var out := d.duplicate()
	for k: String in keys:
		out.erase(k)
	return out

func test_pair_0ms(t: T) -> void:
	_replay(t, _scene("pair-0ms"))

func test_pair_100ms(t: T) -> void:
	if t.quick:
		return
	_replay(t, _scene("pair-100ms"))

func test_trio_300ms_jitter(t: T) -> void:
	_replay(t, _scene("trio-300ms-jitter"))

func test_catch_latch(t: T) -> void:
	_replay(t, _scene("catch-latch"))

func test_lossy(t: T) -> void:
	if t.quick:
		return
	_replay(t, _scene("lossy"))

func test_four_bank(t: T) -> void:
	if t.quick:
		return
	_replay(t, _scene("four-bank"))

func test_ride_join_leave(t: T) -> void:
	if t.quick:
		return
	_replay(t, _scene("ride-join-leave"))

## The protocol's numbers: every reference message text read and written again by net/jsjson.gd
## gives the same text (JavaScript's own number formatting and exact reading).
func test_json_numbers(t: T) -> void:
	const JsJson = preload("res://net/jsjson.gd")
	var texts := 0
	var bad := 0
	var first := ""
	for s: Dictionary in _scenes():
		var samples: Dictionary = s["msgs"]["samples"]
		for k: String in samples:
			var txt: String = samples[k]
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
	t.note("%d message texts read and written back" % texts)
