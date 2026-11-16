# Textures from Gemini

`generate.mjs` makes game textures with Google's Gemini image model, inside a fixed budget, and
post-processes them into the game's low-colour look.

## Add a texture in one command

1. Add an entry to `requests` in `requests.json`:
   `id`, `purpose`, `prompt` (the subject only; the style block is added for you), `size` (final px,
   a number or `[w, h]`), and as needed `tile` (`true`, or `"x"` for left-right only), `alpha_key`
   (`"#FF00FF"` or `"#00FF00"`: the model paints holes and background in that colour),
   `alpha_from_white` (stains: drawn on white, anything darker becomes opaque), `aspect` (`"16:9"`),
   `palette` (hex notes added to the prompt) and `post` options (see `post()` in the script).
2. Run (PowerShell; the path to the key file comes from `.local/MACHINE.md` and is never written
   into a tracked file):

   ```
   $env:GD_GEMINI_KEY_FILE = '<path from .local/MACHINE.md>'; node assets_src/textures/generate.mjs <id>
   ```

3. Look at `public/assets/textures/<id>.png` and, for tiling textures, `check/<id>_2x2.png`
   (four copies, pixels enlarged, to spot seams); for alpha textures `check/<id>_on_grey.png`.
   To change only the post-processing, edit `post` and run `node assets_src/textures/generate.mjs
   --post <id>` (no request, no cost). To re-prompt, change the prompt (which changes the hash) and
   note the rejected hash and why under `rejected`.

Other commands: `--list-models` (free; logs the image models to the ledger), `--status`.

## The style block

Prepended to every prompt (`style` in `requests.json`):

> Game texture, 1990s. A flat, evenly lit material photographed straight on, filling the whole frame
> edge to edge: no perspective, no vignette, no cast shadows, no light falloff, no border or frame,
> no text or letters unless asked. Institutional and worn. Muted hospital palette: washed greens,
> off-whites, nicotine yellow, dried brown.

Tiling requests add `tile_clause`; cut-outs add `alpha_clause` or `alpha_white_clause`.

## The budget rule

- This task: at most **$3.00** and **60 images** (`budget` in `requests.json`); the owner's whole
  art budget is $10. Every paid request goes into `ledger.json` with its purpose, model, size, time,
  estimated cost and the API's usage metadata. A request that would pass either limit is refused
  before anything is sent.
- The ledger charges **$0.04 per 1K image**. Google's pricing page (read 2026-11-15) listed about
  $0.034 per 1K image; every response so far reported 1,120 image tokens, which at $30 per million
  output image tokens is $0.0336, plus about 100 to 300 text/thinking tokens (cents of a cent at
  most). So $0.04 is a safe ceiling, not an exact price.
- Results are cached by a hash of (full prompt + model + size) in `raw/<id>__<hash>.jpg`: the same
  picture is never paid for twice. Raw files are the source; keep them.
- If the key is missing, the model list fails or the API refuses, the script stops and prints only
  the HTTP status and the API's error text. The key travels only in the `x-goog-api-key` header and
  is never printed, logged or written to disk.

## Post-processing (ImageMagick)

shave/crop borders -> optional flatten (divide by a heavy blur; off by default now, see below) ->
key out alpha (hard threshold, so the game can alpha-test) -> offset-and-blend tiling (the image
rolled by half is blended in along the edges; a seam score is printed before and after, 1 = no seam;
`tile_method: "none"` keeps an image the model already made seamless) -> box downscale -> ordered
dither (4x4, 16/16/14 levels) and a 32-colour cap -> metadata stripped.

## What is here (2026-11-16)

| id | size | for | notes |
|---|---|---|---|
| orderly_gown_cloth | 256 tile | Orderly gown | already seamless from the model |
| orderly_gown_torn | 256 alpha | Orderly hem strips and holes | magenta key |
| orderly_skin | 256 tile | Orderly skin | model repeated it 2x2 inside the frame |
| orderly_eyelid | 128 alpha | Orderly sewn lids | green key; seam is vertical (turned in the build) |
| orderly_mask | 256 | Orderly mask | no smile; the smile is drawn by `build_orderly.py` |
| wall_paint | 256 tile-x | building walls | stripe sits ~37% up, not 30% as asked |
| floor_tile | 128 tile | building floor | 4x4 tiles, grid lines up with the tiling |
| ceiling_tile | 128 tile | building ceiling | faint stains only (the ring try came out as polka dots) |
| decal_rust_stain | 256 alpha | building decal | dark-on-white cut-out |
| decal_handprint | 128 alpha | building decal | dark-on-white cut-out |
| sign_ward4, sign_quiet, sign_staff, sign_wash | 256x144 | building signs | no dither, 16 colours, legible |

The building textures are produced and documented only; wiring them into the game is a later task.
