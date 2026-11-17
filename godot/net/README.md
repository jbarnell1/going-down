# The network layer

A port of `src/net` (the old browser game's networking) to typed GDScript, proved the same by
`tests/ref_net.gd` (every message, every client frame and every host tick of seven scripted sessions
against the TypeScript) and `tests/prop_net.gd` (the fairness rules of `tests/net/rule.test.ts`
over bot sessions on a hostile network, counts equal to TypeScript's). What changed from the old
game: the host is the home server (`server/`), not a player's browser; the transport is a
WebSocket to that server; nothing else. The game uses it alone too: `local_room.gd` is the same host
and client in one process, so there is one way to play.

```
jsjson.gd       JSON exactly as JavaScript writes and reads it (Godot's own float text is not exact)
protocol.gd     the messages (protocol.ts): encode, decode (validates everything), the wire forms
session.gd      constants, floor plans and cars, move_local, camera_sees, HostClock (session.ts)
pose.gd         q2, q3, lerp_pose, same_pose, Camera, camera_sees (moved here from client/)
host_rules.gd   the game's rules around the run: start spots, the soft catch (moved here from client/)
host.gd         NetHost: the authoritative host (host.ts); the server runs it
client.gd       NetClient: the own body moved locally by the game with the rules (instant), interpolation, the pose hold, the put-back pin,
                the taken latch, blink guards, inputs, the tank (client.ts)
transport.gd    the Transport interface, MemoryNetwork (seeded delay/jitter/loss for tests), Pipe
room_client.gd  what the game uses: the WebSocket to the server, the passphrase, the lobby, a NetClient per run;
                bytes_in / bytes_out (what a player costs the link)
local_room.gd   playing alone: a RoomClient running host.gd + host_rules.gd in-process over two
                Transport.Pipes (the local player's body trusted, a run at once, `time_scale` for tests)
ws_server.gd    the server's door (passphrase, limits)
```

## Emotes

Two messages beside the run's (they never touch the run, and the scripted sessions of `ref_net` and
`prop_net` never send them):

- `[1, "E", k]` client to host: this player plays emote `k`, an index into `Protocol.EMOTES`
  (`wave`, `look_behind`, `pray`, `dance_spin`, `dance_snake`, `button`). `Client.emote(name)`.
- `[1, "M", player, k, t]` host to every OTHER player in the room: `player` played emote `k` at host
  time `t`. The client appends `{player, emote, t}` to `client.emotes` (keep your own index into it).

`NetHost` passes on at most one emote per player every `EMOTE_GAP` (0.4 s) and drops the rest; its
counters `emotes_relayed` and `emotes_dropped` are kept outside `HostStats`, so the stats the tests
compare are unchanged. `server/room.gd` accepts "emote" from a joined player; `decode` validates both
messages like every other (a bad index is a protocol error).

## Faces

The face each player draws before the run (`face/`, North Star H1 and V7) goes only to the other
players in the same run, and nothing stores or logs it on the way:

- `[1, "J", name, ct, face]` client to host: the join's optional fifth element, the face as
  `FaceCodec` text (at most 515 characters). A four-element join is still a join and decodes exactly as
  before (no `face` key, so the reference digests are unchanged). A fifth element that is not a valid
  face (not text, longer than `FaceCodec.MAX_LENGTH`, or refused by `FaceCodec.check`) counts as no
  face, and the player still joins. A join with the worst-case face and a 32-character name is 571
  bytes (the server's limit is 4096). `Client.new(..., face)`, `RoomClient.connect_to(url, secret,
  name, face)`, `LocalRoom.open_local(seed, name, entity, face)`.
- `[1, "F", player, face]` host to client: `player`'s face. After each welcome the joiner gets every
  other player's face (so a late joiner has everyone's), and the others get the joiner's once (when it
  is new or changed). Never in the 20 Hz snapshot. The client keeps them in `client.faces` (player id
  -> text); its own is `client.face`. `server/room.gd` refuses "F" from a client.
- `[1, "C", face]` client to host (decoded type `setFace`): this player changed their face during the
  run (the prison's face kiosk, `client/face_kiosk.gd`). A face that is not valid decodes as `""`, so
  the room server passes it and the host ignores it: nobody is kicked for a bad face. The host takes
  at most one change per player every `Protocol.FACE_GAP` (5 s), keeps it (a late joiner gets the new
  one) and passes it on once with "F"; the rest are dropped (`face_changes`, `face_changes_ignored`).
  `Client.change_face(face, now)` shows it at once on this screen and holds a change made sooner than
  the gap (plus `FACE_SEND_SLACK`) after the last one sent until a later frame, sending only the newest;
  `RoomClient.set_face(face)` also puts it in every later run's join. Worst case 525 bytes.

`NetHost.faces_sent` counts the face messages (outside `HostStats`); `relay_faces = false` stops
them (tests use it to show the checks can fail). `tests/prop_face_net.gd` (run alone with
`tests/run_face_net.gd`) checks all of the above.

## The client API (what `client/play_link.gd` does)

The game is joined: `client/play_link.gd` is the only client script that talks to the room, alone
(`LocalRoom`) or with friends (`RoomClient`); `client/main.gd` draws its snapshot and
`client/start_screen.gd` is the join form and the lobby (`rc.people`, `rc.start_run()`, `rc.leave()`,
`rc.status`, `rc.close_code`). What it does each frame is the pattern below.

The game talks to one object, `RoomClient`. Call `poll(now)` every frame (local seconds, any
monotonic clock), then, while `client` is not null, `frame(now, local)` once per rendered frame with
the camera and the player's intents. It returns a `Client.Frame`: what to draw. Everything else
(the HUD's phase, timers, tapes, events) is in `rc.client.latest` and `rc.client.events`.

```gdscript
const RoomClient = preload("res://net/room_client.gd")
const Client = preload("res://net/client.gd")
var rc := RoomClient.new()
var t0 := Time.get_ticks_usec()

func _ready() -> void:
	rc.connect_to("wss://your-server.example", passphrase_from_the_join_screen, "Ann")

func _process(_dt: float) -> void:
	var now := (Time.get_ticks_usec() - t0) / 1e6
	rc.poll(now)                                   # status: connecting, lobby, running, closed
	if rc.status == "lobby" and start_pressed:
		rc.start_run()                             # rc.people: [[id, name], ...]
	if rc.client == null:
		return
	var lf := Client.LocalFrame.new()              # the player's own body, moved locally (instant)
	lf.body = my_body                              # Move.Body; move it with Session.move_local()
	lf.yaw = cam_yaw; lf.pitch = cam_pitch; lf.eye = 1.65
	lf.h_fov_deg = h_fov; lf.v_fov_deg = 70.0      # the REAL camera's fields of view
	lf.raised = instrument_up; lf.hold_doors = holding; lf.gait = gait  # "walk" | "creep" | "sprint"
	lf.call = call_pressed_this_frame; lf.pick_up = pick_pressed_this_frame
	lf.stamina = rc.client.correct_stamina(my_tank)  # the game's own tank, nudged toward the host's
	var f := rc.frame(now, lf)
	if f.placed != null:
		my_body = f.placed                         # the host moved you (start, ride, pushed out, joining)
	screen_dark = f.dark                           # blinks, the blackout, and being taken
	orderly_node.visible = f.visible               # never on a dark frame (it is still heard)
	if f.orderly != null:
		pose_orderly(f.orderly)                    # {x, y, z, level, yaw, anim, animTime}: draw EXACTLY this
	for p in f.players:                            # everyone else, interpolated
		draw_player(p["id"], p["body"], p["yaw"], p["pitch"], p["gait"], p["status"], p["active"])
```

What the frame and the client give you:

- `f.orderly` is the pose this screen must draw, already held when seen: never draw anything newer
  (the old game's "never seen to move" depends on it), and use it for the squeak's position too.
  `f.held` (frozen on screen), `f.seeing` (this screen sees it now), `f.taken` (this player was
  caught: show the caught sequence; the screen is blind until the catch is drawn or called off;
  `rc.client.latch_released` on the frame a false alarm ends), `f.depth`, `f.render_time` (host
  time being drawn).
- `rc.client.latest`: the newest snapshot, a Dictionary with the TypeScript names: `phase`
  ("arriving", "unloading", "away", "coming", "boarding", "riding", "ended"), `depth`, `timer`,
  `floorsAway` (the indicator), `bellLeft`, `holdLeft`, `held`, `blink` ({at, len, warn, blackout,
  announced, endsAt} in host time), `orderly` (host's pose plus `speed`, `frozen`, `mode`, `windUp`),
  `players` ([{id, body, yaw, pitch, active, status, aboard, side, connected, gait}]), `crew`
  ([{id, needle, raised, open, rate, tickHz, tape: {id, owner, readings, total}, carrying}]),
  `floor` (dropped tapes with `at`), `summary` (the bank or the wipe, else null).
  `rc.client.me()` is this player's crew entry (the instrument's needle, rate and tick rate).
- `rc.client.events`: every run event, once each and in host order (plain Dictionaries with the
  TypeScript keys: `called`, `indicator`, `blinkSoon`, `blinkStart`, `blinkEnd`, `doorsOpened`,
  `voteChanged`, `bell`, `banked`, `wiped`, `caught`, `windUp`, `readingClosed`, `slip`, ...).
  Keep your own index into it.
- `rc.client.id` (also `rc.my_id`), `rc.client.playing` (false while a late joiner watches until the
  next stop; they are placed in the car there), `rc.client.local_depth`, `rc.client.seed` (every
  floor comes from it: `Session.plan_for(seed, depth)`), `rc.client.host_stamina`.
- The lift is `Session.car_for(plan)`; doors are open in `Session.doors_open_in(phase)`; walls and
  the doorway are in `Session.move_local(plan, phase, body, dx, dz)` (exactly what the host checks).
  The host refuses a body further than the player could have gone (sprint only while its own copy of
  the tank allows), so move the body with the rules' speeds.
- Caught players: the host keeps what the run does. A caught player's `status` is "caught" until the
  car next rides down; only a catch that would wipe the run while the car is here or coming is the
  soft catch of `host_rules.gd` (the player is put back on their feet; `HostRules.revived` is not used
  by `host.gd`, so nobody is moved). The game draws a caught crewmate lying where they were taken
  (`others_view.gd`, from `status`), and a caught player's own screen plays the catch (`f.taken`, the
  "caught" event). The downed-and-healed rules (B6 as amended) will change the run and the host; the
  client follows `status`.
- `rc.status == "closed"`: `rc.close_code` says why (4001 passphrase, 4002 room full, 4003-4006
  limits, 1000 normal).

Things to keep: call `frame` every rendered frame (the hold is per frame); pass the real camera and
fields of view (the sight test is the logic's own, widened); do not smooth or tween the Orderly's
pose; do not draw the Orderly on a dark frame. The game draws `f.orderly` exactly (the old bridge's
"frozen close to you is drawn reaching" pose swap is gone for that reason). `latest["phase"]` is the
newest snapshot's; the screen (`f.dark`, the Orderly, the others) is drawn about 0.1 s behind it, and
a blink stays dark one tick past its end, so the lights come back about 0.15 s after the phase turns.

The sight test is generous on purpose (the larger outlines of `Entity.seen_by`): a figure just behind
a door frame can count as seen and stay frozen though the picture does not show it. That errs on the
safe side of the fairness rule.

## Checks

- `tools/net_local.mjs` (10 checks): the headless server and three headless GDScript players over
  real WebSockets with injected delay, then hostile probes.
- `tools/play_net.mjs` (31 checks): the real Windows game, two windows and a browser, through the start
  screen, the face step, the lobby, the run and back (see `godot/README.md`, Checks). To prove it can
  fail, replace `_transport.send(q.peer, text)` in `host.gd` `_relay_emote` with
  `pass  # BREAK: _transport.send(q.peer, text)`, export Windows (`npm run godot:export -- windows`)
  and run it: the two emote checks fail. Likewise `var relay_faces := false` in `host.gd`: the face
  checks (the monitor, the masks, faces received) fail. Undo it and export again.
- `tests/run_face_net.gd` (7 tests): the face in the join and the host passing it on, in memory.
- `tests/run_eye.gd` (3 tests): the eye height (`client/eye_height.gd`: standing 1.65, creeping 1.13,
  down 0.45, eased over 0.2 s in whole centimetres). Playing alone through `play_link.gd` and the real
  NetClient and host: on every frame the camera drawn is the camera sight is judged from, and every
  input carries that eye; creeping under an atrium's edge hides an Orderly on the floor above that
  standing shows. Desks, beds and counters do not block the rules' sight (generous), so a crouch behind
  one can hide the Orderly on screen while it still counts as seen: the safe side of the fairness rule.
