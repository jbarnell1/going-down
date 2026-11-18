# Game night's logs (client/telemetry.gd, server/night_log.gd, net/build_info.gd): the telemetry message
# round-trips and refuses what does not fit; the rate limits hold on both sides; an F9 report fits the
# server's message limit; the local log rolls at its cap and keeps the last session (clean or crashed);
# the passphrase never reaches a server log line (a real WebSocket session on 127.0.0.1); a client of
# another build is refused with the out-of-date reason, and the same build joins.
extends RefCounted

const T = preload("res://tests/t.gd")
const Protocol = preload("res://net/protocol.gd")
const WsServer = preload("res://net/ws_server.gd")
const Room = preload("res://server/room.gd")
const NightLog = preload("res://server/night_log.gd")
const RoomClient = preload("res://net/room_client.gd")
const BuildInfo = preload("res://net/build_info.gd")
const Telemetry = preload("res://client/telemetry.gd")

const SECRET := "Known-Pass-7731-telemetry"
const TEST_DIR := "user://telemetry_tests"

# --- the message ------------------------------------------------------------------------------------

func test_the_telemetry_message_round_trips(t: T) -> void:
	var msgs: Array[Dictionary] = [
		{"type": "telemetry", "kind": "hb", "body": JSON.stringify({"fps": 60, "gpu": "x"})},
		{"type": "telemetry", "kind": "log", "body": "err Something \"quoted\" \\ failed (res://a.gd:3 f)"},
		{"type": "telemetry", "kind": "log", "body": "x".repeat(Protocol.MAX_TELEMETRY_LINE)},
		{"type": "telemetry", "kind": "rep", "body": "line one\nline two", "id": 3, "part": 1, "parts": 2},
		{"type": "telemetry", "kind": "crash", "body": "y".repeat(Protocol.MAX_TELEMETRY_PART), "id": 1, "part": 0, "parts": Protocol.MAX_TELEMETRY_PARTS},
	]
	for m in msgs:
		var text := Protocol.encode(m)
		var back: Variant = Protocol.decode(text)
		t.check(back is Dictionary and JSON.stringify(back) == JSON.stringify(m), "round trip of %s: got %s" % [m["kind"], str(back).left(120)])
		t.check(Protocol.message_bytes("t|" + text) <= WsServer.MAX_MESSAGE, "%s fits the server's message limit" % m["kind"])
	var bad: Array[String] = [
		JSON.stringify([1, "T", "hb"]),
		JSON.stringify([1, "T", "exec", "x"]),
		JSON.stringify([1, "T", "log", "x".repeat(Protocol.MAX_TELEMETRY_LINE + 1)]),
		JSON.stringify([1, "T", "log", 5]),
		JSON.stringify([1, "T", "log", "x", 1, 0, 1]),
		JSON.stringify([1, "T", "rep", "x"]),
		JSON.stringify([1, "T", "rep", "x", 1, 2, 2]),
		JSON.stringify([1, "T", "rep", "x", 1, 0, Protocol.MAX_TELEMETRY_PARTS + 1]),
		JSON.stringify([1, "T", "rep", "x", 0, 0, 1]),
		JSON.stringify([1, "T", "rep", "y".repeat(Protocol.MAX_TELEMETRY_PART + 1), 1, 0, 1]),
		JSON.stringify([2, "T", "log", "x"]),
	]
	for b in bad:
		t.check(Protocol.decode(b) == null, "refused: %s" % b.left(60))
	t.check(not Room.ACCEPTED.has("telemetry"), "a telemetry message is never one of a run's messages")

# --- the rate limits ----------------------------------------------------------------------------------

