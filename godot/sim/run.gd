# A run: the ride down. Pure, deterministic logic for the shape of a run and the elevator's rules;
# no rendering, audio or engine code. The game calls step_run once per logic tick.
# Port of src/sim/run.ts.
#
# The elevator is the bank, the briefing room and the only safe place. Per tick, in this order:
#   1. run rules: phase timers, the call and its indicator, light blinks, boarding, votes, the
#      bell, departures and arrivals;
#   2. the Orderly, with every player `blind` during a blink, players inside the car never
#      huntable, and (while the car is coming) the call itself as a blind target at the landing;
#   3. the crew's instruments, then pick-ups; readings that close are multiplied by the depth's pay.
#
# The car is the void 4 m by 4 m space on the far side of the landing's elevator wall (landing.gd says
# which wall): centred on the landing cell's wall, two cells deep (North Star C5, owner decision V9: "about
# four metres square, so a full crew fits and has room to change sides before the bell"). The floor plans
# keep that space void on both levels (clinic.gd, annex.gd, prison.gd). It is outside the floor plan, so nothing that moves with the plan's collision (the Orderly)
# can ever enter it; run.gd checks that anyway every tick and puts it back if it ever ended inside.
# Players get in and out through the doorway with move_in_run, which knows when the doors are open.
#
# Choices made where the design is silent (also listed in the report):
#  - Seeing out of the car: with the doors open, a player inside sees the floor as if their eyes stood
#    on the threshold (generous: it can only add sightings). With the doors shut they see nothing out.
#  - "Drawn to the call": the call is an extra blind target at the landing; the Orderly hunts the
#    nearest of it and the players by walking distance, and the pull ends once it is within
#    LURE_DROP_DISTANCE of the landing. A waiting Orderly is not woken by the call.
#  - Arrival: anyone still in the car when the arrival doors close is put out onto the landing.
#  - Caught players stay inactive until the car next RIDES DOWN (not when it leaves empty).
#  - The depth multiplier compounds and is applied when a reading closes onto a tape.
#  - Each floor's Orderly is a new subject (entity id `orderly-<depth>`), so repeat factors restart.
#  - Which place a floor is comes from the run's deck (places.gd): Clinic only unless the caller passes
#    another, so a run made without one is the run every stored result was recorded from. The game
#    passes Places.FULL. The floor's resident is driven by "the Orderly" below whoever it is: the Temp
#    keeps the Orderly's rules in its own body (T16f); the Playroom's Minder is stepped by sim/seek.gd
#    (see "The Playroom" below), and `orderly` carries its pose so the network and the views are unchanged.
#  - The lights while the car comes (dark_schedule): blinks that grow, then the blackout, ending on the
#    tick the car arrives. A false stop (one floor above, in the last few seconds) always falls inside
#    the blackout: it is heard in the dark, and the blackout still ends as the doors really open.
#  - In the blackout the Orderly hunts at BLACKOUT_HUNT_SPEED and does not creep up on still prey (the
#    creep is there so a recorder can time a turn; nobody can see to do that in the dark). In the
#    short blinks it hunts exactly as before.
#  - BANK is the left half of the car as you walk in, DOWN the right half.
#
# The day (docs/floors/prison.md P7; loop/NIGHT-PLAN.md A2), on only for a run made with days
# (create_run's `days`, with_days(): the game's rooms turn it on; tests and every stored result leave it
# off, and then nothing below happens). With it on a run is a run of days:
#  - BANK banks the tapes aboard exactly as before ("banked"), then settles the day with sim/day.gd
#    (Day.end_day on the banked total floored to whole credits: "dayEnded" with its facts), and the car
#    rides UP for RIDE_UP_TIME ("carLeft" reason "up"). Everyone gets a fresh empty tape at once, so no
#    tape can be banked twice; tapes on the floor and those of players not aboard are lost, as on a ride.
#  - A wipe settles the day with nothing banked, and the empty car rides up the same way.
#  - Arriving home: depth 0, the prison plan (Places.generate at depth 0), no resident (it is parked and
#    never stepped). Players aboard step out of the car; everyone else (left behind, caught, or all of
#    them after a wipe) wakes on their own bunk (Day.bunk_of), on their feet ("rodeUp", with bodies).
#    The doors open as on any floor; when they close the phase is "night" and the car cannot be called.
#  - Bed: hold F (PlayerInput.use) for BED_HOLD seconds standing on any bunk's cell to lie down; a new
#    press of F gets you up. The count is Day's: lights out LIGHTS_OUT_DELAY after more than half the
#    crew is in bed, or as soon as everyone is; once started it cannot be stopped ("bed", "bedCount",
#    "lightsOut"). A player who is no longer on their feet (left the game) leaves the count.
#  - Day.LIGHTS_OUT_SECONDS after lights out the next day starts as day 1 did: the crew in the car at
#    depth 1, doors about to open, the floors drawn from the day's seed day_seed(seed, n) =
#    "<seed>:day<n>" (day 1 keeps the run's seed). n counts every day of the run, so a seed never
#    comes back, even after a game over resets the day number ("newDay", with bodies).
#  - The tapes are numbered on across days (the crew's next_tape carries on), so every tape id is new.
# The facts of the day just settled stay on the state (day_result) until the next morning.
#
# The Playroom (docs/floors/playarea.md; loop/NIGHT-PLAN.md A3, T15d). On a floor whose place is the
# Playroom, with its resident on (seek_off false), the run holds sim/seek.gd's state (`seek`) and steps
# it instead of the Orderly's rules, every tick except while riding (that floor is behind the crew):
#  - Inputs: each active player who is out of the car, with their gait, the hide key (PlayerInput.hide_use,
#    a press; hide_fast when sprint was held), W held (peek), a sound emote, the voice and a light; their
#    instrument ticked on the tick before (Instr ticks), a reason inside a hide. Players in the car are
#    not on the floor: they neither provoke nor are looked for.
#  - Found players are rooted: their input is their found spot, so the Minder can run them down. Taken
#    (at the party table) and down players give no input: their eyes and position count for nothing.
#    The tick after a "down" their dropped tape is heard (dropped_tape).
#  - Statuses: found, taken or down is the run's "caught" (out until the car next rides down, as any
#    catch). Bodies: a player getting into, sitting in or getting out of a hide, found, taken or down is
#    where the rules hold them (seek's body): the hide's inside or front spot, the found spot, the seat.
#  - The tape drops where a player is found or goes down (the instrument's "caught", not a run event).
#  - The instrument (playarea.md 11): trait "hearing", recording only during a count after the 6 s, and
#    only for a player out of its view, or peeking from a hide (EntityTick.acting, .holders).
#  - The call (phase away) starts the last count instead of the usual wait: phase "coming" with no call
#    schedule and no blinks ("called" with floorsAway 0 and last true). The car arrives, doors open, on
#    the tick of the last count's "countEnd". If the last count is already over (the car left empty), a
#    call is the usual wait.
#  - Every seek event is a run event, at its host time ("count" {n, t0, len, last, by, why}, "countEnd",
#    hide*, "found", "taken", "down", ...: sim/seek.gd lists them).
#
# The floor quota (North Star C9; T5q), on only for a run made with it (create_run's `quota`, with_quota():
# net/host_rules.gd turns it on for the game's rooms when the resident is on; tests and every stored result
# leave it off, and then nothing below happens). The call button does nothing until the crew has recorded
# enough on this floor:
#  - Needed: floor_quota(depth, crew), one number for the crew together. It is set while the car arrives
#    on the floor (with everyone in the run then, a player admitted at the stop included) and afterwards
#    only shrinks, if a player leaves the game. Never at home.
#  - Earned: every reading closed on this floor (its "readingClosed" value, depth pay included), whatever
#    happens to its tape afterwards: a tape dropped, left on the floor or lost still counts, so a lost tape
#    can never trap the crew. A reading still open counts once it closes.
#  - The call (phase away, the Playroom's last count included) with floor(earned) < needed is refused:
#    "callRefused" {playerId, earned, needed}, and nothing else happens (the resident does not hear it).
#  - The tick floor(earned) first reaches needed: "quotaMet" {depth, earned, needed, top: who recorded
#    the most here (for the Annex's note), or ""}, once per floor (not
#    on the ride away). Earned and needed go back to 0 and the new floor's quota on every new floor
#    ("rodeDown", "newDay"; at home needed is 0).
# The day loop's DAY_FLOOR_QUOTA is floor 1's quota per player, so the day quota is a whole number of
# floor 1 quotas for the morning's crew (docs/floors/prison.md section 2: one and a half on day 1).
#
# The day quota's lock (FD2; docs/floors/findables-and-day.md section 1, "What counts" and "The lock"), on
# only for a run made with it (with_day_lock(), and only with days: net/host_rules.gd turns it on for the
# game's rooms whenever the floor quota is on; tests and every stored result leave it off, and then nothing
# below happens and a short BANK is a missed day as before):
#  - Earned (`day_earned`): every reading closed today, on any floor (its "readingClosed" value, depth pay
#    included; the bell's flush of open readings too), whatever happens to its tape afterwards. It never
#    falls within a day: a dropped tape, a player left behind or a drop-out cannot take it back. 0 every
#    morning ("newDay"); kept through the ride home and the night for the prison's board.
#  - BANK is locked while floor(earned) < the day quota (day_locked; Day.is_locked). At the bell, if BANK
#    has more feet than DOWN and BANK is locked, the vote is refused: "bell" {outcome "ride", refused true},
#    then "bankRefused" {bank, down, day, earned, quota}, and the car rides down exactly as if DOWN had won
#    (tapes stay with their holders, those not aboard are left behind, out players rejoin on the next
#    floor). A tie rides, as always.
#  - The tick floor(earned) first reaches the quota (not at home): "dayMet" {day, earned, quota}, once a day.
#  - So every BANK is made: Day.end_day pays what was aboard. A wipe is the missed day (Day.end_day wiped).
#  - day_preview() is Day.bank_preview for the run now: the lift monitor's three rows (aboard is the tapes
#    held by those on their feet in the car).
#
# The Annex (docs/floors/annex.md sections 2 and 4; loop/NIGHT-PLAN.md A6, T16h). On a floor whose place is
# the Annex the run holds `annex` (an AnnexFloor: the crew's marks and the Temp's sticky notes), made when
# the crew reaches the floor and dropped on the next; on any other floor it is null and nothing below
# happens. Everything in it is the host's, the same for everyone.
#  - Marks (sim/marks.gd): ONE pad for the whole crew, Marks.DEFAULT_PAD a floor (a new floor, a full pad).
#    PlayerInput.mark is a press of Q: the placing starts at the player's feet, pointing where they face
#    (snapped to eight), and the run finishes it Marks.PLACE_SECONDS later by itself ("markStart", then
#    "markPlaced" with the slap's radius, or "markRefused" {reason}: pad_empty, sprinting, down, in_car,
#    busy, gone). PlayerInput.peel is the id of a mark the player has held F on for Marks.PEEL_SECONDS
#    (the client times the hold): any player peels any mark within MARK_PEEL_REACH, and it goes back on
#    the pad ("markPeeled", or "markRefused" far / no_such_mark / down). Marks are immune: nothing but a
#    peel removes one, and nothing moves or changes one; the Temp never touches them.
#  - Sticky notes (sim/notes.gd, data/annex_notes.json): triggers are this tick's events: the arrival
#    doors opening ("lobby", posted at once on the wall nearest the lift doors), "startedHunting" ("wake"),
#    every NOTE_HUNT_EVERY seconds the Temp hunts ("hunt"), "caught" ("catch"), "tapeDropped" ("tape"),
#    "quotaMet" ("quota", by its top), "called" ("lift") and, with the down rule on, "healed" ("heal",
#    naming who was healed and who healed them). The Temp posts them: a trigger waits in a queue until a tick the Temp is not held (Stillness:
#    it never posts while anyone looks), one a tick, on the wall nearest the Temp. At most
#    Notes.cap_per_floor() a floor. Each posting is a "note" event {id, n, trigger, template, text, x, z,
#    level, yaw, t}: one loud click where the note is. The facts are true and the same for everyone:
#    names (from `names`, the host's player names), who is alone, who stands very close, who is furthest
#    from the lift, sprints this floor, notes per name, the pad's use; door passes and looking are not
#    tracked yet, so their notes are never used. Note ids count up over the whole run (note_seq).
#
# Two-watcher Stillness (docs/floors/traits-and-hiding.md section 1; T19a), on only for a run made with it
# (with_two_watchers(): net/host_rules.gd turns it on for the game's server rooms; tests and every stored
# result leave it off, and then one watcher always holds a Stillness resident, as before). With it on, every
# tick the run counts the up players (stillness_up_count: on their feet with an input) and gives the
# resident Entity.watch_need of them: 1 with one or two up, 2 with three or more. A down, caught, out or
# left-behind player is not up, so a crew of three with one down needs one (sim/entity.gd "Watchers").
#
# Relocation (docs/floors/traits-and-hiding.md section 5; T19e), on only for a run made with it (with_relocation():
# net/host_rules.gd turns it on for the game's rooms; tests and every stored result leave it off, and then nothing
# below happens). With it on, every tick after a Stillness resident is stepped, sim/relocate.gd may move it from a
# place nobody can see to another nobody can see, near a player: "relocated" {from, to, near (the player it went
# to), k (relocations on this floor), who (its body), reach (its arrival cue's reach, m), why (its trait's trigger:
# Stillness "dormant" or "far")}, the tick it happens; the
# event is its arrival cue. The run's part: the eyes (relocation_eyes: every player on their feet or down), the
# bars (the lobby, the landing, the car's zone, stairs, hide spots) and when it is free to (relocation_free: no
# blink, blackout or warning, the lift not boarding or riding). The trait decides the rest (sim/relocate.gd rows);
# only Stillness has one yet.
#
# The Temp's own mechanic, Lonely (docs/floors/traits-and-hiding.md section 2; T19c; sim/lonely.gd), on only for a
# run made with it (with_lonely(): net/host_rules.gd turns it on for the game's rooms; tests and every stored
# result leave it off, and then the Temp keeps the Orderly's Stillness, as before). With it on, the Annex's
# resident is Lonely (resident_of; Places.resident_in) and is stepped by sim/lonely.gd instead of Stillness: it
# only goes for a player who is alone (lonely_people: every player on their feet with an input, and every
# player down, is company), chases one in its sight within 16 m, breaks off the tick they have company. Looking
# at it does nothing. Its events: "chaseStarted" {playerId, at, yaw} and "chaseEnded" {playerId, why}. The
# instrument records it only while it chases, and only on the chased player's (EntityTick acting, holders).
# With relocation on, sim/relocate.gd's Lonely row moves it after a break-off or 20 s with nobody lonely. In a
# solo run it is Lonely too, chasing slower than a walk (sim/lonely.gd SOLO_CHASE_SPEED). On the Annex its
# notes gain two triggers: "chase" (note 7 naming the chased, where it stood) and "relocate" ("Gone to see
# {name}.", where it left from, naming who it went to); a chase note at most once per player per
# NOTE_HUNT_EVERY seconds.
#
# Down first, then out (North Star B6; loop/NIGHT-PLAN.md A5, T8a), on only for a run made with it
# (create_run's `downs`, with_downs(): net/host_rules.gd turns it on for the game's rooms; tests and every
# stored result leave it off, and then nothing below happens and a catch is "caught" as before). With it on:
#  - A catch ("caught", the resident's own event, kept for the screens and the Annex's note) puts the player
#    down where they stood: status "down" ("downed" {playerId, until, by: "catch", at}). The tape stays with
#    them for now. The resident bends over them (Entity.bend_over): while it has someone it goes after
#    nobody else, and its bend is the one movement it makes while watched (sim/entity.gd's exception).
#  - Health at 0 on the Playroom (sim/seek.gd "down") is the same down ("downed" by "health"); the Minder
#    does not bend. Found and taken stay the Playroom's own rule (caught, as before).
#  - A downed player crawls: their input body is followed at most CRAWL_SPEED, with the car's walls. They
#    are not active (no call, vote, pick-up, instrument, mark) and the resident neither sees nor hunts them.
#  - Healing: a player on their feet with F held (PlayerInput.use) within HEAL_REACH of the downed body, on
#    its level. The hold counts from the start of the tick it began ("healStart" {playerId: the healer,
#    target, from, done}: host times, the same on every screen); letting go, stepping out of reach or going
#    down stops it and the count starts again ("healStop" {playerId, target}). A downed player has one
#    healer at a time: the one already holding, else the nearest, and a healer heals one at a time. HEAL_TIME
#    seconds held: "healed" {playerId, by, at}, back on their feet where they lie (the Playroom: health
#    HEAL_HEALTH). The resident bent over them stands off, quiet (dormant) for HEAL_QUIET seconds.
#  - Not healed by DOWN_TIME seconds after going down (the host's clock, alone or not): "out" {playerId, at,
#    spot}: status "out", the tape drops where they lie (the instrument's "caught"), and a red spot is left
#    there (`spots`, {playerId, x, z, level, y, t}, this floor's, cleared on the next). The resident hunts
#    again from the next tick. Out is caught by another name: back on their feet when the car next rides
#    down (or rides home), as a catch always was.
#  - The car leaving without a downed player (a ride down or a BANK) puts them out ("out" with spot null).
#  - The wipe waits while anyone is down: a crew all out is a wipe; a crew all down is not yet.
#
# Hiding off the Playroom (docs/floors/traits-and-hiding.md section 4; T19b). On a Clinic or an Annex the
# run holds sim/hiding.gd's state (`hiding`), made at the first hide press on the floor (so a run where
# nobody hides is exactly the run every stored result was recorded from) and dropped on the next floor.
# The hides are sim/hides.gd's list, a pure function of the plan.
#  - Stepped before the resident, every tick except while riding, with each active player out of the car
#    on their feet: the hide key (PlayerInput.hide_use: F, or the client's Ctrl-walk into a desk; hide_fast),
#    W held (peek), their instrument ticking. Events: hideStart, hideIn, hideLeave, hideOut, hideFull, flap,
#    reason (sim/hiding.gd). Bodies: inside, the hide's inside spot; getting out, its front spot.
#  - The resident's view of a player inside (sim/entity.gd "Hidden players"): hidden, so never hunted or
#    reached for; sat back, blind; peeking, eyes at the hide's eye looking out of the gap (yaw clamped to
#    it, pitch to HIDE_PEEK_PITCH), so a peeker in Stillness's sight holds it. With a reason it looks in and
#    catches everyone inside ("caught", pulled out onto the front spot first); without one it stands where
#    it lost them, then hunts someone else.
#
# The owner's 17 Nov changes (build 0833), each on only for a run made with it (with_long_dark, with_paced,
# with_car_waits: net/host_rules.gd turns them on for the game's rooms; tests and every stored result leave
# them off, and then nothing below happens):
#  - The long dark (T20c, `long_dark`): the blackout before the car arrives lasts LONG_BLACKOUT_MIN..MAX
#    seconds (LONG_BLACKOUT_FIRST_MIN..MAX on the first floor) instead of BLACKOUT_MIN..MAX, but never so
#    long that the first blink of the ladder no longer fits before its warning (dark_schedule).
#  - Paced (T20h, `paced`): every player's tank holds Stamina.PACED_SPRINT_SECONDS of sprinting (the host
#    steps it with sprint_seconds(state)), and the Stillness residents hunt at PACED_HUNT_SPEED (in the
#    blackout PACED_BLACKOUT_HUNT_SPEED) so the chase is paced as before. The Playroom's Minder is unchanged.
#  - The car waits (FD4, `car_waits`; docs/floors/findables-and-day.md section 2): on arrival the doors stay
#    open until the car has been empty of active players for UNLOAD_EMPTY_CLOSE seconds, however long that
#    takes (no UNLOAD_TIME, nobody active is ever pushed out). A player aboard records nothing (their
#    instrument is not live in the car). When the car comes back for the crew, boarding lasts
#    BOARD_TIME_WAITS seconds before the bell. Anyone on their feet the car leaves on the floor (a ride down
#    or a BANK) is left out for the rest of the day (`left_out`): status "leftBehind", not brought back on the
#    next floor (they stand on its landing, out of the run), no share of the day's bank (the summary and
#    Day.end_day leave them out), and they wake on their bunk in the prison when the crew gets home (or after
#    a wipe), as everyone does.
#
# The Playroom tuned from the owner's first play (T15m, `playroom_tuned`, with_playroom_tuned: net/host_rules.gd
# turns it on for the game's rooms; tests and every stored result leave it off, and then nothing below happens).
# The run only hands it to sim/seek.gd (Seek.tune on the floor's seek state); the rules are seek.gd's "T15m"
# section: 30-45 s to hide, then a 30 s search; an anger bar the provocations fill, a count when it is full; the
# Minder grabs anyone within 1 m outside a count and drags them to the party table; and the hint events
# ("playroomArrived", "sprintDuringHunt") for the announcer.
# Solid furniture (FD7, `furniture`, with_furniture: docs/floors/findables-and-day.md section 4; net/host_rules.gd
# turns it on for the game's rooms; tests and every stored result leave it off, and then nothing below happens).
# Players' bodies (move_in_run: the local player, the bots, a crawl) slide along every solid piece of the
# floor's one list (sim/furniture.gd, Furniture.solids_of) as along walls, and a body found standing inside one
# (dragged, grabbed, relocated, or there when the flag turned on) is first pushed out to the nearest clear spot
# (Move.settle). With `resident_navigation` (T20k), the residents route around the same solid footprints.
# Findables (FD9, `findables`, with_findables: docs/floors/findables-and-day.md section 3; sim/findables.gd;
# net/host_rules.gd turns it on for the game's rooms; tests and every stored result leave it off, and then nothing
# below happens). On a Clinic or an Annex the run holds `find` (a Findables.FindFloor: the fill, what has been
# opened, the searches under way), made the first tick the arrival doors are open (the fill's credits are units
# of the floor's quota as set on arrival) and dropped on the next floor; `lore_used` keeps the lore pages dealt
# tonight; `items` what each player has found to carry, {id: {item: count}}.
#  - Stepped before the resident, every tick the doors have opened on the floor (not while riding), for every
#    player: F held (PlayerInput.search), sprint with it (search_fast), and able (on their feet, active, out of
#    the car, out of any hide, not sprinting). Findables.step says the rest (the two speeds, what stops a search,
#    one opening per piece). Its events are run events.
#  - While searching a player is rooted where the search began, their instrument is away (an open reading
#    closes as a lowered instrument's does), and their eyes are in the drawer: never a watcher (their view is
#    blind, as when sat back in a hide), still huntable. Lonely's company is unchanged.
#  - A rushed search's noise ("searchNoise") wakes a resident still standing where the floor began, as the call
#    does ("startedHunting").
#  - Credits found go onto the finder's own tape as a reading of trait "found" (entity "found", worth the
#    credits, never multiplied by depth), so they ride with the tape: dropped, picked up, banked and lost with
#    it, and banked as pay. They count towards the day's earned (with the day lock) the tick they are found,
#    and never towards the floor quota (no "readingClosed": the call still needs the instrument, C9).
#  - A carton of juice adds one to the finder's items[JUICE]. That is all, until the inventory and the nerve
#    bar exist: nothing drinks it, no stamina changes. Cartons do not go home: items empty every morning.
# The four-slot inventory (S1, `inventory`, with_inventory: docs/floors/skill-tree.md; sim/inventory.gd; net/host_rules.gd
# turns it on for the game's rooms; tests and every stored result leave it off, and then nothing below happens).
# `bags` holds each player's four slots, `pickups` what lies on this floor (gone when the plan changes).
#  - Stepped each tick after the crew's tapes (not on the tick the crew banks or the run ends): first everyone who is
#    not on their feet (down, caught, out, left behind) drops all they carry where they are ("itemDropped" {why:
#    "down"}); then, for each player on their feet and active, in the run's player order: the slot asked for
#    (PlayerInput.inv_select), then one request (inv_op): "drop" the selected slot at the feet, "take" a pickup in
#    reach (as much as fits), "give" the selected slot to a crewmate on their feet within the hand reach (as much
#    as fits). A request that cannot be done is refused ("invRefused" {playerId, op, why: full, theirFull, reach,
#    empty, gone}) and changes nothing.
#  - With findables, a carton found goes into the finder's bag instead of `items`. No room: the piece is not
#    opened, the carton stays in the furniture, and "searchFull" {playerId, piece} says so (searchDone is not sent).
#  - The morning clears every bag and every pickup.
# The shop and the cabinet (S2, T28 and T29, `shop`, with_shop: docs/floors/skill-tree.md sections 1, 2b and 5; sim/shop.gd;
# net/host_rules.gd turns it on for the game's rooms; it needs the inventory; tests and every stored result leave it off,
# and then nothing below happens). `shop_state` (Shop.ShopState) holds every cabinet and what the items left lit.
#  - The requests come as the inventory's (PlayerInput.inv_op, after its busy check): "stash" (inv_arg: your slot) puts
#    that slot into your own cabinet, "fetch" (inv_arg: the cabinet's slot) takes it out, both standing at your
#    cabinet (beside your bunk, Shop.cabinet_cell) in the prison, as much as fits ("stashed", "fetched"). Refused
#    ("invRefused" {why: reach, empty, cabFull, full}) changes nothing.
#  - "buy" (inv_arg: the item's index in Shop.ITEMS) at shop window 1 or 2, before bed: the price (Shop.price, the host's
#    shop.price.<item>) leaves the buyer's own wallet and the item goes into their hands ("bought" {item, price,
#    credits}). Refused (window, closed, busy, full, poor) it changes nothing.
#  - "use" (inv_arg 0): the item in the hand, if it is one of the shop's (_use_item); used, it leaves the hand ("itemUsed"
#    {item, ...}). Speed juice: Shop.JUICE_SECONDS of sprint that costs no stamina (net/host.gd holds the tank full),
#    then "juiceOut" (winded). Glow stick: lit where it was dropped for shop.glow seconds ("glowOut"); nothing reads
#    its light. Wind-up toy: set at the feet, TOY_WAIT later it rattles for TOY_RATTLE: the host event "noise" {x, z,
#    level, radius, by} once as it starts (nothing listens yet), and on the Playroom a provocation of its owner's
#    (Seek WHY_TOY). Flashbulb: for FLASH_SECONDS the Stillness step counts the player as looking even in a blackout,
#    one watcher. Smelling salts: a downed crewmate faced within HEAL_REACH is up at once ("healed" {salts: true}),
#    refused "nobody". Marker: the Annex only ("annexOnly"): one mark in the player's colour at once (a "markPlaced"
#    {own: true}) that never comes from the crew's pad, and peeled never goes onto it.#  - The night: at lights out + Day.LIGHTS_OUT_SECONDS every bag and pickup is cleared, the cabinets are kept, and the
#    crew wakes on their bunks, lights on ("wokeUp" {bodies, leaveAt}), for Shop.WAKE_SECONDS; then the morning
#    (the car on floor 1, as before) with what each player then carries.
# Live settings (docs/floors/live-settings.md, sim/settings.gd): `tuning` is null unless the host's desk put one
# there (with_tuning). The rules read the host's numbers through Settings.f with today's constant as the
# fallback, so a run without one computes exactly as before. Read so far (LS1): the Stillness residents' hunt
# speeds, lit and in the blackout, by body (_tuned_hunt); the call's fewest and most floors and seconds a floor
# (call_plan, stamped in the plan at the call); the down timer (stamped in Downed.until); the Minder's search
# and run speeds (sim/seek.gd).
#
# The Arboretum (North Star A2 and B1; sim/noise.gd, sim/hearing.gd; AR1). On a floor whose place is the
# Arboretum, with its resident on (seek_off false), the run holds `garden` (a GardenFloor: the Groundskeeper and
# this floor's heal counts), made when the crew reaches the floor and dropped on the next; on any other floor it
# is null and nothing below happens, so every stored result is as recorded (no deck but the game's has the place).
#  - Every tick except while riding, sim/hiding.gd first (the floor's hides, sim/hides.gd), then sim/hearing.gd
#    with every player on the floor: on their feet out of the car (their gait, a sound emote, the hide they got
#    into or out of this tick, sitting in a hide), or down (their crawl). Players in the car, caught or out are
#    not given: they make no noise and are never taken. A tape that hit the floor and a player healed back up on
#    the tick before are heard this tick.
#  - `orderly` carries its pose, mode and speed, so the network and the views are unchanged (as for the Minder).
#  - A snatch is "caught" (the resident's own event) and then the down rule's down ("downed", by "catch", with
#    `more`: the heals this player still has here after this one) while the player has been healed fewer than
#    KEEPER_HEALS times on this floor (the setting groundskeeper.heals); after that it is "out" at once (`by`
#    "keeper"), until the car next moves. Without the down rule a snatch is "caught", as any catch.
#  - The instrument: trait "listening", recording only while it comes or leans (EntityTick.acting), for every
#    holder in range; in the lean each holder's pay is multiplied by their closeness to its reach (EntityTick.pay,
#    Hearing.lean_pay).
#  - Its events are run events at host time: "keeperTilt", "keeperComing", "keeperArrived", "keeperLean",
#    "keeperLeanEnd", "keeperSweep", "keeperSnatch", "twigCrack" (sim/hearing.gd).
#
# Events are Dictionaries with the TypeScript shapes (see RunEvent in run.ts), carrying Move.Body,
# TapeLib.Reading and RunSummary objects where TypeScript carries those objects.
extends RefCounted

