# Drawn faces over the network (face/README.md "Wiring", North Star H1 and V7): the join's optional
# fifth element, what counts as no face, the host passing each face on once (and to a late joiner),
# never in the snapshot; and changing your face during the run (the face kiosk, "C"): passed on once,
# a bad face ignored without a kick, at most one change every FACE_GAP seconds. Run alone with
# tests/run_face_net.gd.
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
const Room = preload("res://server/room.gd")

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

# --- Changing your face during the run (the prison's face kiosk): [1, "C", face] -----------------

## Two faces are the same text; a failure names them by a short hash, never by the face itself.
static func _same(t: T, got: Variant, want: String, message: String) -> void:
	var g := str(got)
	t.check(g == want, "%s: got %s, want %s" % [message, g.md5_text().left(8) if g != "" else "no face", want.md5_text().left(8)])

func test_the_face_change_message(t: T) -> void:
	var face := starter_face("frown")
	var text := Protocol.encode({"type": "setFace", "face": face})
	t.eq(text, JSON.stringify([1, "C", face]), "the face change on the wire")
	var m: Variant = Protocol.decode(text)
	t.check(m is Dictionary and m["type"] == "setFace" and m["face"] == face, "it round-trips")
	var worst := Protocol.encode({"type": "setFace", "face": noise_face("faces-noise")})
	t.check(Protocol.message_bytes(worst) < 700, "the worst-case face change is %d bytes" % Protocol.message_bytes(worst))
	# A bad face still decodes (so the room server passes it and the host ignores it, kicking nobody), as
	# no face; a message of the wrong shape does not.
	for b: Variant in [face + "A", "x".repeat(5000), "F1Rabc", "", 12345, null, [face]]:
		var bm: Variant = Protocol.decode(JSON.stringify([1, "C", b]))
		t.check(bm is Dictionary and bm["type"] == "setFace" and bm["face"] == "", "a face change with a bad face (%s) decodes as no face" % str(b).left(20))
	t.check(Protocol.decode(JSON.stringify([1, "C"])) == null, "a face change without a face is not a message")
	t.check(Protocol.decode(JSON.stringify([1, "C", face, "x"])) == null, "a face change of four elements is not a message")
	t.check(Room.ACCEPTED.has("setFace"), "the room server takes face changes from clients")
	t.check(not Room.ACCEPTED.has("face"), "and still refuses the host's face message from a client")

## A host and its players over the in-memory network: {net, host, clients, t}. Step it with _step_to.
func _start(faces: Dictionary, roster: Array[String], tag: String) -> Dictionary:
	var net := Transport.MemoryNetwork.new(tag)
	net.log_sends = true
	var host := Host.new(net.connect_peer("host"), "alpha", roster, 0.0)
	var clients := {}
	for id: String in roster:
		clients[id] = Client.new(net.connect_peer(id), "host", id.to_upper(), 0.0, Session.INTERP_DELAY, Session.INPUT_INTERVAL, str(faces.get(id, "")))
	return {"net": net, "host": host, "clients": clients, "t": 0.0}

func _step_to(s: Dictionary, t_end: float) -> void:
	var net: Transport.MemoryNetwork = s["net"]
	var host: Host = s["host"]
	var t: float = s["t"]
	while t < t_end - 1e-9:
		t += 0.05
		net.now = t
		host.update(t)
		for c: Client in (s["clients"] as Dictionary).values():
			c.receive(t)
			var lf := Client.LocalFrame.new()
			lf.body = Move.Body.make(0.0, 0.0, 0, 0.0)
			c.frame(t, lf)
	s["t"] = t

## [to, player, face] of every face message the host sent after send number `from`.
static func _face_sends_since(net: Transport.MemoryNetwork, from: int) -> Array:
	var out: Array = []
	for i in range(from, net.sends.size()):
		var sd: Array = net.sends[i]
		if sd[1] == "host" and str(sd[3]).begins_with("[1,\"F\""):
			var m: Variant = Protocol.decode(sd[3])
			out.append([sd[2], m["player"], m["face"]] if m != null else [sd[2], "?", ""])
	return out

