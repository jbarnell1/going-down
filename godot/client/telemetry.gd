# What the game records about itself, so a crash or a problem on game night can be fixed the same night.
# A node client/main.gd adds once (two hook lines there); it reads main's state and changes nothing in the
# game. What a player sees from it: only the one line after F9 ("Report sent, thank you").
#
# Locally, in user://telemetry/ (on Windows %APPDATA%\Godot\app_userdata\Going Down\telemetry):
#   session.log, session.1.log   this session, one line each: "<UTC time>Z <kind> <text>". Kinds: start
#                                (build, OS, GPU, renderer), perf (average and worst frame time, once a
#                                minute), where (place, depth, phase, on each change), net (joining, lobby,
#                                run), disc (a connection closed: code and reason), err / warn / script /
#                                shader / stderr (every engine and script error the game reports), rep
#                                (a repeated error, counted), f9, crash, end. Rolls at ROLL_BYTES to
#                                session.1.log, so a session holds at most two files (5 MB).
#   previous.log (.1)            the last session that ended cleanly;
#   crash.log (.1)               the last session that did not (the "running" marker was left behind);
#   reports/f9-<time>.txt/.jpg   each F9 report and a picture of the screen (the newest REPORTS_KEPT).
# To the server (net/room_client.gd send_telemetry; server/night_log.gd writes it to the night's log), and
# never anywhere else (no HTTP, no third party): a heartbeat every HEARTBEAT_EVERY s, every error line (at
# most SEND_PER_WINDOW a minute; the rest are counted in the heartbeat), disconnects (sent with the next
# connection), an F9 report (the last REPORT_SECONDS of this log, in parts of at most
# Protocol.MAX_TELEMETRY_PART bytes; the picture stays on this PC: it would not fit the server's message
# limit), and the tail of a crashed session at the next start. Playing alone sends nothing.
# The passphrase never goes in a line: every line is scrubbed of the one typed into the join form.
#
# Errors: GDScript has no exceptions. Godot 4.7's OS.add_logger takes a Logger whose _log_error sees every
# engine error, script error, push_error and push_warning (with the script backtrace when there is one),
# and _log_message every print (only the error stream is kept). It is called on any thread, so it only
# buffers; _process writes the lines. Errors before main's _ready (a script that fails to load at start)
# happen before it is added, and a hard crash of the engine itself is not seen: the marker catches it.
extends Node

const Protocol = preload("res://net/protocol.gd")
const BuildInfo = preload("res://net/build_info.gd")
const RoomClient = preload("res://net/room_client.gd")

const DIR := "user://telemetry"
## Each session file's size before it rolls (two files a session).
const ROLL_BYTES := 2500000
const HEARTBEAT_EVERY := 30.0
const PERF_EVERY := 60.0
## Error lines sent to the server per minute (the server takes the same: server/night_log.gd LIMITS).
const SEND_PER_WINDOW := 20
## Error lines written here per minute (repeats of one already written are counted, not written).
const LOCAL_PER_WINDOW := 200
const WINDOW := 60.0
## An F9 report holds this much of the log; one is sent at most every REPORT_GAP seconds (more are saved).
const REPORT_SECONDS := 60.0
const REPORT_GAP := 20.0
const REPORTS_KEPT := 10
## The crash tail sent at the next start: the last lines of the crashed session.
const CRASH_TAIL_LINES := 60
## Messages waiting for a connection (disconnects, a crash tail), at most.
const OUTBOX_MAX := 40
const NOTE_MS := 3000
const SENT := "Report sent, thank you"
const SAVED := "Report saved, thank you"

## Collects what the engine reports, from any thread.
class Tap extends Logger:
	var mutex := Mutex.new()
	var buf: Array = []  # [kind, text]
	var lost := 0

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := "%s (%s:%d %s)" % [rationale if not rationale.is_empty() else code, file, line, function]
		for bt in script_backtraces:
			for i in mini(bt.get_frame_count(), 3):
				text += " <- %s:%d %s" % [bt.get_frame_file(i), bt.get_frame_line(i), bt.get_frame_function(i)]
		_add(["err", "warn", "script", "shader"][clampi(error_type, 0, 3)], text)

	func _log_message(message: String, error: bool) -> void:
		if error:
			_add("stderr", message.strip_edges())

	func _add(kind: String, text: String) -> void:
		mutex.lock()
		if buf.size() < 1000:
			buf.append([kind, text])
		else:
			lost += 1
		mutex.unlock()

	func take() -> Array:
		mutex.lock()
		var out := buf
		buf = []
		if lost > 0:
			out.append(["err", "%d more errors in one frame, not recorded" % lost])
			lost = 0
		mutex.unlock()
		return out

