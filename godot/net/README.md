# The network layer

A port of `src/net` (the old browser game's networking) to typed GDScript, proved the same by
`tests/ref_net.gd` (every message, every client frame and every host tick of seven scripted sessions
against the TypeScript) and `tests/prop_net.gd` (the fairness rules of `tests/net/rule.test.ts`
over bot sessions on a hostile network, counts equal to TypeScript's). What changed from the old
game: the host is the home server (`server/`), not a player's browser; the transport is a
WebSocket to that server; nothing else.

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
room_client.gd  what the game uses: the WebSocket to the server, the passphrase, the lobby, a NetClient per run
ws_server.gd    the server's door (passphrase, limits)
```

## Joining the real client to the network (the next task)

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
- Downed players: the old host keeps what the run does (a catch while the car is here or coming is the
  soft catch of `host_rules.gd`; the player is put back on their feet). The camera view is not built.
- `rc.status == "closed"`: `rc.close_code` says why (4001 passphrase, 4002 room full, 4003-4006
  limits, 1000 normal).

Things to keep: call `frame` every rendered frame (the hold is per frame); pass the real camera and
fields of view (the sight test is the logic's own, widened); do not smooth or tween the Orderly's
pose; do not draw the Orderly on a dark frame.
