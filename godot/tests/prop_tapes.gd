# The orientation tape (client/orientation_tape.gd, data/tapes.json; docs/floors/story.md section 2,
# ST1 and ST2). Checked here, without drawing anything:
#   - 21 shots, in order; every shot has a subtitle, at least one pictogram, and only pictograms from
#     the list (client/tape_symbols.gd NAMES: a resident is only ever the diamond); every picture is one
#     the player draws, and no two neighbouring shots draw the same picture; no caption or subtitle
#     names a resident, a place, or a word the tape must not give away;
#   - the timing: the tape is laid out from the measured recordings (not the fallback seconds); every
#     shot runs 1.5 to 5 s and no picture holds longer than 4 s (a shot over 4 s changes its picture
#     part-way, the design's "then"); the shots tile the tape; the whole is 60 to 75 s; every beat's
#     recording is 0.7 to 1.4 times its shots' target seconds and sits inside its shots;
#   - each beat's subtitles, joined, are word for word the recording's text in the voice manifest, the
#     recording exists, and the manifest gives it Bella only;
#   - skipping: a tap (held under 0.6 s) never skips; a 0.6 s hold skips on any shot; `finished` fires
#     once, skipped, and never again;
#   - played to the end: `finished` fires once, not skipped, at the tape's length, never again; each
#     shot's subtitle is on screen during it;
#   - shot 16: the lone figure's body is a diamond for exactly two tape frames, twice, and never
#     anywhere else on the tape.
extends RefCounted

const Move = preload("res://sim/move.gd")
const Protocol = preload("res://net/protocol.gd")
const T = preload("res://tests/t.gd")
const OrientationTape = preload("res://client/orientation_tape.gd")
const TapeSymbols = preload("res://client/tape_symbols.gd")

## Words the tape must not say: the residents, the places, the rules (docs/floors/story.md: "What it
## does not [give away]: any body, any place, any rule, the blackout by name, ... hiding").
const BANNED: Array[String] = ["orderly", "temp", "minder", "trolley", "stapler", "mask", "gown", "clinic", "annex",
	"playroom", "blackout", "hide", "hiding", "stillness", "lonely", "dark", "soke", "crew 7"]

func _tape() -> OrientationTape:
	return OrientationTape.new()

func test_every_shot_has_a_subtitle_and_a_symbol(t: T) -> void:
	var tape := _tape()
	t.eq(tape.shots.size(), 21, "shots on the orientation tape")
	var prev := ""
	for i in tape.shots.size():
		var s: Dictionary = tape.shots[i]
		var n := int(s["n"])
		t.eq(n, i + 1, "shot numbers in order")
		t.check(str(s["subtitle"]).strip_edges() != "", "shot %d has no subtitle" % n)
		var syms: Array = s["symbols"]
		t.check(not syms.is_empty(), "shot %d has no pictogram" % n)
		for sym: Variant in syms:
			t.check(TapeSymbols.NAMES.has(str(sym)), "shot %d uses %s, which is not a tape pictogram" % [n, str(sym)])
		var pic := str(s["picture"])
		t.check(OrientationTape.PICTURES.has(pic), "shot %d draws %s, which the tape does not know" % [n, pic])
		t.check(pic != prev, "shots %d and %d draw the same picture %s" % [n - 1, n, pic])
		prev = pic
		for text: String in [str(s["caption"]).to_lower(), str(s["subtitle"]).to_lower()]:
			for w in BANNED:
				var rx := RegEx.create_from_string("\\b%s\\b" % w)
				t.check(rx.search(text) == null, "shot %d says '%s': %s" % [n, w, text])
	tape.free()

