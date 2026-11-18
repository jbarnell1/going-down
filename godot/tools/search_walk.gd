# Searching seen working without a screen (FD9; sim/findables.gd, sim/run.gd findables). A bot rides to floor
# DEPTH of the game's deck (the resident parked), walks out of the car to the pieces holding notes and the page, then the nearest others,
# faces each and holds F (every third one with sprint: the rushed search), and prints what the rules said: the
# prompt FD10 shows, the bar's times, the result line, any note's words, the tape's found credits, the cartons.
#   "$GODOT" --headless --path godot --script res://tools/search_walk.gd [-- SEED DEPTH PIECES]
extends SceneTree

const Run = preload("res://sim/run.gd")
const Findables = preload("res://sim/findables.gd")
const Furniture = preload("res://sim/furniture.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Follow = preload("res://sim/follow.gd")
const Places = preload("res://sim/places.gd")
const Entity = preload("res://sim/entity.gd")
const Instr = preload("res://sim/instrument.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Host = preload("res://net/host.gd")

const DT := 0.05
const SPEED := 3.0

var s: Run.RunState
var body: Move.Body

func _step(yaw: float, search: bool, fast: bool) -> Array[Dictionary]:
	var i := Run.PlayerInput.make("bot", body, 1.65, yaw, 0.0, 90.0, 70.0)
	i.search = search
	i.search_fast = fast
	var ins: Array[Run.PlayerInput] = [i]
	var r := Run.step_run(s, ins, DT)
	s = r.state
	for p in s.players:
		body = p.body
	return r.events

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seed := args[0] if args.size() > 0 else "walk"
	var depth := int(args[1]) if args.size() > 1 else 1
	var want := int(args[2]) if args.size() > 2 else 5
	var ids: Array[String] = ["bot"]
	var rules := HostRules.new(false, depth, Places.FULL, true, false, false, false, false, false, false, false, true, false, false, true, true)
	s = rules.prepare(Run.create_run(seed, ids))
	body = s.players[0].body
	while s.find == null and s.t < 10.0:
		_step(0.0, false, false)
	var ff: Findables.FindFloor = s.find
	print("%s, depth %d (%s), trait %s: %d searchable pieces" % [seed, depth, s.plan.place, ff.fill.trait_name, ff.pieces.size()])
	print("  the sheet: %s" % Findables.sheet_text(ff.fill))
	var order: Array = ff.pieces.duplicate()
	# A note and the page first (so their words show), then the rest nearest the lift first.
	var rank := func(p: Furniture.Piece) -> int:
		var w := str(ff.fill.contents[p.id]["what"])
		return (0 if w == "note" or w == "page" else 1000) + int(ff.fill.contents[p.id]["steps"])
	order.sort_custom(func(a: Furniture.Piece, b: Furniture.Piece) -> bool: return rank.call(a) < rank.call(b))
	var n := 0
	for p: Furniture.Piece in order:
		if n >= want:
			break
		# Where to stand: 45 cm in front of its side facing into the room.
		var inward := -Furniture.dir_vec(p.wall) if p.wall != &"" else Furniture.dir_vec(p.facing)
		var ext := p.foot.size.x / 2 if inward.x != 0 else p.foot.size.y / 2
		var at := p.foot.position + p.foot.size / 2 + inward * (ext + 45)
		var to := Move.Body.make(at.x / 100.0, at.y / 100.0, p.level, Move.LEVEL_HEIGHT if p.level == 1 else 0.0)
		# Walk there: the path by cells, then straight in.
		var walk := Follow.start_path_walk(Floor.find_path(s.plan, Move.cell_of(s.plan, body), Move.cell_of(s.plan, to)))
		var guard := 0
		while not Follow.path_done(s.plan, walk, body) and guard < 2000:
			body = Follow.step_path_walk(s.plan, walk, body, SPEED * DT, 0.3, Run.solids_in(s))
			_step(0.0, false, false)
			guard += 1
		while M.hypot2(to.x - body.x, to.z - body.z) > 0.02 and guard < 4000:
			var d := M.hypot2(to.x - body.x, to.z - body.z)
			var stp := minf(SPEED * DT, d)
			body = Run.move_in_run(s, body, (to.x - body.x) / d * stp, (to.z - body.z) / d * stp, 0.3)
			_step(0.0, false, false)
			guard += 1
		var yaw := Entity.yaw_toward(p.x / 100.0 - body.x, p.y / 100.0 - body.z)
		var aim := Findables.piece_in_reach(s.find as Findables.FindFloor, body, yaw)
		if aim == null:
			print("  piece %d (%s): could not stand in reach of it" % [p.id, p.kind])
			continue
		n += 1
		var fast := n % 3 == 0
		print("  piece %d: %s, %d steps from the lift. Prompt: \"%s\" / \"%s\"" % [aim.id, aim.kind, int(ff.fill.contents[aim.id]["steps"]), Findables.prompt_for(aim.kind), Findables.RUSH_PROMPT])
		var events: Array[Dictionary] = []
		for k in 60:
			events.append_array(_step(yaw, k < 58, fast))
		events.append_array(_step(yaw, false, false))
		for e in events:
			match str(e["type"]):
				"searchStart":
					print("    %s search from %.2f to %.2f s (the bar)" % ["a rushed" if e["fast"] else "a careful", e["from"], e["done"]])
				"searchNoise":
					print("    noise at the piece (the rushed search)")
				"startedHunting":
					print("    the resident woke")
				"searchStop":
					print("    stopped: %s" % e["why"])
				"searchDone":
					print("    found: %s" % Findables.result_line(str(e["what"]), int(e["credits"])))
					if str(e["note"]) != "":
						print("      %s (%s): %s" % [e["note"], "a poem" if Findables.is_poem(str(e["note"])) else "somebody's page", " / ".join(Findables.note_lines(str(e["note"])))])
	var m := Instr.member(s.crew, "bot")
	print("found credits on the bot's tape: %.0f; the day's earned: %.0f; cartons carried: %s" % [Run.found_on(m.tape), s.day_earned, str(s.items.get("bot", {}))])
	print("the snapshot's find block: %s" % str(Host.find_block(s)))
	quit(0)
