# Wiring the stamped save (for P8 and P11)

`net/save_slip.gd` (task P3) is finished and tested alone (`tests/run_save.gd`). Nothing uses it yet.
These are the changes to existing files it needs; none were made, because other tasks own those files.

## 1. Run its tests with the rest (`tests/run_tests.gd`)

Add `"prop_save"` to `FILES`, after `"prop_net"`:

```gdscript
	"prop_stamina", "prop_clinic", "prop_entity", "prop_instrument", "prop_run", "prop_blackout", "prop_net", "prop_save",
```

## 2. The server reads the key once at start (`server/server.gd`, in `_ready`, after the passphrase)

```gdscript
const SaveSlip = preload("res://net/save_slip.gd")
...
	var save_key: PackedByteArray
	var k := SaveSlip.key_from_env()        # GD_SAVE_KEY: at least 64 hex characters (32 bytes)
	if bool(k["ok"]):
		save_key = k["key"]
	elif insecure:
		save_key = Crypto.new().generate_random_bytes(32)   # tests: saves last until the server stops
	else:
		say("not started: no save key. Set GD_SAVE_KEY (64 hex characters; %s)" % k["reason"])
		get_tree().quit(2)
		return
```

Hand `save_key` to the room; never print it, never put it in a message. The server still opens no
file for writing: the key is read from the environment only.

## 3. The key on the lab box (`~/going-down.env`, `run-on-host.sh`, `server/README.md`)

One more line in the same private file as the passphrase, made once on the box:

```sh
printf 'GD_SAVE_KEY=%s\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> ~/going-down.env
```

It is not changed when the passphrase is. Changing it turns every saved game fresh. The README's
"To change the passphrase" line should say so.

## 4. The messages (P8 decides the exact shape; these fit the limits)

- **Bedtime, server to one player:** `m|{"t":"save","save":"<sealed>"}`, sent only on that player's
  own connection (P8's break: "send every save to everyone").
- **Joining, player to server:** either a fifth hello element, `["hello", 1, "<passphrase>", "<name>", "<sealed or empty>"]`
  (then `_hello` in `net/ws_server.gd` must accept size 4 or 5 and check element 4 is a String of at
  most `SaveSlip.MAX_SEALED` characters), or a room message `m|{"t":"save","save":"<sealed>"}` right
  after joining, which `server/room.gd` must add to the room messages it accepts.
- A sealed line is at most `SaveSlip.MAX_SEALED` (3072) bytes, ASCII from `[0-9A-Za-z|,:_]` only,
  so it needs no JSON escaping; the largest valid save is 1309 bytes. The server's message limit is
  `MAX_MESSAGE := 4096` in `net/ws_server.gd`.
- `SaveSlip.open(sealed, key)` refused (any reason): start the player from
  `SaveSlip.fresh(SaveSlip.new_player_number())`. Never tell the client which check failed beyond
  "your save was not accepted".

## 5. Within a night (`server/room.gd`)

Keep `player number -> fields` in memory so a friend who drops and rejoins gets their day back.
Two connections presenting the same player number at once (a copied save) should not both play
as one player: give the second one a fresh player number.

## What the stamp cannot stop

- **Going back to an older save.** A player who keeps an earlier sealed line (before spending
  credits, or before the roll took an upgrade) can present it next night; it is genuinely stamped.
  Stopping that needs the server to remember something between nights, which a read-only server
  cannot. Within one night, the in-memory map above wins over whatever the client sends.
- **Copying a save to a friend.** The friend gets the same credits and nodes. There are no accounts,
  so this is accepted as the cost of "your save is yours" (G3).