func test_the_server_rate_limit_holds(t: T) -> void:
	var out: Array[String] = []
	var night := NightLog.new(func(l: String) -> void: out.append(l))
	var line := Protocol.encode({"type": "telemetry", "kind": "log", "body": "err boom"})
	var hb := Protocol.encode({"type": "telemetry", "kind": "hb", "body": "{\"fps\":60}"})
	for i in 30:
		night.client_line("c1", line, 1.0 + i * 0.01)
		night.client_line("c1", hb, 1.0 + i * 0.01)
	for i in 5:
		night.client_line("c2", line, 2.0)
	var rep := Protocol.encode({"type": "telemetry", "kind": "rep", "body": "r", "id": 1, "part": 0, "parts": 1})
	var crash := Protocol.encode({"type": "telemetry", "kind": "crash", "body": "c", "id": 2, "part": 0, "parts": 1})
	for i in 20:
		night.client_line("c3", rep if i % 2 == 0 else crash, 3.0)
	t.eq(_count(out, "clog", "c1"), NightLog.LIMITS["log"], "player c1's log lines in one minute")
	t.eq(_count(out, "hb", "c1"), NightLog.LIMITS["hb"], "player c1's heartbeats in one minute")
	t.eq(_count(out, "clog", "c2"), 5, "another player's lines are not held back by c1's")
	t.eq(_count(out, "report", "c3"), NightLog.LIMITS["rep"], "report parts (F9 and crash together) in one minute")
	night.client_line("c1", line, 61.5)
	t.eq(_count(out, "clog", "c1"), NightLog.LIMITS["log"] + 1, "a new minute, a new allowance")
	night.client_line("c1", "[1,\"T\",\"exec\",\"run me\"]", 62.0)
	t.eq(_count(out, "clog", "c1"), NightLog.LIMITS["log"] + 1, "a message that does not decode is not logged")
	var cut := NightLog.clean_heartbeat(JSON.stringify({"fps": 60, "gpu": "g".repeat(300), "secret": "x", "os": {"a": 1}, "avg_ms": "1"}))
	t.check(cut.get("fps") == 60.0 and String(cut.get("gpu", "")).length() == 80 and not cut.has("secret") and not cut.has("os") and not cut.has("avg_ms"),
		"a heartbeat keeps only its known keys, numbers, and strings within their length: %s" % str(cut).left(100))

func test_the_client_rate_limit_holds(t: T) -> void:
	var tel := Telemetry.new()
	for i in 30:
		tel.error_line("err", "error number %d" % i)
	for i in 10:
		tel.error_line("err", "the same error")
	var sent := 0
	for m in tel.outbox:
		if m["kind"] == "log":
			sent += 1
	t.eq(sent, Telemetry.SEND_PER_WINDOW, "error lines queued for the server in one minute")
	t.eq(tel.unsent, 30 - Telemetry.SEND_PER_WINDOW + 1, "the rest are counted for the heartbeat")
	t.eq(tel.errors, 40, "every error is counted")
	var same := 0
	for r: Array in tel._recent:
		if String(r[1]).contains("the same error"):
			same += 1
	t.eq(same, 1, "a repeated error is written once a minute (and counted)")
	tel.free()

func test_a_report_fits_the_message_limit(t: T) -> void:
	var lines := PackedStringArray(["player pressed F9 at 2026-11-20T21:00:00Z: mode game, place annex, depth 3, phase away"])
	for i in 400:
		lines.append("2026-11-20T21:00:%02dZ err line %d %s" % [i % 60, i, "z\"\\".repeat(150)])
	var parts := Telemetry.report_parts("rep", 7, lines)
	t.check(parts.size() >= 2 and parts.size() <= Protocol.MAX_TELEMETRY_PARTS, "a long report is cut into 2 to %d parts (got %d)" % [Protocol.MAX_TELEMETRY_PARTS, parts.size()])
	for m in parts:
		var text := "t|" + Protocol.encode(m)
		t.check(Protocol.message_bytes(text) <= WsServer.MAX_MESSAGE, "part %d fits the server's message limit (%d bytes)" % [m["part"], Protocol.message_bytes(text)])
		t.check(Protocol.decode(text.substr(2)) != null, "part %d decodes" % m["part"])
	t.check(String(parts[0]["body"]).begins_with("player pressed F9"), "the first part starts with the note")
	t.check(String(parts[-1]["body"]).ends_with(lines[-1]), "the last part ends with the newest line")
	var short := Telemetry.report_parts("rep", 8, PackedStringArray(["head", "one", "two"]))
	t.check(short.size() == 1 and short[0]["body"] == "head\none\ntwo", "a short report is one part, in order: %s" % str(short))

# --- the local log --------------------------------------------------------------------------------------

func test_the_log_rolls_at_its_cap(t: T) -> void:
	var dir := TEST_DIR + "/roll"
	_clear(dir)
	var cap := 20000
	var rl := Telemetry.RollingLog.new(dir, "session", cap)
	t.check(rl.open(), "the log opens")
	for i in 2000:
		rl.write("line %05d %s" % [i, "x".repeat(90)])
	rl.flush()
	var a := FileAccess.get_file_as_bytes(dir + "/session.log").size()
	var b := FileAccess.get_file_as_bytes(dir + "/session.1.log").size()
	rl.close()
	t.check(rl.rolls > 5, "it rolled (%d times)" % rl.rolls)
	t.check(a <= cap and b <= cap and b > cap / 2, "each file stays within the cap (%d and %d bytes, cap %d)" % [a, b, cap])
	t.check(FileAccess.get_file_as_string(dir + "/session.log").contains("line 01999"), "the newest line is in the current file")
	t.eq(DirAccess.get_files_at(dir).size(), 2, "two files, never more")
	_clear(dir)

