# Continuance's orientation tape (docs/floors/story.md section 2, ST1): the induction video a convict
# sees on joining, before the controls card. Flat yellow pictograms on one blue field, drawn in code
# (client/tape_symbols.gd) at 480x270 and shown through a VCR filter turned up (client/tape_vcr.gdshader):
# a tracking band, head-switch noise, the yellow smearing right, a jump on every cut. Over it, crisp:
# PLAY and the tape counter top left, CONTINUANCE INDUCTION 1 top right, the narration's subtitles in the
# announcer's black strip, and HOLD SPACE TO SKIP with a ring that fills.
#
# The shots, captions, subtitles and timing are data (data/tapes.json "orientation"). One recording per
# beat (assets_src/voice/lines.json group tape, Bella); a beat's shots share it, each cut placed on the
# pause before its sentence (godot/tools/tape_cues.mjs). Without the cues it plays to the design's seconds.
#
# Use: add it full screen, call start(), wait for `finished`. Holding Space, Enter or the mouse button
# for 0.6 s skips; a tap does nothing. Played alone: res://client/tape_demo.tscn, or `-- scene=tape`.
extends Control

signal finished(skipped: bool)

const S = preload("res://client/tape_symbols.gd")
const DATA := "res://data/tapes.json"
const W := 480.0
const H := 270.0
## How long Space, Enter or the mouse button must be held to skip.
const SKIP_HOLD := 0.6
## Each beat's recording starts this long after its first shot, and its last shot holds this long after it.
const LEAD := 0.25
const TAIL := 0.35
## A tape frame: shot 16's flickers last two of them.
const FRAME := 1.0 / 30.0
## Shot 16 ("LATE"): when, after its second move (the tape tears), the body shows as a diamond, for two frames each.
const FLICKERS: Array[float] = [0.08, 1.0]
## When the clunk falls in the last shot.
const CLUNK_AT := 0.3
## Every picture draw_picture() knows (tapes.json "picture").
const PICTURES: Array[String] = ["mark_rise", "city_up", "drop_below", "floors_unroll", "you_alone", "crew_faces", "car_down",
	"residents", "record", "waves_to_credits", "credits_up", "classified", "quota", "car_noticed", "doors_close", "late", "choose",
	"remission", "long_bar", "mark_end", "rewind"]

var shots: Array = []
var beats: Dictionary = {}
var title := ""
## Per shot: its start and length on the tape (seconds).
var starts: Array[float] = []
var lengths: Array[float] = []
## Per beat: when its recording starts on the tape.
var audio_at: Dictionary = {}
var total := 0.0
## Whether the timeline came from the measured recordings (else the design's target seconds).
var measured := false

var time := 0.0
var playing := false
var done := false
var hold := 0.0
## Tests: the skip input held (true / false), or null for the keyboard and mouse.
var t_hold: Variant = null
var finished_count := 0

var _sub: SubViewport
var _picture: Control
var _screen: TextureRect
var _overlay: Control
var _mat: ShaderMaterial
var _voice: AudioStreamPlayer
var _hiss: AudioStreamPlayer
var _clunk: AudioStreamPlayer
var _audio_key := ""
var _clunked := false

func _init() -> void:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if d is Dictionary and (d as Dictionary).has("orientation"):
		var o: Dictionary = (d as Dictionary)["orientation"]
		shots = o["shots"]
		beats = o["beats"]
		title = str(o["title"])
	build_timeline()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

## Lays the shots out on the tape: a beat's first shot starts LEAD before its recording, each other shot
## at its cue in the recording, and the beat ends TAIL after it. A shot with no beat runs its target.
func build_timeline() -> void:
	starts.clear()
	lengths.clear()
	audio_at.clear()
	measured = true
	var t := 0.0
	var i := 0
	while i < shots.size():
		var b: String = str((shots[i] as Dictionary)["beat"])
		var j := i
		while j < shots.size() and str((shots[j] as Dictionary)["beat"]) == b:
			j += 1
		var n := j - i
		var beat: Dictionary = beats.get(b, {})
		var cues: Array = beat.get("cues", [])
		var dur := float(beat.get("duration", 0.0))
		if b != "" and cues.size() == n and dur > 0.0:
			audio_at[b] = t + LEAD
			for k in n:
				var s0 := 0.0 if k == 0 else LEAD + float(cues[k])
				var s1 := LEAD + dur + TAIL if k == n - 1 else LEAD + float(cues[k + 1])
				starts.append(t + s0)
				lengths.append(s1 - s0)
			t += LEAD + dur + TAIL
		else:
			if b != "":
				measured = false
				audio_at[b] = t + LEAD
			for k in n:
				starts.append(t)
				var target := float((shots[i + k] as Dictionary)["target"])
				lengths.append(target)
				t += target
		i = j
	total = t

