extends RefCounted

const T = preload("res://tests/t.gd")
const NotesView = preload("res://client/annex_notes_view.gd")
const Reader = preload("res://client/note_reader.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")

func test_wall_note_requires_a_near_front_facing_look(t: T) -> void:
	var view := NotesView.new()
	var plan := Places.generate("annex-note-view", 3, Places.FULL)
	var car := Run.car_geometry(plan)
	var wall := Run.note_spot(plan, car.level, car.door_x - car.in_x, car.door_z - car.in_z, 0.0)
	var authored := "We never touch your marks, Birch. We do read them."
	var row := {"id": 9, "x": wall[0], "z": wall[1], "level": car.level, "yaw": wall[2], "text": authored}
	view.show_notes([row])
	var point := NotesView.wall_point(row)
	var front := NotesView.wall_face(row)
	var nearby := point + front * 0.8
	var got := view.focus(plan, nearby, -front, car.level)
	t.eq(got.get("text"), authored, "the physical host note is readable from the right side")
	t.check(view.focus(plan, point + front * 3.05, -front, car.level).is_empty(), "outside three metres cannot expose this text")
	t.check(view.focus(plan, nearby, front, car.level).is_empty(), "looking away cannot expose this text")
	t.check(view.focus(plan, point - front * 0.3, front, car.level).is_empty(), "the reverse side of the wall cannot expose the note")
	t.check(view.focus(plan, nearby, -front, 1 - car.level).is_empty(), "the other storey cannot expose the note")
	view.show_notes([])
	t.check(view.focus(plan, nearby, -front, car.level).is_empty(), "the floor's next snapshot removes vanished notes")
	view.free()

func test_deliberate_note_read_preserves_identity_and_stays_off_the_archive(t: T) -> void:
	var reader := Reader.new()
	var authored := "Aster and Birch: you are standing very close. HR has been informed."
	reader.open_wall(17, authored)
	var shown := reader.describe()
	t.eq(shown["open"], "annex-17", "the read quotes the right host note")
	t.eq(shown["wallText"], authored, "the exact crew names and wording are preserved")
	t.check((shown["read"] as Array).is_empty(), "a note on the wall is not added to the found-paper list")
	var put_down := InputEventKey.new()
	put_down.physical_keycode = KEY_F
	put_down.pressed = true
	t.check(reader.key(put_down) and not reader.is_open() and reader.wall_text == "", "F closes and clears the text")
	reader.open("annex-17")
	t.check(not reader.is_open(), "the old wall note cannot be opened through the archived paper API")
	reader.free()
