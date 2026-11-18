# Ready-up on screen (docs/floors/findables-and-day.md section 2, FD6) and the orientation tape's place in
# joining (docs/floors/story.md ST1): client/start_screen.gd and client/main.gd's decisions, headless.
#   - the run is shown only after this player's own READY and once the room has put them in it: a player
#     still reading (or watching the tape) is never dropped into a run that is on;
#   - the controls card is the design's table without the keys that do nothing yet (Q, G), the three lines
#     under it and ENTER OR CLICK: I'M READY; the crew's states and the count's and late joiner's lines;
#   - playing alone, READY starts the run at once;
#   - `tape_seen` is set when the tape reaches its last shot and when it is skipped, never when it starts;
#     an automated client never gets the tape unless asked, and the tape is seen once per player.
# The same on screen, with two real game windows and a late joiner: tools/play_ready.mjs.
extends RefCounted

const T = preload("res://tests/t.gd")
const Main = preload("res://client/main.gd")
const StartScreenScript = preload("res://client/start_screen.gd")
const LocalRoom = preload("res://net/local_room.gd")

func test_the_run_shows_only_after_your_own_ready(t: T) -> void:
	# [my READY, the room's running flag, in the run (playing)] -> shown.
	var cases: Array = [
		[false, true, false, false, "still reading while the crew's run is on: Ready-up stays"],
		[false, true, true, false, "in the run but never pressed READY: not dropped in"],
		[true, true, false, false, "ready, the run on, waiting for the next stop: Ready-up with the late line"],
		[true, false, false, false, "ready, no run yet: Ready-up (the count)"],
		[true, true, true, true, "ready and in the run: the car"],
	]
	for c: Array in cases:
		t.eq(Main.run_view_on(c[0], c[1], c[2]), c[3], c[4])

func test_the_controls_card(t: T) -> void:
	var design: Array = [
		["W A S D, MOUSE", "WALK, LOOK"], ["SHIFT", "SPRINT. IT TIRES YOU"], ["CTRL OR C", "CREEP. QUIET"],
		["E", "INSTRUMENT OUT / AWAY"], ["RIGHT MOUSE", "HOLD IT UP TO RECORD"], ["F", "USE: CALL THE LIFT, SEARCH, HIDE, PICK UP"],
		["Q", "STICK AN ARROW"], ["G", "DRINK"], ["HOLD R", "EMOTES"], ["ESC", "THIS CARD AGAIN"],
	]
	# Q and G do nothing in the game yet (no key handler sends a mark or a drink): their rows wait.
	var want: Array = design.filter(func(r: Array) -> bool: return r[0] != "Q" and r[0] != "G")
	t.eq(StartScreenScript.CARD_ROWS.size(), want.size(), "the card has the design's rows but Q and G")
	for i in mini(want.size(), StartScreenScript.CARD_ROWS.size()):
		t.eq(StartScreenScript.CARD_ROWS[i], want[i], "card row %d" % i)
	t.eq(StartScreenScript.CARD_LINES, ["RECORD WHAT LIVES ON EACH FLOOR.", "MEET THE QUOTA. CALL THE LIFT.", "STAND ON BANK TO GO HOME, DOWN TO GO DEEPER."] as Array[String], "the three lines under it")
	t.eq(StartScreenScript.READY_LINE, "ENTER OR CLICK: I'M READY", "the press at the bottom")
	var text := ""
	for row: Array in StartScreenScript.card_lines():
		text += " " + str(row[1])
	t.check(text.contains("USE: CALL THE LIFT,") and text.contains("HIDE, PICK UP"), "a long action wraps onto a second row, whole (%s)" % text)

