# The wire protocol between the host (the home server) and the players' machines. Port of
# src/net/protocol.ts: every message is a JSON text, versioned, and the two 20 Hz messages (input and
# snapshot) travel in the same compact positional-array form as the TypeScript host wrote them.
# Nothing here touches the network; transports move strings.
#
# Units: positions in metres, angles in radians, times in seconds. "Host time" is the run's own clock
# (RunState.t): the host's tick k is at host time k * TICK. Client times are the client's local clock.
#
# Quantisation: positions to the centimetre, angles and clocks to the millisecond. A quantised number
# survives the JSON round trip bit for bit (net/jsjson.gd writes and reads numbers exactly as
# JavaScript does), so the host can compute exactly what a client drew from the same quantised poses
# the client was sent (see Pose.lerp_pose and host.gd).
#
# The readable (decoded) messages are Dictionaries with the TypeScript (camelCase) keys. Bodies are
# Move.Body; poses are Dictionaries {x, y, z, level, yaw, anim, animTime} (net/pose.gd); phases,
# statuses, gaits, needles and modes are Strings; events are plain Dictionaries (bodies inside them
# are {x, z, level, y} Dictionaries, as JSON.parse gave them in TypeScript). Every number that came
# off the wire is a float; counters (tick, seq, depth, ...) are ints.
#
# decode() validates everything it accepts (types, ranges, finite numbers): a client's input that
# does not fit the protocol exactly is null, and never reaches the rules.
extends RefCounted

const ReactorWire = preload("res://net/reactor_wire.gd")
const WardWire = preload("res://net/ward_wire.gd")
const WORLD_SHOP_INDEX := 27
const WORLD_FLOOR_EXTENSIONS_INDEX := WORLD_SHOP_INDEX + 1

