# A look at the Playroom (client/playroom_view.gd) and the stand-in Minder (client/minder_view.gd) in
# the game's own picture: a seeded Playroom built by Level from sim/playroom.gd's plan, the 480x270
# view through the tape shader, in a window (it never captures the mouse). Every check prints
# "playroom demo: CHECK <name> PASS|FAIL ..." and the last line is "playroom demo json: {...}"; the
# exit code is 0 only when all pass.
#   rules    on this floor and twelve more (play-0..2 at depths 1 to 4): every hide's furniture within
#            5 cm of its Playroom.hides inside spot; every squeaker tile in the rules drawn, no other;
#            every zone's signs reading its hide count from the rules; real lights under the limit
#            (PlayroomView.check)
#   dark     the count-dark flag: every real light and strip light out, the glow-in-the-dark things on
#   figure   about 2.3 m standing; the fingertips below the knees; one mask, on the front of the head,
#            facing forward; on all fours it is low and its hands are at the floor; counting, both
#            hands are on the mask
#   hold     not a Stillness resident: handed a held pose while the snapshots move, it draws the
#            snapshots' pose, a different picture on every frame the camera sees it
#   music    one note per 0.5 m walked (three per 1.5 m), silent beyond 30 m and heard inside it, on
#            the Entity bus or else Sfx
#   frames   frame time walking the Playroom within the Clinic's of the same seed and depth (10 %
#            and 0.5 ms)
# Pictures (shots=DIR): the ball-pit hall, a party room and its sign, count dark, the Minder front
# and side, upright and on all fours, and more. The release build loads it with
# `GoingDown.exe -- scene=playroom_demo` (main.gd); tools/playroom_walk.mjs runs it on the project.
# Arguments after `--`: shots=DIR seed=play-1 depth=4 bench=5 (seconds per walk, 0 = none)
# rounds=2 break=sign|squeak (PlayroomView.test_break: the rules check must go red).
extends Node

const Playroom = preload("res://sim/playroom.gd")
const Clinic = preload("res://sim/clinic.gd")
const Floor = preload("res://sim/floor.gd")
const Run = preload("res://sim/run.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const PlayroomView = preload("res://client/playroom_view.gd")
const AnnexView = preload("res://client/annex_view.gd")
const AnnexDemo = preload("res://client/annex_demo.gd")
const VFOV := 70.0
const EYE := 1.65
const S := 2.0
const LH := 3.2

## A stand-in for the network client the Minder reads its un-held pose from (net/client.gd's
## _rt, _bracket and local_depth): two snapshots ({depth, orderly: pose, ...}) that move every frame.
class FakeClient:
	extends RefCounted
	var _rt: Variant = 1.0
	var local_depth := 4
	var a: Dictionary = {}
	var b: Dictionary = {}
	func _bracket(_rt_now: float) -> Array:
		return [a, b, 0.5]

class FakeLink:
	extends RefCounted
	var c := FakeClient.new()
	func client() -> Object:
		return c

var sub: SubViewport
var cam: Camera3D
var world: Node3D
var env: Environment
var level: Level
var lift: Lift
var view: Node3D
var minder: MinderView
var fp: Floor.FloorPlan
var shots_dir := "user://playroom_shots"
var seed_text := "play-1"
var depth := 4
var bench := 5.0
var rounds := 2
var light := 1.0
var emergency := 0.0
var report := {}
var checks := {}
var problems: Array[String] = []
var shot_lines: Array[String] = []

func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		var key := a.get_slice("=", 0)
		var val := a.substr(key.length() + 1)
		match key:
			"shots": shots_dir = val
			"seed": seed_text = val
			"depth": depth = int(val)
			"bench": bench = float(val)
			"rounds": rounds = int(val)
			"break": PlayroomView.test_break = val
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	AudioServer.set_bus_volume_db(0, -18.0)
	_build_view()
	_run.call_deferred()

func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(480, 270)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_DISABLED
	sub.positional_shadow_atlas_size = 2048
	sub.audio_listener_enable_3d = true
	add_child(sub)
	get_viewport().disable_3d = true
	# The game's own environment (main.gd _build_view).
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.025, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.6)
	env.ambient_light_energy = 0.12
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.06, 0.06)
	env.fog_density = 0.035
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_hdr_threshold = 0.9
	we.environment = env
	sub.add_child(we)
	world = Node3D.new()
	sub.add_child(world)
	cam = Camera3D.new()
	cam.fov = VFOV
	cam.near = 0.05
	cam.far = 60.0
	sub.add_child(cam)
	cam.current = true
	var screen := TextureRect.new()
	screen.texture = sub.get_texture()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var tape := ShaderMaterial.new()
	tape.shader = load("res://client/tape.gdshader")
	screen.material = tape
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(screen)

