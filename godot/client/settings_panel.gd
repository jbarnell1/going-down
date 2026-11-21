# The host's settings panel and the one-line notice (docs/floors/live-settings.md section 4, piece LS3). F8 opens
# it over the game (in a run and in the lobby); F8 or Esc closes it. The game goes on underneath.
#
# Anyone can open it. For the host it is live; for everyone else every control is grey and the top line says who
# the host is. Every word and number comes from the registry (sim/settings.gd: its wired rows, in its order, group
# by group, player speeds last) and the two lists the room keeps (net/room_client.gd: what the host asked for, and
# what is in force, also the run's own list from the snapshots); the panel holds no list of its own.
#
#   left    TONIGHT'S CHANGES, then the sections of the groups with a count of changed rows in each
#   right   the chosen section's rows: the name, a slider with a notch at the game's value, [-] and [+] (one step;
#           Shift five), the value in force with its unit, when it holds, [RESET]. A changed row has an amber *
#           and WAS ...; a value that waits for the next floor or tomorrow shows both ("FROM THE NEXT FLOOR. NOW
#           5.0"). An arrow that would break a pair rule is grey.
#   keys    up and down move between rows, left and right one step (Shift five), Tab the next section, Backspace
#           resets the row, Backspace held for 1 s resets everything. The mouse does the same; a slider drags.
#   sending a value goes when the key or the mouse is let go, or after 0.3 s without moving: a drag is one change.
#   refused the row snaps back and says why for 2 s.
#
# YOUR SOUND (MU1; the owner, 20 Nov: "That shouldn't just be the host, that should be everyone"): a page of the
# player's own MASTER, MUSIC and EFFECTS sliders (client/volume.gd), live for every player, host or not, kept on
# this computer only and never sent. The [YOUR SOUND] button on the top line or S opens it (S or a section goes
# back); the Esc menu's V opens the panel on it. Up and down choose a slider, left and right move it 5 % (Shift
# 25 %), Backspace puts it back to 100 %; the mouse clicks - and +, drags the slider, RESET.
#
# The notice: one line at the top centre for 4 s (more than three in 2 s become one: "... CHANGED 5 SETTINGS. F8 TO
# SEE."), from every "tune" message's line (the server words it, so every screen says the same).
extends Control

const Settings = preload("res://sim/settings.gd")
const TuningDesk = preload("res://net/tuning_desk.gd")
const Run = preload("res://sim/run.gd")
const Stamina = preload("res://sim/stamina.gd")
const Volume = preload("res://client/volume.gd")

const INK := Color("#f4f4ec")
const AMBER := Color("#ffd27a")
const GREY := Color(0.55, 0.57, 0.55)
const DIM := Color(0.36, 0.38, 0.36)
const RED := Color("#ff7a6a")
const CARD := Color(0.03, 0.035, 0.035, 0.97)
const NOTICE_SECONDS := 4.0
const SEND_IDLE := 0.3
const HOLD_RESET_ALL := 1.0
## The room (net/room_client.gd or net/local_room.gd), set by the game every frame; null for none.
var rc: Object = null
## Notices shown: {text, until}.
var notice := ""
var notice_until := 0.0
var _recent: Array = []  # times of notices in the last 2 s
var _open := false
var _sections: Array[Dictionary] = []  # {id, title, group, rows: Array[Setting]} (first: tonight's changes)
var _sel := 1
var _row := 0
var _pending := {}  # id -> value not yet sent
var _pending_at := 0.0
var _flash := ""
var _flash_until := 0.0
var _flash_id: StringName = &""
var _back_down_at := -1.0
var _drag: StringName = &""
var _hits: Array = []  # [Rect2, kind, arg]
var _seen_refusals := 0
## MU1: the player's own sound levels (client/volume.gd), set by the game; null for none (no page then).
var volume: Object = null
var _sound := false
var _sound_row := 0
var _sound_drag := ""

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()

func _build() -> void:
	_sections = [{"id": &"changes", "title": "TONIGHT'S CHANGES", "group": &"", "rows": []}]
	var groups := Settings.groups()
	for g in groups:
		for sec in Settings.sections():
			if sec["group"] != g["id"]:
				continue
			var rows: Array = []
			for s in Settings.list(true):
				if s.section == sec["id"]:
					rows.append(s)
			if not rows.is_empty():
				_sections.append({"id": sec["id"], "title": sec["title"], "group": g["id"], "group_title": g["title"], "rows": rows})

func is_open() -> bool:
	return _open

