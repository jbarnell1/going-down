// Shows an entity model (a skinned, animated .glb) standing in the scene: loads it, plays one of its
// named animations, and gives it a real shadow on the floor. The shadow comes from one light straight
// overhead (like the ceiling panels) with a small frustum that follows the figure, landing on a
// shadow-only patch under its feet, so the world's own materials and the rest of the floor are
// untouched. The model is shaded with Lambert, like the room, so it sits in the same washed light.
// The entity runtime builds on this.

import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';

export interface EntityPreviewOptions {
  /** Shadow-catcher size in metres (square, centred on the feet). */
  shadowPatch?: number;
  /** Shadow map size in texels. */
  shadowMapSize?: number;
}

/** Animations that play once and hold their last pose; the rest loop. */
const ONCE = new Set(['reach']);

export class EntityPreview {
  /** Moved and turned to place the figure. Its origin is on the floor between the feet. */
  readonly root = new THREE.Group();
  readonly ready: Promise<void>;
  loaded = false;
  private mixer: THREE.AnimationMixer | null = null;
  private clips = new Map<string, THREE.AnimationClip>();
  private action: THREE.AnimationAction | null = null;
  private currentName = '';
  private bones = new Map<string, THREE.Bone>();
  private readonly light: THREE.DirectionalLight;
  private readonly catcher: THREE.Mesh;
  private pending = 'idle';

  constructor(scene: THREE.Scene, url: string, opts: EntityPreviewOptions = {}) {
    const patch = opts.shadowPatch ?? 3;
    scene.add(this.root);

    // The shadow light: straight down, like the ceiling panels, so the shadow is a short contact
    // shadow the feet stand in; it also puts pale highlights on the cap and shoulders and leaves the
    // underside of the chin and hands in shade.
    this.light = new THREE.DirectionalLight(0xfffdf6, 0.8);
    this.light.castShadow = true;
    const cam = this.light.shadow.camera;
    cam.left = -patch / 2;
    cam.right = patch / 2;
    cam.top = patch / 2;
    cam.bottom = -patch / 2;
    cam.near = 0.5;
    cam.far = 10;
    this.light.shadow.mapSize.set(opts.shadowMapSize ?? 512, opts.shadowMapSize ?? 512);
    this.light.shadow.bias = -0.002;
    this.light.shadow.radius = 1.5; // a slightly softened edge (PCF)
    scene.add(this.light, this.light.target);

    this.catcher = new THREE.Mesh(
      new THREE.PlaneGeometry(patch, patch).rotateX(-Math.PI / 2),
      new THREE.ShadowMaterial({ opacity: 0.38, depthWrite: false }),
    );
    this.catcher.receiveShadow = true;
    this.catcher.renderOrder = 1;
    scene.add(this.catcher);

    this.ready = new GLTFLoader().loadAsync(url).then((gltf) => {
      gltf.scene.traverse((o) => {
        if ((o as THREE.Bone).isBone) this.bones.set(o.name, o as THREE.Bone);
        const mesh = o as THREE.Mesh;
        if (!mesh.isMesh) return;
        mesh.castShadow = true;
        // The reach stretches far past the bind pose's bounds; one mesh, so skip the culling test.
        mesh.frustumCulled = false;
        // Same shading model as the world (Lambert), keeping the texture with hard pixels.
        const lambert = (m: THREE.Material): THREE.Material => {
          const map = (m as THREE.MeshStandardMaterial).map;
          if (map) {
            map.magFilter = THREE.NearestFilter;
            map.minFilter = THREE.NearestFilter;
            map.generateMipmaps = false;
            map.needsUpdate = true;
          }
          const out = new THREE.MeshLambertMaterial({ map, side: m.side });
          m.dispose();
          return out;
        };
        mesh.material = Array.isArray(mesh.material) ? mesh.material.map(lambert) : lambert(mesh.material);
      });
      this.root.add(gltf.scene);
      this.mixer = new THREE.AnimationMixer(gltf.scene);
      for (const c of gltf.animations) this.clips.set(c.name, c);
      this.loaded = true;
      this.play(this.pending);
    });
  }

  /** Names of the animations in the file. */
  animations(): string[] {
    return [...this.clips.keys()];
  }

  /** The animation now playing ('' before the model has loaded). */
  current(): string {
    return this.currentName;
  }

  /** Switches to a named animation. Returns false if the model has no such animation. */
  play(name: string): boolean {
    if (!this.mixer) {
      this.pending = name;
      return true;
    }
    const clip = this.clips.get(name);
    if (!clip) return false;
    this.action?.stop();
    const a = this.mixer.clipAction(clip);
    a.reset();
    if (ONCE.has(name)) {
      a.setLoop(THREE.LoopOnce, 1);
      a.clampWhenFinished = true;
    } else {
      a.setLoop(THREE.LoopRepeat, Infinity);
    }
    a.play();
    this.action = a;
    this.currentName = name;
    return true;
  }

  /**
   * Puts the feet at (x, y, z) in world metres. `yaw` uses the player's convention (radians about
   * +y, 0 faces north, -z); the model itself faces +z.
   */
  place(x: number, y: number, z: number, yaw: number): void {
    this.root.position.set(x, y, z);
    this.root.rotation.set(0, yaw + Math.PI, 0);
    this.follow();
  }

  /** World position of a bone, for tests: proves the skeleton is moving. */
  bonePosition(name: string): [number, number, number] | null {
    // The loader strips characters such as '.' from node names ('foot.L' arrives as 'footL').
    const b = this.bones.get(name) ?? this.bones.get(THREE.PropertyBinding.sanitizeNodeName(name));
    if (!b) return null;
    const v = b.getWorldPosition(new THREE.Vector3());
    return [v.x, v.y, v.z];
  }

  update(dt: number): void {
    this.mixer?.update(dt);
  }

  private follow(): void {
    const p = this.root.position;
    this.light.position.set(p.x + 0.05, p.y + 7, p.z + 0.1);
    this.light.target.position.copy(p);
    this.light.target.updateMatrixWorld();
    this.catcher.position.set(p.x, p.y + 0.004, p.z);
  }
}
