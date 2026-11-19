# The host's test tools (tracker PT6; docs/floors/live-settings.md and the owner's playtest of 19 Nov: "I couldn't
# use f6 to bring up the menu of which level to go to and I never found out how to change game parameters in real
# time"). The real game scene (client/main.gd), headless and automated (it never reads or writes the player's
# files). Proved here:
#   1. Alone (Play Alone, and with bots): the host is told F6 and F8 as the game starts; F8 opens the live panel and
#      a value changed with its keys is in force in the running rules; F6 opens the floor picker (RESUME first,
#      ESC back to the same game); a floor chosen is the floor the host's rules start, and the changed value goes
#      with the jump; the title gets the player's face back after.
#   2. In a shared room: F6 never jumps (the picker stays shut, the room is the same) and says where the picker is;
#      the host is told F8 as the game starts, a guest is told nothing.
#   3. The controls card's F6 and F8 rows only where each works; the picker's line and the panel's foot name the keys.
#   4. The sandbox's room keeps carried settings from its first tick, and drops a carried value the rules refuse.
extends RefCounted

const T = preload("res://tests/t.gd")
const Game = preload("res://client/main.gd")
const GameScene = preload("res://main.tscn")
const LocalRoom = preload("res://net/local_room.gd")
const RoomClient = preload("res://net/room_client.gd")
const PlayLink = preload("res://client/play_link.gd")
const Settings = preload("res://sim/settings.gd")
const Places = preload("res://sim/places.gd")
const Session = preload("res://net/session.gd")
const HudScript = preload("res://client/hud.gd")
const StartScreenScript = preload("res://client/start_screen.gd")
const SettingsPanel = preload("res://client/settings_panel.gd")

const ID := &"orderly.speed"

static func _game() -> Game:
	var game := GameScene.instantiate() as Game
	game.automated = true   # set before _ready: no saved face, hints, tape, brightness or settings file
	(Engine.get_main_loop() as SceneTree).root.add_child(game)
	return game

static func _key(game: Game, code: Key) -> void:
	for pressed: bool in [true, false]:
		var k := InputEventKey.new()
		k.pressed = pressed
		k.keycode = code
		k.physical_keycode = code
		game._input(k)

static func _f_rows(hud: Variant) -> Array:
	return (hud.menu_rows() as Array).filter(func(r: Array) -> bool: return str(r[0]) == "F6" or str(r[0]) == "F8")

func test_alone_f6_and_f8(t: T) -> void:
	var original_deck := Session.deck
	for bots: int in [0, 2]:
		var tag := "alone with %d bots" % bots
		var game := _game()
		game._solo_bots = bots
		game.start.face_code = "face-before"
		game._play_alone()
		var lr := game.link.rc as LocalRoom
		t.check(game.mode == "game" and game.link.local and lr.run_on and not game._playtest_active, "%s: in the run, not the sandbox" % tag)
		t.eq(game.hud.note, Game.HOST_KEYS_ALONE, "%s: the host is told both keys as the game starts" % tag)
		game._process(0.016)
		t.eq(_f_rows(game.hud), [["F6", "JUMP TO A FLOOR"], ["F8", "HOST SETTINGS"]], "%s: the controls card lists F6 and F8" % tag)
		# F8: the live panel; one step right on the Orderly's speed with the keys.
		_key(game, KEY_F8)
		var panel := game.settings_panel
		t.check(panel.is_open() and panel.is_host() and panel.top_line() == "HOST SETTINGS", "%s: F8 opens the live panel" % tag)
		panel.select(Settings.row(ID).section)
		panel._row = panel._section_rows(panel._sel).find(Settings.row(ID))
		_key(game, KEY_RIGHT)
		var want := Settings.snap(ID, Settings.today(ID) + Settings.row(ID).step)
		t.eq(lr.tune_asked.get(ID), want, "%s: the arrow key asked for one step" % tag)
		t.eq(Settings.f(lr.host.state.tuning, ID, -1.0), want, "%s: in force in the host's running rules" % tag)
		var now := 1000.0
		for _k in 6:
			now += 0.05
			lr.poll(now)
		t.check(lr.client.tune_rev == lr.desk.rev and lr.desk.rev > 0, "%s: the run's client has the revision" % tag)
		_key(game, KEY_F8)
		t.check(not panel.is_open(), "%s: F8 closes it" % tag)
		# F6: the picker over the same game; ESC goes back to it.
		_key(game, KEY_F6)
		t.eq(game.start.screen, "playtest", "%s: F6 opens the floor picker" % tag)
		t.eq(str(game.start.playtest_choices[0]["id"]), "resume", "%s: RESUME first" % tag)
		_key(game, KEY_ESCAPE)
		t.check(game.start.screen == "" and game.link.rc == lr and game.mode == "game", "%s: ESC resumes the same game" % tag)
		# F6 and a floor: the host's rules start on it, the changed value with it.
		_key(game, KEY_F6)
		var dest: Dictionary = LocalRoom.playtest_destinations(game.seed, Session.deck)[3]
		game.start.press(str(dest["depth"]))
		var sb := game.link.rc as LocalRoom
		t.check(sb != lr and game._playtest_active and game.start.screen == "", "%s: a choice starts the sandbox" % tag)
		t.check(sb.host.state.depth == int(dest["depth"]) and sb.host.state.plan.place == StringName(dest["place"]), "%s: on the chosen floor %d (%s)" % [tag, int(dest["depth"]), dest["place"]])
		t.eq(Settings.f(sb.host.state.tuning, ID, -1.0), want, "%s: the changed value went with the jump" % tag)
		t.eq(game.hud.note, Game.HOST_KEYS_ALONE, "%s: the sandbox says the keys too" % tag)
		_key(game, KEY_F6)
		t.check(game.start.playtest_choices.any(func(c: Dictionary) -> bool: return c["id"] == "restart"), "%s: in the sandbox, RESTART is offered" % tag)
		game.start.press("title")
		t.check(game.mode == "title" and game.link == null and not game._playtest_active, "%s: END SANDBOX goes to the title" % tag)
		t.eq(game.start.face_code, "face-before", "%s: the player's face is back" % tag)
		game._process(0.016)
		t.eq(_f_rows(game.hud), [], "%s: on the title neither row" % tag)
		game.free()
	Session.deck = original_deck