static func playroom_plan(s: String, d: int) -> Dictionary:
	var p := Playroom.generate_playroom(s, d)
	return PlanDump.dump(p, Run.car_geometry(p))

static func clinic_plan(s: String, d: int) -> Dictionary:
	var p := Clinic.generate_clinic(s, d)
	return PlanDump.dump(p, Run.car_geometry(p))

func _build(plan: Dictionary) -> void:
	if level:
		level.free()
		lift.free()
	level = Level.new()
	level.shadows = true
	world.add_child(level)
	level.build(plan, seed_text)
	lift = Lift.new()
	world.add_child(lift)
	lift.build(plan["car"])
	lift.set_doors(true, true)
	view = level.get_meta("playroom") if level.has_meta("playroom") else null
	light = 1.0
	emergency = 0.0
	level.set_light_level(1.0)
	level.set_emergency(0.0)

func _process(delta: float) -> void:
	if level:
		level.set_light_level(light)
		level.set_emergency(emergency)
		level.update_lights(delta, cam.global_position)
		env.ambient_light_color = level.ambient_color(emergency)
	var dark := 0.0
	if view != null:
		dark = float(view.get("count_dark"))
	env.ambient_light_energy = lerpf(0.12, 0.03, maxf(emergency, dark)) * maxf(light * (1.0 - dark), 0.25)
	env.background_color = Color(0.02, 0.025, 0.025) * light * (1.0 - dark)

func _check(name: String, ok: bool, what: String) -> void:
	checks[name] = {"pass": ok, "what": what}
	print("playroom demo: CHECK %s %s %s" % [name, "PASS" if ok else "FAIL", what])
	if not ok:
		problems.append("%s: %s" % [name, what])

# --- the rules check ---------------------------------------------------------------------------

func _rules_check() -> void:
	var all: Array[String] = []
	var stats := {}
	all.append_array(view.call(&"check", stats))
	report["rules_demo_floor"] = stats
	var floors := 1
	var hides := int(stats.hides)
	var squeak := int(stats.squeakers_rules)
	var signs := int(stats.signs)
	var max_lights := int(stats.lights)
	var worst := float(stats.max_offset_cm)
	for i in 3:
		for d in range(1, 5):
			var s := "play-%d" % i
			var lv := Level.new()
			lv.build(playroom_plan(s, d), s)
			var v: Object = lv.get_meta("playroom")
			var st := {}
			all.append_array(v.call(&"check", st))
			floors += 1
			hides += int(st.hides)
			squeak += int(st.squeakers_rules)
			signs += int(st.signs)
			max_lights = maxi(max_lights, int(st.lights))
			worst = maxf(worst, float(st.max_offset_cm))
			lv.free()
	report["rules"] = {"floors": floors, "hides": hides, "squeakers": squeak, "signs": signs, "max_lights": max_lights, "max_offset_cm": worst, "problems": all.slice(0, 40)}
	for p: String in all.slice(0, 12):
		print("playroom demo:   ", p)
	_check("rules", all.is_empty(), "%d floors: %d hides' furniture (at most %.2f cm off), %d squeaker tiles, %d signs, at most %d real lights a floor (limit %d)%s" % [
		floors, hides, worst, squeak, signs, max_lights, PlayroomView.LIGHT_LIMIT, "" if all.is_empty() else "; %d problems" % all.size()])
	var dark: Array[String] = view.call(&"check_dark")
	_check("dark", dark.is_empty(), "the count-dark flag: lit, dark, lit again%s" % ("" if dark.is_empty() else ": " + "; ".join(dark)))