func test_the_crew_list_and_the_lines(t: T) -> void:
	t.eq(StartScreenScript.crew_state(["c1", "Ann", true, false, false, ""]), "READY", "ready")
	t.eq(StartScreenScript.crew_state(["c1", "Ann", false, false, false, ""]), "READING", "reading the card")
	t.eq(StartScreenScript.crew_state(["c1", "Ann", false, true, false, ""]), "WATCHING THE TAPE", "watching the tape")
	t.eq(StartScreenScript.crew_state(["c1", "Ann"]), "READING", "an older server's row")
	var ss: StartScreen = StartScreenScript.new()
	ss.persist_tape = false
	ss.count_left = 4.2
	t.eq(ss.status_line(), "GOING DOWN IN 5", "the count")
	ss.count_left = 0.3
	t.eq(ss.status_line(), "GOING DOWN IN 1", "the count's last second")
	ss.run_depth = 2
	t.eq(ss.status_line(), "THE CREW IS ON FLOOR 2. YOU JOIN AT THE NEXT STOP.", "the late joiner's line, in place of the count")
	ss.run_depth = -1
	ss.count_left = -1.0
	t.eq(ss.status_line(), "", "nothing while waiting for the others")
	ss.people = [["c1", "Ann", true, false, false, ""], ["c2", "Bob", false, false, false, ""], ["c3", "Cy", false, true, false, ""]]
	t.eq(ss.stragglers(), 2, "START WITHOUT counts who it leaves")
	ss.free()

func test_play_alone_ready_starts_at_once(t: T) -> void:
	var lr := LocalRoom.new()
	lr.open_local("ready-alone", "YOU", false)
	lr.days = false
	lr.set_ready(false, true)
	t.check(not lr.run_on and lr.people[0][3] == true, "watching the tape alone: no run, shown as watching")
	lr.set_ready(true)
	t.check(lr.run_on and lr.client != null, "READY alone starts the run at once")
	t.eq(lr.host_id, "me", "alone you are the host")
	lr.leave()

# ---- the tape --------------------------------------------------------------------------------------

func _screen() -> StartScreen:
	var ss: StartScreen = StartScreenScript.new()
	ss.persist_tape = false   # a test never writes the player's record
	ss.tape_seen = false
	return ss

func test_tape_seen_is_set_at_the_end_not_the_start(t: T) -> void:
	var ss := _screen()
	var ends: Array = []
	ss.tape_finished.connect(func(skipped: bool) -> void: ends.append(skipped))
	ss.play_tape()
	t.check(ss.tape.playing and ss.screen == "tape", "the tape plays on this screen")
	t.check(not ss.tape_seen, "tape_seen is not set when the tape starts")
	ss.tape.t_hold = false
	ss.tape.advance(ss.tape.total * 0.5)
	t.check(not ss.tape_seen, "nor halfway (a player who quits on shot 2 sees it again)")
	ss.tape.advance(ss.tape.total)
	t.check(ss.tape_seen and ends == [false], "it is set when the tape reaches its last shot (%s)" % str(ends))
	ss.free()

func test_tape_seen_is_set_on_a_skip(t: T) -> void:
	var ss := _screen()
	var ends: Array = []
	ss.tape_finished.connect(func(skipped: bool) -> void: ends.append(skipped))
	ss.play_tape()
	ss.tape.t_hold = true
	ss.tape.advance(0.2)
	t.check(not ss.tape_seen, "a tap does not skip, and sets nothing")
	ss.tape.advance(0.5)
	t.check(ss.tape_seen and ends == [true], "a 0.6 s hold skips, and sets it (%s)" % str(ends))
	ss.free()

func test_the_tape_once_per_player_and_never_for_a_test_unless_asked(t: T) -> void:
	t.check(StartScreenScript.wants_tape(false, false, false), "the first join on this PC plays the tape")
	t.check(not StartScreenScript.wants_tape(true, false, false), "a second join does not")
	t.check(not StartScreenScript.wants_tape(false, true, false), "an automated client (auto=1) never gets it unless asked")
	t.check(StartScreenScript.wants_tape(false, true, true), "and gets it with tape=1")
	# WATCH THE TAPE plays it again on Ready-up.
	var ss := _screen()
	ss.tape_seen = true
	ss.show_screen("lobby")
	t.check("watch" in ss._order(), "Ready-up has WATCH THE TAPE")
	var asked := [0]
	ss.watch_tape_pressed.connect(func() -> void: asked[0] += 1)
	ss.press("watch")
	t.eq(asked[0], 1, "pressing it asks for the tape")
	ss.free()