func open() -> void:
	_open = true
	_build()
	_sel = clampi(_sel, 0, _sections.size() - 1)
	mouse_filter = Control.MOUSE_FILTER_STOP

func close() -> void:
	_send_pending()
	_sound_let_go()
	_open = false
	_drag = &""
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func toggle() -> void:
	if _open:
		close()
	else:
		open()

# ---------------------------------------------------------------------------------------------
# What the room says.

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func is_host() -> bool:
	return rc != null and bool(rc.call("is_host"))

func _asked() -> Dictionary:
	return rc.get("tune_asked") if rc != null else {}

## The values in force: the run's own list (the snapshots) once it has one, else the room's.
func _in_force() -> Dictionary:
	if rc == null:
		return {}
	var c: Object = rc.get("client")
	if c != null and int(c.get("tune_rev")) > 0 and int(c.get("tune_rev")) >= int(rc.get("tune_rev")):
		return c.get("tune_in_force")
	return rc.call("tune_in_force")

func host_name() -> String:
	if rc == null:
		return ""
	var h := str(rc.get("tune_host"))
	for p: Variant in rc.get("people"):
		if p is Array and str(p[0]) == h:
			return str(p[1]).to_upper()
	return h.to_upper()

func value_of(id: StringName) -> float:
	if _pending.has(id):
		return float(_pending[id])
	return float(_asked().get(id, Settings.today(id)))

func force_of(id: StringName) -> float:
	return float(_in_force().get(id, Settings.today(id)))

func changed_count() -> int:
	return _asked().size()

func _section_rows(i: int) -> Array:
	if i == 0:
		var out: Array = []
		var asked := _asked()
		for s in Settings.list(true):
			if asked.has(s.id) or _in_force().has(s.id):
				out.append(s)
		return out
	return _sections[i]["rows"]

func _changed_in(i: int) -> int:
	var n := 0
	var asked := _asked()
	for s: Settings.Setting in _section_rows(i):
		if asked.has(s.id):
			n += 1
	return n

# ---------------------------------------------------------------------------------------------
# Every frame: notices, refusals, the 0.3 s send.

func _process(_d: float) -> void:
	var want := get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	var now := _now()
	if rc != null:
		var lines: Array = rc.get("tune_lines")
		if not lines.is_empty():
			for l: Variant in lines:
				_show_notice(str(l), now)
			lines.clear()
		var refusals: Array = rc.get("tune_refusals")
		if refusals.size() > _seen_refusals:
			var r: Dictionary = refusals[refusals.size() - 1]
			_refused(str(r.get("why", "")), now)
		_seen_refusals = refusals.size()
	if not _pending.is_empty() and now - _pending_at >= SEND_IDLE and _drag == &"":
		_send_pending()
	if _back_down_at >= 0.0 and now - _back_down_at >= HOLD_RESET_ALL:
		_back_down_at = -1.0
		_pending.clear()
		if is_host():
			rc.call("tune_reset_all")
	queue_redraw()

func _show_notice(text: String, now: float) -> void:
	var kept: Array = []
	for t: float in _recent:
		if now - t < 2.0:
			kept.append(t)
	kept.append(now)
	_recent = kept
	if kept.size() > 3:
		var by := text.get_slice(" ", 0)
		notice = "%s CHANGED %d SETTINGS. F8 TO SEE." % [by, kept.size()]
	else:
		notice = text
	notice_until = now + NOTICE_SECONDS

func _refused(why: String, now: float) -> void:
	_flash = refusal_words(why)
	_flash_until = now + 2.0
	_pending.clear()

## What a refusal says on the row.
func refusal_words(why: String) -> String:
	match why:
		"host":
			return "ONLY THE HOST CAN CHANGE THESE"
		"range":
			return "OUT OF RANGE"
		"pair":
			var given := _asked().duplicate()
			return Settings.pair_broken(given) if not Settings.pair_broken(given).is_empty() else "THAT BREAKS A PAIR RULE"
		"busy":
			return "TOO FAST: TRY AGAIN"
		"id":
			return "THIS BUILD DOES NOT KNOW THAT SETTING"
	return "REFUSED"

# ---------------------------------------------------------------------------------------------
# Changing a value (the host only: everyone else's panel never sends).

func _setting(i: int, r: int) -> Settings.Setting:
	var rows := _section_rows(i)
	if r < 0 or r >= rows.size():
		return null
	return rows[r]