# --- the Minder's checks --------------------------------------------------------------------------

static func pose_at(p: Vector3, level_i: int, yaw: float, anim: String, t := 0.0) -> Dictionary:
	return {"x": p.x, "y": p.y, "z": p.z, "level": level_i, "yaw": yaw, "anim": anim, "animTime": t}

static func yaw_facing(f: Vector3) -> float:
	return atan2(-f.x, -f.z)

func _minder_checks() -> void:
	var spot := Vector3(0, 0, 0)
	minder.reset()
	minder.show_pose(pose_at(spot, 0, 0.0, "stand"), true)
	var e := minder.extent()
	var top := e.end.y
	var wrist := minder.fingertip_y()
	var knee := minder.joint_point("knee_l").y
	var mask: Dictionary = minder.mask_info()
	var head: Vector3 = mask.head
	var at: Vector3 = mask.at
	var facing: Vector3 = mask.facing
	minder.show_pose(pose_at(spot, 0, 0.0, "prowl"), true)
	var e4 := minder.extent()
	var hand4 := minder.joint_point("hand_l").y
	var kind4 := minder.body_kind
	minder.show_pose(pose_at(spot, 0, 0.0, "cover"), true)
	var kindc := minder.body_kind
	var mc: Dictionary = minder.mask_info()
	var mca: Vector3 = mc.at
	var reach := maxf(minder.hand_middle("hand_l").distance_to(mca), minder.hand_middle("hand_r").distance_to(mca))
	report["figure"] = {"height": top, "fingertip_y": wrist, "knee_y": knee, "mask_count": mask.count, "mask_ahead": at.z - head.z, "fours_top": e4.end.y, "fours_hand_y": hand4, "cover_hands_to_mask": reach}
	var ok := top >= 2.1 and top <= 2.45 and wrist < knee and int(mask.count) == 1 and at.z - head.z > 0.25 and facing.z > 0.9 \
		and e4.end.y < 1.6 and hand4 < 0.25 and kind4 == "fours" and kindc == "cover" and reach < 0.3
	_check("figure", ok, "standing %.2f m tall; fingertips %.2f m, knee %.2f m; %d mask, %.2f m in front of the head, facing %s; on all fours %.2f m tall, hands at %.2f m; counting, the middle of both hands within %.2f m of the mask" % [
		top, wrist, knee, int(mask.count), at.z - head.z, facing, e4.end.y, hand4, reach])
	# The hold: a held pose handed in (as net/client.gd hands one in while the camera sees it) and
	# snapshots that keep moving. The Minder draws the snapshots' pose: a new picture every frame.
	var room := Playroom.party_room(fp)
	var c := Vector3((room.x + room.w * 0.5) * S, room.level * LH, (room.y + room.h * 0.5) * S)
	var link := FakeLink.new()
	minder.reset()
	minder.follow(link)
	var held := pose_at(c, room.level, 0.0, "walk", 0.0)
	_look(c + Vector3(0, EYE, 4.0), c + Vector3(0, 1.2, 0))
	var sigs: Array[String] = []
	var unheld0 := minder.unheld_frames
	var seen := 0
	for i in 20:
		var p := c + Vector3(0.05 * i, 0, 0)
		link.c.a = {"depth": link.c.local_depth, "orderly": pose_at(p, room.level, 0.0, "walk", i * 0.05)}
		link.c.b = {"depth": link.c.local_depth, "orderly": pose_at(p + Vector3(0.05, 0, 0), room.level, 0.0, "walk", i * 0.05 + 0.05)}
		minder.show_pose(held, true)
		await get_tree().process_frame
		if cam.is_position_in_frustum(minder.global_position + Vector3(0, 1.2, 0)):
			seen += 1
		sigs.append(minder.drawn_signature())
	var changed := 0
	for i in range(1, sigs.size()):
		if sigs[i] != sigs[i - 1]:
			changed += 1
	var follows := minder.unheld_frames - unheld0
	# The same held pose without a link to follow stays put: the check can tell the difference.
	minder.follow(null)
	var still_sigs: Array[String] = []
	for i in 3:
		minder.show_pose(held, true)
		still_sigs.append(minder.drawn_signature())
	var still := still_sigs[0] == still_sigs[1] and still_sigs[1] == still_sigs[2]
	report["hold"] = {"frames": sigs.size(), "seen": seen, "changed": changed, "unheld_frames": follows, "held_without_link_is_still": still}
	_check("hold", not MinderView.STILLNESS and seen == sigs.size() and changed == sigs.size() - 1 and follows == sigs.size() and still,
		"not Stillness; in view on %d of %d frames, a new picture on %d of %d, drawn from the snapshots on %d (a held pose alone stays still: %s)" % [
		seen, sigs.size(), changed, sigs.size() - 1, follows, still])
	# The music box: walking 40 m straight at the camera along a line, from 40 m away to 0.
	minder.reset()
	minder.notes.clear()
	var ear := Vector3(1000, 1.6, 1000)
	_look(ear, ear + Vector3(0, 0, -1))
	await get_tree().process_frame
	var plan_keep: Variant = minder.get("_plan")
	minder.set("_plan", null)
	var walked := 0.0
	var prev := ear + Vector3(0, -1.6, -40.0)
	for i in 801:
		var p := ear + Vector3(0, -1.6, -40.0 + i * 0.05)
		walked += p.distance_to(prev) if i > 0 else 0.0
		prev = p
		minder.show_pose(pose_at(p, 0, 0.0, "walk"), true)
	minder.set("_plan", plan_keep)
	var far := 0
	var near := 0
	var bad := 0
	for n: Dictionary in minder.notes:
		var d := (n.at as Vector3).distance_to(ear)
		if d > MinderView.HEAR_RANGE + 0.01:
			far += 1
			if float(n.gain) > 0.0:
				bad += 1
		else:
			near += 1
			if float(n.gain) <= 0.0 and d < MinderView.HEAR_RANGE - 0.5:
				bad += 1
	var want := floori(walked / MinderView.NOTE_STEP + 1e-6)
	var bus := String(MinderView.bus_name())
	var player: AudioStreamPlayer3D = minder.get_node("MusicBox")
	report["music"] = {"walked": walked, "notes": minder.notes.size(), "want": want, "beyond_30m": far, "within_30m": near, "wrong_gain": bad, "bus": String(player.bus)}
	_check("music", minder.notes.size() == want and bad == 0 and far > 0 and near > 0 and (bus == "Entity" or bus == "Sfx") and String(player.bus) == bus,
		"%d notes over %.1f m (want %d, three per 1.5 m); %d beyond 30 m all silent, %d within heard; bus %s" % [minder.notes.size(), walked, want, far, near, String(player.bus)])

