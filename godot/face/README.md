# Draw your face

Each player draws a face before the run. It shows on the screen of the mask their crewmate wears
(North Star H1 and amendment V7), and later on the elevator monitor, the standee left where they
fall, and posters. This folder holds the format, the editor, the tests and a demo. It is not wired
into the start screen or the network yet; the last section lists what that takes.

Nothing here touches the network. The face stays on the player's machine until the game sends it
to the other players in the same room, and it is never uploaded anywhere else.

## Files

| File | What it is |
| --- | --- |
| `face_codec.gd` | `FaceCodec`: the palette, the text format, encode/decode/check, save/load of the last face |
| `face_paint.gd` | `FacePaint`: the picture model (brush dabs and lines, bucket, undo) and the three starting faces |
| `face_editor.gd`, `face_editor.tscn` | `FaceEditor`: the drawing screen, a Control any screen can embed |
| `face_tests.gd` | Headless tests of all of the above |
| `face_demo.gd`, `face_demo.tscn` | The editor, then the face on four crewmates in a real corridor at 1, 2, 3 and 6 m |
| `shots/` | Pictures from the demo (`auto=1`) |

## The picture

32 x 32 cells, 7 fixed colours. Index 0 is the lit screen itself, which is also what the eraser
paints and what Clear fills with.

| Index | Colour | Use |
| --- | --- | --- |
| 0 | `#b8ccbd` screen | background, eraser |
| 1 | `#14161a` ink | the face itself |
| 2 | `#d0202c` red | accents (cheeks, mouth) |
| 3 | `#2050d8` blue | accents (tears) |
| 4 | `#12963a` green | accents |
| 5 | `#ffd21f` yellow | highlights |
| 6 | `#ffffff` white | highlights (eye whites, teeth) |

Why dark ink on a lit screen: the mask's screen glows inside a black bezel. In the demo, bright
strokes on a dark screen read only at 1 to 2 m, because past that the dark screen merges with the
bezel. Dark ink on the lit screen reads at 2 to 3 m and still shows as a glowing face at 6 m. The tape
filter keeps brightness and smears colour, so colours 1 to 4 are all much darker than the screen
(a test pins this) and 5 and 6 are lighter than it.

Why 32 x 32: the screen is a 16.6 cm square at head height, about 32 pixels tall in the game's
480 x 270 view at 1 m and 5 at 6 m. Nothing finer can ever show.

## The format

A face travels as one short text of URL- and JSON-safe characters (`A-Z a-z 0-9 - _`):

    "F1R" + 512 characters    raw: each character holds two pixels (3 bits each, high first)
    "F1L" + run tokens        runs: a colour and a run length per token

`F` marks a face, `1` is the format version, `R` or `L` the packing. Pixels go row by row, top row
first, left to right as the player drew them; pixel 0 is the top-left as the viewer sees it, so the
picture is not mirrored on the mask. A run token is one character `v` (0..63): colour `v >> 3`,
`n = v & 7`; `n` 0..6 is a run of `n + 1` pixels, and `n = 7` means the next character `e` follows
and the run is `8 + e` pixels (8..71).

The encoder writes both packings and keeps the shorter (runs on a tie), so one picture always gives
one text. Sizes measured by the tests: blank 33 characters, the smile 103, the frown 114, the shock
185, a busy hand-drawn face 223, the demo's hand-drawn face 163, and the worst case (random noise)
515. 515 is the hard maximum (`FaceCodec.MAX_LENGTH`).

The decoder takes text from other players' machines. It checks the type, then the length before
reading anything else, then the magic, the version, the packing, every character, every colour index
(7 is not a colour) and that the runs add up to exactly 1024 pixels. It gives back an empty result,
never an error, when anything is off.

## API

### FaceCodec (static)

- `encode(indices: PackedByteArray) -> String`: 1024 colour indices to text, or `""` if the
  picture is not 1024 values of 0..6.
- `decode(code, palette := PALETTE) -> ImageTexture`: the 32 x 32 texture for the mask (with
  mipmaps, so it averages far away instead of sparkling), or `null` if `code` is not a valid face.
  `code` may be any Variant, so it can go straight from a parsed message.
