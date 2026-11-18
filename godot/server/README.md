# The Going Down server

One room, run by the home server: a lobby until a player presses start, then the run (the
authoritative host of `net/host.gd`, stepping the rules through `net/host_rules.gd` exactly as the
game does), then back to the lobby ten seconds after a bank or a wipe. It draws nothing, opens no
file for writing, starts no process and makes no outgoing connection.

```
server/server.gd    the entry point (args, passphrase, the loop); server.tscn runs it
server/room.gd      the lobby and the run; the room's own messages (m|...) and the run's (n<epoch>|...)
net/ws_server.gd    the door: WebSocket connections, the passphrase hello, every limit
```

## The door

- **Passphrase.** Read at start from the environment variable `GD_JOIN_SECRET`, or from the first
  line of the file named by `GD_JOIN_SECRET_FILE` (keep that file outside the repository). Never in
  the game, never in git, never logged; only its SHA-256 is kept. The first message on a connection
  must be `["hello", 1, "<passphrase>", "<name>"]`; it is compared in constant time, and a wrong or
  missing one closes the connection (code 4001) before any game message is read. Without a
  passphrase the server refuses to start, unless `insecure=1` is given (local tests only; it prints
  a loud warning).
- **Limits.** At most 8 players (a ninth is closed with 4002) and 4 connections waiting for their
  hello; 5 s to say hello; after the second failed passphrase from an address, that address is
  refused for 2, 4, 8 ... s (at most 60 s) before any handshake; messages at most 4096 bytes (4003);
  at most 120 messages a second per connection (4004); 20 s of silence closes a connection (4006;
  clients ping every 2 s in the lobby and send 20 inputs a second in a run). Every message must be
  text and fit the protocol exactly: the room's own (`m|{"t":"start"|"name"|"ping"}`) or a run
  message that `net/protocol.gd` decodes with every field in range and every number finite;
  anything else closes the connection (4005). A client's run messages are handed to the host as
  coming from its own connection id, so it can only ever send its own inputs.
- **Behind Tailscale Funnel** every friend arrives from the same address (the proxy), so the
  per-address back-off acts for the whole room; that is why it stops at 60 s.

- **Build.** The hello may carry a fifth element, the game's build id (`net/build_info.gd`: the short
  commit, written by `npm run godot:export`). A server whose own id is not `dev` refuses any other id,
  and a hello without one, with code 4007 and "Your game is out of date. Ask the host for the new
  GoingDown.zip.", which the join screen shows. A server run from source before any export is `dev`
  and takes everyone. `build=ID` (an argument) sets the server's id for tests.

## The night's log

Beside its plain lines the server prints the night's log, one JSON object per line
(`server/night_log.gd` lists every event): joins and leaves (names, builds, close codes; addresses only
as a salted 8-digit hash), the runs and what happened in them (floors, catches, downs, wipes, banks), the
tick cost each stats period, refused connections, server errors (a Logger sees every engine and script
error), and what the games send on their own `t|` frame (`client/telemetry.gd`): a heartbeat every 30 s
(build, OS, GPU, frame times, ping, floor, phase), every error line, F9 reports and crash tails. The
server only logs those: at most 20 lines, 4 heartbeats and 16 report parts a minute per player, the
rest counted; one that does not decode is dropped, never a kick. The passphrase is never in it.

The container can write nowhere but a 1 MB `/tmp`, so standard output is the store: Docker keeps it
until the container is removed, and `run-on-host.sh` removes it. Fetch the logs before a redeploy:

```sh
node godot/tools/night_logs.mjs --ssh USER@HOST         # saves godot/export/night-logs/night-<time>.log, prints the summary
node godot/tools/night_logs.mjs godot/export/night-logs/*.log --errors-only
node godot/tools/hotfix.mjs "what the fix is"            # tests, export, playthroughs, promote, package, server; prints the deploy commands
```

## Running it

Locally (Windows, for tests):

```sh
GD_JOIN_SECRET=test-passphrase tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path godot res://server/server.tscn -- server port=4451 bind=127.0.0.1
node godot/tools/net_local.mjs 4451     # the end-to-end check (starts and stops its own server)
```

Arguments after `--`: `server` (required), `port=N` (default 4450), `bind=ADDRESS` (default every
interface), `seed=TEXT` (tests), `insecure=1` (tests), `quit_after=S` (tests), `stats=S` (seconds
between the cost line in the log, default 60).

The Linux build and the container (on the Linux box; this PC cannot run either):

```sh
npm run godot:export -- server          # on the PC: godot/export/server/GoingDownServer.x86_64
# copy godot/export/server/GoingDownServer.x86_64 and godot/server/Dockerfile to the Linux box, then there:
docker build -t going-down-server -f Dockerfile .          # in the folder holding both files
printf 'GD_JOIN_SECRET=%s\n' 'your passphrase here' > ~/going-down.env && chmod 600 ~/going-down.env
docker run -d --name going-down --restart unless-stopped \
  --read-only --tmpfs /tmp:size=1m --cap-drop ALL --security-opt no-new-privileges \
  --memory 256m --pids-limit 64 \
  -p 127.0.0.1:4450:4450 --env-file ~/going-down.env going-down-server
docker logs -f going-down               # "listening on *:4450", then one line per join and run
docker inspect --format '{{.State.Health.Status}}' going-down   # "healthy" after ~10 s
```

The port is published on 127.0.0.1 only: point the Funnel at `localhost:4450` and nothing else on
the box is reachable through it. The container runs as an unprivileged user with a read-only root
file system; the engine is pointed at `/tmp` (a 1 MB tmpfs) for the user folder it looks for at
start, and the server writes nothing there. Quick checks on the box: `docker run --rm
going-down-server` with no passphrase must exit at once with "not started: no passphrase"; with the
passphrase, a WebSocket client sending a wrong hello must be closed with code 4001.

Cost (measured on the development PC, 60 s of bots, `godot --headless --path godot --script
res://tests/net_bench.gd`): about 2.3 ms a tick with 4 players and 3.5 ms with 8 (20 ticks a second,
so under 7% of one core), worst about 20 to 22 ms (the first tick builds the floor);
snapshots about 10 KB/s per client with 4 players and 16 KB/s with 8, inputs about 2 KB/s per client.

## The image built from nothing (what runs on the lab box)

`Dockerfile` above starts from a Debian image, which has to be downloaded. `Dockerfile.scratch`
starts from nothing instead: the image holds the server file and the six C library files it is
linked against, copied from the machine that builds it. There is no shell and no other program
inside, so there is nothing for an intruder to run. This is the one in use.

On the Linux machine, in one folder: `GoingDownServer.x86_64` (from `npm run godot:export -- server`),
`Dockerfile.scratch`, `build-on-host.sh`, `run-on-host.sh`.

```sh
sh build-on-host.sh        # builds the image "going-down-server"
sh run-on-host.sh          # starts it as the container "going-down", reachable only at 127.0.0.1:4450
docker logs -f going-down  # who joined, who was refused, a line of numbers every minute
```

`run-on-host.sh` reads the passphrase from `~/going-down.env` (one line, `GD_JOIN_SECRET=...`, a file
only its owner can read) and runs the container with a read-only filesystem, no privileges, memory,
process and CPU caps, and its own small network with no route out: the server answers players and
cannot start a connection to the home network or the internet. To change the passphrase, edit that
file and run `run-on-host.sh` again. It sets no restart policy: after a reboot, run it again.

What is not closed: from inside that network the machine's own address is still reachable, so a
service on the machine that listens on every address could be reached by someone who had first
broken into the server. Closing that takes one firewall rule on the machine, which is its owner's
to add.