func test_a_face_change_reaches_every_other_player_once(t: T) -> void:
	var fa := starter_face("smile")
	var fb := starter_face("shock")
	var fb2 := noise_face("faces-b2")
	var roster: Array[String] = ["a", "b", "x"]
	var s := _start({"a": fa, "b": fb}, roster, "faces-change")
	_step_to(s, 2.0)
	var net: Transport.MemoryNetwork = s["net"]
	var host: Host = s["host"]
	var cl: Dictionary = s["clients"]
	var ca: Client = cl["a"]
	var cb: Client = cl["b"]
	var cx: Client = cl["x"]
	_same(t, ca.faces.get("b", ""), fb, "before: a has b's first face")
	var mark := net.sends.size()
	t.check(cb.change_face(fb2, 2.0), "b changes face (the kiosk's Done)")
	_same(t, cb.face, fb2, "b's own screen has the new face at once")
	_step_to(s, 3.0)
	_same(t, ca.faces.get("b", ""), fb2, "a has b's new face")
	_same(t, cx.faces.get("b", ""), fb2, "x (who drew no face) has it too")
	t.check(not cb.faces.has("b"), "b is not sent its own face")
	var sends := _face_sends_since(net, mark)
	var to := {}
	for fs: Array in sends:
		t.check(fs[1] == "b" and fs[2] == fb2, "only b's new face was sent (got %s's)" % str(fs[1]))
		to[fs[0]] = int(to.get(fs[0], 0)) + 1
	t.check(sends.size() == 2 and to.get("a", 0) == 1 and to.get("x", 0) == 1, "relayed once to each other player (sent %s)" % JSON.stringify(to))
	t.eq(host.face_changes, 1, "the host took one change")
	# Never in the snapshot.
	var in_snap := 0
	for i in range(mark, net.sends.size()):
		var text := str(net.sends[i][3])
		if text.begins_with("[1,\"S\"") and text.contains(fb2):
			in_snap += 1
	t.eq(in_snap, 0, "snapshots carrying the new face")
	# A late joiner gets the new face, not the old one.
	cl["c"] = Client.new(net.connect_peer("c"), "host", "C", s["t"], Session.INTERP_DELAY, Session.INPUT_INTERVAL, "")
	_step_to(s, 4.0)
	_same(t, (cl["c"] as Client).faces.get("b", ""), fb2, "a late joiner gets b's new face")
	t.note("face change: %d face messages after it, the host took %d change(s)" % [sends.size(), host.face_changes])

func test_the_check_bites_when_the_host_keeps_changes_to_itself(t: T) -> void:
	var roster: Array[String] = ["a", "b"]
	var s := _start({"a": starter_face("smile"), "b": starter_face("shock")}, roster, "faces-change-off")
	_step_to(s, 2.0)
	var host: Host = s["host"]
	var cb: Client = (s["clients"] as Dictionary)["b"]
	host.relay_faces = false
	cb.change_face(starter_face("frown"), 2.0)
	_step_to(s, 3.0)
	_same(t, ((s["clients"] as Dictionary)["a"] as Client).faces.get("b", ""), starter_face("shock"), "with relaying off a keeps b's old face (so the check above is not vacuous)")
	t.eq(host.face_changes, 1, "though the host kept the change")

func test_a_bad_face_change_is_ignored_and_nobody_is_kicked(t: T) -> void:
	var net := Transport.MemoryNetwork.new("faces-change-bad")
	net.log_sends = true
	var roster: Array[String] = ["a", "b"]
	var host := Host.new(net.connect_peer("host"), "alpha", roster, 0.0)
	var ta := net.connect_peer("a")
	var tb := net.connect_peer("b")
	ta.send("host", JSON.stringify([1, "J", "Ann", 0.0, starter_face("smile")]))
	tb.send("host", JSON.stringify([1, "J", "Bob", 0.0, starter_face("frown")]))
	net.now = 0.1
	host.update(0.1)
	var mark := net.sends.size()
	for b: Variant in [starter_face("shock") + "A", "F1Rabc", "", 7, null]:
		ta.send("host", JSON.stringify([1, "C", b]))
	net.now = 0.3
	host.update(0.3)
	t.eq(_face_sends_since(net, mark).size(), 0, "face messages sent for bad faces")
	t.eq(host.face_changes, 0, "changes taken")
	t.eq(host.face_changes_ignored, 5, "changes ignored")
	var ra := {}
	for r: Dictionary in host.roster():
		ra[r["id"]] = r
	t.check(ra.has("a") and ra["a"]["connected"] and not ra["a"]["left"], "a is still in the room")
	# Still served: snapshots keep coming, and a good face afterwards is taken.
	var snaps_to_a := 0
	for i in range(mark, net.sends.size()):
		if net.sends[i][2] == "a" and str(net.sends[i][3]).begins_with("[1,\"S\""):
			snaps_to_a += 1
	t.check(snaps_to_a > 0, "a still gets snapshots")
	ta.send("host", JSON.stringify([1, "C", starter_face("shock")]))
	net.now = 0.4
	host.update(0.4)
	var after := _face_sends_since(net, mark)
	t.check(after.size() == 1 and after[0][0] == "b" and after[0][2] == starter_face("shock"), "then a good face is taken and passed to b (sent %s)" % str(after.size()))

