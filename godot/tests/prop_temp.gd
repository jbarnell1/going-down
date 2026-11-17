# The Temp (docs/floors/annex.md section 4, task T5): the Orderly's rules with another body. On Annex
# floors with wandering bots it proves three things:
#   1. Stillness: it never moves, turns or clicks in a tick it is held (seen now, or within the grace
#      after), nor in a tick the independent oracle (tests/prop_entity.gd's line of sight and true
#      camera frustum, sampled at the Temp's own heights) says a bot could see it;
#   2. waiting unseen, it clicks once every 4 s of its own unwatched standing, and that click is
#      audible near it and silent beyond 30 m;
#   3. walking, it clicks once per 1.2 m walked: click k comes in the tick its walked distance first
#      reaches 1.2 k metres.
# And the default body is still the Orderly's, with no stapler.
#
# The design's numbers are restated here, not imported from entity.gd. The deliberate break (let the
# idle click ignore "seen") turns test_never_moves_or_clicks_while_seen red.
extends RefCounted

const T = preload("res://tests/t.gd")
const Entity = preload("res://sim/entity.gd")
const Annex = preload("res://sim/annex.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")
const PE = preload("res://tests/prop_entity.gd")

const DT := 0.05
const DEPTH := 3
# annex.md section 4, restated.
const O_HEIGHT := 1.8
const O_CLICK_STEP := 1.2
const O_CLICK_WAIT := 4.0
const O_HEAR := 30.0
## Where the oracle looks for it: chest and head of a 1.8 m figure.
const O_POINTS: Array[float] = [1.0, 1.7]
const O_RANGE := 25.0
const RUN_SECONDS := 90.0

static var _plans := {}

static func annex(i: int) -> Floor.FloorPlan:
	if not _plans.has(i):
		_plans[i] = Annex.generate_annex("temp-%d" % i, DEPTH)
	return _plans[i]

static func floors(t: T) -> int:
	return 2 if t.quick else 6

static func clicks_of(events: Array[Dictionary], why: String = "") -> int:
	var n := 0
	for e in events:
		if e["type"] == "click" and (why.is_empty() or e["why"] == why):
			n += 1
	return n

static func oracle_sees(plan: Floor.FloorPlan, v: Entity.PlayerView, fig: Move.Body) -> bool:
	if M.hypot2(v.body.x - fig.x, v.body.z - fig.z) > O_RANGE:
		return false
	var ey := v.body.y + v.eye
	for h in O_POINTS:
		if PE.oracle_in_frustum(v, fig.x, fig.y + h, fig.z) and PE.oracle_los(plan, v.body.x, ey, v.body.z, fig.x, fig.y + h, fig.z):
			return true
	return false

func test_bodies(t: T) -> void:
	var temp := Entity.temp_body()
	var orderly := Entity.orderly_body()
	t.eq(temp.height, O_HEIGHT, "the Temp's height")
	t.eq(temp.click_step, O_CLICK_STEP, "metres walked per click")
	t.eq(temp.click_wait, O_CLICK_WAIT, "seconds standing unseen per click")
	t.eq(temp.hear_range, O_HEAR, "the stapler's hearing range")
	t.check(temp.seen_height > temp.height and temp.seen_radius > temp.radius, "the Temp's seen outline is larger than its body")
	t.eq(orderly.height, Entity.ORDERLY_HEIGHT, "the default body is the Orderly's")
	t.eq(orderly.click_step, 0.0, "the Orderly has no stapler (walk)")
	t.eq(orderly.click_wait, 0.0, "the Orderly has no stapler (wait)")
	t.check(Entity.create_orderly(annex(0)).kind == orderly, "create_orderly without a body makes an Orderly")
	t.check(Entity.create_orderly(annex(0), temp).kind == temp, "create_orderly with the Temp's body makes a Temp")