## A log of at most two files of `cap` bytes: `<base>.log`, rolled to `<base>.1.log`.
class RollingLog:
	var path: String
	var path1: String
	var cap: int
	var size := 0
	var rolls := 0
	var _f: FileAccess = null

	func _init(dir: String, base: String, cap_: int) -> void:
		path = "%s/%s.log" % [dir, base]
		path1 = "%s/%s.1.log" % [dir, base]
		cap = cap_

	func open() -> bool:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_f = FileAccess.open(path, FileAccess.WRITE)
		size = 0
		return _f != null

	func write(line: String) -> void:
		if _f == null:
			return
		var n := line.to_utf8_buffer().size() + 1
		if size + n > cap and size > 0:
			roll()
			if _f == null:
				return
		_f.store_line(line)
		size += n

	func roll() -> void:
		_f.close()
		DirAccess.remove_absolute(path1)
		DirAccess.rename_absolute(path, path1)
		rolls += 1
		open()

	func flush() -> void:
		if _f != null:
			_f.flush()

	func close() -> void:
		if _f != null:
			_f.close()
			_f = null

	## Both files' text, oldest first.
	func text() -> String:
		flush()
		var out := ""
		for p: String in [path1, path]:
			if FileAccess.file_exists(p):
				out += FileAccess.get_file_as_string(p)
		return out

## The game's main node (client/main.gd), read only; null in tests.
var main: Node = null
var dir := DIR
var file_log: RollingLog
var tap := Tap.new()
## Whether the session before this one did not end cleanly (its log is kept as crash.log).
var crashed_before := false
## Errors and warnings recorded this session, and error lines not sent (over the limit).
var errors := 0
var warnings := 0
var unsent := 0
## Messages for the server: [Protocol message]; sent once a server connection is open.
var outbox: Array[Dictionary] = []
var _marker := ""
var _recent: Array = []  # [msec, line]
var _window_at := -INF
var _sent_in_window := 0
var _local_in_window := 0
var _repeats := {}  # text -> count, this window
var _perf := [0.0, 0, 0.0]  # sum, n, max (s) since the last perf line
var _hb := [0.0, 0, 0.0]  # the same since the last heartbeat
var _perf_at := 0.0
var _hb_at := 0.0
var _up := 0.0
var _rc: RoomClient = null
var _rc_status := ""
var _where := ""
var _report_id := 0
var _last_report := -INF
var _note: Control = null
var _note_text := ""
var _note_until := 0
var _ended := false

func _init(main_: Node = null) -> void:
	main = main_
	name = "Telemetry"

func _ready() -> void:
	if main != null and main.get("automated") == true:
		dir = DIR + "/test"
	begin()
	var layer := CanvasLayer.new()
	layer.layer = 120
	add_child(layer)
	_note = Control.new()
	_note.set_anchors_preset(Control.PRESET_FULL_RECT)
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note.draw.connect(_draw_note)
	layer.add_child(_note)

## Opens this session's log (keeping the last one), and starts listening to the engine.
func begin() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var base := "session"
	_marker = dir + "/running"
	if FileAccess.file_exists(_marker) and _other_instance(_marker):
		# Another copy of the game is running on this PC: this one keeps its own files, and leaves theirs.
		base = "session-%d" % OS.get_process_id()
		_marker = "%s/running-%d" % [dir, OS.get_process_id()]
	else:
		crashed_before = FileAccess.file_exists(_marker)
		_keep_previous("crash" if crashed_before else "previous")
		_sweep()
	var m := FileAccess.open(_marker, FileAccess.WRITE)
	if m != null:
		m.store_line("0" if OS.has_feature("web") else str(OS.get_process_id()))
		m.close()
	file_log = RollingLog.new(dir, base, ROLL_BYTES)
	file_log.open()
	record("start", "build %s, %s %s, %s %s, renderer %s, screen %s, %s" % [BuildInfo.id(), OS.get_name(), OS.get_version(),
		RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method(),
		str(DisplayServer.screen_get_size()) if DisplayServer.get_name() != "headless" else "headless", "browser" if OS.has_feature("web") else OS.get_processor_name()])
	if crashed_before:
		record("crash", "the session before this one did not end cleanly (a crash, or the game was killed); its log is kept as crash.log")
		_queue_crash_tail()
	OS.add_logger(tap)
	file_log.flush()

func _exit_tree() -> void:
	end()

