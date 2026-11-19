# Stamped saves

Dedicated rooms enable saves when `GD_SAVE_KEY` contains a valid signing key. The key is read once from the environment at startup and stays in server memory. A room without the key uses the existing connection and run behavior.

1. The room advertises profile support in its authenticated welcome. The client reads its most recent save for that WebSocket address and submits it before readying. The server verifies the stamp and fields before applying the wallet and cabinet, also accepting legacy signed saves without a cabinet field.
2. After an accepted purchase, stash or fetch, and at the day checkpoints, the room seals the current cabinet and progress. It sends the save only to its owner. The client writes a temporary file and replaces its active save after the write succeeds. Held items and floor pickups never enter the saved data.
3. A registered profile can have one active connection. Within the same server process, a reconnect recovers the most recent authoritative checkpoint even when it supplies an older valid save. Across server restarts an older genuine stamp can still be presented because the server writes no save files.

Playing alone uses a separate disk file with the same checked canonical fields. Its unsigned contents are trusted only by the player's local room and cannot be presented as a stamped multiplayer save. Host Playtest and the default automated client keep their profiles off disk.