## 1. Stillness, by the rules' own held flag and by the oracle.
func test_never_moves_or_clicks_while_seen(t: T) -> void:
	var held_ticks := 0
	var oracle_ticks := 0
	var unheld_clicks := 0
	var wait_clicks_after_watch := 0
	var bad := 0
	for i in floors(t):
		var p := annex(i)
		var rng := Rng.make_rng("temp-bots-%d" % i)
		var bots: Array[Bot.Bot] = []
		for b in 3:
			bots.append(Bot.create_bot(p, "bot%d" % b, "temp-%d:%d" % [i, b], rng.next(), false, p.landing if b == 0 else null))
		var st := Entity.create_orderly(p, Entity.temp_body())
		var watched_since_click := false
		for tick in int(round(RUN_SECONDS / DT)):
			for b in bots:
				Bot.step_bot(p, b, DT, st.body)
			var views: Array[Entity.PlayerView] = []
			for b in bots:
				views.append(Bot.bot_view(b))
			var before := st
			var r := Entity.step_entity(p, before, views, DT)
			st = r.state
			var moved := st.body.x != before.body.x or st.body.y != before.body.y or st.body.z != before.body.z or st.body.level != before.body.level
			var turned := st.yaw != before.yaw
			var clicks := clicks_of(r.events)
			var oracle := false
			for v in views:
				if oracle_sees(p, v, before.body):
					oracle = true
					break
			if st.held:
				held_ticks += 1
				watched_since_click = true
			if oracle:
				oracle_ticks += 1
			if (st.held or oracle) and (moved or turned or clicks > 0 or st.clicks > 0):
				bad += 1
				if bad <= 5:
					t.check(false, "floor %d t=%.2f: %s, yet it %s%s%s" % [i, st.t, "held" if st.held else "the oracle sees it",
						"moved " if moved else "", "turned " if turned else "", "clicked" if clicks > 0 else ""])
			if not st.held and clicks > 0:
				unheld_clicks += clicks
				if clicks_of(r.events, "wait") > 0 and watched_since_click:
					wait_clicks_after_watch += 1
				watched_since_click = false
	t.eq(bad, 0, "ticks it moved, turned or clicked while held or seen")
	t.note("%d held ticks, %d seen by the oracle, %d clicks while unwatched (%d waiting clicks after a look)" % [held_ticks, oracle_ticks, unheld_clicks, wait_clicks_after_watch])
	t.check(held_ticks > 100, "not vacuous: it was held for over 100 ticks (got %d)" % held_ticks)
	t.check(oracle_ticks > 20, "not vacuous: the oracle saw it on over 20 ticks (got %d)" % oracle_ticks)
	t.check(unheld_clicks > 20, "not vacuous: it clicked over 20 times while unwatched (got %d)" % unheld_clicks)

