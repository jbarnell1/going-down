## Picture and transport status for the three reels on the car's back-wall monitor.
extends Node2D

const Reels = preload("res://sim/night_reels.gd")
const Art = preload("res://client/tape_symbols.gd")
const SIZE := Vector2i(276, 140)
const CENTER := Vector2(138, 59)
const WHITE := Color("#f1f3ec")

var reel_day := 0
var shot := -1
var shot_time := 0.0
var cue: Array = []
var elapsed := 0.0
var status_text := ""

## The reel with the real counts added: "went" (players in the run) and "came" (those aboard and well).
static func with_counts(reel: Dictionary, players: Array) -> Dictionary:
	var went := 0
	var came := 0
	for row: Dictionary in players:
		if bool(row.get("active", false)):
			went += 1
			if bool(row.get("aboard", false)) and str(row.get("status", "")) == "ok":
				came += 1
	var out := reel.duplicate()
	out["went"] = went if went > 0 else int(reel.get("crew", 0))
	out["came"] = came
	return out

func present(reel: Dictionary, host_now: float, player_id: String, pending: Variant) -> void:
	reel_day = int(reel["day"])
	elapsed = maxf(0.0, host_now - float(reel["started"]))
	shot_time = elapsed
	var shots: Array = Reels.SHOTS[reel_day - 1]
	shot = 0
	while shot + 1 < shots.size() and shot_time >= float(shots[shot][0]):
		shot_time -= float(shots[shot][0])
		shot += 1
	cue = shots[shot]
	if reel_day == 1 and reel.has("went") and reel.has("came"):
		# The closing line states the crew's real numbers (a wipe sends the car up empty).
		cue = cue.duplicate()
		if shot == shots.size() - 1:
			cue[2] = Reels.day_one_line(int(reel["went"]), int(reel["came"]))
	var votes: Array = reel["votes"]
	var needed := int(reel["crew"]) / 2 + 1
	var voted: bool = votes.has(player_id) or pending == reel["started"]
	status_text = "%s %d/%d" % ["VOTED" if voted else "SPACE TO SKIP", votes.size(), needed]
	queue_redraw()

func caption() -> String:
	if shot < 0:
		return ""
	var copy := str(cue[2])
	if shot == Reels.SHOTS[reel_day - 1].size() - 1:
		return copy.left(floori(shot_time * 54.0))
	return copy

func _draw() -> void:
	if shot < 0:
		return
	var shots: Array = Reels.SHOTS[reel_day - 1]
	var bleed := shot == shots.size() - 1
	var background := Color("#172459") if bleed else Art.BLUE
	draw_rect(Rect2(Vector2.ZERO, Vector2(SIZE)), background)
	if bleed:
		var copy := caption()
		var y := 37.0
		for row in PixelFont.wrap(copy, 30):
			Art.text(self, row, Vector2(18, y), 1.0, WHITE)
			y += 12.0
		var band := fposmod(shot_time * 53.0, 108.0)
		draw_rect(Rect2(0, band, SIZE.x, 2), Color(0.8, 0.86, 1.0, 0.23))
	else:
		Art.text(self, "PLAY > %02d" % int(elapsed), Vector2(9, 7), 1.0)
		var caption := str(cue[1])
		Art.text(self, caption, Vector2((SIZE.x - Art.text_width(caption, 1.0)) * 0.5, 23), 1.0)
		_draw_beat()
		var y := 96.0
		for row in PixelFont.wrap(caption(), 36):
			Art.text(self, row, Vector2((SIZE.x - Art.text_width(row, 1.0)) * 0.5, y), 1.0, WHITE)
			y += 9.0
	for y in range(2, 126, 3):
		draw_rect(Rect2(0, y, SIZE.x, 1), Color(0.0, 0.0, 0.0, 0.1))
	draw_rect(Rect2(0, 126, SIZE.x, 14), Color("#0a183b"))
	Art.text(self, status_text, Vector2(10, 129), 1.0, WHITE)

func _draw_beat() -> void:
	if shot == 0:
		Art.mark(self, CENTER + Vector2(-24, 0), 0.65)
		if reel_day == 3:
			Art.clock(self, CENTER + Vector2(30, 0), 13, 0.3)
		else:
			Art.bunk(self, CENTER + Vector2(29, 1), 0.5)
		return
	match reel_day:
		1: _draw_city()
		2: _draw_crew()
		3: _draw_late()

