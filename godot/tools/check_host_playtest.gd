# Run the Windows client scene headlessly with -- auto=1, without opening a test socket.
extends SceneTree

const Game = preload("res://client/main.gd")
const GameScene = preload("res://main.tscn")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")

var _failures := 0

func _initialize() -> void:
	_check.call_deferred()

func _expect(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures += 1

func _f6(game: Game) -> void:
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_F6
	key.physical_keycode = KEY_F6
	game._input(key)

func _check() -> void:
	var game := GameScene.instantiate() as Game
	root.add_child(game)
	await process_frame
	_expect(game.start.focused_id() == "alone", "the title starts on Play Alone")
	game.start.press("playtest")
	_expect(game.start.screen == "playtest", "the title button opens the sandbox picker")
	var destinations := LocalRoom.playtest_destinations(game.seed, Session.deck)
	for destination in destinations:
		var depth := int(destination["depth"])
		# The late floors (FL1) hand the screen to their own scene (main is replaced), so this tool stops short of them:
		# tests/test_floor_entry.gd plays that hand-over and the way home.
		if String(destination["place"]) in ["ward", "reactor"]:
			continue
		game.start.press(str(depth))
		await _wait_for_floor(game, depth)
		# The late floors (FL1) are overlays on that depth's own plan: the plan's place is the deck's, not "ward"/"reactor".
		var overlay := String(destination["place"]) in ["ward", "reactor"]
		_expect(game.built_depth == depth and (overlay or game.link.plan_dict.get("place") == String(destination["place"])),
			"the client draws the real selected area on floor %d" % depth)
		_f6(game)
		_expect(game.start.screen == "playtest", "F6 opens the picker from floor %d" % depth)
	var previous := game.link.rc as LocalRoom
	var selected_depth := previous.host.state.depth
	game.start.press("restart")
	await _wait_for_floor(game, selected_depth)
	_expect(game.link.rc != previous and game.built_depth == selected_depth, "restart opened a fresh copy of the selected area")
	_f6(game)
	game.start.press("resume")
	_expect(game.start.screen == "", "resume closes the picker")
	_f6(game)
	game.start.press("title")
	_expect(game.start.screen == "title" and game.link == null, "end sandbox returns to the title")
	game._play_alone()
	_f6(game)
	_expect(game.start.screen == "playtest" and game.start.playtest_choices[0]["id"] == "resume", "F6 in a game played alone opens the picker, RESUME first (PT6)")
	game.start.press("resume")
	_expect(game.start.screen == "" and game.mode == "game", "resume goes back to the same solo game")
	game._back_to_title()
	game.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)

func _wait_for_floor(game: Game, depth: int) -> void:
	var end := Time.get_ticks_msec() + 15000
	while (game.built_depth != depth or game.link.plan_dict.is_empty()) and Time.get_ticks_msec() < end:
		await process_frame
