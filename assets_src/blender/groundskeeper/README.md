# Groundskeeper

Run either script in a fresh headless Blender 5.3 process. Pass the directory containing the six takes listed in [MIXAMO.md](MIXAMO.md) to rebuild the game GLB. Add `--preview` after the Blender argument separator for nine 480×270 lighting and pose studies under `godot/export/groundskeeper/`.

```powershell
& $Blender -b --disable-autoexec --python-exit-code 1 --python assets_src/blender/groundskeeper/build_groundskeeper.py -- --mixamo-dir $MotionDirectory
& $Blender -b --disable-autoexec --python-exit-code 1 --python assets_src/blender/groundskeeper/check_groundskeeper.py
```

The game rig uses metres, faces Godot +Z, and has a stationary floor origin. `Head`, `Badges`, and `Shears` are attachment points. `Blade.B` opens once in the snatch and closes at 0.20 seconds. `Blade.A` stays fixed to the grip. The last half-second of `lean` holds its pose before `recover` returns to listening.

Running the builder without `--mixamo-dir` generates the T-pose upload and the authored fallback GLB. Pass `-- --authored` to the checker when inspecting that fallback. The upload contains the coverall figure with open hands and straight arms. The badge cord, loose roots, and shears are on the game rig.