func test_the_last_session_is_kept_clean_or_crashed(t: T) -> void:
	var dir := TEST_DIR + "/keep"
	_clear(dir)
	var one := Telemetry.new()
	one.dir = dir
	one.begin()
	one.record("net", "first session line")
	one.end()
	t.check(not FileAccess.file_exists(dir + "/running"), "a clean end removes the marker")
	var two := Telemetry.new()
	two.dir = dir
	two.begin()
	t.check(not two.crashed_before, "after a clean end, no crash")
	t.check(FileAccess.get_file_as_string(dir + "/previous.log").contains("first session line"), "the clean session is kept as previous.log")
	two.record("net", "second session line, then the game dies")
	two.file_log.close()
	OS.remove_logger(two.tap)  # dies: no end(), the marker stays (with a process id that is not running)
	var m := FileAccess.open(dir + "/running", FileAccess.WRITE)
	m.store_line("999999")
	m.close()
	var three := Telemetry.new()
	three.dir = dir
	three.begin()
	t.check(three.crashed_before, "the marker left behind is a crash")
	t.check(FileAccess.get_file_as_string(dir + "/crash.log").contains("then the game dies"), "the crashed session is kept as crash.log")
	var crash_parts := three.outbox.filter(func(x: Dictionary) -> bool: return x["kind"] == "crash")
	t.check(crash_parts.size() >= 1 and String(crash_parts[0]["body"]).contains("then the game dies"), "its tail waits to go to the server")
	three.end()
	for x: Node in [one, two, three]:
		(x as Node).free()
	_clear(dir)

# --- the server, over real WebSockets -------------------------------------------------------------------

func test_the_passphrase_never_reaches_a_server_log_line(t: T) -> void:
	var out := _session(t, 4491, true)
	t.check(out.size() > 10, "not vacuous: the server wrote %d lines" % out.size())
	var kinds := {}
	for l in out:
		var d: Variant = JSON.parse_string(l) if l.begins_with("{") else null
		var k := str((d as Dictionary).get("ev")) if d is Dictionary else "plain"
		kinds[k] = int(kinds.get(k, 0)) + 1
	t.note("server lines by kind: %s" % JSON.stringify(kinds))
	for ev: String in ["\"ev\":\"start\"", "\"ev\":\"join\"", "\"ev\":\"hb\"", "\"ev\":\"clog\"", "\"ev\":\"report\"", "\"ev\":\"run\"", "\"ev\":\"leave\""]:
		t.check(_has(out, ev), "the night's log has %s" % ev)
	var leaks := out.filter(func(l: String) -> bool: return l.contains(SECRET))
	t.check(leaks.is_empty(), "no server line holds the passphrase (%d do, first: %s)" % [leaks.size(), str(leaks[0]).left(160) if not leaks.is_empty() else ""])
	var addrs := out.filter(func(l: String) -> bool: return l.contains("127.0.0.1"))
	t.check(addrs.is_empty(), "no server line holds an address (%d do, first: %s)" % [addrs.size(), str(addrs[0]).left(160) if not addrs.is_empty() else ""])
	t.check(_has(out, "***"), "the line that held it reached the server scrubbed")

func test_another_build_is_refused_and_the_same_build_joins(t: T) -> void:
	var saved := BuildInfo._id
	var said: Array[String] = []
	var ws := WsServer.new(SECRET, false, func(l: String) -> void: said.append(l))
	ws.build = "build-a"
	t.check(ws.listen(4492, "127.0.0.1") == OK, "the test server listens on 4492")
	var room := Room.new(ws, func(l: String) -> void: said.append(l))
	var night := NightLog.new(func(l: String) -> void: said.append(l))
	BuildInfo._id = "build-b"
	var old := RoomClient.new()
	old.connect_to("ws://127.0.0.1:4492", SECRET, "Old")
	BuildInfo._id = "build-a"
	var same := RoomClient.new()
	same.connect_to("ws://127.0.0.1:4492", SECRET, "Same")
	var raw := WebSocketPeer.new()
	raw.connect_to_url("ws://127.0.0.1:4492")
	var raw_said := false
	var now := 0.0
	for i in 300:
		now += 0.02
		ws.poll(now)
		night.pump(ws, room, now)
		BuildInfo._id = "build-b"
		old.poll(now)
		BuildInfo._id = "build-a"
		same.poll(now)
		raw.poll()
		if raw.get_ready_state() == WebSocketPeer.STATE_OPEN and not raw_said:
			raw_said = true
			raw.send_text(JSON.stringify(["hello", 1, SECRET, "NoBuild"]))
		if old.status == "closed" and same.status == "lobby" and raw.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			break
		OS.delay_msec(5)
	BuildInfo._id = saved
	t.eq(old.close_code, WsServer.CLOSE_VERSION, "a client of another build is closed with 4007")
	t.eq(old.close_reason, BuildInfo.OUT_OF_DATE, "with the reason the join screen shows")
	t.eq(raw.get_close_code(), WsServer.CLOSE_VERSION, "a hello without a build is refused the same way")
	t.eq(same.status, "lobby", "the same build joins as today")
	t.eq(ws.refused["version"], 2, "two refused for their build")
	t.eq(ws.refused["auth"], 0, "and neither counted as a wrong passphrase")
	same.leave()
	ws.stop()
	t.check(BuildInfo.accepts(BuildInfo.DEV, "anything") and BuildInfo.accepts(BuildInfo.DEV, ""), "a server run from source (dev) takes every build")
	t.check(not BuildInfo.accepts("abc", "") and not BuildInfo.accepts("abc", "abd") and BuildInfo.accepts("abc", "abc"), "an exported server takes only its own")
	t.check(BuildInfo.valid("1a2b3c4d5e-dirty") and not BuildInfo.valid("") and not BuildInfo.valid("a b") and not BuildInfo.valid("x".repeat(65)), "what a build id may be")