const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Orientation = preload("res://sim/orientation.gd")
const Seek = preload("res://sim/seek.gd")
const Hiding = preload("res://sim/hiding.gd")
const Day = preload("res://sim/day.gd")
const Prison = preload("res://sim/prison.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Floor = preload("res://sim/floor.gd")
const Instr = preload("res://sim/instrument.gd")
const Landing = preload("res://sim/landing.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const TapeLib = preload("res://sim/tape.gd")
const M = preload("res://sim/jsmath.gd")
const Marks = preload("res://sim/marks.gd")
const Notes = preload("res://sim/notes.gd")
const Walls = preload("res://sim/walls.gd")
const Relocate = preload("res://sim/relocate.gd")
const Stamina = preload("res://sim/stamina.gd")
const Lonely = preload("res://sim/lonely.gd")
const Settings = preload("res://sim/settings.gd")
const Furniture = preload("res://sim/furniture.gd")
const Noises = preload("res://sim/noise.gd")
const Hearing = preload("res://sim/hearing.gd")
const Findables = preload("res://sim/findables.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Flare = preload("res://sim/flare.gd")
const Lamp = preload("res://sim/lamp.gd")
const GardenCones = preload("res://sim/garden_cones.gd")

# ---------------------------------------------------------------------------------------------
# Tuning.

## Width of the car along the elevator wall, metres (two cells), centred on the landing cell: BANK and
## DOWN are each half of it, 2 m wide.
const CAR_WIDTH := 4.0
## Depth of the car away from the landing, metres (two cells).
const CAR_DEPTH := 4.0
## Width of the door opening, centred on the landing cell's elevator wall, metres (so half of it opens
## onto each half of the car).
const CAR_DOOR_WIDTH := 1.8
## Seconds the car sits with its doors shut on arrival before they open.
const ARRIVE_DOOR_DELAY := 1.0
## On arrival the doors close this long after the last active player stepped out (seconds)...
const UNLOAD_EMPTY_CLOSE := 2.0
## ...or after this long regardless (seconds); then the car leaves. It is not waiting for you.
const UNLOAD_TIME := 12.0
## A player whose feet are within this distance (metres) of the door's centre can call the car.
const CALL_REACH := 2.2
## Seconds between the call and the car starting to move (drawn per call, uniform).
const CALL_START_DELAY_MIN := 1.0
const CALL_START_DELAY_MAX := 3.0
## How many floors away the car starts (drawn per call, never the same as the previous call).
const CALL_FLOORS_MIN := 6
const CALL_FLOORS_MAX := 12
## Seconds per floor on the indicator. Constant, so a player can read the wait: floors x 4 s.
const FLOOR_TIME := 4.0
## Chance per call that the car stops one floor above first.
const FALSE_STOP_CHANCE := 0.25
## Extra seconds a false stop costs (drawn per call, uniform).
const FALSE_STOP_EXTRA_MIN := 3.5
const FALSE_STOP_EXTRA_MAX := 5.0
## During a false stop, doors are heard opening this long after the chime (seconds)...
const FALSE_STOP_DOORS_OPEN_AT := 0.8
## ...and heard closing this long before the car moves on (seconds).
const FALSE_STOP_DOORS_CLOSE_BEFORE := 1.2
## The lights while the car is coming (see dark_schedule): blinks that grow, then the blackout that ends
## as the doors open. Blink lengths in order (seconds); a short wait uses only the first few.
const BLINK_LADDER: Array[float] = [1.0, 1.5, 2.5, 4.0, 6.0]
## The lit gap after each blink, before the next warning (seconds, drawn uniform per gap), nearest the
## blackout first: the gaps shrink as the blackout nears. Spare time in a long wait stretches them
## (each to at most BLINK_GAP_STRETCH_MAX).
const BLINK_GAPS: Array[Array] = [[3.0, 4.0], [3.5, 4.5], [4.0, 5.0], [4.5, 5.5], [5.0, 6.0]]
const BLINK_GAP_STRETCH_MAX := 9.0
## The first warning comes no sooner than this after the call (seconds).
const BLINK_FIRST_AFTER := 2.5
## How far ahead of a blink the game is told, so the screen and sound can telegraph it (seconds).
const BLINK_WARNING := 0.6
## The blackout: the last dark stretch of a wait, ending as the car's doors open (seconds, uniform)...
const BLACKOUT_MIN := 12.0
const BLACKOUT_MAX := 15.0
## ...shorter on the first floor of a run...
const BLACKOUT_FIRST_MIN := 9.0
const BLACKOUT_FIRST_MAX := 10.0
## ...and its warning, long and unmistakable (seconds).
const BLACKOUT_WARNING := 3.0
## The long dark (T20c, a run made with it: see the header): the blackout's length instead, and on the first
## floor. Owner, 17 Nov: "Once the lights dim, we should have them borrow the lights for longer before the
## elevator comes." About two thirds longer than BLACKOUT_MIN..MAX; capped so the first blink still fits.
const LONG_BLACKOUT_MIN := 20.0
const LONG_BLACKOUT_MAX := 24.0
const LONG_BLACKOUT_FIRST_MIN := 14.0
const LONG_BLACKOUT_FIRST_MAX := 16.0
## The Orderly's hunting speed while the blackout is on (m/s; see entity.gd HUNT_SPEED).
const BLACKOUT_HUNT_SPEED := Entity.HUNT_SPEED
## The boarding window: seconds from the doors opening to the bell, not counting holds.
const BOARD_TIME := 20.0
## The same when the car waits (FD4, a run made with it): owner, 17 Nov, "we want to extend to 30 second wait
## before doors close and elevator leaves once it comes".
const BOARD_TIME_WAITS := 30.0
## Paced (T20h, a run made with it: see the header): the Stillness residents' hunting speed, and in the
## blackout (m/s). Measured with the bot runs in godot/tools/pace_check.gd (200 crews x 180 s): the bigger
## tank alone hardly changes how often bots are caught (they sprint only when they see it close behind), and
## each 0.05 m/s more adds about 3 % catches to crews that flee. 3.8 keeps a fleeing player's best run-and-walk
## (Stamina.sustained_flee_speed, 3.93 m/s on the paced tank) a little further ahead of it than today (3.77
## against 3.7), and costs fleeing crews about 8 % more catches; crews recording, about 4 %.
const PACED_HUNT_SPEED := 3.8
const PACED_BLACKOUT_HUNT_SPEED := PACED_HUNT_SPEED
## Total seconds the doors can be held per stop.
const HOLD_LIMIT := 15.0
## Seconds the ride down takes, doors shut.
const RIDE_TIME := 6.0
## Pay multiplier per floor of depth: readings closed at depth d are worth DEPTH_PAY_STEP^(d-1).
const DEPTH_PAY_STEP := 1.35
## The call stops pulling the Orderly once its centre is within this distance (metres) of the landing's centre.
const LURE_DROP_DISTANCE := 3.0
## Longest tick step_run takes in one go (seconds); longer dt is split. Keeps the lure provably uncatchable.
const MAX_TICK := 0.1
## Id the call uses as a target in the Orderly's player list. Never a real player id.
const LURE_ID := "#call"

## The day (only with days on). Seconds the ride up to the prison takes (prison.md section 3: "about
## eight seconds").
const RIDE_UP_TIME := 8.0
const NightReels = preload("res://sim/night_reels.gd")
## Seconds F must be held on a bunk to lie down (prison.md section 6: "Hold F on any bunk").
const BED_HOLD := 1.0
## The floor quota (North Star C9; see the header): what the crew must record on a floor before the call
## button works. floor_quota(depth, crew) = QUOTA_PER_PLAYER x crew x QUOTA_DEPTH_STEP^(depth - 1),
## rounded to the nearest QUOTA_ROUND. Measured with reading bots (tests/prop_quota_net.gd): on floor 1
## a crew that reads well meets it in about 2 minutes (1:45 alone, 2:40 for four, slow floors nearer 4).
## Each floor deeper pays DEPTH_PAY_STEP (1.35) more and asks QUOTA_DEPTH_STEP more: about 7% longer.
const QUOTA_PER_PLAYER := 400
const QUOTA_DEPTH_STEP := 1.45
const QUOTA_ROUND := 5
## Each player's floor quota, the unit of the day quota (Day.quota_for): floor 1's quota per player, so
## Day.first_floor_quota(DAY_FLOOR_QUOTA, crew) is floor_quota(1, crew) exactly. The day quota is 1.5 of
## floor 1's quota on day 1 (docs/floors/prison.md section 2).
const DAY_FLOOR_QUOTA := QUOTA_PER_PLAYER
## The Annex (see the header): how near a mark a player must stand to peel it (metres, feet to the
## arrow); the Temp's "hunt" note every this many seconds of hunting; no crewmate within ALONE_DISTANCE
## is "alone"; two crew within CLOSE_DISTANCE stand "very close".
const MARK_PEEL_REACH := 1.5
const NOTE_HUNT_EVERY := 25.0
const ALONE_DISTANCE := 10.0
const CLOSE_DISTANCE := 1.0
## Down first, then out (see the header). Seconds a downed player has before they are out (B6: "about ten
## seconds"); seconds F must be held beside them (B6: three); how near the healer's feet must be to the
## downed body (metres, same level: "beside"); how fast a downed player crawls (m/s); how long a resident
## that loses its downed player to a heal stays quiet (seconds); the health a heal gives back on the
## Playroom; the body radius a crawl moves with (net/session.gd PLAYER_RADIUS).
const DOWN_TIME := 10.0
const HEAL_TIME := 3.0
const HEAL_REACH := 1.5
const CRAWL_SPEED := 0.6
const HEAL_QUIET := 5.0
const HEAL_HEALTH := 50.0
const CRAWL_RADIUS := 0.3
## The Arboretum (see the header): how many times a player can be healed back up on one Arboretum floor.
const KEEPER_HEALS := 2

const EPS := 1e-9
## How far onto the landing side of the wall line the doorway channel reaches, beyond a body's radius.
const DOOR_ZONE_SLACK := 0.01

# ---------------------------------------------------------------------------------------------
# The car.

class Rect:
	var x0: float
	var z0: float
	var x1: float
	var z1: float

## Where the car is, in world metres. Local coordinates: u is the distance past the wall line into the
## car (0 at the doors, CAR_DEPTH at the back), v is sideways, positive to the right as you walk in.
class CarGeometry:
	## Which side of the landing cell the doors are on.
	var wall: StringName
	var level: int
	## Height of the car floor. (TypeScript: floorY)
	var floor_y: float
	## Centre of the door opening on the wall line. (TypeScript: doorX, doorZ)
	var door_x: float
	var door_z: float
	## Unit vector from the landing into the car, and the unit vector to the right walking in.
	var in_x: float
	var in_z: float
	var right_x: float
	var right_z: float
	var width: float
	var depth: float
	var door_width: float  # TypeScript: doorWidth
	## The car's floor as an axis-aligned rectangle.
	var rect: Rect
	## The BANK half (left walking in) and the DOWN half (right walking in).
	var bank: Rect
	var down: Rect

static func _rect_of(points: Array[PackedFloat64Array]) -> Rect:
	var r := Rect.new()
	r.x0 = INF
	r.z0 = INF
	r.x1 = -INF
	r.z1 = -INF
	for p in points:
		r.x0 = minf(r.x0, p[0])
		r.z0 = minf(r.z0, p[1])
		r.x1 = maxf(r.x1, p[0])
		r.z1 = maxf(r.z1, p[1])
	return r

static func _car_at(c: CarGeometry, u: float, w: float) -> PackedFloat64Array:
	return PackedFloat64Array([c.door_x + c.in_x * u + c.right_x * w, c.door_z + c.in_z * u + c.right_z * w])

## The car for a floor plan.
static func car_geometry(plan: Floor.FloorPlan) -> CarGeometry:
	var wall := Landing.elevator_wall(plan)
	if wall == &"":
		wall = &"n"
	var vx := float(Floor.dir_dx(wall))
	var vy := float(Floor.dir_dy(wall))
	var s := float(plan.cell_size)
	var c := CarGeometry.new()
	c.wall = wall
	c.level = plan.landing.level
	c.floor_y = Move.LEVEL_HEIGHT if c.level == 1 else 0.0
	c.door_x = (plan.landing.x + 0.5) * s + vx * (s / 2.0)
	c.door_z = (plan.landing.y + 0.5) * s + vy * (s / 2.0)
	c.in_x = vx
	c.in_z = vy
	# Right as you face (in_x, in_z), three.js style top-down: facing -z, right is +x.
	c.right_x = -c.in_z
	c.right_z = c.in_x
	var hw := CAR_WIDTH / 2.0
	c.width = CAR_WIDTH
	c.depth = CAR_DEPTH
	c.door_width = CAR_DOOR_WIDTH
	c.rect = _rect_of([_car_at(c, 0.0, -hw), _car_at(c, CAR_DEPTH, hw)])
	c.bank = _rect_of([_car_at(c, 0.0, -hw), _car_at(c, CAR_DEPTH, 0.0)])
	c.down = _rect_of([_car_at(c, 0.0, 0.0), _car_at(c, CAR_DEPTH, hw)])
	return c

## World position to car-local: Vector of (u into the car, v to the right), as [u, v].
static func car_local(car: CarGeometry, x: float, z: float) -> PackedFloat64Array:
	var dx := x - car.door_x
	var dz := z - car.door_z
	return PackedFloat64Array([dx * car.in_x + dz * car.in_z, dx * car.right_x + dz * car.right_z])

## A body standing at car-local (u, v).
static func car_body(car: CarGeometry, u: float, v: float) -> Move.Body:
	return Move.Body.make(car.door_x + car.in_x * u + car.right_x * v, car.door_z + car.in_z * u + car.right_z * v, car.level, car.floor_y)

## Whether a body's centre is inside the car.
static func in_car(car: CarGeometry, b: Move.Body) -> bool:
	if b.level != car.level:
		return false
	var l := car_local(car, b.x, b.z)
	return l[0] > 0.0 and l[0] <= car.depth + EPS and absf(l[1]) <= car.width / 2.0 + EPS

## Which half of the car a body stands on (&"bank" or &"down"), or null if it is not inside.
static func car_side(car: CarGeometry, b: Move.Body) -> Variant:
	if not in_car(car, b):
		return null
	return &"bank" if car_local(car, b.x, b.z)[1] < 0.0 else &"down"

## Spawn spots inside the car, by player index: two rows, a metre either side of the middle line.
static func _car_slot(car: CarGeometry, i: int) -> Move.Body:
	var us: Array[float] = [1.3, 1.3, 2.7, 2.7]
	var vs: Array[float] = [-1.0, 1.0, -1.0, 1.0]
	return car_body(car, us[i % 4], vs[i % 4])

## Spots on the landing just outside the doors, by index.
static func _landing_slot(car: CarGeometry, i: int) -> Move.Body:
	var vs: Array[float] = [-0.5, 0.5, -0.1, 0.3]
	return car_body(car, -0.8 - 0.3 * floorf(i / 4.0), vs[i % vs.size()])

# ---------------------------------------------------------------------------------------------
# The call schedule.

## One dark stretch of a wait. Times in seconds after the call.
class DarkStretch:
	## When the lights go out.
	var at: float
	## How long they stay out (the blackout's ends as the car arrives: at + len == wait).
	var len: float
	## How long before `at` the warning starts.
	var warn: float
	## The last and longest: the blackout.
	var blackout: bool

	static func make(at_: float, len_: float, warn_: float, blackout_: bool) -> DarkStretch:
		var d := DarkStretch.new()
		d.at = at_
		d.len = len_
		d.warn = warn_
		d.blackout = blackout_
		return d

class CallPlan:
	## Seconds before the car starts moving.
	var delay: float
	## Floors away it starts.
	var floors: int
	var false_stop: bool  # TypeScript: falseStop
	## Extra seconds the false stop costs (0 without one).
	var extra: float
	## Total seconds from the call to the car arriving.
	var wait: float
	## Seconds each floor on the indicator takes, stamped at the call (FLOOR_TIME, or the host's
	## lift.floor_time then: live settings, sim/settings.gd). The indicator steps by it till the car is here.
	var floor_time: float = FLOOR_TIME
	## The dark stretches of this wait, in order; the last is the blackout.
	var darks: Array[DarkStretch] = []

## The schedule of the `index`-th call of a run (0-based) at `depth`. Never starts from `prev_floors`
## floors away (pass -1 for none: TypeScript null). `tuning` (live settings, sim/settings.gd; null: none):
## the host's fewest and most floors and seconds a floor, stamped into the plan; the same draws either way.
static func call_plan(seed: String, index: int, prev_floors: int, depth: int = 1, long_dark: bool = false, tuning: Settings.Values = null) -> CallPlan:
	var rng := Rng.make_rng(seed).fork("call:%d" % index)
	var p := CallPlan.new()
	p.delay = CALL_START_DELAY_MIN + rng.next() * (CALL_START_DELAY_MAX - CALL_START_DELAY_MIN)
	var fewest := Settings.i(tuning, &"lift.floors_min", CALL_FLOORS_MIN)
	var most := Settings.i(tuning, &"lift.floors_max", CALL_FLOORS_MAX)
	var floors := rng.int_in(fewest, most)
	if floors == prev_floors:
		floors = fewest if floors == most else floors + 1
	p.floors = floors
	# Live settings: the host's chance (lift.false_stop, in 100); the same one draw either way.
	p.false_stop = rng.chance(FALSE_STOP_CHANCE if tuning == null or not tuning.has(&"lift.false_stop") else Settings.f(tuning, &"lift.false_stop", 25.0) / 100.0)
	p.extra = FALSE_STOP_EXTRA_MIN + rng.next() * (FALSE_STOP_EXTRA_MAX - FALSE_STOP_EXTRA_MIN) if p.false_stop else 0.0
	p.floor_time = Settings.f(tuning, &"lift.floor_time", FLOOR_TIME)
	p.wait = p.delay + floors * p.floor_time + p.extra
	p.darks = dark_schedule(seed, index, p.wait, depth, long_dark, tuning)
	return p

static func _need(gaps: Array[float], n: int) -> float:
	var s := 0.0
	for k in n:
		s += (BLINK_LADDER[k] + BLINK_WARNING) + gaps[k]
	return s

## The lights of one wait, laid out when the car is called, from the run's seed alone. The last dark
## stretch is the blackout: BLACKOUT_MIN..MAX seconds (less on the first floor), ending exactly when the
## car arrives, after a BLACKOUT_WARNING warning. Before it, blinks of BLINK_LADDER lengths, each longer
## than the last, with lit gaps that shrink toward the blackout. As many blinks as fit after
## BLINK_FIRST_AFTER (a short wait gets fewer, never no blackout); spare time stretches the gaps
## and delays the first blink.
## Every wait draws the same seven numbers, whatever fits. `long_dark` (see the header): the blackout is
## LONG_BLACKOUT_* seconds instead, but never longer than leaves room for the ladder's first blink. `tuning` (live
## settings): the host's blackout bounds (dark.min, dark.max; dark.first_min, dark.first_max on the first floor) and its
## warning (dark.warning), stamped into the plan at the call; the same draws either way.
static func dark_schedule(seed: String, index: int, wait: float, depth: int, long_dark: bool = false, tuning: Settings.Values = null) -> Array[DarkStretch]:
	var rng := Rng.make_rng(seed).fork("call:%d:dark" % index)
	var lo := BLACKOUT_FIRST_MIN if depth <= 1 else BLACKOUT_MIN
	var hi := BLACKOUT_FIRST_MAX if depth <= 1 else BLACKOUT_MAX
	if long_dark:
		lo = LONG_BLACKOUT_FIRST_MIN if depth <= 1 else LONG_BLACKOUT_MIN
		hi = LONG_BLACKOUT_FIRST_MAX if depth <= 1 else LONG_BLACKOUT_MAX
	var warn := BLACKOUT_WARNING
	if tuning != null:
		lo = Settings.f(tuning, &"dark.first_min" if depth <= 1 else &"dark.min", lo)
		hi = Settings.f(tuning, &"dark.first_max" if depth <= 1 else &"dark.max", hi)
		warn = Settings.f(tuning, &"dark.warning", BLACKOUT_WARNING)
	var black := minf(lo + rng.next() * (hi - lo), maxf(1.0, wait - warn))
	var gaps: Array[float] = []
	for g: Array in BLINK_GAPS:
		var a: float = g[0]
		var b: float = g[1]
		gaps.append(a + rng.next() * (b - a))
	# Of any spare time, this share (up to half) goes before the first blink, the rest into the gaps.
	var lead := rng.next() * 0.5
	if long_dark:
		# The long dark never eats the whole wait: the first blink, its warning and its gap still fit after
		# BLINK_FIRST_AFTER (the shortest wait, 25 s, keeps a blackout of about 14 s and one blink).
		black = minf(black, maxf(1.0, wait - warn - BLINK_FIRST_AFTER - _need(gaps, 1)))
	var black_at := wait - black
	var room := black_at - warn - BLINK_FIRST_AFTER
	var n := BLINK_LADDER.size()
	while n > 0 and _need(gaps, n) > room + 1e-9:
		n -= 1
	# Spare time stretches the gaps evenly (each capped), so a long wait keeps its blinks spread out.
	var spare := room - _need(gaps, n)
	var stretch := (spare * (1.0 - lead)) / n if n > 0 else 0.0
	var gap: Array[float] = []
	for k in n:
		gap.append(minf(BLINK_GAP_STRETCH_MAX, gaps[k] + stretch))
	var out: Array[DarkStretch] = [DarkStretch.make(black_at, black, warn, true)]
	var cursor := black_at - warn
	# Backwards from the blackout: the longest blink nearest it.
	for k in range(n - 1, -1, -1):
		var length := BLINK_LADDER[k]
		var end := cursor - gap[n - 1 - k]
		var at := end - length
		out.push_front(DarkStretch.make(at, length, BLINK_WARNING, false))
		cursor = at - BLINK_WARNING
	return out

## Readings closed at this depth are worth this many times their recorded value.
## (TypeScript writes DEPTH_PAY_STEP ** n; see rate_at in instrument.gd about pow.)
static func depth_multiplier(depth: int) -> float:
	return M.pow_js(DEPTH_PAY_STEP, float(maxi(0, depth - 1)))

# ---------------------------------------------------------------------------------------------
# Types.

# RunPhase: 'arriving' (car here, doors shut, about to open onto the floor) | 'unloading' (doors
# open on arrival; they close once everyone is out or after UNLOAD_TIME) | 'away' (car gone; it
# must be called) | 'coming' (called and on its way) | 'boarding' (doors open, the bell is
# counting) | 'riding' (doors shut, going down) | 'ended'
# PlayerStatus: 'ok' | 'caught' | 'leftBehind'

class RunPlayer:
	var id: String
	## Where the run last knew them (from the inputs, or where it placed them).
	var body: Move.Body
	var status: StringName = &"ok"
	## Inside the car this tick.
	var aboard: bool = false
	## Their vote: the half of the car they stand on (null when not aboard or not active).
	var side: Variant = null

	func copy() -> RunPlayer:
		var p := RunPlayer.new()
		p.id = id
		p.body = body
		p.status = status
		p.aboard = aboard
		p.side = side
		return p

class CallState:
	var index: int
	## Run time of the call.
	var at: float
	var plan: CallPlan
	## What the indicator shows: floors away. (TypeScript: floorsAway)
	var floors_away: int
	## Run time the indicator next changes (or the car arrives). (TypeScript: nextAt)
	var next_at: float
	## False stop in progress: run time it ends (or null), and which of its sounds have played.
	var stop_until: Variant = null  # TypeScript: stopUntil
	var stop_doors_opened: bool = false  # TypeScript: stopDoorsOpened
	var stop_doors_closed: bool = false  # TypeScript: stopDoorsClosed

	func copy() -> CallState:
		var c := CallState.new()
		c.index = index
		c.at = at
		c.plan = plan
		c.floors_away = floors_away
		c.next_at = next_at
		c.stop_until = stop_until
		c.stop_doors_opened = stop_doors_opened
		c.stop_doors_closed = stop_doors_closed
		return c

class BlinkState:
	var call_index: int  # TypeScript: callIndex
	## Blink number within the call.
	var n: int
	## Run time this blink starts.
	var at: float
	## Seconds it lasts (the blackout's is nominal: it ends when the car arrives).
	var len: float
	## Seconds of warning before `at`.
	var warn: float
	## The wait's last dark stretch: the blackout.
	var blackout: bool
	var announced: bool = false
	## Run time it ends once started, else null. (TypeScript: endsAt)
	var ends_at: Variant = null

	func copy() -> BlinkState:
		var b := BlinkState.new()
		b.call_index = call_index
		b.n = n
		b.at = at
		b.len = len
		b.warn = warn
		b.blackout = blackout
		b.announced = announced
		b.ends_at = ends_at
		return b

class RunSummary:
	## Deepest floor reached.
	var depth: int
	## Readings on the banked tapes.
	var readings: int
	var total: float
	## Each player's share: the total split evenly between everyone in the run (insertion-ordered).
	var shares: Dictionary = {}
	## Tapes banked.
	var tapes: Array[String] = []
	var wiped: bool

## The Annex floor the crew is on (see the header): its marks and notes. Replaced, never edited, once in
## a RunState (copy() first).
class AnnexFloor:
	## The plan it belongs to (a new plan is a new floor).
	var plan: Floor.FloorPlan
	## The crew's one pad and the marks down (sim/marks.gd).
	var marks: Marks.MarksState
	## Notes.post's state (count and templates used), and the notes posted, in order: {id, n, trigger,
	## template, text, x, z, level, yaw, t}. Each Dictionary is never edited once posted.
	var notes_state: Dictionary = {}
	var notes: Array[Dictionary] = []
	## RunState.note_seq when the crew reached the floor: this floor's note ids are notes_from + 1 on.
	var notes_from: int = 0
	## Triggers waiting for the Temp to be free to post: {trigger, facts}.
	var queue: Array[Dictionary] = []
	## The lobby note has been posted.
	var lobby_done: bool = false
	## Seconds the Temp has hunted since the last "hunt" note.
	var hunt_clock: float = 0.0
	## Sprints started this floor, {id: int}, whether each player sprinted last tick, {id: bool}, and notes
	## naming each name so far, {name: int}.
	var sprints: Dictionary = {}
	var sprinting: Dictionary = {}
	var named: Dictionary = {}
	## Lonely (see the header): the run time of the last chase note queued for each player, {id: t}.
	var chase_noted: Dictionary = {}

	static func start(plan_: Floor.FloorPlan, note_seq: int) -> AnnexFloor:
		var a := AnnexFloor.new()
		a.plan = plan_
		a.marks = Marks.MarksState.start_floor(Marks.DEFAULT_PAD)
		a.notes_state = Notes.new_state()
		a.notes_from = note_seq
		return a

	func copy() -> AnnexFloor:
		var a := AnnexFloor.new()
		a.plan = plan
		a.marks = marks
		a.notes_state = notes_state
		a.notes = notes.duplicate()
		a.notes_from = notes_from
		a.queue = queue.duplicate()
		a.lobby_done = lobby_done
		a.hunt_clock = hunt_clock
		a.sprints = sprints.duplicate()
		a.sprinting = sprinting.duplicate()
		a.named = named.duplicate()
		a.chase_noted = chase_noted.duplicate()
		return a

## The Arboretum floor the crew is on (see the header). Replaced, never edited, once in a RunState (copy() first).
class GardenFloor:
	## The plan it belongs to (a new plan is a new floor).
	var plan: Floor.FloorPlan
	## The Groundskeeper (sim/hearing.gd).
	var keeper: Hearing.Keeper
	## Times each player has been healed back up on this floor, {id: int}.
	var heals: Dictionary = {}
	## Who was healed back up on the tick before (their getting up is heard this tick), and the tapes that hit
	## the floor then.
	var healed: Array[String] = []
	var drops: Array[Noises.Sound] = []
	## Accepted throws waiting to land, [{at: Move.Body, lands: float}].
	var cones_in_flight: Array[Dictionary] = []

	func copy() -> GardenFloor:
		var g := GardenFloor.new()
		g.plan = plan
		g.keeper = keeper
		g.heals = heals.duplicate()
		g.healed = healed.duplicate()
		g.drops = drops.duplicate()
		g.cones_in_flight = cones_in_flight.duplicate()
		return g

## A downed player (see the header). Replaced, never edited, once in a RunState.
class Downed:
	var id: String
	## Host time they went down, and when they are out unless healed first.
	var at: float
	var until: float
	## &"catch" (the resident) or &"health" (the Playroom).
	var by: StringName
	## Who is holding F beside them ("" for nobody), and the host time that hold began (-1 for none).
	var healer: String = ""
	var heal_from: float = -1.0
	## Seconds that hold takes, stamped as it begins (HEAL_TIME, or the host's heal.time then: live settings).
	var heal_len: float = HEAL_TIME

	func copy() -> Downed:
		var d := Downed.new()
		d.id = id
		d.at = at
		d.until = until
		d.by = by
		d.healer = healer
		d.heal_from = heal_from
		d.heal_len = heal_len
		return d

class RunState:
	var seed: String
	## Run time, seconds.
	var t: float = 0.0
	var depth: int = 1
	var plan: Floor.FloorPlan
	var car: CarGeometry
	var orderly: Entity.OrderlyState
	## Entity id of this floor's Orderly. (TypeScript: entityId)
	var entity_id: String
	## The places this run's floors are drawn from (places.gd); Clinic only by default.
	var deck: Array[StringName] = Places.CLINIC_ONLY
	var crew: Instr.CrewState
	var players: Array[RunPlayer] = []
	var phase: StringName = &"arriving"
	## Seconds left in a timed phase (arriving, unloading, riding).
	var timer: float = 0.0
	## Unloading: seconds the car has been empty of active players. (TypeScript: emptyFor)
	var empty_for: float = 0.0
	var calls: int = 0
	## TypeScript: lastFloors (null before the first call: -1 here).
	var last_floors: int = -1
	var call: CallState = null
	var blink: BlinkState = null
	## The Orderly is being pulled toward the landing by the call.
	var lure: bool = false
	## Boarding: seconds of boarding window left, hold seconds left, whether the doors are held.
	var bell_left: float = 0.0  # TypeScript: bellLeft
	var hold_left: float = 0.0  # TypeScript: holdLeft
	var held: bool = false
	## Set when the run ends (banked or wiped). With days on: the last bank or wipe, until the next morning.
	var summary: RunSummary = null
	## The day loop (see the header). Off: everything below stays as it is made and is never read.
	var days: bool = false
	## The run's own seed (day 1's); `seed` is the day's (day_seed(base_seed, day_index)).
	var base_seed: String = ""
	## Every day of this run counted from 1 (never reset): the day's seed comes from it.
	var day_index: int = 1
	## Today's day rules (sim/day.gd): day number, streak, misses, quota level, crew size.
	var day_state: Day.DayState = null
	## Once today is settled (BANK or a wipe): the next day's state, until the morning. Else null.
	var day_next: Day.DayState = null
	## The facts of the day just settled (Day.DayResult.facts plus "shares" and "credits"), until the
	## next morning; else null.
	var day_result: Variant = null
	## Every player's wallet, {id: Upgrades.UpgradeState}.
	var wallets: Dictionary = {}
	## The car is riding up to the prison (phase riding).
	var going_up: bool = false
	var nightly_reels := false
	var reel_day := 0
	var reel_started := 0.0
	var reel_crew := 0
	var reel_votes: Array[String] = []
	var reel_skipped := false
	## The bedtime count in the prison (null on the floors).
	var bed: Day.BedState = null
	## Seconds each player has held F on a bunk (-1: waiting for them to let go first), and whether F
	## was held on their previous input.
	var bed_hold: Dictionary = {}
	var use_prev: Dictionary = {}
	## Run time the lights went out in the prison, or -1.
	var lights_out_t: float = -1.0
	## The Playroom (see the header): sim/seek.gd's state on this floor (a Seek.SeekState), else null.
	var seek: Variant = null
	## The resident is off (net/host_rules.gd, entity off): no seek, the Minder stays parked.
	var seek_off: bool = false
	## Players whose tape hit the floor as they went down last tick: heard this tick.
	var seek_drops: Array[String] = []
	## Run time of the call that started the last count (-1 before).
	var seek_call_at: float = -1.0
	## Hiding off the Playroom (see the header): sim/hiding.gd's state on this floor (a Hiding.HidingState),
	## made at the first hide press on a Clinic or an Annex, else null.
	var hiding: Variant = null
	## The two practice prop trigger times, negative while still hidden.
	var orientation_standees := Orientation.STANDEES_UNTRIGGERED
	## The floor quota (see the header). Off: everything below stays as it is made and is never read.
	var quota: bool = false
	## A standalone safe practice stop, with no day, wallet or campaign advancement.
	var orientation: bool = false
	## The paid campaign prepared for its first stop. Present only in the optional Day 1 prelude.
	var orientation_resume: RunState = null
	## The separate spendable practice wage, shown on the first real report.
	var orientation_paid := 0
	## Recorded on this floor: every reading closed here (depth pay included), wherever its tape went since.
	var floor_earned: float = 0.0
	## The same per player, {id: value} (who did most of it: the Annex's note). Replaced, never edited.
	var floor_by: Dictionary = {}
	## What this floor asks for (floor_quota), 0 at home.
	var floor_needed: int = 0
	## "quotaMet" has been said on this floor.
	var quota_met: bool = false
	## The Annex (see the header): this floor's marks and notes (an AnnexFloor), else null.
	var annex: AnnexFloor = null
	## Notes posted over the whole run (a note's id is the count when it was posted).
	var note_seq: int = 0
	## The players' names as the notes write them, {id: name} (the host's; an id is its own name otherwise).
	var names: Dictionary = {}
	## Down first, then out (see the header). Off: everything below stays empty and is never read.
	var downs: bool = false
	## Who is down, {id: Downed}. Replaced, never edited.
	var down: Dictionary = {}
	## This floor's red spots, {playerId, x, z, level, y, t}, in the order left. Replaced, never edited.
	var spots: Array[Dictionary] = []
	## Two-watcher Stillness (T19a, with_two_watchers): with three or more up players it takes two watchers
	## to hold a Stillness resident. Off: one always does, as every stored result has it.
	var two_watchers: bool = false
	## Relocation (T19e, with_relocation; sim/relocate.gd): the resident may leave where nobody can see it and
	## arrive where nobody can. Off: it never does, as every stored result has it.
	var relocation: bool = false
	## The owner's 17 Nov changes (see the header). Off: nothing below is ever read.
	var long_dark: bool = false
	var paced: bool = false
	var car_waits: bool = false
	## The car waits: who the car left on a floor today, {id: true}, until the crew gets home. Replaced, never edited.
	var left_out: Dictionary = {}
	## Lonely (T19c, with_lonely; sim/lonely.gd): the Temp carries its own mechanic. Off: Stillness, as every
	## stored result has it.
	var lonely: bool = false
	## The day quota's lock (FD2, with_day_lock; see the header). Off: nothing below is ever read, and a short
	## BANK is a missed day as before.
	var day_lock: bool = false
	## Everything the crew has recorded today (every reading closed, depth pay included), whatever became of
	## its tape. Only rises within a day; 0 every morning.
	var day_earned: float = 0.0
	## "dayMet" has been said today.
	var day_met: bool = false
	## The Playroom tuned from the owner's first play (T15m, with_playroom_tuned; sim/seek.gd "T15m"). Off: the
	## Playroom's rules are exactly as every stored result has them.
	var playroom_tuned: bool = false
	## Solid furniture (FD7, with_furniture; sim/furniture.gd): players slide along the floor's pieces. Off:
	## nothing blocks but walls, as every stored result has it.
	var furniture: bool = false
	## Restored waiting chairs, atrium seating and break-room tables (T20j).
	var furniture_layout: bool = false
	var resident_navigation: bool = false
	## Findables (FD9, with_findables; sim/findables.gd). Off: nothing below is ever made or read.
	var findables: bool = false
	var badge_search := false
	var quick_fingers := false
	## This floor's findables (a Findables.FindFloor), or null; the lore pages dealt tonight; each player's
	## found items {id: {item: count}}. Replaced, never edited.
	var find: Variant = null
	var lore_used: Array = []
	var items: Dictionary = {}
	## The four-slot inventory (S1, with_inventory; sim/inventory.gd). Off: nothing below is ever made or read.
	var inventory: bool = false
	var garden_cones: bool = false
	var garden_search: bool = false
	## Each player's slots {id: Inventory.Bag}; the floor's pickups (Inventory.Pickup) and the plan they lie on;
	## the next pickup's id. Replaced, never edited.
	var bags: Dictionary = {}
	var pickups: Array = []
	var pickups_plan: Variant = null
	var pickup_seq: int = 0
	## The shop and the cabinet (S2, with_shop; sim/shop.gd). Off: nothing below is ever made or read.
	var shop: bool = false
	var deep_pockets: bool = false
	var second_wind: bool = false
	var soft_shoes: bool = false
	var long_burn: bool = false
	var flare := false
	var flare_plan: Floor.FloorPlan = null
	var flare_issued := {}
	var flare_profiles := {}
	var flare_bursts: Array[Dictionary] = []
	var flare_seq := 0
	var flare_stun_until := -1.0
	var lamp := false
	var lamps := {}
	var wind_spent := {}
	var wind_profiles := {}
	## Every cabinet and what the items left lit (Shop.ShopState). Replaced, never edited.
	var shop_state: Variant = null

	## Live settings (sim/settings.gd): the host's numbers in force in this run, or null for none (every test
	## and stored result). The rules read it with Settings.f, falling back to today's constant. Replaced,
	## never edited (with_tuning).
	var tuning: Settings.Values = null
	## The Arboretum (see the header): this floor's Groundskeeper and heal counts (a GardenFloor), else null.
	var garden: GardenFloor = null

	func copy() -> RunState:
		var s := RunState.new()
		s.tuning = tuning
		s.garden = garden
		s.lonely = lonely
		s.day_lock = day_lock
		s.day_earned = day_earned
		s.day_met = day_met
		s.playroom_tuned = playroom_tuned
		s.furniture = furniture
		s.furniture_layout = furniture_layout
		s.resident_navigation = resident_navigation
		s.findables = findables
		s.badge_search = badge_search
		s.quick_fingers = quick_fingers
		s.find = find
		s.lore_used = lore_used
		s.items = items
		s.inventory = inventory
		s.garden_cones = garden_cones
		s.garden_search = garden_search
		s.bags = bags
		s.pickups = pickups
		s.pickups_plan = pickups_plan
		s.pickup_seq = pickup_seq
		s.shop = shop
		s.shop_state = shop_state
		s.deep_pockets = deep_pockets
		s.second_wind = second_wind
		s.soft_shoes = soft_shoes
		s.long_burn = long_burn
		s.flare = flare
		s.flare_plan = flare_plan
		s.flare_issued = flare_issued
		s.flare_profiles = flare_profiles
		s.flare_bursts = flare_bursts
		s.flare_seq = flare_seq
		s.flare_stun_until = flare_stun_until
		s.lamp = lamp
		s.lamps = lamps
		s.wind_spent = wind_spent
		s.wind_profiles = wind_profiles
		s.two_watchers = two_watchers
		s.relocation = relocation
		s.seed = seed
		s.t = t
		s.depth = depth
		s.plan = plan
		s.car = car
		s.orderly = orderly
		s.entity_id = entity_id
		s.deck = deck
		s.crew = crew
		s.players = players
		s.phase = phase
		s.timer = timer
		s.empty_for = empty_for
		s.calls = calls
		s.last_floors = last_floors
		s.call = call
		s.blink = blink
		s.lure = lure
		s.bell_left = bell_left
		s.hold_left = hold_left
		s.held = held
		s.summary = summary
		s.days = days
		s.base_seed = base_seed
		s.day_index = day_index
		s.day_state = day_state
		s.day_next = day_next
		s.day_result = day_result
		s.wallets = wallets
		s.going_up = going_up
		s.nightly_reels = nightly_reels
		s.reel_day = reel_day
		s.reel_started = reel_started
		s.reel_crew = reel_crew
		s.reel_votes = reel_votes
		s.reel_skipped = reel_skipped
		s.bed = bed
		s.bed_hold = bed_hold
		s.use_prev = use_prev
		s.lights_out_t = lights_out_t
		s.seek = seek
		s.seek_off = seek_off
		s.seek_drops = seek_drops
		s.seek_call_at = seek_call_at
		s.orientation_standees = orientation_standees
		s.hiding = hiding
		s.quota = quota
		s.orientation = orientation
		s.orientation_resume = orientation_resume
		s.orientation_paid = orientation_paid
		s.floor_earned = floor_earned
		s.floor_by = floor_by
		s.floor_needed = floor_needed
		s.quota_met = quota_met
		s.annex = annex
		s.note_seq = note_seq
		s.names = names
		s.downs = downs
		s.down = down
		s.spots = spots
		s.long_dark = long_dark
		s.paced = paced
		s.car_waits = car_waits
		s.left_out = left_out
		return s

class PlayerInput:
	var id: String
	var body: Move.Body
	## Eye height above the feet, yaw/pitch three.js style, full fields of view in degrees.
	var eye: float
	var yaw: float
	var pitch: float
	var h_fov_deg: float
	var v_fov_deg: float
	## Pressing the call button.
	var call: bool = false
	## Holding the doors (only counts from inside the car while boarding). (TypeScript: holdDoors)
	var hold_doors: bool = false
	## Instrument raised: true, false, or null for "not said" (TypeScript: undefined).
	var raised: Variant = null
	## Pick up a tape: its id (String), true for the nearest one within reach, or null.
	var pick_up: Variant = null  # TypeScript: pickUp
	## Sees nothing this tick, though present and huntable (the host's call).
	var blind: bool = false
	## F is held (the use key): in the prison, held on a bunk it lies you down (days on only).
	var use: bool = false
	## The Playroom only (see the header). The gait the player has this tick (Stamina.gait_for): "walk",
	## "creep" or "sprint".
	var gait: StringName = &"walk"
	## F pressed for a hide this tick (a press, not held): into the hide in reach, or out of the one
	## you are in; `hide_fast`: sprint was held as it was pressed (quick, and the flap is let go).
	var hide_use: bool = false
	var hide_fast: bool = false
	## W held inside a hide: leaning to the gap.
	var peek: bool = false
	## An emote that plays a sound, the voice (when the microphone exists), the party horn (harmless).
	var emote_sound: bool = false
	var wind_gasp: bool = false
	var voice: bool = false
	var horn: bool = false
	## A lamp or flash (a Seek.Light), or null. A hook: lamps do not exist yet.
	var light: Variant = null
	## The Annex only (see the header). Q pressed this tick: start placing a mark from the shared pad.
	var mark: bool = false
	## The id of a mark to peel back onto the pad (F held on it for Marks.PEEL_SECONDS), or -1.
	var peel: int = -1
	## Findables (see the header): F held to search the piece in reach, and sprint held with it (rushed).
	var search: bool = false
	var search_fast: bool = false
	## The inventory (S1, see the header): the slot asked for (0 to 3, -1 for none); one request this tick,
	## &"drop", &"take" (inv_arg: the pickup's id) or &"give" (inv_arg: the crewmate's id), or &"" for none.
	var inv_select: int = -1
	var inv_op: StringName = &""
	var inv_arg: Variant = null

	static func make(id_: String, body_: Move.Body, eye_: float, yaw_: float, pitch_: float, h_fov: float, v_fov: float) -> PlayerInput:
		var p := PlayerInput.new()
		p.id = id_
		p.body = body_
		p.eye = eye_
		p.yaw = yaw_
		p.pitch = pitch_
		p.h_fov_deg = h_fov
		p.v_fov_deg = v_fov
		return p

class RunStep:
	var state: RunState
	var events: Array[Dictionary] = []

# ---------------------------------------------------------------------------------------------
# Creating a run.

class _FloorFor:
	var plan: Floor.FloorPlan
	var car: CarGeometry
	var orderly: Entity.OrderlyState
	var entity_id: String

static func _floor_for(seed: String, depth: int, deck: Array[StringName], garden_dense: bool = false) -> _FloorFor:
	var f := _FloorFor.new()
	f.plan = Places.generate(seed, depth, deck, garden_dense)
	f.car = car_geometry(f.plan)
	f.orderly = Places.create_resident(f.plan)
	f.entity_id = Places.entity_id(f.plan.place, depth)
	return f

## The deck a caller gave, or Clinic only.
static func deck_of(deck: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for p: Variant in deck:
		out.append(StringName(p))
	return out if not out.is_empty() else Places.CLINIC_ONLY

## The seed of the run's `index`-th day (1-based): day 1 is the run's own seed, then "<seed>:day<n>".
static func day_seed(base: String, index: int) -> String:
	return base if index <= 1 else "%s:day%d" % [base, index]

## Turns the day loop on for a run that has not ticked yet (create_run's state): day 1 with the crew
## that rides down now.
static func with_days(s0: RunState) -> RunState:
	var s := s0.copy()
	s.days = true
	s.base_seed = s0.seed
	s.day_index = 1
	s.day_state = Day.morning(Day.start_night(), s0.players.size())
	s.day_next = null
	s.day_result = null
	s.wallets = {}
	return s

## Whether the crew is at home: the day loop is on and the run is in the prison.
static func at_home(s: RunState) -> bool:
	return s.days and s.depth == 0

## What floor `depth` asks a crew of `crew` to record before the call button works (see QUOTA_PER_PLAYER).
## 0 at home (depth 0 or less).
static func floor_quota(depth: int, crew: int) -> int:
	if depth <= 0:
		return 0
	var raw := float(QUOTA_PER_PLAYER * maxi(1, crew)) * M.pow_js(QUOTA_DEPTH_STEP, float(depth - 1))
	return maxi(QUOTA_ROUND, roundi(raw / QUOTA_ROUND) * QUOTA_ROUND)

## The crew a floor quota is for: everyone in the run who has not left the game (the host marks those
## who leave "leftBehind"; between floors nobody else is).
static func quota_crew(players: Array[RunPlayer]) -> int:
	var n := 0
	for p in players:
		if p.status != &"leftBehind":
			n += 1
	return n

## Whether this floor's quota is met (always, with the quota off). Whole credits, as the call panel shows.
static func quota_reached(s: RunState) -> bool:
	return not s.quota or floori(s.floor_earned) >= s.floor_needed

## Who recorded the most on this floor (the first by id on a tie), or "" if nobody recorded anything.
static func quota_top(s: RunState) -> String:
	var top := ""
	var best := 0.0
	for id: String in _sorted_keys(s.floor_by):
		var v := float(s.floor_by[id])
		if v > best:
			best = v
			top = id
	return top

## Turns the floor quota on for a run that has not ticked yet: nothing recorded, this floor's quota for
## the crew in the run now.
static func with_quota(s0: RunState) -> RunState:
	var s := s0.copy()
	s.quota = true
	s.floor_earned = 0.0
	s.floor_by = {}
	s.floor_needed = floor_quota(0 if at_home(s) else s.depth, quota_crew(s.players))
	s.quota_met = false
	return s

## A new floor for the quota: nothing recorded yet, its quota for the crew aboard.
static func _new_quota_floor(s: RunState, players: Array[RunPlayer]) -> void:
	if not s.quota:
		return
	s.floor_earned = 0.0
	s.floor_by = {}
	s.floor_needed = floor_quota(0 if at_home(s) else s.depth, quota_crew(players))
	s.quota_met = false

## A new run: the crew in the car at floor 1's landing, doors about to open. `deck`: the places its
## floors are drawn from (places.gd); empty means Clinic only. `days`: the day loop; `quota`: the floor
## quota (see the header); `downs`: down first, then out.
static func create_run(seed: String, player_ids: Array[String], deck: Array = [], days: bool = false, quota: bool = false, downs: bool = false) -> RunState:
	var s := _create_run(seed, player_ids, deck)
	if days:
		s = with_days(s)
	if downs:
		s = with_downs(s)
	return with_quota(s) if quota else s

## The campaign prelude always has course tools. Its prepared paid floor keeps its own equipment flags.
static func with_orientation(initial: RunState, prelude := false) -> RunState:
	var ids: Array[String] = []
	for player in initial.players:
		ids.append(player.id)
	var s := _create_run(initial.seed, ids, Places.ORIENTATION_ONLY, Orientation.PRELUDE_DEPTH if prelude else 1)
	s.orientation = true
	s.car_waits = true
	s.quota = true
	s.floor_needed = Orientation.QUOTA
	if prelude:
		s.orientation_resume = initial
		s.wallets = initial.wallets
	if prelude or initial.flare:
		s = with_flare(s)
	return with_lamp(s) if prelude or initial.lamp else s

## Turns down first, then out on for a run (see the header): nobody down, no red spots.
static func with_downs(s0: RunState) -> RunState:
	var s := s0.copy()
	s.downs = true
	s.down = {}
	s.spots = []
	return s

## The run with two-watcher Stillness on (sim/entity.gd "Watchers"; docs/floors/traits-and-hiding.md
## section 1): from three up players on the floor it takes two watchers to hold a Stillness resident.
static func with_two_watchers(s0: RunState) -> RunState:
	var s := s0.copy()
	s.two_watchers = true
	return s

## The run with relocation on (sim/relocate.gd; docs/floors/traits-and-hiding.md section 5): see the header.
static func with_relocation(s0: RunState) -> RunState:
	var s := s0.copy()
	s.relocation = true
	return s

## Turns the long dark on (T20c, see the header): every call from now on has the longer blackout.
static func with_long_dark(s0: RunState) -> RunState:
	var s := s0.copy()
	s.long_dark = true
	return s

## Turns paced on (T20h, see the header): the bigger tank and the faster residents.
static func with_paced(s0: RunState) -> RunState:
	var s := s0.copy()
	s.paced = true
	return s

## Turns the car waits on (FD4, see the header): nobody left out yet.
static func with_car_waits(s0: RunState) -> RunState:
	var s := s0.copy()
	s.car_waits = true
	s.left_out = {}
	return s

## Turns the day quota's lock on (FD2, see the header) for a run with days: nothing earned yet today.
## A run without days is returned as it is (there is no day to lock).
static func with_day_lock(s0: RunState) -> RunState:
	if not s0.days:
		return s0
	var s := s0.copy()
	s.day_lock = true
	s.day_earned = 0.0
	s.day_met = false
	return s

## Today's day quota (Day.day_quota for the morning's crew), 0 without days.
static func day_quota_now(s: RunState) -> int:
	return Day.day_quota(s.day_state, DAY_FLOOR_QUOTA) if s.days and s.day_state != null else 0

## Whether BANK is locked now: the lock is on and today's earned (whole credits) is under the day quota.
static func day_locked(s: RunState) -> bool:
	return s.day_lock and s.days and Day.is_locked(floori(s.day_earned), day_quota_now(s))

## The crew BANK pays today: everyone in the run but those the car left out (the car waits).
static func day_crew(s: RunState) -> Array[String]:
	var crew: Array[String] = []
	for p in s.players:
		if not (s.car_waits and s.left_out.has(p.id)):
			crew.append(p.id)
	return crew

## What is aboard now, in whole credits: the tapes held by every player on their feet in the car (what
## BANK would pay, before the bell's flush of open readings).
static func day_aboard(s: RunState) -> int:
	var total := 0.0
	for p in s.players:
		if p.status != &"ok" or not p.aboard:
			continue
		var m := Instr.member(s.crew, p.id)
		if m != null:
			total += TapeLib.tape_value(_held_tapes(m))
	return floori(total)

## What BANK would do now and what a missed day would cost (Day.bank_preview, the lift monitor's rows), for
## a run with days; null without. Earned is today's (the lock's) with the lock on, else what is aboard.
static func day_preview(s: RunState) -> Variant:
	if not s.days or s.day_state == null:
		return null
	var aboard := day_aboard(s)
	var earned := floori(s.day_earned) if s.day_lock else aboard
	return Day.bank_preview(s.day_state, aboard, earned, day_crew(s), s.wallets, DAY_FLOOR_QUOTA, s.quick_fingers)
## Turns the tuned Playroom on (T15m, see the header): every Playroom from now on (and one already reached)
## has the long hiding time, the anger bar, the grab at 1 m and the hint events (sim/seek.gd "T15m").
static func with_playroom_tuned(s0: RunState) -> RunState:
	var s := s0.copy()
	s.playroom_tuned = true
	if s.seek != null:
		s.seek = Seek.tune(s.seek as Seek.SeekState)
	return s

## Turns solid furniture on (FD7, see the header): from now on players slide along every floor's pieces.
static func with_furniture(s0: RunState) -> RunState:
	var s := s0.copy()
	s.furniture = true
	return s

## Enables the restored layout on top of solid furniture.
static func with_furniture_layout(s0: RunState) -> RunState:
	var s := with_furniture(s0)
	s.furniture_layout = true
	return s

## Turns findables on (FD9, see the header): nothing opened, no pages dealt, nothing carried.
## Opt-in: only rooms with search and the ordinary bag can deal badges.
static func with_badge_search(s0: RunState) -> RunState:
	if not s0.findables or not s0.inventory:
		return s0
	var s := s0.copy()
	s.badge_search = true
	return s

static func with_findables(s0: RunState) -> RunState:
	var s := s0.copy()
	s.findables = true
	s.find = null
	s.lore_used = []
	s.items = {}
	return s

## Turns the shop and the cabinet on (S2, see the header): empty cabinets, nothing lit.
static func with_shop(s0: RunState) -> RunState:
	var s := s0.copy()
	s.shop = true
	s.shop_state = Shop.ShopState.new()
	return s

## Turns the four-slot inventory on (S1, see the header): empty hands, nothing on the floor.
static func with_inventory(s0: RunState) -> RunState:
	var s := s0.copy()
	s.inventory = true
	s.bags = {}
	s.pickups = []
	s.pickups_plan = null
	s.pickup_seq = 0
	return s

## Enable searching the Arboretum's outdoor storage sites.
static func with_deep_pockets(s0: RunState) -> RunState:
	var s := s0.copy()
	s.deep_pockets = true
	return s

static func with_second_wind(s0: RunState) -> RunState:
	var s := s0.copy()
	s.second_wind = true
	return s

static func with_flare(s0: RunState) -> RunState:
	var s := s0.copy() if s0.inventory else with_inventory(s0)
	s.flare = true
	return s

static func with_lamp(s0: RunState) -> RunState:
	var s := s0.copy()
	s.lamp = true
	return s

static func lamp_of(s: RunState, player_id: String) -> Dictionary:
	return s.lamps.get(str(s.flare_profiles.get(player_id, player_id)), {})

static func flare_stunned(s: RunState, t: float) -> bool:
	return s.flare and s.flare_plan == s.plan and t < s.flare_stun_until

static func flare_blinded(s: RunState, id: String, t: float) -> bool:
	if s.flare and s.flare_plan == s.plan:
		for burst in s.flare_bursts:
			if burst.blind == id and t < float(burst.blindUntil):
				return true
	return false

static func with_soft_shoes(s0: RunState) -> RunState:
	var s := s0.copy()
	s.soft_shoes = true
	return s

static func with_quick_fingers(s0: RunState) -> RunState:
	if not (s0.deep_pockets and s0.inventory and s0.shop and s0.findables):
		return s0
	var s := s0.copy()
	s.quick_fingers = true
	return s

static func with_long_burn(s0: RunState) -> RunState:
	var s := s0.copy()
	s.long_burn = true
	return s

static func training_enabled(s: RunState, id: String) -> bool:
	match id:
		"deep_pockets":
			return s.deep_pockets
		"second_wind":
			return s.second_wind
		"soft_shoes":
			return s.soft_shoes
		"long_burn":
			return s.long_burn
		"quick_fingers":
			return s.quick_fingers
	return false

static func wind_spent_here(s: RunState, id: String) -> bool:
	return s.wind_spent.get(s.wind_profiles.get(id, id)) == Vector2i(s.day_index, s.depth)

static func can_second_wind(s: RunState, id: String) -> bool:
	if not s.second_wind or s.depth <= 0 or s.phase in [&"riding", &"arriving", &"ended"]:
		return false
	var wallet: Upgrades.UpgradeState = s.wallets.get(id)
	return wallet != null and wallet.owned.has("second_wind") and not wind_spent_here(s, id) and not _in_hide(s, id)

static func spend_second_wind(s0: RunState, id: String) -> RunState:
	var s := s0.copy()
	s.wind_spent = s.wind_spent.duplicate()
	s.wind_spent[s.wind_profiles.get(id, id)] = Vector2i(s.day_index, s.depth)
	return s

static func with_garden_search(s0: RunState) -> RunState:
	var s := s0.copy()
	s.garden_search = true
	return s

## Enable the Arboretum cone decoy for an inventory run.
static func with_garden_cones(s0: RunState) -> RunState:
	var s := s0.copy()
	s.garden_cones = true
	return s

## The floor's solid pieces for players in this run (Furniture.solids_of), or null when furniture is off.
static func solids_in(state: RunState) -> Move.Solids:
	if state == null or not state.furniture or state.plan == null:
		return null
	return Furniture.solids_of(state.plan, state.furniture_layout)

## Enables furniture routing for residents. The host applies this after enabling solid furniture.
static func with_resident_navigation(s0: RunState) -> RunState:
	var s := s0.copy()
	s.resident_navigation = true
	s.orderly = _settled_resident(s, s.orderly)
	return s

static func _resident_solids(s: RunState) -> Move.Solids:
	var solids := solids_in(s) if s.resident_navigation else null
	return solids if solids != null and solids.count() > 0 else null

static func _settled_resident(s: RunState, o: Entity.OrderlyState) -> Entity.OrderlyState:
	var solids := _resident_solids(s)
	if solids == null:
		return o
	var body := Move.settle(s.plan, solids, o.body, Entity.kind_of(o).radius)
	if body == o.body:
		return o
	var next := o.copy()
	next.body = body
	next.resident_walk = null
	return next

## The run with this tuning in force (live settings, sim/settings.gd): `given` is {id: number}, checked by
## the caller with Settings.check. An empty set reads exactly like none.
static func with_tuning(s0: RunState, given: Dictionary) -> RunState:
	var s := s0.copy()
	s.tuning = Settings.make(given)
	return s

## The hunting speed of this floor's Stillness resident, by its body (live settings: orderly.* or temp.*),
## or `fallback`, today's, when the host has not set it.
static func _tuned_hunt(s: RunState, dark: bool, fallback: float) -> float:
	if s.tuning == null:
		return fallback
	if Entity.kind_of(s.orderly).name == &"temp":
		return Settings.f(s.tuning, &"temp.dark_speed" if dark else &"temp.speed", fallback)
	return Settings.f(s.tuning, &"orderly.dark_speed" if dark else &"orderly.speed", fallback)

## The Lonely Temp's chase speed (live settings: temp.speed lit, temp.dark_speed in the blackout, temp.alone_speed
## with a crew of one), or -1 (Lonely's own constants, sim/lonely.gd CHASE_SPEED and SOLO_CHASE_SPEED) when the
## host has not set it: an untuned run passes -1 and Lonely chases exactly as it always did.
static func _tuned_chase(s: RunState, solo: bool) -> float:
	if s.tuning == null:
		return -1.0
	if solo:
		return Settings.f(s.tuning, &"temp.alone_speed", -1.0)
	return Settings.f(s.tuning, &"temp.dark_speed" if blacked_out(s) else &"temp.speed", -1.0)

## Seconds of sprinting a player's tank holds in this run (Stamina.Stamina.tank): more when paced.
static func sprint_seconds(s: RunState) -> float:
	var today := Stamina.PACED_SPRINT_SECONDS if s != null and s.paced else Stamina.SPRINT_SECONDS
	# Live settings: the host's tank (stamina.tank). The host resizes every tank to it, keeping how full it is.
	return Settings.f(s.tuning, &"stamina.tank", today) if s != null else today

## The boarding window of this run (seconds from the doors opening to the bell).
static func board_time(s: RunState) -> float:
	if s.orientation:
		return 3.0
	return Settings.f(s.tuning, &"lift.board", BOARD_TIME_WAITS if s.car_waits else BOARD_TIME)

## The most a crew may hold the doors at one stop (live settings: lift.hold), stamped as the doors open.
static func hold_limit(s: RunState) -> float:
	return Settings.f(s.tuning, &"lift.hold", HOLD_LIMIT)

## The car waits: everyone on their feet who is not in `aboard` as the car leaves is left out for the day.
static func _leave_out(s: RunState, players: Array[RunPlayer], aboard: Dictionary) -> void:
	if not s.car_waits or s.orientation:
		return
	var out := s.left_out.duplicate()
	for p in players:
		if p.status == &"ok" and not aboard.has(p.id):
			out[p.id] = true
	s.left_out = out
## The run with Lonely on (sim/lonely.gd; docs/floors/traits-and-hiding.md section 2): see the header.
static func with_lonely(s0: RunState) -> RunState:
	var s := s0.copy()
	s.lonely = true
	return s

## Who lives on the run's floor, with the run's rules (Places.resident_in): the host and the network read it too.
static func resident_of(s: RunState) -> Places.Resident:
	return Places.resident_in(s.plan.place if s.plan != null else &"", s.lonely)

static func _create_run(seed: String, player_ids: Array[String], deck: Array = [], depth := 1) -> RunState:
	assert(not player_ids.is_empty(), "a run needs at least one player")
	var d := deck_of(deck)
	var f := _floor_for(seed, depth, d)
	var s := RunState.new()
	s.seed = seed
	s.deck = d
	s.t = 0.0
	s.depth = depth
	s.plan = f.plan
	s.car = f.car
	s.orderly = f.orderly
	s.entity_id = f.entity_id
	s.crew = Instr.create_crew(player_ids)
	for i in player_ids.size():
		var p := RunPlayer.new()
		p.id = player_ids[i]
		p.body = _car_slot(f.car, i)
		p.status = &"ok"
		p.aboard = true
		p.side = null
		s.players.append(p)
	s.phase = &"arriving"
	s.timer = ARRIVE_DOOR_DELAY
	return s

## Whether the car's doors are open at this floor's landing.
static func doors_open(state: RunState) -> bool:
	return state.phase == &"unloading" or state.phase == &"boarding"

## Whether every player is blind this tick (a blink is on).
static func blinking(state: RunState) -> bool:
	return state.blink != null and state.blink.ends_at != null

## Whether the blackout (the wait's last, long dark) is on this tick.
static func blacked_out(state: RunState) -> bool:
	return blinking(state) and state.blink.blackout

## The `n`-th dark stretch of a call as run state (unannounced), or null past the last.
static func _blink_of(call: CallState, n: int) -> BlinkState:
	if n >= call.plan.darks.size():
		return null
	var d := call.plan.darks[n]
	var b := BlinkState.new()
	b.call_index = call.index
	b.n = n
	b.at = call.at + d.at
	b.len = d.len
	b.warn = d.warn
	b.blackout = d.blackout
	b.announced = false
	b.ends_at = null
	return b

# ---------------------------------------------------------------------------------------------
# Moving bodies with the car in mind.

## Moves a player's body by (dx, dz) like move_with_collision, except that the car's doorway is open
## while the doors are, and inside the car the car's walls hold. A body caught in the doorway when
## the doors shut is pushed to whichever side its centre is on.
static func move_in_run(state: RunState, body: Move.Body, dx: float, dz: float, radius: float) -> Move.Body:
	var dist := M.hypot2(dx, dz)
	var n := maxi(1, int(ceil(dist / 0.05)))
	var cur := body
	var open := doors_open(state)
	var solids := solids_in(state)
	if solids != null:
		cur = Move.settle(state.plan, solids, cur, radius)
	for _i in n:
		cur = _move_step(state.plan, state.car, open, cur, dx / n, dz / n, radius, solids)
	return cur

static func _clamp(x: float, lo: float, hi: float) -> float:
	return maxf(lo, minf(hi, x))

static func _move_step(plan: Floor.FloorPlan, car: CarGeometry, open: bool, cur: Move.Body, sx: float, sz: float, r: float, solids: Move.Solids = null) -> Move.Body:
	if cur.level != car.level:
		return Move.move_with_collision(plan, cur, sx, sz, r, solids)
	var here := car_local(car, cur.x, cur.z)
	var next := car_local(car, cur.x + sx, cur.z + sz)
	var band := car.door_width / 2.0 - r
	var out := -(r + DOOR_ZONE_SLACK)
	var here_in_channel := here[0] > out and absf(here[1]) <= band + EPS
	var next_in_channel := next[0] > out and absf(next[1]) <= band + EPS
	# Inside the car: past the wall line AND within its width and depth. Floor beside or behind the car, past
	# the wall line's extension, is ordinary floor (it used to count as inside and snapped a body into the car).
	var inside := here[0] > 0.0 and here[0] <= car.depth + EPS and absf(here[1]) <= car.width / 2.0 + EPS
	var zone := inside or here_in_channel
	if not zone:
		if open and next_in_channel:
			return car_body(car, next[0], next[1])
		return Move.move_with_collision(plan, cur, sx, sz, r, solids)
	var inside_v := car.width / 2.0 - r
	var max_u := car.depth - r
	if open and absf(next[1]) <= band + EPS:
		return car_body(car, minf(next[0], max_u), next[1])
	if inside:
		# Inside: the car's walls hold. In the open doorway, slide along it; otherwise stay clear of the front wall.
		if open and here[0] < r:
			return car_body(car, minf(next[0], max_u), _clamp(next[1], -band, band))
		return car_body(car, _clamp(next[0], r, max_u), _clamp(next[1], -inside_v, inside_v))
	# On the landing side of the doorway with the doors shut (or stepping sideways out of the gap): back out.
	return car_body(car, minf(next[0], out - 0.001), _clamp(next[1], -inside_v, inside_v))

# ---------------------------------------------------------------------------------------------
# Helpers.

static func _view_of(inp: PlayerInput, active: bool, blind: bool) -> Entity.PlayerView:
	return Entity.PlayerView.make(inp.id, inp.body, inp.eye, inp.yaw, inp.pitch, inp.h_fov_deg, inp.v_fov_deg, active, blind)

## The view a player inside the car has of the floor: eyes moved onto the threshold.
static func _threshold_view(car: CarGeometry, inp: PlayerInput) -> Entity.PlayerView:
	var v := car_local(car, inp.body.x, inp.body.z)[1]
	var at := car_body(car, -0.02, _clamp(v, -car.door_width / 2.0, car.door_width / 2.0))
	var body := Move.Body.make(at.x, at.z, at.level, inp.body.y)
	return Entity.PlayerView.make(inp.id, body, inp.eye, inp.yaw, inp.pitch, inp.h_fov_deg, inp.v_fov_deg, true, false)

static func _step_orientation(s: RunState, players: Array[RunPlayer], input_of: Dictionary, dt: float,
		events: Array[Dictionary]) -> Instr.EntityTick:
	var targets: Array[Entity.PlayerView] = []
	var watchers: Array[Entity.PlayerView] = []
	for p in players:
		if not _is_active(p, input_of):
			continue
		var input := _inp(p, input_of)
		var blind := input.blind or flare_blinded(s, p.id, s.t)
		if p.aboard:
			if doors_open(s) and not blind:
				watchers.append(_threshold_view(s.car, input))
		else:
			var view := _view_of(input, true, blind)
			targets.append(view)
			watchers.append(view)
			s.orientation_standees = Orientation.trigger_standees(s.orientation_standees, p.body, s.t)
	var before := s.orderly
	var step := Orientation.step_target(s.plan, before, targets, watchers, dt, flare_stunned(s, s.t))
	s.orderly = step.state
	events.append_array(step.events)
	var sample := Instr.EntityTick.make(s.entity_id, &"stillness", before, step.state, step.events)
	var rates := {}
	for target in targets:
		rates[target.id] = Orientation.PAY_SCALE
	sample.pay = rates
	return sample

## Distance from a point to a rectangle (0 inside).
static func rect_distance(r: Rect, x: float, z: float) -> float:
	var dx := maxf(maxf(r.x0 - x, 0.0), x - r.x1)
	var dz := maxf(maxf(r.z0 - z, 0.0), z - r.z1)
	return M.hypot2(dx, dz)

static func _scaled(tape: TapeLib.Tape, ids: Dictionary, mult: float) -> TapeLib.Tape:
	var any := false
	for r in tape.readings:
		if ids.has(r.id):
			any = true
	if not any:
		return tape
	var t := tape.copy()
	t.readings = []
	var total := 0.0
	for r in tape.readings:
		var nr := r
		if ids.has(r.id):
			nr = r.copy()
			nr.value = r.value * mult
			nr.peak_rate = r.peak_rate * mult
		t.readings.append(nr)
		total = total + nr.value
	t.total = total
	return t

## Every tape held by members, carried, or on the floor, with readings scaled by id.
static func _scale_readings(crew: Instr.CrewState, ids: Dictionary, mult: float) -> Instr.CrewState:
	if ids.is_empty() or mult == 1.0:
		return crew
	var c := crew.copy()
	c.members = []
	for m in crew.members:
		var nm := m.copy()
		nm.tape = _scaled(m.tape, ids, mult)
		nm.carrying = []
		for tp in m.carrying:
			nm.carrying.append(_scaled(tp, ids, mult))
		c.members.append(nm)
	c.floor = []
	for f in crew.floor:
		c.floor.append(Instr.FloorTape.make(_scaled(f.tape, ids, mult), f.at))
	return c

## step_crew, with closed readings multiplied by the depth's pay (tapes and events both).
static func _crew_tick(s: RunState, players: Array[Instr.CrewPlayer], entities: Array[Instr.EntityTick], dt: float) -> Instr.CrewStep:
	var out := Instr.step_crew(s.plan, s.crew, players, entities, dt)
	var mult := depth_multiplier(s.depth)
	var ids := {}
	for e in out.events:
		if e["type"] == "readingClosed":
			ids[(e["reading"] as TapeLib.Reading).id] = true
	if ids.is_empty() or mult == 1.0:
		return out
	var events: Array[Dictionary] = []
	for e in out.events:
		if e["type"] == "readingClosed":
			var ne := e.duplicate()
			ne["value"] = float(e["value"]) * mult
			var rd := (e["reading"] as TapeLib.Reading).copy()
			rd.value = rd.value * mult
			rd.peak_rate = rd.peak_rate * mult
			ne["reading"] = rd
			events.append(ne)
		else:
			events.append(e)
	var res := Instr.CrewStep.new()
	res.crew = _scale_readings(out.crew, ids, mult)
	res.events = events
	return res

static func _held_tapes(m: Instr.CrewMember) -> Array[TapeLib.Tape]:
	var out: Array[TapeLib.Tape] = []
	for tp: TapeLib.Tape in [m.tape] + m.carrying:
		if not tp.readings.is_empty():
			out.append(tp)
	return out

static func _summarize(s: RunState, tapes: Array[TapeLib.Tape], wiped: bool) -> RunSummary:
	var r := RunSummary.new()
	r.depth = s.depth
	r.total = 0.0 if wiped else TapeLib.tape_value(tapes)
	var share := r.total / s.players.size()
	if s.car_waits and not s.left_out.is_empty():
		# The car waits: whoever it left out today has no share (see the header).
		var kept := 0
		for p in s.players:
			if not s.left_out.has(p.id):
				kept += 1
		share = r.total / maxi(1, kept)
	var n := 0
	for tp in tapes:
		n += tp.readings.size()
	r.readings = 0 if wiped else n
	for p in s.players:
		r.shares[p.id] = 0.0 if (s.car_waits and s.left_out.has(p.id)) else share
	if not wiped:
		for tp in tapes:
			r.tapes.append(tp.id)
	r.wiped = wiped
	return r

static func _with_t(e: Dictionary, t: float) -> Dictionary:
	var ne := e.duplicate()
	ne["t"] = t
	return ne

# ---------------------------------------------------------------------------------------------
# The tick.

## Advances the run by dt seconds. Never mutates `prev`. Inputs for unknown ids are ignored.
static func step_run(prev: RunState, inputs: Array[PlayerInput], dt: float) -> RunStep:
	if dt > MAX_TICK + EPS:
		var n := int(ceil(dt / MAX_TICK - EPS))
		var state := prev
		var out := RunStep.new()
		for _i in n:
			var r := _step_once(state, inputs, dt / n)
			state = r.state
			out.events.append_array(r.events)
		out.state = state
		return out
	return _step_once(prev, inputs, dt)

## The lights. Blinks run on their own clock: once announced, a blink always happens, even after the
## car arrives (the schedule ends each one before the blackout, so that does not happen). The blackout
## ends when the car arrives, on the tick its doors open.
static func _step_blink(s: RunState, t: float, events: Array[Dictionary]) -> void:
	var b := s.blink
	if b == null:
		return
	if not b.announced and t >= b.at - b.warn - EPS:
		# While the car is coming, or later if it was already scheduled to be announced before arrival.
		if s.phase != &"coming":
			s.blink = null
			return
		var nb := b.copy()
		nb.announced = true
		s.blink = nb
		events.append({"type": "blinkSoon", "t": t, "at": b.at, "len": b.len, "blackout": b.blackout})
	var c := s.blink
	if c != null and c.announced and c.ends_at == null and t >= c.at - EPS:
		var nc := c.copy()
		nc.ends_at = t + c.len
		s.blink = nc
		events.append({"type": "blinkStart", "t": t, "len": c.len, "blackout": c.blackout})
	var d := s.blink
	if d != null and d.ends_at != null and ((s.phase != &"coming") if d.blackout else (t >= float(d.ends_at) - EPS)):
		events.append({"type": "blinkEnd", "t": t, "blackout": d.blackout})
		s.blink = _blink_of(s.call, d.n + 1) if (s.phase == &"coming" and s.call != null) else null

# ---------------------------------------------------------------------------------------------
# The Playroom (see the header).

## Whether this floor's resident is the Minder stepped by seek.gd.
static func seeks(s: RunState) -> bool:
	return not s.seek_off and not at_home(s) and s.plan != null and s.plan.place == Places.PLAYROOM

## Keeps `seek` the state of this floor: made when the crew reaches a Playroom (everyone at 100, the
## Minder at its start facing its wall), dropped on any other floor.
static func _sync_seek(s: RunState) -> void:
	if not seeks(s):
		if s.seek != null:
			s.seek = null
			s.seek_drops = []
			s.seek_call_at = -1.0
		return
	if s.seek != null and (s.seek as Seek.SeekState).floor.plan == s.plan:
		return
	var ids: Array[String] = []
	for p in s.players:
		ids.append(p.id)
	s.seek = Seek.create_seek(s.plan, ids)
	(s.seek as Seek.SeekState).t = s.t
	if s.playroom_tuned:
		s.seek = Seek.tune(s.seek as Seek.SeekState)
	s.seek_drops = []
	s.seek_call_at = -1.0

## The run's view of a seek player: whether the rules hold their body (in a hide, found, taken, down).
static func _seek_holds(sp: Seek.SeekPlayer) -> bool:
	return sp != null and sp.body != null and (sp.status != &"ok" or sp.phase != &"out")

## One tick of the Playroom's rules. Updates `s` (seek, orderly, seek_drops, the car on the last
## count's end) and `players` (statuses and bodies), appends the events, and returns the Minder's tick
## for the instruments.
static func _step_seek(s: RunState, players: Array[RunPlayer], input_of: Dictionary, call_by: String, t_prev: float, t: float, dt: float, events: Array[Dictionary]) -> Instr.EntityTick:
	var ss: Seek.SeekState = s.seek
	var drops := s.seek_drops
	s.seek_drops = []
	var inputs: Array[Seek.SeekInput] = []
	for p in players:
		var sp := Seek.player_of(ss, p.id)
		var status: StringName = sp.status if sp != null else &"ok"
		if status == &"found" and sp.body != null:
			# Rooted where found: the Minder is coming for them.
			inputs.append(Seek.SeekInput.make(p.id, sp.body, &"walk"))
			continue
		if drops.has(p.id):
			# Down last tick: their tape hits the floor now, and that is heard.
			# (With the down rule: out last tick, where they had crawled to.)
			var di := Seek.SeekInput.make(p.id, sp.body if (not s.downs and sp != null and sp.body != null) else p.body, &"walk")
			di.dropped_tape = true
			inputs.append(di)
			continue
		if status != &"ok" or not _is_active(p, input_of) or p.aboard:
			# Taken (at the party table), down, gone, or in the car: not on the floor for it.
			continue
		var i: PlayerInput = input_of[p.id]
		var si := Seek.SeekInput.make(p.id, i.body, i.gait)
		si.use = i.hide_use
		si.fast = i.hide_fast
		si.peek = i.peek
		si.emote_sound = i.emote_sound
		si.voice = i.voice
		si.horn = i.horn
		si.light = i.light
		var carried := lamp_of(s, p.id) if s.lamp else {}
		if bool(carried.get("on", false)):
			si.light = Lamp.beam(s.tuning, p.body, i.eye, i.yaw, i.pitch)
		# The shop (S2): a wind-up toy of theirs starting to rattle is their noise.
		si.toy = s.shop and Shop.rattles_from(s.shop_state, t_prev, t).has(p.id)
		var mem := Instr.member(s.crew, p.id)
		si.ticking = mem != null and mem.instrument.ticks > 0
		inputs.append(si)
	var fl := Seek.FloorInput.new()
	fl.call = call_by != ""
	fl.call_by = call_by
	fl.boarding = s.phase == &"boarding"
	fl.riding = s.phase == &"riding"
	# The seek runs on the run's own clock: every time in its events and state is host time.
	var base := ss.copy()
	base.t = t_prev
	var r := Seek.step_seek(base, inputs, dt, fl, s.tuning)
	var ns := r.state
	s.seek = ns
	events.append_array(r.events)

	# The Minder as the network and the views carry a resident: its pose, mode and speed.
	var before := s.orderly
	var o := before.copy()
	var mm := ns.minder
	o.t = before.t + dt
	o.body = mm.body
	o.yaw = mm.yaw
	o.mode = mm.mode
	o.anim = mm.anim
	o.anim_time = mm.anim_time
	o.speed = mm.speed
	o.moving = mm.moving
	o.seen = false
	o.held = false
	o.frozen = false
	o.wind_up_left = 0.0
	o.wind_up_target = null
	o.target_id = null
	s.orderly = o
	s.lure = false

	# Statuses and bodies: found, taken and down are out of the run (caught) where the rules hold them.
	for k in players.size():
		var p := players[k]
		var sp := Seek.player_of(ns, p.id)
		if sp == null:
			continue
		var np := p
		# Down first, then out: down from health is a down like a catch's (they crawl; the rules do not hold them).
		var crawls := s.downs and sp.status == &"down"
		if sp.status != &"ok" and p.status == &"ok":
			if crawls:
				_go_down(s, players, k, t, &"health", events)
				continue
			np = p.copy()
			np.status = &"caught"
			np.side = null
		if crawls:
			continue
		if _seek_holds(sp) and not (np.body.x == sp.body.x and np.body.z == sp.body.z and np.body.level == sp.body.level and np.body.y == sp.body.y):
			if np == p:
				np = p.copy()
			np.body = sp.body
			np.aboard = in_car(s.car, np.body)
		players[k] = np

	# The instruments: found or down drops the tapes where they are (the instrument's "caught").
	var caught: Array[Dictionary] = []
	for e in r.events:
		if e["type"] == "down" and s.downs:
			continue  # Down first, then out: the tape drops (and is heard) when they are out.
		if e["type"] == "found" or e["type"] == "down":
			caught.append({"type": "caught", "t": t, "playerId": e["playerId"]})
		if e["type"] == "down":
			s.seek_drops.append(String(e["playerId"]))
	var who := Places.resident(s.plan.place)
	var et := Instr.EntityTick.make(s.entity_id, who.trait_name, before, o, caught)
	# Recording (playarea.md 11): only while it searches, after the 6 s; only for a player out of its
	# view, or peeking from a hide. Sitting back in a hide, or standing in its view, records nothing.
	et.acting = Seek.phase_of(ns) == &"seek"
	var holders := {}
	if et.acting:
		for p in players:
			var sp := Seek.player_of(ns, p.id)
			if sp == null or sp.status != &"ok" or sp.body == null or not _is_active(p, input_of) or p.aboard:
				continue
			if sp.phase == &"inside":
				if sp.peeking:
					holders[p.id] = true
			elif not Seek.in_view(s.plan, mm.body, mm.yaw, sp.body):
				holders[p.id] = true
	et.holders = holders

	# The last count over: the car is here, doors open, boarding as on any floor.
	for e in r.events:
		if e["type"] == "countEnd" and bool(e["last"]) and s.phase == &"coming":
			s.phase = &"boarding"
			s.bell_left = board_time(s)
			s.hold_left = hold_limit(s)
			s.held = false
			s.call = null
			s.blink = null
			events.append({"type": "carArrived", "t": t, "wait": t - s.seek_call_at if s.seek_call_at >= 0.0 else 0.0})
			events.append({"type": "doorsOpened", "t": t, "depth": s.depth, "reason": "boarding"})
	return et

# ---------------------------------------------------------------------------------------------
# The Arboretum (see the header): the Groundskeeper, who hears.

## Whether this floor's resident is the Groundskeeper stepped by sim/hearing.gd.
static func listens(s: RunState) -> bool:
	return not s.seek_off and not at_home(s) and s.plan != null and s.plan.place == Places.ARBORETUM

## Keeps `garden` the state of this floor: made when the crew reaches an Arboretum (the Groundskeeper where the
## floor's resident starts, listening), dropped on any other floor.
static func _sync_garden(s: RunState) -> void:
	if not listens(s):
		if s.garden != null:
			s.garden = null
		return
	if s.garden != null and s.garden.plan == s.plan:
		return
	var g := GardenFloor.new()
	g.plan = s.plan
	g.keeper = Hearing.create(s.orderly.body, s.orderly.yaw)
	g.keeper.t = s.t
	s.garden = g

## The heals a player still has on this Arboretum floor (0 off one).
static func keeper_heals_left(s: RunState, id: String) -> int:
	if s.garden == null:
		return 0
	return maxi(0, Settings.i(s.tuning, &"groundskeeper.heals", KEEPER_HEALS) - int(s.garden.heals.get(id, 0)))

## One tick of the Arboretum's rules (see the header). Updates `s` (garden, orderly, hiding) and `players`
## (statuses and bodies), appends the events, and returns the Groundskeeper's tick for the instruments.
## `ev_from`: where this tick's hiding events start in `events`.
static func _step_garden(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t_prev: float, t: float, dt: float, events: Array[Dictionary], ev_from: int) -> Instr.EntityTick:
	var g := s.garden.copy()
	# Nothing sees on this floor: hiding's "seen" reasons are not the Groundskeeper's (it reads none of them).
	var hide_noise := {}
	var i := ev_from
	while i < events.size():
		var ty: String = events[i]["type"]
		if ty == "reason":
			events.remove_at(i)
			continue
		if ty == "hideStart" or ty == "hideLeave":
			hide_noise[str(events[i]["playerId"])] = int(events[i]["hide"])
		i += 1
	var search_noise := {}
	if s.garden_search:
		for e in events:
			if e.get("silent", false):
				continue
			var kind := str(e["type"])
			if kind == "searchStart" and bool(e["fast"]):
				search_noise[str(e["playerId"])] = Noises.search_radius(true, s.tuning)
			elif kind == "searchDone" and not bool(e["fast"]):
				search_noise[str(e["playerId"])] = Noises.search_radius(false, s.tuning)
	var people: Array[Hearing.Person] = []
	for p in players:
		var down := p.status == &"down" and s.down.has(p.id)
		if in_car(s.car, p.body) or not (down or _is_active(p, input_of)):
			continue
		var inp := _inp(p, input_of)
		var hp := Hearing.Person.make(p.id, p.body, inp.gait)
		if s.soft_shoes:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			hp.soft_shoes = wallet != null and wallet.owned.has("soft_shoes")
		hp.up = not down
		hp.down = down
		hp.emote = inp.emote_sound and not down
		if inp.wind_gasp and not down:
			hp.gasp_radius = Settings.f(s.tuning, &"noise.emote", Noises.EMOTE)
		hp.healed = g.healed.has(p.id)
		hp.hide_noise = int(hide_noise.get(p.id, -1))
		hp.search_radius = float(search_noise.get(p.id, 0.0))
		if s.hiding != null and not down:
			var h := Hiding.player_of(s.hiding, p.id)
			if h != null and h.phase == &"inside":
				hp.hide = h.hide
		people.append(hp)
	var heard_things := g.drops
	if s.flare:
		for e in events:
			if e.type == "flareUsed":
				heard_things.append(Noises.Sound.make("", e.x, e.z, e.level, e.noise, &"flare"))
	if s.shop and s.garden_cones:
		var stock: Shop.ShopState = s.shop_state
		if stock.plan == s.plan:
			for toy: Dictionary in stock.toys:
				var starts := float(toy["start"])
				if starts > t_prev + EPS and starts <= t + EPS:
					var spot: Move.Body = toy["at"]
					heard_things.append(Noises.Sound.make("", spot.x, spot.z, spot.level, Shop.TOY_RADIUS, &"toy"))
	for index in range(g.cones_in_flight.size() - 1, -1, -1):
		var flight := g.cones_in_flight[index]
		if t < float(flight["lands"]):
			continue
		var at: Move.Body = flight["at"]
		heard_things.append(Noises.cone(at.x, at.z, at.level, s.tuning))
		events.append({"type": "coneLanded", "t": t, "x": at.x, "z": at.z})
		g.cones_in_flight.remove_at(index)
	g.healed = []
	g.drops = []
	var base := g.keeper.copy()
	base.t = t_prev
	var r := Hearing.step(s.plan, s.plan.ground as Noises.Ground, base, people, heard_things, blacked_out(s), dt, s.tuning)
	var k := r.state
	g.keeper = k
	events.append_array(r.events)

	# The Groundskeeper as the network and the views carry a resident: its pose, mode and speed.
	var before := s.orderly
	var o := before.copy()
	o.t = before.t + dt
	o.body = k.body
	o.yaw = k.yaw
	o.mode = k.mode
	o.anim = k.anim
	o.anim_time = k.anim_time
	o.speed = k.speed
	o.moving = k.moving
	o.seen = false
	o.held = false
	o.frozen = false
	o.wind_up_left = 0.0
	o.wind_up_target = null
	o.target_id = null
	s.orderly = o
	s.lure = false

	# A snatch: down while the player still has a heal here, else out at once (see the header).
	var dropped: Array[Dictionary] = []
	var limit := Settings.i(s.tuning, &"groundskeeper.heals", KEEPER_HEALS)
	for id in r.taken:
		for n in players.size():
			if players[n].id != id or players[n].status != &"ok":
				continue
			if s.hiding != null:
				# Taken out of a hide: pulled out onto its front spot first.
				var rel := Hiding.release(s.hiding, id)
				s.hiding = rel[0]
				if rel[1] != null:
					var moved := players[n].copy()
					moved.body = rel[1]
					players[n] = moved
			events.append({"type": "caught", "t": t, "playerId": id})
			var had := int(g.heals.get(id, 0))
			if s.downs and had < limit:
				_go_down(s, players, n, t, &"catch", events)
				events[events.size() - 1]["more"] = limit - had - 1
				continue
			var np := players[n].copy()
			np.side = null
			if s.downs:
				np.status = &"out"
				var b := np.body
				var spot := {"playerId": id, "x": _cm(b.x), "z": _cm(b.z), "level": b.level, "y": _cm(b.y), "t": _mrad(t)}
				var spots: Array[Dictionary] = s.spots.duplicate()
				spots.append(spot)
				s.spots = spots
				events.append({"type": "out", "t": t, "playerId": id, "at": b, "spot": spot, "by": "keeper"})
			else:
				np.status = &"caught"
			players[n] = np
			dropped.append({"type": "caught", "t": t, "playerId": id})
	s.garden = g

	var et := Instr.EntityTick.make(s.entity_id, resident_of(s).trait_name, before, o, dropped)
	et.acting = Hearing.acting(k)
	if k.mode == &"lean":
		# The lean's pay, by each holder's closeness to its reach.
		var pay := {}
		for p in players:
			if p.status == &"ok" and p.body.level == k.body.level:
				pay[p.id] = Hearing.lean_pay(k, M.hypot2(p.body.x - k.body.x, p.body.z - k.body.z), s.tuning)
		et.pay = pay
	return et

## After the tick's heals and the crew's tick: who got back up and which tapes hit the floor, for the
## Groundskeeper to hear on the next tick; and the heal counts.
static func _garden_after(s: RunState, events: Array[Dictionary]) -> void:
	var g: GardenFloor = null
	for e in events:
		var ty: String = e["type"]
		if ty != "healed" and ty != "tapeDropped":
			continue
		if g == null:
			g = s.garden.copy()
		var id := str(e["playerId"])
		if ty == "healed":
			g.heals[id] = int(g.heals.get(id, 0)) + 1
			g.healed.append(id)
		elif e.get("at") is Move.Body:
			g.drops.append(Noises.drop(id, e["at"], s.tuning))
	if g != null:
		s.garden = g

# ---------------------------------------------------------------------------------------------
# Hiding off the Playroom (see the header).

## Whether this floor has hides the run steps with sim/hiding.gd: a Clinic or an Annex with its resident.
static func hides_here(s: RunState) -> bool:
	if s.plan != null and s.plan.place == Places.ARBORETUM:
		return listens(s)
	return not at_home(s) and s.plan != null and (s.plan.place == Places.CLINIC or s.plan.place == Places.ANNEX) \
		and Places.resident(s.plan.place).stillness

## Drops `hiding` on any other floor (it is made at the first hide press: _step_hiding).
static func _sync_hiding(s: RunState) -> void:
	if s.hiding != null and (not hides_here(s) or (s.hiding as Hiding.HidingState).floor.plan != s.plan):
		s.hiding = null

## One tick of hiding, before the resident: presses, getting in and out, peeking, reasons. Updates `s`
## (hiding) and `players` (the bodies the rules hold) and appends the events.
static func _step_hiding(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t_prev: float, dt: float, events: Array[Dictionary]) -> void:
	if not hides_here(s):
		return
	var inputs: Array[Hiding.HideInput] = []
	var pressed := false
	for p in players:
		if p.status != &"ok" or not _is_active(p, input_of) or p.aboard:
			continue
		var i: PlayerInput = input_of[p.id]
		var hi := Hiding.HideInput.make(p.id, i.body)
		hi.use = i.hide_use
		hi.fast = i.hide_fast
		hi.peek = i.peek
		var mem := Instr.member(s.crew, p.id)
		hi.ticking = mem != null and mem.instrument.ticks > 0
		inputs.append(hi)
		pressed = pressed or i.hide_use
	if s.hiding == null:
		if not pressed:
			return
		s.hiding = Hiding.create(s.plan)
	var base := (s.hiding as Hiding.HidingState).copy()
	base.t = t_prev
	var o := s.orderly
	var w := Hiding.Watcher.make(o.body, o.yaw, Entity.kind_of(o).height)
	var r := Hiding.step_hiding(base, inputs, w, dt)
	s.hiding = r.state
	events.append_array(r.events)
	for k in players.size():
		var hp := Hiding.player_of(r.state, players[k].id)
		if hp == null or players[k].status != &"ok":
			continue
		var held := Hiding.held_body(r.state, hp)
		if held != null:
			var np := players[k].copy()
			np.body = held
			np.aboard = false
			players[k] = np

## The resident's view of a player in a hide (sim/entity.gd "Hidden players"), or null when they are not in
## one. Sat back they see nothing; peeking, they look out of the gap from the hide's eye, turned only
## within it (as client/play_link.gd hide_camera draws it).
static func _hidden_view(s: RunState, inp: PlayerInput, blind: bool) -> Entity.PlayerView:
	if s.hiding == null:
		return null
	var hs: Hiding.HidingState = s.hiding
	var hp := Hiding.player_of(hs, inp.id)
	if hp == null or hp.phase != &"inside":
		return null
	var h := Hiding.hide_of(hs, hp.hide)
	var at := Hiding.inside_body(hs, h)
	var gy := Seek.yaw_toward(float(Floor.dir_dx(h.gap)), float(Floor.dir_dy(h.gap)))
	var half := deg_to_rad(float(h.gap_half))
	var yaw := gy + clampf(_wrap_pi(inp.yaw - gy), -half, half)
	var pitch := clampf(inp.pitch, -HIDE_PEEK_PITCH, HIDE_PEEK_PITCH)
	var v := Entity.PlayerView.make(inp.id, at, h.eye / 100.0, yaw, pitch, inp.h_fov_deg, inp.v_fov_deg, true, blind or not hp.peeking)
	v.hidden = true
	v.hide = h.id
	v.hide_reason = hs.reasons.has(h.id)
	v.hide_front = Hiding.front_body(hs, h)
	v.hide_at = at
	v.hide_spot = hp.spot
	return v

## Peeking: how far up or down the gap lets you look (client/play_link.gd PEEK_PITCH).
const HIDE_PEEK_PITCH := 0.35

static func _wrap_pi(a: float) -> float:
	var r := fmod(a, 2.0 * PI)
	if r > PI:
		r -= 2.0 * PI
	if r < -PI:
		r += 2.0 * PI
	return r

## After the resident's tick: players it caught out of a hide (its look-in) are pulled out, onto the hide's
## front spot, before the catch puts them down or out.
static func _release_caught(s: RunState, players: Array[RunPlayer], o_events: Array[Dictionary]) -> void:
	if s.hiding == null:
		return
	for e in o_events:
		if e["type"] != "caught":
			continue
		var r := Hiding.release(s.hiding, str(e["playerId"]))
		s.hiding = r[0]
		if r[1] == null:
			continue
		for k in players.size():
			if players[k].id == str(e["playerId"]):
				var np := players[k].copy()
				np.body = r[1]
				players[k] = np

# ---------------------------------------------------------------------------------------------
# The Annex: the crew's marks and the Temp's sticky notes (see the header).

## Whether this floor is the Annex (and the crew is not at home).
static func annexes(s: RunState) -> bool:
	return not at_home(s) and s.plan != null and s.plan.place == Places.ANNEX

## Keeps `annex` the state of this floor: a full pad and no notes when the crew reaches an Annex, null on
## any other floor.
static func _sync_annex(s: RunState) -> void:
	if not annexes(s):
		s.annex = null
		return
	if s.annex != null and s.annex.plan == s.plan:
		return
	s.annex = AnnexFloor.start(s.plan, s.note_seq)

## A player's name as the notes write it: the host's name for them, without braces, else their id.
static func name_of(s: RunState, id: String) -> String:
	var n := str(s.names.get(id, "")).replace("{", "").replace("}", "").strip_edges()
	if n.is_empty():
		n = id.replace("{", "").replace("}", "")
	return n if not n.is_empty() else "someone"

## To the centimetre and the milliradian, as the wire carries them, so every list is the same everywhere.
static func _cm(x: float) -> float:
	var r := floorf(x * 100.0 + 0.5) / 100.0
	return 0.0 if r == 0.0 else r

static func _mrad(x: float) -> float:
	var r := floorf(x * 1000.0 + 0.5) / 1000.0
	return 0.0 if r == 0.0 else r

## Where a note goes from a point: on the nearest wall (its nearest point), facing back toward the point;
## with no wall near, at the point facing `yaw`. [x, z, yaw].
static func note_spot(plan: Floor.FloorPlan, level: int, x: float, z: float, yaw: float) -> PackedFloat64Array:
	var cs := float(plan.cell_size)
	var segs := Walls.segments_near(plan, level, floori(x / cs), floori(z / cs))
	var best := INF
	var bx := x
	var bz := z
	var i := 0
	while i < segs.size():
		var ax := segs[i]
		var az := segs[i + 1]
		var ex := segs[i + 2] - ax
		var ez := segs[i + 3] - az
		var len2 := ex * ex + ez * ez
		var k := minf(1.0, maxf(0.0, ((x - ax) * ex + (z - az) * ez) / len2)) if len2 > 0.0 else 0.0
		var qx := ax + ex * k
		var qz := az + ez * k
		var d := M.hypot2(x - qx, z - qz)
		if d < best - EPS:
			best = d
			bx = qx
			bz = qz
		i += 4
	var face := yaw
	if not is_inf(best) and best > 1e-6:
		face = Entity.yaw_toward(x - bx, z - bz)
	return PackedFloat64Array([_cm(bx), _cm(bz), _mrad(face)])

static func _player_in(players: Array[RunPlayer], id: String) -> RunPlayer:
	for p in players:
		if p.id == id:
			return p
	return null

static func _mark_by_id(ms: Marks.MarksState, id: int) -> Marks.Mark:
	for m in ms.marks:
		if m.id == id:
			return m
	return null

## A mark as the events and the snapshot carry it.
static func mark_plain(m: Marks.Mark) -> Dictionary:
	return {"id": m.id, "x": m.x, "z": m.z, "level": m.level, "dir": m.dir, "player": m.player, "placedAt": m.placed_at}

## The true facts a note may use (sim/notes.gd's dictionary), as they stand this tick.
static func _note_facts(s: RunState, players: Array[RunPlayer], a: AnnexFloor) -> Dictionary:
	var names: Array = []
	var on_floor: Array[RunPlayer] = []
	var standing: Array[RunPlayer] = []
	for p in players:
		if p.status == &"leftBehind":
			continue
		names.append(name_of(s, p.id))
		if p.status == &"ok":
			standing.append(p)
			if not p.aboard:
				on_floor.append(p)
	var alone: Array = []
	var close: Array = []
	var furthest := ""
	var far := 0.0
	var cs := float(s.plan.cell_size)
	var lx := (s.plan.landing.x + 0.5) * cs
	var lz := (s.plan.landing.y + 0.5) * cs
	for i in on_floor.size():
		var p := on_floor[i]
		var near := false
		for q in standing:
			if q != p and q.body.level == p.body.level and M.hypot2(q.body.x - p.body.x, q.body.z - p.body.z) < ALONE_DISTANCE:
				near = true
				break
		if not near:
			alone.append(name_of(s, p.id))
		for j in range(i + 1, on_floor.size()):
			var q := on_floor[j]
			if q.body.level == p.body.level and M.hypot2(q.body.x - p.body.x, q.body.z - p.body.z) < CLOSE_DISTANCE:
				close.append([name_of(s, p.id), name_of(s, q.id)])
		var d := M.hypot2(p.body.x - lx, p.body.z - lz)
		if d > far + EPS:
			far = d
			furthest = name_of(s, p.id)
	var sprints := {}
	for id: String in _sorted_keys(a.sprints):
		if int(a.sprints[id]) > 0:
			sprints[name_of(s, id)] = int(a.sprints[id])
	var notes_for := {}
	for n: String in names:
		notes_for[n] = int(a.named.get(n, 0)) + 1
	var facts := {"names": names, "alone": alone, "close_pairs": close, "sprints": sprints, "notes_for": notes_for,
		"marks_used": a.marks.pad_size - a.marks.pad, "marks_cap": a.marks.pad_size}
	if furthest != "":
		facts["furthest"] = furthest
	return facts

## Posts one note for `trigger` at `spot` ([x, z, yaw] on `level`), if the floor's cap and the facts allow.
static func _post_note(s: RunState, players: Array[RunPlayer], a: AnnexFloor, trigger: String, extra: Dictionary, level: int, spot: PackedFloat64Array, t: float, events: Array[Dictionary]) -> void:
	var facts := _note_facts(s, players, a)
	facts.merge(extra, true)
	var r := Notes.post(s.seed, s.depth, trigger, facts, a.notes_state)
	if not r["ok"]:
		return
	a.notes_state = r["state"]
	s.note_seq += 1
	var note := {"id": s.note_seq, "n": int(r["state"]["count"]), "trigger": trigger, "template": int(r["id"]), "text": String(r["text"]),
		"x": spot[0], "z": spot[1], "level": level, "yaw": spot[2], "t": _mrad(t)}
	a.notes.append(note)
	for n: Variant in facts["names"]:
		if String(r["text"]).contains(String(n)):
			a.named[n] = int(a.named.get(n, 0)) + 1
	var e := note.duplicate()
	e["type"] = "note"
	events.append(e)

## One tick of the Annex: the marks (finishing, peeling, starting), then the notes (the triggers in this
## tick's `events`, the lobby note, the Temp's queue). Updates `s.annex` and appends the events.
static func _step_annex(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, dt: float, events: Array[Dictionary]) -> void:
	if s.annex == null:
		return
	var a := s.annex.copy()
	s.annex = a
	var riding := s.phase == &"riding"

	# The notes' triggers, from what happened this tick (before any mark event is added).
	var lobby := false
	for e in events:
		match str(e["type"]):
			"doorsOpened":
				lobby = lobby or str(e["reason"]) == "arrival"
			"startedHunting":
				a.queue.append({"trigger": "wake", "facts": {}})
			"caught":
				a.queue.append({"trigger": "catch", "facts": {"caught": name_of(s, str(e["playerId"]))}})
			"tapeDropped":
				a.queue.append({"trigger": "tape", "facts": {"tape_dropper": name_of(s, str(e["playerId"]))}})
			"quotaMet":
				if str(e["top"]) != "":
					a.queue.append({"trigger": "quota", "facts": {"quota_top": name_of(s, str(e["top"]))}})
			"called":
				a.queue.append({"trigger": "lift", "facts": {"lift_caller": name_of(s, str(e["playerId"]))}})
			"healed":
				a.queue.append({"trigger": "heal", "facts": {"healed": name_of(s, str(e["playerId"])), "healer": name_of(s, str(e["by"]))}})
			"chaseStarted":
				# Lonely: where it stood as the chase began, naming who is alone (at most once per player per
				# NOTE_HUNT_EVERY seconds).
				var id := str(e["playerId"])
				if not a.chase_noted.has(id) or t - float(a.chase_noted[id]) >= NOTE_HUNT_EVERY - EPS:
					a.chase_noted[id] = t
					var at: Move.Body = e["at"]
					a.queue.append({"trigger": "chase", "facts": {"alone": [name_of(s, id)]}, "level": at.level,
						"spot": note_spot(s.plan, at.level, at.x, at.z, float(e["yaw"]))})
			"relocated":
				# Lonely: where it left from, naming who it has gone to.
				if resident_of(s).trait_name == &"lonely":
					var from: Move.Body = e["from"]
					a.queue.append({"trigger": "relocate", "facts": {"gone_to": name_of(s, str(e["near"]))}, "level": from.level,
						"spot": note_spot(s.plan, from.level, from.x, from.z, s.orderly.yaw)})
	if not riding and (s.orderly.mode == &"hunting" or s.orderly.mode == &"windUp"):
		a.hunt_clock += dt
		while a.hunt_clock >= NOTE_HUNT_EVERY - EPS:
			a.hunt_clock -= NOTE_HUNT_EVERY
			a.queue.append({"trigger": "hunt", "facts": {}})

	# Sprints this floor (a fact for the notes): a sprint starts when the gait becomes sprint.
	for p in players:
		if not _is_active(p, input_of):
			a.sprinting.erase(p.id)
			continue
		var sprint: bool = (input_of[p.id] as PlayerInput).gait == &"sprint"
		if sprint and not bool(a.sprinting.get(p.id, false)):
			a.sprints[p.id] = int(a.sprints.get(p.id, 0)) + 1
		a.sprinting[p.id] = sprint

	# The marks: placings due, then peels, then new placings.
	var ms := a.marks
	for pend: Marks.Pending in ms.pending.duplicate():
		var p := _player_in(players, pend.player)
		if p == null or not _is_active(p, input_of):
			ms = Marks.cancel_place(ms, pend.player)
			events.append({"type": "markRefused", "t": t, "playerId": pend.player, "reason": "gone"})
			continue
		var fr := Marks.finish_place(ms, pend.player, p.status, (input_of[p.id] as PlayerInput).gait, p.aboard, t)
		if fr.ok:
			ms = fr.state
			events.append({"type": "markPlaced", "t": t, "playerId": pend.player, "mark": mark_plain(fr.mark), "pad": ms.pad, "radius": fr.noise.radius})
		elif fr.reason != &"too_early":
			ms = Marks.cancel_place(ms, pend.player)
			events.append({"type": "markRefused", "t": t, "playerId": pend.player, "reason": String(fr.reason)})
	for p in players:
		if not _is_active(p, input_of):
			continue
		var inp: PlayerInput = input_of[p.id]
		if inp.peel >= 0 and s.shop and (s.shop_state as Shop.ShopState).own_marks.has(inp.peel) and _mark_by_id(ms, inp.peel) != null:
			# A bought marker's mark (S2): peeled, it goes; it never goes onto the crew's pad.
			var om := _mark_by_id(ms, inp.peel)
			if om.level == p.body.level and M.hypot2(om.x - p.body.x, om.z - p.body.z) <= MARK_PEEL_REACH + EPS and p.status == &"ok":
				ms = ms.copy()
				ms.marks.erase(om)
				events.append({"type": "markPeeled", "t": t, "playerId": p.id, "id": om.id, "owner": om.player, "pad": ms.pad, "own": true})
			else:
				events.append({"type": "markRefused", "t": t, "playerId": p.id, "reason": "far", "peel": inp.peel})
		elif inp.peel >= 0:
			var m := _mark_by_id(ms, inp.peel)
			var why := ""
			if m == null:
				why = "no_such_mark"
			elif m.level != p.body.level or M.hypot2(m.x - p.body.x, m.z - p.body.z) > MARK_PEEL_REACH + EPS:
				why = "far"
			else:
				var pr := Marks.peel(ms, inp.peel, p.id, p.status)
				if pr.ok:
					ms = pr.state
					events.append({"type": "markPeeled", "t": t, "playerId": p.id, "id": pr.mark.id, "owner": pr.mark.player, "pad": ms.pad})
				else:
					why = String(pr.reason)
			if why != "":
				events.append({"type": "markRefused", "t": t, "playerId": p.id, "reason": why, "peel": inp.peel})
		if inp.mark:
			var at := Move.Body.make(_cm(p.body.x), _cm(p.body.z), p.body.level, p.body.y)
			var br := Marks.begin_place(ms, p.id, at, inp.yaw, p.status, inp.gait, p.aboard, t)
			if br.ok:
				ms = br.state
				events.append({"type": "markStart", "t": t, "playerId": p.id, "x": at.x, "z": at.z, "level": at.level, "dir": Marks.snap_dir(inp.yaw)})
			else:
				events.append({"type": "markRefused", "t": t, "playerId": p.id, "reason": String(br.reason)})
	a.marks = ms

	# The notes: the lobby's at once, as the doors open; the rest when the Temp is free to post them.
	if lobby and not a.lobby_done:
		a.lobby_done = true
		var car := s.car
		_post_note(s, players, a, "lobby", {}, car.level,
			note_spot(s.plan, car.level, car.door_x - car.in_x, car.door_z - car.in_z, Entity.yaw_toward(-car.in_x, -car.in_z)), t, events)
	var room := Notes.cap_per_floor() - int(a.notes_state.get("count", 0))
	if a.queue.size() > room:
		a.queue.resize(maxi(0, room))
	if not riding and not a.queue.is_empty() and not s.orderly.held:
		var job: Dictionary = a.queue.pop_front()
		var o := s.orderly
		if job.has("spot"):
			# A note that goes where something happened (Lonely's two), not where it stands now.
			_post_note(s, players, a, str(job["trigger"]), job["facts"], int(job["level"]), job["spot"], t, events)
		else:
			_post_note(s, players, a, str(job["trigger"]), job["facts"], o.body.level, note_spot(s.plan, o.body.level, o.body.x, o.body.z, o.yaw), t, events)

# ---------------------------------------------------------------------------------------------
# Down first, then out (see the header).

## Where a downed player gets to this tick: toward `want`, at most CRAWL_SPEED * dt, with the walls and the car.
static func _crawl(prev: RunState, from: Move.Body, want: Move.Body, dt: float) -> Move.Body:
	var dx := want.x - from.x
	var dz := want.z - from.z
	var d := M.hypot2(dx, dz)
	if d <= 1e-9:
		return from
	var most := CRAWL_SPEED * dt
	if d > most:
		dx *= most / d
		dz *= most / d
	return move_in_run(prev, from, dx, dz, CRAWL_RADIUS)

## Player `k` goes down where they are, now ("downed").
static func _go_down(s: RunState, players: Array[RunPlayer], k: int, t: float, by: StringName, events: Array[Dictionary]) -> void:
	var np := players[k].copy()
	np.status = &"down"
	np.side = null
	players[k] = np
	var d := Downed.new()
	d.id = np.id
	d.at = t
	d.until = t + Settings.f(s.tuning, &"down.time", DOWN_TIME)
	d.by = by
	var down := s.down.duplicate()
	down[np.id] = d
	s.down = down
	events.append({"type": "downed", "t": t, "playerId": np.id, "until": d.until, "by": String(by), "at": np.body})

## Whether player `id` may heal someone lying at `at` this tick: on their feet, F held, feet within
## HEAL_REACH on the same level. Their distance, or -1 when they may not.
static func _heal_reach(players: Array[RunPlayer], input_of: Dictionary, id: String, at: Move.Body) -> float:
	var h := _player_in(players, id)
	if h == null or not _is_active(h, input_of) or not (input_of[id] as PlayerInput).use or h.body.level != at.level:
		return -1.0
	var d := M.hypot2(h.body.x - at.x, h.body.z - at.z)
	return d if d <= HEAL_REACH + EPS else -1.0

## One tick of the downed: who holds F beside each, the heals that finish, and those whose time is up.
## Updates `s` (down, spots, the resident, the Playroom's seek) and `players`; returns who went out.
static func _step_downs(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, dt: float, events: Array[Dictionary]) -> Array[String]:
	var down := s.down.duplicate()
	var outs: Array[String] = []
	var busy := {}
	# Holds already going on keep their healer first (a healer heals one at a time).
	for k in players.size():
		var d: Downed = down.get(players[k].id)
		if d != null and d.healer != "" and _heal_reach(players, input_of, d.healer, players[k].body) >= 0.0:
			busy[d.healer] = players[k].id
	for k in players.size():
		var p := players[k]
		var d: Downed = down.get(p.id)
		if d == null:
			continue
		if p.status != &"down":
			down.erase(p.id)
			continue
		var healer := ""
		if d.healer != "" and busy.get(d.healer, "") == p.id:
			healer = d.healer
		else:
			var best := INF
			for q in players:
				if q.id == p.id or busy.has(q.id):
					continue
				var r := _heal_reach(players, input_of, q.id, p.body)
				if r >= 0.0 and r < best - EPS:
					best = r
					healer = q.id
			if healer != "":
				busy[healer] = p.id
		var nd := d
		if healer != d.healer:
			nd = d.copy()
			if d.healer != "":
				events.append({"type": "healStop", "t": t, "playerId": d.healer, "target": p.id})
			nd.healer = healer
			nd.heal_from = t - dt if healer != "" else -1.0
			nd.heal_len = Settings.f(s.tuning, &"heal.time", HEAL_TIME)
			if healer != "":
				events.append({"type": "healStart", "t": t, "playerId": healer, "target": p.id, "from": nd.heal_from, "done": nd.heal_from + nd.heal_len})
		if healer != "" and t - nd.heal_from >= nd.heal_len - EPS:
			# Healed: back on their feet where they lie.
			down.erase(p.id)
			var np := p.copy()
			np.status = &"ok"
			np.side = null
			players[k] = np
			events.append({"type": "healed", "t": t, "playerId": p.id, "by": healer, "at": np.body})
			if s.orderly.mode == &"bending" and str(s.orderly.bend_target) == p.id:
				s.orderly = Entity.stand_off(s.orderly, Settings.f(s.tuning, &"heal.quiet", HEAL_QUIET))
			_seek_heal(s, np)
			continue
		if t >= nd.until - EPS:
			# Out: the tape drops where they lie, and a red spot is left there.
			down.erase(p.id)
			var np := p.copy()
			np.status = &"out"
			np.side = null
			players[k] = np
			outs.append(p.id)
			var b := np.body
			var spot := {"playerId": p.id, "x": _cm(b.x), "z": _cm(b.z), "level": b.level, "y": _cm(b.y), "t": _mrad(t)}
			var spots: Array[Dictionary] = s.spots.duplicate()
			spots.append(spot)
			s.spots = spots
			events.append({"type": "out", "t": t, "playerId": p.id, "at": b, "spot": spot})
			if s.orderly.mode == &"bending" and str(s.orderly.bend_target) == p.id:
				s.orderly = Entity.stand_off(s.orderly, 0.0)
			if s.seek != null:
				s.seek_drops.append(p.id)
			continue
		down[p.id] = nd
	s.down = down
	return outs

## The Playroom: a healed player is back in the seek on their feet, with HEAL_HEALTH, where they lie.
static func _seek_heal(s: RunState, p: RunPlayer) -> void:
	if s.seek == null:
		return
	var ss: Seek.SeekState = s.seek
	var sp := Seek.player_of(ss, p.id)
	if sp == null or sp.status != &"down":
		return
	var ns := ss.copy()
	var list: Array[Seek.SeekPlayer] = []
	for q in ss.players:
		if q.id != p.id:
			list.append(q)
			continue
		var nq := q.copy()
		nq.status = &"ok"
		nq.phase = &"out"
		nq.hide = -1
		nq.peeking = false
		nq.health = Settings.f(s.tuning, &"heal.health", HEAL_HEALTH)
		nq.body = p.body
		nq.last = p.body
		list.append(nq)
	ns.players = list
	s.seek = ns

## The car leaves without the downed: they are out ("out", no spot: the floor is behind the crew).
static func _leave_downs(s: RunState, players: Array[RunPlayer], t: float, events: Array[Dictionary]) -> void:
	if s.down.is_empty():
		return
	for k in players.size():
		var p := players[k]
		if p.status != &"down":
			continue
		var np := p.copy()
		np.status = &"out"
		np.side = null
		players[k] = np
		events.append({"type": "out", "t": t, "playerId": p.id, "at": p.body, "spot": null})
	s.down = {}

## A new floor: nobody down, no red spots.
static func _new_down_floor(s: RunState) -> void:
	if not s.down.is_empty():
		s.down = {}
	if not s.spots.is_empty():
		s.spots = []

static func _step_once(prev: RunState, inputs: Array[PlayerInput], dt: float) -> RunStep:
	var res := RunStep.new()
	if prev.phase == &"ended":
		var ended := prev.copy()
		ended.t = prev.t + dt
		res.state = ended
		return res
	var t := prev.t + dt
	var s := prev.copy()
	s.t = t
	res.state = s
	var events := res.events
	var car := s.car

	# Each player's input this tick; players without one stay where they were, inactive.
	var input_of := {}
	for inp in inputs:
		input_of[inp.id] = inp

	var players: Array[RunPlayer] = []
	for p in prev.players:
		var np := p.copy()
		var given: PlayerInput = input_of.get(p.id)
		if given != null and p.status == &"down" and prev.down.has(p.id):
			# Down: they crawl, no faster than CRAWL_SPEED toward where they say they are.
			np.body = _crawl(prev, p.body, given.body, dt)
		else:
			np.body = given.body if given != null else p.body
		np.aboard = in_car(car, np.body)
		players.append(np)
	_sync_seek(s)
	_sync_hiding(s)
	_sync_annex(s)
	_sync_garden(s)
	# Who called the car on the Playroom this tick (it starts the last count).
	var seek_call_by := ""
	# The floor quota for the crew as it is: set while the car arrives (so a player admitted at the stop
	# counts), then it can only shrink (a player who leaves the game), never grow.
	if s.quota and not s.orientation and not at_home(s):
		var want := floor_quota(s.depth, quota_crew(players))
		s.floor_needed = want if (s.phase == &"arriving" or s.floor_needed <= 0) else mini(s.floor_needed, want)

	# ---- 1. Run rules.
	match s.phase:
		&"arriving":
			s.timer -= dt
			if s.timer <= EPS:
				s.phase = &"unloading"
				s.timer = UNLOAD_TIME
				s.empty_for = 0.0
				events.append({"type": "doorsOpened", "t": t, "depth": s.depth, "reason": "arrival"})
		&"unloading":
			# The car waits (see the header): no clock, only the car being empty closes the doors.
			if not s.car_waits:
				s.timer -= dt
			s.empty_for = s.empty_for + dt if _active_aboard(players, input_of).is_empty() else 0.0
			if s.empty_for >= UNLOAD_EMPTY_CLOSE - EPS or (not s.car_waits and s.timer <= EPS):
				var pushed_out := {}
				var k := 0
				for i in players.size():
					var p := players[i]
					if not p.aboard:
						continue
					var body := _landing_slot(car, k)
					k += 1
					pushed_out[p.id] = body
					var np := p.copy()
					np.body = body
					np.aboard = false
					players[i] = np
				events.append({"type": "doorsClosed", "t": t, "aboard": [], "pushedOut": pushed_out})
				if at_home(s):
					# Home: the car stays shut until the morning, and nobody can call it.
					s.phase = &"night"
				else:
					s.phase = &"away"
					events.append({"type": "carLeft", "t": t, "reason": "unloaded"})
		&"away":
			var caller: RunPlayer = null
			for p in players:
				if _is_active(p, input_of) and not p.aboard and _inp(p, input_of).call \
					and M.hypot2(p.body.x - car.door_x, p.body.z - car.door_z) <= CALL_REACH + EPS and p.body.level == car.level:
					caller = p
					break
			if caller != null and not quota_reached(s):
				# The floor quota (C9): the button does nothing until the crew has recorded enough here.
				events.append({"type": "callRefused", "t": t, "playerId": caller.id, "earned": floori(s.floor_earned), "needed": s.floor_needed})
				caller = null
			if caller != null and s.seek != null and not (s.seek as Seek.SeekState).done:
				# The Playroom: the call starts the last count; the car comes when it ends (see the header).
				s.calls += 1
				s.call = null
				s.blink = null
				s.lure = false
				s.phase = &"coming"
				s.seek_call_at = t
				seek_call_by = caller.id
				events.append({"type": "called", "t": t, "playerId": caller.id, "floorsAway": 0, "at": caller.body, "last": true})
			elif caller != null:
				var index := s.calls
				var plan := CallPlan.new() if s.orientation else call_plan(s.seed, index, s.last_floors, s.depth, s.long_dark, s.tuning)
				if s.orientation:
					plan.floors = 1
					plan.delay = 0.5
					plan.floor_time = 2.5
					plan.wait = plan.delay + plan.floor_time
				s.calls = index + 1
				s.last_floors = plan.floors
				var c := CallState.new()
				c.index = index
				c.at = t
				c.plan = plan
				c.floors_away = plan.floors
				c.next_at = t + plan.delay + plan.floor_time
				s.call = c
				s.phase = &"coming"
				s.lure = not s.orientation
				# The call is loud. If the Orderly was still standing where the floor began, it wakes now.
				if not s.orientation and s.orderly.mode == &"waiting" and (resident_of(s).stillness or resident_of(s).trait_name == &"lonely"):
					var o := s.orderly.copy()
					o.mode = &"hunting"
					o.replan_in = 0.0
					s.orderly = o
					events.append({"type": "startedHunting", "t": t})
				s.blink = _blink_of(s.call, 0)
				events.append({"type": "called", "t": t, "playerId": caller.id, "floorsAway": plan.floors, "at": caller.body})
				events.append({"type": "indicator", "t": t, "floorsAway": plan.floors, "floor": s.depth - plan.floors})
		&"coming":
			var c: CallState = s.call
			if c != null:
				# The indicator, floor by floor; the false stop one floor above.
				for _guard in 64:
					if c.stop_until != null:
						var stop: float = c.stop_until
						if not c.stop_doors_opened and t >= stop - c.plan.extra + FALSE_STOP_DOORS_OPEN_AT - EPS:
							c = c.copy()
							c.stop_doors_opened = true
							events.append({"type": "falseStopDoors", "t": t, "open": true})
						if not c.stop_doors_closed and t >= stop - FALSE_STOP_DOORS_CLOSE_BEFORE - EPS:
							c = c.copy()
							c.stop_doors_closed = true
							events.append({"type": "falseStopDoors", "t": t, "open": false})
						if t < stop - EPS:
							break
						c = c.copy()
						c.next_at = stop + c.plan.floor_time
						c.stop_until = null
						continue
					if t < c.next_at - EPS:
						break
					var floors_away := c.floors_away - 1
					events.append({"type": "indicator", "t": t, "floorsAway": floors_away, "floor": s.depth - floors_away})
					if floors_away == 1 and c.plan.false_stop:
						c = c.copy()
						c.floors_away = floors_away
						c.stop_until = c.next_at + c.plan.extra
						events.append({"type": "falseStop", "t": t, "extra": c.plan.extra})
						continue
					c = c.copy()
					c.floors_away = floors_away
					c.next_at = c.next_at + c.plan.floor_time
					if floors_away <= 0:
						break
				s.call = c
				if c.floors_away <= 0:
					s.phase = &"boarding"
					s.lure = false
					s.bell_left = board_time(s)
					s.hold_left = hold_limit(s)
					s.held = false
					events.append({"type": "carArrived", "t": t, "wait": t - c.at})
					events.append({"type": "doorsOpened", "t": t, "depth": s.depth, "reason": "boarding"})
					s.call = null
		&"boarding":
			var aboard := _active_aboard(players, input_of)
			if s.orientation:
				# The training car waits until all active crew have picked BANK.
				var waiting := aboard.is_empty() or players.any(func(p: RunPlayer) -> bool:
					if p.status != &"ok":
						return false
					if not _is_active(p, input_of):
						return s.orientation_resume != null
					return car_side(car, p.body) != &"bank")
				s.bell_left = board_time(s) if waiting else s.bell_left - dt
			else:
				var any_hold := false
				for p in aboard:
					if _inp(p, input_of).hold_doors:
						any_hold = true
						break
				var holding := s.hold_left > EPS and any_hold
				if holding != s.held:
					s.held = holding
					events.append({"type": "holdChanged", "t": t, "held": holding, "holdLeft": s.hold_left})
				if holding:
					s.hold_left = maxf(0.0, s.hold_left - dt)
					if s.hold_left <= EPS:
						s.held = false
						events.append({"type": "holdChanged", "t": t, "held": false, "holdLeft": s.hold_left})
				else:
					s.bell_left -= dt
		&"riding":
			s.timer -= dt
	_step_blink(s, t, events)

	# Votes: the half of the car each active player stands on, while boarding and before the bell.
	if s.phase == &"boarding":
		for i in players.size():
			var p := players[i]
			var side: Variant = car_side(car, p.body) if _is_active(p, input_of) else null
			if side != p.side:
				events.append({"type": "voteChanged", "t": t, "playerId": p.id, "side": side})
			var np := p.copy()
			np.side = side
			players[i] = np

	# The bell: count, close the doors, and go (or not).
	var departing := &""
	if s.phase == &"boarding" and s.bell_left <= EPS:
		var aboard := _active_aboard(players, input_of)
		var bank := 0
		var down := 0
		for p in aboard:
			if p.side == &"bank":
				bank += 1
			elif p.side == &"down":
				down += 1
		var outcome := "empty" if aboard.is_empty() else ("bank" if bank > down else "ride")
		# The day quota's lock (FD2): BANK won but today's quota is not met. The vote is refused and the car
		# rides down exactly as if DOWN had won.
		var refused := outcome == "bank" and day_locked(s)
		if refused:
			outcome = "ride"
			events.append({"type": "bell", "t": t, "bank": bank, "down": down, "outcome": outcome, "refused": true})
			events.append({"type": "bankRefused", "t": t, "bank": bank, "down": down, "day": s.day_state.day,
				"earned": floori(s.day_earned), "quota": day_quota_now(s)})
		else:
			events.append({"type": "bell", "t": t, "bank": bank, "down": down, "outcome": outcome})
		var ids: Array = []
		for p in aboard:
			ids.append(p.id)
		events.append({"type": "doorsClosed", "t": t, "aboard": ids, "pushedOut": {}})
		s.held = false
		if outcome == "empty":
			s.phase = &"away"
			events.append({"type": "carLeft", "t": t, "reason": "empty"})
		else:
			departing = StringName(outcome)

	if departing == &"bank":
		var aboard_ids: Array[String] = []
		for p in _active_aboard(players, input_of):
			aboard_ids.append(p.id)
		_bank(s, players, aboard_ids, t, events)
		return res

	if departing == &"ride":
		var aboard_ids := {}
		for p in _active_aboard(players, input_of):
			aboard_ids[p.id] = true
		# Everyone not aboard is lost for this floor, with what they hold; so is everything on the floor.
		var next_tape := s.crew.next_tape
		var members: Array[Instr.CrewMember] = []
		for m in s.crew.members:
			if aboard_ids.has(m.id):
				members.append(m)
				continue
			var lost := _held_tapes(m)
			var lost_ids: Array = []
			for tp in lost:
				lost_ids.append(tp.id)
			events.append({"type": "leftBehind", "t": t, "playerId": m.id, "lostTapes": lost_ids, "lostValue": TapeLib.tape_value(lost)})
			var nm := m.copy()
			nm.tape = TapeLib.empty_tape("tape-%d" % next_tape, m.id)
			next_tape += 1
			nm.carrying = []
			nm.instrument = m.instrument.copy()
			nm.instrument.current = null
			nm.instrument.raised = false
			members.append(nm)
		if not s.crew.floor.is_empty():
			var lost: Array[TapeLib.Tape] = []
			var lost_ids: Array = []
			for f in s.crew.floor:
				lost.append(f.tape)
				lost_ids.append(f.tape.id)
			events.append({"type": "floorTapesLost", "t": t, "tapes": lost_ids, "lostValue": TapeLib.tape_value(lost)})
		var nc := s.crew.copy()
		nc.members = members
		nc.floor = []
		nc.next_tape = next_tape
		s.crew = nc
		_leave_downs(s, players, t, events)
		_leave_out(s, players, aboard_ids)
		for i in players.size():
			var p := players[i]
			if aboard_ids.has(p.id):
				continue
			var np := p.copy()
			np.status = p.status if (p.status == &"caught" or p.status == &"out") else &"leftBehind"
			np.side = null
			players[i] = np
		s.phase = &"riding"
		s.timer = Settings.f(s.tuning, &"lift.ride", RIDE_TIME)
		s.blink = null
		s.lure = false
		events.append({"type": "carLeft", "t": t, "reason": "ride"})

	# ---- Findables (FD9, see the header): searches, before the resident.
	if s.findables:
		_step_findables(s, players, input_of, t, events)
	if s.lamp:
		_step_lamps(s, players, input_of, t, dt, events)
	var flare_users := _step_flares(s, players, input_of, t, events) if s.flare else {}

	# ---- 2. The Orderly (not while riding: that floor is behind the crew).
	var entity_ticks: Array[Instr.EntityTick] = []
	var who := resident_of(s)
	var home := at_home(s)
	if home:
		pass  # The prison has no resident: nothing hunts there.
	elif s.orientation:
		if s.phase != &"ended" and s.phase != &"riding":
			entity_ticks = [_step_orientation(s, players, input_of, dt, events)]
	elif s.phase != &"riding" and s.seek != null:
		# The Playroom: the count, the search, hiding, health (sim/seek.gd; see the header).
		entity_ticks = [_step_seek(s, players, input_of, seek_call_by, prev.t, t, dt, events)]
	elif s.phase != &"riding" and s.garden != null:
		# The Arboretum's Groundskeeper (sim/hearing.gd; see the header), after the floor's hides.
		var ev_from := events.size()
		_step_hiding(s, players, input_of, prev.t, dt, events)
		entity_ticks = [_step_garden(s, players, input_of, prev.t, t, dt, events, ev_from)]
	elif s.phase != &"riding" and who.trait_name == &"lonely":
		# The Temp's own mechanic (sim/lonely.gd; see the header).
		entity_ticks = [_step_lonely(s, players, input_of, t, dt, events)]
	elif s.phase != &"riding" and not who.stillness:
		# A resident that is not a Stillness one, with its rules off (seek_off: the resident parked): it
		# stands where it is and takes nobody. No events.
		s.lure = false
		var none: Array[Dictionary] = []
		entity_ticks = [Instr.EntityTick.make(s.entity_id, who.trait_name, s.orderly, s.orderly, none)]
	elif s.phase != &"riding":
		# Hiding (sim/hiding.gd), before the resident: who is in a hide, peeking, or has given it a reason.
		_step_hiding(s, players, input_of, prev.t, dt, events)
		var blind := blinking(s)
		var open := doors_open(s)
		var views: Array[Entity.PlayerView] = []
		for p in players:
			var i := _inp(p, input_of)
			var flared := flare_blinded(s, p.id, t)
			if not _is_active(p, input_of):
				views.append(_view_of(i, false, false))
			elif p.aboard:
				# Never huntable inside the car. With the doors open and the lights on, they still watch the floor.
				var w := _threshold_view(car, i)
				var just_w: Array[Entity.PlayerView] = [w]
				if open and not blind and not i.blind and not flared and Entity.seen_by(s.plan, s.orderly.body, just_w, Entity.kind_of(s.orderly)) != null:
					views.append(w)
				else:
					views.append(_view_of(i, false, false))
			else:
				var hv := _hidden_view(s, i, blind or i.blind or flared)
				# A searcher's eyes are in the drawer (findables): huntable, never a watcher.
				# The shop's flashbulb (S2): for its second the player looks from where they stand, even in the dark, as one
				# watcher (the deliberate break counts it twice).
				var flash := s.shop and Shop.flashing(s.shop_state, p.id, t)
				views.append(hv if hv != null else _view_of(i, true, (blind and not flash) or i.blind or flared or searching(s, p.id)))
				if flash and hv == null and Shop.flash_watchers() > 1:
					views.append(_view_of(i, true, false))
		# The call pulls it toward the landing, until it gets there.
		var s2 := float(s.plan.cell_size)
		var lx := (s.plan.landing.x + 0.5) * s2
		var lz := (s.plan.landing.y + 0.5) * s2
		if s.lure and M.hypot2(s.orderly.body.x - lx, s.orderly.body.z - lz) <= LURE_DROP_DISTANCE:
			s.lure = false
		if s.lure:
			views.append(Entity.PlayerView.make(LURE_ID, Move.Body.make(lx, lz, s.plan.landing.level, car.floor_y), 1.6, 0.0, 0.0, 1.0, 1.0, true, true))
		var before := s.orderly
		# In the blackout it runs its prey down: no creeping up on the still (that is for recording it,
		# and nobody can see to time a turn in the dark), at BLACKOUT_HUNT_SPEED.
		var er: Entity.StepResult
		var need := Entity.watch_need(stillness_up_count(players, input_of)) if s.two_watchers else 1
		var resident_solids := _resident_solids(s)
		# Paced (see the header): both Stillness residents hunt at HUNT_SPEED, so both at the paced speeds.
		# Live settings: the host's speeds for this body (_tuned_hunt), else these.
		if flare_stunned(s, t):
			er = Entity.step_entity(s.plan, before, views, dt, 0.0, false, need, resident_solids, true)
		elif blacked_out(s):
			er = Entity.step_entity(s.plan, before, views, dt, _tuned_hunt(s, true, PACED_BLACKOUT_HUNT_SPEED if s.paced else BLACKOUT_HUNT_SPEED), false, need, resident_solids)
		elif s.paced:
			er = Entity.step_entity(s.plan, before, views, dt, _tuned_hunt(s, false, PACED_HUNT_SPEED), true, need, resident_solids)
		else:
			er = Entity.step_entity(s.plan, before, views, dt, _tuned_hunt(s, false, -1.0), true, need, resident_solids)
		var next := er.state
		# Belt and braces: it can never end a tick in (or overlapping) the car.
		if rect_distance(car.rect, next.body.x, next.body.z) < Entity.ORDERLY_RADIUS - 1e-3 and next.body.level == car.level:
			next = next.copy()
			next.body = before.body
			next.moving = false
			next.speed = 0.0
		var o_events: Array[Dictionary] = []
		for e in er.events:
			if not e.has("playerId") or e["playerId"] != LURE_ID:
				o_events.append(e)
		# Down first, then out: a catch puts the player down, and the resident bends over them. Their tape
		# stays with them until they are out (the instrument does not hear this catch).
		var crew_events := o_events
		if s.downs:
			crew_events = []
			for e in o_events:
				if e["type"] == "caught":
					next = Entity.bend_over(next, str(e["playerId"]))
				else:
					crew_events.append(e)
		# Relocation (see the header): it may leave where nobody can see it and arrive where nobody can.
		var moved_on: Array[Dictionary] = []
		if s.relocation and not flare_stunned(s, t):
			next = _relocate(s, next, who.trait_name, players, input_of, t, dt, moved_on)
		s.orderly = next
		for e in o_events:
			events.append(_with_t(e, t))
		events.append_array(moved_on)
		entity_ticks = [Instr.EntityTick.make(s.entity_id, who.trait_name, before, next, crew_events)]
		# Caught out of a hide (its look-in): pulled out onto the hide's front spot first.
		_release_caught(s, players, o_events)
		for e in o_events:
			if e["type"] != "caught":
				continue
			for k in players.size():
				if players[k].id == e["playerId"]:
					if s.downs:
						if players[k].status == &"ok":
							_go_down(s, players, k, t, &"catch", events)
						continue
					var np := players[k].copy()
					np.status = &"caught"
					np.side = null
					players[k] = np

	# ---- Down first, then out (see the header): heals, and the timer running out.
	if s.downs and not s.down.is_empty() and s.phase != &"riding":
		var outs := _step_downs(s, players, input_of, t, dt, events)
		if not outs.is_empty():
			# Out: the tape drops where they lie (the instrument's "caught").
			var dropped: Array[Dictionary] = []
			for id in outs:
				dropped.append({"type": "caught", "t": t, "playerId": id})
			if entity_ticks.is_empty():
				entity_ticks = [Instr.EntityTick.make(s.entity_id, who.trait_name, s.orderly, s.orderly, dropped)]
			else:
				var et0 := entity_ticks[0]
				var evs: Array[Dictionary] = et0.events.duplicate()
				evs.append_array(dropped)
				var et := Instr.EntityTick.make(et0.id, et0.trait_name, et0.prev, et0.next, evs)
				et.acting = et0.acting
				et.holders = et0.holders
				entity_ticks = [et]

	# ---- 3. The crew.
	var crew := s.crew
	for p in players:
		var i: PlayerInput = input_of.get(p.id)
		if i != null and i.raised != null:
			crew = Instr.set_raised(crew, p.id, bool(i.raised) and p.status == &"ok" and not searching(s, p.id))
		elif searching(s, p.id):
			# Searching (findables): the instrument is away.
			crew = Instr.set_raised(crew, p.id, false)
	s.crew = crew
	var crew_players: Array[Instr.CrewPlayer] = []
	for p in players:
		# The car waits (see the header): a player aboard records nothing, so the open car is safe but unpaid.
		crew_players.append(Instr.CrewPlayer.make(p.id, p.body, _is_active(p, input_of) and not (s.car_waits and p.aboard)))
	var out := _crew_tick(s, crew_players, entity_ticks, dt)
	s.crew = out.crew
	for e in out.events:
		events.append(_with_t(e, t))
		# The floor quota counts what was recorded, not what is still held: a tape dropped later counts.
		if s.quota and e["type"] == "readingClosed":
			s.floor_earned += float(e["value"])
			var by := s.floor_by.duplicate()
			by[e["playerId"]] = float(by.get(e["playerId"], 0.0)) + float(e["value"])
			s.floor_by = by
		# The day's earned (FD2): the same, over the whole day.
		if s.day_lock and e["type"] == "readingClosed":
			s.day_earned += float(e["value"])
	for p in players:
		var given: PlayerInput = input_of.get(p.id)
		if given == null or given.pick_up == null or not _is_active(p, input_of):
			continue
		var want: Variant = given.pick_up
		var m := Instr.member(s.crew, p.id)
		var tape_id: Variant = null
		if want is bool and want == true:
			var best := INF
			for f in s.crew.floor:
				var d := Instr.feet_distance(m.body, f.at) if (m != null and m.body != null) else INF
				if d <= Instr.PICKUP_REACH + EPS and d < best:
					best = d
					tape_id = f.tape.id
		elif want is String:
			tape_id = want
		if tape_id == null:
			continue
		var up := Instr.pick_up_tape(s.crew, p.id, tape_id)
		if up.ok:
			s.crew = up.crew
			if up.event != null:
				events.append(_with_t(up.event, t))

	# ---- The four-slot inventory (S1, see the header).
	if s.inventory:
		_step_inventory(s, players, input_of, t, events)
	# ---- The shop and the cabinet (S2, see the header): after the inventory, whose requests they share.
	if s.shop and s.inventory:
		_step_shop(s, players, input_of, t, dt, events, flare_users)

	# ---- The floor quota met: said once per floor, while the crew is still on it.
	if s.quota and not s.quota_met and not at_home(s) and s.phase != &"riding" and s.floor_needed > 0 and quota_reached(s):
		s.quota_met = true
		events.append({"type": "quotaMet", "t": t, "depth": s.depth, "earned": floori(s.floor_earned), "needed": s.floor_needed, "top": quota_top(s)})
	# ---- The day quota met (FD2): said once a day, the tick it becomes true. BANK is open from now on.
	if s.day_lock and not s.day_met and not at_home(s) and not day_locked(s):
		s.day_met = true
		events.append({"type": "dayMet", "t": t, "day": s.day_state.day, "earned": floori(s.day_earned), "quota": day_quota_now(s)})

	# ---- The Annex: the crew's marks and the Temp's notes (see the header).
	_step_annex(s, players, input_of, t, dt, events)
	# ---- The Arboretum: what the Groundskeeper will hear next tick (a heal, a dropped tape).
	if s.garden != null:
		_garden_after(s, events)

	# ---- Arriving home (the day loop).
	if s.phase == &"riding" and s.timer <= EPS and s.orientation_resume != null:
		res.state = _leave_orientation(s, players, t, events)
		return res
	elif s.phase == &"riding" and s.timer <= EPS and s.going_up:
		_arrive_home(s, players, t, events)
	# ---- Bed and the morning (the day loop).
	elif home:
		_step_bed(s, players, input_of, t, dt, events)
		var waking := s.shop and (s.shop_state as Shop.ShopState).wake_until >= 0.0
		if waking and t >= (s.shop_state as Shop.ShopState).wake_until - EPS:
			# The shop (S2): the morning in the cells is over; the car takes the crew down.
			var sh := (s.shop_state as Shop.ShopState).copy()
			sh.wake_until = -1.0
			s.shop_state = sh
			_morning(s, players, t, events)
		elif not waking and s.lights_out_t >= 0.0 and t >= s.lights_out_t + Day.LIGHTS_OUT_SECONDS - EPS:
			if s.shop:
				_wake_in_cells(s, players, t, events)
			else:
				_morning(s, players, t, events)
	# ---- Arriving on the next floor.
	elif s.phase == &"riding" and s.timer <= EPS:
		var depth := s.depth + 1
		var f := _floor_for(s.seed, depth, s.deck, s.garden_search)
		var bodies := {}
		var outside := 0
		for i in players.size():
			var p := players[i]
			var body: Move.Body
			if s.car_waits and s.left_out.has(p.id):
				# Left out today (the car waits): not brought back. They stand on the new landing, out of the run.
				body = _landing_slot(f.car, outside)
				outside += 1
				bodies[p.id] = body
				var lp := p.copy()
				lp.body = body
				lp.status = &"leftBehind"
				lp.aboard = false
				lp.side = null
				players[i] = lp
				continue
			if p.status == &"ok" and in_car(car, p.body):
				var l := car_local(car, p.body.x, p.body.z)
				body = car_body(f.car, l[0], l[1])
			else:
				body = _car_slot(f.car, i)
			bodies[p.id] = body
			var np := p.copy()
			np.body = body
			np.status = &"ok"
			np.aboard = true
			np.side = null
			players[i] = np
		s.depth = depth
		s.plan = f.plan
		s.car = f.car
		s.orderly = _settled_resident(s, f.orderly)
		s.entity_id = f.entity_id
		var nc := s.crew.copy()
		nc.members = []
		for m in s.crew.members:
			var nm := m.copy()
			nm.body = bodies.get(m.id, m.body)
			nm.active = true
			nc.members.append(nm)
		s.crew = nc
		s.phase = &"arriving"
		s.timer = ARRIVE_DOOR_DELAY
		_new_quota_floor(s, players)
		_new_down_floor(s)
		events.append({"type": "rodeDown", "t": t, "depth": depth, "bodies": bodies})

	s.players = players
	_sync_seek(s)
	_sync_hiding(s)
	_sync_annex(s)
	_sync_garden(s)

	# ---- A wipe: nobody left who can call or board.
	var everyone_out := true
	for p in players:
		# A downed player is not out yet: the wipe waits for their ten seconds.
		if p.status == &"ok" or p.status == &"down":
			everyone_out = false
	if s.phase != &"riding" and everyone_out and not at_home(s):
		var no_tapes: Array[TapeLib.Tape] = []
		var summary := _summarize(s, no_tapes, true)
		s.summary = summary
		s.blink = null
		events.append({"type": "wiped", "t": t, "summary": summary})
		if s.days:
			# The day: a wipe is the missed day, nothing banked; the empty car rides up and everyone wakes on a bunk.
			_settle_day(s, t, 0, events, true)
			# The tapes are kept as they are this tick (net/host_rules.gd's soft catch reads them back);
			# they are lost on arrival.
			var nobody: Array[String] = []
			_ride_up(s, players, nobody, false)
		else:
			s.phase = &"ended"
	return res

# ---------------------------------------------------------------------------------------------
# The day loop (days on only; see the header).

## Ward review uses the same instrument, departure, wallet and day records.
static func step_ward(prev: RunState, inputs: Array[PlayerInput], crew_rows: Dictionary, limb: PackedVector3Array,
		phase: StringName, bell_left: float, aboard: Array[String], dt: float, cues: Array[Dictionary]) -> RunStep:
	var out := RunStep.new()
	var s := prev.copy()
	out.state = s
	s.t += dt
	var players: Array[RunPlayer] = []
	var holders: Array[Instr.CrewPlayer] = []
	var by_id := {}
	for inp in inputs:
		by_id[inp.id] = inp
	var caught_events: Array[Dictionary] = []
	var caught := {}
	for cue in cues:
		if cue["type"] == "ward_contact":
			var hit := {"type": "caught", "t": s.t, "playerId": cue.id}
			caught_events.append(hit)
			caught[cue.id] = true
	out.events.append_array(cues)
	out.events.append_array(caught_events)
	for old in prev.players:
		var p := old.copy()
		var row: Dictionary = crew_rows[p.id]
		var pos: Vector3 = row.position
		var given: PlayerInput = by_id.get(p.id)
		p.body = Move.Body.make(pos.x, pos.z, 0, pos.y)
		p.aboard = row.aboard
		if caught.has(p.id):
			p.status = &"caught"
		var active := bool(row.active) and p.status == &"ok" and not p.aboard
		s.crew = Instr.set_raised(s.crew, p.id, active and given != null and bool(given.raised))
		holders.append(Instr.CrewPlayer.make(p.id, p.body, active))
		players.append(p)
	s.players = players
	var entities: Array[Instr.EntityTick] = []
	if not limb.is_empty() or not caught_events.is_empty():
		var resident := Instr.EntityTick.make("rigger-%d" % s.depth, &"rigger", s.orderly, s.orderly, caught_events)
		resident.acting = limb.size() > 1
		resident.limb = limb
		entities.append(resident)
	var reading := _crew_tick(s, holders, entities, dt)
	s.crew = reading.crew
	for event in reading.events:
		out.events.append(_with_t(event, s.t))
		if s.day_lock and event["type"] == "readingClosed":
			s.day_earned += float(event.value)
	if phase != &"departed":
		s.phase = phase
		s.bell_left = bell_left
		return out
	# Ward departure is collection, so only the physically boarded crew can take money home.
	var car_waited := s.car_waits
	s.car_waits = true
	s.left_out = s.left_out.duplicate()
	for p in players:
		if not aboard.has(p.id):
			s.left_out[p.id] = true
			if p.status == &"ok":
				p.status = &"leftBehind"
		else:
			var slot := aboard.find(p.id)
			p.body = car_body(s.car, 1.05 + float(slot / 2) * 0.61, -0.46 if slot % 2 == 0 else 0.46)
	_bank(s, players, aboard, s.t, out.events, aboard.is_empty(), true)
	s.car_waits = car_waited
	return out

static func _bank(s: RunState, players: Array[RunPlayer], aboard_ids: Array[String], t: float, events: Array[Dictionary], wiped := false, ward := false) -> void:
	# The car waits: whoever it leaves on the floor has no share of this bank (see the header).
	var aboard_set := {}
	for id in aboard_ids:
		aboard_set[id] = true
	_leave_out(s, players, aboard_set)
	var crew := s.crew
	for p in players:
		crew = Instr.set_raised(crew, p.id, false)
	var crew_players: Array[Instr.CrewPlayer] = []
	for p in players:
		crew_players.append(Instr.CrewPlayer.make(p.id, p.body, aboard_ids.has(p.id)))
	var flush_state := s.copy()
	flush_state.crew = crew
	var no_entities: Array[Instr.EntityTick] = []
	for _k in 20:
		var out := _crew_tick(flush_state, crew_players, no_entities, 0.1)
		flush_state.crew = out.crew
		for e in out.events:
			events.append(_with_t(e, t))
			# Recorded today: the day's earned counts the readings closed as the car leaves too.
			if s.day_lock and e["type"] == "readingClosed":
				s.day_earned += float(e["value"])
	s.crew = flush_state.crew
	var dep := Instr.leave_floor(s.crew, aboard_ids)
	s.players = players
	var summary := _summarize(s, dep.carried, wiped)
	if ward:
		var tape_ids: Array[String] = []
		for tape in dep.lost:
			tape_ids.append(tape.id)
		events.append({"type": "ward_tapes_lost", "t": t, "tapes": tape_ids, "value": dep.lost_value})
	s.summary = summary
	s.blink = null
	if s.orientation_resume != null:
		_pay_orientation(s, aboard_ids, floori(summary.total), t, events)
		return
	events.append({"type": "banked", "t": t, "summary": summary})
	if s.days:
		# The day: settled on what got home (made, with the lock: a locked BANK never gets here), then the
		# car rides up with whoever is aboard.
		_settle_day(s, t, floori(summary.total), events, wiped)
		_leave_downs(s, players, t, events)
		_ride_up(s, players, aboard_ids, true)
		events.append({"type": "carLeft", "t": t, "reason": "up"})
		return
	s.phase = &"ended"

static func _pay_orientation(s: RunState, aboard: Array[String], total: int, t: float, events: Array[Dictionary]) -> void:
	var resume := s.orientation_resume.copy()
	var shares := Day.split_shares(total, aboard, 1)
	var wallets := s.wallets.duplicate()
	for id: String in shares:
		var wallet: Upgrades.UpgradeState = wallets.get(id)
		wallets[id] = Upgrades.add_credits(wallet if wallet != null else Upgrades.UpgradeState.make(), int(shares[id]))
	resume.wallets = wallets
	s.wallets = wallets
	s.orientation_resume = resume
	s.orientation_paid = total
	s.phase = &"riding"
	s.timer = Orientation.PRELUDE_RIDE_SECONDS
	events.append({"type": "orientationPaid", "t": t, "total": total, "shares": shares})
	events.append({"type": "carLeft", "t": t, "reason": "ride"})

static func _leave_orientation(s: RunState, players: Array[RunPlayer], t: float, events: Array[Dictionary]) -> RunState:
	var resume := s.orientation_resume.copy()
	resume.t = t
	resume.tuning = s.tuning
	resume.orientation_paid = s.orientation_paid
	resume.players = []
	var ids: Array[String] = []
	var bodies := {}
	for player in players:
		if player.status != &"ok":
			continue
		var passenger := player.copy()
		var spot := car_local(s.car, player.body.x, player.body.z)
		passenger.body = car_body(resume.car, spot[0], spot[1])
		passenger.aboard = true
		passenger.side = null
		resume.players.append(passenger)
		ids.append(player.id)
		bodies[player.id] = passenger.body
	resume.crew = Instr.create_crew(ids)
	resume.day_state = Day.morning(resume.day_state, ids.size())
	_new_quota_floor(resume, resume.players)
	events.append({"type": "rodeDown", "t": t, "depth": resume.depth, "bodies": bodies})
	return resume


## Settles today with `banked` whole credits (Day.end_day): wallets paid, any loss rolled, the next day's
## state kept for the morning, the facts kept for the snapshot ("dayEnded"). `wiped`: nobody came back,
## the missed day. With the lock the day's earned opens BANK; without it earned is what was banked (a
## short BANK is a missed day, as before FD1).
static func _settle_day(s: RunState, t: float, banked: int, events: Array[Dictionary], wiped: bool) -> void:
	# The car waits: whoever it left out today is paid nothing today (see the header).
	var crew := day_crew(s)
	var earned := floori(s.day_earned) if s.day_lock else banked
	var r := Day.end_day(s.day_state, banked, earned, crew, s.wallets, DAY_FLOOR_QUOTA, s.seed, wiped, s.quick_fingers)
	s.wallets = r.wallets
	s.day_next = r.state
	var result: Dictionary = r.facts.duplicate(true)
	result["shares"] = r.shares.duplicate()
	# Tomorrow's quota for today's crew (the prison's day board; the morning sizes it for whoever rides down).
	result["next_quota"] = Day.day_quota(r.state, DAY_FLOOR_QUOTA)
	var credits := {}
	for id: String in _sorted_keys(r.wallets):
		credits[id] = (r.wallets[id] as Upgrades.UpgradeState).credits
	result["credits"] = credits
	s.day_result = result
	events.append({"type": "dayEnded", "t": t, "result": result})

static func _sorted_keys(d: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for k: Variant in d.keys():
		out.append(String(k))
	out.sort()
	return out

## The crew as it is, each with a fresh empty tape (numbered on) and a fresh instrument; nothing on the
## floor. What a day's tapes become once they are banked or lost.
static func _fresh_crew(crew: Instr.CrewState) -> Instr.CrewState:
	var c := crew.copy()
	var next_tape := crew.next_tape
	c.members = []
	for m in crew.members:
		var nm := m.copy()
		nm.instrument = Instr.create_instrument()
		nm.tape = TapeLib.empty_tape("tape-%d" % next_tape, m.id)
		next_tape += 1
		nm.carrying = []
		nm.active = true
		c.members.append(nm)
	c.floor = []
	c.next_tape = next_tape
	return c

## Whether any tape with readings is held by a member or lies on the floor.
static func _holds_tapes(crew: Instr.CrewState) -> bool:
	if not crew.floor.is_empty():
		return true
	for m in crew.members:
		if not _held_tapes(m).is_empty():
			return true
	return false

static func with_nightly_reels(s0: RunState) -> RunState:
	var s := s0.copy()
	s.nightly_reels = true
	return s

## The host supplies the connected crew and the votes reported by their latest input.
## Keep a vote until that player leaves this ride. An empty crew cannot skip.
static func with_reel_votes(s: RunState, crew: Array[String], pressed: Array[String]) -> RunState:
	if s.reel_day == 0 or s.reel_skipped:
		return s
	var votes: Array[String] = []
	for id in crew:
		if s.reel_votes.has(id) or pressed.has(id):
			votes.append(id)
	var next := s.copy()
	next.reel_crew = crew.size()
	next.reel_votes = votes
	if votes.size() * 2 > crew.size():
		next.reel_skipped = true
		next.timer = minf(s.timer, maxf(0.0, s.reel_started + RIDE_UP_TIME - s.t))
	return next

## The car leaves for the prison with `aboard`: everyone else stays behind (they wake on their bunks).
## `fresh`: everyone gets a fresh tape now (a bank: what was aboard is banked, the rest is lost).
static func _ride_up(s: RunState, players: Array[RunPlayer], aboard: Array[String], fresh: bool) -> void:
	for i in players.size():
		var p := players[i]
		var np := p.copy()
		np.side = null
		if not aboard.has(p.id) and p.status == &"ok":
			np.status = &"leftBehind"
		players[i] = np
	if fresh:
		s.crew = _fresh_crew(s.crew)
	s.phase = &"riding"
	s.going_up = true
	s.timer = RIDE_UP_TIME
	if s.nightly_reels and NightReels.duration(s.day_state.day) > 0.0:
		s.reel_day = s.day_state.day
		s.reel_started = s.t
		s.reel_crew = players.size()
		s.reel_votes = []
		s.reel_skipped = false
		s.timer = maxf(RIDE_UP_TIME, NightReels.duration(s.reel_day))
	s.blink = null
	s.lure = false
	s.call = null
	s.held = false

## The body of player `id` standing on their own bunk (Day.bunk_of over the run's players).
static func bunk_body(plan: Floor.FloorPlan, crew: Array[String], id: String) -> Move.Body:
	var cell := Day.bunk_of(crew, id)
	return Move.body_at_cell(plan, Floor.Pos.make(0, cell.x, cell.y))

## Whether a body stands on a bunk's cell.
static func at_bunk(plan: Floor.FloorPlan, body: Move.Body) -> bool:
	if body == null or body.level != 0:
		return false
	var c := Move.cell_of(plan, body)
	return Prison.bunk_positions().has(Vector2i(c.x, c.y))

## The car arrives at the prison: depth 0, no resident. Those aboard step out of the car as on any floor;
## everyone else wakes on their own bunk, on their feet. The bedtime count starts empty.
static func _arrive_home(s: RunState, players: Array[RunPlayer], t: float, events: Array[Dictionary]) -> void:
	var old_car := s.car
	var plan := Places.generate(s.seed, 0, s.deck)
	var car := car_geometry(plan)
	var ids: Array[String] = []
	for p in players:
		ids.append(p.id)
	var bodies := {}
	for i in players.size():
		var p := players[i]
		var body: Move.Body
		var aboard := p.status == &"ok" and in_car(old_car, p.body)
		if aboard:
			var l := car_local(old_car, p.body.x, p.body.z)
			body = car_body(car, l[0], l[1])
		else:
			body = bunk_body(plan, ids, p.id)
		bodies[p.id] = body
		var np := p.copy()
		np.body = body
		np.status = &"ok"
		np.aboard = aboard
		np.side = null
		players[i] = np
	s.depth = 0
	s.plan = plan
	s.car = car
	var o := Places.create_resident(plan)
	o.mode = &"dormant"
	o.dormant_left = INF
	s.orderly = o
	s.entity_id = Places.entity_id(plan.place, 0)
	# After a wipe the day's tapes are still held: they are lost now (a bank gave fresh ones as it left).
	var nc := _fresh_crew(s.crew) if _holds_tapes(s.crew) else s.crew.copy()
	var members: Array[Instr.CrewMember] = []
	for m in nc.members:
		var nm := m.copy()
		nm.body = bodies.get(m.id, m.body)
		nm.active = true
		members.append(nm)
	nc.members = members
	s.crew = nc
	s.going_up = false
	s.reel_day = 0
	s.phase = &"arriving"
	s.timer = ARRIVE_DOOR_DELAY
	if not s.left_out.is_empty():
		s.left_out = {}
	s.bed = Day.BedState.make(ids)
	s.bed_hold = {}
	s.use_prev = {}
	s.lights_out_t = -1.0
	_new_quota_floor(s, players)
	_new_down_floor(s)
	events.append({"type": "rodeUp", "t": t, "depth": 0, "day": s.day_state.day, "bodies": bodies})

## Bed, one tick: who leaves the count, who climbs in (F held BED_HOLD seconds on a bunk) or out (a new
## press of F), the count starting, and lights out.
static func _step_bed(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, dt: float, events: Array[Dictionary]) -> void:
	var b := s.bed
	if b == null:
		return
	var before := b
	var hold := s.bed_hold.duplicate()
	var prev := s.use_prev.duplicate()
	for p in players:
		if b.crew.has(p.id) and p.status != &"ok":
			var nb := Day.leave(b, p.id, t)
			if nb != b:
				b = nb
				events.append({"type": "bed", "t": t, "playerId": p.id, "inBed": false, "left": true, "count": Day.count_text(b)})
			hold.erase(p.id)
			prev.erase(p.id)
		elif not b.crew.has(p.id) and p.status == &"ok" and not Day.is_lights_out(b, t):
			# Joined at the prison's stop (the host admits newcomers as the car arrives): in the count too.
			var nb := b.copy()
			nb.crew.append(p.id)
			nb.crew.sort()
			if nb.all_in_at >= 0.0:
				nb.all_in_at = -1.0
			b = nb
	for p in players:
		if not b.crew.has(p.id):
			continue
		var inp: PlayerInput = input_of.get(p.id)
		var use := inp != null and inp.use and p.status == &"ok"
		var was: bool = prev.get(p.id, false)
		prev[p.id] = use
		if b.in_bed.has(p.id):
			if use and not was:
				var nb := Day.climb_out(b, p.id, t)
				if nb != b:
					b = nb
					hold[p.id] = -1.0
					events.append({"type": "bed", "t": t, "playerId": p.id, "inBed": false, "count": Day.count_text(b)})
			continue
		if not use:
			hold.erase(p.id)
			continue
		var h := float(hold.get(p.id, 0.0))
		if h < 0.0:
			continue  # got up with this press: let go of F first
		if not at_bunk(s.plan, p.body):
			hold.erase(p.id)
			continue
		h += dt
		if h >= BED_HOLD - EPS:
			var nb := Day.climb_in(b, p.id, t)
			hold.erase(p.id)
			if nb != b:
				b = nb
				if s.deep_pockets:
					_settle_training(s, p.id, t, events)
				events.append({"type": "bed", "t": t, "playerId": p.id, "inBed": true, "count": Day.count_text(b)})
		else:
			hold[p.id] = h
	if before.count_from < 0.0 and b.count_from >= 0.0:
		events.append({"type": "bedCount", "t": t, "lightsOutAt": Day.lights_out_at(b)})
	s.bed = b
	s.bed_hold = hold
	s.use_prev = prev
	if s.lights_out_t < 0.0 and Day.is_lights_out(b, t):
		s.lights_out_t = t
		if s.deep_pockets:
			for id: String in s.wallets.keys():
				_settle_training(s, id, t, events)
		events.append({"type": "lightsOut", "t": t, "assisted": Day.assisted(b), "morningAt": t + Day.LIGHTS_OUT_SECONDS})

## The next morning: a new day, started as day 1 was (create_run), on the next day's seed.
static func _morning(s: RunState, players: Array[RunPlayer], t: float, events: Array[Dictionary]) -> void:
	var crew_size := s.bed.crew.size() if s.bed != null else players.size()
	s.day_index += 1
	s.seed = day_seed(s.base_seed, s.day_index)
	s.day_state = Day.morning(s.day_next if s.day_next != null else s.day_state, crew_size)
	s.day_next = null
	s.day_result = null
	s.summary = null
	if s.day_lock:
		s.day_earned = 0.0
		s.day_met = false
	if s.findables:
		# Cartons do not go home (findables, see the header).
		s.items = {}
	if s.inventory and not s.shop and Inventory.test_break != "no_clear":
		# Everything carried or left lying is cleared overnight (the inventory, see the header). With the shop that was
		# done as the crew woke in the cells (_wake_in_cells): what they took out of their cabinets goes down with them.
		s.bags = {}
		s.pickups = []
		s.pickups_plan = null
	var f := _floor_for(s.seed, 1, s.deck)
	var bodies := {}
	for i in players.size():
		var p := players[i]
		var np := p.copy()
		np.body = _car_slot(f.car, i)
		np.status = &"ok"
		np.aboard = true
		np.side = null
		players[i] = np
		bodies[p.id] = np.body
	s.depth = 1
	s.plan = f.plan
	s.car = f.car
	s.orderly = _settled_resident(s, f.orderly)
	s.entity_id = f.entity_id
	var nc := _fresh_crew(s.crew)
	for m in nc.members:
		m.body = bodies.get(m.id, m.body)
	s.crew = nc
	s.phase = &"arriving"
	s.timer = ARRIVE_DOOR_DELAY
	s.empty_for = 0.0
	s.calls = 0
	s.last_floors = -1
	s.call = null
	s.blink = null
	s.lure = false
	s.bell_left = 0.0
	s.hold_left = 0.0
	s.held = false
	s.bed = null
	s.bed_hold = {}
	s.use_prev = {}
	s.lights_out_t = -1.0
	if not s.left_out.is_empty():
		s.left_out = {}
	_new_quota_floor(s, players)
	_new_down_floor(s)
	events.append({"type": "newDay", "t": t, "day": s.day_state.day, "dayIndex": s.day_index, "depth": 1, "bodies": bodies})

static func _inp(p: RunPlayer, input_of: Dictionary) -> PlayerInput:
	var given: PlayerInput = input_of.get(p.id)
	if given != null:
		return given
	return PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0)

static func _is_active(p: RunPlayer, input_of: Dictionary) -> bool:
	return p.status == &"ok" and input_of.has(p.id)

## Two-watcher Stillness (sim/entity.gd "Watchers"; T19a): the up players this tick, from which
## Entity.watch_need says how many watchers hold a Stillness resident. Up: on their feet with an input
## (aboard counts while the car is here); never a down, caught, out or left-behind player. A player
## sitting back in a hide is up (they count here) but sees nothing, so is never a watcher.
static func stillness_up_count(players: Array[RunPlayer], input_of: Dictionary) -> int:
	var n := 0
	for p in players:
		if _is_active(p, input_of):
			n += 1
	return n

## Relocation (see the header; sim/relocate.gd): the eyes, every player on their feet or down (caught, out and
## left-behind players see nothing), each with the cell their walking is measured from (the landing for one in
## the car) and whether it may go to them (on their feet, with an input, out of the car).
static func relocation_eyes(s: RunState, players: Array[RunPlayer], input_of: Dictionary) -> Array[Relocate.Eye]:
	var out: Array[Relocate.Eye] = []
	for p in players:
		if p.status != &"ok" and p.status != &"down":
			continue
		var i: PlayerInput = input_of.get(p.id)
		var aboard := in_car(s.car, p.body)
		var c := Move.cell_of(s.plan, p.body)
		var walk: Floor.Pos = s.plan.landing if aboard else (c if Floor.is_walkable(s.plan, c.level, c.x, c.y) else null)
		out.append(Relocate.Eye.make(p.id, p.body, i.eye if i != null else 1.65, walk, _is_active(p, input_of) and not aboard))
	return out

## Whether the run lets the resident relocate this tick: no blink, blackout or their warning, the lift not boarding.
static func relocation_free(s: RunState) -> bool:
	return s.phase != &"boarding" and s.phase != &"riding" and not (s.blink != null and (s.blink.announced or s.blink.ends_at != null))

## One tick of relocation for the resident just stepped (`o`), its "relocated" event added to `events`.
static func _relocate(s: RunState, o: Entity.OrderlyState, trait_name: StringName, players: Array[RunPlayer], input_of: Dictionary, t: float, dt: float, events: Array[Dictionary]) -> Entity.OrderlyState:
	var r := s.car.rect
	var bars := Relocate.barred(s.plan, s.plan.seed, PackedFloat64Array([r.x0, r.z0, r.x1, r.z1]), s.car.level)
	var st := Relocate.step(s.plan, s.seed, s.depth, trait_name, o, relocation_eyes(s, players, input_of), bars, relocation_free(s), t, dt, _resident_solids(s))
	if st.event != null:
		events.append(st.event)
	return st.state

## Lonely (see the header; sim/lonely.gd): the people, every player on their feet with an input (in the car too,
## as company only) and every player down (company only), with their eyes.
static func lonely_people(s: RunState, players: Array[RunPlayer], input_of: Dictionary) -> Array[Lonely.Person]:
	var out: Array[Lonely.Person] = []
	for p in players:
		var i: PlayerInput = input_of.get(p.id)
		if _is_active(p, input_of):
			out.append(Lonely.Person.make(p.id, p.body, i.eye, not in_car(s.car, p.body)))
		elif p.status == &"down":
			out.append(Lonely.Person.make(p.id, p.body, i.eye if i != null else 1.65, false))
	return out

## One tick of the Lonely Temp (see the header): its step, the car, catches (the down rule's bend), relocation,
## and the instrument's tick (recording only the chased).
static func _step_lonely(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, dt: float, events: Array[Dictionary]) -> Instr.EntityTick:
	var car := s.car
	s.lure = false
	var blind := blinking(s)
	var views: Array[Entity.PlayerView] = []
	for p in players:
		var i := _inp(p, input_of)
		views.append(_view_of(i, _is_active(p, input_of) and not p.aboard, blind or i.blind))
	var before := s.orderly
	var er := Lonely.step(s.plan, before, lonely_people(s, players, input_of), views, dt, players.size() <= 1, s.relocation, _tuned_chase(s, players.size() <= 1), _resident_solids(s))
	var next := er.state
	# Belt and braces: it can never end a tick in (or overlapping) the car.
	if rect_distance(car.rect, next.body.x, next.body.z) < Entity.ORDERLY_RADIUS - 1e-3 and next.body.level == car.level:
		next = next.copy()
		next.body = before.body
		next.moving = false
		next.speed = 0.0
	var crew_events: Array[Dictionary] = er.events
	if s.downs:
		crew_events = []
		for e in er.events:
			if e["type"] == "caught":
				next = Entity.bend_over(next, str(e["playerId"]))
			else:
				crew_events.append(e)
	var moved_on: Array[Dictionary] = []
	if s.relocation:
		next = _relocate(s, next, &"lonely", players, input_of, t, dt, moved_on)
	s.orderly = next
	for e in er.events:
		events.append(_with_t(e, t))
	events.append_array(moved_on)
	var et := Instr.EntityTick.make(s.entity_id, &"lonely", before, next, crew_events)
	var who := Lonely.chased(before, next)
	et.acting = who != ""
	et.holders = {who: true} if who != "" else {}
	for e in er.events:
		if e["type"] != "caught":
			continue
		for k in players.size():
			if players[k].id == e["playerId"]:
				if s.downs:
					if players[k].status == &"ok":
						_go_down(s, players, k, t, &"catch", events)
					continue
				var np := players[k].copy()
				np.status = &"caught"
				np.side = null
				players[k] = np
	return et

static func _active_aboard(players: Array[RunPlayer], input_of: Dictionary) -> Array[RunPlayer]:
	var out: Array[RunPlayer] = []
	for p in players:
		if _is_active(p, input_of) and p.aboard:
			out.append(p)
	return out

# ---------------------------------------------------------------------------------------------
# Findables (FD9; see the header).

## Whether this floor has findables in this run.
static func finds_here(s: RunState) -> bool:
	return s.findables and not at_home(s) and s.plan != null and Findables.place_on(s.plan.place, s.garden_search)

## Whether a player is searching now.
static func searching(s: RunState, id: String) -> bool:
	return s.find != null and Findables.searching(s.find as Findables.FindFloor, id)

## The floor's quota as set on arrival, for the fill's credit units: the quota's own number, else what it would be.
static func find_base(s: RunState, players: Array[RunPlayer]) -> int:
	return s.floor_needed if s.quota and s.floor_needed > 0 else floor_quota(s.depth, quota_crew(players))

## Whether a player is in, getting into or getting out of a hide.
static func _in_hide(s: RunState, id: String) -> bool:
	if s.hiding == null:
		return false
	var hp := Hiding.player_of(s.hiding as Hiding.HidingState, id)
	return hp != null and hp.phase != &"out"

## The chance is stamped when this floor's furniture is first filled, once for everyone.
static func badge_search_chance(s: RunState) -> float:
	if not s.badge_search:
		return 0.0
	var first := Settings.i(s.tuning, &"badge.chance", Findables.BADGE_FIRST_CHANCE)
	var step := Settings.i(s.tuning, &"badge.depth_chance", Findables.BADGE_DEPTH_CHANCE)
	return minf(1.0, 0.01 * (first + maxi(0, s.depth - 1) * step))

## One tick of searching (see the header). Updates `s` (find, crew, day_earned, items, the resident woken),
## `players` (rooted bodies) and appends the events.
static func _step_findables(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, events: Array[Dictionary]) -> void:
	if s.find != null and (not finds_here(s) or (s.find as Findables.FindFloor).plan != s.plan):
		s.find = null
	if not finds_here(s) or s.phase == &"riding" or s.phase == &"arriving":
		return
	if s.find == null:
		var day := s.day_state.day if s.days and s.day_state != null else 1
		var ff := Findables.start_floor(s.plan, s.plan.seed, s.depth, find_base(s, players), Findables.trait_for(s.plan.place, s.lonely), day, s.lore_used, s.garden_search, badge_search_chance(s))
		s.find = ff
		if ff.fill.page != "":
			var used := s.lore_used.duplicate()
			used.append(ff.fill.page)
			s.lore_used = used
	var inputs: Array[Findables.SearchInput] = []
	for p in players:
		var i: PlayerInput = input_of.get(p.id)
		var able := i != null and p.status == &"ok" and _is_active(p, input_of) and not p.aboard and not _in_hide(s, p.id) \
			and i.gait != &"sprint" and not i.hide_use
		var search := Findables.SearchInput.make(p.id, p.body, i.yaw if i != null else 0.0, i != null and i.search, i != null and i.search_fast, able)
		if s.quick_fingers and search.held:
			var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
			if wallet != null:
				search.speed += 0.1 * Upgrades.trade_seniority(wallet.owned, "Hands")
				search.silent = wallet.owned.has("quick_fingers")
				if search.silent:
					search.speed *= 2.0
		inputs.append(search)
	var r := Findables.step(s.find as Findables.FindFloor, inputs, t)
	s.find = r.floor
	events.append_array(r.events)
	# A rushed search is loud: a resident still standing where the floor began wakes, as at the call.
	if not r.noisy.is_empty() and s.orderly.mode == &"waiting" and (resident_of(s).stillness or resident_of(s).trait_name == &"lonely"):
		var o := s.orderly.copy()
		o.mode = &"hunting"
		o.replan_in = 0.0
		s.orderly = o
		events.append({"type": "startedHunting", "t": t})
	for row in r.found:
		var by := str(row["by"])
		if str(row["what"]) == "credits":
			_add_found(s, by, int(row["credits"]), int(row["piece"]), t)
		elif s.inventory and str(row["what"]) in ["juice", "badge"]:
			_store_search_item(s, by, int(row["piece"]), str(row["what"]), t, events)
		elif str(row["what"]) == "juice":
			var items := s.items.duplicate()
			var mine: Dictionary = (items.get(by, {}) as Dictionary).duplicate()
			mine[String(Findables.JUICE)] = int(mine.get(String(Findables.JUICE), 0)) + 1
			items[by] = mine
			s.items = items
	# Rooted: a searcher stands where the search began.
	var ff2: Findables.FindFloor = s.find
	for k in players.size():
		var sr: Findables.Search = ff2.searches.get(players[k].id)
		if sr != null:
			var np := players[k].copy()
			np.body = sr.spot
			players[k] = np

## Credits found: a reading of trait "found" on the finder's own tape (it rides with the tape), and the day's
## earned (with the day lock). Never the floor quota.
static func _add_found(s: RunState, id: String, credits: int, piece: int, t: float) -> void:
	if credits <= 0:
		return
	var m := Instr.member(s.crew, id)
	if m == null:
		return
	var rd := TapeLib.Reading.new()
	rd.id = "found-%d-%d-%d" % [s.day_index, s.depth, piece]
	rd.player_id = id
	rd.entity_id = "found"
	rd.trait_name = &"found"
	rd.value = float(credits)
	rd.duration = 0.0
	rd.peak_rate = 0.0
	rd.closed_at = t
	var nm := m.copy()
	nm.tape = TapeLib.add_reading(m.tape, rd)
	var c := s.crew.copy()
	for k in c.members.size():
		if c.members[k].id == id:
			c.members[k] = nm
	s.crew = c
	if s.day_lock:
		s.day_earned += float(credits)
	if Findables.test_break == "floor_earned" and s.quota:
		# The deliberate break: found credits counted on the floor quota.
		s.floor_earned += float(credits)

## What a tape holds in found credits (its "found" readings).
static func found_on(tape: TapeLib.Tape) -> float:
	var sum := 0.0
	for r in tape.readings:
		if r.trait_name == &"found":
			sum += r.value
	return sum

# ---------------------------------------------------------------------------------------------
# The four-slot inventory (S1; see the header).

static func _step_lamps(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, dt: float, events: Array[Dictionary]) -> void:
	var lamps := s.lamps.duplicate()
	for p in players:
		var identity := str(s.flare_profiles.get(p.id, p.id))
		var before: Dictionary = lamps.get(identity, {})
		if not _is_active(p, input_of) or p.status != &"ok":
			if bool(before.get("on", false)):
				var switched_off := before.duplicate()
				switched_off.on = false
				lamps[identity] = switched_off
			continue
		var i := _inp(p, input_of)
		var charge := float(before.get("charge", Lamp.new_charge(s.tuning)))
		var on := bool(before.get("on", false))
		if i.inv_op == &"lamp" and charge > 0.0:
			var wanted: bool = i.inv_arg == 1
			if wanted != on:
				events.append({"type": "lampSwitched", "t": t, "playerId": p.id, "on": wanted})
			on = wanted
		if on:
			charge = maxf(0.0, charge - dt)
			if charge <= 0.000001:
				charge = 0.0
				on = false
				events.append({"type": "lampEmpty", "t": t, "playerId": p.id})
		var light := Lamp.beam(s.tuning, p.body, i.eye, i.yaw, i.pitch)
		lamps[identity] = {"on": on, "charge": charge, "x": light.x, "y": light.y, "z": light.z, "yaw": light.yaw,
			"pitch": light.pitch, "range": light.range}
	s.lamps = lamps

static func _step_flares(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, events: Array[Dictionary]) -> Dictionary:
	var used := {}
	if s.flare_plan != s.plan:
		s.flare_plan = s.plan
		s.flare_bursts = []
		s.flare_stun_until = -1.0
	else:
		s.flare_bursts = s.flare_bursts.filter(func(b: Dictionary) -> bool: return t < maxf(b.until, b.blindUntil))
	if s.phase == &"riding" or at_home(s):
		return used
	for p in players:
		if not _is_active(p, input_of) or p.status != &"ok":
			continue
		var id := str(s.flare_profiles.get(p.id, p.id))
		var bag := Inventory.bag_of(s.bags, p.id)
		if not s.flare_issued.has(id):
			var added := Inventory.add(bag, Flare.ITEM, 1, 1)
			if added.added != 0:
				bag = added.bag
				_set_bag(s, p.id, bag)
				s.flare_issued = s.flare_issued.duplicate()
				s.flare_issued[id] = true
		var input := _inp(p, input_of)
		var slot := input.inv_select if input.inv_select >= 0 and input.inv_select < Inventory.SLOTS else bag.sel
		if input.inv_op != &"use" or bag.item(slot) != Flare.ITEM:
			continue
		used[p.id] = true
		if p.aboard or _in_hide(s, p.id) or searching(s, p.id):
			events.append({"type": "invRefused", "t": t, "playerId": p.id, "op": "use", "why": "busy"})
			continue
		_set_bag(s, p.id, Inventory.remove_one(bag, slot))
		_burst_flare(s, p, input.yaw, players, input_of, t, events)
	return used

static func _burst_flare(s: RunState, p: RunPlayer, yaw: float, players: Array[RunPlayer], input_of: Dictionary, t: float, events: Array[Dictionary]) -> void:
	var direction := Flare.forward(yaw)
	var reach := Settings.f(s.tuning, &"flare.throw", Flare.THROW)
	var at := Move.move_with_collision(s.plan, p.body, direction.x * reach, direction.y * reach, 0.08)
	var struck := ""
	var nearest := reach + 0.001
	for other in players:
		if p.id == other.id or other.aboard or other.status != &"ok" or not _is_active(other, input_of):
			continue
		if not Flare.within(p.body, other.body, reach):
			continue
		var along := Flare.aim(p.body, other.body, direction)
		if along < nearest and Flare.clear(s.plan, p.body, other.body):
			struck = other.id
			nearest = along
			at = other.body
	var stunned := false
	if struck.is_empty() and s.orderly != null and (s.orientation or resident_of(s).stillness) and not s.seek_off:
		var radius := Settings.f(s.tuning, &"flare.reach", Flare.REACH)
		stunned = Flare.within(at, s.orderly.body, radius) and Flare.clear(s.plan, at, s.orderly.body)
		if stunned:
			s.flare_stun_until = maxf(s.flare_stun_until, t + Settings.f(s.tuning, &"flare.stun", Flare.STUN))
	s.flare_seq += 1
	var blind_until := t + Settings.f(s.tuning, &"flare.blind", Flare.BLIND) if not struck.is_empty() else t
	var burst := {"id": s.flare_seq, "x": at.x, "y": at.y, "z": at.z, "until": t + Flare.BURST_SECONDS,
		"blind": struck, "blindUntil": blind_until}
	s.flare_bursts.append(burst)
	var event := burst.duplicate()
	event.merge({"type": "flareUsed", "t": t, "playerId": p.id, "level": at.level, "stunned": stunned,
		"noise": Settings.f(s.tuning, &"flare.noise", Flare.NOISE)})
	events.append(event)

## A found item goes into the bag. A full bag leaves it in the piece for a fresh search.
static func _store_search_item(s: RunState, by: String, piece: int, item: String, t: float, events: Array[Dictionary]) -> void:
	var r := Inventory.add(Inventory.bag_of(s.bags, by), item, 1, inventory_limit(s, by))
	if r.added > 0:
		var bags := s.bags.duplicate()
		bags[by] = r.bag
		s.bags = bags
		return
	var ff := (s.find as Findables.FindFloor).copy()
	ff.opened.erase(piece)
	s.find = ff
	for k in range(events.size() - 1, -1, -1):
		var e := events[k]
		if str(e.get("type")) == "searchDone" and str(e.get("playerId")) == by and int(e.get("piece", -1)) == piece:
			events.remove_at(k)
			break
	var full := {"type": "searchFull", "t": t, "playerId": by, "piece": piece}
	if item == String(Findables.BADGE):
		full["item"] = item
	events.append(full)

## Every bag and pickup as one list of items ({item: count}): what the world holds (tests count it).
static func items_in_world(s: RunState) -> Dictionary:
	return Inventory.world_totals(s.bags, s.pickups)

## One tick of the inventory (see the header). Updates `s` (bags, pickups) and appends the events.
static func _step_inventory(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, events: Array[Dictionary]) -> void:
	if s.pickups_plan != s.plan:
		# A new floor (or home): what lay on the last one is gone with it.
		s.pickups = []
		s.pickups_plan = s.plan
		if s.garden_cones:
			for cone in GardenCones.placements(s.plan):
				s.pickup_seq += 1
				s.pickups.append(Inventory.Pickup.make(s.pickup_seq, GardenCones.ITEM, 1, cone))
	var bags := s.bags
	var pickups := s.pickups
	var seq := s.pickup_seq
	var touched := false
	# Not on their feet: everything they carry falls where they are (B6).
	for p in players:
		if p.status == &"ok":
			continue
		var b: Inventory.Bag = bags.get(p.id)
		if b == null or b.is_empty():
			continue
		if not touched:
			bags = bags.duplicate()
			pickups = pickups.duplicate()
			touched = true
		var nb := b
		for k in Inventory.SLOTS:
			if nb.count(k) <= 0:
				continue
			seq += 1
			pickups.append(Inventory.Pickup.make(seq, nb.item(k), nb.count(k), p.body))
			events.append({"type": "itemDropped", "t": t, "playerId": p.id, "pickup": seq, "item": nb.item(k), "count": nb.count(k), "at": p.body, "why": "down"})
			nb = Inventory.clear_slot(nb, k)
		bags[p.id] = nb
	# The requests, in the run's player order.
	for p in players:
		var i: PlayerInput = input_of.get(p.id)
		if i == null or p.status != &"ok" or not _is_active(p, input_of) or (i.inv_select < 0 and i.inv_op == &""):
			continue
		if not touched:
			bags = bags.duplicate()
			pickups = pickups.duplicate()
			touched = true
		var b := Inventory.bag_of(bags, p.id)
		if i.inv_select >= 0 and i.inv_select < Inventory.SLOTS and i.inv_select != b.sel:
			b = Inventory.select(b, i.inv_select)
			bags[p.id] = b
		if i.inv_op == &"" or (i.inv_op == &"throw" and not s.garden_cones) or (i.inv_op == &"skill" and not s.deep_pockets):
			continue
		var refuse := func(why: String) -> void:
			events.append({"type": "invRefused", "t": t, "playerId": p.id, "op": String(i.inv_op), "why": why})
		if s.phase == &"riding" or _in_hide(s, p.id) or searching(s, p.id):
			refuse.call("busy")
			continue
		var k := b.sel
		match i.inv_op:
			&"drop":
				if b.count(k) <= 0:
					refuse.call("empty")
					continue
				seq += 1
				pickups.append(Inventory.Pickup.make(seq, b.item(k), b.count(k), p.body))
				events.append({"type": "itemDropped", "t": t, "playerId": p.id, "pickup": seq, "item": b.item(k), "count": b.count(k), "at": p.body, "why": "drop"})
				if Inventory.test_break != "dup_drop":
					bags[p.id] = Inventory.clear_slot(b, k)
			&"take":
				var at := -1
				for n in pickups.size():
					if i.inv_arg != null and (pickups[n] as Inventory.Pickup).id == int(i.inv_arg):
						at = n
						break
				if at < 0:
					refuse.call("gone")
					continue
				var pk: Inventory.Pickup = pickups[at]
				if not Inventory.within(p.body, pk.at, Inventory.PICKUP_REACH):
					refuse.call("reach")
					continue
				var r := Inventory.add(b, pk.item, pk.count, inventory_limit(s, p.id))
				if r.added <= 0:
					refuse.call("full")
					continue
				bags[p.id] = r.bag
				if r.left > 0:
					pickups[at] = Inventory.Pickup.make(pk.id, pk.item, r.left, pk.at)
				else:
					pickups.remove_at(at)
				events.append({"type": "itemTaken", "t": t, "playerId": p.id, "pickup": pk.id, "item": pk.item, "count": r.added, "left": r.left})
			&"throw":
				if s.garden == null or in_car(s.car, p.body) or b.item(k) != GardenCones.ITEM or b.count(k) < 1:
					refuse.call("throw")
					continue
				var at := GardenCones.landing(s.plan, solids_in(s), p.body, i.yaw, i.pitch)
				var g := s.garden.copy()
				var distance := M.hypot2(at.x - p.body.x, at.z - p.body.z)
				var duration := maxf(0.12, distance / GardenCones.SPEED)
				g.cones_in_flight.append({"at": at, "lands": t + duration})
				s.garden = g
				bags[p.id] = Inventory.remove_one(b, k)
				events.append({"type": "coneThrown", "t": t, "from": p.body, "at": at, "flight": duration})
			&"give":
				if b.count(k) <= 0:
					refuse.call("empty")
					continue
				var q: RunPlayer = null
				for o in players:
					if i.inv_arg != null and o.id == str(i.inv_arg):
						q = o
				if q == null or q.id == p.id or q.status != &"ok" or not _is_active(q, input_of):
					refuse.call("gone")
					continue
				if not Inventory.within(p.body, q.body, Inventory.hand_reach(s.tuning)):
					refuse.call("reach")
					continue
				var r := Inventory.add(Inventory.bag_of(bags, q.id), b.item(k), b.count(k), inventory_limit(s, q.id))
				if r.added <= 0:
					refuse.call("theirFull")
					continue
				bags[q.id] = r.bag
				var nb := b.copy()
				var n_left := b.count(k) - r.added
				nb.slots[k] = [b.item(k) if n_left > 0 else "", n_left]
				bags[p.id] = nb
				events.append({"type": "itemGiven", "t": t, "playerId": p.id, "to": q.id, "item": b.item(k), "count": r.added})
			_:
				# The shop's requests (S2) are the shop's step's, after this one.
				if not (s.shop and Shop.OPS.has(String(i.inv_op))) and i.inv_op not in [&"skill", &"lamp"] and not (s.flare and i.inv_op == &"use"):
					refuse.call("op")
	if touched:
		s.bags = bags
		s.pickups = pickups
		s.pickup_seq = seq

# ---------------------------------------------------------------------------------------------
# The shop and the cabinet (S2; see the header).

static func inventory_limit(s: RunState, id: String) -> int:
	var wallet: Upgrades.UpgradeState = s.wallets.get(id)
	if s.deep_pockets and wallet != null and wallet.owned.has("deep_pockets"):
		return 3
	return Inventory.stack_limit(s.tuning, id)

static func _settle_training(s: RunState, id: String, t: float, events: Array[Dictionary]) -> void:
	var wallet: Upgrades.UpgradeState = s.wallets.get(id)
	if wallet == null or (Upgrades.induction_node(wallet.last_id).is_empty() and not (s.quick_fingers and wallet.last_id == "quick_fingers")):
		return
	var wallets := s.wallets.duplicate()
	wallets[id] = Upgrades.next_morning(wallet)
	s.wallets = wallets
	events.append({"type": "trainingSettled", "t": t, "playerId": id})

static func _skill_transaction(s: RunState, p: RunPlayer, bag: Inventory.Bag, arg: Variant, t: float, events: Array[Dictionary]) -> String:
	if not at_home(s) or s.plan == null or p.body == null or p.body.level != 0:
		return "window"
	var cell := Move.cell_of(s.plan, p.body)
	if Prison.station_at(Vector2i(cell.x, cell.y)) != &"skills":
		return "window"
	if (s.shop_state as Shop.ShopState).wake_until >= 0.0 or s.lights_out_t >= 0.0 or s.bed == null or Day.is_lights_out(s.bed, t):
		return "closed"
	if s.bed.in_bed.has(p.id):
		return "busy"
	var wallet: Upgrades.UpgradeState = s.wallets.get(p.id)
	if wallet == null:
		wallet = Upgrades.UpgradeState.make()
	var result: Upgrades.UpResult
	var next_bag := bag
	if arg in [0, 2, 4, 6]:
		var node_id := str({0: "deep_pockets", 2: "second_wind", 4: "soft_shoes", 6: "long_burn"}[int(arg)])
		if not training_enabled(s, node_id):
			return "op"
		result = Upgrades.buy_induction(wallet, node_id, Shop.SHARE)
	elif arg == 5:
		if not s.quick_fingers:
			return "op"
		var cost := int(Upgrades.trade_node("quick_fingers")["badge_cost"])
		result = Upgrades.buy_trade(wallet, "quick_fingers", int(bag.totals().get("badge", 0)))
		if result.ok:
			next_bag = Inventory.spend(bag, "badge", cost)
			if next_bag == null:
				return "badges"
	elif arg == 1:
		if not training_enabled(s, wallet.last_id):
			return "nothing_to_undo"
		if wallet.last_id == "deep_pockets":
			next_bag = _unstack_bag(bag, Inventory.stack_limit(s.tuning, p.id))
			if next_bag == null:
				return "unstack"
		elif wallet.last_id == "quick_fingers":
			var refund := int(Upgrades.trade_node(wallet.last_id)["badge_cost"])
			var returned := Inventory.add(bag, "badge", refund, inventory_limit(s, p.id))
			if returned.left > 0:
				return "badge_room"
			next_bag = returned.bag
		result = Upgrades.undo(wallet)
	else:
		return "op"
	if not result.ok:
		return result.reason
	var wallets := s.wallets.duplicate()
	wallets[p.id] = result.state
	s.wallets = wallets
	if next_bag != bag:
		_set_bag(s, p.id, next_bag)
	var kind := "trainingUndone" if arg == 1 else "trained"
	events.append({"type": kind, "t": t, "playerId": p.id, "node": wallet.last_id if arg == 1 else result.state.last_id})
	return ""

## Keep every item on undo, retaining the selected slot. Return null if the untrained bag cannot fit it all.
static func _unstack_bag(bag: Inventory.Bag, limit: int) -> Inventory.Bag:
	var next := bag.copy()
	for k in Inventory.SLOTS:
		var excess := bag.count(k) - limit
		if excess > 0:
			next.slots[k] = [bag.item(k), limit]
	for k in Inventory.SLOTS:
		var excess := bag.count(k) - limit
		if excess <= 0:
			continue
		var placed := Inventory.add(next, bag.item(k), excess, limit)
		if placed.left > 0:
			return null
		next = placed.bag
	return next

## The ids of the run's players, in its order (Day.bunk_of sorts them: every bunk and cabinet is the same for all).
static func _ids_of(players: Array[RunPlayer]) -> Array[String]:
	var ids: Array[String] = []
	for p in players:
		ids.append(p.id)
	return ids

## The night in the cells (the shop on; see the header): everything carried or left lying is cleared, the cabinets
## are kept, and the crew wakes on their bunks, lights on, until the car takes them down.
static func _wake_in_cells(s: RunState, players: Array[RunPlayer], t: float, events: Array[Dictionary]) -> void:
	if s.inventory and Shop.test_break != "keep" and Inventory.test_break != "no_clear":
		s.bags = {}
		s.pickups = []
		s.pickups_plan = null
	var sh := (s.shop_state as Shop.ShopState).copy()
	sh.glows = []
	sh.toys = []
	sh.juiced = {}
	sh.flashes = {}
	sh.wake_until = t + Shop.WAKE_SECONDS
	s.shop_state = sh
	var ids := _ids_of(players)
	var bodies := {}
	for i in players.size():
		var np := players[i].copy()
		np.body = bunk_body(s.plan, ids, np.id)
		np.status = &"ok"
		np.aboard = false
		np.side = null
		players[i] = np
		bodies[np.id] = np.body
	var nc := s.crew.copy()
	var members: Array[Instr.CrewMember] = []
	for m in nc.members:
		var nm := m.copy()
		nm.body = bodies.get(m.id, m.body)
		members.append(nm)
	nc.members = members
	s.crew = nc
	s.bed = null
	s.bed_hold = {}
	s.use_prev = {}
	s.lights_out_t = -1.0
	events.append({"type": "wokeUp", "t": t, "bodies": bodies, "leaveAt": sh.wake_until})

## One tick of the shop (see the header): the floor's lit things go with it, and the requests in the run's player
## order. Updates `s` (shop_state, bags) and appends the events.
static func _step_shop(s: RunState, players: Array[RunPlayer], input_of: Dictionary, t: float, _dt: float, events: Array[Dictionary], flare_users := {}) -> void:
	var sh0: Shop.ShopState = s.shop_state
	var sh := sh0
	if sh.plan != s.plan:
		# A new floor (or home): what was lit or set on the last one is gone with it.
		sh = sh.copy()
		sh.plan = s.plan
		sh.glows = []
		sh.toys = []
	# What the items left (S2): glow sticks going out, toys rattling (the host event "noise": nothing listens to it on
	# main yet; the Playroom hears it through the seek step) and going quiet, the juice and the flash running out.
	var t0 := t - _dt
	var live_g: Array = []
	for g: Dictionary in sh.glows:
		if float(g["until"]) <= t + EPS:
			events.append({"type": "glowOut", "t": t, "id": g["id"]})
		else:
			live_g.append(g)
	var live_t: Array = []
	for g: Dictionary in sh.toys:
		var st := float(g["start"])
		if st > t0 + EPS and st <= t + EPS:
			var b0: Move.Body = g["at"]
			events.append({"type": "noise", "t": t, "source": "toy", "id": g["id"], "by": g["by"], "x": b0.x, "z": b0.z, "y": b0.y, "level": b0.level, "radius": Shop.TOY_RADIUS})
		if float(g["end"]) <= t + EPS:
			events.append({"type": "toyDone", "t": t, "id": g["id"]})
		else:
			live_t.append(g)
	var ju := {}
	for id: String in sh.juiced:
		if float(sh.juiced[id]) <= t + EPS:
			events.append({"type": "juiceOut", "t": t, "playerId": id})
		else:
			ju[id] = sh.juiced[id]
	var fl := {}
	for id: String in sh.flashes:
		if float(sh.flashes[id]) > t + EPS:
			fl[id] = sh.flashes[id]
	if live_g.size() != sh.glows.size() or live_t.size() != sh.toys.size() or ju.size() != sh.juiced.size() or fl.size() != sh.flashes.size():
		sh = sh.copy() if sh == sh0 else sh
		sh.glows = live_g
		sh.toys = live_t
		sh.juiced = ju
		sh.flashes = fl
	var ids := _ids_of(players)
	for p in players:
		var i: PlayerInput = input_of.get(p.id)
		if flare_users.has(p.id):
			continue
		if i == null or p.status != &"ok" or not _is_active(p, input_of):
			continue
		if not Shop.OPS.has(String(i.inv_op)) and not (s.deep_pockets and i.inv_op == &"skill"):
			continue
		# The inventory's step said "busy" to these already.
		if s.phase == &"riding" or _in_hide(s, p.id) or searching(s, p.id):
			continue
		var refuse := func(why: String) -> void:
			events.append({"type": "invRefused", "t": t, "playerId": p.id, "op": String(i.inv_op), "why": why})
		var b := Inventory.bag_of(s.bags, p.id)
		var limit := inventory_limit(s, p.id)
		match String(i.inv_op):
			"skill":
				var why := _skill_transaction(s, p, b, i.inv_arg, t, events)
				if not why.is_empty():
					refuse.call(why)
			"stash", "fetch":
				if not Shop.at_cabinet(s.plan, ids, p.id, p.body):
					refuse.call("reach")
					continue
				var cab := Shop.cabinet_of(sh.cabinets, p.id)
				var k := int(i.inv_arg) if i.inv_arg != null else -1
				if i.inv_op == &"stash":
					if k < 0 or k >= Inventory.SLOTS or b.count(k) <= 0:
						refuse.call("empty")
						continue
					var put := Shop.cab_put(cab, Shop.cab_slots(s.tuning), b.item(k), b.count(k), limit)
					if int(put[1]) <= 0:
						refuse.call("cabFull")
						continue
					var nb := b.copy()
					var left := b.count(k) - int(put[1])
					nb.slots[k] = [b.item(k) if left > 0 else "", left]
					_set_bag(s, p.id, nb)
					sh = _with_cabinet(sh, sh0, p.id, put[0])
					events.append({"type": "stashed", "t": t, "playerId": p.id, "item": b.item(k), "count": int(put[1]), "slot": k})
				else:
					if k < 0 or k >= Shop.CAB_MAX or int(cab[k][1]) <= 0:
						refuse.call("empty")
						continue
					var item := str(cab[k][0])
					var r := Inventory.add(b, item, int(cab[k][1]), limit)
					if r.added <= 0:
						refuse.call("full")
						continue
					var nc := cab.duplicate(true)
					var left := int(cab[k][1]) - r.added
					nc[k] = [item if left > 0 else "", left]
					_set_bag(s, p.id, r.bag)
					sh = _with_cabinet(sh, sh0, p.id, nc)
					events.append({"type": "fetched", "t": t, "playerId": p.id, "item": item, "count": r.added, "slot": k})
			"buy":
				var n := int(i.inv_arg) if i.inv_arg != null else -1
				if n < 0 or n >= Shop.ITEMS.size():
					refuse.call("op")
					continue
				if not Shop.at_shop(s.plan, p.body):
					refuse.call("window")
					continue
				# In the prison you can only buy and then sleep (C6): not in bed, not after lights out, not in the morning.
				if sh.wake_until >= 0.0 or s.lights_out_t >= 0.0 or (s.bed != null and Day.is_lights_out(s.bed, t)):
					refuse.call("closed")
					continue
				if s.bed != null and s.bed.in_bed.has(p.id):
					refuse.call("busy")
					continue
				var item: String = Shop.ITEMS[n]
				var price := Shop.price(s.tuning, item)
				if not Inventory.has_room(b, item, limit):
					refuse.call("full")
					continue
				var w: Upgrades.UpgradeState = s.wallets.get(p.id)
				if w == null:
					w = Upgrades.UpgradeState.make(0)
				if w.credits < price:
					refuse.call("poor")
					continue
				var nw := w.copy()
				if Shop.test_break != "free":
					nw.credits -= price
				var wallets := s.wallets.duplicate()
				wallets[p.id] = nw
				s.wallets = wallets
				_set_bag(s, p.id, Inventory.add(b, item, 1, limit).bag)
				events.append({"type": "bought", "t": t, "playerId": p.id, "item": item, "price": price, "credits": nw.credits})
			"use":
				var k := b.sel
				if b.count(k) <= 0:
					refuse.call("empty")
					continue
				var item := b.item(k)
				if not Shop.usable(item):
					refuse.call("unusable")
					continue
				var used: Array = _use_item(s, sh, sh0, players, p, i, item, t, events)
				if str(used[0]) != "":
					refuse.call(str(used[0]))
					continue
				sh = used[1]
				_set_bag(s, p.id, Inventory.remove_one(Inventory.bag_of(s.bags, p.id), k))
			_:
				refuse.call("op")
	if sh != sh0:
		s.shop_state = sh

static func _light_duration_scale(s: RunState, id: String) -> float:
	var wallet: Upgrades.UpgradeState = s.wallets.get(id)
	return 2.0 if s.long_burn and wallet != null and wallet.owned.has("long_burn") else 1.0

## Uses `item` from player `p`'s hand (the shop's items; see the header). Returns ["" and the shop state after] when it
## worked (the caller takes the item from the hand), or [why, the shop state unchanged] when it cannot be used here.
static func _use_item(s: RunState, sh: Shop.ShopState, sh0: Shop.ShopState, players: Array[RunPlayer], p: RunPlayer, i: PlayerInput, item: String, t: float, events: Array[Dictionary]) -> Array:
	var at := Move.Body.make(_cm(p.body.x), _cm(p.body.z), p.body.level, p.body.y)
	var used := {"type": "itemUsed", "t": t, "playerId": p.id, "item": item}
	var n := sh.copy() if sh == sh0 else sh
	match item:
		"speed":
			# Eight seconds of sprint that costs no stamina (the host holds the tank full), then winded ("juiceOut").
			var ju := n.juiced.duplicate()
			ju[p.id] = t + Shop.JUICE_SECONDS
			n.juiced = ju
			used["until"] = ju[p.id]
		"glow":
			# Dropped at the feet, lit on every screen until shop.glow runs out. No rule reads its light.
			n.seq += 1
			var g := n.glows.duplicate()
			g.append({"id": n.seq, "at": at, "until": t + Shop.glow_seconds(s.tuning) * _light_duration_scale(s, p.id), "by": p.id})
			n.glows = g
			used["id"] = n.seq
			used["at"] = at
		"toy":
			# Set at the feet: TOY_WAIT later it rattles for TOY_RATTLE.
			n.seq += 1
			var g := n.toys.duplicate()
			g.append({"id": n.seq, "at": at, "start": t + Shop.TOY_WAIT, "end": t + Shop.TOY_WAIT + Shop.TOY_RATTLE, "by": p.id})
			n.toys = g
			used["id"] = n.seq
			used["at"] = at
		"flash":
			# One second of looking from where they stand, even in the dark (the Stillness step reads it).
			var fl := n.flashes.duplicate()
			fl[p.id] = t + Shop.FLASH_SECONDS * _light_duration_scale(s, p.id)
			n.flashes = fl
			used["until"] = fl[p.id]
		"salts":
			# A downed crewmate, faced, within the heal reach: up at once, counted as a heal.
			var k := _salts_target(s, players, p, i)
			if k < 0:
				return ["nobody", sh]
			used["target"] = players[k].id
			events.append(used)
			_salts_heal(s, players, k, p.id, t, events)
			return ["", n]
		"marker":
			# The Annex's marks (sim/marks.gd): one in your colour, on top of the crew's pad, which it never touches.
			if s.annex == null or (s.annex as AnnexFloor).plan != s.plan:
				return ["annexOnly", sh]
			if p.aboard or i.gait == &"sprint":
				return ["busy", sh]
			var a := (s.annex as AnnexFloor).copy()
			var ms := a.marks.copy()
			var m := Marks.Mark.make(ms.next_id, at.x, at.z, at.level, Marks.snap_dir(i.yaw), p.id, t)
			ms.next_id += 1
			ms.marks.append(m)
			a.marks = ms
			s.annex = a
			var om := n.own_marks.duplicate()
			om[m.id] = true
			n.own_marks = om
			used["mark"] = m.id
			events.append(used)
			events.append({"type": "markPlaced", "t": t, "playerId": p.id, "mark": mark_plain(m), "pad": ms.pad, "radius": Marks.NOISE_RADIUS, "own": true})
			return ["", n]
		_:
			return ["unusable", sh]
	events.append(used)
	return ["", n]

## The downed crewmate player `p` faces within the salts' reach (feet, same level, within Shop.SALTS_FACE_DEG of where
## they look): the nearest, or -1.
static func _salts_target(s: RunState, players: Array[RunPlayer], p: RunPlayer, i: PlayerInput) -> int:
	if not s.downs:
		return -1
	var reach := Shop.salts_reach(HEAL_REACH)
	var fx := -sin(i.yaw)
	var fz := -cos(i.yaw)
	var cos_max := cos(deg_to_rad(Shop.SALTS_FACE_DEG))
	var best := -1
	var best_d := INF
	for k in players.size():
		var q := players[k]
		if q.id == p.id or q.status != &"down" or q.body == null or q.body.level != p.body.level or not s.down.has(q.id):
			continue
		var dx := q.body.x - p.body.x
		var dz := q.body.z - p.body.z
		var d := M.hypot2(dx, dz)
		if d > reach + EPS or (d > 0.05 and (dx * fx + dz * fz) / d < cos_max):
			continue
		if d < best_d:
			best_d = d
			best = k
	return best

## Smelling salts: player `k` is up at once where they lie, as a finished heal is ("healed", by the user).
static func _salts_heal(s: RunState, players: Array[RunPlayer], k: int, by: String, t: float, events: Array[Dictionary]) -> void:
	var p := players[k]
	var down := s.down.duplicate()
	var d: Downed = down.get(p.id)
	if d != null and d.healer != "":
		events.append({"type": "healStop", "t": t, "playerId": d.healer, "target": p.id})
	down.erase(p.id)
	s.down = down
	var np := p.copy()
	np.status = &"ok"
	np.side = null
	players[k] = np
	events.append({"type": "healed", "t": t, "playerId": p.id, "by": by, "at": np.body, "salts": true})
	if s.orderly.mode == &"bending" and str(s.orderly.bend_target) == p.id:
		s.orderly = Entity.stand_off(s.orderly, Settings.f(s.tuning, &"heal.quiet", HEAL_QUIET))
	_seek_heal(s, np)

## The bags with player `id`'s replaced.
static func _set_bag(s: RunState, id: String, b: Inventory.Bag) -> void:
	var bags := s.bags.duplicate()
	bags[id] = b
	s.bags = bags

## The shop state with player `id`'s cabinet replaced (copied first if it is still the tick's first).
static func _with_cabinet(sh: Shop.ShopState, sh0: Shop.ShopState, id: String, cab: Array) -> Shop.ShopState:
	var n := sh.copy() if sh == sh0 else sh
	var cabs := n.cabinets.duplicate()
	cabs[id] = cab
	n.cabinets = cabs
	return n

## Every item in the world with the shop on: every bag, every pickup and every cabinet ({item: count}).
static func items_with_cabinets(s: RunState) -> Dictionary:
	var out := items_in_world(s)
	if s.shop_state != null:
		var c: Dictionary = Shop.cabinet_totals((s.shop_state as Shop.ShopState).cabinets)
		for item: String in c:
			out[item] = int(out.get(item, 0)) + int(c[item])
	return out

## Tests and the stamped save: the run with player `id`'s cabinet as given (Shop.cabinet_from_text of a save).
static func with_cabinet(s0: RunState, id: String, cab: Array) -> RunState:
	var s := s0.copy()
	var sh := (s.shop_state as Shop.ShopState).copy()
	var cabs := sh.cabinets.duplicate()
	cabs[id] = cab.duplicate(true)
	sh.cabinets = cabs
	s.shop_state = sh
	return s
