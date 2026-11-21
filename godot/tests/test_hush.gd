# VC2, the intercom hushes a noisy crew (the owner, 20 Nov: "if people are talking a lot when the intercom goes off,
# the intercom responds to that with a throat clearing and asking them to be quiet and then continues saying what I
# was saying before"; "I agree to intercom hushing."). net/host.gd HUSH_EVERY decides, client/announcer.gd hush()
# acts. Proved here:
#   1. The host: two players talking (level 5+ held 200 ms) send "crewNoisy"; one alone does not; one shouting (11+)
#      does; a 150 ms burst does not; at most once a second; never with the voice off.
#   2. The announcer: a ride line 1 s in stops on "crewNoisy", the hush caption shows in silence for 1.8 s, then the
#      same line starts again from its beginning; it is not hushed twice, nor another line within a minute; after a
#      minute the next line is; a danger line, a hint and a line under 0.5 s old are never hushed.
#   3. Two screens fed the same events hush the same line at the same time.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Transport = preload("res://net/transport.gd")
const AnnouncerScript = preload("res://client/announcer.gd")

static func _input(seq: int, body: Move.Body, lv: int) -> Dictionary:
	var m := {"type": "input", "seq": seq, "ct": 1.0, "body": body, "eye": 1.65, "yaw": 0.0, "pitch": 0.0, "hFovDeg": 90.0, "vFovDeg": 70.0,
		"raised": false, "holdDoors": false, "gait": "walk", "seeing": false, "calls": 0, "pickUps": 0, "ackEvent": 0, "ackHt": -1.0, "renderTime": 0.0, "placeAck": 0, "seen": []}
	if lv > 0:
		m["voice"] = lv
	return m

## A host of three with the voice on or off; `levels` per player id for `secs`. Returns the crewNoisy events' times.
static func _host_run(on: bool, levels: Dictionary, secs: float) -> Array[float]:
	var net := Transport.MemoryNetwork.new("vc2-host")
	var ids: Array[String] = ["p0", "p1", "p2"]
	var host := Host.new(net.connect_peer("host"), "vc2-host", ids, 0.0)
	if on:
		host.state = Run.with_voice(host.state)
	for id in ids:
		host._join(id)
	var seq := 0
	var now := 0.0
	var out: Array[float] = []
	var seen := 0
	while now < secs:
		seq += 1
		for i in ids.size():
			var id := ids[i]
			host._on_message(id, Protocol.encode(_input(seq, host.state.players[i].body, int(levels.get(id, 0)))), now)
		now += 0.05
		host.update(now)
		while seen < host.event_log.size():
			var le: Host.LoggedEvent = host.event_log[seen]
			var e: Dictionary = le.e
			if str(e.get("type", "")) == "crewNoisy":
				out.append(float(e["t"]))
			seen += 1
	host.close()
	return out

func test_the_host_hears_a_noisy_crew(t: T) -> void:
	t.eq(_host_run(true, {}, 2.0).size(), 0, "a silent crew: never")
	t.eq(_host_run(true, {"p0": 8}, 2.0).size(), 0, "one talking: never")
	t.eq(_host_run(true, {"p0": 4, "p1": 4}, 2.0).size(), 0, "two whispering: never")
	var two := _host_run(true, {"p0": 8, "p1": 7}, 2.05)
	t.check(two.size() == 2 and two[0] >= 0.2 - 1e-6 and two[0] <= 0.35, "two talking: after 200 ms, then once a second (%s)" % str(two))
	t.check(two.size() == 2 and absf(two[1] - two[0] - 1.0) < 0.06, "the second a second later (%s)" % str(two))
	t.eq(_host_run(true, {"p0": 13}, 1.0).size(), 1, "one shouting: yes")
	t.eq(_host_run(false, {"p0": 8, "p1": 8, "p2": 15}, 2.0).size(), 0, "the voice off: never")

static func _ann(seed_text: String) -> Node:
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	var a: Node = AnnouncerScript.new()
	a.fake = true
	a.persist = false
	a.clock_ms = 0
	a.my_id = "ann"
	a.days_on = true
	a._rng.seed = hash(seed_text)
	a.use_manifest(m if m is Dictionary else {})
	a.start_run(true, "night-" + seed_text)
	a.queue.clear()
	a.clock_ms = 5000
	return a