## A clean end: the last line, the marker removed (so the next start does not count a crash).
func end() -> void:
	if _ended or file_log == null:
		return
	_ended = true
	_drain()
	record("end", "clean exit after %d s; %d errors, %d warnings" % [int(_up), errors, warnings])
	OS.remove_logger(tap)
	file_log.close()
	DirAccess.remove_absolute(_marker)

static func _other_instance(marker: String) -> bool:
	if OS.has_feature("web"):
		return false
	var pid := FileAccess.get_file_as_string(marker).strip_edges()
	return pid.is_valid_int() and int(pid) != OS.get_process_id() and OS.is_process_running(int(pid))

## Moves session.log (and .1) to `to`.log (and .1), replacing what was there.
func _keep_previous(to: String) -> void:
	for suffix: String in ["", ".1"]:
		var src := "%s/session%s.log" % [dir, suffix]
		var dst := "%s/%s%s.log" % [dir, to, suffix]
		DirAccess.remove_absolute(dst)
		if FileAccess.file_exists(src):
			DirAccess.rename_absolute(src, dst)

## Files of other copies that are no longer running (their markers and logs).
func _sweep() -> void:
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("running-") and not _other_instance(dir + "/" + f):
			var pid := f.substr(8)
			DirAccess.remove_absolute(dir + "/" + f)
			for g: String in ["session-%s.log" % pid, "session-%s.1.log" % pid]:
				DirAccess.remove_absolute(dir + "/" + g)

## One line in this session's log (and the last REPORT_SECONDS kept for an F9 report).
func record(kind: String, text: String) -> void:
	var line := "%sZ %s %s" % [Time.get_datetime_string_from_system(true), kind, scrub(text).left(Protocol.MAX_TELEMETRY_LINE)]
	if file_log != null:
		file_log.write(line)
	var now := Time.get_ticks_msec()
	_recent.append([now, line])
	while _recent.size() > 2000 or (not _recent.is_empty() and now - int(_recent[0][0]) > int(REPORT_SECONDS * 2000.0)):
		_recent.pop_front()

## `text` without the passphrase typed into the join form (or given as pass=), and on one line.
func scrub(text: String) -> String:
	var out := text.replace("\n", " | ").replace("\r", "")
	var secret := ""
	if main != null:
		var st: Variant = main.get("start")
		if st is Object:
			secret = str((st as Object).get("passphrase"))
		var pa: Variant = main.get("pass_arg")
		if secret.length() < 3 and pa is String:
			secret = pa
	if secret.length() >= 3:
		out = out.replace(secret, "***")
	var at := out.find("pass=")
	while at >= 0:
		var stop := out.find(" ", at)
		out = out.substr(0, at + 5) + "***" + (out.substr(stop) if stop >= 0 else "")
		at = out.find("pass=", at + 8)
	return out

## An engine or script error (or warning): written once a window (repeats counted), and sent while the
## window's budget lasts.
func error_line(kind: String, text: String) -> void:
	if kind == "warn":
		warnings += 1
	else:
		errors += 1
	_window()
	if _repeats.has(text):
		_repeats[text] = int(_repeats[text]) + 1
		return
	_repeats[text] = 1
	_local_in_window += 1
	if _local_in_window > LOCAL_PER_WINDOW:
		return
	record(kind, text)
	send_line("%s %s" % [kind, text])

## A line for the server's log (an error, a disconnect), within the minute's budget.
func send_line(text: String) -> void:
	_window()
	if _sent_in_window >= SEND_PER_WINDOW:
		unsent += 1
		return
	_sent_in_window += 1
	_post({"type": "telemetry", "kind": "log", "body": scrub(text).left(Protocol.MAX_TELEMETRY_LINE)})

func _window() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _window_at < WINDOW:
		return
	for t: String in _repeats:
		if int(_repeats[t]) > 1:
			record("rep", "%d more times in the last minute: %s" % [int(_repeats[t]) - 1, t])
	_repeats.clear()
	_window_at = now
	_sent_in_window = 0
	_local_in_window = 0

func _post(m: Dictionary) -> void:
	if outbox.size() < OUTBOX_MAX:
		outbox.append(m)
	else:
		unsent += 1

func _drain() -> void:
	for e: Array in tap.take():
		error_line(String(e[0]), String(e[1]))