## The shot at `at` seconds into the tape (the current time by default).
func shot_index(at := -1.0) -> int:
	var tt := time if at < 0.0 else at
	for i in range(starts.size() - 1, -1, -1):
		if tt >= starts[i]:
			return i
	return 0

func shot_time(at := -1.0) -> float:
	var tt := time if at < 0.0 else at
	return tt - starts[shot_index(tt)]

## When a shot's second move starts (seconds into the shot), or its length if it has none.
func then_time(i: int) -> float:
	var th: Variant = (shots[i] as Dictionary).get("then")
	return lengths[i] * float(th) if th != null else lengths[i]

## The times a picture changes inside a shot: its start, its second move.
func picture_spans(i: int) -> Array[float]:
	var out: Array[float] = []
	var th := then_time(i)
	if th < lengths[i]:
		out.append(th)
		out.append(lengths[i] - th)
	else:
		out.append(lengths[i])
	return out

## Shot 16: whether the lone figure's body is a diamond at `at` (two tape frames, twice).
func body_is_diamond(at := -1.0) -> bool:
	var tt := time if at < 0.0 else at
	var i := shot_index(tt)
	if str((shots[i] as Dictionary)["picture"]) != "late":
		return false
	var t := tt - starts[i]
	var th := then_time(i)
	for f in FLICKERS:
		if t >= th + f and t < th + f + 2.0 * FRAME:
			return true
	return false

## The subtitle on screen at `at`.
func subtitle_at(at := -1.0) -> String:
	var tt := time if at < 0.0 else at
	var i := shot_index(tt)
	var shot: Dictionary = shots[i]
	if str(shot["beat"]) == "" and tt - starts[i] < CLUNK_AT:
		return ""
	return str(shot["subtitle"])

# --- playing ----------------------------------------------------------------------------------------

func start() -> void:
	time = 0.0
	hold = 0.0
	done = false
	playing = true
	_audio_key = ""
	_clunked = false
	if is_inside_tree() and _hiss != null:
		_hiss.play()
	_sync_audio()

## Ends the tape now, as if skipped.
func skip() -> void:
	_finish(true)

## Moves the tape on `dt` seconds (the game calls it every frame; tests call it directly).
func advance(dt: float) -> void:
	if not playing or done:
		return
	var held: bool = bool(t_hold) if t_hold != null else _input_held()
	if held:
		hold += dt
		if hold >= SKIP_HOLD:
			_finish(true)
			return
	else:
		hold = 0.0
	time += dt
	if time >= total:
		time = total
		_finish(false)
		return
	_sync_audio()

func _finish(skipped: bool) -> void:
	if done:
		return
	done = true
	playing = false
	finished_count += 1
	if _voice != null:
		_voice.stop()
	if _hiss != null:
		_hiss.stop()
	finished.emit(skipped)

func _input_held() -> bool:
	if not is_inside_tree() or not is_visible_in_tree():
		return false
	return Input.is_physical_key_pressed(KEY_SPACE) or Input.is_physical_key_pressed(KEY_ENTER) or Input.is_physical_key_pressed(KEY_KP_ENTER) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

## Starts each beat's recording when the tape reaches it (and at the right place after a jump).
func _sync_audio() -> void:
	if not is_inside_tree() or _voice == null:
		return
	for b: String in audio_at:
		var at: float = audio_at[b]
		var dur := float((beats[b] as Dictionary).get("duration", 0.0))
		if time >= at and time < at + maxf(dur, 0.1) and _audio_key != b:
			_audio_key = b
			var path := str((beats[b] as Dictionary)["audio"])
			if ResourceLoader.exists(path):
				_voice.stream = load(path)
				_voice.play(time - at)
	var i := shot_index()
	if not _clunked and str((shots[i] as Dictionary)["beat"]) == "" and time - starts[i] >= CLUNK_AT:
		_clunked = true
		_clunk.play()

