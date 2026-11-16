# Thirty seeded bot crews played tick by tick for 90 s each against src/sim (bot.ts, entity.ts,
# instrument.ts): bots wander and flee, the Orderly hunts them, every instrument is raised, one bot
# keeps lowering and raising its own, tapes are dropped and picked up. Every tick's full state is
# compared by digest. Mirrors botCrew in godot/tools/dump_reference.ts.
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Trace = preload("res://tests/trace.gd")
const Plans = preload("res://tests/plans.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05

static func bot_crew(i: int, want: Dictionary) -> Trace:
	var seed := "crew-%d" % i
	var depth := 1 + (i % 4)
	var n_bots := 1 + ((i / 4) % 4)
	var p := Plans.plan(seed, depth)
	var rng := Rng.make_rng(seed).fork("setup")
	var toggles := Rng.make_rng(seed).fork("toggles")
	var bots: Array[Bot.Bot] = []
	for b in n_bots:
		var oblivious := b == 0 and i % 3 == 0
		var w := rng.next()
		bots.append(Bot.create_bot(p, "bot%d" % b, "%s:%d" % [seed, b], w, oblivious, p.landing if b == 0 else null))
	var ids: Array[String] = []
	for b in bots:
		ids.append(b.id)
	var active := {}
	for id in ids:
		active[id] = true
	var crew := Instr.create_crew(ids)
	for id in ids:
		crew = Instr.set_raised(crew, id, true)
	var toggle_in := 2.0 + toggles.next() * 6.0
	var orderly := Entity.create_orderly(p)
	var tr := Trace.new(want)
	var tick := 0
	while tick < 90.0 / DT:
		toggle_in -= DT
		if toggle_in <= 0.0 and n_bots > 1:
			toggle_in = 1.0 + toggles.next() * 6.0
			var m := Instr.member(crew, "bot1")
			if m != null:
				crew = Instr.set_raised(crew, "bot1", not m.instrument.raised)
		for b in bots:
			if active[b.id]:
				var raised := Instr.member(crew, b.id).instrument.raised
				Bot.step_bot(p, b, DT, null if raised else orderly.body, 2.2 if raised else INF)
		var views: Array[Entity.PlayerView] = []
		for b in bots:
			var v := Bot.bot_view(b)
			v.active = active[b.id]
			views.append(v)
		var before := orderly
		var res := Entity.step_entity(p, before, views, DT)
		orderly = res.state
		var players: Array[Instr.CrewPlayer] = []
		for v in views:
			players.append(Instr.CrewPlayer.make(v.id, v.body, v.active))
		var ticks: Array[Instr.EntityTick] = [Instr.EntityTick.make("orderly", &"stillness", before, orderly, res.events)]
		var out := Instr.step_crew(p, crew, players, ticks, DT)
		crew = out.crew
		var events: Array = res.events + out.events
		for e in res.events:
			if e["type"] == "caught":
				active[e["playerId"]] = false
		for f: Instr.FloorTape in crew.floor.duplicate():
			for k in ids.size():
				var id := ids[k]
				var pl := players[k]
				if not active[id] or not pl.active or M.hypot3(pl.body.x - f.at.x, pl.body.y - f.at.y, pl.body.z - f.at.z) > 1.3:
					continue
				var up := Instr.pick_up_tape(crew, id, f.tape.id)
				if up.ok:
					crew = up.crew
					events.append(up.event)
					break
		var bots_plain: Array = []
		for b in bots:
			bots_plain.append(Snap.bot(b))
		tr.tick({"bots": bots_plain, "orderly": Snap.orderly(orderly), "crew": Snap.crew(crew)}, events)
		tick += 1
	return tr

func test_thirty_crews(t: T) -> void:
	var ref: Array = Snap.load_ref("bots.json")
	var total := Snap.Diff.new()
	var ticks := 0
	var events := 0
	var firsts := PackedStringArray()
	var pay_ticks := 0
	# The quick set: two crews (crew-7's pay differs from TypeScript's in the last bits early on).
	var crews: Array[int] = [0, 7]
	if not t.quick:
		crews.clear()
		for i in 30:
			crews.append(i)
	for i in crews:
		var tr := bot_crew(i, ref[i])
		ticks += tr.ticks
		events += tr.events.size()
		pay_ticks += tr.full_bad
		total.add(tr.finish(t, true))
		if tr.exact_first >= 0 or tr.full_first >= 0:
			firsts.append("%s: %s" % [tr.name, tr.first_difference()])
	t.note("%d crews x 1800 ticks = %d ticks, %d events; every tick's state (pay masked) identical; events, snapshots: %s" % [crews.size(), ticks, events, total.summary()])
	t.note("ticks whose pay fields differ in the last bits (pow): %d; first differences: %s" % [pay_ticks, ", ".join(firsts) if not firsts.is_empty() else "never"])