## The value one press from `v` (dir -1 or +1, `n` steps), or `v` when that is out of range or breaks a pair.
func stepped(id: StringName, v: float, dir: int, n: int = 1) -> float:
	var s := Settings.row(id)
	var w := Settings.snap(id, clampf(v + dir * n * s.step, s.lo, s.hi))
	var others := _asked().duplicate()
	others.erase(id)
	for k: Variant in _pending:
		if k != id:
			others[k] = _pending[k]
	return w if Settings.check(id, w, others) == &"" else v

## Whether an arrow can move (in range and no pair rule broken).
func can_step(id: StringName, dir: int) -> bool:
	var v := value_of(id)
	return is_host() and stepped(id, v, dir) != v

func nudge(id: StringName, dir: int, n: int = 1) -> bool:
	if not is_host():
		return false
	var v := value_of(id)
	var w := stepped(id, v, dir, n)
	if w == v:
		_flash = refusal_words("pair") if stepped(id, v, dir, 1) == v and Settings.check(id, Settings.snap(id, v + dir * Settings.row(id).step), _asked()) == &"pair" else "AT THE END OF ITS RANGE"
		_flash_until = _now() + 2.0
		_flash_id = id
		return false
	_pending[id] = w
	_pending_at = _now()
	return true

func set_value(id: StringName, v: float) -> bool:
	if not is_host():
		return false
	_pending[id] = Settings.snap(id, v)
	_send_pending()
	return true

func reset_row(id: StringName) -> bool:
	if not is_host():
		return false
	_pending.erase(id)
	return bool(rc.call("tune_reset", id))

func reset_all() -> bool:
	if not is_host():
		return false
	_pending.clear()
	return bool(rc.call("tune_reset_all"))

func _send_pending() -> void:
	if _pending.is_empty() or rc == null:
		return
	if is_host():
		for id: StringName in _pending:
			var v := float(_pending[id])
			if absf(v - float(_asked().get(id, Settings.today(id)))) > 1e-9:
				rc.call("tune_set", id, v)
	_pending.clear()

# ---------------------------------------------------------------------------------------------
# YOUR SOUND (MU1): every player's own, nothing sent.

func is_sound() -> bool:
	return _sound

## The sound page on or off (off: back to the section that was chosen).
func show_sound(on: bool) -> void:
	_sound = on and volume != null
	_sound_drag = ""

## One slider `dir` steps of Volume.STEP (`n` at a time), applied at once and saved.
func sound_nudge(row: int, dir: int, n: int = 1) -> bool:
	if volume == null or row < 0 or row >= Volume.ROWS.size():
		return false
	var key_name := str(Volume.ROWS[row][0])
	var was: int = volume.get_pct(key_name)
	return sound_set(row, was + dir * n * Volume.STEP)

## One slider to `pct` %, applied at once (saved unless a drag is still going).
func sound_set(row: int, pct: int) -> bool:
	if volume == null or row < 0 or row >= Volume.ROWS.size():
		return false
	var key_name := str(Volume.ROWS[row][0])
	var was: int = volume.get_pct(key_name)
	volume.set_pct(key_name, pct)
	volume.apply()
	if _sound_drag == "":
		volume.save()
	return volume.get_pct(key_name) != was

func _sound_let_go() -> void:
	if _sound_drag != "" and volume != null:
		_sound_drag = ""
		volume.save()
	_sound_drag = ""

func _sound_key(k: InputEventKey) -> void:
	if k.physical_keycode == KEY_BACKSPACE:
		if k.pressed and not k.echo:
			sound_set(_sound_row, Volume.DEFAULT)
		return
	if not k.pressed:
		return
	var n := 5 if k.shift_pressed else 1
	match k.physical_keycode:
		KEY_ESCAPE, KEY_F8:
			if not k.echo:
				close()
		KEY_S, KEY_TAB:
			if not k.echo:
				show_sound(false)
		KEY_UP:
			_sound_row = maxi(0, _sound_row - 1)
		KEY_DOWN:
			_sound_row = mini(Volume.ROWS.size() - 1, _sound_row + 1)
		KEY_LEFT, KEY_RIGHT:
			sound_nudge(_sound_row, -1 if k.physical_keycode == KEY_LEFT else 1, n)

static func _sound_row_of(key_name: String) -> int:
	for i in Volume.ROWS.size():
		if str(Volume.ROWS[i][0]) == key_name:
			return i
	return -1

