# The chase in numbers (ported from tests/sim/stamina.test.ts): the Orderly is faster than a walk
# and slower than a sprint, and a tired player cycling run and walk only just outpaces it.
extends RefCounted

const T = preload("res://tests/t.gd")
const Stamina = preload("res://sim/stamina.gd")
const Entity = preload("res://sim/entity.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 1.0 / 20.0

static func run(st: Stamina.Stamina, seconds: float, gait: StringName, speed: float) -> Stamina.Stamina:
	var t := 0.0
	while t < seconds - 1e-9:
		st = Stamina.step_stamina(st, gait, speed, DT)
		t += DT
	return st

func test_tank(t: T) -> void:
	var st := run(Stamina.fresh_stamina(), Stamina.SPRINT_SECONDS - 0.2, &"sprint", Stamina.SPRINT_SPEED)
	t.check(not st.winded, "winded too early")
	st = run(st, 0.4, &"sprint", Stamina.SPRINT_SPEED)
	t.check(st.level == 0.0 and st.winded, "a full tank sprints for SPRINT_SECONDS")
	t.eq(Stamina.gait_for(st, true, false, true, INF), &"walk", "winded cannot sprint")
	var w := run(Stamina.Stamina.make(0.0, true), Stamina.RECOVER_WALKING * Stamina.WINDED_UNTIL - 0.3, &"walk", Stamina.WALK_SPEED)
	t.eq(Stamina.gait_for(w, true, false, true, INF), &"walk", "still winded")
	w = run(w, 0.6, &"walk", Stamina.WALK_SPEED)
	t.eq(Stamina.gait_for(w, true, false, true, INF), &"sprint", "past the mark")
	t.check(run(Stamina.fresh_stamina(), 3.0, &"sprint", 0.0).level == 1.0, "sprinting into a wall costs nothing")
	t.eq(Stamina.gait_for(Stamina.fresh_stamina(), true, false, true, 2.2), &"walk", "a capped player cannot sprint")

func test_the_orderly_against_a_fleeing_player(t: T) -> void:
	t.check(Entity.HUNT_SPEED > Stamina.WALK_SPEED and Entity.HUNT_SPEED < Stamina.SPRINT_SPEED, "faster than a walk, slower than a sprint")
	var flee := Stamina.sustained_flee_speed()
	t.check(flee > Entity.HUNT_SPEED and flee - Entity.HUNT_SPEED < 0.3, "a tired player only just outpaces it: %s" % flee)
	var st := Stamina.fresh_stamina()
	var fled := 0.0
	var tt := 0.0
	while tt < 60.0:
		var gait := Stamina.gait_for(st, true, false, true, INF)
		var v := Stamina.speed_for(gait)
		fled += v * DT
		st = Stamina.step_stamina(st, gait, v, DT)
		tt += DT
	var hunted := Entity.HUNT_SPEED * 60.0
	t.check(fled > hunted and fled - hunted < 25.0 and Stamina.WALK_SPEED * 60.0 < hunted, "60 s: fled %s, hunted %s" % [fled, hunted])
	t.note("sustained flee %s m/s against %s (TypeScript prints 3.769 against 3.7); 60 s: fled %s m, the Orderly %s m (TypeScript: 231.9, 222.0)" % [
		M.to_fixed(flee, 3), Entity.HUNT_SPEED, M.to_fixed(fled, 1), M.to_fixed(hunted, 1)])