- `decode_indices(code) -> PackedByteArray`: the colour indices, or empty.
- `check(code) -> String`: `""` when valid, otherwise the reason ("not text", "too long", "bad
  character", "colour out of range", "too few pixels", and so on). For logs and tests.
- `is_valid(code) -> bool`.
- `to_image(indices, palette := PALETTE, mipmaps := false) -> Image`: for posters and anything
  that wants the picture at another size.
- `save_last(code) -> bool`, `load_last() -> String`: this computer's last face, kept at
  `user://face/last_face.txt` (`FaceCodec.SAVE_PATH`). Only valid faces are written or read back.
  Nothing else is written. `FaceCodec.save_path` can be pointed elsewhere (the tests do).

### FaceEditor (Control, `face_editor.tscn`)

Give it a rect (anchors or size), add it to the tree and listen:

- `signal done(code: String, texture: ImageTexture)`: the player pressed Done (or Enter, or the
  time limit ran out). If `remember` is on, the face has already been saved.
- `signal cancelled`: Cancel or Esc.

Set before adding it to the tree:

- `palette: Array[Color]` (at most 7, index 0 is the background), `time_limit` (seconds, 0 for
  none; Done fires by itself at zero), `title`, `show_starters`, `remember` (load the last face to
  start from and save on Done), `start_code` (a face to start from), `backdrop` (draw its own
  opaque background).

Calls: `begin(code := "")` reopens it for a new drawing (from `code`, else the saved face, else the
smile, else blank); `get_code()`; `load_code(code)`; `press(id)` drives any control by id
(`"colour:N"`, `"brush:N"`, `"pen"`, `"fill"`, `"erase"`, `"undo"`, `"clear"`, `"starter:NAME"`,
`"done"`, `"cancel"`); `key(event)` for a host that routes keys itself.

Controls: left mouse draws with the tool, right mouse erases. Keys: 1-7 colour, `-` and `+` (or
`[` and `]`) brush size, B pen, F fill, E eraser, Z or Ctrl+Z undo, Delete clear, Enter done, Esc
cancel. The mouse is never captured. Previews under the canvas show the face at about its size in
the game's view at 1, 3 and 6 m.

The second-wave sketchbook (North Star B2) can reuse it as is: its own `palette`, a `time_limit`,
`title = "DRAW WHAT YOU SAW"`, `show_starters = false`, `remember = false`. The tests cover this
set-up.

## Running

From the repository root:

    timeout 120 tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path godot --script res://face/face_tests.gd

prints the sizes and one summary line, `face tests: N passed, 0 failed`, and exits non-zero on any
failure. It never touches the player's own saved face.

    tools/godot/Godot_v4.7.2-stable_win64_console.exe --path godot --resolution 960x540 --position 40,40 res://face/face_demo.tscn -- [auto=1] [shots=DIR]

opens the editor; Done shows the face on four crewmates in a Clinic corridor through the tape
filter, E draws again, Esc quits. `auto=1` draws a face with mouse events, takes 24 pictures into
`shots/` (or `DIR`) and quits. The demo never reads or writes the saved face.

## What the pictures show

At 1 m every face reads in full, including the small details (the "OK", the wink, the glint in the
eye). At 2 m all four faces read clearly: the expression, the tear, the red mouth, the green "OK".
At 3 m the expression still reads (two eyes and the curve of the mouth, the red O of the shock),
but small details such as letters do not. At 6 m the screen is a small glowing square with faint
dark marks: you can tell someone is wearing a face, not which one. That is the limit of a 16.6 cm
screen in a 480 x 270 view, so it is not worth polishing further. The tape filter pushes red a
little to the right of where it was drawn; that is the filter, not the face.

## Wiring left for later

None of this is done. The pieces it needs are all here.

1. **Start screen, before the run.** Add a "draw your face" step to the start screen (or the lobby)
   before the elevator: instance `face_editor.tscn`, full rect, with `remember = true`; it opens on
   the player's last face, so returning players can press Enter at once. Keep the resulting `code`
   for the session. If the player cancels, use `FaceCodec.load_last()`, and if that is empty, send
   no face (the crewmate then shows `CrewView.default_face()`). Teach it in one line: the editor
   already says "BIG AND BOLD READS BEST".
2. **Network: a `face` field.** Send the code once, when the player joins. The join message today
   is `[1, "J", name, ct]` (`net/protocol.gd`, `encode` and `decode`); add the face as a fifth,
   optional element and keep accepting four. On decode, take it only if it is a String of at most
   515 characters (`FaceCodec.MAX_LENGTH`) and `FaceCodec.check(face) == ""`; anything else counts
   as no face, and the player still joins. A join with the worst-case face is under 700 bytes,
   well inside the 4096-byte message limit. The host keeps each player's face and passes it to the
   others once (on join, and in what a late joiner receives), never in the 20 Hz snapshot.
   `host.gd`'s `_relay_emote` is the pattern for relaying to the other players. The room server
   (`server/room.gd`) has a list of message types it accepts and would need the same change if a
   new message type is used instead.
3. **The avatar's mask.** `CrewView.set_face(FaceCodec.decode(code))` already works (the demo does
   exactly this); `null` gives the default face.
4. **The elevator monitor.** A screen in the elevator showing every player's face, for example
   side by side: `FaceCodec.decode(code)` per player, drawn with nearest filtering on the monitor's
   surface.
5. **The standee.** Where a player falls, a flat cut-out with their face: the same texture on its
   head.
6. **Posters.** Faces on walls where they should not be (split reality). `FaceCodec.to_image()`
   gives the picture to compose into a poster texture at any size.
7. **Later waves.** The scared face (a second doodle that swaps in when the microphone spikes) is a
   second code in the same format, sent the same way; the editor needs only a different `title`.
