# The fairness rule under delay, ported from tests/net/rule.test.ts and tests/net/rule.ts with their
# independent oracle (tests/net/oracle.ts): networked sessions of a host machine and 1 to 3 remote
# players, bots driving every player, links with one-way delays drawn per link from 0 to 250 ms,
# jitter up to 60 ms, 5% loss, some reordering and duplication. Every client renders at 60 frames a
# second in its own local time and every frame is checked by the oracle against where THAT client
# draws the Orderly:
#   1. a visible Orderly is drawn at exactly the same pose and clock as on the frame before;
#   3. no catch of a player whose own screen showed the Orderly during the wind-up; the taken latch;
#   4. every frame the host treats as blind (a blink, the blackout) is dark on every client, and no
#      dark frame draws the Orderly;
#   5. events exactly once and in order, and at the end every client agrees with the host;
#   6. other players are drawn within 0.5 m of where the host had them at the drawn time.
# The counts must equal TypeScript's for the same sessions (tools/property_counts.ts, key `net` of
# properties.json, at the quick, default and full sizes).
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Harness = preload("res://tests/net_harness.gd")
const PropEntity = preload("res://tests/prop_entity.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const M = preload("res://sim/jsmath.gd")
const Session = preload("res://net/session.gd")
const Pose = preload("res://net/pose.gd")
const Protocol = preload("res://net/protocol.gd")
const JsJson = preload("res://net/jsjson.gd")
const Move = preload("res://sim/move.gd")
const Client = preload("res://net/client.gd")

const TICK := Session.TICK
const FRAME := Harness.FRAME
const POS_BOUND := 0.5
const ORACLE_RANGE := 25.0
const ORACLE_POINTS: Array[float] = [1.7, 2.6]

# =============================================================================================
# The oracle (tests/net/oracle.ts): the line of sight of tests/prop_entity.gd, against the viewer's
# TRUE frustum (its own fields of view, no margin), figure tested at its chest and the top of its head.

static func oracle_in_frustum(v: Pose.Camera, px: float, py: float, pz: float) -> bool:
	var wx := px - v.body.x
	var wy := py - (v.body.y + v.eye)
	var wz := pz - v.body.z
	var c := M.cos_js(v.yaw)
	var s := M.sin_js(v.yaw)
	var x1 := wx * c - wz * s
	var z1 := wx * s + wz * c
	var cp := M.cos_js(v.pitch)
	var sp := M.sin_js(v.pitch)
	var y2 := wy * cp + z1 * sp
	var z2 := -wy * sp + z1 * cp
	var depth := -z2
	if depth <= 0.0:
		return false
	var h_half := (v.h_fov_deg * PI) / 360.0
	var v_half := (v.v_fov_deg * PI) / 360.0
	return M.atan2_js(absf(x1), depth) <= h_half and M.atan2_js(absf(y2), depth) <= v_half

static func oracle_sees(plan: Floor.FloorPlan, v: Pose.Camera, fig: Dictionary) -> bool:
	var ex := v.body.x
	var ey := v.body.y + v.eye
	var ez := v.body.z
	var fx: float = fig["x"]
	var fy: float = fig["y"]
	var fz: float = fig["z"]
	if M.hypot3(fx - ex, fy + 1.7 - ey, fz - ez) > ORACLE_RANGE:
		return false
	var in_view: Array[float] = []
	for h in ORACLE_POINTS:
		if oracle_in_frustum(v, fx, fy + h, fz):
			in_view.append(h)
	for h in in_view:
		if PropEntity.oracle_los(plan, ex, ey, ez, fx, fy + h, fz):
			return true
	return false

# =============================================================================================
# One session (tests/net/rule.ts runRuleSession).

class Result:
	var label: String
	var pairs := 0
	var violations: Array[String] = []
	var visible_frames := 0
	var frames := 0
	var put_backs := 0
	var put_back_distances := PackedFloat64Array()
	var max_put_back := 0.0
	var bound_violations := 0
	var max_violation_gap := 0.0
	var reports := 0
	var travelled := 0.0
	var seen_on_host := false
	var catches := 0
	var strict: Array[String] = []
	var natural: Array[String] = []
	var displayed: Array[String] = []
	var catch_hold_ticks := 0
	var catches_forced := 0
	var blinks := 0
	var blink_violations: Array[String] = []
	var blink_frames_checked := 0
	var extra_dark := PackedFloat64Array()
	var blackouts := 0
	var blackout_frames_checked := 0
	var dark_drawn: Array[String] = []
	var dark_frames := 0
	var max_release_jump := 0.0
	var releases := 0
	var big_releases := 0
	var pos_checks := 0
	var max_pos_err := 0.0
	var pos_over: Array[String] = []
	var disagreements: Array[String] = []
	var events_checked := 0
	var clamped := 0
	var latches := 0
	var false_latches := 0
	var latched_catches := 0
	var latch_gaps: Array[String] = []

class Track:
	var g := PackedFloat64Array()
	var rt := PackedFloat64Array()
	var dark: Array[bool] = []
	var showed: Array[bool] = []
	var taken: Array[bool] = []
	var prev_vis := false
	var prev_pose: Variant = null
	var prev_depth := -1

## Where the host had a player at host time `t` (between ticks, blended); null across a teleport.
static func host_body_at(s: Harness, id: String, t: float) -> Variant:
	var k := floori(t / TICK + 1e-6)
	var a := _body_of(s, k, id)
	var b := _body_of(s, k + 1, id)
	if a == null or b == null:
		return null
	# Placed by the run (rides, push-outs): the drawn figure blends across, so is not compared there.
	for j in range(k - 3, k + 4):
		var p := _body_of(s, j, id)
		var q := _body_of(s, j + 1, id)
		if p != null and q != null and (M.hypot2(p.x - q.x, p.z - q.z) > 1.0 or p.level != q.level):
			return null
	var f := maxf(0.0, minf(1.0, t / TICK - k))
	return [a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f]

static func _body_of(s: Harness, k: int, id: String) -> Move.Body:
	var st := s.host.state_at(k)
	if st == null:
		return null
	for p in st.players:
		if p.id == id:
			return p.body
	return null

static func _fx(x: float, d: int) -> String:
	return M.to_fixed(x, d)

static func run_session(i: int, cfg: Harness.NetConfig, seconds: float) -> Result:
	var seed := "net-%d" % i
	var remotes := 1 + (i % 3)
	var res := Result.new()
	res.label = "%s remotes%d" % [seed, remotes]
	var tracks := {}
	var last := {"body": null, "depth": 1}
	var s := Harness.new(seed, remotes, cfg)
	s.on_tick = func(ss: Harness) -> void:
		var st := ss.host.state
		var b := st.orderly.body
		if last["body"] != null and st.depth == last["depth"]:
			res.travelled += M.hypot2(b.x - float(last["body"][0]), b.z - float(last["body"][1]))
		last["body"] = [b.x, b.z]
		last["depth"] = st.depth
		if st.orderly.seen:
			res.seen_on_host = true
	s.on_frame = func(m: Harness.Machine, rec: Dictionary) -> void:
		var t: Track = tracks.get(m.id)
		if t == null:
			t = Track.new()
			tracks[m.id] = t
		res.frames += 1
		var f: Client.Frame = rec["frame"]
		var g: float = rec["g"]
		if rec["dark"]:
			res.dark_frames += 1
			if f.visible:
				res.dark_drawn.append("%s %s drew the Orderly on a dark frame at t=%s" % [res.label, m.id, _fx(g, 3)])
		var pose: Variant = rec["pose"]
		var depth: int = rec["depth"]
		var vis: bool = not rec["dark"] and pose != null and oracle_sees(Session.plan_for(seed, depth), rec["cam"], pose)
		if vis:
			res.visible_frames += 1
		if vis and t.prev_vis and pose != null and t.prev_pose != null and depth == t.prev_depth:
			res.pairs += 1
			if not Pose.same_pose(pose, t.prev_pose):
				res.violations.append("%s %s t=%s drawn moved while visible" % [res.label, m.id, _fx(g, 3)])
		# 6. Other players, drawn where the host had them at the (delayed) time being drawn.
		for dp: Dictionary in f.players:
			var truth: Variant = host_body_at(s, dp["id"], rec["rt"])
			if truth == null:
				continue
			res.pos_checks += 1
			var db: Move.Body = dp["body"]
			var err := M.hypot3(db.x - float(truth[0]), db.z - float(truth[2]), db.y - float(truth[1]))
			res.max_pos_err = maxf(res.max_pos_err, err)
			if err > POS_BOUND:
				res.pos_over.append("%s %s draws %s %s m off at t=%s" % [res.label, m.id, dp["id"], _fx(err, 2), _fx(g, 2)])
		t.prev_vis = vis
		t.prev_pose = pose
		t.prev_depth = depth
		t.g.append(g)
		t.rt.append(rec["rt"])
		t.dark.append(rec["dark"])
		t.showed.append(vis or rec["seeing"])
		t.taken.append(f.taken)
	s.run(seconds)
	s.on_frame = Callable()
	s.on_tick = Callable()
	agreement(s, res)

	var h := s.host
	res.put_backs = h.stats.put_backs
	res.put_back_distances = h.stats.put_back_distances
	res.max_put_back = h.stats.max_put_back
	res.bound_violations = h.stats.bound_violations
	res.max_violation_gap = h.stats.max_violation_gap
	res.reports = h.stats.reports
	res.catch_hold_ticks = h.stats.catch_hold_ticks
	res.catches_forced = h.stats.catches_forced
	res.clamped = h.stats.clamped_inputs
	for m in s.machines:
		res.max_release_jump = maxf(res.max_release_jump, m.client.stats.max_release_jump)
		res.releases += m.client.stats.releases
		res.big_releases += m.client.stats.big_releases
		res.latches += m.client.stats.latches
		res.false_latches += m.client.stats.false_latches

	# 3. Looking saves you.
	var wind_ups := {}
	for l in h.event_log:
		var e := l.e
		if e["type"] == "windUp":
			wind_ups[e["playerId"]] = e["t"]
		if e["type"] != "caught":
			continue
		res.catches += 1
		var pid: String = e["playerId"]
		var t: Track = tracks.get(pid)
		if not wind_ups.has(pid) or t == null:
			continue
		var w: float = wind_ups[pid]
		var c: float = e["t"]
		var latched := false
		for k in t.g.size():
			var rt := t.rt[k]
			if rt < w or rt >= c:
				continue
			if t.taken[k]:
				latched = true
			elif latched:
				res.latch_gaps.append("%s %s caught t=%s: frame at t=%s not blind after the latch" % [res.label, pid, _fx(c, 2), _fx(t.g[k], 3)])
		if latched:
			res.latched_catches += 1
		for k in t.g.size():
			if not t.showed[k]:
				continue
			var g := t.g[k]
			var rt := t.rt[k]
			var tag := "%s %s caught t=%s windUp t=%s" % [res.label, pid, _fx(c, 2), _fx(w, 2)]
			if g >= w and g <= c:
				res.strict.append("%s screen showed it at t=%s" % [tag, _fx(g, 3)])
			if g >= w and g <= w + Entity.WIND_UP_TIME:
				res.natural.append("%s screen showed it at t=%s" % [tag, _fx(g, 3)])
			if rt >= w and rt < c:
				res.displayed.append("%s screen showed it drawing t=%s" % [tag, _fx(rt, 3)])

	# 4. Blinks: every frame inside a host blind window is dark on every client.
	var start: Variant = null
	for l in h.event_log:
		var e := l.e
		if e["type"] == "blinkStart":
			start = e["t"]
		if e["type"] != "blinkEnd" or start == null:
			continue
		res.blinks += 1
		if e["blackout"]:
			res.blackouts += 1
		var lo := float(start) - TICK
		var hi := float(e["t"]) - TICK
		for id: String in tracks:
			var t: Track = tracks[id]
			var dark := 0
			for k in t.g.size():
				var g := t.g[k]
				if g > lo and g <= hi:
					res.blink_frames_checked += 1
					if e["blackout"]:
						res.blackout_frames_checked += 1
					if not t.dark[k]:
						res.blink_violations.append("%s %s lit at t=%s in blink" % [res.label, id, _fx(g, 3)])
				if g >= float(start) - 3.0 and g <= float(e["t"]) + 3.0 and t.dark[k]:
					dark += 1
			res.extra_dark.append(dark * FRAME - (hi - lo))
		start = null
	return res

static func _q2s(x: float) -> String:
	return JsJson.num(Protocol.q2(x))

## Tests 5 and 6 at the end of a session: every client agrees with the host (rule.ts agreement).
static func agreement(s: Harness, res: Result) -> void:
	var h := s.host
	var host_events: Array[String] = []
	for l in h.event_log:
		host_events.append(JsJson.stringify(l.e))
	for m in s.machines:
		if m.gone:
			continue
		var c := m.client
		var w: Variant = c.latest
		if w == null:
			res.disagreements.append("%s %s has no state" % [res.label, m.id])
			continue
		var wt: int = w["tick"]
		if wt < h.tick - 20:
			res.disagreements.append("%s %s is %d ticks behind" % [res.label, m.id, h.tick - wt])
		var hs := h.state_at(wt)
		if hs == null:
			continue
		var mine_tapes := PackedStringArray()
		for mm: Dictionary in w["crew"]:
			var parts := PackedStringArray()
			for tp: Dictionary in [mm["tape"]] + mm["carrying"]:
				parts.append("%s/%d/%s" % [tp["id"], int(tp["readings"]), _q2s(tp["total"])])
			mine_tapes.append("%s:%s" % [mm["id"], ",".join(parts)])
		var host_tapes := PackedStringArray()
		for mm in hs.crew.members:
			var parts := PackedStringArray()
			var all: Array = [mm.tape]
			all.append_array(mm.carrying)
			for tp: Variant in all:
				parts.append("%s/%d/%s" % [tp.id, tp.readings.size(), _q2s(tp.total)])
			host_tapes.append("%s:%s" % [mm.id, ",".join(parts)])
		var mine_floor := PackedStringArray()
		for f: Dictionary in w["floor"]:
			mine_floor.append("%s/%d/%s" % [f["id"], int(f["readings"]), _q2s(f["total"])])
		var host_floor := PackedStringArray()
		for f in hs.crew.floor:
			host_floor.append("%s/%d/%s" % [f.tape.id, f.tape.readings.size(), _q2s(f.tape.total)])
		var mine := [w["phase"], int(w["depth"]), " ".join(mine_tapes), ",".join(mine_floor), _banked(w["summary"])]
		var host := [String(hs.phase), hs.depth, " ".join(host_tapes), ",".join(host_floor), _banked(Protocol.summary_plain(hs.summary))]
		if str(mine) != str(host):
			res.disagreements.append("%s %s at tick %d: %s vs host %s" % [res.label, m.id, wt, str(mine), str(host)])
		# 5. Events: exactly the host's, in its order, with nothing missing up to a second before the end.
		res.events_checked += c.events.size()
		for k in c.events.size():
			var got := JsJson.stringify(c.events[k])
			if k >= host_events.size() or got != host_events[k]:
				res.disagreements.append("%s %s event %d: %s" % [res.label, m.id, k + 1, got])
				break
		var due := 0
		for l in h.event_log:
			if l.tick <= wt - 20:
				due += 1
		if c.events.size() < due:
			res.disagreements.append("%s %s has %d events, host had %d a second before its newest state" % [res.label, m.id, c.events.size(), due])

static func _banked(sm: Variant) -> Variant:
	if sm == null:
		return null
	var shares := PackedStringArray()
	var sh: Dictionary = sm["shares"]
	for k: String in sh:
		shares.append("%s=%s" % [k, _q2s(sh[k])])
	return "%s %s %s" % ["wiped" if sm["wiped"] else "banked", _q2s(sm["total"]), ",".join(shares)]

# =============================================================================================
# The sizes and the tests.

## [lossy sessions, zero-delay sessions, seconds] per size (tools/property_counts.ts NET_SIZES).
const SIZES := {"quick": [2, 1, 20.0], "sub": [8, 2, 60.0], "full": [200, 40, 60.0]}

var _cache := {}

func _runs(t: T) -> Dictionary:
	var key := t.size_key()
	if _cache.has(key):
		return _cache[key]
	var sz: Array = SIZES[key]
	var t0 := Time.get_ticks_msec()
	var lossy: Array[Result] = []
	for i in int(sz[0]):
		lossy.append(run_session(i, Harness.lossy(), sz[2]))
	var zero: Array[Result] = []
	for i in int(sz[1]):
		zero.append(run_session(i, Harness.zero(), sz[2]))
	var out := {"lossy": lossy, "zero": zero, "secs": (Time.get_ticks_msec() - t0) / 1000.0}
	_cache[key] = out
	return out

## The counts property_counts.ts writes (netCounts), from a list of sessions.
static func counts(rs: Array[Result]) -> Dictionary:
	var c := {"sessions": rs.size(), "frames": 0, "visibleFrames": 0, "pairs": 0, "violations": 0, "putBacks": 0, "reports": 0,
		"bigPutBacks": 0, "boundViolations": 0, "releases": 0, "bigReleases": 0, "catches": 0, "natural": 0, "strict": 0, "displayed": 0,
		"catchHoldTicks": 0, "catchesForced": 0, "latches": 0, "falseLatches": 0, "latchedCatches": 0, "latchGaps": 0, "blinks": 0,
		"blinkViolations": 0, "blinkFramesChecked": 0, "blackouts": 0, "blackoutSessions": 0, "blackoutFramesChecked": 0, "darkFrames": 0,
		"darkDrawn": 0, "posChecks": 0, "posOver": 0, "disagreements": 0, "eventsChecked": 0, "clamped": 0, "moved": 0, "seen": 0,
		"caught": 0, "maxPutBack": 0.0, "putBackSum": 0.0, "maxReleaseJump": 0.0, "maxPosErr": 0.0, "extraDarkSum": 0.0, "extraDarkMax": -INF, "extraDarkN": 0}
	for r in rs:
		c["frames"] += r.frames
		c["visibleFrames"] += r.visible_frames
		c["pairs"] += r.pairs
		c["violations"] += r.violations.size()
		c["putBacks"] += r.put_backs
		c["reports"] += r.reports
		for d in r.put_back_distances:
			if d > 0.6:
				c["bigPutBacks"] += 1
			c["putBackSum"] += d
		c["boundViolations"] += r.bound_violations
		c["releases"] += r.releases
		c["bigReleases"] += r.big_releases
		c["catches"] += r.catches
		c["natural"] += r.natural.size()
		c["strict"] += r.strict.size()
		c["displayed"] += r.displayed.size()
		c["catchHoldTicks"] += r.catch_hold_ticks
		c["catchesForced"] += r.catches_forced
		c["latches"] += r.latches
		c["falseLatches"] += r.false_latches
		c["latchedCatches"] += r.latched_catches
		c["latchGaps"] += r.latch_gaps.size()
		c["blinks"] += r.blinks
		c["blinkViolations"] += r.blink_violations.size()
		c["blinkFramesChecked"] += r.blink_frames_checked
		c["blackouts"] += r.blackouts
		c["blackoutSessions"] += 1 if r.blackouts > 0 else 0
		c["blackoutFramesChecked"] += r.blackout_frames_checked
		c["darkFrames"] += r.dark_frames
		c["darkDrawn"] += r.dark_drawn.size()
		c["posChecks"] += r.pos_checks
		c["posOver"] += r.pos_over.size()
		c["disagreements"] += r.disagreements.size()
		c["eventsChecked"] += r.events_checked
		c["clamped"] += r.clamped
		c["moved"] += 1 if r.travelled > 5.0 else 0
		c["seen"] += 1 if (r.seen_on_host or r.reports > 0) else 0
		c["caught"] += 1 if r.catches > 0 else 0
		c["maxPutBack"] = maxf(c["maxPutBack"], r.max_put_back)
		c["maxReleaseJump"] = maxf(c["maxReleaseJump"], r.max_release_jump)
		c["maxPosErr"] = maxf(c["maxPosErr"], r.max_pos_err)
		for x in r.extra_dark:
			c["extraDarkSum"] += x
			c["extraDarkMax"] = maxf(c["extraDarkMax"], x)
			c["extraDarkN"] += 1
	if c["extraDarkN"] == 0:
		c["extraDarkMax"] = 0.0
	return c

func _want(t: T) -> Dictionary:
	return Snap.load_ref("properties.json")[t.size_key()]["net"]

func _first(rs: Array[Result], field: String) -> Array[String]:
	var out: Array[String] = []
	for r in rs:
		for x: String in r.get(field):
			out.append(x)
	return out

func _no(t: T, rs: Array[Result], field: String, what: String) -> void:
	var bad := _first(rs, field)
	t.check(bad.is_empty(), "%s: %d, first: %s" % [what, bad.size(), bad[0] if not bad.is_empty() else ""])

## Every count equals TypeScript's for the same sessions.
func test_counts_match_typescript(t: T) -> void:
	var runs := _runs(t)
	var want := _want(t)
	var lossy: Array[Result] = runs["lossy"]
	var zero: Array[Result] = runs["zero"]
	var got := {"lossy": counts(lossy), "zero": counts(zero)}
	var d := Snap.compare(got, {"lossy": want["lossy"], "zero": want["zero"]}, "net")
	t.check(d.ok(), "counts: %s" % d.summary())
	var l: Dictionary = got["lossy"]
	t.note("%d lossy + %d zero-delay sessions of %d s in %.1f s: frames %d, visible pairs %d (violations %d), put-backs %d of %d reports, releases %d (big %d), catches %d (latched first %d, forced %d), latches %d (false %d), blinks %d (blackouts %d), blind frames checked %d (lit %d), dark frames drawing it %d, players checked %d (max error %.3f m), events %d, disagreements %d" % [
		lossy.size(), zero.size(), int(SIZES[t.size_key()][2]), runs["secs"], l["frames"], l["pairs"], l["violations"], l["putBacks"], l["reports"], l["releases"],
		l["bigReleases"], l["catches"], l["latchedCatches"], l["catchesForced"], l["latches"], l["falseLatches"], l["blinks"], l["blackouts"],
		l["blinkFramesChecked"], l["blinkViolations"], l["darkDrawn"], l["posChecks"], l["maxPosErr"], l["eventsChecked"], l["disagreements"]])

## 1. On every client, a visible Orderly is drawn at exactly the same pose and clock as on the frame before.
func test_watched_never_moves(t: T) -> void:
	var runs := _runs(t)
	var lossy: Array[Result] = runs["lossy"]
	var zero: Array[Result] = runs["zero"]
	_no(t, lossy, "violations", "visible frame pairs where the drawn Orderly moved (lossy)")
	_no(t, zero, "violations", "visible frame pairs where the drawn Orderly moved (zero delay)")
	var c := counts(lossy)
	t.eq(c["boundViolations"], 0, "put-backs refused for distance")
	if not t.quick:
		t.check(c["pairs"] > 150 * lossy.size(), "not vacuous: %d visible frame pairs" % c["pairs"])

## 3. Looking saves you, and the victim's screen commits to the catch at the end of the wind-up it drew.
func test_looking_saves_you(t: T) -> void:
	var runs := _runs(t)
	var lossy: Array[Result] = runs["lossy"]
	_no(t, lossy, "natural", "catches whose victim's screen showed the Orderly during the wind-up")
	_no(t, lossy, "displayed", "catches whose victim's screen showed the wind-up being drawn")
	_no(t, lossy, "latch_gaps", "frames not blind after the taken latch")
	var c := counts(lossy)
	if not t.quick:
		t.check(c["latchedCatches"] >= c["catches"] * 0.9, "catches latched first: %d of %d" % [c["latchedCatches"], c["catches"]])

## 4. Blinks and the blackout: every frame the host treats as blind is dark on every client; no dark frame draws it.
func test_blinks_dark_everywhere(t: T) -> void:
	var runs := _runs(t)
	var lossy: Array[Result] = runs["lossy"]
	var zero: Array[Result] = runs["zero"]
	_no(t, lossy, "blink_violations", "lit frames inside a blind window")
	_no(t, lossy, "dark_drawn", "dark frames drawing the Orderly (lossy)")
	_no(t, zero, "dark_drawn", "dark frames drawing the Orderly (zero delay)")
	var c := counts(lossy)
	if not t.quick:
		t.check(c["blinkFramesChecked"] > 1000 * lossy.size(), "not vacuous: %d blind frames checked" % c["blinkFramesChecked"])
		t.check(c["extraDarkSum"] / maxf(1.0, c["extraDarkN"]) < 1.0, "extra darkness per blink per client %.2f s" % (c["extraDarkSum"] / maxf(1.0, c["extraDarkN"])))

## 5 and 6. Events exactly once and in order; every client agrees with the host; players drawn within 0.5 m.
func test_agreement(t: T) -> void:
	var runs := _runs(t)
	var lossy: Array[Result] = runs["lossy"]
	_no(t, lossy, "disagreements", "disagreements with the host")
	_no(t, lossy, "pos_over", "players drawn more than 0.5 m from the host's record")
	var c := counts(lossy)
	t.check(c["maxPosErr"] <= POS_BOUND, "largest drawn-player error %.3f m" % c["maxPosErr"])