const Pose = preload("res://net/pose.gd")
const JsJson = preload("res://net/jsjson.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Run = preload("res://sim/run.gd")
const TapeLib = preload("res://sim/tape.gd")
const Stamina = preload("res://sim/stamina.gd")
const Face = preload("res://face/face_codec.gd")
const Findables = preload("res://sim/findables.gd")
const Settings = preload("res://sim/settings.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")

const PROTOCOL_VERSION := 1
const SOLID_BASELINE := 1
const SOLID_RESTORED := 2

## "night" (the day loop: in the prison once the car's doors have closed) is last, so the codes of the
## others are as they were.
const PHASES: Array[String] = ["arriving", "unloading", "away", "coming", "boarding", "riding", "ended", "night"]
## The Orderly's poses and modes first (their codes are as they were), then the Playroom's Minder's
## (sim/seek.gd MinderState: anim and mode).
## Then the bend over a downed player (sim/entity.gd "bending" / "bend").
const ANIMS: Array[String] = ["idle", "walk", "duck", "reach",
	"stand", "straighten", "cover", "prowl", "sweep", "look", "slump", "run", "catch",
	"bend",
	"tilt", "lean"]
const MODES: Array[String] = ["waiting", "hunting", "windUp", "dormant",
	"wander", "cover", "search", "sweep", "look", "slump", "run", "catch",
	"bending",
	"grab", "drag",
	"listening", "tilt", "coming", "lean", "beat", "strike"]
## The Playroom's per-player states (sim/seek.gd SeekPlayer), for the seek block.
const SEEK_STATUSES: Array[String] = ["ok", "found", "taken", "down"]
const SEEK_PHASES: Array[String] = ["out", "entering", "inside", "leaving"]
## Emotes that play a sound: on the Playroom, a noise that starts a count (playarea.md section 3).
const SOUND_EMOTES: Array[String] = ["button"]
const NEEDLES: Array[String] = ["off", "idle", "dormant", "recording", "contaminated"]
## A player's status (sim/run.gd RunPlayer.status). Its code rides in a player row's flags: the low two bits
## at bit 5, the third at bit 9 ("out" is the first code that needs it), so the old codes are as they were.
const STATUSES: Array[String] = ["ok", "caught", "leftBehind", "down", "out"]
## How a player went down (the downs block).
const DOWN_BY: Array[String] = ["catch", "health"]
const GAITS: Array[String] = ["walk", "creep", "sprint"]
## The emote wheel's emotes (client/crew_view.gd plays them). Not in protocol.ts: the emote messages
## ("E" client -> host, "M" host -> the other clients) are new in the Godot game. They change nothing
## in the other messages, and a session that never emotes sends exactly what it did before.
const EMOTES: Array[String] = ["wave", "look_behind", "pray", "dance_spin", "dance_snake", "button", "point", "cheer", "scared"]
## Drawn faces (face/README.md, North Star H1 and V7). Also new in the Godot game, and also optional:
##  - the join may carry the player's face as a fifth element, [1, "J", name, ct, face]. A join of four
##    elements is still a join; a fifth that is not a valid face (FaceCodec.check, at most
##    FaceCodec.MAX_LENGTH characters) counts as no face, and the player still joins. A join without a
##    face decodes exactly as before (no "face" key);
##  - the host passes each face on to the other players in the run, once: [1, "F", player id, face]
##    (host -> client only; the room server refuses it from a client). Never in the 20 Hz snapshot.
##  - a player who changes their face during the run (the prison's face kiosk) sends it: [1, "C", face]
##    (client -> host). A "C" whose face is not valid still decodes, as {"type": "setFace", "face": ""},
##    so the room server passes it on and the host ignores it: a bad face never kicks anyone. The host
##    takes at most one change per player every Host.FACE_GAP seconds and passes it on with "F".
## The face goes only to the other players in the same run: nothing else stores or logs it.
## The day loop (sim/run.gd days, docs/floors/prison.md P7). New in the Godot game, and only ever sent
## when the run has days on, so a run without them sends exactly what it did before:
##  - the input's flags gain bit 32, "use": F is held (in the prison, held on a bunk it lies you down).
##    Decoded as "use": true only when set (no key otherwise);
##  - the world (snapshot and welcome) gains a 16th element, the day block (enc_day / "day" decoded):
##    [day index (every day of the run, from 1: the day's seed is Run.day_seed(seed, index)), day number,
##    day quota, streak, misses, [ids in bed], host time the bedtime count started or null, host time of
##    lights out or null, the settled day's result or null, how many are in the bedtime count];
##  - a placement gains a 4th element, the day index of the floor it is on ("day");
##  - phase "night"; events "dayEnded" {result}, "rodeUp" {depth, day, bodies}, "bed" {playerId, inBed,
##    count}, "bedCount" {lightsOutAt}, "lightsOut" {assisted, morningAt}, "newDay" {day, dayIndex,
##    depth, bodies}; "carLeft" reason "up".
## The Playroom (sim/run.gd and sim/seek.gd; docs/floors/playarea.md; loop/NIGHT-PLAN.md A3). New in the
## Godot game, and only ever sent on a Playroom (or by a player who hides or peeks), so a run that never
## reaches one sends exactly what it did before:
##  - the input's flags gain bit 64, "peek": W held inside a hide. Decoded as "peek": true only when set;
##  - the input may carry two more elements, [..., seen, hides, fastHides]: how many times this player has
##    pressed F for a hide, and how many of those with sprint held (the quick, noisy way). Counters, like
##    "calls", so a press is never lost with an input. Sent only once hides > 0; decoded as "hides" and
##    "fastHides" (no keys when absent: read them as 0);
##  - the world gains a 17th element, the seek block (enc_seek / "seek" decoded), with the 16th the day
##    block or null: [noise (the crew's loudest this tick, 0 to 1, the instrument's needle outside a
##    count), flags (1 counting, 2 the running count is the last, 4 the lift was called, 8 the last count
##    is over), count number n, t0 (host time the count began: the 6 s to hide start then), len (seconds
##    of count after the 6 s), by (player id), why, counts ended, calm until (host time; nothing provokes
##    before), last at (host time a pending last count starts, or null), [[player id, hide id or -1,
##    flags (1 peeking, SEEK_PHASES index << 1, SEEK_STATUSES index << 3), health, sight total, gap
##    total, party-table seat or -1], ...]] and, only with the tuned Playroom (sim/seek.gd T15m), two more:
##    [..., anger (0 to 1, the HUD's bar), hide (the running count's seconds to hide)]. Times are host
##    times, never durations;
##  - the Minder rides in the Orderly's place (pose, speed, mode) with its own pose and mode names
##    (ANIMS and MODES, appended);
##  - events, all at host time: "count" {n, t0, len, last, by, why} (why: sprint, squeaker, ballpit,
##    flap, tape, emote, bump, light, voice, call), "countEnd" {n, last}, "hideStart"/"hideLeave"
##    {playerId, hide, fast}, "hideIn"/"hideOut"/"hideFull" {playerId, hide}, "flap" {playerId, hide},
##    "reason" {hide, why, playerId}, "sweep" {zone}, "draw" {zone, n, hide, k}, "look" {hide},
##    "lookDone" {hide, found}, "emptyHide" {hide}, "found" {playerId, cause, hide}, "taken" {playerId,
##    seat}, "down" {playerId}; and "called" gains "last": true (floorsAway 0) when the call starts the
##    last count. With the tuned Playroom (T15m): "count" gains "hide" (its seconds to hide), "found" may be
##    cause "grab" (outside a count, within 1 m), the Minder's modes "grab" and "drag" (appended to MODES),
##    and the hint events "playroomArrived" {depth} and "sprintDuringHunt" {playerId, n}.
##    With the party table (T15h, sim/seek.gd with_party, only together with the tuned Playroom) the seek block
##    gains a 14th element, [fetcher id or "", host time their hold counts from or -1] ("party" decoded: {by,
##    from}), and the events "fetchStart" {playerId, from, done, seated}, "fetchStop" {playerId} and "tableFreed"
##    {playerId (the fetcher), freed (ids), health}; "count" may be why "fetch".
## The floor quota (sim/run.gd quota; North Star C9). New in the Godot game, and only ever sent when the
## run has the quota on, so a run without it sends exactly what it did before:
##  - the world gains an 18th element, the quota block (enc_quota / "quota" decoded), with the 16th and
##    17th the day and seek blocks or null: [earned (whole credits recorded on this floor: every reading
##    closed here, dropped tapes included), needed (this floor's quota, 0 at home)]. The call panel shows
##    earned against needed; the call works once earned >= needed;
##  - events "callRefused" {playerId, earned, needed} (the call button was pressed below the quota and
##    did nothing) and "quotaMet" {depth, earned, needed, top} (once per floor, the tick it is met; top:
##    the player who recorded the most on the floor).
## The day quota's lock (sim/run.gd day_lock; FD2, docs/floors/findables-and-day.md section 1). New in the
## Godot game, and only ever sent when the run has the lock on, so a run without it sends exactly what it did
## before:
##  - the day block gains five elements after the crew, [..., earned (whole credits recorded today, every
##    reading closed on any floor, dropped tapes included), locked (1 while earned < the day quota, else 0),
##    aboard (whole credits held by those on their feet in the car: what BANK would pay), each (aboard split
##    over today's crew, the odd credits aside), stakes (the lift monitor's third row, sim/day.gd
##    stakes_row)], decoded as "earned", "locked" (a bool), "aboard", "each" and "stakes";
##  - events "bankRefused" {bank, down, day, earned, quota} (BANK won the bell while locked: the car rides
##    down; the "bell" before it has outcome "ride" and "refused": true) and "dayMet" {day, earned, quota}
##    (once a day, the tick earned reaches the quota).
## The Annex (sim/run.gd annex; docs/floors/annex.md sections 2 and 4; T16h). New in the Godot game, and only
## ever sent on an Annex floor (or by a player who marks or peels), so a run that never reaches one sends
## exactly what it did before:
##  - the input may carry three more elements after the hides, [..., hides, fastHides, marks, peels,
##    peelId] (the hides then 0 when there were none): how many times this player has pressed Q to place
##    a mark, how many peels it has asked for, and the mark id of the newest peel (-1 before any).
##    Counters, so a press is never lost with an input. Sent only once marks or peels > 0; decoded as
##    "marks", "peels" and "peelId" (no keys when absent: read them as 0, 0, -1);
##  - the world gains a 19th element, the annex block (enc_annex / "annex" decoded), with the 16th to 18th
##    the day, seek and quota blocks or null: [pad (marks left on the crew's one pad), pad size, [[mark id,
##    x, z, level, dir (0..7, Marks.dir_vector), player id, host time placed], ...], notesFrom (this
##    floor's note ids are notesFrom + 1 on), noteCount] and, in the welcome only, a 6th element: every
##    note of the floor so far, [[id, n, trigger, template, text, x, z, level, yaw, t], ...]. Notes are
##    otherwise only events (each arrives exactly once), so a snapshot carries how many there are, not
##    their text;
##  - events "markStart" {playerId, x, z, level, dir}, "markPlaced" {playerId, mark {id, x, z, level, dir,
##    player, placedAt}, pad, radius (the slap carries this far)}, "markPeeled" {playerId, id, owner, pad},
##    "markRefused" {playerId, reason, peel (only for a peel)} and "note" {id, n, trigger, template, text,
##    x, z, level, yaw} (the Temp's stapler: one loud click where the note is).
## Down first, then out (sim/run.gd downs; North Star B6; T8a). New in the Godot game, and only ever sent when
## the run has the down rule on, so a run without it sends exactly what it did before:
##  - player statuses "down" (code 3) and "out" (code 4: the flags' bit 9 is the code's third bit);
##  - the resident's mode "bending" and pose "bend" (appended to MODES and ANIMS): bent over a downed player,
##    the one movement it makes while watched (sim/entity.gd);
##  - the world gains a 20th element, the downs block (enc_downs / "downs" decoded), with the 16th to 19th the
##    day, seek, quota and annex blocks or null: [[[player id, host time down, host time out unless healed,
##    DOWN_BY index, healer id or "", host time the heal hold began or null], ...], [[player id, x, z, level,
##    y, host time], ...] (this floor's red spots, where each tape fell)]. Times are host times, never
##    durations: a heal is done at healFrom + Run.HEAL_TIME (or + a 7th element, the hold's own seconds, when the
##    host's live settings timed it otherwise: "healFor"), the timer runs out at the second time;
##  - events "downed" {playerId, until, by, at}, "healStart" {playerId (the healer), target, from, done},
##    "healStop" {playerId, target}, "healed" {playerId, by, at} and "out" {playerId, at, spot (null when the
##    car left without them)}. The resident's own "caught" still comes first, as before.
## A second Orderly (sim/run.gd second_orderly; T9b). New in the Godot game, and only ever sent on a floor that has
## one, so a run without it sends exactly what it did before (old fields keep their meaning: "orderly", "reloc" and
## "watch" are always the first Orderly's):
##  - the world's floor extensions (its 29th element) gain "o2": [the second's orderly array, exactly as the 11th
##    element is for the first, its relocation count, its watch block as enc_watch or 0], decoded as "orderly2",
##    "reloc2" and "watch2" (absent when 0);
##  - an input's flags gain 512, "seeing2": the player can see the second Orderly now (as 4, "seeing", is for the
##    first);
##  - a seen report of the second has a 7th element, 2, decoded as "n": 2 (a report without one is of the first);
##  - events about the second (the run's and the host's) carry "n": 2; the first's never carry "n".
## Relocation (sim/run.gd relocation, sim/relocate.gd; T19e). New in the Godot game, and only ever sent once the
## floor's resident has relocated, so a run without it sends exactly what it did before:
##  - the world gains a 22nd element, the relocation count ("reloc" decoded: relocations on this floor so far),
##    with the 16th to 21st null when absent. A client whose two snapshots differ in it never blends between
##    them (net/client.gd: it snaps to the new pose);
##  - the event "relocated" {from, to (bodies), near (the player it went to), k, who (its body), reach (its
##    arrival cue's reach, m), why}: its arrival cue.
## Lonely (sim/run.gd lonely, sim/lonely.gd; T19c). New in the Godot game, and only ever sent on a floor whose
## resident is Lonely, so a run without it sends exactly what it did before:
##  - the world gains a 23rd element, who it chases ("lonely" decoded: a player id, or "" for nobody), with the
##    16th to 22nd null when absent. A client that has it never holds the figure (looking does nothing);
##  - the events "chaseStarted" {playerId, at (a body), yaw} and "chaseEnded" {playerId, why}.
## Solid furniture (sim/run.gd furniture, sim/furniture.gd; FD7). New in the Godot game, and only ever sent in a run
## with it, so a run without it sends exactly what it did before:
##  - the world gains a 24th element, 1 for the baseline or 2 for the restored wall furniture (T20j), decoded
##    as "solid". The client draws that layout and moves its body round it (net/session.gd move_local).
## Findables (sim/run.gd findables, sim/findables.gd; FD9). New in the Godot game, and only ever sent in a run with
## them, so a run without them sends exactly what it did before:
##  - the input's flags gain bit 128, "search" (F held to search the piece in reach), and bit 256, "searchFast"
##    (sprint held with it: the rushed search). Decoded as true only when set (no keys otherwise);
##  - the world gains a 26th element, the find block (enc_find / "find" decoded), with the 16th to 25th null when
##    absent: [[[piece id, player id, what (Findables.WHAT index), credits, note or page id or "", fast (0/1),
##    host time], ...] (what has been opened on this floor, by piece id), [[player id, piece id, fast (0/1), host
##    time it began, host time it ends], ...] (searches under way: the bar is (now - from) / (done - from)),
##    [[player id, cartons], ...] (what each player carries), base (the floor's quota as set on arrival: the fill's
##    unit is 1% of it, Findables.fill_for)]. Sent on a Clinic or an Annex, or while anyone carries a carton;
##  - a tape (in the crew's rows and on the floor) gains a 5th element, the credits found on it, only when there are
##    any (decoded as "found"; a floor tape's body stays last). They are in its total too;
##  - events "searchStart" {playerId, piece, kind, fast, from, done}, "searchStop" {playerId, piece, why: let_go,
##    moved, interrupted, taken}, "searchNoise" {playerId, piece, at} (the rushed search's noise) and "searchDone"
##    {playerId, piece, kind, what, credits, note, fast}.
## Live settings (docs/floors/live-settings.md LS2; net/tuning_desk.gd). New in the Godot game, and only ever sent once
## the host has changed a setting (the revision is above 0), so a run without a change sends exactly what it did:
##  - the world gains a 25th element, the tune block ("tune" decoded): [rev] or, in the welcome, for a second after
##    a change and once a second after that, [rev, [[id, value], ...]] (every value in force that is not the game's),
##    with the 16th to 24th null when absent. A client keeps the newest list as its tuning (net/client.gd);
##  - the event "tuned" {rev, by, id, was, v, when, line}: the one-line notice of a change going into the run.
## The four-slot inventory (sim/run.gd inventory, sim/inventory.gd; S1). New in the Godot game, and only ever sent in a
## run with it, so a run without it sends exactly what it did before:
##  - the input gains four elements after the Annex's (which, with the Playroom's, are then sent as 0 when unused,
##    27 in all): [invSel, invs, invOp, invArg]. invSel is the slot the player asks to hold (0 to 3, -1 for none
##    asked yet); invs counts the requests made so far and invOp (INV_OPS index) and invArg are the newest:
##    "drop" (arg 0), "take" (arg the pickup's id) or "give" (arg the crewmate's id). Decoded "invSel", "invs",
##    "invOp", "invArg" only when sent;
##  - the world gains a 27th element, the inv block ("inv" decoded), with the 16th to 26th null when absent:
##    [[[player id, selected slot, [slot, slot, slot, slot]], ...], [[pickup id, item, count, body], ...]], a slot
##    [item, count] or 0 for empty, an item its index in Inventory.ITEMS;
##  - events "itemDropped" {playerId, pickup, item, count, at, why: drop, down}, "itemTaken" {playerId, pickup,
##    item, count, left}, "itemGiven" {playerId, to, item, count}, "invRefused" {playerId, op, why: full,
##    theirFull, reach, empty, gone, busy} and "searchFull" {playerId, piece} (a carton found with no room).
## The shop and the cabinet (sim/run.gd shop, sim/shop.gd; S2). New in the Godot game, and only ever sent in a run with
## it, so a run without it sends exactly what it did before:
##  - the inventory's requests gain "stash" (arg your slot, 0 to 3), "fetch" (arg the cabinet's slot), "buy" (arg the
##    item's index in Shop.ITEMS) and "use" (arg 0), sent and counted as the others;
##  - the world gains a 28th element, the shop block ("shop" decoded), with the 16th to 27th null when absent:
##    [[[player id, credits], ...], [[player id, [slot x Shop.CAB_MAX]], ...], [[glow id, body, until], ...],
##    [[toy id, body, start, end], ...], [[player id, juice until, flash until], ...], wake until (-1 for none)],
##    a slot as in the inv block;
##  - events "stashed" / "fetched" {playerId, item, count, slot}, "wokeUp" {bodies, leaveAt}, and the refusals as
##    "invRefused" {why: cabFull, poor, window, closed, nobody, annexOnly, unusable} besides the inventory's.
## The Tenant clock (net/host_rules.gd tenant_timer; TT1). New in the Godot game, and only ever sent in a run with it,
## on a floor below the prison while its clock runs, so a run without it sends exactly what it did before:
##  - the world's floor extensions (its 29th element) gain "tenant": [at, len], decoded as "tenant" {at, len}: the
##    host time the Tenant arrives on this floor and the clock's length in seconds (the live setting tenant.minutes
##    as it was when the doors opened). Every screen shows at - ht of the newest snapshot ("TENANT ARRIVES IN
##    09:59", then "THE TENANT IS HERE" from zero), so they agree to the tick and a late joiner's welcome carries it.
##    Absent on the prison, Practice, during a ride, and beside a "ward" or "reactor" block;
##  - the event "tenantArrived" {depth, quotaMet} at the host time the clock reached zero, once a floor: a door
##    slams and the announcer says the time is up (client/main.gd, client/announcer.gd).
## Cycles (FL2; sim/places.gd, sim/run.gd "Cycles"). Only in a run with them, and only from cycle 2 on, so cycle 1 and a
## run without them send exactly what they did before:
##  - the world's floor extensions (its last element, the dictionary after the shop block) gain "cycle": the cycle
##    number, a whole number from 2 (1 + (depth - 1) / 7 on a floor; in the prison, the next descent's). Decoded as
##    "cycle" (an int); absent means cycle 1.
## Nightly reels (T24). With a reel in progress, the day block can end in [day, started, crew, votes, skipped].
## An input with a skip vote extends its 27-element form by a host-clock timestamp (the reel's start).
const INV_OPS: Array[String] = ["", "drop", "take", "give", "stash", "fetch", "buy", "use", "throw", "skill", "lamp"]
# Skill request args: 0 buys Deep Pockets, 1 undoes the pending training, 2 buys
# Second Wind, 3 asks to use it, 4 buys Soft Shoes, 5 Quick Fingers, 6 Long Burn and 7 Field Dressing.
# Named states in the floor envelope show settled or undoable purchases, trade locks and missing prerequisites.

## Telemetry (client/telemetry.gd -> server/night_log.gd). New in the Godot game: [1, "T", kind, body] for kind
## "hb" (a heartbeat: body is a small JSON object as text) or "log" (one error or warning line), and
## [1, "T", kind, body, report id, part, parts] for "rep" (part of an F9 report) or "crash" (the tail of a
## session that crashed). Sent on its own frame, "t|<text>", in the lobby or a run; never part of a run's
## messages. The server only logs it (rate limited per player, and never executed or trusted), and drops
## one that does not decode instead of closing the connection.
const TELEMETRY_KINDS: Array[String] = ["hb", "log", "rep", "crash"]
const MAX_TELEMETRY_LINE := 500
const MAX_TELEMETRY_PART := 3000
const MAX_TELEMETRY_PARTS := 8

## Limits on what a client may send (the server refuses anything outside them).
const MAX_NAME := 32
const MAX_SEEN := 8
const MAX_COORD := 10000.0
const MAX_CLOCK := 1e9
const MAX_COUNT := 2147483647
## The host takes at most one face change ("C") per player every FACE_GAP seconds (net/host.gd); the
## client holds back a newer face until the gap (and FACE_SEND_SLACK more, for the link) has passed.
const FACE_GAP := 5.0
const FACE_SEND_SLACK := 0.5

# ---------------------------------------------------------------------------------------------
# Numbers.

static func q2(x: float) -> float:
	return Pose.q2(x)

static func q3(x: float) -> float:
	return Pose.q3(x)

static func q_body(b: Move.Body) -> Move.Body:
	return Move.Body.make(q2(b.x), q2(b.z), b.level, q2(b.y))

## Math.floor(x * 1000) / 1000 (rounded down: a bound stays a bound).
static func floor3(x: float) -> float:
	var r := floorf(x * 1000.0) / 1000.0
	return 0.0 if r == 0.0 else r

# ---------------------------------------------------------------------------------------------
# The Orderly as drawn.

## The snapshot form of the logic's Orderly (quantised): a pose plus speed, frozen, mode, windUp.
static func orderly_snap(o: Entity.OrderlyState) -> Dictionary:
	var d := {
		"x": q2(o.body.x), "y": q2(o.body.y), "z": q2(o.body.z), "level": o.body.level, "yaw": q3(o.yaw),
		"anim": String(o.anim), "animTime": q3(o.anim_time), "speed": q2(o.speed), "frozen": o.held, "mode": String(o.mode),
	}
	if o.mode == &"windUp" and o.wind_up_target != null:
		d["windUp"] = {"target": String(o.wind_up_target), "left": q3(o.wind_up_left)}
	return d

# ---------------------------------------------------------------------------------------------
# Plain data (what JSON.parse(JSON.stringify(x)) gives in TypeScript).

static func body_plain(b: Move.Body) -> Dictionary:
	return {"x": b.x, "z": b.z, "level": b.level, "y": b.y}

static func reading_plain(r: TapeLib.Reading) -> Dictionary:
	return {"id": r.id, "playerId": r.player_id, "entityId": r.entity_id, "trait": String(r.trait_name), "value": r.value,
		"duration": r.duration, "peakRate": r.peak_rate, "closedAt": r.closed_at}

static func summary_plain(s: Run.RunSummary) -> Variant:
	if s == null:
		return null
	var tapes: Array = []
	for t in s.tapes:
		tapes.append(t)
	return {"depth": s.depth, "readings": s.readings, "total": s.total, "shares": s.shares.duplicate(), "tapes": tapes, "wiped": s.wiped}

## An event (or anything in one) as plain data.
static func plain(v: Variant) -> Variant:
	if v is StringName:
		return String(v)
	if v is Move.Body:
		return body_plain(v)
	if v is TapeLib.Reading:
		return reading_plain(v)
	if v is Run.RunSummary:
		return summary_plain(v)
	if v is float and (is_inf(v) or is_nan(v)):
		return null
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(plain(x))
		return out
	if v is Dictionary:
		var d: Dictionary = v
		var out := {}
		for k: Variant in d:
			out[k] = plain(d[k])
		return out
	return v

# ---------------------------------------------------------------------------------------------
# The compact wire form.

static func _enc_body(b: Move.Body) -> Array:
	return [q2(b.x), q2(b.z), q2(b.y), b.level]

static func _enc_pose(p: Dictionary) -> Array:
	return [p["x"], p["z"], p["y"], p["level"], p["yaw"], ANIMS.find(String(p["anim"])), p["animTime"]]

static func _enc_tape(t: Dictionary) -> Array:
	var a: Array = [t["id"], t["owner"], t["readings"], q2(t["total"])]
	if t.get("found") != null:
		# Findables (see the header): the credits found on the tape, only when there are any.
		a.append(q2(t["found"]))
	return a

## The orderly array of the world (its 11th element; "o2" for a second Orderly): a pose, speed, frozen, mode, windUp.
static func _enc_orderly(o: Dictionary) -> Array:
	var ow := _enc_pose(o)
	ow.append(o["speed"])
	ow.append(1 if o["frozen"] else 0)
	ow.append(MODES.find(String(o["mode"])))
	if o.has("windUp"):
		ow.append(o["windUp"]["target"])
		ow.append(o["windUp"]["left"])
	return ow

static func _dec_orderly(c: _V, w: Variant) -> Dictionary:
	var ow := _a(c, w, 10, 12)
	if c.bad or ow.size() == 11:
		c.bad = true
		return {}
	var orderly := _dec_pose(c, ow, 10, 12)
	orderly["speed"] = _f(c, ow[7])
	orderly["frozen"] = _f(c, ow[8]) == 1.0
	orderly["mode"] = _code(c, MODES, ow[9])
	if ow.size() > 11:
		orderly["windUp"] = {"target": _s(c, ow[10]), "left": _f(c, ow[11])}
	return orderly

static func enc_world(w: Dictionary) -> Array:
	var o: Dictionary = w["orderly"]
	var blink: Variant = 0
	if w["blink"] != null:
		var b: Dictionary = w["blink"]
		blink = [b["at"], 1 if b["announced"] else 0, b["endsAt"], b["len"], b["warn"], 1 if b["blackout"] else 0]
	var ow := _enc_orderly(o)
	var players: Array = []
	for p: Dictionary in w["players"]:
		var side: Variant = p["side"]
		var sc := STATUSES.find(String(p["status"]))
		var flags := (1 if p["active"] else 0) | (2 if p["aboard"] else 0) | (4 if p["connected"] else 0) \
			| (8 if side == "bank" else (16 if side == "down" else 0)) | ((sc & 3) << 5) | (GAITS.find(String(p["gait"])) << 7) | ((sc >> 2) << 9)
		var row: Array = [p["id"]]
		row.append_array(_enc_body(p["body"]))
		row.append(q3(p["yaw"]))
		row.append(q3(p["pitch"]))
		row.append(flags)
		players.append(row)
	var crew: Array = []
	for m: Dictionary in w["crew"]:
		var carrying: Array = []
		for t: Dictionary in m["carrying"]:
			carrying.append(_enc_tape(t))
		crew.append([m["id"], NEEDLES.find(String(m["needle"])), 1 if m["raised"] else 0, q2(m["open"]), q2(m["rate"]), q2(m["tickHz"]), _enc_tape(m["tape"]), carrying])
	var fl: Array = []
	for f: Dictionary in w["floor"]:
		var row := _enc_tape(f)
		row.append(_enc_body(f["at"]))
		fl.append(row)
	var out: Array = [w["tick"], w["ht"], PHASES.find(String(w["phase"])), w["depth"], q2(w["timer"]), w["floorsAway"], q2(w["bellLeft"]), q2(w["holdLeft"]),
		1 if w["held"] else 0, blink, ow, players, crew, fl, w["summary"]]
	if w.get("day") != null:
		out.append(enc_day(w["day"]))
	if w.get("seek") != null:
		if out.size() == 15:
			out.append(null)
		out.append(enc_seek(w["seek"]))
	if w.get("quota") != null:
		while out.size() < 17:
			out.append(null)
		out.append(enc_quota(w["quota"]))
	if w.get("annex") != null:
		while out.size() < 18:
			out.append(null)
		out.append(enc_annex(w["annex"]))
	if w.get("downs") != null:
		while out.size() < 19:
			out.append(null)
		out.append(enc_downs(w["downs"]))
	if w.get("watch") != null:
		while out.size() < 20:
			out.append(null)
		out.append(enc_watch(w["watch"]))
	if w.get("reloc") != null:
		while out.size() < 21:
			out.append(null)
		out.append(w["reloc"])
	if w.get("lonely") != null:
		while out.size() < 22:
			out.append(null)
		out.append(String(w["lonely"]))
	if w.get("solid") != null:
		while out.size() < 23:
			out.append(null)
		out.append(w["solid"])
	if w.get("tune") != null:
		while out.size() < 24:
			out.append(null)
		out.append(enc_tune(w["tune"]))
	if w.get("find") != null:
		while out.size() < 25:
			out.append(null)
		out.append(enc_find(w["find"]))
	if w.get("inv") != null:
		while out.size() < 26:
			out.append(null)
		out.append(enc_inv(w["inv"]))
	if w.get("shop") != null:
		while out.size() < WORLD_SHOP_INDEX:
			out.append(null)
		out.append(enc_shop(w["shop"]))
	if w.get("orderly2") != null or w.get("ward") != null or w.get("reactor") != null or w.get("orientationStandees") != null or w.get("skills") != null or w.get("wind") != null or w.get("shoes") != null or w.get("flares") != null or w.get("lamps") != null or w.get("porter") != null or w.get("longBurn") != null or w.get("medic") != null or w.get("steady") != null or w.get("listener") != null or w.get("nerve") != null or w.get("tenant") != null or w.get("cycle") != null:
		var extensions := {}
		if w.get("orderly2") != null:
			extensions["o2"] = [_enc_orderly(w["orderly2"]), int(w.get("reloc2", 0)), enc_watch(w["watch2"]) if w.get("watch2") != null else 0]
		if w.get("tenant") != null:
			extensions["tenant"] = [q3(w["tenant"]["at"]), q3(w["tenant"]["len"])]
		if w.get("cycle") != null:
			extensions["cycle"] = int(w["cycle"])
		if w.get("nerve") != null:
			var nerve: Array = w["nerve"].duplicate()
			nerve[0] = q3(nerve[0])
			extensions["nerve"] = nerve
		if w.get("lamps") != null:
			var lamps := []
			for l: Dictionary in w["lamps"]:
				lamps.append([l.playerId, 1 if l.on else 0, q3(l.charge), q3(l.x), q3(l.y), q3(l.z), q3(l.yaw), q3(l.pitch), q3(l.range)])
			extensions["lamps"] = lamps
		if w.get("flares") != null:
			var bursts := []
			for b: Dictionary in w["flares"]:
				bursts.append([b.id, q3(b.x), q3(b.y), q3(b.z), q3(b.until), b.blind, q3(b.blindUntil)])
			extensions["flares"] = bursts
		if w.get("orientationStandees") != null:
			extensions["orientationStandees"] = w["orientationStandees"]
		if w.get("ward") != null:
			extensions["ward"] = WardWire.encode(w["ward"])
		if w.get("reactor") != null:
			extensions["reactor"] = ReactorWire.encode(w["reactor"])
		for key: String in ["skills", "wind", "shoes", "porter", "longBurn", "medic", "steady", "listener"]:
			if w.get(key) != null:
				var rows := []
				for id: String in w[key]:
					rows.append([id, w[key][id]])
				extensions[key] = rows
		while out.size() < WORLD_FLOOR_EXTENSIONS_INDEX:
			out.append(null)
		out.append(extensions)
	return out

## The inv block (see the header) from its readable form {bags: [{playerId, sel, slots: [[item, count] x4]}],
## pickups: [{id, item, count, at (a body)}]}.
static func enc_inv(k: Dictionary) -> Array:
	var bags: Array = []
	for b: Dictionary in k["bags"]:
		var slots: Array = []
		for s: Array in b["slots"]:
			slots.append([Inventory.ITEMS.find(String(s[0])), s[1]] if int(s[1]) > 0 else 0)
		bags.append([b["playerId"], b["sel"], slots])
	var pickups: Array = []
	for p: Dictionary in k["pickups"]:
		pickups.append([p["id"], Inventory.ITEMS.find(String(p["item"])), p["count"], _enc_body(p["at"])])
	return [bags, pickups]

static func dec_inv(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 2, 2)
	if c.bad:
		return {}
	var bags: Array = []
	for bw: Variant in _a(c, a[0], 0, 64):
		var b := _a(c, bw, 3, 3)
		if c.bad:
			return {}
		var slots: Array = []
		for sw: Variant in _a(c, b[2], Inventory.SLOTS, Inventory.SLOTS):
			if _is_num(sw) and float(sw) == 0.0:
				slots.append(["", 0])
				continue
			var s := _a(c, sw, 2, 2)
			if c.bad:
				return {}
			slots.append([_code(c, Inventory.ITEMS, s[0]), _i(c, s[1], 1, MAX_COUNT)])
		bags.append({"playerId": _s(c, b[0]), "sel": _i(c, b[1], 0, Inventory.SLOTS - 1), "slots": slots})
	var pickups: Array = []
	for pw: Variant in _a(c, a[1], 0, 1024):
		var p := _a(c, pw, 4, 4)
		if c.bad:
			return {}
		pickups.append({"id": _i(c, p[0], 0, MAX_COUNT), "item": _code(c, Inventory.ITEMS, p[1]), "count": _i(c, p[2], 1, MAX_COUNT), "at": _dec_body(c, p[3])})
	return {"bags": bags, "pickups": pickups}

## The shop block (see the header) from its readable form {credits: [{playerId, credits}], cabinets: [{playerId,
## slots: [[item, count] x Shop.CAB_MAX]}], glows: [{id, at, until}], toys: [{id, at, start, end}], timers:
## [{playerId, juice, flash}], wake}.
static func enc_shop(k: Dictionary) -> Array:
	var credits: Array = []
	for r: Dictionary in k["credits"]:
		credits.append([r["playerId"], r["credits"]])
	var cabs: Array = []
	for r: Dictionary in k["cabinets"]:
		var slots: Array = []
		for s: Array in r["slots"]:
			slots.append([Inventory.ITEMS.find(String(s[0])), s[1]] if int(s[1]) > 0 else 0)
		cabs.append([r["playerId"], slots])
	var glows: Array = []
	for g: Dictionary in k["glows"]:
		glows.append([g["id"], _enc_body(g["at"]), floor3(g["until"])])
	var toys: Array = []
	for g: Dictionary in k["toys"]:
		var row := [g["id"], _enc_body(g["at"]), floor3(g["start"]), floor3(g["end"])]
		if g.has("from"):
			row.append_array([_enc_body(g["from"]), floor3(g["launch"]), floor3(g["land"])])
		toys.append(row)
	var timers: Array = []
	for r: Dictionary in k["timers"]:
		timers.append([r["playerId"], floor3(r["juice"]), floor3(r["flash"])])
	return [credits, cabs, glows, toys, timers, floor3(k["wake"])]

static func dec_shop(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 6, 6)
	if c.bad:
		return {}
	var credits: Array = []
	for rw: Variant in _a(c, a[0], 0, 64):
		var r := _a(c, rw, 2, 2)
		if c.bad:
			return {}
		credits.append({"playerId": _s(c, r[0]), "credits": _i(c, r[1], 0, MAX_COUNT)})
	var cabs: Array = []
	for rw: Variant in _a(c, a[1], 0, 64):
		var r := _a(c, rw, 2, 2)
		if c.bad:
			return {}
		var slots: Array = []
		for sw: Variant in _a(c, r[1], Shop.CAB_MAX, Shop.CAB_MAX):
			if _is_num(sw) and float(sw) == 0.0:
				slots.append(["", 0])
				continue
			var s := _a(c, sw, 2, 2)
			if c.bad:
				return {}
			slots.append([_code(c, Inventory.ITEMS, s[0]), _i(c, s[1], 1, MAX_COUNT)])
		cabs.append({"playerId": _s(c, r[0]), "slots": slots})
	var glows: Array = []
	for gw: Variant in _a(c, a[2], 0, 256):
		var g := _a(c, gw, 3, 3)
		if c.bad:
			return {}
		glows.append({"id": _i(c, g[0], 0, MAX_COUNT), "at": _dec_body(c, g[1]), "until": _f(c, g[2])})
	var toys: Array = []
	for gw: Variant in _a(c, a[3], 0, 256):
		var g := _a(c, gw, 4, 7)
		if c.bad or g.size() not in [4, 7]:
			c.bad = true
			return {}
		var toy := {"id": _i(c, g[0], 0, MAX_COUNT), "at": _dec_body(c, g[1]), "start": _f(c, g[2]), "end": _f(c, g[3])}
		if g.size() == 7:
			toy["from"] = _dec_body(c, g[4])
			toy["launch"] = _f(c, g[5])
			toy["land"] = _f(c, g[6])
		toys.append(toy)
	var timers: Array = []
	for rw: Variant in _a(c, a[4], 0, 64):
		var r := _a(c, rw, 3, 3)
		if c.bad:
			return {}
		timers.append({"playerId": _s(c, r[0]), "juice": _f(c, r[1]), "flash": _f(c, r[2])})
	return {"credits": credits, "cabinets": cabs, "glows": glows, "toys": toys, "timers": timers, "wake": _f(c, a[5])}

## The find block (see the header) from its readable form {opened: [{piece, by, what, credits, note, fast, t}],
## searching: [{playerId, piece, fast, from, done}], items: [{playerId, juice}], base}.
static func enc_find(k: Dictionary) -> Array:
	var opened: Array = []
	for o: Dictionary in k["opened"]:
		opened.append([o["piece"], o["by"], Findables.WHAT.find(String(o["what"])), o["credits"], o["note"], 1 if o["fast"] else 0, q3(o["t"])])
	var searching: Array = []
	for s: Dictionary in k["searching"]:
		searching.append([s["playerId"], s["piece"], 1 if s["fast"] else 0, q3(s["from"]), q3(s["done"])])
	var items: Array = []
	for i: Dictionary in k["items"]:
		items.append([i["playerId"], i["juice"]])
	return [opened, searching, items, k["base"]]

static func dec_find(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 4, 4)
	if c.bad:
		return {}
	var opened: Array = []
	for ow: Variant in _a(c, a[0], 0, 1024):
		var o := _a(c, ow, 7, 7)
		if c.bad:
			return {}
		opened.append({"piece": _i(c, o[0], 0, MAX_COUNT), "by": _s(c, o[1]), "what": _code(c, Findables.WHAT, o[2]), "credits": _i(c, o[3], 0, MAX_COUNT),
			"note": _s(c, o[4], 16), "fast": _i(c, o[5], 0, 1) == 1, "t": _f(c, o[6])})
	var searching: Array = []
	for sw: Variant in _a(c, a[1], 0, 64):
		var s := _a(c, sw, 5, 5)
		if c.bad:
			return {}
		searching.append({"playerId": _s(c, s[0]), "piece": _i(c, s[1], 0, MAX_COUNT), "fast": _i(c, s[2], 0, 1) == 1, "from": _f(c, s[3]), "done": _f(c, s[4])})
	var items: Array = []
	for iw: Variant in _a(c, a[2], 0, 64):
		var i := _a(c, iw, 2, 2)
		if c.bad:
			return {}
		items.append({"playerId": _s(c, i[0]), "juice": _i(c, i[1], 0, MAX_COUNT)})
	return {"opened": opened, "searching": searching, "items": items, "base": _i(c, a[3], 0, MAX_COUNT)}

## The tune block (see the header) from its readable form [rev] or [rev, [[id, value], ...]].
static func enc_tune(k: Array) -> Array:
	if k.size() < 2:
		return [k[0]]
	var list: Array = []
	for e: Array in k[1]:
		list.append([String(e[0]), e[1]])
	return [k[0], list]

## The tune block: [rev] or [rev, [[id, value], ...]]. An entry this build's registry does not know, or whose
## value Settings.check refuses, is left out (never a reason to drop the snapshot).
static func dec_tune(c: _V, w: Variant) -> Array:
	var a := _a(c, w, 1, 2)
	if c.bad:
		return []
	var rev := _i(c, a[0], 1, MAX_COUNT)
	if a.size() == 1:
		return [rev]
	var list: Array = []
	for ew: Variant in _a(c, a[1], 0, 256):
		if not ew is Array or (ew as Array).size() != 2 or not (ew as Array)[0] is String or not _is_num((ew as Array)[1]):
			continue
		var id := StringName((ew as Array)[0])
		var why := Settings.check(id, (ew as Array)[1])
		if why == &"id" or why == &"range":
			continue
		list.append([String(id), float((ew as Array)[1])])
	return [rev, list]

## The watch block (see the header) from its readable form {need, watchers: [ids]}.
static func enc_watch(k: Dictionary) -> Array:
	var ids: Array = []
	for id: Variant in k["watchers"]:
		ids.append(String(id))
	return [k["need"], ids]

static func dec_watch(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 2, 2)
	if c.bad:
		return {}
	var ids: Array = []
	for id: Variant in _a(c, a[1], 0, 64):
		ids.append(_s(c, id))
	return {"need": _i(c, a[0], 1, 2), "watchers": ids}

## The downs block (see the header) from its readable form {down: [{id, at, until, by, healer, healFrom}],
## spots: [{playerId, x, z, level, y, t}]}. Opt-in Annex drag appends [rear yaw or null, Stillness hold].
static func enc_downs(k: Dictionary) -> Array:
	var down: Array = []
	for d: Dictionary in k["down"]:
		var row: Array = [d["id"], q3(d["at"]), q3(d["until"]), DOWN_BY.find(String(d["by"])), d["healer"], null if d["healFrom"] == null else q3(d["healFrom"])]
		var drag: Variant = d.get("drag")
		if d.get("healFor") != null or drag != null:
			row.append(null if d.get("healFor") == null else q3(d["healFor"]))
		if drag != null:
			row.append([null if drag["rear"] == null else q3(drag["rear"]), 1 if drag["held"] else 0])
		down.append(row)
	var spots: Array = []
	for p: Dictionary in k["spots"]:
		spots.append([p["playerId"], q2(p["x"]), q2(p["z"]), p["level"], q2(p["y"]), q3(p["t"])])
	return [down, spots]

static func dec_downs(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 2, 2)
	if c.bad:
		return {}
	var down: Array = []
	for dw: Variant in _a(c, a[0], 0, 64):
		var d := _a(c, dw, 6, 8)
		if c.bad:
			return {}
		var row := {"id": _s(c, d[0]), "at": _f(c, d[1]), "until": _f(c, d[2]), "by": _code(c, DOWN_BY, d[3]), "healer": _s(c, d[4]),
			"healFrom": _opt_num(c, d[5])}
		if d.size() > 6 and (d.size() == 7 or d[6] != null):
			row["healFor"] = _f(c, d[6], 0.0, 60.0)
		if d.size() == 8:
			var drag := _a(c, d[7], 2, 2)
			if c.bad:
				return {}
			row["drag"] = {"rear": null if drag[0] == null else _f(c, drag[0], -PI - 0.001, PI + 0.001),
				"held": _i(c, drag[1], 0, 1) == 1}
		down.append(row)
	var spots: Array = []
	for pw: Variant in _a(c, a[1], 0, 256):
		var p := _a(c, pw, 6, 6)
		if c.bad:
			return {}
		spots.append({"playerId": _s(c, p[0]), "x": _f(c, p[1], -MAX_COORD, MAX_COORD), "z": _f(c, p[2], -MAX_COORD, MAX_COORD), "level": _i(c, p[3], 0, 1),
			"y": _f(c, p[4], -MAX_COORD, MAX_COORD), "t": _f(c, p[5])})
	return {"down": down, "spots": spots}

## The annex block (see the header) from its readable form {pad, padSize, marks: [{id, x, z, level, dir,
## player, placedAt}], notesFrom, noteCount} and, in the welcome, notes: [{id, n, trigger, template, text,
## x, z, level, yaw, t}].
static func enc_annex(k: Dictionary) -> Array:
	var marks: Array = []
	for m: Dictionary in k["marks"]:
		marks.append([m["id"], q2(m["x"]), q2(m["z"]), m["level"], m["dir"], m["player"], q3(m["placedAt"])])
	var out: Array = [k["pad"], k["padSize"], marks, k["notesFrom"], k["noteCount"]]
	if k.get("notes") != null:
		var notes: Array = []
		for n: Dictionary in k["notes"]:
			notes.append([n["id"], n["n"], n["trigger"], n["template"], n["text"], q2(n["x"]), q2(n["z"]), n["level"], q3(n["yaw"]), q3(n["t"])])
		out.append(notes)
	return out

static func dec_annex(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 5, 6)
	if c.bad:
		return {}
	var marks: Array = []
	for mw: Variant in _a(c, a[2], 0, 256):
		var m := _a(c, mw, 7, 7)
		if c.bad:
			return {}
		marks.append({"id": _i(c, m[0], 0, MAX_COUNT), "x": _f(c, m[1], -MAX_COORD, MAX_COORD), "z": _f(c, m[2], -MAX_COORD, MAX_COORD),
			"level": _i(c, m[3], 0, 1), "dir": _i(c, m[4], 0, 7), "player": _s(c, m[5]), "placedAt": _f(c, m[6])})
	var out := {"pad": _i(c, a[0], 0, MAX_COUNT), "padSize": _i(c, a[1], 0, MAX_COUNT), "marks": marks, "notesFrom": _i(c, a[3], 0, MAX_COUNT),
		"noteCount": _i(c, a[4], 0, MAX_COUNT)}
	if a.size() > 5:
		var notes: Array = []
		for nw: Variant in _a(c, a[5], 0, 256):
			var n := _a(c, nw, 10, 10)
			if c.bad:
				return {}
			notes.append({"id": _i(c, n[0], 1, MAX_COUNT), "n": _i(c, n[1], 1, MAX_COUNT), "trigger": _s(c, n[2], 16), "template": _i(c, n[3], 0, MAX_COUNT),
				"text": _s(c, n[4], 512), "x": _f(c, n[5], -MAX_COORD, MAX_COORD), "z": _f(c, n[6], -MAX_COORD, MAX_COORD), "level": _i(c, n[7], 0, 1),
				"yaw": _f(c, n[8], -MAX_COORD, MAX_COORD), "t": _f(c, n[9])})
		out["notes"] = notes
	return out

## The quota block (see the header) from its readable form {earned, needed}.
static func enc_quota(q: Dictionary) -> Array:
	return [q["earned"], q["needed"]]

static func dec_quota(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 2, 2)
	if c.bad:
		return {}
	return {"earned": _i(c, a[0], 0, MAX_COUNT), "needed": _i(c, a[1], 0, MAX_COUNT)}

## The seek block (see the header) from its readable form {noise, counting, last, called, done, n, t0,
## len, by, why, ended, calmUntil, lastAt, players: [{id, hide, peek, phase, status, health, sight, gap,
## seat}]}.
static func enc_seek(k: Dictionary) -> Array:
	var flags := (1 if k["counting"] else 0) | (2 if k["last"] else 0) | (4 if k["called"] else 0) | (8 if k["done"] else 0)
	var players: Array = []
	for p: Dictionary in k["players"]:
		var pf := (1 if p["peek"] else 0) | (SEEK_PHASES.find(String(p["phase"])) << 1) | (SEEK_STATUSES.find(String(p["status"])) << 3)
		players.append([p["id"], p["hide"], pf, q2(p["health"]), q3(p["sight"]), q3(p["gap"]), p["seat"]])
	var out := [q2(k["noise"]), flags, k["n"], q3(k["t0"]), q3(k["len"]), k["by"], k["why"], k["ended"], q3(k["calmUntil"]),
		null if k["lastAt"] == null else q3(k["lastAt"]), players]
	# T15m (sim/seek.gd tune): the anger bar and the running count's seconds to hide.
	if k.has("anger"):
		out.append(q3(k["anger"]))
		out.append(q3(k["hide"]))
		# The party table (T15h): [fetcher id or "", host time their hold counts from or -1].
		if k.has("party"):
			var pt: Dictionary = k["party"]
			out.append([str(pt["by"]), q3(pt["from"])])
	return out

static func dec_seek(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 11, 14)
	if c.bad:
		return {}
	var f := _i(c, a[1], 0, 15)
	var players: Array = []
	for pw: Variant in _a(c, a[10], 0, 64):
		var p := _a(c, pw, 7, 7)
		if c.bad:
			return {}
		var pf := _i(c, p[2], 0, 31)
		players.append({"id": _s(c, p[0]), "hide": _i(c, p[1], -1, MAX_COUNT), "peek": (pf & 1) != 0, "phase": _code(c, SEEK_PHASES, (pf >> 1) & 3),
			"status": _code(c, SEEK_STATUSES, (pf >> 3) & 3), "health": _f(c, p[3], 0.0, 100.0), "sight": _f(c, p[4], 0.0, MAX_CLOCK),
			"gap": _f(c, p[5], 0.0, MAX_CLOCK), "seat": _i(c, p[6], -1, 64)})
	var out := {"noise": _f(c, a[0], 0.0, 1.0), "counting": (f & 1) != 0, "last": (f & 2) != 0, "called": (f & 4) != 0, "done": (f & 8) != 0,
		"n": _i(c, a[2], 0, MAX_COUNT), "t0": _f(c, a[3]), "len": _f(c, a[4], 0.0, MAX_CLOCK), "by": _s(c, a[5]), "why": _s(c, a[6]),
		"ended": _i(c, a[7], 0, MAX_COUNT), "calmUntil": _f(c, a[8]), "lastAt": _opt_num(c, a[9]), "players": players}
	if a.size() >= 13:
		out["anger"] = _f(c, a[11], 0.0, 1.0)
		out["hide"] = _f(c, a[12], 0.0, MAX_CLOCK)
		if a.size() == 14:
			var pt := _a(c, a[13], 2, 2)
			if c.bad:
				return {}
			out["party"] ={"by": _s(c, pt[0]), "from": _f(c, pt[1], -1.0, MAX_CLOCK)}
	elif a.size() != 11:
		c.bad = true
	return out

## The day block (see the header): {index, day, quota, streak, misses, inBed, countFrom, lightsOutAt,
## result, crew} as an array, with an optional last dictionary of owner IDs and loss denominators.
static func enc_day(d: Dictionary) -> Array:
	var in_bed: Array = []
	for id: Variant in d["inBed"]:
		in_bed.append(String(id))
	var out := [d["index"], d["day"], d["quota"], d["streak"], d["misses"], in_bed, d["countFrom"], d["lightsOutAt"], d["result"], d["crew"]]
	if d.has("earned"):
		# The day quota's lock (see the header): only with the lock on.
		out.append_array([d["earned"], 1 if bool(d["locked"]) else 0, d["aboard"], d["each"], d["stakes"]])
	if d.has("reel"):
		var r: Dictionary = d["reel"]
		out.append([r["day"], q3(r["started"]), r["crew"], r["votes"], 1 if r["skipped"] else 0])
	if d.has("lossOdds"):
		out.append(d["lossOdds"])
	return out

static func dec_day(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 10, 17)
	if c.bad:
		return {}
	var has_odds: bool = a[-1] is Dictionary
	var size := a.size() - (1 if has_odds else 0)
	if not size in [10, 11, 15, 16] or (has_odds and size < 15):
		c.bad = true
		return {}
	var in_bed: Array = []
	for id: Variant in _a(c, a[5], 0, 64):
		in_bed.append(_s(c, id))
	var result: Variant = a[8]
	if result != null and not result is Dictionary:
		c.bad = true
	var out := {"index": _i(c, a[0], 1, MAX_COUNT), "day": _i(c, a[1], 1, MAX_COUNT), "quota": _i(c, a[2], 0, MAX_COUNT), "streak": _i(c, a[3], 0, MAX_COUNT),
		"misses": _i(c, a[4], 0, MAX_COUNT), "inBed": in_bed, "countFrom": _opt_num(c, a[6]), "lightsOutAt": _opt_num(c, a[7]), "result": result,
		"crew": _i(c, a[9], 0, 64)}
	if size >= 15:
		out["earned"] = _i(c, a[10], 0, MAX_COUNT)
		out["locked"] = _i(c, a[11], 0, 1) == 1
		out["aboard"] = _i(c, a[12], 0, MAX_COUNT)
		out["each"] = _i(c, a[13], 0, MAX_COUNT)
		out["stakes"] = _s(c, a[14], 400)
	if size == 11 or size == 16:
		var r := _a(c, a[size - 1], 5, 5)
		if c.bad:
			return {}
		var votes: Array[String] = []
		for id: Variant in _a(c, r[3], 0, 64):
			votes.append(_s(c, id))
		out["reel"] = {"day": _i(c, r[0], 1, 3), "started": _f(c, r[1]), "crew": _i(c, r[2], 0, 64),
			"votes": votes, "skipped": _i(c, r[4], 0, 1) == 1}
	if has_odds:
		var wire: Dictionary = a[-1]
		if wire.is_empty() or wire.size() > 64:
			c.bad = true
			return {}
		var loss_odds := {}
		for id: Variant in wire:
			var owner := _s(c, id)
			if owner.is_empty():
				c.bad = true
			loss_odds[owner] = _i(c, wire[id], 1, MAX_COUNT)
		out["lossOdds"] = loss_odds
	return out

## The JSON text of a world snapshot (computed once per tick, shared by every client's snapshot).
static func world_json(w: Dictionary) -> String:
	return JsJson.stringify(enc_world(w))

## A snapshot's wire text. `head` has st, ackIn, echo, ackSeen, evFrom, place, stamina; `event_texts`
## are the JSON texts of its events; `world` is world_json() of the shared part.
static func snapshot_text(head: Dictionary, event_texts: PackedStringArray, world: String) -> String:
	var echo: Variant = head["echo"]
	var place: Variant = head["place"]
	var st: Variant = head.get("stamina")
	var parts := PackedStringArray([
		JsJson.num(head["st"]), str(head["ackIn"]),
		JsJson.stringify(echo) if echo != null else "0",
		str(head["ackSeen"]), str(head["evFrom"]),
		"[" + ",".join(event_texts) + "]",
		JsJson.stringify(_enc_place(place)) if place != null else "0",
		JsJson.stringify(_enc_tank(st)) if st != null else "0",
	])
	return "[%d,\"S\",[%s],%s]" % [PROTOCOL_VERSION, ",".join(parts), world]

## A player's tank in a snapshot: [level, winded], and its size in seconds when it is not
## Stamina.SPRINT_SECONDS (a paced run's, sim/run.gd paced), so a run without pace sends what it did before.
static func _enc_tank(st: Stamina.Stamina) -> Array:
	var a: Array = [q3(st.level), 1 if st.winded else 0]
	if st.tank != Stamina.SPRINT_SECONDS:
		a.append(q3(st.tank))
	return a

## A placement: [seq, depth, body], and the day index when the run has days.
static func _enc_place(place: Dictionary) -> Array:
	var a: Array = [place["seq"], place["depth"], _enc_body(place["body"])]
	if place.get("day") != null:
		a.append(place["day"])
	return a

## Serialises a message (input, join, welcome, leave, ping, pong, emote, emoted, face, setFace) to its
## wire text.
static func encode(m: Dictionary) -> String:
	match String(m["type"]):
		"input":
			var seen: Array = []
			for r: Dictionary in m["seen"]:
				var row: Array = [r["id"], r["depth"], r["a"], r["b"], q3(r["alpha"]), _enc_pose(r["pose"])]
				if int(r.get("n", 1)) == 2:
					row.append(2)
				seen.append(row)
			var flags := (1 if m["raised"] else 0) | (2 if m["holdDoors"] else 0) | (4 if m["seeing"] else 0) | (GAITS.find(String(m.get("gait", "walk"))) << 3) \
				| (32 if m.get("use", false) == true else 0) | (64 if m.get("peek", false) == true else 0) \
				| (128 if m.get("search", false) == true else 0) | (256 if m.get("searchFast", false) == true else 0) \
				| (512 if m.get("seeing2", false) == true else 0)
			var inp: Array = [PROTOCOL_VERSION, "I", m["seq"], floor3(m["ct"]), _enc_body(m["body"]), q2(m["eye"]), q3(m["yaw"]), q3(m["pitch"]),
				q2(m["hFovDeg"]), q2(m["vFovDeg"]), flags, m["calls"], m["pickUps"], m["ackEvent"], m["ackHt"], floor3(m["renderTime"]), m["placeAck"], seen]
			var marks := int(m.get("marks", 0))
			var peels := int(m.get("peels", 0))
			# The inventory (see the header): its four after the Annex's, which are then sent even when unused.
			var skip_at: Variant = m.get("skipReelAt")
			var inv := m.get("invSel") != null or int(m.get("invs", 0)) > 0 or skip_at != null
			if int(m.get("hides", 0)) > 0 or marks > 0 or peels > 0 or inv:
				inp.append(int(m.get("hides", 0)))
				inp.append(int(m.get("fastHides", 0)))
			if marks > 0 or peels > 0 or inv:
				inp.append(marks)
				inp.append(peels)
				inp.append(int(m.get("peelId", -1)))
			if inv:
				var op := String(m.get("invOp", ""))
				inp.append(int(m.get("invSel", -1)))
				inp.append(int(m.get("invs", 0)))
				inp.append(INV_OPS.find(op))
				inp.append(str(m["invArg"]) if op == "give" else (int(m["invArg"]) if op in ["take", "stash", "fetch", "buy", "skill", "lamp"] else 0))
			if skip_at != null:
				inp.append(q3(float(skip_at)))
			return JsJson.stringify(inp)
		"join":
			var j: Array = [PROTOCOL_VERSION, "J", m["name"], m["ct"]]
			var jf: Variant = m.get("face", "")
			if jf is String and not (jf as String).is_empty():
				j.append(jf)
			return JsJson.stringify(j)
		"face":
			return JsJson.stringify([PROTOCOL_VERSION, "F", m["player"], m["face"]])
		"setFace":
			return JsJson.stringify([PROTOCOL_VERSION, "C", m["face"]])
		"welcome":
			return JsJson.stringify([PROTOCOL_VERSION, "W", m["you"], m["seed"], 1 if m["playing"] else 0, m["evFrom"], enc_world(m["world"])])
		"leave":
			return JsJson.stringify([PROTOCOL_VERSION, "L"])
		"ping":
			return JsJson.stringify([PROTOCOL_VERSION, "P", m["ct"]])
		"pong":
			return JsJson.stringify([PROTOCOL_VERSION, "O", m["ct"], m["hr"], m["st"]])
		"emote":
			var k := EMOTES.find(String(m["emote"]))
			if k >= 0:
				return JsJson.stringify([PROTOCOL_VERSION, "E", k])
		"emoted":
			var k := EMOTES.find(String(m["emote"]))
			if k >= 0:
				return JsJson.stringify([PROTOCOL_VERSION, "M", m["player"], k, m["t"]])
		"telemetry":
			if String(m["kind"]) in ["rep", "crash"]:
				return JSON.stringify([PROTOCOL_VERSION, "T", m["kind"], m["body"], m["id"], m["part"], m["parts"]])
			return JSON.stringify([PROTOCOL_VERSION, "T", m["kind"], m["body"]])
	push_error("protocol: cannot encode %s" % str(m["type"]))
	return ""

# ---------------------------------------------------------------------------------------------
# Reading (and validating) the wire form.

class _V:
	var bad := false

static func _is_num(v: Variant) -> bool:
	return (v is float and not is_nan(v) and not is_inf(v)) or v is int

static func _f(c: _V, v: Variant, lo: float = -MAX_CLOCK, hi: float = MAX_CLOCK) -> float:
	if not _is_num(v) or float(v) < lo or float(v) > hi:
		c.bad = true
		return 0.0
	return float(v)

## An integral number in [lo, hi].
static func _i(c: _V, v: Variant, lo: int, hi: int) -> int:
	if not _is_num(v) or float(v) != floorf(float(v)) or float(v) < lo or float(v) > hi:
		c.bad = true
		return 0
	return int(v)

static func _s(c: _V, v: Variant, max_len: int = 64) -> String:
	if not v is String or (v as String).length() > max_len:
		c.bad = true
		return ""
	return v

static func _a(c: _V, v: Variant, min_size: int, max_size: int) -> Array:
	if not v is Array or (v as Array).size() < min_size or (v as Array).size() > max_size:
		c.bad = true
		return []
	return v

static func _code(c: _V, list: Array[String], v: Variant) -> String:
	var k := _i(c, v, 0, list.size() - 1)
	return "" if c.bad else list[k]

static func _dec_body(c: _V, w: Variant) -> Move.Body:
	var a := _a(c, w, 4, 4)
	if c.bad:
		return null
	var x := _f(c, a[0], -MAX_COORD, MAX_COORD)
	var z := _f(c, a[1], -MAX_COORD, MAX_COORD)
	var y := _f(c, a[2], -MAX_COORD, MAX_COORD)
	var level := _i(c, a[3], 0, 1)
	return Move.Body.make(x, z, level, y)

static func _dec_pose(c: _V, w: Variant, min_size: int = 7, max_size: int = 7) -> Dictionary:
	var a := _a(c, w, min_size, max_size)
	if c.bad:
		return {}
	return {"x": _f(c, a[0], -MAX_COORD, MAX_COORD), "z": _f(c, a[1], -MAX_COORD, MAX_COORD), "y": _f(c, a[2], -MAX_COORD, MAX_COORD),
		"level": _i(c, a[3], 0, 1), "yaw": _f(c, a[4], -MAX_COORD, MAX_COORD), "anim": _code(c, ANIMS, a[5]), "animTime": _f(c, a[6])}

static func _dec_tape(c: _V, w: Variant, min_size: int = 4) -> Dictionary:
	var a := _a(c, w, min_size, min_size + 1)
	if c.bad:
		return {}
	var out := {"id": _s(c, a[0]), "owner": _s(c, a[1]), "readings": _i(c, a[2], 0, MAX_COUNT), "total": _f(c, a[3])}
	if a.size() > min_size:
		out["found"] = _f(c, a[min_size], 0.0, MAX_CLOCK)
	return out

static func _opt_num(c: _V, v: Variant) -> Variant:
	return null if v == null else _f(c, v)

static func dec_world(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 15, WORLD_FLOOR_EXTENSIONS_INDEX + 1)
	if c.bad:
		return {}
	var blink: Variant = null
	if not (_is_num(a[9]) and float(a[9]) == 0.0):
		var b := _a(c, a[9], 6, 6)
		if c.bad:
			return {}
		blink = {"at": _f(c, b[0]), "announced": _f(c, b[1]) == 1.0, "endsAt": _opt_num(c, b[2]), "len": _f(c, b[3]), "warn": _f(c, b[4]), "blackout": _f(c, b[5]) == 1.0}
	var ow := _a(c, a[10], 10, 12)
	if c.bad or ow.size() == 11:
		c.bad = true
		return {}
	var orderly := _dec_pose(c, ow, 10, 12)
	orderly["speed"] = _f(c, ow[7])
	orderly["frozen"] = _f(c, ow[8]) == 1.0
	orderly["mode"] = _code(c, MODES, ow[9])
	if ow.size() > 11:
		orderly["windUp"] = {"target": _s(c, ow[10]), "left": _f(c, ow[11])}
	var players: Array = []
	for pw: Variant in _a(c, a[11], 0, 64):
		var p := _a(c, pw, 8, 8)
		if c.bad:
			return {}
		var f := _i(c, p[7], 0, 1023)
		players.append({
			"id": _s(c, p[0]), "body": _dec_body(c, p.slice(1, 5)), "yaw": _f(c, p[5]), "pitch": _f(c, p[6]),
			"active": (f & 1) != 0, "aboard": (f & 2) != 0, "connected": (f & 4) != 0,
			"side": "bank" if f & 8 else ("down" if f & 16 else null),
			"status": _code(c, STATUSES, ((f >> 5) & 3) | (((f >> 9) & 1) << 2)), "gait": _code(c, GAITS, (f >> 7) & 3),
		})
	var crew: Array = []
	for mw: Variant in _a(c, a[12], 0, 64):
		var m := _a(c, mw, 8, 8)
		if c.bad:
			return {}
		var carrying: Array = []
		for tw: Variant in _a(c, m[7], 0, 256):
			carrying.append(_dec_tape(c, tw))
		crew.append({"id": _s(c, m[0]), "needle": _code(c, NEEDLES, m[1]), "raised": _f(c, m[2]) == 1.0, "open": _f(c, m[3]),
			"rate": _f(c, m[4]), "tickHz": _f(c, m[5]), "tape": _dec_tape(c, m[6]), "carrying": carrying})
	var fl: Array = []
	for fw: Variant in _a(c, a[13], 0, 1024):
		var fa := _a(c, fw, 5, 6)
		if c.bad:
			return {}
		var t := _dec_tape(c, fa.slice(0, fa.size() - 1))
		t["at"] = _dec_body(c, fa[fa.size() - 1])
		fl.append(t)
	var summary: Variant = a[14]
	if summary != null and not summary is Dictionary:
		c.bad = true
	var out := {
		"tick": _i(c, a[0], 0, MAX_COUNT), "ht": _f(c, a[1]), "phase": _code(c, PHASES, a[2]), "depth": _i(c, a[3], 0, 100000),
		"timer": _f(c, a[4]), "floorsAway": null if a[5] == null else _i(c, a[5], -100000, 100000), "bellLeft": _f(c, a[6]),
		"holdLeft": _f(c, a[7]), "held": _f(c, a[8]) == 1.0, "blink": blink, "orderly": orderly, "players": players, "crew": crew,
		"floor": fl, "summary": summary,
	}
	if a.size() > 15 and a[15] != null:
		out["day"] = dec_day(c, a[15])
	if a.size() > 16 and (a[16] != null or a.size() == 17):
		out["seek"] = dec_seek(c, a[16])
	if a.size() > 17 and (a[17] != null or a.size() == 18):
		out["quota"] = dec_quota(c, a[17])
	if a.size() > 18 and (a[18] != null or a.size() == 19):
		out["annex"] = dec_annex(c, a[18])
	if a.size() > 19 and (a[19] != null or a.size() == 20):
		out["downs"] = dec_downs(c, a[19])
	if a.size() > 20 and (a[20] != null or a.size() == 21):
		out["watch"] = dec_watch(c, a[20])
	if a.size() > 21 and (a[21] != null or a.size() == 22):
		out["reloc"] = _i(c, a[21], 0, MAX_COUNT)
	if a.size() > 22 and (a[22] != null or a.size() == 23):
		out["lonely"] = _s(c, a[22], MAX_NAME * 2)
	if a.size() > 23 and (a[23] != null or a.size() == 24):
		out["solid"] = _i(c, a[23], SOLID_BASELINE, SOLID_RESTORED)
	if a.size() > 24 and (a[24] != null or a.size() == 25):
		out["tune"] = dec_tune(c, a[24])
	if a.size() > 25 and (a[25] != null or a.size() == 26):
		out["find"] = dec_find(c, a[25])
	if a.size() > 26 and (a[26] != null or a.size() == 27):
		out["inv"] = dec_inv(c, a[26])
	if a.size() > WORLD_SHOP_INDEX and a[WORLD_SHOP_INDEX] != null:
		out["shop"] = dec_shop(c, a[WORLD_SHOP_INDEX])
	if a.size() > WORLD_FLOOR_EXTENSIONS_INDEX:
		if not a[WORLD_FLOOR_EXTENSIONS_INDEX] is Dictionary:
			c.bad = true
			return {}
		var extensions: Dictionary = a[WORLD_FLOOR_EXTENSIONS_INDEX]
		if extensions.has("o2"):
			var o2 := _a(c, extensions["o2"], 3, 3)
			if c.bad:
				return {}
			out["orderly2"] = _dec_orderly(c, o2[0])
			out["reloc2"] = _i(c, o2[1], 0, MAX_COUNT)
			if not (_is_num(o2[2]) and float(o2[2]) == 0.0):
				out["watch2"] = dec_watch(c, o2[2])
			if c.bad:
				return {}
		if extensions.has("cycle"):
			out["cycle"] = _i(c, extensions["cycle"], 2, 100000)
		if extensions.has("nerve"):
			var nerve := _a(c, extensions["nerve"], 5, 7)
			if c.bad or nerve.size() == 6:
				c.bad = true
				return {}
			out["nerve"] = [_f(c, nerve[0], 0.0, Run.Nerve.FULL),
				_f(c, nerve[1], -Run.Nerve.FULL, 0.0), _f(c, nerve[2], -Run.Nerve.FULL, 0.0),
				_f(c, nerve[3], -Run.Nerve.FULL, 0.0), _f(c, nerve[4], 0.0, Run.Nerve.FULL)]
			if nerve.size() == 7:
				out["nerve"].append(_f(c, nerve[5], -Run.Nerve.FULL, 0.0))
				out["nerve"].append(float(_i(c, nerve[6], 0, 1)))
		if extensions.has("tenant"):
			var tenant := _a(c, extensions["tenant"], 2, 2)
			if c.bad:
				return {}
			out["tenant"] = {"at": _f(c, tenant[0], 0.0, MAX_CLOCK), "len": _f(c, tenant[1], 0.0, 3600.0)}
		if extensions.has("lamps"):
			var lamps: Array[Dictionary] = []
			var ids := {}
			for entry: Variant in _a(c, extensions["lamps"], 0, 8):
				var l := _a(c, entry, 9, 9)
				if c.bad:
					return {}
				var id := _s(c, l[0])
				if id.is_empty() or ids.has(id):
					c.bad = true
				ids[id] = true
				lamps.append({"playerId": id, "on": _i(c, l[1], 0, 1) == 1, "charge": _f(c, l[2], 0.0, 180.0),
					"x": _f(c, l[3]), "y": _f(c, l[4]), "z": _f(c, l[5]),
					"yaw": _f(c, l[6]), "pitch": _f(c, l[7]), "range": _f(c, l[8], 5.0, 22.0)})
			out["lamps"] = lamps
		if extensions.has("flares"):
			var bursts: Array[Dictionary] = []
			for entry: Variant in _a(c, extensions["flares"], 0, 32):
				var b := _a(c, entry, 7, 7)
				if c.bad:
					return {}
				bursts.append({"id": _i(c, b[0], 1, MAX_COUNT), "x": _f(c, b[1]), "y": _f(c, b[2]),
					"z": _f(c, b[3]), "until": _f(c, b[4], 0.0), "blind": _s(c, b[5]), "blindUntil": _f(c, b[6], 0.0)})
			out["flares"] = bursts
		# Practice pop times, or -1 for a prop the party has not reached. The state survives late entry.
		if extensions.has("orientationStandees"):
			var stamps := _a(c, extensions["orientationStandees"], 2, 2)
			if c.bad:
				return {}
			out["orientationStandees"] = [_f(c, stamps[0], -1.0), _f(c, stamps[1], -1.0)]
		if extensions.has("reactor"):
			var reactor: Variant = ReactorWire.decode(extensions["reactor"])
			if reactor == null:
				c.bad = true
			else:
				out["reactor"] = reactor
		if extensions.has("ward"):
			var ward := WardWire.decode(extensions["ward"])
			if ward.is_empty():
				c.bad = true
			else:
				out["ward"] = ward
		for key: String in ["skills", "wind", "shoes", "porter", "longBurn", "medic", "steady", "listener"]:
			if not extensions.has(key):
				continue
			var skills := _a(c, extensions[key], 0, 8)
			var rows := {}
			for entry: Variant in skills:
				var row := _a(c, entry, 2, 2)
				if c.bad:
					return {}
				var pid := _s(c, row[0])
				if pid.is_empty() or rows.has(pid):
					c.bad = true
				var max_status := 4 if key in ["porter", "medic", "steady", "listener"] else (3 if key == "wind" else 2)
				rows[pid] = _i(c, row[1], 0, max_status)
			out[key] = rows
	return out

static func _dec_report(c: _V, w: Variant) -> Dictionary:
	var a := _a(c, w, 6, 7)
	if c.bad:
		return {}
	var r := {"id": _i(c, a[0], 1, MAX_COUNT), "depth": _i(c, a[1], 0, 100000), "a": _i(c, a[2], 0, MAX_COUNT), "b": _i(c, a[3], 0, MAX_COUNT),
		"alpha": _f(c, a[4], 0.0, 1.0), "pose": _dec_pose(c, a[5])}
	if a.size() == 7:
		r["n"] = _i(c, a[6], 2, 2)
	return r

## Parses wire text; null for anything malformed, out of range or from another protocol version.
static func decode(text: String) -> Variant:
	var p := JsJson.parse(text)
	if not p.ok or not p.value is Array:
		return null
	var a: Array = p.value
	if a.size() < 2 or not _is_num(a[0]) or float(a[0]) != PROTOCOL_VERSION or not a[1] is String:
		return null
	var c := _V.new()
	var out: Dictionary
	match String(a[1]):
		"S":
			if a.size() != 4:
				return null
			var h := _a(c, a[2], 7, 8)
			if c.bad:
				return null
			out = dec_world(c, a[3])
			if c.bad:
				return null
			out["type"] = "snap"
			out["st"] = _f(c, h[0])
			out["ackIn"] = _i(c, h[1], 0, MAX_COUNT)
			if _is_num(h[2]) and float(h[2]) == 0.0:
				out["echo"] = null
			else:
				var e := _a(c, h[2], 2, 2)
				out["echo"] = [_f(c, e[0]), _f(c, e[1])] if not c.bad else null
			out["ackSeen"] = _i(c, h[3], 0, MAX_COUNT)
			out["evFrom"] = _i(c, h[4], 0, MAX_COUNT)
			var evs := _a(c, h[5], 0, 100000)
			for e: Variant in evs:
				if not e is Dictionary:
					c.bad = true
			out["events"] = evs
			if _is_num(h[6]) and float(h[6]) == 0.0:
				out["place"] = null
			else:
				var pl := _a(c, h[6], 3, 4)
				out["place"] = {"seq": _i(c, pl[0], 0, MAX_COUNT), "depth": _i(c, pl[1], 0, 100000), "body": _dec_body(c, pl[2])} if not c.bad else null
				if not c.bad and pl.size() > 3:
					out["place"]["day"] = _i(c, pl[3], 1, MAX_COUNT)
			out["stamina"] = null
			if h.size() > 7 and not (_is_num(h[7]) and float(h[7]) == 0.0):
				var sa := _a(c, h[7], 2, 3)
				if not c.bad:
					var st := Stamina.Stamina.new()
					st.level = maxf(0.0, minf(1.0, _f(c, sa[0])))
					st.winded = _f(c, sa[1]) == 1.0
					if sa.size() > 2:
						st.tank = _f(c, sa[2], 1.0, 60.0)
					out["stamina"] = st
		"I":
			if a.size() != 18 and a.size() != 20 and a.size() != 23 and a.size() != 27 and a.size() != 28:
				return null
			var f := _i(c, a[10], 0, 1023)
			var gait := (f >> 3) & 3
			if gait > 2:
				return null
			var seen: Array = []
			for r: Variant in _a(c, a[17], 0, MAX_SEEN):
				seen.append(_dec_report(c, r))
			out = {
				"type": "input", "seq": _i(c, a[2], 1, MAX_COUNT), "ct": _f(c, a[3]), "body": _dec_body(c, a[4]),
				"eye": _f(c, a[5], 0.0, 10.0), "yaw": _f(c, a[6], -MAX_COORD, MAX_COORD), "pitch": _f(c, a[7], -MAX_COORD, MAX_COORD),
				"hFovDeg": _f(c, a[8], 1.0, 180.0), "vFovDeg": _f(c, a[9], 1.0, 180.0),
				"raised": (f & 1) != 0, "holdDoors": (f & 2) != 0, "seeing": (f & 4) != 0, "gait": GAITS[gait],
				"calls": _i(c, a[11], 0, MAX_COUNT), "pickUps": _i(c, a[12], 0, MAX_COUNT), "ackEvent": _i(c, a[13], 0, MAX_COUNT),
				"ackHt": _f(c, a[14]), "renderTime": _f(c, a[15]), "placeAck": _i(c, a[16], 0, MAX_COUNT), "seen": seen,
			}
			if f & 32:
				out["use"] = true
			if f & 64:
				out["peek"] = true
			if f & 128:
				out["search"] = true
			if f & 256:
				out["searchFast"] = true
			if f & 512:
				out["seeing2"] = true
			if a.size() == 20 or (a.size() >= 23 and not (_is_num(a[18]) and float(a[18]) == 0.0)):
				out["hides"] = _i(c, a[18], 1, MAX_COUNT)
				out["fastHides"] = _i(c, a[19], 0, out["hides"])
			elif a.size() >= 23 and not (_is_num(a[19]) and float(a[19]) == 0.0):
				return null
			if a.size() >= 23:
				out["marks"] = _i(c, a[20], 0, MAX_COUNT)
				out["peels"] = _i(c, a[21], 0, MAX_COUNT)
				out["peelId"] = _i(c, a[22], -1, MAX_COUNT)
			if a.size() == 28:
				out["skipReelAt"] = _f(c, a[27])
			if a.size() >= 27:
				# The inventory (see the header).
				out["invSel"] = _i(c, a[23], -1, Inventory.SLOTS - 1)
				out["invs"] = _i(c, a[24], 0, MAX_COUNT)
				var op := _code(c, INV_OPS, a[25])
				out["invOp"] = op
				if op == "give":
					out["invArg"] = _s(c, a[26])
				elif op == "take":
					out["invArg"] = _i(c, a[26], 0, MAX_COUNT)
				elif op == "stash":
					out["invArg"] = _i(c, a[26], 0, Inventory.SLOTS - 1)
				elif op == "fetch":
					out["invArg"] = _i(c, a[26], 0, Shop.CAB_MAX - 1)
				elif op == "buy":
					out["invArg"] = _i(c, a[26], 0, Shop.ITEMS.size() - 1)
				elif op == "skill":
					out["invArg"] = _i(c, a[26], 0, 9)
				elif op == "lamp":
					out["invArg"] = _i(c, a[26], 0, 1)
				else:
					out["invArg"] = _i(c, a[26], 0, 0)
		"J":
			# [1, "J", name, ct] or [1, "J", name, ct, face]; a face that is not valid is no face.
			if a.size() != 4 and a.size() != 5:
				return null
			out = {"type": "join", "name": _s(c, a[2], MAX_NAME), "ct": _f(c, a[3])}
			if a.size() == 5:
				var jf := valid_face(a[4])
				if jf != "":
					out["face"] = jf
		"F":
			# The host passes a player's face on: [1, "F", player id, face]. Only valid faces.
			if a.size() != 4:
				return null
			var ff := valid_face(a[3])
			if ff == "":
				return null
			out = {"type": "face", "player": _s(c, a[2]), "face": ff}
		"C":
			# A player's new face: [1, "C", face]. A face that is not valid is "" (ignored by the host).
			if a.size() != 3:
				return null
			out = {"type": "setFace", "face": valid_face(a[2])}
		"W":
			if a.size() != 7:
				return null
			out = {"type": "welcome", "you": _s(c, a[2]), "seed": _s(c, a[3], 256), "playing": _f(c, a[4]) == 1.0, "evFrom": _i(c, a[5], 0, MAX_COUNT), "world": dec_world(c, a[6])}
		"L":
			if a.size() != 2:
				return null
			out = {"type": "leave"}
		"P":
			if a.size() != 3:
				return null
			out = {"type": "ping", "ct": _f(c, a[2])}
		"O":
			if a.size() != 5:
				return null
			out = {"type": "pong", "ct": _f(c, a[2]), "hr": _f(c, a[3]), "st": _f(c, a[4])}
		"E":
			# A player's emote: [1, "E", index into EMOTES].
			if a.size() != 3:
				return null
			out = {"type": "emote", "emote": _code(c, EMOTES, a[2])}
		"M":
			# The host passes an emote on: [1, "M", player id, index into EMOTES, host time].
			if a.size() != 5:
				return null
			out = {"type": "emoted", "player": _s(c, a[2]), "emote": _code(c, EMOTES, a[3]), "t": _f(c, a[4])}
		"T":
			# Telemetry (see TELEMETRY_KINDS): [1, "T", kind, body] or, for a report, [..., id, part, parts].
			if a.size() < 4 or not a[2] is String or not (a[2] as String) in TELEMETRY_KINDS:
				return null
			var report := String(a[2]) in ["rep", "crash"]
			if a.size() != (7 if report else 4):
				return null
			out = {"type": "telemetry", "kind": a[2], "body": _s(c, a[3], MAX_TELEMETRY_PART if report else MAX_TELEMETRY_LINE)}
			if report:
				out["parts"] = _i(c, a[6], 1, MAX_TELEMETRY_PARTS)
				out["id"] = _i(c, a[4], 1, MAX_COUNT)
				out["part"] = _i(c, a[5], 0, int(out["parts"]) - 1)
		_:
			return null
	return null if c.bad else out

## `v` if it is a valid face (a String of at most Face.MAX_LENGTH characters that FaceCodec accepts),
## else "". The length is checked before anything is read.
static func valid_face(v: Variant) -> String:
	if not v is String or (v as String).length() > Face.MAX_LENGTH or (v as String).is_empty():
		return ""
	return v if Face.check(v) == "" else ""

## Size of a message on the wire in bytes (its UTF-8 text).
static func message_bytes(text: String) -> int:
	return text.to_utf8_buffer().size()