# --- helpers -----------------------------------------------------------------------------------------

## A real session on 127.0.0.1:`port`: one player joins with SECRET, says something through its
## telemetry (a line that holds the passphrase too: the client must scrub it), sends an F9 report, starts
## a run and leaves. Returns every line the server wrote (its plain lines and the night's log).
func _session(t: T, port: int, run: bool) -> Array[String]:
	var out: Array[String] = []
	var say := func(l: String) -> void: out.append(l)
	var ws := WsServer.new(SECRET, false, say)
	t.check(ws.listen(port, "127.0.0.1") == OK, "the test server listens on %d" % port)
	var room := Room.new(ws, say)
	room.fixed_seed = "telemetry-1"
	var night := NightLog.new(say)
	night.started(ws.build, port)
	var rc := RoomClient.new()
	rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, "Ann")
	var fake := _fake_main(SECRET)
	var tel := Telemetry.new(fake)
	var now := 0.0
	var stage := 0
	for i in 400:
		now += 0.02
		ws.poll(now)
		night.pump(ws, room, now)
		rc.poll(now)
		if stage == 0 and rc.status == "lobby":
			stage = 1
			tel.error_line("err", "could not join with the passphrase %s (res://x.gd:1 f)" % SECRET)
			tel.error_line("warn", "a warning")
			rc.send_telemetry({"type": "telemetry", "kind": "hb", "body": JSON.stringify(tel.heartbeat())})
			for m in Telemetry.report_parts("rep", 1, PackedStringArray(["player pressed F9 at test", "a line"])):
				rc.send_telemetry(m)
			for m in tel.outbox:
				rc.send_telemetry(m)
			if run:
				# Ready-up (server/room.gd): a lone ready player's run starts after the 5 s count.
				rc.set_ready(true)
		elif stage == 1 and (room.running() or not run) and i > 150:
			stage = 2
			rc.leave()
		elif stage == 2 and room.people.is_empty():
			break
		OS.delay_msec(3)
	for k in 5:
		now += 0.02
		ws.poll(now)
		night.pump(ws, room, now)
		OS.delay_msec(3)
	ws.stop()
	tel.free()
	fake.free()
	return out

## A stand-in for client/main.gd with the fields telemetry reads.
static func _fake_main(secret: String) -> Node:
	var st := GDScript.new()
	st.source_code = "extends RefCounted\nvar passphrase := \"\"\n"
	st.reload()
	var start: RefCounted = st.new()
	start.set("passphrase", secret)
	var mg := GDScript.new()
	mg.source_code = "extends Node\nvar automated := true\nvar pass_arg := \"\"\nvar mode := \"lobby\"\nvar snap := {}\nvar link: Object = null\nvar start: Object = null\n"
	mg.reload()
	var m: Node = mg.new()
	m.set("start", start)
	return m

static func _count(out: Array[String], ev: String, id: String) -> int:
	var n := 0
	for l in out:
		var d: Variant = JSON.parse_string(l)
		if d is Dictionary and d.get("ev") == ev and d.get("id") == id:
			n += 1
	return n

static func _has(out: Array[String], s: String) -> bool:
	for l in out:
		if l.contains(s):
			return true
	return false

static func _clear(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_clear(dir + "/" + d)
		DirAccess.remove_absolute(dir + "/" + d)