# --- pictures -------------------------------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _look(from: Vector3, to: Vector3) -> void:
	cam.position = from
	cam.look_at(to, Vector3.UP)

func _grab() -> Image:
	await _frames(4)
	return get_viewport().get_texture().get_image()

func _shot(shot_name: String, what: String) -> void:
	var img: Image = await _grab()
	var path := shots_dir.path_join(shot_name + ".png")
	var err := img.save_png(path)
	shot_lines.append("%s.png %s: %s" % [shot_name, "ok" if err == OK else "FAILED", what])

func _first_room(kind: String, level_i := 0) -> Floor.Room:
	var best: Floor.Room = null
	var best_d := INF
	var lc := Vector2(fp.landing.x, fp.landing.y)
	for r in fp.rooms:
		if r.kind == StringName(kind) and r.level == level_i:
			var d := Vector2(r.x + r.w * 0.5, r.y + r.h * 0.5).distance_to(lc)
			if d < best_d:
				best_d = d
				best = r
	return best

## The room's first way in from a walkway: [the room-side cell centre, the walkway-side cell centre].
func _way_in(r: Floor.Room) -> Array:
	for d in fp.doors:
		if d.level != r.level:
			continue
		var a_in := Floor.room_id_at(fp, d.level, d.ax, d.ay) == r.id
		var b_in := Floor.room_id_at(fp, d.level, d.bx, d.by) == r.id
		if a_in and level.kind(d.level, d.bx, d.by) == "corridor":
			return [level.cell_center(d.level, d.ax, d.ay), level.cell_center(d.level, d.bx, d.by)]
		if b_in and level.kind(d.level, d.ax, d.ay) == "corridor":
			return [level.cell_center(d.level, d.bx, d.by), level.cell_center(d.level, d.ax, d.ay)]
	return []

