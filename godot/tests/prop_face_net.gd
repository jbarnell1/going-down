# Drawn faces over the network (face/README.md "Wiring", North Star H1 and V7): the join's optional
# fifth element, what counts as no face, the host passing each face on once (and to a late joiner),
# never in the snapshot. Run alone with tests/run_face_net.gd.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Protocol = preload("res://net/protocol.gd")
const Transport = preload("res://net/transport.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Session = preload("res://net/session.gd")
const Move = preload("res://sim/move.gd")
const Codec = preload("res://face/face_codec.gd")
const Paint = preload("res://face/face_paint.gd")

## The worst case: random noise, which packs to the longest text (MAX_LENGTH).
static func noise_face(seed_text: String) -> String:
	var rng := Rng.make_rng(seed_text)
	var px := PackedByteArray()
	px.resize(Codec.PIXELS)
	for i in Codec.PIXELS:
		px[i] = rng.int_in(0, Codec.COLOURS - 1)
	return Codec.encode(px)

static func starter_face(which: String) -> String:
	return Codec.encode(Paint.starter(which))

func test_join_without_a_face_is_unchanged(t: T) -> void:
	var text := Protocol.encode({"type": "join", "name": "Ann", "ct": 1.5})
	t.eq(text, "[1,\"J\",\"Ann\",1.5]", "a join with no face is the four-element join it always was")
	var m: Variant = Protocol.decode(text)
	t.check(m is Dictionary and m["type"] == "join" and m["name"] == "Ann", "the four-element join still decodes")
	t.check(m is Dictionary and not (m as Dictionary).has("face"), "and has no face key (the reference digests stay the same)")
	t.eq(Protocol.encode({"type": "join", "name": "Ann", "ct": 1.5, "face": ""}), text, "an empty face sends no fifth element")

func test_join_with_the_worst_case_face(t: T) -> void:
	var face := noise_face("faces-noise")
	t.eq(face.length(), Codec.MAX_LENGTH, "the noise face is the longest a face can be")
	var name := "N".repeat(Protocol.MAX_NAME)
	var text := Protocol.encode({"type": "join", "name": name, "ct": 123456.789, "face": face})
	var bytes := Protocol.message_bytes(text)
	t.note("join with the worst-case face and a %d-character name: %d bytes" % [Protocol.MAX_NAME, bytes])
	t.check(bytes < 700, "under 700 bytes (got %d)" % bytes)
	var m: Variant = Protocol.decode(text)
	t.check(m is Dictionary and str((m as Dictionary).get("face", "")) == face, "the face comes through exactly")
	var smile := starter_face("smile")
	var m2: Variant = Protocol.decode(Protocol.encode({"type": "join", "name": "Bob", "ct": 2.0, "face": smile}))
	t.check(m2 is Dictionary and str((m2 as Dictionary).get("face", "")) == smile, "a small face comes through exactly")

func test_a_bad_face_is_no_face_and_the_player_still_joins(t: T) -> void:
	var face := noise_face("faces-noise")
	var bad: Array = [
		face + "A",                       # one character too long
		"x".repeat(5000),                 # far too long
		"F1R" + "!".repeat(512),          # bad characters
		"F1Rabc",                         # wrong length
		"F2L" + face.substr(3),           # unknown version
		"",                               # empty
		12345, null, true, [face], {"f": face},
	]
	for b: Variant in bad:
		var text := JSON.stringify([1, "J", "Ann", 1.0, b])
		var m: Variant = Protocol.decode(text)
		t.check(m is Dictionary and m["type"] == "join" and m["name"] == "Ann", "a join with a bad face (%s) still joins" % str(b).left(24))
		t.check(m is Dictionary and not (m as Dictionary).has("face"), "and counts as no face (%s)" % str(b).left(24))
	t.check(Protocol.decode(JSON.stringify([1, "J", "Ann", 1.0, face, "extra"])) == null, "a join of six elements is not a join")
	t.check(Protocol.decode(JSON.stringify([1, "J", "Ann"])) == null, "a join of three elements is not a join")

func test_the_face_message(t: T) -> void:
	var face := starter_face("shock")
	var text := Protocol.encode({"type": "face", "player": "c2", "face": face})
	var m: Variant = Protocol.decode(text)
	t.check(m is Dictionary and m["type"] == "face" and m["player"] == "c2" and m["face"] == face, "the host's face message round-trips")
	t.check(Protocol.decode(JSON.stringify([1, "F", "c2", face + "A"])) == null, "a face message with a bad face is dropped")
	t.check(Protocol.decode(JSON.stringify([1, "F", "c2"])) == null, "a face message without a face is dropped")
	t.note("face message with the worst-case face: %d bytes" % Protocol.message_bytes(Protocol.encode({"type": "face", "player": "p12", "face": noise_face("faces-noise")})))

# A host and players over the in-memory network, stepped together. Returns the network.
func _session(faces: Dictionary, roster: Array[String], relay: bool, late: Dictionary = {}) -> Dictionary:
	var net := Transport.MemoryNetwork.new("faces")
	net.log_sends = true
	var host := Host.new(net.connect_peer("host"), "alpha", roster, 0.0)
	host.relay_faces = relay
	var clients := {}
	for id: String in roster:
		clients[id] = Client.new(net.connect_peer(id), "host", id.to_upper(), 0.0, Session.INTERP_DELAY, Session.INPUT_INTERVAL, str(faces.get(id, "")))
	var t := 0.0
	while t < 3.0:
		t += 0.05
		net.now = t
		if t >= 1.0:
			for id: String in late:
				if not clients.has(id):
					clients[id] = Client.new(net.connect_peer(id), "host", id.to_upper(), t, Session.INTERP_DELAY, Session.INPUT_INTERVAL, str(late[id]))
		host.update(t)
		for c: Client in clients.values():
			c.receive(t)
			var lf := Client.LocalFrame.new()
			lf.body = Move.Body.make(0.0, 0.0, 0, 0.0)
			c.frame(t, lf)
	return {"net": net, "host": host, "clients": clients}

## [to, player] of every face message the host sent.
static func _face_sends(net: Transport.MemoryNetwork) -> Array:
	var out: Array = []
	for s: Array in net.sends:
		if s[1] == "host" and str(s[3]).begins_with("[1,\"F\""):
			var m: Variant = Protocol.decode(s[3])
			out.append([s[2], m["player"] if m != null else "?"])
	return out

func test_the_host_passes_each_face_on_once(t: T) -> void:
	var fa := starter_face("smile")
	var fb := noise_face("faces-b")
	var fc := starter_face("frown")
	var roster: Array[String] = ["a", "b", "x"]
	var s := _session({"a": fa, "b": fb}, roster, true, {"c": fc})
	var net: Transport.MemoryNetwork = s["net"]
	var cl: Dictionary = s["clients"]
	var ca: Client = cl["a"]
	var cb: Client = cl["b"]
	var cx: Client = cl["x"]
	var cc: Client = cl["c"]
	t.check(ca.id == "a" and cb.id == "b" and cc.id != null, "everyone was welcomed")
	t.eq(ca.faces.get("b", ""), fb, "a has b's face")
	t.eq(cb.faces.get("a", ""), fa, "b has a's face")
	t.check(not ca.faces.has("a") and not cb.faces.has("b"), "nobody is sent their own face")
	t.check(not ca.faces.has("x") and not cb.faces.has("x"), "a player who drew no face sends none (the mask shows the default)")
	t.eq(cx.faces.get("a", ""), fa, "a player with no face still gets the others'")
	t.eq(cc.faces.get("a", "") + "|" + cc.faces.get("b", ""), fa + "|" + fb, "a late joiner gets everyone's face after its welcome")
	t.eq(ca.faces.get("c", ""), fc, "and the others get the late joiner's")
	# Once: each (recipient, face owner) pair at most once, unless a repeated join crossed its welcome.
	var counts := {}
	for fs: Array in _face_sends(net):
		var k := "%s<%s" % [fs[0], fs[1]]
		counts[k] = int(counts.get(k, 0)) + 1
	var twice: Array = []
	for k: String in counts:
		if int(counts[k]) > 1:
			twice.append("%s x%d" % [k, counts[k]])
	t.check(twice.is_empty(), "each face went to each player once (sent twice: %s)" % ", ".join(twice))
	t.note("face messages sent: %d (%s)" % [_face_sends(net).size(), JSON.stringify(counts)])
	# Never in the snapshot (the 20 Hz messages carry no face).
	var in_snap := 0
	var snaps := 0
	for sd: Array in net.sends:
		var text := str(sd[3])
		if text.begins_with("[1,\"S\""):
			snaps += 1
			if text.contains(fa) or text.contains(fb) or text.contains(fc):
				in_snap += 1
	t.check(snaps > 20 and in_snap == 0, "no snapshot carries a face (%d snapshots, %d with one)" % [snaps, in_snap])

func test_the_check_bites_when_the_host_keeps_faces_to_itself(t: T) -> void:
	var roster: Array[String] = ["a", "b"]
	var s := _session({"a": starter_face("smile"), "b": starter_face("shock")}, roster, false)
	var cl: Dictionary = s["clients"]
	t.check((cl["a"] as Client).faces.is_empty() and (cl["b"] as Client).faces.is_empty(), "with relaying off nobody receives a face (so the checks above are not vacuous)")
	t.check((cl["a"] as Client).id == "a", "and everyone still joins")

func test_a_join_with_a_bad_face_still_joins_the_run(t: T) -> void:
	var net := Transport.MemoryNetwork.new("faces-bad")
	net.log_sends = true
	var roster: Array[String] = ["a", "b"]
	var host := Host.new(net.connect_peer("host"), "alpha", roster, 0.0)
	var ta := net.connect_peer("a")
	var tb := net.connect_peer("b")
	# A hand-made join with an oversized face, and a good one.
	ta.send("host", JSON.stringify([1, "J", "Ann", 0.0, noise_face("x") + "AAAA"]))
	tb.send("host", JSON.stringify([1, "J", "Bob", 0.0, starter_face("smile")]))
	net.now = 0.1
	host.update(0.1)
	var welcomed := {}
	for fs: Array in net.sends:
		if fs[1] == "host" and str(fs[3]).begins_with("[1,\"W\""):
			welcomed[fs[2]] = true
	t.check(welcomed.has("a") and welcomed.has("b"), "both are welcomed, the one with the oversized face too")
	var to_b := 0
	var to_a := 0
	for fs: Array in _face_sends(net):
		if fs[0] == "b":
			to_b += 1
		elif fs[0] == "a":
			to_a += 1
	t.check(to_b == 0 and to_a == 1, "the oversized face is no face: b gets nothing, a gets b's (got %d to b, %d to a)" % [to_b, to_a])