# --- each frame -----------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_up += delta
	for acc: Array in [_perf, _hb]:
		acc[0] = float(acc[0]) + delta
		acc[1] = int(acc[1]) + 1
		acc[2] = maxf(float(acc[2]), delta)
	_drain()
	_watch()
	if _up - _perf_at >= PERF_EVERY:
		_perf_at = _up
		record("perf", "%s, %s" % [_frames_text(_perf), _where_text()])
		_perf = [0.0, 0, 0.0]
	if _up - _hb_at >= HEARTBEAT_EVERY:
		_hb_at = _up
		if _online():
			_post({"type": "telemetry", "kind": "hb", "body": JSON.stringify(heartbeat())})
		_hb = [0.0, 0, 0.0]
	_send()
	if file_log != null:
		file_log.flush()
	if _note != null and _note_text != "" and Time.get_ticks_msec() > _note_until:
		_note_text = ""
		_note.queue_redraw()

static func _frames_text(acc: Array) -> String:
	var n := int(acc[1])
	return "frames %d, average %.1f ms, worst %.1f ms" % [n, 1000.0 * float(acc[0]) / maxi(n, 1), 1000.0 * float(acc[2])]

## What a heartbeat says (server/night_log.gd HB_KEYS: anything else is dropped there).
func heartbeat() -> Dictionary:
	var n := int(_hb[1])
	var w := where()
	return {"build": BuildInfo.id(), "os": "%s %s" % [OS.get_name(), OS.get_version()], "gpu": RenderingServer.get_video_adapter_name().left(80),
		"renderer": RenderingServer.get_current_rendering_method(), "mode": w["mode"], "place": w["place"], "phase": w["phase"], "depth": w["depth"],
		"fps": snappedf(Engine.get_frames_per_second(), 0.1), "avg_ms": snappedf(1000.0 * float(_hb[0]) / maxi(n, 1), 0.01),
		"worst_ms": snappedf(1000.0 * float(_hb[2]), 0.01), "ping_ms": _ping_ms(), "errors": errors, "warnings": warnings,
		"mem_mb": snappedf(OS.get_static_memory_usage() / 1048576.0, 0.1), "up_s": int(_up), "dropped": unsent}

## Where the player is: main's mode ("title", "join", "lobby", "game", ...), the floor's place, depth, phase.
func where() -> Dictionary:
	var out := {"mode": "", "place": "", "depth": -1, "phase": ""}
	if main == null:
		return out
	out["mode"] = str(main.get("mode"))
	var snap: Variant = main.get("snap")
	if snap is Dictionary:
		out["phase"] = str((snap as Dictionary).get("phase", ""))
		out["depth"] = int((snap as Dictionary).get("depth", -1))
	var link: Variant = main.get("link")
	if link is Object:
		var pd: Variant = (link as Object).get("plan_dict")
		if pd is Dictionary:
			out["place"] = str((pd as Dictionary).get("place", ""))
	return out

func _where_text() -> String:
	var w := where()
	return "mode %s, place %s, depth %d, phase %s" % [w["mode"], w["place"] if w["place"] != "" else "-", int(w["depth"]), w["phase"] if w["phase"] != "" else "-"]

func _ping_ms() -> float:
	if _rc == null or _rc.client == null or not _rc.client.clock.ready():
		return -1.0
	return snappedf(_rc.client.clock.rtt_best() * 1000.0, 0.1)

## The connection and where the player is, for the log: a new connection, its status, how it closed.
func _watch() -> void:
	var wt := _where_text()
	if wt != _where:
		_where = wt
		record("where", wt)
	if main == null:
		return
	var link: Variant = main.get("link")
	if link is Object and (link as Object).get("local") != true:
		var rc: Variant = (link as Object).get("rc")
		if rc is RoomClient and rc != _rc:
			_rc = rc
			_rc_status = ""
	if _rc == null:
		return
	if _rc.status != _rc_status:
		_rc_status = _rc.status
		if _rc_status == "closed":
			var line := "connection closed: code %d%s, after %s" % [_rc.close_code, " (%s)" % _rc.close_reason if _rc.close_reason != "" else "", wt]
			record("disc", line)
			send_line("disc " + line)
			_rc = null
		else:
			record("net", "connection %s" % _rc_status)

func _online() -> bool:
	return _rc != null and (_rc.status == "lobby" or _rc.status == "running")

## Sends what waits, while a server connection is open (a few a frame).
func _send() -> void:
	if _rc == null or outbox.is_empty():
		return
	for i in 4:
		if outbox.is_empty():
			return
		if not _rc.send_telemetry(outbox[0]):
			return
		outbox.pop_front()

# --- F9 ---------------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo and (event as InputEventKey).physical_keycode == KEY_F9:
		get_viewport().set_input_as_handled()
		_show(report())