## 2. Waiting, unseen: one click per 4 s, heard near it and not past 30 m.
func test_waiting_unseen_clicks_every_4_seconds(t: T) -> void:
	var total := 0
	for i in floors(t):
		var p := annex(i)
		var st := Entity.create_orderly(p, Entity.temp_body())
		var far := Move.body_at_cell(p, p.landing)
		# Present but seeing nothing: it neither wakes it by looking nor is it close enough to.
		var views: Array[Entity.PlayerView] = [Entity.PlayerView.make("me", far, Bot.BOT_EYE, 0.0, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true, true)]
		var near := Move.Body.make(st.body.x + 2.0, st.body.z, st.body.level, st.body.y)
		var beyond := Move.Body.make(st.body.x + O_HEAR + 0.5, st.body.z, st.body.level, st.body.y)
		var clicks_at: Array[float] = []
		var last := 0.0
		while st.t < 59.0 and st.mode == &"waiting":
			var r := Entity.step_entity(p, st, views, DT)
			st = r.state
			if st.mode != &"waiting":
				break
			last = st.t
			var n := clicks_of(r.events)
			t.eq(clicks_of(r.events, "walk"), 0, "floor %d t=%.2f: a walking click while waiting" % [i, st.t])
			for k in n:
				clicks_at.append(st.t)
			var a_near := Entity.audibility(p, st, near, Bot.BOT_EYE)
			var a_far := Entity.audibility(p, st, beyond, Bot.BOT_EYE)
			if n > 0:
				t.check(a_near.gain > 0.0, "floor %d t=%.2f: a click 2 m away is silent" % [i, st.t])
			else:
				t.check(a_near.gain == 0.0, "floor %d t=%.2f: heard without clicking" % [i, st.t])
			t.check(a_far.gain == 0.0, "floor %d t=%.2f: heard past %.0f m" % [i, st.t, O_HEAR])
		t.check(last >= 20.0, "floor %d: it waited at least 20 s (got %.2f)" % [i, last])
		t.eq(clicks_at.size(), int(floor(last / O_CLICK_WAIT + 1e-6)), "floor %d: clicks while waiting %.2f s" % [i, last])
		for k in clicks_at.size():
			t.check(absf(clicks_at[k] - O_CLICK_WAIT * (k + 1)) < DT / 2.0, "floor %d: click %d at %.3f s, want %.1f s" % [i, k + 1, clicks_at[k], O_CLICK_WAIT * (k + 1)])
		total += clicks_at.size()
	t.note("%d waiting clicks" % total)

## 3. Walking: click k in the tick its walked distance first reaches 1.2 k metres.
func test_walking_clicks_every_1_2_metres(t: T) -> void:
	var walked_total := 0.0
	var clicks_total := 0
	for i in floors(t):
		var p := annex(i)
		var st := Entity.create_orderly(p, Entity.temp_body())
		st.mode = &"hunting"
		var me := Move.body_at_cell(p, p.landing)
		var views: Array[Entity.PlayerView] = [Entity.PlayerView.make("me", me, Bot.BOT_EYE, 0.0, 0.0, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true, true)]
		var walked := 0.0
		var k := 0
		for tick in int(round(40.0 / DT)):
			var before := st
			var r := Entity.step_entity(p, before, views, DT)
			st = r.state
			if st.mode != &"hunting":
				break  # reached the player: the walk is over
			var d := M.hypot2(st.body.x - before.body.x, st.body.z - before.body.z)
			var start := walked
			walked += d
			var n := clicks_of(r.events, "walk")
			if d == 0.0:
				t.eq(n, 0, "floor %d t=%.2f: a walking click without walking" % [i, st.t])
			# The thresholds crossed in this tick: from just above `start` up to `walked`.
			var want := int(floor(walked / O_CLICK_STEP + 1e-9)) - k
			if not t.eq(n, want, "floor %d t=%.2f: walking clicks this tick (walked %.4f -> %.4f m)" % [i, st.t, start, walked]):
				return
			k += n
		t.check(walked > 10.0 * O_CLICK_STEP, "floor %d: it walked over 12 m (%.1f)" % [i, walked])
		walked_total += walked
		clicks_total += k
	t.note("%d walking clicks over %.1f m" % [clicks_total, walked_total])

## The default is still the Orderly: no stapler, no click events, in the same kind of run.
func test_orderly_never_clicks(t: T) -> void:
	var p := annex(0)
	var bots: Array[Bot.Bot] = []
	for b in 3:
		bots.append(Bot.create_bot(p, "bot%d" % b, "orderly:%d" % b, 0.5, false, p.landing if b == 0 else null))
	var st := Entity.create_orderly(p)
	var n := 0
	for tick in int(round(60.0 / DT)):
		for b in bots:
			Bot.step_bot(p, b, DT, st.body)
		var views: Array[Entity.PlayerView] = []
		for b in bots:
			views.append(Bot.bot_view(b))
		var r := Entity.step_entity(p, st, views, DT)
		st = r.state
		n += clicks_of(r.events) + st.clicks
	t.eq(n, 0, "clicks from the Orderly")