func _sound_drag_to(pos: Vector2) -> void:
	for h: Array in _hits:
		if String(h[1]) == "snd_slider" and int(h[2]) == _sound_row_of(_sound_drag):
			var r: Rect2 = h[0]
			var f := clampf((pos.x - r.position.x) / maxf(1.0, r.size.x), 0.0, 1.0)
			sound_set(int(h[2]), roundi(f * 100.0))
			return

# ---------------------------------------------------------------------------------------------
# Keys and the mouse (the game passes them while the panel is open).

func key(k: InputEventKey) -> void:
	if _sound:
		_sound_key(k)
		return
	if k.physical_keycode == KEY_S and volume != null:
		if k.pressed and not k.echo:
			show_sound(true)
		return
	var now := _now()
	if k.physical_keycode == KEY_BACKSPACE:
		if k.pressed and not k.echo:
			_back_down_at = now
			var s := _setting(_sel, _row)
			if s != null:
				reset_row(s.id)
		elif not k.pressed:
			_back_down_at = -1.0
		return
	if not k.pressed:
		if k.physical_keycode == KEY_LEFT or k.physical_keycode == KEY_RIGHT:
			_send_pending()
		return
	var n := 5 if k.shift_pressed else 1
	match k.physical_keycode:
		KEY_ESCAPE, KEY_F8:
			if not k.echo:
				close()
		KEY_TAB:
			if not k.echo:
				_sel = (_sel + (-1 if k.shift_pressed else 1) + _sections.size()) % _sections.size()
				_row = 0
		KEY_UP:
			_row = maxi(0, _row - 1)
		KEY_DOWN:
			_row = mini(maxi(0, _section_rows(_sel).size() - 1), _row + 1)
		KEY_LEFT, KEY_RIGHT:
			var s := _setting(_sel, _row)
			if s != null:
				nudge(s.id, -1 if k.physical_keycode == KEY_LEFT else 1, n)

