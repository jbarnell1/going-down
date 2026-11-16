// Turns a FloorPlan into a lit three.js scene: five merged meshes (floors, walls, ceilings, trim,
// lights), cheap lighting, and fog so long halls fade rather than end.

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
}

const FOG = 0xdfe8e4;

export function buildWorld(plan: FloorPlan): World {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(FOG);
  // The Clinic's rule is that nowhere hides you, so its haze starts late: a figure standing at the
  // far end of the longest hall (about 50 m) must still be crisp. Darker places will bring fog close.
  scene.fog = new THREE.Fog(FOG, 38, 130);

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
  ];
  const meshes: THREE.Mesh[] = [];
  for (const [g, mat, name] of parts) {
    if (g.empty) continue;
    const mesh = new THREE.Mesh(g.build(), mat);
    mesh.name = name;
    mesh.matrixAutoUpdate = false;
    scene.add(mesh);
    meshes.push(mesh);
  }

  // Every light on: an even wash from above, plus two weak directional fills from different sides so
  // walls facing different ways shade differently and corners read.
  scene.add(new THREE.HemisphereLight(0xffffff, 0xd2dad6, 2.0));
  const key = new THREE.DirectionalLight(0xffffff, 0.9);
  key.position.set(0.6, 1, 0.25);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0xf2fff8, 0.35);
  fill.position.set(-0.3, 0.6, -0.9);
  scene.add(fill);

  return { scene, meshes };
}