func _room_centre(r: Floor.Room) -> Vector3:
	return Vector3((r.x + r.w * 0.5) * S, r.level * LH, (r.y + r.h * 0.5) * S)

func _pictures() -> void:
	DirAccess.make_dir_recursive_absolute(shots_dir)
	minder.visible = false
	await _frames(10)
	# 1. The ball-pit hall from its way in.
	var pit := _first_room("ballpit")
	if pit != null:
		var w := _way_in(pit)
		var c := _room_centre(pit)
		if not w.is_empty():
			var inside: Vector3 = w[0]
			var into := (c - inside).normalized()
			_look(inside - into * 0.6 + Vector3(0, EYE, 0), c + Vector3(0, 0.6, 0))
			await _shot("ballpit_hall", "the ball-pit hall from its way in")
			emergency = 0.0
			view.call(&"set_count_dark", 1.0)
			await _frames(4)
			await _shot("count_dark_hall", "the same view in count dark: stars on the ceiling, lines on the mats, nothing else lit")
			view.call(&"set_count_dark", 0.0)
	# 2. A party room's sign over its way in, from the walkway; then the party room inside.
	var party := Playroom.party_room(fp)
	if party != null:
		var w := _way_in(party)
		if not w.is_empty():
			var inside: Vector3 = w[0]
			var outside: Vector3 = w[1]
			var out := (outside - inside).normalized()
			var side := Vector3(-out.z, 0, out.x)
			var along := side if level.kind(party.level, int((outside + side * S).x / S), int((outside + side * S).z / S)) == "corridor" else -side
			_look(outside + out * 0.5 + along * 3.2 + Vector3(0, EYE, 0), (inside + outside) * 0.5 + Vector3(0, 1.9, 0))
			await _shot("party_sign", "the far party room's way in and its sign, from the walkway")
			for s: Dictionary in view.get("signs"):
				var p: Vector3 = s.pos
				if p.distance_to((inside + outside) * 0.5 + Vector3(0, p.y - inside.y, 0)) < 0.6:
					var f: Vector3 = s.facing
					_look(p + f * 1.4 + Vector3(0, -0.5, 0), p)
					await _shot("sign_close", "the sign itself: %s" % s.text)
					break
			var c := _room_centre(party)
			_look(inside + (inside - c).normalized() * 0.2 + Vector3(0, EYE, 0), c + Vector3(0, 0.5, 0))
			await _shot("party_room", "inside the far party room: the table laid, the seats, bunting")
	# 3. The Minder, front and side, upright and on all fours, in the party room.
	if party != null:
		var c := _room_centre(party)
		var w := _way_in(party)
		var to_door := Vector3(0, 0, 1)
		if not w.is_empty():
			to_door = (w[0] as Vector3) - c
			to_door.y = 0
			to_door = to_door.normalized()
		var side := Vector3(-to_door.z, 0, to_door.x)
		var at := c + to_door * 0.6
		minder.reset()
		minder.follow(null)
		minder.visible = true
		var yaw := yaw_facing(to_door)
		minder.show_pose(pose_at(at, party.level, yaw, "stand", 1.0), true)
		_look(at + to_door * 3.4 + Vector3(0, 1.45, 0), at + Vector3(0, 1.35, 0))
		await _shot("minder_front", "the Minder from the front: the card mask with its smiley")
		_look(at + side * 3.4 + Vector3(0, 1.45, 0), at + Vector3(0, 1.3, 0))
		await _shot("minder_side", "the Minder from the side: stooped, arms past its knees")
		_look(at - to_door * 2.6 + side * 0.8 + Vector3(0, 1.6, 0), at + Vector3(0, 1.5, 0))
		await _shot("minder_back", "the Minder from behind: nothing on the back of its head")
		minder.reset()
		minder.show_pose(pose_at(at, party.level, yaw, "prowl", 1.0), true)
		minder.show_pose(pose_at(at + to_door * 0.4, party.level, yaw, "prowl", 1.2), true)
		_look(at + side * 3.6 + Vector3(0, 1.1, 0), at + Vector3(0, 0.6, 0))
		await _shot("minder_fours_side", "the Minder on all fours, from the side")
		_look(at + to_door * 3.6 + side * 0.6 + Vector3(0, 1.0, 0), at + Vector3(0, 0.7, 0))
		await _shot("minder_fours_front", "the Minder on all fours, coming")
		minder.reset()
		minder.show_pose(pose_at(at, party.level, yaw + PI, "cover", 1.0), true)
		_look(at + side * 2.8 + to_door * 1.6 + Vector3(0, 1.4, 0), at + Vector3(0, 0.8, 0))
		await _shot("minder_cover", "the Minder counting: crouched, hands over the mask")
		minder.reset()
		minder.show_pose(pose_at(at, party.level, yaw, "stand", 2.0), true)
		_look(at + to_door * 3.4 + Vector3(0, 1.45, 0), at + Vector3(0, 1.35, 0))
		view.call(&"set_count_dark", 1.0)
		await _frames(4)
		await _shot("minder_dark", "the Minder in count dark: only the mask glows")
		view.call(&"set_count_dark", 0.0)
		minder.visible = false
	# 4. The shoe room by the lift: PLAY NICELY, the height chart, SOCKS MUST BE WORN.
	var lobby := _first_room("lobby")
	if lobby != null:
		var lc := level.cell_center(fp.landing.level, fp.landing.x, fp.landing.y)
		var v := level._dir_vec(level.lift_dir)
		var out := Vector3(v.x, 0, v.y)
		_look(lc - out * 1.9 + Vector3(0, EYE, 0), lc + out * 1.0 + Vector3(0, 1.4, 0))
		await _shot("lobby_lift", "the shoe room's lift wall: the height chart, SOCKS MUST BE WORN, the EXIT sign")
		_look(lc + out * 0.4 + Vector3(0, EYE, 0), lc - out * 3.0 + Vector3(0, 1.8, 0))
		await _shot("lobby", "the shoe room from the lift: PLAY NICELY")
	# 5. A toddler corner (squeaker tiles, playhouses) and a cloakroom (cubbies).
	for kind: String in ["toddler", "cloak", "den"]:
		var r := _first_room(kind)
		if r == null:
			continue
		var w := _way_in(r)
		if w.is_empty():
			continue
		var inside: Vector3 = w[0]
		var c := _room_centre(r)
		_look(inside - (c - inside).normalized() * 0.5 + Vector3(0, EYE, 0), c + Vector3(0, 0.3, 0))
		await _shot("room_" + kind, "a %s room from its way in" % kind)
	# 6. The upper deck: across a ball pit's opening through the netting.
	for r in fp.rooms:
		if r.kind != &"ballpit":
			continue
		var c := _room_centre(r)
		var best := Vector2i(-1, -1)
		var best_d := INF
		for y in range(r.y - 1, r.y + r.h + 1):
			for x in range(r.x - 1, r.x + r.w + 1):
				if level.kind(1, x, y) != "corridor":
					continue
				var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(c.x, c.z) / S)
				if d < best_d:
					best_d = d
					best = Vector2i(x, y)
		if best.x < 0:
			continue
		var p := level.cell_center(1, best.x, best.y)
		var out := Vector3(p.x - c.x, 0, p.z - c.z).normalized()
		_look(p + out * 0.5 + Vector3(0, EYE, 0), c - out * 2.0 + Vector3(0, 0.3, 0))
		await _shot("upper_deck", "the upper deck: the netting round a ball pit's opening, the pit below")
		break
	# 7. A walkway junction, lit and in count dark.
	var js: Array = view.get("junctions")
	for j: Dictionary in js:
		if int(j.level) != 0:
			continue
		var cell: Vector2i = j.cell
		var jc := level.cell_center(0, cell.x, cell.y)
		if jc.distance_to(level.cell_center(0, fp.landing.x, fp.landing.y)) < 12.0:
			continue
		var dir := Vector3(1, 0, 0)
		for d: Vector2i in AnnexView.DIRS:
			if level.kind(0, cell.x + d.x * 3, cell.y + d.y * 3) == "corridor" and level.kind(0, cell.x + d.x, cell.y + d.y) == "corridor":
				dir = Vector3(d.x, 0, d.y)
				break
		_look(jc - dir * 3.0 + Vector3(0, EYE, 0), jc + dir * 6.0 + Vector3(0, 1.2, 0))
		await _shot("walkway", "a walkway near the middle: strip lights, mat lines, squeaker tiles, signs")
		view.call(&"set_count_dark", 1.0)
		await _frames(4)
		await _shot("count_dark_walkway", "the same walkway in count dark")
		view.call(&"set_count_dark", 0.0)
		break