func mouse(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			click(mb.position, mb.shift_pressed)
		elif _sound_drag != "":
			_sound_let_go()
		elif _drag != &"":
			_drag = &""
			_send_pending()
	elif e is InputEventMouseMotion and _sound_drag != "":
		_sound_drag_to((e as InputEventMouseMotion).position)
	elif e is InputEventMouseMotion and _drag != &"":
		_drag_to((e as InputEventMouseMotion).position)

## A click at `pos` (window pixels). True when it hit something.
func click(pos: Vector2, shift: bool = false) -> bool:
	for h: Array in _hits:
		var r: Rect2 = h[0]
		if not r.has_point(pos):
			continue
		match String(h[1]):
			"sound_tab":
				show_sound(not _sound)
			"snd_row":
				_sound_row = int(h[2])
			"snd_minus", "snd_plus":
				_sound_row = int(h[2])
				sound_nudge(_sound_row, -1 if h[1] == "snd_minus" else 1, 5 if shift else 1)
			"snd_reset":
				_sound_row = int(h[2])
				sound_set(_sound_row, Volume.DEFAULT)
			"snd_slider":
				_sound_row = int(h[2])
				_sound_drag = str(Volume.ROWS[_sound_row][0])
				_sound_drag_to(pos)
			"section":
				show_sound(false)
				_sel = int(h[2])
				_row = 0
			"minus", "plus":
				_row = int(h[3])
				nudge(h[2], -1 if h[1] == "minus" else 1, 5 if shift else 1)
				_send_pending()
			"reset":
				_row = int(h[3])
				reset_row(h[2])
			"slider":
				_row = int(h[3])
				if is_host():
					_drag = h[2]
					_drag_to(pos)
			"row":
				_row = int(h[3])
		return true
	return false

func _drag_to(pos: Vector2) -> void:
	for h: Array in _hits:
		if String(h[1]) == "slider" and h[2] == _drag:
			var r: Rect2 = h[0]
			var s := Settings.row(_drag)
			var f := clampf((pos.x - r.position.x) / maxf(1.0, r.size.x), 0.0, 1.0)
			var v := Settings.snap(_drag, s.lo + f * (s.hi - s.lo))
			var others := _asked().duplicate()
			others.erase(_drag)
			if Settings.check(_drag, v, others) == &"":
				_pending[_drag] = v
				_pending_at = _now()
			return

# ---------------------------------------------------------------------------------------------
# What a test (and the screen) reads.

## The words on a row: [value text, was text or "", holds text, waiting text or ""].
func row_words(s: Settings.Setting) -> Array:
	var asked := _asked()
	var force := force_of(s.id)
	var v := value_of(s.id)
	var changed := Settings.differs(s.id, v)
	var waits := absf(force - float(asked.get(s.id, s.today))) > 1e-9 and not _pending.has(s.id)
	var main := ("* " if changed else "  ") + Settings.text(s.id, v)
	var was := "WAS " + TuningDesk.bare(s.id, s.today) if changed else ""
	var holds: String = Settings.HOLDS_SHOWN.get(s.holds, "")
	var wait := ""
	if waits:
		wait = "%s. NOW %s" % ["FROM THE NEXT FLOOR" if s.holds == &"floor" else ("FROM TOMORROW" if s.holds == &"day" else "SOON"), TuningDesk.bare(s.id, force)]
	return [main, was, holds, wait]

## The top line: the host's own, or the read-only one.
func top_line() -> String:
	if is_host():
		return "HOST SETTINGS"
	var h := host_name()
	return "ONLY THE HOST CAN CHANGE THESE. HOST: %s" % (h if not h.is_empty() else "NOBODY YET")

## The foot: for the host, how to change a value first (PT6: the panel says how it works on first open).
func foot_line() -> String:
	if _sound:
		return "UP DOWN: CHOOSE    LEFT RIGHT OR DRAG: CHANGE    BACKSPACE: 100    S: BACK    F8: CLOSE"
	if is_host():
		return "LEFT RIGHT OR CLICK: CHANGE    TAB: NEXT    HOLD BACKSPACE: RESET ALL %d    F8: CLOSE" % changed_count()
	return "S: YOUR SOUND    F8: CLOSE" if volume != null else "F8: CLOSE"

## MU1: the sound page's rows: {key, name, pct, text}.
func sound_rows() -> Array:
	var out: Array = []
	if volume == null:
		return out
	for r: Array in Volume.ROWS:
		var pct: int = volume.get_pct(str(r[0]))
		out.append({"key": str(r[0]), "name": str(r[1]), "pct": pct, "text": "OFF" if pct == 0 else "%d%%" % pct})
	return out

func saved_line() -> String:
	if rc == null:
		return ""
	if not bool(rc.get("tune_file")):
		return "NOT SAVED: THIS SERVER HAS NO SETTINGS FILE"
	var at := str(rc.get("tune_saved"))
	return "SAVED " + at.substr(11, 5) if at.length() >= 16 else "NOTHING SAVED YET"

## A hint under some rows, worked out from the registry and the values: the lift's wait, a resident's speed
## against the player's.
func hint(s: Settings.Setting) -> String:
	if s.section == &"lift" and (s.id == &"lift.floors_min" or s.id == &"lift.floors_max" or s.id == &"lift.floor_time"):
		var fewest := value_of(&"lift.floors_min")
		var most := value_of(&"lift.floors_max")
		var sec := value_of(&"lift.floor_time")
		return "THE WAIT: %d TO %d S. A FALSE STOP ADDS UP TO %d." % [roundi(Run.CALL_START_DELAY_MIN + fewest * sec), roundi(Run.CALL_START_DELAY_MAX + most * sec), roundi(Run.FALSE_STOP_EXTRA_MAX)]
	if s.unit == "m/s" and (s.section == &"orderly" or s.section == &"temp" or s.section == &"minder"):
		return "YOU WALK %.1f, SPRINT %.1f" % [Stamina.WALK_SPEED, Stamina.SPRINT_SPEED]
	return ""

func describe() -> Dictionary:
	var rows: Array = []
	for i in _sections.size():
		if i == 0:
			continue
		for s: Settings.Setting in _section_rows(i):
			var w := row_words(s)
			rows.append({"id": String(s.id), "section": String(s.section), "group": String(s.group), "name": s.name, "value": w[0], "was": w[1], "holds": w[2], "wait": w[3],
				"minus": can_step(s.id, -1), "plus": can_step(s.id, 1)})
	var secs: Array = []
	for i in _sections.size():
		secs.append({"id": String(_sections[i]["id"]), "title": _sections[i]["title"], "changed": _changed_in(i)})
	return {"open": _open, "host": is_host(), "top": top_line(), "saved": saved_line(), "changed": changed_count(), "notice": notice if _now() < notice_until else "",
		"sections": secs, "sel": _sel, "row": _row, "rows": rows, "flash": _flash if _now() < _flash_until else "",
		"asked": _plain(_asked()), "inForce": _plain(_in_force()), "rev": int(rc.get("tune_rev")) if rc != null else 0,
		"runRev": int(rc.get("client").get("tune_rev")) if rc != null and rc.get("client") != null else 0,
		"sound": {"open": _sound, "row": _sound_row, "rows": sound_rows(), "foot": foot_line()}}

static func _plain(d: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in d:
		out[String(k)] = d[k]
	return out

func select(section: StringName) -> bool:
	for i in _sections.size():
		if _sections[i]["id"] == section:
			_sel = i
			_row = 0
			return true
	return false

# ---------------------------------------------------------------------------------------------
# Drawing.

func _px() -> float:
	return maxf(2.0, floor(size.y / 320.0))

func _text(t: String, at: Vector2, px: float, col: Color) -> void:
	PixelFont.draw_shadowed(self, t, at, px, col)

func _w(t: String, px: float) -> float:
	return PixelFont.width(t) * px

## A title as the pixel font can print it: "THE ORDERLY (THE CLINIC)" -> "THE ORDERLY, THE CLINIC" (`short`: "THE ORDERLY").
static func _printable(t: String, short: bool = false) -> String:
	var k := t.find(" (")
	if k >= 0:
		return t.left(k) if short else t.left(k) + ", " + t.substr(k + 2).trim_suffix(")")
	return t

## A button: the label in a box.
func _button(label: String, at: Vector2, px: float, col: Color) -> Rect2:
	var r := Rect2(at - Vector2(2, 2) * px, Vector2(_w(label, px) + 4 * px, 11 * px))
	draw_rect(r, Color(col, 0.6), false, maxf(1.0, px * 0.5))
	_text(label, at, px, col)
	return r

## MU1: the sound page's three rows at `at` (the right side; `right` is the card's inner right edge): the name, the
## value, - slider +, RESET. Live for every player: the host's grey never applies here.
func _draw_sound(at: Vector2, rw: float, px: float, lh: float, right: float) -> void:
	var ry := at.y
	var rx := at.x
	var rows := sound_rows()
	for r in rows.size():
		var row: Dictionary = rows[r]
		var on := r == _sound_row
		var row_h := lh * 2.0 + 2 * px
		if on:
			draw_rect(Rect2(Vector2(rx - 4 * px, ry - 3 * px), Vector2(rw + 8 * px, row_h)), Color(1, 1, 1, 0.06))
		_hits.append([Rect2(Vector2(rx, ry - 3 * px), Vector2(rw, row_h)), "snd_row", r])
		var changed := int(row["pct"]) != Volume.DEFAULT
		_text(str(row["name"]), Vector2(rx, ry), px, INK if on else Color(0.85, 0.86, 0.82))
		var vy := ry + lh
		if changed:
			draw_rect(Rect2(Vector2(rx, vy + 2 * px), Vector2(3 * px, 3 * px)), AMBER)
		_text(str(row["text"]), Vector2(rx + 6 * px, vy), px, AMBER if changed else INK)
		var reset_w := _w("RESET", px) + 4 * px
		var reset_at := Vector2(right - reset_w + 2 * px, vy)
		var reset_r := _button("RESET", reset_at, px, INK if changed else DIM)
		_hits.append([reset_r, "snd_reset", r])
		var plus_at := Vector2(reset_at.x - 14 * px, vy)
		var slider_end := plus_at.x - 6 * px
		var minus_at := Vector2(rx + 6 * px + 8 * 6 * px, vy)
		var minus_r := _button("-", minus_at, px, INK if int(row["pct"]) > 0 else DIM)
		_hits.append([minus_r, "snd_minus", r])
		var plus_r := _button("+", plus_at, px, INK if int(row["pct"]) < 100 else DIM)
		_hits.append([plus_r, "snd_plus", r])
		var track := Rect2(Vector2(minus_r.end.x + 5 * px, vy + 3 * px), Vector2(maxf(10 * px, slider_end - minus_r.end.x - 10 * px), px))
		draw_rect(track, GREY)
		var fv := float(row["pct"]) / 100.0
		draw_rect(Rect2(Vector2(track.position.x + track.size.x * fv - 2 * px, vy), Vector2(4 * px, 7 * px)), AMBER if changed else INK)
		_hits.append([Rect2(Vector2(track.position.x, vy - 2 * px), Vector2(track.size.x, 11 * px)), "snd_slider", r])
		ry += row_h + 4 * px
	_text("NOT SENT TO ANYONE. THE HOST'S SETTINGS ARE ON THE LEFT.", Vector2(rx, ry + 2 * px), px, GREY)

func _draw() -> void:
	var px := _px()
	var now := _now()
	if _open:
		_draw_panel(px, now)
	if now < notice_until and not notice.is_empty():
		var w := _w(notice, px)
		var p := Vector2(floorf((size.x - w) * 0.5), (5.0 if _open else 26.0) * px)
		draw_rect(Rect2(p - Vector2(5, 3) * px, Vector2(w + 10 * px, 13 * px)), Color(0, 0, 0, 0.85))
		_text(notice, p, px, AMBER)

func _draw_panel(px: float, now: float) -> void:
	_hits = []
	var host := is_host()
	var card := Rect2(Vector2(size.x * 0.05, size.y * 0.09), Vector2(size.x * 0.9, size.y * 0.86))
	draw_rect(card, CARD)
	draw_rect(card, Color(1, 1, 1, 0.12), false, px * 0.5)
	var lh := 11.0 * px
	var m := 8.0 * px
	var x0 := card.position.x + m
	var y := card.position.y + m
	var top := top_line()
	_text(top, Vector2(x0, y), px, INK if host else AMBER)
	var mid_from := x0 + _w(top, px)
	if volume != null:
		# MU1: every player's own sound page, live whoever the host is.
		var tab_r := _button("YOUR SOUND", Vector2(mid_from + 10 * px, y), px, AMBER if _sound else INK)
		_hits.append([tab_r, "sound_tab", 0])
		mid_from = tab_r.end.x
	var sv := saved_line()
	var sv_x := card.end.x - m - _w(sv, px)
	_text(sv, Vector2(sv_x, y), px, GREY)
	var mid := "%d CHANGED TONIGHT" % changed_count()
	var mid_x := card.position.x + (card.size.x - _w(mid, px)) * 0.5
	if mid_x > mid_from + 6 * px and mid_x + _w(mid, px) < sv_x - 6 * px:
		_text(mid, Vector2(mid_x, y), px, AMBER if changed_count() > 0 else GREY)
	y += lh + 2 * px
	draw_rect(Rect2(Vector2(card.position.x, y), Vector2(card.size.x, px * 0.5)), Color(1, 1, 1, 0.18))
	y += 6 * px
	# Left: the groups and their sections.
	var left_w := 24.0 * 6.0 * px
	var ly := y
	var last_group: StringName = &"-"
	for i in _sections.size():
		var sec: Dictionary = _sections[i]
		var title := _printable(str(sec["title"]), true)
		var indent := 0.0
		if i > 0:
			indent = 2 * 6 * px
			if sec["group"] != last_group:
				last_group = sec["group"]
				# A group of one section with its own name needs no header.
				var alone: bool = str(sec["group_title"]) == title and (i + 1 >= _sections.size() or _sections[i + 1]["group"] != sec["group"])
				if alone:
					indent = 0.0
				else:
					ly += 3 * px
					_text(str(sec["group_title"]), Vector2(x0, ly), px, DIM)
					ly += lh
		if title.length() > 21:
			title = title.left(21)
		var col := INK if i == _sel and not _sound else GREY
		if i == _sel and not _sound:
			draw_rect(Rect2(Vector2(x0 - 3 * px, ly - 2 * px), Vector2(left_w - 2 * px, lh)), Color(1, 1, 1, 0.07))
		_text(title, Vector2(x0 + indent, ly), px, col)
		var n := _changed_in(i)
		if n > 0:
			_text(str(n), Vector2(x0 + left_w - 2 * 6 * px, ly), px, AMBER)
		_hits.append([Rect2(Vector2(x0, ly - 2 * px), Vector2(left_w, lh)), "section", i])
		ly += lh
	draw_rect(Rect2(Vector2(x0 + left_w + 2 * px, y - 2 * px), Vector2(px * 0.5, card.end.y - y - 18 * px)), Color(1, 1, 1, 0.15))
	# Right: the chosen section's rows.
	var rx := x0 + left_w + 10 * px
	var rw := card.end.x - m - rx
	var ry := y
	var rows: Array = [] if _sound else _section_rows(_sel)
	_text("YOUR SOUND: ON THIS COMPUTER ONLY" if _sound else _printable(str(_sections[_sel]["title"])), Vector2(rx, ry), px, INK)
	ry += lh + 5 * px
	if _sound:
		_draw_sound(Vector2(rx, ry), rw, px, lh, card.end.x - m)
	elif rows.is_empty():
		_text("NOTHING IS CHANGED TONIGHT" if _sel == 0 else "NOTHING HERE YET", Vector2(rx, ry), px, GREY)
	for r in rows.size():
		var s: Settings.Setting = rows[r]
		if ry > card.end.y - 3.5 * lh - 16 * px:
			_text("...", Vector2(rx, ry), px, GREY)
			break
		var on := r == _row
		var row_h := lh * 3.0 + 2 * px
		if on:
			draw_rect(Rect2(Vector2(rx - 4 * px, ry - 3 * px), Vector2(rw + 8 * px, row_h)), Color(1, 1, 1, 0.06))
		_hits.append([Rect2(Vector2(rx, ry - 3 * px), Vector2(rw, row_h)), "row", s.id, r])
		var w := row_words(s)
		var changed := not str(w[1]).is_empty()
		# Line 1: the name, and when it holds.
		var name := s.name if _sel != 0 else TuningDesk.label(s.id)
		_text(name, Vector2(rx, ry), px, INK if on else Color(0.85, 0.86, 0.82))
		_text(str(w[2]), Vector2(card.end.x - m - _w(str(w[2]), px), ry), px, GREY)
		# Line 2: the changed mark, the value, what it was; - slider +; RESET.
		var vy := ry + lh
		if changed:
			draw_rect(Rect2(Vector2(rx, vy + 2 * px), Vector2(3 * px, 3 * px)), AMBER)
		var value := str(w[0]).substr(2)
		_text(value, Vector2(rx + 6 * px, vy), px, AMBER if changed else INK)
		if changed:
			_text(str(w[1]), Vector2(rx + 6 * px + 11 * 6 * px, vy), px, GREY)
		var reset_w := _w("RESET", px) + 4 * px
		var reset_at := Vector2(card.end.x - m - reset_w + 2 * px, vy)
		var reset_r := _button("RESET", reset_at, px, (INK if changed else DIM) if host else DIM)
		_hits.append([reset_r, "reset", s.id, r])
		var plus_at := Vector2(reset_at.x - 14 * px, vy)
		var slider_end := plus_at.x - 6 * px
		var slider_start := rx + 6 * px + 21 * 6 * px
		var minus_at := Vector2(slider_start, vy)
		var minus_r := _button("-", minus_at, px, INK if can_step(s.id, -1) else DIM)
		_hits.append([minus_r, "minus", s.id, r])
		var plus_r := _button("+", plus_at, px, INK if can_step(s.id, 1) else DIM)
		_hits.append([plus_r, "plus", s.id, r])
		var track := Rect2(Vector2(minus_r.end.x + 5 * px, vy + 3 * px), Vector2(maxf(10 * px, slider_end - minus_r.end.x - 10 * px), px))
		draw_rect(track, GREY if host else DIM)
		var f_today := (s.today - s.lo) / (s.hi - s.lo)
		draw_rect(Rect2(Vector2(track.position.x + track.size.x * f_today - px * 0.5, vy), Vector2(px, 7 * px)), GREY if host else DIM)
		var v := value_of(s.id)
		var fv := (v - s.lo) / (s.hi - s.lo)
		draw_rect(Rect2(Vector2(track.position.x + track.size.x * fv - 2 * px, vy), Vector2(4 * px, 7 * px)), (AMBER if changed else INK) if host else GREY)
		_hits.append([Rect2(Vector2(track.position.x, vy - 2 * px), Vector2(track.size.x, 11 * px)), "slider", s.id, r])
		# Line 3: a refusal, a waiting value, or the hint.
		var third := ""
		var third_col := GREY
		if now < _flash_until and on:
			third = _flash
			third_col = RED
		elif not str(w[3]).is_empty():
			third = str(w[3])
			third_col = AMBER
		elif on:
			third = hint(s)
		if not third.is_empty():
			_text(third, Vector2(rx + 6 * px, vy + lh), px, third_col)
		ry += row_h + 4 * px
	# The foot.
	var foot := foot_line()
	draw_rect(Rect2(Vector2(card.position.x, card.end.y - 16 * px), Vector2(card.size.x, px * 0.5)), Color(1, 1, 1, 0.18))
	_text(foot, Vector2(x0, card.end.y - 11 * px), px, GREY)
	if _back_down_at >= 0.0:
		var fill := clampf((now - _back_down_at) / HOLD_RESET_ALL, 0.0, 1.0)
		draw_rect(Rect2(Vector2(x0, card.end.y - 3 * px), Vector2(_w(foot, px) * fill, px)), AMBER)