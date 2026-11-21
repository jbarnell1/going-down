# VC1, the microphone's level on the wire (net/protocol.gd "VC1", net/client.gd, net/host.gd). Only a number for how
# loud travels, never a sound. Proved here:
#   1. The 30th input element survives the protocol, with and without the deal's answer and the reel's skip beside it;
#      a level over 15 is decoded as 15; a silent input is the old 18-element one; junk in its place is refused.
#   2. An old client (an input without the element) is silent at the host; a level reaches the run's PlayerInput on the
#      next tick and only on that one (a missing input is silence); the loudest since the last tick is the one taken.
#   3. The client sends the loudest level of the frames since its last input, then 0.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const Client = preload("res://net/client.gd")
const Transport = preload("res://net/transport.gd")

static func _input(seq: int, body: Move.Body) -> Dictionary:
	return {"type": "input", "seq": seq, "ct": 1.0, "body": body, "eye": 1.65, "yaw": 0.0, "pitch": 0.0, "hFovDeg": 90.0, "vFovDeg": 70.0,
		"raised": false, "holdDoors": false, "gait": "walk", "seeing": false, "calls": 0, "pickUps": 0, "ackEvent": 0, "ackHt": -1.0, "renderTime": 0.0, "placeAck": 0, "seen": []}

func test_the_element_survives_and_clamps(t: T) -> void:
	var body := Move.Body.make(3.0, 4.0, 0, 0.0)
	var m := _input(1, body)
	var plain: Array = JSON.parse_string(Protocol.encode(m))
	t.eq(plain.size(), 18, "a silent input is the old one")
	var back: Variant = Protocol.decode(Protocol.encode(m))
	t.check(back != null and not (back as Dictionary).has("voice"), "and decodes without a voice")
	for lv: int in [1, 7, 15]:
		m["voice"] = lv
		var text := Protocol.encode(m)
		var arr: Array = JSON.parse_string(text)
		t.eq(arr.size(), 30, "level %d: a 30th element" % lv)
		back = Protocol.decode(text)
		t.check(back != null and int(back.get("voice", -1)) == lv and back.get("deal") == null and not back.has("skipReelAt"), "level %d survives, no deal, no skip: %s" % [lv, str(back)])
	m["voice"] = 99
	t.eq(int((JSON.parse_string(Protocol.encode(m)) as Array)[29]), 15, "the client never sends over 15")
	# A client that sends more is decoded as 15; less than 0 as 0.
	var raw: Array = JSON.parse_string(Protocol.encode(m))
	raw[29] = 99
	back = Protocol.decode(JSON.stringify(raw))
	t.check(back != null and int(back.get("voice", -1)) == 15, "99 on the wire is decoded as 15")
	raw[29] = -4
	back = Protocol.decode(JSON.stringify(raw))
	t.check(back != null and int(back.get("voice", -1)) == 0, "-4 on the wire is decoded as 0")
	raw[29] = "loud"
	t.check(Protocol.decode(JSON.stringify(raw)) == null, "a word in its place is refused")
	# Beside the deal's answer and the reel's skip.
	m["voice"] = 9
	m["deal"] = [3, 1, "p1", 1, -1]
	m["skipReelAt"] = 12.5
	back = Protocol.decode(Protocol.encode(m))
	t.check(back != null and int(back.get("voice", -1)) == 9 and back.get("deal") == [3, 1, "p1", 1, -1] and is_equal_approx(float(back.get("skipReelAt", -1.0)), 12.5), "with the deal and the skip: %s" % str(back))
	m.erase("voice")
	back = Protocol.decode(Protocol.encode(m))
	t.check(back != null and not back.has("voice") and back.get("deal") == [3, 1, "p1", 1, -1], "the deal alone is as before (29 elements)")
	t.eq((JSON.parse_string(Protocol.encode(m)) as Array).size(), 29, "29 elements")
	# A listening microphone that hears nothing still says so (the NO MIC marks), as level 0.
	var quiet := _input(2, body)
	quiet["mic"] = true
	t.eq((JSON.parse_string(Protocol.encode(quiet)) as Array).size(), 30, "a listening microphone at 0: 30 elements")
	back = Protocol.decode(Protocol.encode(quiet))
	t.check(back != null and back.get("mic") == true and int(back.get("voice", -1)) == 0, "decoded as listening, level 0: %s" % str(back))
	back = Protocol.decode(Protocol.encode(_input(3, body)))
	t.check(back != null and not back.has("mic"), "no microphone: no mic")