# --- frame times ------------------------------------------------------------------------------

## A walk on level 0 from the landing to the farthest corridor cell (breadth first over open edges and
## doors), as eye-height cell centres.
func _route() -> Array[Vector3]:
	var w := level.W
	var h := level.H
	var start := Vector2i(level.landing.y, level.landing.z)
	var prev := {start: start}
	var queue: Array[Vector2i] = [start]
	var last := start
	var qi := 0
	while qi < queue.size():
		var c := queue[qi]
		qi += 1
		if level.kind(0, c.x, c.y) == "corridor":
			last = c
		for d: Vector2i in AnnexView.DIRS:
			var n := c + d
			if n.x < 0 or n.y < 0 or n.x >= w or n.y >= h or prev.has(n):
				continue
			if not level.walkable(0, n.x, n.y) or level.kind(0, n.x, n.y) == "stair":
				continue
			var e := _edge(c, d)
			if e != "open" and e != "door":
				continue
			prev[n] = c
			queue.append(n)
	var path: Array[Vector3] = []
	var at := last
	while at != start:
		path.push_front(level.cell_center(0, at.x, at.y) + Vector3(0, EYE, 0))
		at = prev[at]
	path.push_front(level.cell_center(0, start.x, start.y) + Vector3(0, EYE, 0))
	return path