# --- the screen -------------------------------------------------------------------------------------

func _ready() -> void:
	_sub = SubViewport.new()
	_sub.size = Vector2i(int(W), int(H))
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.disable_3d = true
	add_child(_sub)
	_picture = Picture.new()
	_picture.set("tape", self)
	_picture.size = Vector2(W, H)
	_sub.add_child(_picture)
	_screen = TextureRect.new()
	_screen.texture = _sub.get_texture()
	_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_screen.stretch_mode = TextureRect.STRETCH_SCALE
	_screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://client/tape_vcr.gdshader")
	_screen.material = _mat
	add_child(_screen)
	_overlay = Overlay.new()
	_overlay.set("tape", self)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_voice = AudioStreamPlayer.new()
	_voice.bus = "Voice"
	# As the announcer: in the browser the Voice bus's compressor does not apply, and at -1 lines clipped.
	_voice.volume_db = -5.0
	add_child(_voice)
	_hiss = AudioStreamPlayer.new()
	_hiss.bus = "Ambience"
	_hiss.stream = hiss_stream()
	_hiss.volume_db = -27.0
	add_child(_hiss)
	_clunk = AudioStreamPlayer.new()
	_clunk.bus = "Effects"
	_clunk.stream = clunk_stream()
	_clunk.volume_db = -4.0
	add_child(_clunk)
	if playing:
		_hiss.play()
		_sync_audio()

func _process(delta: float) -> void:
	if playing:
		advance(delta)
	var p := vcr_params()
	_mat.set_shader_parameter("band", p["band"])
	_mat.set_shader_parameter("jitter", p["jitter"])
	_mat.set_shader_parameter("tear", p["tear"])
	_mat.set_shader_parameter("clock", time)
	_picture.queue_redraw()
	_overlay.queue_redraw()

## The filter's moving parts at `at`: the tracking band, the jump on a cut, the tear.
func vcr_params(at := -1.0) -> Dictionary:
	var tt := time if at < 0.0 else at
	var i := shot_index(tt)
	var t := tt - starts[i]
	var L := lengths[i]
	var pic := str((shots[i] as Dictionary)["picture"])
	var band := -1.0
	var ph := fposmod(tt - 1.8, 5.0)
	if ph < 1.1:
		band = ph / 1.1
	if pic == "mark_rise":
		band = t / L * 1.3 - 0.15
	var jitter := 0.0
	if i > 0 and t < 0.1:
		jitter = 4.0 * (1.0 - t / 0.1) * (1.0 if int(t * 30.0) % 2 == 0 else -1.0)
	var tear := 0.0
	if pic == "late":
		var th := then_time(i)
		if t >= th and t < th + 0.3:
			tear = 0.8
		elif t >= th + FLICKERS[1] - 0.03 and t < th + FLICKERS[1] + 0.1:
			tear = 0.25
	if pic == "rewind" and t < 0.15:
		tear = 0.5
	return {"band": band, "jitter": jitter, "tear": tear}

