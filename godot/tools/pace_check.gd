# Catch odds before and after paced (T20h; sim/run.gd paced, sim/stamina.gd PACED_SPRINT_SECONDS): the
# bot runs the stored tests already use, played with each tank size and hunting speed, counting the catches.
#  1. Floor chases: seeded bot crews as tests/ref_bots.gd plays them (sim/bot.gd wandering bots, 1 to 4 a
#     crew, depths 1 to 4, 90 s each, the Orderly hunting with Entity.step_entity), in two kinds: "raised"
#     exactly as ref_bots (every instrument up, so nobody can sprint but the bot that keeps lowering its
#     own) and "flee" (every instrument down: every bot sprints from the Orderly when it sees it close
#     behind, as far as its tank lets it). Per tank and hunting speed: catches per run, the share of runs
#     with a catch, and the time to the first catch.
#  2. Waits for the car: tests/waits.gd's wait bots (stay and flee) from the call to the bell, with the run's
#     own rules, without and with paced and the long dark (T20c): catches per wait, and in the blackout.
#   "$GODOT" --headless --path godot --script res://tools/pace_check.gd [-- crews=120 waits=60 seconds=90
#       speeds=3.7,3.85 kinds=raised,flee base=0 part=chases|waits]  (base=0: no row for today's numbers)
# Prints both tables. Measures only: it asserts nothing.
extends SceneTree

const Plans = preload("res://tests/plans.gd")
const Waits = preload("res://tests/waits.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const Bot = preload("res://sim/bot.gd")
const Rng = preload("res://sim/rng.gd")
const Run = preload("res://sim/run.gd")
const Stamina = preload("res://sim/stamina.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05
## Seconds each crew plays (ref_bots plays 90; more gives more catches to count).
static var seconds := 90.0

class Tally:
	var runs := 0
	var catches := 0
	var runs_caught := 0
	var bots := 0
	var first_times: Array[float] = []
	var all_times: Array[float] = []

func _init() -> void:
	var crews := 120
	var waits := 60
	var speeds: Array[float] = [3.7, 3.8, 3.85, 3.9, 4.0]
	var kinds: Array[String] = ["raised", "flee"]
	var part := "both"
	var base := true
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a.begins_with("part="):
			part = a.substr(5)
		elif a.begins_with("kinds="):
			kinds.assign(a.substr(6).split(","))
		elif a == "base=0":
			base = false
		elif a.begins_with("seconds="):
			seconds = float(a.substr(8))
		elif a.begins_with("crews="):
			crews = int(a.substr(6))
		elif a.begins_with("waits="):
			waits = int(a.substr(6))
		elif a.begins_with("speeds="):
			speeds = []
			for x: String in a.substr(7).split(",", false):
				speeds.append(float(x))
	if part != "waits":
		_chases(crews, speeds, kinds, base)
	if part != "chases":
		_waits(waits)
	quit(0)

func _chases(crews: int, speeds: Array[float], kinds: Array[String], base: bool) -> void:
	print("1. Floor chases: %d seeded bot crews per row (1-4 bots, depths 1-4, %d s each)" % [crews, int(seconds)])
	print("kind    tank  hunt  | runs  bots  catches  per run  runs caught  first catch (mean, median s)  every catch (median s)")
	for kind: String in kinds:
		var rows: Array = [[Stamina.SPRINT_SECONDS, Entity.HUNT_SPEED]] if base else []
		for sp in speeds:
			rows.append([Stamina.PACED_SPRINT_SECONDS, sp])
		for row: Array in rows:
			var t0 := Time.get_ticks_msec()
			var tl := Tally.new()
			for i in crews:
				_crew(i, kind == "flee", float(row[0]), float(row[1]), tl)
			print("%-6s  %4.1f  %4.2f  | %4d  %4d  %7d  %7.3f  %5.1f %%      %6.1f  %6.1f                       %6.1f      (%d ms)" % [
				kind, float(row[0]), float(row[1]), tl.runs, tl.bots, tl.catches, float(tl.catches) / tl.runs, 100.0 * tl.runs_caught / tl.runs,
				_mean(tl.first_times), _median(tl.first_times), _median(tl.all_times), Time.get_ticks_msec() - t0])

func _waits(waits: int) -> void:
	print("2. Waits for the car: %d waits per row and depth (wait bots, crews of 1-4, depths 1-3)" % waits)
	print("rules                     style | waits  lost someone  catches  in the blackout  after the lights")
	var sets: Array = [["today", {}], ["paced", {"paced": true}], ["long dark", {"long_dark": true}], ["paced + long dark", {"paced": true, "long_dark": true}]]
	for st: Array in sets:
		for style: StringName in [&"stay", &"flee"]:
			var lost := 0
			var caught := 0
			var in_black := 0
			var after := 0
			var n := 0
			for depth: int in [1, 2, 3]:
				var tb := Waits.wait_table(style, depth, waits, st[1])
				lost += tb.lost
				caught += tb.caught
				in_black += tb.caught_in_blackout
				after += tb.caught_after
				n += tb.waits
			print("%-24s  %-5s | %5d  %4d (%4.1f %%)  %7d  %15d  %16d" % [st[0], String(style), n, lost, 100.0 * lost / n, caught, in_black, after])

static func _mean(xs: Array[float]) -> float:
	if xs.is_empty():
		return 0.0
	var s := 0.0
	for x in xs:
		s += x
	return s / xs.size()

static func _median(xs: Array[float]) -> float:
	if xs.is_empty():
		return 0.0
	var c := xs.duplicate()
	c.sort()
	return c[c.size() / 2]

## One crew as tests/ref_bots.gd bot_crew plays it (no recording of the trace), with every bot's tank
## `tank` seconds and the Orderly hunting at `hunt`. `flee`: every instrument down (all can sprint).
static func _crew(i: int, flee: bool, tank: float, hunt: float, tl: Tally) -> void:
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
		var bot := Bot.create_bot(p, "bot%d" % b, "%s:%d" % [seed, b], w, oblivious, p.landing if b == 0 else null)
		bot.stamina = Stamina.fresh_stamina(tank)
		bots.append(bot)
	var ids: Array[String] = []
	for b in bots:
		ids.append(b.id)
	var active := {}
	for id in ids:
		active[id] = true
	var crew := Instr.create_crew(ids)
	for id in ids:
		crew = Instr.set_raised(crew, id, not flee)
	var toggle_in := 2.0 + toggles.next() * 6.0
	var orderly := Entity.create_orderly(p)
	var caught_any := false
	var tick := 0
	while tick < seconds / DT:
		toggle_in -= DT
		if not flee and toggle_in <= 0.0 and n_bots > 1:
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
		var res := Entity.step_entity(p, orderly, views, DT, hunt)
		orderly = res.state
		var t := (tick + 1) * DT
		for e in res.events:
			if e["type"] == "caught" and active.get(e["playerId"], false):
				active[e["playerId"]] = false
				tl.catches += 1
				tl.all_times.append(t)
				if not caught_any:
					caught_any = true
					tl.first_times.append(t)
		tick += 1
	tl.runs += 1
	tl.bots += n_bots
	if caught_any:
		tl.runs_caught += 1