func _edge(c: Vector2i, d: Vector2i) -> String:
	var vert: Array = level.edges[0].vertical
	var hor: Array = level.edges[0].horizontal
	var w := level.W
	if d == Vector2i(0, -1): return hor[c.y * w + c.x]
	if d == Vector2i(0, 1): return hor[(c.y + 1) * w + c.x]
	if d == Vector2i(-1, 0): return vert[c.y * (w + 1) + c.x]
	return vert[c.y * (w + 1) + c.x + 1]

## Walks the route for `secs` at 3 m/s (back again at the end) and returns the frame times in ms.
func _walk(secs: float) -> PackedFloat64Array:
	var path := _route()
	var times := PackedFloat64Array()
	var dist := 0.0
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i].distance_to(path[i - 1])
	var t_end := Time.get_ticks_usec() + int((secs + 1.0) * 1e6)
	var t_warm := Time.get_ticks_usec() + 1000000
	var last := Time.get_ticks_usec()
	var yaw := 0.0
	var first := true
	while Time.get_ticks_usec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		if now > t_warm:
			times.append(dt * 1000.0)
		dist += 3.0 * minf(dt, 0.1)
		var along := fmod(dist, 2.0 * total)
		if along > total:
			along = 2.0 * total - along
		var pos := path[0]
		var ahead := path[path.size() - 1]
		var acc := 0.0
		for i in range(1, path.size()):
			var seg := path[i].distance_to(path[i - 1])
			if acc + seg >= along:
				var k := (along - acc) / maxf(seg, 0.001)
				pos = path[i - 1].lerp(path[i], k)
				ahead = path[mini(i + 1, path.size() - 1)]
				break
			acc += seg
		var dir := ahead - pos
		var want := atan2(-dir.x, -dir.z) if dir.length() > 0.01 else yaw
		yaw = want if first else lerp_angle(yaw, want, minf(1.0, dt * 4.0))
		first = false
		cam.position = pos
		cam.rotation = Vector3(-0.05, yaw, 0)
	return times

