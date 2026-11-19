extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Entity = preload("res://sim/entity.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05

static func dist(a: Move.Body,b: Move.Body) -> float:
	return M.hypot3(a.x-b.x,a.y-b.y,a.z-b.z)

static func setup(enabled: bool, lonely: bool, four := false) -> Run.RunState:
	var ids: Array[String] = ["a","b"]
	if four:
		ids.append_array(["c","d"])
	var s := Run.with_downs(Run._create_run("annex-ui-1",ids,Places.FULL,3))
	if enabled:
		s = Run.with_annex_drag(s)
	if lonely:
		s = Run.with_lonely(s)
	s.phase = &"away"
	s.t = 2.0
	s.orderly.body = Move.Body.make(35.0,21.67,0,0.0)
	s.players[0].body = Move.Body.make(35.45,21.0,0,0.0)
	for i in range(1,s.players.size()):
		s.players[i].body = Move.Body.make(37.0,29.0,0,0.0)
	for p: Run.RunPlayer in s.players:
		p.aboard = false
	s.orderly = Entity.bend_over(s.orderly,"a")
	var events: Array[Dictionary] = []
	Run._go_down(s,s.players,0,s.t,&"catch",events)
	return s

static func face(s: Run.RunState, i: int, watches: bool, use := false, body: Move.Body = null) -> Run.PlayerInput:
	var p := s.players[i]
	var at := p.body if body == null else body
	var toward := Entity.yaw_toward(s.orderly.body.x-at.x,s.orderly.body.z-at.z)
	var v := Run.PlayerInput.make(p.id,at,1.65,toward if watches else toward+PI,0.0,90.0,70.0)
	v.use = use
	return v

static func tick(s: Run.RunState, look: Array[bool], rescue := false) -> Run.RunState:
	var inputs: Array[Run.PlayerInput] = []
	for i in s.players.size():
		var body: Move.Body = null
		if i == 0:
			# A movement claim cannot fight the drag.
			body = Move.Body.make(s.players[0].body.x + 0.3,s.players[0].body.z,0,0.0)
		if rescue and i == 1:
			body = Move.Body.make(s.players[0].body.x,s.players[0].body.z,0,0.0)
		inputs.append(face(s,i,look[i],rescue and i == 1,body))
	return Run.step_run(s,inputs,DT).state

func test_only_exact_stillness_watchers_can_hold_drag(t: T) -> void:
	var s := setup(true,false)
	if not t.check(Run.annex_dragging(s,"a"),"enabled Annex catch starts a valid drag"):
		return
	var held := tick(s,[true,true])
	t.check(held.orderly.held,"an up visible witness actually meets Stillness")
	t.check(dist(held.players[0].body,s.players[0].body)<0.000001,"Stillness freezes both bodies while seen")
	t.check(dist(held.orderly.body,s.orderly.body)<0.000001,"held Temp is stationary")
	t.eq(held.orderly.anim_time, s.orderly.anim_time, "the held dragging pose also stops advancing")
	var away := tick(s,[true,false])
	t.check(not away.orderly.held and dist(away.players[0].body,s.players[0].body)>0.04,"downed eyes do not hold Stillness")
	var grace := tick(held,[true,false])
	t.check(grace.orderly.held and dist(grace.players[0].body,held.players[0].body)<0.000001,"ordinary host watch grace also holds the drag")
	t.eq(grace.orderly.anim_time, held.orderly.anim_time, "ordinary watch grace also holds the animation clock")
	var wide := Run.with_two_watchers(setup(true,false,true))
	var one := tick(wide,[true,true,false,false])
	var two := tick(wide,[true,true,true,false])
	t.check(one.orderly.need == 2 and not one.orderly.held and dist(one.players[0].body,wide.players[0].body)>0.04,"one witness is insufficient when three players are up")
	t.check(two.orderly.held and dist(two.players[0].body,wide.players[0].body)<0.000001,"the second watcher holds both")
	var lonely := setup(true,true)
	var seen := tick(lonely,[true,true])
	t.check(seen.orderly.seen and dist(seen.players[0].body,lonely.players[0].body)>0.04,"watching a Lonely Temp never holds the drag")
	t.check(seen.orderly.anim_time > lonely.orderly.anim_time, "Lonely's animation clock continues while watched")

func test_drag_uses_nearest_copy_route_and_normal_collision(t: T) -> void:
	var s := setup(true,true)
	var down: Run.Downed = s.down["a"]
	if not t.check(down.drag_goal != null,"a copy room can be reached"):
		return
	var target := Move.cell_of(s.plan,down.drag_goal)
	t.eq(s.plan.rooms[Floor.room_id_at(s.plan,target.level,target.x,target.y)].kind,&"copy","the goal is inside an actual copy room")
	var distances := Floor.distances_from(s.plan,Move.cell_of(s.plan,s.players[0].body))
	var goal_steps := distances[Floor.pos_index(s.plan,target)]
	for room: Floor.Room in s.plan.rooms:
		if room.kind == &"copy":
			for z in range(room.y,room.y+room.h):
				for x in range(room.x,room.x+room.w):
					var d := distances[Floor.pos_index(s.plan,Floor.Pos.make(room.level,x,z))]
					t.check(d < 0 or d >= goal_steps,"the selected route is nearest by walking")
	# Extend the pure fixture only: exercise the independent 10 m hard limit beyond the rescue timer.
	down.until = 28.0
	var moved := 0.0
	var direction := Vector2.ZERO
	var turned := false
	for i in 260:
		var next := tick(s,[true,false])
		var b := s.players[0].body
		var a := next.players[0].body
		var distance := dist(a,b)
		t.check(distance <= DT+0.000001,"tick %d has a one metre/s limit" % i)
		t.check(Move.clear_at(s.plan,Run.solids_in(s),a.level,a.x,a.z,Run.CRAWL_RADIUS),"tick %d clears the actual floor and walls" % i)
		if distance > 0.000001:
			var new_dir := Vector2(a.x-b.x,a.z-b.z).normalized()
			turned = turned or (direction != Vector2.ZERO and new_dir.dot(direction) < 0.7)
			direction = new_dir
			t.check(Move.straight_to(s.plan,Run.solids_in(s),b,a,Run.CRAWL_RADIUS),"the tick did not tunnel through a wall")
		moved += distance
		s = next
	t.check(absf(moved-10.0)<0.002,"the route stops at 10 m, got %.3f" % moved)
	t.note("movement %.3f m, turned before cap %s" % [moved,str(turned)])

func test_drag_turns_into_copy_room_without_cutting_wall(t: T) -> void:
	var s := setup(true,true)
	s.players[0].body = Move.Body.make(27.0,21.0,0,0.0)
	s.orderly.body = Move.Body.make(27.4,21.0,0,0.0)
	var initial: Array[Dictionary] = []
	Run._go_down(s,s.players,0,s.t,&"catch",initial)
	var d: Run.Downed = s.down["a"]
	for i in 180:
		var p := s.players[0].body
		s = tick(s,[false,false])
		var next := s.players[0].body
		t.check(Move.straight_to(s.plan,Run.solids_in(s),p,next,Run.CRAWL_RADIUS),"corner segment %d stayed inside floor edges" % i)
	t.check(dist(s.players[0].body,d.drag_goal)<0.001,"the movement reaches the copy room by turning through the actual doorway")
	t.check(s.players[0].body.z > 22.9 and s.players[0].body.x < 24.0,"the victim turned from the starting east-west corridor")


func test_drag_heal_timeout_and_default_off(t: T) -> void:
	var off := setup(false,true)
	t.check(not off.annex_drag and not Run.annex_dragging(off,"a"),"the default catch has no dragged player")
	var baseline := tick(off,[false,false])
	t.check(dist(baseline.players[0].body,off.players[0].body) <= 0.6*DT+0.000001,"default off stays ordinary crawl")
	var off_stillness := setup(false,false)
	var before := off_stillness.orderly.anim_time
	var ordinary_bend := tick(off_stillness,[true,true])
	t.check(ordinary_bend.orderly.held and ordinary_bend.orderly.anim_time > before, "ordinary default-off bends retain their watched presentation")
	var rescue := setup(true,true)
	for i in 62:
		rescue = tick(rescue,[false,false],true)
	t.check(rescue.players[0].status == &"ok" and not Run.annex_dragging(rescue,"a"),"three-second valid F hold always frees them")
	t.check(rescue.orderly.bend_target == null,"heal releases the Temp")
	var waiting := setup(true,true)
	var last: Move.Body = waiting.players[0].body
	for i in 200:
		last = waiting.players[0].body
		waiting = tick(waiting,[false,false])
	t.check(waiting.players[0].status == &"out" and not Run.annex_dragging(waiting,"a"),"an unrescued victim still expires in 10 seconds")
	t.check(waiting.orderly.bend_target == null and dist(last,waiting.players[0].body)<0.000001,"timeout releases before same-tick movement")
	t.check(waiting.spots.size()==1,"existing drop/red-spot flow fires at the final authoritative position")

func test_annex_catch_marks_only_the_enabled_resident_catch(t: T) -> void:
	var hit := {"type": "caught", "playerId": "a"}
	for lonely: bool in [false, true]:
		t.check(Run._annex_catch_event(setup(true, lonely), hit).get("annexStaple", false), "both Annex residents carry the cue")
		t.eq(Run._annex_catch_event(setup(false, lonely), hit), hit, "off leaves the catch event unchanged")
	var other := Run.with_annex_drag(Run.with_downs(Run._create_run("clinic", ["a","b"], Places.FULL, 2)))
	t.eq(Run._annex_catch_event(other, hit), hit, "Clinic catch is unchanged")
	var noise := {"type": "windUp", "playerId": "a"}
	t.eq(Run._annex_catch_event(setup(true, false), noise), noise, "a wind-up is never a catch")
	t.check(not hit.has("annexStaple"), "the original resident event is untouched")

func test_annex_catch_schedules_three_distinct_recorded_clicks(t: T) -> void:
	var audio := preload("res://client/sfx.gd").new()
	audio._place = "annex"
	for name: String in ["catch_staple_1", "catch_staple_2", "catch_staple_3"]:
		audio.recorded[name] = {}
	for mine: bool in [true, false]:
		var at := Vector3(3, 1, 9)
		audio.caught(mine, at, true)
		var pending: Array = audio._later
		if t.eq(pending.size(), 3, "only three catch clicks are queued"):
			t.eq(pending.map(func(l: Dictionary) -> String: return str(l.name)),
				["catch_staple_1", "catch_staple_2", "catch_staple_3"], "each click uses a different recorded take")
			t.eq(pending[2].at - pending[0].at, 360, "the clicks have separate onsets")
			t.eq(pending[0].pos, null if mine else at, "the witness cue remains spatial")
		pending.clear()
	audio.caught(false, Vector3.ZERO, false)
	t.check(audio._later.is_empty(), "the old catch never creates the new clicks")
	audio._place = "clinic"
	audio.caught(true, null, true)
	t.check(audio._later.is_empty(), "a tagged cue delivered away from Annex never creates the clicks")
	audio.free()