## An F9 report: written here (with a picture of the screen), and sent to the server when connected and
## the last one was more than REPORT_GAP s ago. Returns the line to show.
func report() -> String:
	_drain()
	var now_ms := Time.get_ticks_msec()
	var head := "player pressed F9 at %sZ: %s, %d s into the session" % [Time.get_datetime_string_from_system(true), _where_text(), int(_up)]
	record("f9", head)
	var lines := PackedStringArray([head])
	for r: Array in _recent:
		if now_ms - int(r[0]) <= int(REPORT_SECONDS * 1000.0):
			lines.append(String(r[1]))
	var text := "\n".join(lines)
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "").replace("-", "")
	DirAccess.make_dir_recursive_absolute(dir + "/reports")
	var f := FileAccess.open("%s/reports/f9-%s.txt" % [dir, stamp], FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
		f.close()
	if DisplayServer.get_name() != "headless" and is_inside_tree():
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_jpg("%s/reports/f9-%s.jpg" % [dir, stamp], 0.7)
	_prune_reports()
	if not _online() or (now_ms / 1000.0) - _last_report < REPORT_GAP:
		return SAVED
	_last_report = now_ms / 1000.0
	_report_id += 1
	for m in report_parts("rep", _report_id, lines):
		_post(m)
	return SENT

## `lines` as report messages of at most Protocol.MAX_TELEMETRY_PART bytes each (as JSON text), the first
## line (the header) always in the first part; when there are more than MAX_TELEMETRY_PARTS parts' worth,
## the oldest lines after the header are left out.
static func report_parts(kind: String, rid: int, lines: PackedStringArray) -> Array[Dictionary]:
	var budget := Protocol.MAX_TELEMETRY_PART - 2
	var parts: Array[String] = []
	var cur := ""
	# Newest first, so whatever is cut is the oldest.
	for i in range(lines.size() - 1, 0, -1):
		var l := lines[i].left(Protocol.MAX_TELEMETRY_LINE)
		var add := l if cur == "" else l + "\n" + cur
		if JSON.stringify(add).to_utf8_buffer().size() > budget:
			parts.push_front(cur)
			cur = l
		else:
			cur = add
	var head := lines[0].left(Protocol.MAX_TELEMETRY_LINE) if lines.size() > 0 else ""
	if cur == "" or JSON.stringify(head + "\n" + cur).to_utf8_buffer().size() <= budget:
		cur = head if cur == "" else head + "\n" + cur
	else:
		parts.push_front(cur)
		cur = head
	parts.push_front(cur)
	while parts.size() > Protocol.MAX_TELEMETRY_PARTS:
		parts.remove_at(1)
	var out: Array[Dictionary] = []
	for i in parts.size():
		out.append({"type": "telemetry", "kind": kind, "body": parts[i], "id": rid, "part": i, "parts": parts.size()})
	return out

func _queue_crash_tail() -> void:
	var lines := PackedStringArray()
	for p: String in ["%s/crash.1.log" % dir, "%s/crash.log" % dir]:
		if FileAccess.file_exists(p):
			lines.append_array(FileAccess.get_file_as_string(p).split("\n", false))
	var tail := lines.slice(maxi(0, lines.size() - CRASH_TAIL_LINES))
	tail.insert(0, "the session before this one did not end cleanly (crash or killed); its last %d lines:" % tail.size())
	_report_id += 1
	for m in report_parts("crash", _report_id, tail):
		_post(m)

func _prune_reports() -> void:
	var files := Array(DirAccess.get_files_at(dir + "/reports"))
	files.sort()
	var txt := files.filter(func(f: String) -> bool: return f.ends_with(".txt"))
	for i in maxi(0, txt.size() - REPORTS_KEPT):
		var stem: String = String(txt[i]).get_basename()
		DirAccess.remove_absolute("%s/reports/%s.txt" % [dir, stem])
		DirAccess.remove_absolute("%s/reports/%s.jpg" % [dir, stem])

func _show(text: String) -> void:
	_note_text = text
	_note_until = Time.get_ticks_msec() + NOTE_MS
	if _note != null:
		_note.queue_redraw()

func _draw_note() -> void:
	if _note_text == "":
		return
	var sz := _note.size
	var px := maxf(2.0, floorf(sz.y / 240.0))
	PixelFont.draw_shadowed(_note, _note_text, Vector2(floorf((sz.x - PixelFont.width(_note_text) * px) * 0.5), floorf(sz.y * 0.86)), px, Color("#f4f4ec"))
