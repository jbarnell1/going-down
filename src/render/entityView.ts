// The live Orderly on screen: the model from entityPreview.ts, posed from the logic's state.
//
// The logic (sim/entity.ts) runs 20 times a second. Between its ticks the figure is smoothed from
// the previous tick's pose to the latest one, but ONLY while the local player cannot see it. The
// frame it becomes visible it is put exactly where the logic has it, the pose is captured, and from
// then on nothing changes on screen (position, facing, animation clock) until it is unseen again.
// Smoothing therefore never carries it forward after it freezes.

import { WIND_UP_TIME, type OrderlyAnim, type OrderlyState } from '../sim/entity';
import { EntityPreview } from './entityPreview';
import type * as THREE from 'three';

/** Walk clip playback rate against the logic's animation clock. The clip's 2 s cycle at 3.4 m/s
 * reads as gliding; 1.7x gives a lurching stride of about 2 m per step. */
export const WALK_RATE = 1.7;

/** What is drawn this frame: feet position (metres), facing (radians, three.js style), clip and time. */
export interface DrawnPose {
  x: number;
  y: number;
  z: number;
  yaw: number;
  anim: OrderlyAnim;
  /** Seconds into the logic's animation clock (before clip rate scaling). */
  animTime: number;
}

function lerpAngle(a: number, b: number, t: number): number {
  let d = (b - a) % (2 * Math.PI);
  if (d > Math.PI) d -= 2 * Math.PI;
  if (d < -Math.PI) d += 2 * Math.PI;
  return a + d * t;
}

/** The pose the logic implies between two ticks (alpha 0 = prev, 1 = cur). */
export function blendPose(prev: OrderlyState, cur: OrderlyState, alpha: number): DrawnPose {
  const a = Math.min(1, Math.max(0, alpha));
  // A clip change or a level change (stairs) is not blended: show the newer tick's clip.
  const sameClip = prev.anim === cur.anim && prev.body.level === cur.body.level;
  return {
    x: prev.body.x + (cur.body.x - prev.body.x) * a,
    y: prev.body.y + (cur.body.y - prev.body.y) * a,
    z: prev.body.z + (cur.body.z - prev.body.z) * a,
    yaw: lerpAngle(prev.yaw, cur.yaw, a),
    anim: cur.anim,
    animTime: sameClip ? prev.animTime + (cur.animTime - prev.animTime) * a : cur.animTime,
  };
}

/** The exact pose of one logic state. */
export function exactPose(s: OrderlyState): DrawnPose {
  return { x: s.body.x, y: s.body.y, z: s.body.z, yaw: s.yaw, anim: s.anim, animTime: s.animTime };
}

export class EntityView {
  readonly model: EntityPreview;
  /** The pose last drawn. */
  drawn: DrawnPose | null = null;
  /** The pose captured the frame it became visible; held while it stays visible. */
  private frozen: DrawnPose | null = null;

  constructor(scene: THREE.Scene, url: string) {
    this.model = new EntityPreview(scene, url);
  }

  get loaded(): boolean {
    return this.model.loaded;
  }

  get isFrozen(): boolean {
    return this.frozen !== null;
  }

  /** Widest the figure gets from its feet axis in a clip (metres), measured from the mesh at load. */
  extent(anim: OrderlyAnim): number {
    return this.model.extent(anim);
  }

  /**
   * Draws the figure. `visible`: the local player's screen could show it this frame. `freezePose`
   * is used the first frame it is visible (normally the logic's exact latest pose).
   */
  update(visible: boolean, smooth: DrawnPose, freezePose: DrawnPose): void {
    if (visible) {
      if (!this.frozen) this.frozen = freezePose;
      this.apply(this.frozen);
    } else {
      this.frozen = null;
      this.apply(smooth);
    }
  }

  /** Shows or hides the figure (it is on another floor, or there is nothing to draw yet). */
  setVisible(on: boolean): void {
    this.model.root.visible = on;
    if (!on) {
      this.drawn = null;
      this.frozen = null;
    }
  }

  private apply(p: DrawnPose): void {
    this.drawn = p;
    this.model.place(p.x, p.y, p.z, p.yaw);
    this.model.pose(p.anim, this.clipTime(p.anim, p.animTime));
  }

  private clipTime(anim: OrderlyAnim, t: number): number {
    if (anim === 'walk') return t * WALK_RATE;
    // The reach clip is drawn out over the wind-up, so the hand is at full stretch when it lands.
    if (anim === 'reach') return (t / WIND_UP_TIME) * this.model.duration('reach');
    return t;
  }
}