func _draw_city() -> void:
	if shot == 6:
		_draw_moon()
		return
	var at := CENTER + Vector2(0, 18)
	if shot <= 3:
		Art.ground(self, 39, 55, 221)
		if shot == 1:
			Art.city(self, at, 0.58, 6.0, 0.0)
		else:
			var sink := 8.0 * Art.ease_in_out(shot_time) if shot == 3 else 0.0
			for i in 3:
				if shot == 3 or shot_time >= i * 0.65:
					var box := Rect2(85 + i * 39, 52 + sink, 25, 22)
					Art.frame(self, box, 2, Art.YELLOW)
					if i != 1 or shot != 3 or fmod(shot_time, 0.65) < 0.3:
						Art.text(self, ["+", "::", "O"][i], box.position + Vector2(7, 7), 1.0)
	else:
		var lid_y := lerpf(39.0, 67.0, Art.ease_in_out(shot_time * 1.7)) if shot == 4 else 67.0
		draw_rect(Rect2(61, lid_y, 154, 5), Art.YELLOW)
		if shot == 4:
			Art.city(self, Vector2(138, lid_y), 0.48, maxf(0.0, shot_time - 0.7) * 4.0, 6.0)
		else:
			Art.frame(self, Rect2(121, 74, 34, 16), 2, Art.YELLOW)
			for i in 3:
				draw_line(Vector2(128 + 9 * i, 75), Vector2(128 + 9 * i, 89), Art.YELLOW, 1)
			Art.arrow(self, Vector2(174, 82), 0.38, false)

func _draw_crew() -> void:
	match shot:
		1, 3:
			for i in 4:
				var at := Vector2(76 + i * 41, 82)
				Art.you(self, at, 0.61, i if shot == 1 or shot_time < i * 0.6 else -1)
				if shot == 3 and i < 3 and shot_time < (i + 1) * 0.65:
					draw_line(at + Vector2(12, -13), at + Vector2(29, -13), Art.YELLOW, 2)
			if shot == 1:
				Art.text(self, "CREW %d" % mini(41, 7 + int(shot_time * 12)), Vector2(110, 34), 1)
		2:
			var t := fposmod(shot_time, 1.75)
			var down := t < 0.875
			var y := 48.0 + (t if down else 1.75 - t) * 40.0
			Art.rail(self, CENTER.x, 35, 86)
			Art.car(self, Vector2(CENTER.x, y), 0.6, -1 if down else 1, 4 if down else 0)
		4:
			for i in mini(5, 1 + floori(shot_time)):
				var at := Vector2(70 + i * 34, 54)
				Art.frame(self, Rect2(at, Vector2(26, 26)), 2, Art.YELLOW)
				draw_line(at + Vector2(7, 5), at + Vector2(19, 5), Art.YELLOW, 2)
				Art.credit(self, at + Vector2(9, 17), 4)
				draw_rect(Rect2(at + Vector2(16, 13), Vector2(6, 9)), Art.YELLOW)
		5: _draw_moon()

func _draw_late() -> void:
	match shot:
		1:
			Art.doors(self, Rect2(90, 39, 38, 47), 0.0)
			var y := 82.0 - 30.0 * Art.ease_in_out(shot_time - 2.0)
			Art.you(self, Vector2(155, y), 0.63)
			draw_line(Vector2(155, 35), Vector2(155, y - 25), Art.YELLOW, 2)
			draw_arc(Vector2(160, y - 21), 5, PI * 0.1, PI, 12, Art.YELLOW, 2)
		2:
			Art.clock(self, CENTER, 21, shot_time * 8.5)
		3, 4:
			Art.frame(self, Rect2(93, 36, 90, 52), 2, Art.YELLOW)
			Art.you(self, Vector2(138, 83), 0.84, 0)
			var cover := minf(26.0, shot_time * 9.0) if shot == 3 else 26.0
			for row in ceili(cover / 4.0):
				for stripe in 4:
					draw_rect(Rect2(128 + stripe * 5, 81 - row * 4, 2, 2), Art.BLUE)
			if shot == 4 or shot_time > 3.6:
				draw_rect(Rect2(150, 64, 8, 7), Art.YELLOW)
		5:
			_draw_moon()
			Art.doors(self, Rect2(92, 51, 30, 34), 0.0)

func _draw_moon() -> void:
	draw_circle(CENTER + Vector2(15, -6), 16, Art.YELLOW)
	draw_circle(CENTER + Vector2(22, -12), 15, Art.BLUE)
	Art.ground(self, 83, 74, 202)