func test_timing(t: T) -> void:
	var tape := _tape()
	t.check(tape.measured, "the tape is laid out from the recordings' cues (godot/tools/tape_cues.mjs), not the design's fallback seconds")
	var lo := 999.0
	var hi := 0.0
	for i in tape.shots.size():
		var n := i + 1
		var L := tape.lengths[i]
		lo = minf(lo, L)
		hi = maxf(hi, L)
		t.check(L >= 1.5 and L <= 5.0, "shot %d runs %.2f s (1.5 to 5 s)" % [n, L])
		for span in tape.picture_spans(i):
			t.check(span <= 4.0, "shot %d holds one picture %.2f s (at most 4 s)" % [n, span])
		if i + 1 < tape.shots.size():
			t.check(absf(tape.starts[i] + L - tape.starts[i + 1]) < 1e-6, "shot %d ends where shot %d starts" % [n, n + 1])
	t.eq(tape.starts[0], 0.0, "the first shot starts the tape")
	t.check(absf(tape.starts[-1] + tape.lengths[-1] - tape.total) < 1e-6, "the last shot ends the tape")
	t.check(tape.total >= 60.0 and tape.total <= 75.0, "the tape runs %.2f s (60 to 75)" % tape.total)
	for b: String in tape.beats:
		var target := 0.0
		var first := -1
		var last := -1
		for i in tape.shots.size():
			if str((tape.shots[i] as Dictionary)["beat"]) == b:
				target += float((tape.shots[i] as Dictionary)["target"])
				last = i
				if first < 0:
					first = i
		var dur := float((tape.beats[b] as Dictionary)["duration"])
		t.check(first >= 0, "beat %s has shots" % b)
		t.check(dur >= 0.7 * target and dur <= 1.4 * target, "beat %s's recording is %.2f s against %.1f s of shots (0.7 to 1.4 times)" % [b, dur, target])
		var at: float = tape.audio_at[b]
		t.check(at >= tape.starts[first] and at + dur <= tape.starts[last] + tape.lengths[last] + 1e-6, "beat %s's recording plays inside its shots" % b)
	t.note("21 shots, %.2f s; shots %.2f to %.2f s" % [tape.total, lo, hi])
	tape.free()

func test_subtitles_are_the_recordings(t: T) -> void:
	var tape := _tape()
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	t.check(m is Dictionary, "the voice manifest loads")
	if not (m is Dictionary):
		tape.free()
		return
	var plain := {}
	var voices := {}
	for l: Dictionary in (m as Dictionary)["lines"]:
		plain[str(l["id"])] = str(l["plain"])
		voices[str(l["id"])] = l.get("voices", [])
	for b: String in tape.beats:
		var beat: Dictionary = tape.beats[b]
		var id := str(beat["line"])
		var parts: Array[String] = []
		for s: Dictionary in tape.shots:
			if str(s["beat"]) == b:
				parts.append(str(s["subtitle"]))
		t.eq(" ".join(parts), str(plain.get(id, "(no such line in the manifest)")), "beat %s's subtitles against %s" % [b, id])
		t.eq(str(voices.get(id, [])), str(["bella"]), "%s is read by Bella only" % id)
		t.check(ResourceLoader.exists(str(beat["audio"])), "%s exists" % str(beat["audio"]))
	tape.free()

func test_skip(t: T) -> void:
	var dt := 1.0 / 60.0
	# A tap, and a long press let go just short of the hold, never skip.
	var tape := _tape()
	var got: Array = []
	tape.finished.connect(func(skipped: bool) -> void: got.append(skipped))
	tape.start()
	for hold_s: float in [0.1, 0.3, 0.55]:
		tape.t_hold = true
		for f in int(hold_s / dt):
			tape.advance(dt)
		tape.t_hold = false
		tape.advance(dt)
	t.check(not tape.done and got.is_empty(), "a hold under 0.6 s skipped the tape")
	# Held 0.6 s: skipped, once.
	tape.t_hold = true
	for f in int(OrientationTape.SKIP_HOLD / dt) + 2:
		tape.advance(dt)
	t.check(tape.done, "a 0.6 s hold did not skip")
	tape.skip()
	tape.t_hold = false
	for f in 120:
		tape.advance(dt)
	t.eq(str(got), str([true]), "finished after a skip (fired once, skipped)")
	tape.free()
	# On every shot.
	for i in 21:
		var tp := _tape()
		var g: Array = []
		tp.finished.connect(func(skipped: bool) -> void: g.append(skipped))
		tp.start()
		tp.advance(tp.starts[i] + 0.05)
		tp.t_hold = true
		var held := 0.0
		while not tp.done and held < 2.0:
			tp.advance(dt)
			held += dt
		t.check(tp.shot_index() == i, "the skip on shot %d happened on shot %d" % [i + 1, tp.shot_index() + 1])
		t.check(held >= OrientationTape.SKIP_HOLD - 1e-4 and held <= OrientationTape.SKIP_HOLD + 2.0 * dt, "on shot %d the skip took %.2f s of holding" % [i + 1, held])
		t.eq(str(g), str([true]), "finished on shot %d" % (i + 1))
		tp.free()