## The tape's hiss: two seconds of soft noise, looped (made here, no sound file).
static func hiss_stream() -> AudioStreamWAV:
	var rate := 22050
	var n := rate * 2
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	var lp := 0.0
	var prev := 0.0
	for i in n:
		var w := rng.randf_range(-1.0, 1.0)
		lp += (w - lp) * 0.35
		var hp := lp - prev * 0.6
		prev = lp
		data.encode_s16(i * 2, int(clampf(hp * 0.5, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = rate
	s.stereo = false
	s.data = data
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = n
	return s

## The deck stopping: a low knock and a click.
static func clunk_stream() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.35)
	var data := PackedByteArray()
	data.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in n:
		var t := float(i) / rate
		var knock := sin(TAU * (95.0 - 40.0 * t) * t) * exp(-t * 18.0)
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 260.0) * 0.6
		var second := sin(TAU * 70.0 * t) * exp(-(t - 0.09) * 30.0) * (1.0 if t > 0.09 else 0.0) * 0.5
		data.encode_s16(i * 2, int(clampf(knock * 0.8 + click + second, -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = rate
	s.stereo = false
	s.data = data
	return s

# --- the picture (480x270, through the filter) ------------------------------------------------------

class Picture extends Control:
	var tape: Node = null
	func _draw() -> void:
		if tape != null:
			tape.call("draw_picture", self)

class Overlay extends Control:
	var tape: Node = null
	func _draw() -> void:
		if tape != null:
			tape.call("draw_overlay", self)

func _caption(ci: CanvasItem, text: String, y := 30.0, px := 3.0) -> void:
	if text == "":
		return
	S.text(ci, text, Vector2(roundf((W - S.text_width(text, px)) * 0.5), y), px)

func draw_picture(ci: CanvasItem) -> void:
	var i := shot_index()
	var shot: Dictionary = shots[i]
	var t := time - starts[i]
	var L := lengths[i]
	var th := then_time(i)
	var cap := str(shot["caption"])
	var Y := S.YELLOW
	var bg := S.BLUE
	if str(shot["picture"]) == "car_noticed":
		# The blue dims two steps.
		bg = S.BLUE.darkened(0.3 if t >= 0.1 else 0.0)
		if t >= 0.8:
			bg = S.BLUE.darkened(0.55)
	ci.draw_rect(Rect2(0, 0, W, H), bg)
	match str(shot["picture"]):
		"mark_rise":
			S.mark(ci, Vector2(240, lerpf(360.0, 165.0, S.ease_out(t / (L * 0.45)))), 2.0)
			if t >= L * 0.45:
				_caption(ci, cap)
		"city_up":
			S.ground(ci, 150, 20, lerpf(20.0, 460.0, S.ease_in_out(t / th)))
			if t > th:
				S.city(ci, Vector2(240, 150), 1.0, 6.0 * clampf((t - th) / ((L - th) * 0.75), 0.0, 1.0), 0.0)
			if t >= 0.12:
				_caption(ci, cap)
		"drop_below":
			var off := -118.0 * S.ease_in_out(t / (L * 0.45))
			S.city(ci, Vector2(240, 150 + off), 1.0, 6.0, 0.0)
			S.ground(ci, 150 + off, 20, 460)
			if t >= L * 0.5:
				_caption(ci, cap, 112, 5)
		"floors_unroll":
			S.ground(ci, 32, 20, 460)
			var base := "NOTHING"
			var x0 := roundf((W - S.text_width(base, 5)) * 0.5)
			S.text(ci, base, Vector2(x0, 112), 5)
			if t >= 0.08:
				var px := 5.0 + 4.0 * (1.0 - S.ease_out((t - 0.08) / 0.2))
				S.text(ci, "*", Vector2(x0 + S.text_width(base, 5) + 5.0, 112 - (px - 5.0) * 3.5), px)
			S.floors(ci, Vector2(400, 36), 56, 24, 5, 5.0 * S.ease_out(t / (L * 0.75)))
		"you_alone":
			S.ground(ci, 190, 30, 450)
			var blink := t > th and t < th + 0.7 and int((t - th) / 0.1) % 2 == 0
			S.you(ci, Vector2(220, 190), 2.2, -1, 1.0, not blink)
			if t >= th + 0.1:
				_gavel(ci, t - th - 0.1)
			if t >= 0.12:
				_caption(ci, cap)
		"crew_faces":
			S.ground(ci, 190, 30, 450)
			var seg := (L - th - 0.3) / 4.0
			for k in 4:
				if t >= k * 0.12:
					var fk := clampf((t - th - k * seg) / seg, 0.0, 1.0)
					S.you(ci, Vector2(120 + k * 80, 190), 1.6, k if fk > 0.0 else -2, fk)
			if t >= 0.12:
				_caption(ci, cap)
		"car_down":
			S.ground(ci, 110, 20, 460)
			S.city(ci, Vector2(140, 110), 0.7, 6.0, 0.0)
			S.rail(ci, 330, 30, 210)
			S.car(ci, Vector2(330, lerpf(52.0, 170.0, S.ease_in_out(t / (L * 0.85)))), 1.1, 1, 4)
			if t >= 0.12:
				_caption(ci, cap)
		"residents":
			S.ground(ci, 62, 20, 460)
			S.floors(ci, Vector2(240, 66), 150, 32, 4, 4.0 * S.ease_out(t / 0.5))
			if _blinked_on(t, th):
				S.resident(ci, Vector2(200, 118), 0.68)
			if _blinked_on(t, th + 0.45 * (L - th)):
				S.resident(ci, Vector2(290, 190), 0.68)
			if t >= 0.12:
				_caption(ci, cap)
		"record":
			S.ground(ci, 190, 30, 450)
			S.you(ci, Vector2(130, 190), 1.8)
			ci.draw_rect(Rect2(150, 142, 32, 5), Y)
			var needle := -0.6 + 0.08 * sin(t * 5.0)
			if t >= th:
				needle = sin(t * 13.0) * 0.8
				S.waves(ci, Vector2(370, 132), Vector2(196, 138), (t - th) * 0.9, (t - th) / 0.3)
			S.instrument(ci, Vector2(196, 138), 1.3, needle)
			S.resident(ci, Vector2(370, 132), 1.5)
			if t >= 0.12:
				_caption(ci, cap)
		"waves_to_credits":
			S.ground(ci, 190, 30, 450)
			for k in 3:
				var c := Vector2(150 + k * 90, 125)
				var m := L * (0.12 + k * 0.17)
				if t < m:
					ci.draw_arc(c - Vector2(36, 0), 36.0, -0.55, 0.55, 12, Y, 5.0, false)
				else:
					var f := clampf((t - m) / 0.12, 0.0, 1.0)
					if f < 1.0:
						ci.draw_arc(c - Vector2(36.0 * (1.0 - f), 0), 36.0 * (1.0 - f) + 1.0, -0.55, 0.55, 12, Y, 5.0, false)
					S.credit(ci, c, 17.0 * S.pop((t - m) / 0.25))
			if t >= 0.12:
				_caption(ci, cap)
		"credits_up":
			S.ground(ci, 100, 20, 460)
			ci.draw_rect(Rect2(198, 100, 4, 110), Y)
			ci.draw_rect(Rect2(278, 100, 4, 110), Y)
			var lit := 0
			for b in 6:
				if t >= 0.55 + int(b / 2.0) * 0.45 + (b % 2) * 0.15:
					lit += 1
			S.city(ci, Vector2(240, 100), 0.85, 6.0, lit)
			for j in 3:
				var arrive := 0.55 + j * 0.45
				var f := clampf((t - (arrive - 0.7)) / 0.7, 0.0, 1.0)
				if f > 0.0 and f < 1.0:
					S.credit(ci, Vector2(240, lerpf(220.0, 100.0, f)), 10.0)
		"classified":
			S.ground(ci, 190, 30, 450)
			for k in 5:
				S.hazard(ci, Vector2(80 + k * 80, 130), 1.3 * S.pop((t - k * 0.16) / 0.25), true)
			if t >= th:
				var x := lerpf(-450.0, 24.0, S.ease_out((t - th) / 0.35))
				ci.draw_rect(Rect2(x - 4, 113, 440, 34), bg)
				ci.draw_rect(Rect2(x, 117, 432, 26), Y)
			if t >= 0.12:
				_caption(ci, cap)
		"quota":
			S.ground(ci, 190, 30, 450)
			S.meter(ci, Rect2(50, 104, 230, 46), S.ease_in_out(t / (L * 0.55)))
			var press := clampf((t - L * 0.68) / 0.1, 0.0, 1.0)
			S.button(ci, Vector2(372, 127), 1.5, press)
			if press >= 1.0:
				for r in 2:
					var rr := 36.0 + fposmod((t - L * 0.68) * 70.0 + r * 18.0, 36.0)
					ci.draw_arc(Vector2(372, 127), rr, -0.6, 0.6, 10, Y, 3.0, false)
					ci.draw_arc(Vector2(372, 127), rr, PI - 0.6, PI + 0.6, 10, Y, 3.0, false)
			if t >= 0.12:
				_caption(ci, cap)
		"car_noticed":
			S.ground(ci, 58, 20, 460, Y)
			S.rail(ci, 140, 0, 210)
			S.car(ci, Vector2(140, lerpf(-40.0, 150.0, S.ease_in_out(t / (L * 0.6)))), 1.2, 1, 4, Y, bg)
			var f := clampf((t - L * 0.62) / (L * 0.16), 0.0, 1.0)
			var turn := cos(PI * f)
			S.resident(ci, Vector2(360, 150), 1.4, turn, f < 0.5, Y, bg)
			if f >= 1.0:
				var tip := Vector2(360 - 19.0 * 1.4 - 14.0, 150)
				ci.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(9, -7), tip + Vector2(9, 7)]), Y)
		"doors_close":
			S.ground(ci, 196, 30, 450)
			S.frame(ci, Rect2(130, 82, 220, 114), 4.0, Y)
			for k in 3:
				S.you(ci, Vector2(185 + k * 55, 192), 1.05)
			S.doors(ci, Rect2(134, 86, 212, 106), S.ease_in_out((t - 0.1 * L) / (0.7 * L)))
			if t >= 0.12:
				_caption(ci, cap)
		"late":
			S.ground(ci, 196, 30, 450)
			S.frame(ci, Rect2(40, 82, 180, 114), 4.0, Y)
			S.doors(ci, Rect2(44, 86, 172, 106), 1.0)
			S.you(ci, Vector2(300, 192), 1.3, -1, 1.0, true, body_is_diamond())
			S.clock(ci, Vector2(400, 118), 26.0, t * 2.4)
			if t >= 0.12:
				_caption(ci, cap)
		"choose":
			S.ground(ci, 204, 30, 450)
			S.frame(ci, Rect2(110, 62, 260, 142), 4.0, Y)
			ci.draw_rect(Rect2(238, 62, 4, 142), Y)
			S.bank(ci, Vector2(175, 112), 1.0)
			S.arrow(ci, Vector2(305, 108), 1.0, false)
			var from: Array[float] = [200.0, 226.0, 254.0, 280.0]
			var to: Array[float] = [140.0, 180.0, 300.0, 340.0]
			for k in 4:
				var f := S.ease_in_out((t - th - k * 0.15) / 0.6)
				var hop := -5.0 * absf(sin(f * PI * 3.0))
				S.you(ci, Vector2(lerpf(from[k], to[k], f), 198 + hop), 0.75)
			if t >= 0.12:
				_caption(ci, cap)
		"remission":
			S.ground(ci, 196, 30, 450)
			S.bunk(ci, Vector2(80, 150), 1.3)
			S.frame(ci, Rect2(150, 118, 420, 32), 4.0, Y)
			S.tally(ci, Vector2(162, 124), int(9.0 * clampf(t / (L * 0.85), 0.0, 1.0)), 20.0)
			if t >= 0.12:
				_caption(ci, cap)
		"long_bar":
			S.ground(ci, 196, 30, 450)
			var off := 60.0 * t + 45.0 * t * t
			S.bunk(ci, Vector2(80 - off, 150), 1.3)
			S.frame(ci, Rect2(150 - off, 118, 3000, 32), 4.0, Y)
			ci.draw_rect(Rect2(0, 122, W, 24), bg)
			S.tally(ci, Vector2(162 - off, 124), 9, 20.0)
			var j0 := int(floor(off / 48.0))
			for j in range(j0, j0 + 12):
				var x := 150.0 - off + j * 48.0
				if x > -4.0 and x < W:
					ci.draw_rect(Rect2(x, 104, 3, 10), Y)
		"mark_end":
			S.mark(ci, Vector2(240, 158), 1.8 * S.pop(t / 0.3))
			var half := 150.0 * S.ease_out((t - 0.2) / 0.5)
			S.ground(ci, 184, 240 - half, 240 + half)
			if t >= L * 0.45:
				_caption(ci, cap)
		"rewind":
			S.ground(ci, 160, 140, 340)
			if t >= CLUNK_AT + 0.1:
				_caption(ci, cap, 110, 4)

func _blinked_on(t: float, at: float) -> bool:
	if t < at:
		return false
	return t - at > 0.3 or int((t - at) / 0.075) % 2 == 0

## Shot 5: a gavel-shaped bar taps once on a block beside the figure.
func _gavel(ci: CanvasItem, t: float) -> void:
	var Y := S.YELLOW
	ci.draw_rect(Rect2(296, 180, 44, 10), Y)
	var a := -0.9
	if t < 0.35:
		a = lerpf(-0.9, 0.0, S.ease_in_out(t / 0.35))
	elif t < 0.6:
		a = lerpf(0.0, -0.35, S.ease_out((t - 0.35) / 0.25))
	else:
		a = -0.35
	var pivot := Vector2(392, 168)
	ci.draw_set_transform(pivot, a, Vector2.ONE)
	ci.draw_rect(Rect2(-58, -3, 58, 6), Y)
	ci.draw_rect(Rect2(-74, -14, 18, 26), Y)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if t >= 0.35 and t < 0.6:
		for k in 3:
			var x := 304.0 + k * 14.0
			ci.draw_rect(Rect2(x, 160 - k % 2 * 4, 3, 10), Y)

# --- crisp over the picture: the deck's display, subtitles, skip ------------------------------------

func draw_overlay(ci: CanvasItem) -> void:
	var sz: Vector2 = (ci as Control).size
	var px := maxf(2.0, roundf(sz.y / 330.0))
	var white := Color("#f4f4ec")
	var margin := Vector2(maxf(sz.x * 0.04, 12.0), maxf(sz.y * 0.05, 10.0))
	var i := shot_index()
	var stopped := str((shots[i] as Dictionary)["beat"]) == "" and time - starts[i] >= CLUNK_AT
	var top := "STOP" if stopped or done else ("PLAY >" if int(time * 2.0) % 2 == 0 else "PLAY")
	PixelFont.draw_shadowed(ci, top, margin, px, white)
	var s := int(minf(time, starts[i] + CLUNK_AT if stopped else time))
	PixelFont.draw_shadowed(ci, "SP %d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60], margin + Vector2(0, 10 * px), px, white)
	PixelFont.draw_shadowed(ci, title, Vector2(sz.x - margin.x - PixelFont.width(title) * px, margin.y), px, white)
	var sub := subtitle_at()
	if sub != "":
		_draw_subtitle(ci, sz, sub)
	# HOLD SPACE TO SKIP, with a ring that fills while it is held.
	var label := "HOLD SPACE TO SKIP"
	var sp := px
	var lw := PixelFont.width(label) * sp
	var ly := sz.y - margin.y * 0.6 - 7.0 * sp
	var lx := sz.x - margin.x - lw
	PixelFont.draw_shadowed(ci, label, Vector2(lx, ly), sp, white)
	var rc := Vector2(lx - 6.0 * sp, ly + 3.5 * sp)
	var rr := 4.0 * sp
	ci.draw_arc(rc, rr, 0.0, TAU, 24, Color(white, 0.5), 2.0, true)
	var k := clampf(hold / SKIP_HOLD, 0.0, 1.0)
	if k > 0.0:
		ci.draw_arc(rc, rr * 0.5, -PI * 0.5, -PI * 0.5 + TAU * k, 24, Color("#ffd27a"), rr, false)

## The subtitle strip, drawn as the announcer's are (client/hud.gd _draw_subtitle).
func _draw_subtitle(ci: CanvasItem, sz: Vector2, text: String) -> void:
	var up := text.to_upper().replace("’", "'").replace("‘", "'").replace("…", "...")
	var clean := ""
	for ch: String in up:
		if ch == " " or PixelFont.known(ch):
			clean += ch
	var rows := PixelFont.wrap(clean, 38)
	var w := 10
	for r in rows:
		w = maxi(w, PixelFont.width(r))
	w += 6
	var h := rows.size() * 10 + 4
	var sc := clampf(floor(sz.x * 0.92 / w), 1.0, 4.0)
	var origin := Vector2((sz.x - w * sc) * 0.5, sz.y * 0.91 - h * sc)
	ci.draw_rect(Rect2(origin, Vector2(w, h) * sc), Color(0, 0, 0, 0.45))
	for i in rows.size():
		var r: String = rows[i]
		var x := floorf((w - PixelFont.width(r)) / 2.0)
		var p := origin + Vector2(x, 2 + i * 10) * sc
		PixelFont.draw(ci, r, p + Vector2(sc, sc), sc, Color(0, 0, 0, 0.7))
		PixelFont.draw(ci, r, p, sc, Color("#f4f4ec"))