func test_shared_room_f6_and_the_host_line(t: T) -> void:
	var original_deck := Session.deck
	var game := _game()
	var rc := RoomClient.new()
	rc.my_id = "c1"
	rc.tune_host = "c1"
	game.link = PlayLink.new(rc, false)
	game._enter_game()
	t.eq(game.hud.note, Game.HOST_KEYS_ROOM, "the host of a shared room is told F8")
	game._host_tools_hud()
	t.eq(_f_rows(game.hud), [["F8", "HOST SETTINGS"]], "the host's card: F8, no F6")
	game.hud.note = ""
	_key(game, KEY_F6)
	t.check(game.start.screen != "playtest" and game.link.rc == rc and not game._playtest_active, "F6 in a shared room never jumps")
	t.eq(game.hud.note, Game.F6_IN_ROOM, "and says where the picker is")
	# A guest.
	rc.tune_host = "c2"
	game.hud.note = ""
	game._enter_game()
	t.eq(game.hud.note, "", "a guest is not told the host's keys")
	game._host_tools_hud()
	t.eq(_f_rows(game.hud), [["F8", "SEE THE HOST'S SETTINGS"]], "the guest's card: F8 read-only, no F6")
	game.link = null
	game.free()
	Session.deck = original_deck

func test_the_card_and_the_words(t: T) -> void:
	var hud: Variant = HudScript.new()
	var base: Array = hud.menu_rows()
	t.eq(_f_rows(hud), [], "no game: neither row")
	hud.f6_row = true
	hud.f8_row = "host"
	var rows: Array = hud.menu_rows()
	t.eq(rows.size(), base.size() + 2, "two rows added")
	var esc := rows.find(["ESC", "THIS MENU"])
	t.check(rows.find(["F6", "JUMP TO A FLOOR"]) == esc - 2 and rows.find(["F8", "HOST SETTINGS"]) == esc - 1, "F6 then F8, just above ESC")
	hud.free()
	t.check(StartScreenScript.PLAYTEST_SUBTITLE.contains("F6") and StartScreenScript.PLAYTEST_SUBTITLE.contains("F8"), "the picker's line names both keys")
	var lr := LocalRoom.new()
	lr.open_local("pt6-words", "Solo", true)
	var p := SettingsPanel.new()
	p.rc = lr
	t.check(p.foot_line().begins_with("LEFT RIGHT OR CLICK: CHANGE") and p.foot_line().ends_with("F8: CLOSE"), "the host's foot says how to change a value: %s" % p.foot_line())
	p.free()
	lr.leave()

func test_the_sandbox_keeps_carried_settings(t: T) -> void:
	var original_deck := Session.deck
	Session.deck = Places.FULL
	var lr := LocalRoom.new()
	lr.open_local("pt6-carry", "Solo", true)
	lr.start_playtest(2, {ID: 3.5, &"no.such": 1.0})
	t.eq(lr.tune_asked, {ID: 3.5}, "the carried value is asked for, an unknown one dropped")
	t.eq(Settings.f(lr.host.state.tuning, ID, -1.0), 3.5, "in force from the first tick")
	lr.leave()
	var bad := LocalRoom.new()
	bad.open_local("pt6-carry", "Solo", true)
	bad.start_playtest(2, {ID: 99.0})
	t.check(bad.tune_asked.is_empty() and bad.host.state.tuning == null, "a value out of range is not carried")
	bad.leave()
	var none := LocalRoom.new()
	none.open_local("pt6-carry", "Solo", true)
	none.start_playtest(2)
	t.check(none.tune_asked.is_empty() and none.desk.rev == 0, "nothing carried: nothing changed")
	none.leave()
	Session.deck = original_deck
