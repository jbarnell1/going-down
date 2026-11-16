// Turns a FloorPlan into a lit three.js scene: five merged meshes (floors, walls, ceilings, trim,
// lights), cheap lighting, and fog so long halls fade rather than end.
//
// The floor's meshes and lights live in one group, so a run can swap floors without rebuilding the
// scene (the Orderly, the tapes and the elevator car stay in it): replaceFloor() disposes the old
// group's geometry, materials and textures and builds the new one.

import * as THREE from 'three';
import type { FloorPlan } from '../sim/floor';
import { buildFixtures } from './fixtures';
import { GeoBuilder } from './geoBuilder';
import { buildStructure } from './structure';
import { ceilingTexture, floorTexture, wallTexture } from './textures';

export interface World {
  scene: THREE.Scene;
  /** One per material, for counting draw calls and, later, picking shadow casters. */
  meshes: THREE.Mesh[];
  /** The floor's meshes and lights. */
  floor: THREE.Group;
}

export const FOG = 0xdfe8e4;

/**
 * The emergency lighting's wash when fully on: a deep red-amber light, strongest on the floor and
 * the lower walls (the strips are at the foot of the walls) and weakest on the ceiling, enough to
 * read walls, doorways and corners at the tape's 270 lines, and nothing like the cold white of the
 * real lights. `sky` lights faces turned up, `ground` faces turned down.
 */
export const EMERGENCY_WASH = { sky: 0x8a1c08, ground: 0x3a0804, intensity: 2.4 };

/** The meshes and lights of one floor, in a group named 'floor'. */
export function buildFloor(plan: FloorPlan): { group: THREE.Group; meshes: THREE.Mesh[] } {
  const group = new THREE.Group();
  group.name = 'floor';
  const shell = buildStructure(plan);
  const trim = new GeoBuilder();
  buildFixtures(plan, trim, shell.lights);

  // Lambert throughout: cheap, takes vertex colours, and can receive a shadow map later.
  const parts: [GeoBuilder, THREE.Material, string][] = [
    [shell.floors, new THREE.MeshLambertMaterial({ map: floorTexture(), vertexColors: true }), 'floors'],
    [shell.walls, new THREE.MeshLambertMaterial({ map: wallTexture(), vertexColors: true }), 'walls'],
    // Ceilings face down, away from the sky light; a little emission stands in for light bounced
    // off a bright floor, so the ceiling reads lit rather than grey.
    [shell.ceilings, new THREE.MeshLambertMaterial({ map: ceilingTexture(), vertexColors: true, emissive: 0x5a605d }), 'ceilings'],
    [trim, new THREE.MeshLambertMaterial({ vertexColors: true }), 'trim'],
    // Light panels are pure emission: unlit, and fog still fades them with distance.
    [shell.lights, new THREE.MeshBasicMaterial({ color: 0xf6fbff }), 'lights'],
    // The emergency strips and signs: pure glow, hidden while the lights are on (setEmergency).
    [shell.emergency, new THREE.MeshBasicMaterial({ vertexColors: true }), 'emergency'],
  ];
  const meshes: THREE.Mesh[] = [];
  for (const [g, mat, name] of parts) {
    if (g.empty) {
      mat.dispose();
      continue;
    }
    const mesh = new THREE.Mesh(g.build(), mat);
    mesh.name = name;
    mesh.matrixAutoUpdate = false;
    if (name === 'emergency') {
      // Not scaled by applyLighting, and not drawn at all with the lights on.
      mesh.userData.ownLight = true;
      mesh.visible = false;
    }
    group.add(mesh);
    meshes.push(mesh);
  }

  // Every light on: an even wash from above, plus two weak directional fills from different sides so
  // walls facing different ways shade differently and corners read.
  group.add(new THREE.HemisphereLight(0xffffff, 0xd2dad6, 2.0));
  const key = new THREE.DirectionalLight(0xffffff, 0.9);
  key.position.set(0.6, 1, 0.25);
  group.add(key);
  const fill = new THREE.DirectionalLight(0xf2fff8, 0.35);
  fill.position.set(-0.3, 0.6, -0.9);
  group.add(fill);
  // The emergency wash. Always in the scene at intensity 0 with the lights on (it then adds exactly
  // nothing, and toggling a light's presence would recompile every material at the moment the lights go).
  const wash = new THREE.HemisphereLight(EMERGENCY_WASH.sky, EMERGENCY_WASH.ground, 0);
  wash.name = 'emergency-wash';
  wash.userData.ownLight = true;
  group.add(wash);
  return { group, meshes };
}

/** The emergency lighting, 0 (off: the reference look) to 1 (fully on, in the dark). */
export function setEmergency(floor: THREE.Object3D, k: number): void {
  const on = Math.max(0, Math.min(1, k));
  for (const o of floor.children) {
    if (o.name === 'emergency') {
      const mesh = o as THREE.Mesh;
      mesh.visible = on > 0;
      (mesh.material as THREE.MeshBasicMaterial).color.setScalar(on);
    } else if (o.name === 'emergency-wash') {
      (o as THREE.HemisphereLight).intensity = EMERGENCY_WASH.intensity * on;
    }
  }
}

/** Frees everything a group's meshes hold on the GPU: geometry, materials and their textures. */
export function disposeGroup(group: THREE.Object3D): void {
  group.traverse((o) => {
    const mesh = o as THREE.Mesh;
    if (!mesh.isMesh) return;
    mesh.geometry.dispose();
    const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
    for (const m of mats) {
      for (const v of Object.values(m)) if (v instanceof THREE.Texture) v.dispose();
      m.dispose();
    }
  });
}

export function buildWorld(plan: FloorPlan): World {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(FOG);
  // The Clinic's rule is that nowhere hides you, so its haze starts late: a figure standing at the
  // far end of the longest hall (about 50 m) must still be crisp. Darker places will bring fog close.
  scene.fog = new THREE.Fog(FOG, 38, 130);
  const { group, meshes } = buildFloor(plan);
  scene.add(group);
  return { scene, meshes, floor: group };
}

/** Swaps the world's floor for a new plan's, disposing the old one. */
export function replaceFloor(world: World, plan: FloorPlan): void {
  world.scene.remove(world.floor);
  disposeGroup(world.floor);
  const { group, meshes } = buildFloor(plan);
  world.scene.add(group);
  world.floor = group;
  world.meshes = meshes;
}