func test_finishes_once(t: T) -> void:
	var tape := _tape()
	var got: Array = []
	tape.finished.connect(func(skipped: bool) -> void: got.append(skipped))
	tape.start()
	var dt := 1.0 / 30.0
	var seen := {}
	while not tape.done and tape.time < 200.0:
		tape.advance(dt)
		if not tape.done:
			var i := tape.shot_index()
			if tape.subtitle_at() == str((tape.shots[i] as Dictionary)["subtitle"]):
				seen[i] = true
	t.eq(str(got), str([false]), "finished at the end (fired once, not skipped)")
	t.check(absf(tape.time - tape.total) < 1e-6, "finished at %.2f s, the tape is %.2f s" % [tape.time, tape.total])
	t.eq(seen.size(), 21, "shots whose subtitle was on screen during them")
	for f in 60:
		tape.advance(dt)
	tape.skip()
	t.eq(got.size(), 1, "finished fired again after the end")
	tape.free()

func test_shot_16_flickers(t: T) -> void:
	var tape := _tape()
	var late := -1
	for i in tape.shots.size():
		if str((tape.shots[i] as Dictionary)["picture"]) == "late":
			late = i
	t.eq(late, 15, "the LATE picture is shot 16")
	var runs: Array[int] = []
	var run := 0
	var frames := int(ceil(tape.total * 30.0))
	for f in frames:
		var at := 0.0004 + f / 30.0
		var on := tape.body_is_diamond(at)
		if on:
			t.check(tape.shot_index(at) == late, "a diamond body at %.3f s, outside shot 16" % at)
			run += 1
		elif run > 0:
			runs.append(run)
			run = 0
	t.eq(str(runs), str([2, 2]), "tape frames the body is a diamond, run by run")
	tape.free()

func test_nightly_vote_timestamp_preserves_shop_input(t: T) -> void:
	var input := {"type": "input", "seq": 1, "ct": 0.0, "body": Move.Body.make(0, 0, 0, 0), "eye": 1.65, "yaw": 0.0,
		"pitch": 0.0, "hFovDeg": 90.0, "vFovDeg": 70.0, "raised": false, "holdDoors": false,
		"gait": "walk", "seeing": false, "calls": 0, "pickUps": 0, "ackEvent": 0, "ackHt": 0.0,
		"renderTime": 0.0, "placeAck": 0, "seen": [], "invSel": 2, "invs": 1, "invOp": "buy", "invArg": 3}
	var plain: Array = JSON.parse_string(Protocol.encode(input))
	t.eq(plain.size(), 27, "no skip vote leaves the shop wire form unchanged")
	input["skipReelAt"] = 15.125
	var wire: Array = JSON.parse_string(Protocol.encode(input))
	t.eq(wire.slice(0, 27), plain, "skip vote is after all inventory fields")
	var decoded: Variant = Protocol.decode(Protocol.encode(input))
	if t.check(decoded is Dictionary, "shop and vote together decode"):
		t.eq(decoded.get("skipReelAt"), 15.125, "timestamp survives")
		t.eq([decoded["invOp"], decoded["invArg"]], ["buy", 3], "same shop operation and argument")
	wire[27] = "15.125"
	t.eq(Protocol.decode(JSON.stringify(wire)), null, "a timestamp must be numeric")

func test_remission_notice_follows_the_first_positive_personal_bank_share(t: T) -> void:
	var game := preload("res://client/main.gd").new()
	t.check(not game._remission_for(null, "p1"), "no day loop has no notice")
	t.check(not game._remission_for({"index": 1, "result": null}, "p1"), "no notice before a report")
	t.check(not game._remission_for({"index": 1, "result": {"wiped": true, "shares": {"p1": 4}}}, "p1"), "no notice after a wipe")
	var report := {"index": 2, "result": {"shares": {"p1": 0, "p2": 19}}}
	t.check(not game._remission_for(report, "p1"), "another crew member's pay cannot unlock it")
	report["result"]["shares"]["p1"] = 13
	t.check(game._remission_for(report, "p1"), "the first positive share shows the authored notice")
	t.check(game._remission_for(report, "p1"), "the first paid report stays readable")
	report["index"] = 3
	t.check(not game._remission_for(report, "p1"), "later paid reports do not repeat the notice")
	game.free()
