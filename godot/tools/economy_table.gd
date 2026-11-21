# PY1's numbers, before and after (sim/run.gd "PY1"): for floors 1 to 21, what a reading is worth (times floor 1's)
# and the floor quota for one player, with the game's rooms' pressures on; the day quota each player owes on day 1 of
# each cycle; and the credits each player banks on five day shapes for crews of 1, 2 and 4, counting only the floor
# quotas the crew must record to call the car (the Reactor asks none). Nothing is simulated: these are the rules'
# own functions. Run:
#   "$GODOT" --headless --path godot --script res://tools/economy_table.gd
extends SceneTree

const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Day = preload("res://sim/day.gd")

func _init() -> void:
	print("floor | place | pay x before | pay x after | quota each before | quota each after")
	for d in range(1, 22):
		var before := _state(d, false)
		var after := _state(d, true)
		print("%d | %d | %.2f | %.2f | %d | %d" % [d, Run.economy_depth(d), Run.pay_multiplier(before), Run.pay_multiplier(after),
			_quota(before, 1), _quota(after, 1)])
	print("")
	print("day 1 quota, each player | before | after")
	for cycle: int in [1, 2, 3]:
		var first: int = Places.cycle_start(cycle - 1)
		print("cycle %d (floor %d) | %d | %d" % [cycle, first, Day.quota_for(0, 1, Run.day_floor_quota(_state(first, false))), Day.quota_for(0, 1, Run.day_floor_quota(_state(first, true)))])
	print("")
	var shapes := [["cycle 1, bank at floor 5", 1, 5], ["cycle 1, the full day (floors 1-6 earn)", 1, 6],
		["cycle 2, bank at floor 12", 8, 12], ["cycle 2, the full day (floors 8-13 earn)", 8, 13], ["cycle 3, bank at floor 19", 15, 19]]
	print("credits each player banks (the quotas recorded) | crew | before | after")
	for sh: Array in shapes:
		for crew: int in [1, 2, 4]:
			var b := 0
			var a := 0
			for d in range(int(sh[1]), int(sh[2]) + 1):
				b += _quota(_state(d, false), crew)
				a += _quota(_state(d, true), crew)
			print("%s | %d | %d | %d" % [sh[0], crew, b / crew, a / crew])
	quit(0)

## A run of the game's rooms (cycles and the pressures on) standing on floor `depth`.
func _state(depth: int, economy: bool) -> Run.RunState:
	var ids: Array[String] = ["p0"]
	var s := Run.create_run("economy-table", ids, Places.with_cycles(Places.with_reactor(Places.FULL)), true, true, true)
	s = Run.with_pressures(s)
	if economy:
		s = Run.with_economy_fix(s)
	s.depth = depth
	s.cycles_done = (depth - 1) / 7
	return s

func _quota(s: Run.RunState, crew: int) -> int:
	return Run.floor_quota(s.depth, crew, null, Run.pressure_quota_mult(s, null), s.economy_fix)