func _bench() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	minder.visible = false
	var all := {"playroom": PackedFloat64Array(), "clinic": PackedFloat64Array()}
	var info := {}
	for r in rounds:
		for place: String in ["playroom", "clinic"]:
			_build(playroom_plan(seed_text, depth) if place == "playroom" else clinic_plan(seed_text, depth))
			await _frames(5)
			var times: PackedFloat64Array = await _walk(bench)
			var sofar: PackedFloat64Array = all[place]
			sofar.append_array(times)
			all[place] = sofar
			info[place] = {"lights": level.main_lights.size(), "emergency_lights": level.emergency_lights.size(),
				"draw_calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				"primitives": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)}
			var s := AnnexDemo.summary(times)
			print("playroom demo: bench round %d %s: %d frames, mean %.2f ms, p95 %.2f ms" % [r + 1, place, s.frames, s.mean_ms, s.p95_ms])
	for place: String in ["playroom", "clinic"]:
		var s := AnnexDemo.summary(all[place])
		s.merge(info[place])
		report["bench_" + place] = s
	var p: Dictionary = report.bench_playroom
	var c: Dictionary = report.bench_clinic
	var ok := float(p.mean_ms) <= maxf(float(c.mean_ms) * 1.1, float(c.mean_ms) + 0.5) and float(p.p95_ms) <= maxf(float(c.p95_ms) * 1.1, float(c.p95_ms) + 0.5)
	_check("frames", ok, "walking the Playroom: mean %.2f ms, p95 %.2f ms, %d lights, %d draw calls; the Clinic: mean %.2f ms, p95 %.2f ms, %d lights, %d draw calls" % [
		p.mean_ms, p.p95_ms, p.lights, p.draw_calls, c.mean_ms, c.p95_ms, c.lights, c.draw_calls])

func _run() -> void:
	var t0 := Time.get_ticks_msec()
	fp = Playroom.generate_playroom(seed_text, depth)
	_build(PlanDump.dump(fp, Run.car_geometry(fp)))
	report["build_ms"] = Time.get_ticks_msec() - t0
	report["seed"] = seed_text
	report["depth"] = depth
	report["break"] = PlayroomView.test_break
	report["lights"] = level.main_lights.size() + level.emergency_lights.size()
	print("playroom demo: floor %s depth %d built in %d ms: %d real lights (%d emergency), %d hides, %d squeaker tiles, %d zones, %d signs" % [
		seed_text, depth, report.build_ms, level.main_lights.size(), level.emergency_lights.size(), (view.get("furniture") as Array).size(),
		(view.get("squeaker_tiles") as PackedInt32Array).size(), (view.get("zones") as Array).size(), (view.get("signs") as Array).size()])
	minder = MinderView.new()
	minder.name = "Minder"
	sub.add_child(minder)
	minder.set_floor(fp, level)
	_rules_check()
	await _minder_checks()
	await _pictures()
	report["shots"] = shot_lines
	for l in shot_lines:
		print("playroom demo: shot ", l)
	if bench > 0.0:
		await _bench()
	report["checks"] = checks
	report["problems"] = problems
	print("playroom demo json: ", JSON.stringify(report))
	get_tree().quit(0 if problems.is_empty() else 1)