static func _wait(a: Node, ms: int) -> void:
	var end: int = a.clock_ms + ms
	while a.clock_ms < end:
		a.clock_ms += 100
		a.update()

static func _starts(a: Node, moment: String) -> Array:
	return (a.history as Array).filter(func(h: Dictionary) -> bool: return h.moment == moment)

const NOISY := [{"type": "crewNoisy"}]

func test_the_announcer_hushes_and_says_it_again(t: T) -> void:
	var a := _ann("vc2-a")
	a.request("called")
	_wait(a, 200)
	t.check(not a.current.is_empty() and a.current.moment == "called", "the call line is playing")
	var id := str(a.current.id)
	a.on_events(NOISY)
	t.check(not a.current.is_empty(), "200 ms in: too early to hush")
	_wait(a, 800)
	a.on_events(NOISY)
	t.check(a.current.is_empty() and a.hushing(), "1 s in: the line stops and the hush begins")
	t.check(str(a.subtitle).begins_with("AHEM"), "the hush caption: %s" % a.subtitle)
	_wait(a, 1500)
	t.check(a.current.is_empty(), "1.5 s of silence: nothing speaks")
	_wait(a, 600)
	t.check(not a.current.is_empty() and str(a.current.id) == id, "then the same line again (%s)" % str(a.current.get("id", "")))
	t.eq(_starts(a, "called").size(), 2, "it started twice: from its beginning again")
	t.check(not str(a.subtitle).begins_with("AHEM"), "the hush caption has gone: %s" % a.subtitle)
	_wait(a, 800)
	a.on_events(NOISY)
	t.check(not a.current.is_empty() and str(a.current.id) == id, "talked over again: not hushed twice")
	t.eq(a.hushes, 1, "one hush")
	# Another line within a minute: not hushed.
	_wait(a, 6000)
	a.request("ride")
	_wait(a, 1200)
	a.on_events(NOISY)
	t.check(not a.current.is_empty() and a.current.moment == "ride", "a minute has not passed: the next line plays on")
	# After a minute: hushed again.
	_wait(a, 60000)
	a.request("quota")
	_wait(a, 1200)
	t.check(not a.current.is_empty() and a.current.moment == "quota", "a quota line")
	a.on_events(NOISY)
	t.check(a.current.is_empty() and a.hushes == 2, "a minute on: the next line is hushed")
	a.free()

func test_never_a_danger_line_or_a_hint(t: T) -> void:
	var a := _ann("vc2-b")
	a.request("taken")
	_wait(a, 1200)
	t.check(not a.current.is_empty() and a.current.moment == "taken", "a player taken: the line plays")
	a.on_events(NOISY)
	t.check(not a.current.is_empty() and a.hushes == 0, "a danger line is never hushed")
	_wait(a, 20000)
	a.request("wipe")
	_wait(a, 1200)
	if not a.current.is_empty():
		a.on_events(NOISY)
		t.check(not a.current.is_empty() and a.hushes == 0, "priority 5 is never hushed")
	a.free()
	var b := _ann("vc2-c")
	t.check(b.hint("hint_job"), "a hint")
	_wait(b, 1200)
	if not b.current.is_empty():
		b.on_events(NOISY)
		t.check(not b.current.is_empty() and b.hushes == 0, "a hint is never hushed")
	b.free()

func test_two_screens_hush_alike(t: T) -> void:
	var a := _ann("vc2-same")
	var b := _ann("vc2-same")
	for s: Node in [a, b]:
		s.request("arrived")
		_wait(s, 1000)
		s.on_events(NOISY)
		_wait(s, 3000)
	var ha := (a.history as Array).map(func(h: Dictionary) -> String: return "%s@%d" % [h.id, h.at])
	var hb := (b.history as Array).map(func(h: Dictionary) -> String: return "%s@%d" % [h.id, h.at])
	t.check(a.hushes == 1 and b.hushes == 1, "both hushed")
	t.eq(ha, hb, "the same lines at the same times")
	a.free()
	b.free()
