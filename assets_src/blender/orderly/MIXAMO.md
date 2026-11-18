# Orderly Mixamo bake

The private source takes are the Orderly downloads delivered 18 November 2026. All seven came with the same 25-bone rig and 14,458-vertex source mesh. The game GLB uses the original 44-bone Orderly, textures, hands and cloth. Retargeting copies sampled motion onto that rig.

| Take | Use | SHA-256 |
| --- | --- | --- |
| Zombie Idle.fbx | Upper body idle twitch | dec1aec3a50b6f2673eecb3023acd353cd126a31fab3820ce56e099d5f6575c7 |
| Scary Clown Walk.fbx | Main walk movement | 4edb50dbffba9074e4328d691f983eaddfa949a7be9d5417c5a913bbc1caa6ee |
| Scary Clown Walk (1).fbx | Faster movement mixed into the walk | e3d745eabfa9b29797baf0671348bba7a59ba9ba72d01c80e0ae6295bae30d34 |
| Push.fbx | Arm movement mixed into the walk | 06ed11565adc089c232faf541c8d4407f82409f773b0fd7d4551d5b0d7dd9c60 |
| Zombie Attack (1).fbx | Middle of the reach | 370e193ae8a50fdf82deb152ab77a6d23f9952bf2c06d30c10cbd7667e0e65b3 |
| Yelling Out.fbx | Head and spine during the first 0.8 seconds of the bend | ff637d1bff46e0da717c4a705f40860d33e8a496ee54362e5cf0eb099622a896 |
| Bellydancing.fbx | First nine seconds, after the bend when the room setting is on | df47c27a2d542c58f24c892f14b6fa205b54a5e07e04d3889055a1fc4081fee9 |

Run with Blender 5.3 from the checkout root. Replace the source directory with the location of the seven FBXs if needed.

```powershell
& tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --disable-autoexec --python-exit-code 1 --python assets_src/blender/orderly/build_orderly.py -- --out "$PWD/godot/assets/entities/orderly.glb" --mixamo-dir "$PWD/.local/orderly-mixamo-2026-11-18"
```

Use the Godot asset path for the bake. The authored door duck keeps its clearance pose. The reach starts and ends in the authored stretch poses. The walk and all catch clips leave the authoritative position and facing to the host.