func test_the_host_takes_it_once(t: T) -> void:
	var seen: Array[int] = []
	var step := func(s: Run.RunState, inputs: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
		for i in inputs:
			if i.id == "p0":
				seen.append(i.voice_level)
		return Run.step_run(s, inputs, dt)
	var net := Transport.MemoryNetwork.new("vc1-wire")
	var ids: Array[String] = ["p0"]
	var host := Host.new(net.connect_peer("host"), "vc1-wire", ids, 0.0, Callable(), step)
	host._join("p0")
	var body := host.state.players[0].body
	var now := 0.0
	var seq := 0
	# An old client: no element.
	seq += 1
	host._on_message("p0", Protocol.encode(_input(seq, body)), now)
	now += 0.05
	host.update(now)
	# Two inputs before the next tick: 4, then 11, then 6: the loudest is taken.
	for lv: int in [4, 11, 6]:
		seq += 1
		var m := _input(seq, body)
		m["voice"] = lv
		host._on_message("p0", Protocol.encode(m), now)
	now += 0.05
	host.update(now)
	var at := seen.size()
	# No new input: silence, though the last input carried a level.
	now += 0.05
	host.update(now)
	now += 0.05
	host.update(now)
	t.check(at >= 2, "the host ticked (%d inputs seen: %s)" % [seen.size(), str(seen)])
	t.check(not seen.is_empty() and seen[0] == 0, "an old client's input is silent: %s" % str(seen))
	t.check(seen.size() >= 2 and seen[at - 1] == 11, "the loudest level since the last tick reaches the run: %s" % str(seen))
	var after := seen.slice(at)
	t.check(not after.is_empty() and after.all(func(v: int) -> bool: return v == 0), "and only once: the next ticks are silent: %s" % str(after))
	# The NO MIC marks: the world lists whose microphone is listening, only in a run with the voice.
	t.check(not host.world().has("mic"), "the voice off: no mic list")
	host.state = Run.with_voice(host.state)
	var dec := Protocol.dec_world(Protocol._V.new(), JSON.parse_string(Protocol.world_json(host.world())))
	t.check(dec.get("mic") == ["p0"], "p0's last input carried a level: listening (%s)" % str(dec.get("mic")))
	seq += 1
	host._on_message("p0", Protocol.encode(_input(seq, body)), now)
	dec = Protocol.dec_world(Protocol._V.new(), JSON.parse_string(Protocol.world_json(host.world())))
	t.check(dec.get("mic") == [], "an input with no microphone: nobody listening (%s)" % str(dec.get("mic")))
	seq += 1
	var q := _input(seq, body)
	q["mic"] = true
	host._on_message("p0", Protocol.encode(q), now)
	dec = Protocol.dec_world(Protocol._V.new(), JSON.parse_string(Protocol.world_json(host.world())))
	t.check(dec.get("mic") == ["p0"], "a listening microphone at 0: listening (%s)" % str(dec.get("mic")))
	host.close()

func test_the_client_sends_the_loudest_since_its_last_input(t: T) -> void:
	var src := FileAccess.get_file_as_string("res://net/client.gd")
	t.check(src.contains("_voice_peak = clampi(maxi(_voice_peak, local.voice), 0, Protocol.VOICE_MAX)"), "each frame keeps the loudest")
	t.check(src.contains("if _voice_peak > 0:\n\t\tm[\"voice\"] = _voice_peak\n\t_voice_peak = 0"), "the input carries it and starts again from 0")
	var link := FileAccess.get_file_as_string("res://client/play_link.gd")
	t.check(link.contains("lf.voice = clampi(int(inp.get(\"voice\", 0)), 0, 15)"), "the screen's frame passes the microphone's level")