func test_face_changes_are_rate_limited(t: T) -> void:
	var net := Transport.MemoryNetwork.new("faces-change-flood")
	net.log_sends = true
	var roster: Array[String] = ["a", "b"]
	var host := Host.new(net.connect_peer("host"), "alpha", roster, 0.0)
	var ta := net.connect_peer("a")
	var tb := net.connect_peer("b")
	ta.send("host", JSON.stringify([1, "J", "Ann", 0.0]))
	tb.send("host", JSON.stringify([1, "J", "Bob", 0.0]))
	net.now = 0.05
	host.update(0.05)
	var mark := net.sends.size()
	# A flood: a different face every 50 ms for 4.9 s.
	var faces: Array[String] = []
	var tt := 0.1
	var k := 0
	while tt < 5.0:
		var f := noise_face("flood-%d" % k)
		faces.append(f)
		ta.send("host", JSON.stringify([1, "C", f]))
		net.now = tt
		host.update(tt)
		tt += 0.05
		k += 1
	var during := _face_sends_since(net, mark)
	t.check(during.size() == 1 and during[0][2] == faces[0], "%d changes in 4.9 s: only the first passed on (passed %d)" % [faces.size(), during.size()])
	t.eq(host.face_changes_ignored, faces.size() - 1, "the rest dropped")
	# After the gap the next one is taken.
	var late := starter_face("smile")
	ta.send("host", JSON.stringify([1, "C", late]))
	net.now = 0.1 + Host.FACE_GAP + 0.01
	host.update(net.now)
	var all := _face_sends_since(net, mark)
	t.check(all.size() == 2 and all[1][2] == late, "after %.0f s the next change is taken (passed %d in all)" % [Host.FACE_GAP, all.size()])
	t.note("flood of %d face changes in 4.9 s: %d passed on; gap %.1f s" % [faces.size(), during.size(), Host.FACE_GAP])

func test_the_client_holds_a_quick_second_change_until_the_gap(t: T) -> void:
	var roster: Array[String] = ["a", "b"]
	var s := _start({"a": starter_face("smile"), "b": starter_face("shock")}, roster, "faces-change-wait")
	_step_to(s, 2.0)
	var net: Transport.MemoryNetwork = s["net"]
	var host: Host = s["host"]
	var ca: Client = (s["clients"] as Dictionary)["a"]
	var cb: Client = (s["clients"] as Dictionary)["b"]
	var mark := net.sends.size()
	var f1 := starter_face("frown")
	var f2 := noise_face("faces-wait-2")
	var f3 := starter_face("smile")
	cb.change_face(f1, 2.0)
	_step_to(s, 3.0)
	cb.change_face(f2, 3.0)
	cb.change_face(f3, 3.0)
	t.check(cb.face_change_waiting(), "a change one second after the last waits for the host's gap")
	_same(t, cb.face, f3, "while b's own screen shows the newest face")
	_step_to(s, 9.0)
	t.check(not cb.face_change_waiting(), "and goes out when the gap has passed")
	_same(t, ca.faces.get("b", ""), f3, "so the others end on b's newest face")
	var sent_c := 0
	for i in range(mark, net.sends.size()):
		if net.sends[i][1] == "b" and str(net.sends[i][3]).begins_with("[1,\"C\""):
			sent_c += 1
	t.eq(sent_c, 2, "face changes b sent (the middle one never went out)")
	t.eq(host.face_changes_ignored, 0, "changes the host had to drop")
	t.check(not cb.change_face("not a face", 9.0), "the client refuses to send a bad face")
